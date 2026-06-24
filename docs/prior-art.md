# shellmux — Prior Art & How We Differ

This is the document that keeps the project honest in front of a hostile reviewer. Every prior-art
claim names a concrete project, paper, or OS feature, states precisely how shellmux differs, and the
final section lists the "this is just X" dismissals that must be pre-empted.

## Concrete prior art

### The deadline-scheduler discipline (borrowed, not invented)

The scheduler we re-express in shell is the discipline of a durable-deadline job scheduler — a
SQLite-backed job queue. We did not invent it; we ported it.

- **Next-deadline query.** The reference job queue's next-deadline query does a
  `SELECT MIN(deadline)` over pending `run_at` and processing `claim_expires_at`. We re-express that
  `MIN` over `deferred/<run_at>.<seq>` filenames — no SQLite, no WAL, no Rust.
- **Block-until-deadline.** Its receive path blocks until the next deadline with a
  `recv_timeout(Duration::from_secs(unix_sec - now))`, then drains. We use `read -t $((min(idle,
  next-now)))` on a wake-FIFO. **The reference uses whole-second `from_secs` resolution — so our ~1s
  floor is faithful, not a degradation.**
- **Ordering rule.** A comment in that reference states the rule outright — *"recv first, then drain
  — the opposite order would lose a wakeup when a publish lands between refill() and drain"* — which
  we adopt as "stage the file, **then** poke the wake-FIFO."
- **Prune vs death-guard (we fix the draft's swap).** The reference's opportunistic leaf prune (a
  `retain(... Disconnected => false)` over the subscriber list) maps to our subscriber `EXIT`-trap
  unlink + `[ -p ]` skip. Its death-guard — which clears *all* senders when the **central** watcher
  dies — maps to our **broker** shutdown (`pkill -P`), not a single subscriber dying. We state the
  mapping correctly.

*How we differ:* we drop persistence, WAL, leases (`claim_expires_at`), and the SQLite engine
entirely; we keep only the deadline-firing discipline, ported to a substrate with no threads, no
atomics, and only advisory locks. That port — proving the discipline survives in shell — is the work.

### The socat-fork relay shape (borrowed)

The relay shape comes from a socat-fork terminal relay — a terminal-sharing tool built on
socat-fork + FIFOs.

- Reused from the reference relay: the socat-fork acceptor, per-client FIFO, drainer, keepalive
  `exec 3>`, `[ -p ]`-guarded fan-out, flock'd stats, `kill`+`pkill -P` cleanup, and persistent fd
  binding.
- **What is NOT there / what we replace:** non-blocking writes. The relay's fan-out line is
  `printf '%s\n' "$line" > "$f" 2>/dev/null &` — a *blocking* write backgrounded with `&`. Under a
  flood to a wedged subscriber it leaks one stuck process per message. We name it as the bug and
  replace it with a bounded ring drainer; we never cite it as the backpressure fix.

*How we differ:* the reference relay has no topics, no timed delivery, and the leaky write path.
shellmux adds topic subdirs, the deadline scheduler, and a corrected single-drainer backpressure
unit. The relay unlinks at handler end; we harden that into an `EXIT` trap.

### Mosquitto / NATS / Redis Pub-Sub / ZeroMQ

kLOC–MLOC daemons with wire protocols, config languages, persistence, and clustering.
*How we differ:* we do not compete on throughput, durability, QoS, or HA. We compete only on
auditability (the whole broker is `ls`/`cat`/`ps`-inspectable) and a tiny dependency set. We claim a
*small* correct thing, not a faster broker.

### inetd / xinetd / systemd socket activation

The same fork-per-connection model socat hands us.
*How we differ:* they are transport, not a broker — no topics, no fan-out, no timed delivery. We
build the broker semantics on top of that model.

### OS timer facilities (`at`, cron, `timerfd`, `sleep`, timer wheels)

The classic ways to fire something later.
*How we differ:* `at`/cron are minute/second-granular external daemons with their own spool, not an
in-process race-free wake; a naive `sleep $((next-now))` is exactly the bug we refute (it sleeps
through a publish landing in the compute window). `timerfd`/timer wheels need a language with the
syscall and event loop we don't have. Our contribution is achieving the *correctness* of a
data-derived wake in shell, with the poll fallback as the floor, proven by the chaos test.

## Dangerous "this is just X" dismissals (pre-empt these)

- **"It's just `tee` to a bunch of FIFOs / a shell pub/sub stunt."** Fan-out *is* trivial and we say
  so. The non-trivial part a `tee`-one-liner cannot do is race-free timed delivery with zero
  busy-spin. That, and only that, is the claim — proven by 5000 adversarial-timing trials with a
  must-fail negative control.
- **"Just run Mosquitto / NATS."** Correct for clustered/persistent/high-throughput needs. shellmux
  targets air-gapped / homelab / $5-Pi deployments where a kLOC daemon is the wrong dependency and
  auditability matters more than throughput.
- **"`sleep $((next-now))` already does this."** No — that is the exact bug class. A publish landing
  between deadline computation and the sleep is slept through. Our discipline (durable file,
  stage-then-poke, rescan-on-wake, poll floor) makes the miss structurally absent; the negative
  control variant *demonstrates* the naive version failing.
- **"It's POSIX `sh`, so it'll run anywhere."** False, and the red-team flags it: it needs bash ≥ 4
  features, `flock`, `timeout`, `socat`, and (for sub-second timers) fractional `read -t`. We state
  the real dep set and the platform matrix (bash 4 fractional timers vs whole-second on bash3/dash)
  up front. Do not let a judge discover this on macOS bash 3.2.
- **"Content-blind = secure / private."** No. The host sees every byte; content-blind is a
  simplicity note, not E2EE. Use `socat OPENSSL` or SSH for transport security.
- **"Backpressure is lossless / makes the bad state impossible."** No. The ring is lossy and
  best-effort; we expose it via `drops_$pid`. "Make the bad state impossible" is claimed **only** for
  the stranded-FIFO case (a write to a vanished pipe is a harmless ENOENT/ENXIO). If the ring cannot
  be a true single-long-lived-process-per-subscriber, the red-team verdict says cut the claim — so
  we will.

## Red-team verdict (folded)

Verdict: *survives as a small correctness demo; do not sell it as a serious broker.* Adopted
patches: (1) put the deadline chaos test first in the README and demo; (2) replace "zero idle CPU"
with "blocks between computed deadlines; worst-case latency is `idle_poll`"; (3) ship a platform
matrix (bash 4 fractional vs whole-second timers); (4) make length-prefixed framing mandatory if the
timeout-write fallback ships; (5) if the bounded ring drainer is not actually one long-lived process
per subscriber, cut the backpressure claim. The verdict's own source checks — the next-deadline
query, the prune-and-death-guard pair from the job scheduler, and the acceptor / FIFO / cleanup /
fd-binding shapes from the relay — were re-verified against the reference implementations.

## The single sharpest dismissal we must survive

> **"A correct timer is just `sleep $((deadline-now))`; the rest is `tee` to FIFOs — this is a
> first-year shell exercise dressed up as a contribution."**

The whole project is the rebuttal: that naive sleep loses any publish landing in the
compute-before-sleep window, and shellmux's structural discipline plus the 5000-trial chaos test
*with a must-fail negative control* is the proof that ours does not.
