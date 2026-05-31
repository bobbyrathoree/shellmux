# shellmux — Implementation Plan

Source of truth is `spec.md`. This plan folds in `_partner-plan.md` (its milestone naming and "keep
the pitch on deadlines" risk call are kept; its terser claims are superseded by the hardened spec).

## Stack & dependencies

bash ≥ 4, `socat`, `flock` (util-linux), `timeout` + `mkfifo` + `dd` (coreutils), `lsof`/`ps` for
tests. Develop and measure **in the Linux container** (`Dockerfile`), never on bare macOS bash 3.2.
Reuse terminalphone's socat/FIFO/cleanup shape and honker's deadline discipline; write the scheduler
and bounded subscriber path fresh.

## Architecture units (build targets)

- `src/sched.sh` — deferred files, min-deadline scan, wake-FIFO, idle-poll fallback. (M0/M1)
- `src/shellmux` — the single ~150-line broker: acceptor, SUB/PUB parser, handler, fan-out, drainer.
- `tests/chaos_deadline.sh` — the proof harness + its must-fail negative control.
- `tests/flood_wedged.sh` — wedged-subscriber backpressure test.
- `tests/crash_recovery.sh` — deferred-file survival across broker kill/restart.

## Milestone sequence (riskiest first)

**M0 — Deadline chaos proof (THE milestone; do this before any broker code).**
*Deliverable:* `src/sched.sh` standalone + `tests/chaos_deadline.sh`. The scheduler obeys the
six-point discipline in `CLAUDE.md`/`design.md` (disk state, MIN scan, `read -t` on wake-FIFO held
by `exec 4>`, stage-then-poke, full rescan on every wake, `mv` as the single commit point).
*Verified by:* the harness instruments a test hook that pauses the loop between `next=MIN(...)` and
`read -t`, fires a publish whose `run_at` is *now* into that pause, releases, and checks the fire.
Run N ≥ 5000 with jittered pause widths. **Pass = `missed=0 dup=0` over N ≥ 5000** AND an idle-CPU
sample (`top`/`ps`) reads ~0%. Any miss/dup = fail.
*Effort:* ~1 day (most of the project's real risk lives here).

**M1 — File-backed deferred scheduler hardened.** *Deliverable:* crash-safe re-arm — on startup the
scheduler rebuilds `next` purely from existing `deferred/` files. *Verified by:* a unit that stages
files, kills `sched.sh`, restarts, asserts all fire (at most one duplicate per file crashed
mid-`mv`, matching the documented at-most-once-modulo-crash). *Effort:* ~0.5 day.

**M2 — Acceptor + SUB handler + per-subscriber FIFO.** *Deliverable:* `socat ... fork EXEC:handler`
over UNIX + TCP; handler does `mkfifo sub_$$.fifo`, `EXIT` trap, `exec 3>`, drainer start.
*Verified by:* a subscriber connects, `ls topics/$T/sub_*.fifo` shows its FIFO; disconnect → FIFO
gone. *Effort:* ~0.5 day.

**M3 — Length-prefixed fan-out + bounded ring drainer + drop counter.** *Deliverable:* publishers
write FIFOs (never the socket); the drainer owns the last-N ring and writes the socket, bumping
`drops_$pid` on overflow. *Verified by:* the flood test below. *Effort:* ~1 day (the partner plan's
risk: this can balloon past the broker in size — keep it lean).

**M4 — Death cleanup + introspection.** *Deliverable:* `EXIT`-trap unlink + `[ -p ]` skip;
`pkill -P` broker shutdown; all state readable via `ls`/`cat`. *Verified by:* `kill -9` a wedged sub
mid-flood; `ls sub_*.fifo` shows it gone; publisher never hiccups. *Effort:* ~0.5 day.

**M5 — Pi demo + benchmarks.** *Deliverable:* the live demo script; throughput and fd/process counts
measured on a real Raspberry Pi. *Verified by:* recorded numbers on the slide (low-thousands small
msgs/sec; flat process count under flood). *Effort:* ~0.5 day.

## The differential / adversarial test (and its must-fail negative control)

The chaos harness is only a proof if it can fail a wrong implementation. `tests/chaos_deadline.sh`
runs **two** scheduler variants against the same injected race:

- **Correct variant** (`src/sched.sh`): stage-then-poke, full rescan on every wake, poll fallback.
  Assertion: `missed=0 dup=0` over N ≥ 5000. Test FAILS if any miss/dup.
- **Negative control** (a deliberately broken variant, e.g. `sched_broken_pokefirst.sh` that pokes
  *before* staging, OR `sched_broken_norescan.sh` that sleeps `next-now` without rescanning on
  wake): the harness asserts the broken variant **DOES** produce `missed>0` (or `dup>0`). If the
  broken variant passes clean, the harness itself is not exercising the race — that is a test bug,
  and the whole proof is void.

This guards against the most embarrassing failure mode: a green chaos test that would stay green even
against an obviously incorrect scheduler. The negative control is mandatory, not optional.

Two supporting tests: `tests/flood_wedged.sh` (three subs, one wedged via
`socat … | (read x; sleep 999)`; flood it; assert healthy subs stay real-time, `drops_<wedged>`
rises, and `ps --ppid $PUB | wc -l` stays **flat** over time — the direct refutation of the
`> $f &` leak). `tests/crash_recovery.sh` (M1's restart check).

## Effort estimate

~2–3 days total (matches the partner plan). M0+M1 (the provable core) is ~1.5 days; the broker and
backpressure path are ~2 days; demo/benchmarks ~0.5 day. M0 is the only milestone that can sink the
project, so it is funded first.

## Biggest delivery risk

Per the partner plan: **the backpressure implementation becomes more code than the broker.** The
ring drainer is fiddly in shell and tempting to over-engineer. Mitigation: keep the correctness
pitch entirely on the deadline scheduler; ship the simplest ring that keeps `ps` flat and accept the
documented lossiness. If the ring can't be made genuinely one-long-lived-process-per-subscriber, cut
the backpressure claim rather than fake it (red-team patch #5). Secondary risk: a judge runs it on
macOS bash 3 / dash and sees ~1s resolution — pre-empt with the platform matrix and the
`from_secs` citation.
