# shellmux: a race-free deadline scheduler (and an honest broker) in ~150 lines of shell

*A topic pub/sub broker built from socat-fork, FIFOs, and flock — whose one hard, real contribution is a data-derived deadline scheduler that fires timed messages race-free against concurrent publishes, with zero idle CPU and no timer wheel.*

## The Vision

Brokers are where "simple" goes to grow a config language, a JVM, and a clustering protocol nobody reads. For an enormous class of real deployments — sensors on a boat, CI runners on a LAN, a homelab event bus, an air-gapped factory floor — you do not need any of that. You need correct fan-out plus correct *timing*: a publisher writes to a topic, every live subscriber gets the bytes, a dead subscriber is forgotten not stranded, and a TTL/retry/delayed message fires when it is due rather than a poll-cycle later.

The bet is narrow and honest. Two of the three properties people pay clustered brokers for — per-subscriber isolation and forget-on-death — *fall out of fork-per-connection for free* and are not where the engineering is. The third — **timed delivery that is race-free against concurrent publishes, with zero busy-spin** — is the one thing a `tee`-to-FIFOs one-liner cannot do, and it is genuinely hard in a language with no threads, no atomics, and only advisory locks. shellmux earns its keep there, and is honest about the rest.

## The Novel Idea

The genuinely new artifact is a **correct data-derived deadline scheduler in POSIX-ish shell**: state lives entirely on disk as `deferred/<run_at>.<seq>` files; the scheduler computes `next = MIN(run_at)` over those filenames, then blocks on `read -t $(( min(idle_poll, next-now) ))` against a wake-FIFO that publishers poke. The correctness discipline — *re-scan disk on every wake; wakes carry no data; a publish that lands during deadline computation still leaves a file the next scan finds* — makes the classic "slept through a just-arrived deadline" bug **structurally absent for correctness**, with worst-case latency bounded by `idle_poll` (the poll fallback), not by the best-effort wake.

That is the brag, and it is small. Everything else is honestly a refactor: isolation is "each subscriber is a forked process" (free from socat); forget-on-death is an `EXIT`-trap `rm` plus a `[ -p ]` fan-out skip. We do **not** claim novel parts — FIFO fan-out and brokers are ancient. We claim a *small thing that is correct and provably so*.

## Prior Art & How We Differ

- **honker (the algorithm we port).** honker's claim loop queries `queue_next_claim_at` (`honker-core/src/honker_ops.rs:536-558`: `SELECT COALESCE(MIN(deadline),0)` over pending `run_at` and processing `claim_expires_at`) then calls `recv_until(&self.rx, next_at)` (`packages/honker-rs/src/lib.rs:828`). `recv_until` itself (`lib.rs:1558-1582`) does `recv_timeout(Duration::from_secs(unix_sec-now))` then drains. We re-express this over FIFOs/`read -t`. **Crucially, even honker's reference uses `from_secs` — whole-second resolution** — so our ~1s granularity is faithful, not a degradation. The "recv first, then drain" ordering (`lib.rs:1105-1106`: *"the opposite order would lose a wakeup when a publish lands between refill() and drain"*) is the rule we adopt as "stage the file, *then* poke the wake-FIFO." We add no SQLite, no Rust, no WAL.
- **honker's prune vs. death-guard (we fix the draft's swapped mapping).** honker's *opportunistic prune* is `list.retain(|_,s| match s.try_send(()) { Disconnected => false })` (`honker-core/src/lib.rs:957-960`) — this is what maps to our subscriber `EXIT`-trap unlink + `[ -p ]` skip (a leaf forgotten on its own death). honker's `WatcherDeathGuard::drop` (`lib.rs:908-916`) clears *all* senders when the **central** watcher thread dies so everyone fails loud — that maps to our **broker shutdown** (`pkill -P`), not to a single subscriber dying. The draft inverted these; this version states the mapping correctly.
- **terminalphone (the relay shape, cited for what's actually there).** The socat-fork acceptor (`terminalphone.sh:1206`/`1350`), per-client `out_${pid}.fifo` (`:1518`, mkfifo `:1520`), background drainer (`:1540`), keepalive `exec 3>` (`:1546`), `[ -p ]`-guarded fan-out (`:1567-1572`), flock'd stats (`:1585-1590`), and `kill`+`pkill -P` cleanup (`:1674-1676`) are all real and reused. **What is NOT there:** non-blocking writes. Line 1570 is `printf '%s\n' "$line" > "$f" 2>/dev/null &` — a *blocking* write backgrounded with `&`. We do not cite it for backpressure; we replace it (see Hard Problem).
- **Mosquitto / NATS / Redis / ZeroMQ.** kLOC–MLOC daemons with wire protocols and config. We do not compete on throughput, persistence, or clustering — only on auditability and a tiny dependency set.
- **inetd / xinetd / systemd socket activation.** Same fork-per-connection model socat gives us; no pub/sub, no topics, no timed delivery. They are transport, not broker.

## Architecture

- **Acceptor.** `socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'bash handler.sh $DIR'` plus a parallel `UNIX-LISTEN`. socat's `fork` gives each connection a fresh process with the socket on stdin/stdout — the kernel provides per-client isolation and crash cleanup. Handler `$$` is the subscriber's stable id (terminalphone.sh:1206/1350/1518).
- **Per-subscriber mailbox FIFO.** Handler does `mkfifo $DIR/topics/$T/sub_$$.fifo`, registers `trap 'rm -f $INFIFO' EXIT`, starts a drainer `while IFS= read -r m; do printf '%s\n' "$m"; done < $INFIFO &` and holds it open with `exec 3>$INFIFO` (terminalphone.sh:1520/1540/1546).
- **Bounded ring drainer (the corrected backpressure unit).** The drainer is the *only* writer to the socket. Publishers do **not** write the client socket; they write the FIFO, and the drainer applies a bounded policy (keep-newest-N or drop-on-timeout) so a slow socket cannot make writers accumulate. See Hard Problem for the two concrete implementations and their honest costs.
- **Publisher fan-out.** Per record: `for f in $DIR/topics/$T/sub_*.fifo; do [ "$f" = "$INFIFO" ] && continue; [ -p "$f" ] || continue; <bounded-write>; done` (terminalphone.sh:1567-1572 shape). Records are length-prefixed (see Framing). Broker parses only the `SUB`/`PUB` control line.
- **Subscriber death-guard.** `EXIT` trap unlinks the FIFO; the next fan-out's `[ -p ]` simply never sees it — the shell equivalent of honker's `Disconnected => false` prune (`lib.rs:957-960`).
- **Deadline scheduler.** Staged files `topics/$T/deferred/<run_at>.<seq>`; loop computes `next=$(min over names)`, blocks on `read -t $((min(idle,next-now)))` on a wake-FIFO, re-scans on wake, moves due records into fan-out, deletes them, recomputes. (honker `queue_next_claim_at` + `recv_until`.)
- **Shared state under flock.** `( flock 9; … ) 9>$DIR/.lock` for counters; topics are subdirs (`mkdir -p`, atomic). Liveness = existence of `sub_*.fifo` (terminalphone.sh:1585-1590).
- **Introspection = the filesystem.** `ls topics/`; `ls topics/$T/sub_*.fifo | wc -l`; `cat topics/$T/drops_*`; `ls topics/$T/deferred | sort | head -1`.

## The Hard Problem & Our Approach

**The one hard thing: timed delivery, race-free, zero busy-spin.** The bug class: a publish lands in the window between "scheduler computed `next`" and "scheduler entered the blocking wait," so the scheduler sleeps through a deadline. honker dodges it with the *discipline*, not a lock: durable state on disk, wakes that mean only "go re-read," recv-before-drain ordering (`honker-rs/src/lib.rs:1105-1106`). Our shell port: **(a)** durable deferred files are written *before* the wake-FIFO poke (stage-then-poke; the reverse loses the wake); **(b)** every wake triggers a full `deferred/` re-scan — a dropped or spurious wake costs one directory scan, never a missed message; **(c)** the `idle_poll` fallback (`read -t` always has a finite timeout = `min(idle_poll, next-now)`) guarantees that even if *every* wake is lost, the next poll rescans and fires. So correctness depends on the poll fallback; the wake only improves *latency*. We claim exactly that, and prove it with a chaos harness that hammers publishes into the computed window across thousands of trials and asserts zero missed and zero duplicate fires (duplicates prevented by `mv` of the deferred file into fan-out being the single commit point; a crash after `mv` but before fan-out re-delivers at most once on restart — see Risks).

**The backpressure write — re-spec'd honestly (the draft's fatal flaw).** terminalphone's `> $f &` is a *blocking* write backgrounded; under a flood to one wedged subscriber it spawns one stuck background process per message — an unbounded fd/process leak, the opposite of isolation. Bash has no O_NONBLOCK redirection and coreutils ships no non-blocking-FIFO-write tool. We offer two real mechanisms and pick one in the build:

1. **Bounded ring drainer (default).** Publishers always write the FIFO with a `timeout`-bounded write; the *drainer* owns boundedness: it reads frames into a fixed last-N ring and writes the socket, dropping oldest on overflow and bumping `drops_$pid`. Background writers cannot accumulate because there is exactly one long-lived drainer per subscriber, not one printf per message.
2. **`timeout`-bounded write.** `timeout 0.05 dd of="$f" bs=… 2>/dev/null` per subscriber per message; EWOULDBLOCK-equivalent = the timeout kills it, we bump `drops_$pid`. Honest cost: O(subs × msgs) fork+exec/sec (collapses the throughput envelope on a Pi), **and** a timeout mid-write can tear a frame — which is exactly why framing is length-prefixed, not newline (a torn frame is detected by short read and discarded, not concatenated).

We default to (1) and benchmark both on a real Pi.

## Control / Data Flow

1. **SUBSCRIBE.** Client connects; socat forks `handler.sh` with the socket on stdin/stdout (terminalphone.sh:1206/1350).
2. Handler reads one control line `SUB <topic>` (the only line interpreted), `mkdir -p topics/<topic>`, `mkfifo sub_$$.fifo`, sets `trap 'rm -f $INFIFO' EXIT`, starts the bounded ring drainer, `exec 3>$INFIFO`.
3. **PUBLISH.** Publisher sends `PUB <topic>` then streams **length-prefixed** records (`<decimal-len>\n<bytes>`).
4. **FAN-OUT.** Per record, iterate `sub_*.fifo`, skip self and non-pipes (`[ -p ]`), bounded-write each. Drop+counter on overflow; no peer blocked.
5. **DELAYED PUBLISH.** `PUB <topic> --at <epoch>` (or `--delay <s>`) writes `deferred/<epoch>.<seq>` **first**, *then* pokes the wake-FIFO.
6. **SCHEDULER WAKE.** Computes `next=min(deferred/*)`, blocks `read -t $((min(idle,next-now)))` on the wake-FIFO; wakes on poke or timeout.
7. On wake: re-scan `deferred/`, `mv` each now-due file into the fan-out path (step 4), recompute `next`, re-block.
8. **SUBSCRIBER DEATH.** Disconnect/kill → `EXIT` trap `rm -f sub_$$.fifo`; next scan never sees it; count drops by one.
9. **BROKER DEATH.** Parent `kill`s socat, `pkill -P` the handlers (terminalphone.sh:1674-1676); each `EXIT` trap unlinks; subscribers get EOF and reconnect — fail-loud, no silent hang.

## Key Design Decisions & Tradeoffs

- **Forked process + private FIFO per subscriber.** True isolation and crash-safety free from the kernel; costs a process+FIFO each, so the real ceiling is fd/process limits — **measured and stated on the Pi**, not the round word "hundreds."
- **Backpressure = bounded ring drainer with a visible `drops_$pid`.** Lossy under sustained overload *for that one subscriber only*, never silent. No at-least-once in MVP. "Make the bad state impossible" is **claimed only for the stranded-FIFO case** (a write to a vanished pipe is a harmless ENOENT/ENXIO); for backpressure the bad state is *possible* and *mitigated*, and we say so.
- **Data-derived deadline wakeup.** Zero idle CPU; resolution ~1s on dash/bash3, sub-100ms only with bash≥4 fractional `read -t`. We state the platform-qualified number and that worst-case latency = `idle_poll`.
- **Length-prefixed framing.** Recovers from torn writes; costs slightly more `read` plumbing than newline framing.
- **Content-blind = an honesty note, not a feature.** The broker never parses payloads (simpler). It is **not** privacy/E2EE — the host sees every byte. Use `socat OPENSSL` or SSH for transport security.
- **State is the filesystem; no admin protocol.** Composes with every UNIX tool; no atomic multi-key txn, no remote admin beyond the FS.
- **Trust model stated.** No auth: any local process (or any LAN peer on the TCP listener) can `PUB`/`SUB`/enumerate topics via `ls`. Fine air-gapped; an open bus on a LAN. Lock down with UNIX-socket-only + filesystem perms, or front with `socat OPENSSL` + client cert.

## MVP / Hackathon Scope

**Delivers:** one `shellmux` script (~150 lines) that (a) accepts `SUB`/`PUB` over UNIX + TCP via socat-fork; (b) topics = subdirs; (c) isolated FIFO mailbox per subscriber with a **bounded ring drainer** and visible `drops_$pid`; (d) `EXIT`-trap unlink + `[ -p ]` forget-on-death; (e) `--at`/`--delay` deferred delivery via honker's data-derived deadline wakeup with stage-then-poke ordering and idle-poll fallback; (f) full `ls`/`cat` introspection; plus a demo harness, a **deadline chaos test** (publishes inside the compute-window, asserts 0 missed/0 dup over N≥5000 trials), a wedged-subscriber flood test asserting flat publisher rate **and flat background-process/fd count over time** (`lsof`/`ps`), and a deferred crash-recovery test.

**Punts:** persistence/replay, full at-least-once/acks, wildcard/hierarchical topics, auth/TLS (delegate to socat OPENSSL/SSH), clustering/HA, payload inspection. Throughput is bounded by per-message FIFO writes + dir scans (low thousands of small msgs/sec on a Pi).

**Build sequence:** (1) deadline scheduler + chaos test FIRST (the hard, provable core); (2) socat-fork acceptor + SUB handler + ring drainer; (3) length-prefixed fan-out + drop counter; (4) `EXIT`-trap + `[ -p ]` death path; (5) deferred crash recovery + topic GC reaper; (6) demo + benchmarks on the Pi.

**As-built note (honesty reconciliation, post-implementation).** The "~150 lines / one screen"
figure is the size of the *contribution* — `src/sched.sh` is **186 lines**. The full broker
`src/shellmux` (acceptor + SUB/PUB + bounded-drainer fan-out + deferred-PUB wiring + client helpers +
GC reaper + input validation) is **504 lines** (374 pre-R1; +78 for the input-boundary gates that
validate the data path deriving the deadlines, +6 for the round-002 arg-rc split, +21 for the R3
per-subscriber fan-out write lock and the corrupt-deferred skip guard, +23 for the v0.1.0 top-level
`--version`/`--help`). The pitch should say "the scheduler is one screen", not "the whole
broker". The wedged-flood beat is as-built true: healthy subscribers receive the full flood while a
wedged peer's `drops_$pid` ticks up and `ps --ppid $PUB` stays flat (~15 vs a leaky control's ~1300).
The bounded write is **not fork-free** (each is a `timeout bash -c`, ~0.5–10ms on the dev host); the
proven claim is *no per-message process accumulation*, not "zero forks". Backpressure remains lossy
and best-effort, exposed via `drops_$pid` — never silent, never claimed lossless. All other spec
claims held as written.

**R3 hardening (post-round-2 adversarial-verification pass).** A fresh 5-lens adversarial workflow
(spine race-corners, data-plane, crash-recovery, prior-art, doc-honesty) re-confirmed the missed=0/dup=0
proof live (NOT-REFUTED, 0 threats to the proof axis) and surfaced two real *off-axis* robustness bugs,
both fixed test-first with must-fail controls: (1) a corrupt deferred filename (non-numeric `run_at`
prefix — reachable only by a raw producer writing into the filesystem-native state dir, NOT through the
validated broker) crashed the scheduler under `set -u`, a global-liveness DoS — now skipped per the
"a spurious wake costs one scan, never a missed message" posture (`tests/corrupt_deferred.sh`);
(2) two concurrent publishers fanning records **larger than PIPE_BUF (4 KiB)** to the same subscriber
could interleave bytes into a torn/concatenated frame that reached a *healthy* subscriber — the
length-prefix short-read guard alone did not cover the concurrent-large-write case. Fan-out writes are
now serialized under a **per-subscriber** `flock` (atomic per sub, parallel across subs, still
`timeout`-bounded so the backpressure contract and wedged-vs-healthy isolation are unchanged) —
`tests/concurrent_frames.sh`. Neither touches `src/sched.sh`'s `mv` commit point or the wake
discipline; chaos re-ran `missed=0 dup=0` over N=5000 after both.

## The Demo

On a literal $5 Raspberry Pi (bash, coreutils, util-linux, socat — the *real* dep set, stated on the slide), start `shellmux`, no config. *(As-built note: the proof and footprint were re-measured on real ARM64 bare metal — AWS Graviton t4g.nano/0.5 GB and t4g.small/2 GB, AL2023, no Docker — chaos N=5000 = 0/0 at 0.00% idle CPU on both, throughput ~52-60 msg/s/sub fork-bound on 2 vCPU, subscriber ceiling ~150-175 on the 0.5 GB box; see `docs/evidence/R3-aws-graviton.md`. Graviton ≠ a Pi — its cores are faster, so those throughputs upper-bound a Pi while the RAM-bound ceiling transfers directly.)* **Lead with the hard thing:** run the deadline chaos test live — a tight loop firing publishes into the exact window between deadline-computation and the blocking wait; a counter prints `missed=0 dup=0` after 5000 trials while `top` shows ~0% CPU. Then `shellmux pub control --delay 5 'reboot-now'`; with `top` at 0% the whole 5 s, it lands on the second. **Then the backpressure path, honestly:** three subscribers on `sensors`, one deliberately wedged (`socat … | (read x; sleep 999)`); flood it. The two healthy subscribers stay real-time, `cat drops_<wedged>` ticks up, **and a live `watch 'ps --ppid $PUB | wc -l'` stays flat** — proving background writers do NOT accumulate (the bug the old `> $f &` pattern would show). `kill -9` the wedged one: `ls sub_*.fifo` shows it gone, publisher never hiccups. Close with `wc -l shellmux` — one screen.

## Risks & Honest Limitations

- **Backpressure is lossy and the mechanism is imperfect.** The ring drains best-effort; under the `timeout`-write fallback, fork cost is O(subs×msgs) and torn frames are possible — caught by length-prefix short-read discard. We never claim lossless or "impossible" for backpressure.
- **Timer resolution is ~1s** on dash/bash3 (and honker itself uses `from_secs`); sub-second only on bash≥4. Worst-case wake latency = `idle_poll` because the wake-FIFO poke is best-effort. Stated, not hidden.
- **Wake-FIFO lifecycle.** Single shared FIFO; the scheduler holds it open with `exec 4>` to avoid reader-absence blocking; pokes are 1-byte (< PIPE_BUF, atomic); a poke when not reading is harmless because the poll fallback rescans. Concurrent pokes coalesce — correctness independent of how many land.
- **Deferred crash recovery.** Files survive a crash; on restart the scheduler re-arms from `deferred/`. A crash *after* `mv`-into-fan-out but *before* delivery re-delivers at most once — we document at-most-once-modulo-crash, not honker's full `claim_expires_at` (explicitly punted).
- **Topic/deferred GC.** A reaper rmdir's empty topic dirs and sweeps orphaned deferred files older than a TTL; without it they accumulate.
- **Publisher is single-threaded.** A fast publisher to many subscribers serializes N writes/message and is bounded by the *sum* of writes — a slow subscriber can't stall it (bounded writes) but fan-out fan-out cost is real. Stated.
- **Dependency set is bash≥4 + coreutils (mkfifo, timeout) + util-linux (flock) + socat** — not "coreutils + socat." `ls`/`lsof` auditability survives; the zero-deps claim does not.

## Why Linus Respects It

It leads with the one hard thing and *proves* it: a race-free, data-derived deadline scheduler whose correctness is the absence of a bug class, demonstrated by a test that fires publishes into the exact race window thousands of times with zero misses. It does not pretend the easy parts are achievements — isolation and forget-on-death are "free from fork," said plainly. It fixes its own dishonesty: the backpressure write is re-spec'd as a real bounded ring (terminalphone's `> $f &` is named as the *bug*, not cited as the fix), the honker prune/death-guard mapping is corrected, the timer resolution and dependency set are the true ones, and "make the bad state impossible" is claimed *only* for the stranded-FIFO case where a write to a vanished pipe is genuinely a harmless ENOENT. Every cited line says what we claim it says. It is a small thing, correct, and honestly bounded — and it runs on hardware cheaper than lunch.
