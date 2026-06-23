# shellmux — Design

This is the "how it works" companion to `spec.md` (which holds the "what/why"). Where they appear
to differ, `spec.md` wins. Source citations below were verified against the cloned trees under
`/Users/bobbyrathore/Documents/WildProjects/cool-oss-projects/{terminalphone,honker}`.

## Vision

A broker is correct fan-out plus correct timing. shellmux delivers both from the smallest possible
substrate: `socat`-fork for connection acceptance and isolation, one FIFO per subscriber for the
mailbox, the filesystem for all shared state, and `flock` only for the few genuinely shared
counters. The architecture is deliberately auditable: you can watch the entire broker with `ls`,
`cat`, and `ps`. The single component that is *engineering* rather than plumbing is the deadline
scheduler; the rest of the design exists to keep that component honest and small.

## Components and responsibilities

**Acceptor.** `socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'bash handler.sh $DIR'`, plus a parallel
`UNIX-LISTEN`. `fork` hands each connection a fresh process with the socket on stdin/stdout; the
kernel provides per-client isolation and crash cleanup for free. The handler's `$$` is the
subscriber's stable id. Shape borrowed from `terminalphone.sh:1206`/`:1350` (terminalphone uses a
`SYSTEM:` target; we use `EXEC:` + `,fork` — same fork-per-connection model).

**Per-subscriber mailbox FIFO.** The handler runs `mkfifo $DIR/topics/$T/sub_$$.fifo`, registers
`trap 'rm -f $INFIFO' EXIT`, starts a bounded ring drainer reading the FIFO, and holds it open with
`exec 3>$INFIFO` so the reader never sees a spurious EOF when publishers come and go. Structure
borrowed from `terminalphone.sh:1518-1546` (mkfifo, the `while IFS= read -r` drainer, the `exec 3>`
keepalive). Note: terminalphone unlinks at *script end* (`:1590`); we harden this into an `EXIT`
trap so cleanup also fires on signal/crash. This is borrowed-in-spirit, not a literal trap line.

**Bounded ring drainer (the backpressure unit).** The drainer is the *only* writer to the client
socket. Publishers never touch the socket; they write the subscriber's FIFO. The drainer reads
frames into a fixed last-N ring and writes the socket, dropping oldest on overflow and incrementing
`drops_$pid`. This is the corrected backpressure design: exactly one long-lived drainer per
subscriber, so background writers cannot accumulate. (A fallback, `timeout 0.05 dd of=$f`, exists
but pays O(subs×msgs) fork cost and can tear a frame — handled by length-prefix framing.)

**Publisher fan-out.** Per record: `for f in topics/$T/sub_*.fifo; do [ "$f" = "$INFIFO" ] &&
continue; [ -p "$f" ] || continue; <bounded-write>; done`. Shape borrowed from
`terminalphone.sh:1567-1572`. Critically, terminalphone's actual write at `:1570` is
`printf '%s\n' "$line" > "$f" 2>/dev/null &` — a *blocking* write backgrounded with `&`. Under a
flood to a wedged subscriber this spawns one stuck process per message: an unbounded fd/process
leak, the *opposite* of isolation. We name that as the bug and replace it with the ring drainer; we
do not cite it as the backpressure mechanism.

**Deadline scheduler (the contribution).** Detailed below.

**Shared state under flock.** `( flock 9; … ) 9>$DIR/.lock` guards counters only. Topics are
subdirs created with `mkdir -p` (atomic). Subscriber liveness *is* the existence of `sub_*.fifo`.
flock pattern from `terminalphone.sh:1585-1590`.

**Cleanup.** Broker shutdown `kill`s socat and `pkill -P $socat_pid` reaps the forked handlers
(`terminalphone.sh:1674-1676`); each handler's `EXIT` trap unlinks its FIFO; subscribers get EOF and
reconnect — fail-loud, never a silent hang.

## The deadline scheduler — mechanism

State lives entirely on disk as `topics/$T/deferred/<run_at>.<seq>` files. The scheduler loop:

1. Compute `next = MIN(run_at)` by sorting filenames. This is the shell re-expression of honker's
   `queue_next_claim_at` — `SELECT COALESCE(MIN(deadline),0)` over pending `run_at`
   (`honker/honker-core/src/honker_ops.rs:536-558`).
2. Block on `read -t $((min(idle_poll, next-now)))` against a long-lived wake-FIFO held open with
   `exec 4>`. This mirrors honker's `recv_until` (`honker-rs/src/lib.rs:828` call, `:1558-1582`
   impl), which does `recv_timeout(Duration::from_secs(unix_sec-now))` then drains. honker's use of
   `from_secs` (`:1572`) — whole-second resolution — is why our ~1s floor on bash3/dash is faithful,
   not a degradation.
3. On any wake (poke or timeout), **re-scan `deferred/` from scratch**, `mv` each now-due file into
   the fan-out path, recompute `next`, re-block.

A delayed publish stages its file **first**, then pokes the wake-FIFO (a 1-byte write, < `PIPE_BUF`,
atomic; concurrent pokes coalesce harmlessly). This stage-then-poke ordering is the direct analog of
honker's recv-then-drain rule, whose comment states the failure of the reverse order outright:
*"recv first, then drain — the opposite order would lose a wakeup when a publish lands between
refill() and drain"* (`honker-rs/src/lib.rs:1105-1106`).

The correctness argument has three layers, in priority order:

- **Durability:** the file exists before any wake is sent, so a wake lost in transit cannot lose the
  message — the next scan finds the file.
- **Idempotent rescan:** every wake means only "go re-read the directory." A dropped or spurious
  wake costs one directory scan, never a missed or duplicate fire.
- **Poll fallback as the correctness floor:** `read -t` always carries a finite timeout
  `= min(idle_poll, next-now)`. Even if *every* wake were lost, the next poll rescans and fires.
  Therefore the wake-FIFO is a *latency* optimization, not a correctness dependency. Worst-case
  latency is `idle_poll`; we claim exactly that and no more.

Fire-once is the property of a single commit point: the `mv` of the deferred file into fan-out.
Before `mv`, the file is a pending deadline; after `mv`, it is consumed and gone. A crash *after*
`mv` but *before* delivery re-delivers at most once on restart — documented as
at-most-once-modulo-crash; we explicitly punt honker's full `claim_expires_at` lease machinery.

## Control / data flow

`SUB`: client connects → socat forks handler with socket on stdin/stdout → handler reads one
control line `SUB <topic>`, `mkdir -p topics/<topic>`, `mkfifo sub_$$.fifo`, sets the `EXIT` trap,
starts the drainer, `exec 3>`. `PUB`: publisher sends `PUB <topic>` then streams length-prefixed
records (`<decimal-len>\n<bytes>`); the broker parses only the control line, never the payload.
Fan-out iterates `sub_*.fifo`, skips self and non-pipes, bounded-writes each, increments `drops_`
on overflow. `--at <epoch>` / `--delay <s>` writes `deferred/<epoch>.<seq>` then pokes the wake.
The scheduler fires due files into the same fan-out path. Subscriber death → `EXIT` trap unlink →
next scan never sees it. Broker death → `pkill -P` → all traps fire.

## Key design decisions and tradeoffs

(spec.md carries the full treatment; the load-bearing few:)

- **Fork-per-connection + private FIFO:** isolation/crash-safety free from the kernel; the real
  ceiling is fd/process limits — measured on the Pi, not rounded to "hundreds."
- **Backpressure = bounded ring with visible `drops_$pid`:** lossy under sustained overload for that
  *one* subscriber only, never silent. No at-least-once in the MVP.
- **Data-derived wakeup:** zero idle CPU; ~1s resolution on dash/bash3, sub-100ms only on bash≥4
  fractional `read -t`; worst-case latency = `idle_poll`.
- **Length-prefixed framing:** recovers from torn writes; mandatory if the timeout-write fallback
  ships (red-team verdict).
- **State is the filesystem; no auth, no admin protocol:** composes with every UNIX tool; any local
  process or LAN peer can `PUB`/`SUB`/enumerate — fine air-gapped, lock down with UNIX-socket perms
  or `socat OPENSSL`.

## How the borrowed techniques are adapted

honker contributes the *discipline*, not code: durable-on-disk state, min-deadline scan,
stage-then-poke ordering, and the leaf-prune vs central-death-guard distinction. We port the
SQLite/Rust mechanics to FIFOs/`read -t` and filenames — no SQLite, no WAL, no Rust. terminalphone
contributes the *relay shape* (socat-fork acceptor, per-client FIFO, drainer, keepalive `exec`,
`[ -p ]` fan-out, flock'd stats, `pkill -P` cleanup) reused as cited — minus its one fatal pattern,
the `> $f &` backgrounded blocking write, which we replace with the ring drainer.
