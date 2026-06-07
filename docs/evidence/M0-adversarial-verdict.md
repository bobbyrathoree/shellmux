# M0 — Adversarial verification verdict

Per PROMPT.md §3 and §7.2, the M0 proof must **survive an adversarial-verification workflow**
before it is trusted. Four independent skeptic agents were each told to *refute* the
0-missed/0-duplicate-over-5000 claim via a distinct lens, with full read access to the code, the
honker source, and the ability to run the harness themselves. Run ID `wf_f9f50b67-d54`,
2026-06-06.

## Result: 4 / 4 lenses HOLDS (high confidence). No lens refuted the claim.

| Lens | Verdict | Confidence | What it attacked |
|---|---|---|---|
| Correctness of race injection + scheduler logic | **HOLDS** | high | Does the hook truly freeze in the `[MIN, read]` window? Is "fired within grace" a sound miss-proxy? Is `mv` really fire-once? |
| Negative-control integrity | **HOLDS** | high | Is each control exactly one knob? Do they fail for the right reason? Can a *different* broken scheduler pass clean (false negative)? |
| Fidelity to honker + honest citations | **HOLDS** | high | Do the cited honker lines say what we claim? Is the shell analog faithful? Is the ~1s-resolution defense honest? |
| Measurement & environment validity | **HOLDS** | high | Is 0.00% real or a measurement artifact? Does grace=1000ms hide Pi-relevant latency? Is the lockstep deterministic? Is the ms math correct? |

Notable skeptic confirmations (their words, paraphrased):
- "Harness cannot be fooled: a scheduler that never fires will fail (R_MISSED=N), not pass."
- "nocommit duplicates match re-fire-every-scan exactly: 1770 dup over 60 trials = sum(1..60) − 60." (verified arithmetic signature)
- "Each negative control violates EXACTLY ONE discipline point."
- "Hook freezes at the precise window between MIN(run_at) and read -t entry."

## Two recurring concerns, independently settled by the implementer

The skeptics flagged two questions worth a direct probe rather than acceptance. Both were answered:

### 1. Could idle CPU "0.00%" mask a busy-spin? — NO.
Independent check of the scheduler's kernel state while idle:
```
$ ps -o pid=,stat=,wchan=,pcpu= -p <sched>
   10 S    do_select    0.0
$ # cpu ticks (utime+stime) over a 3s idle sample:
  cpu ticks over 3s idle: 0   (0 == genuinely blocked, not spinning)
```
The process is in state `S` (interruptible sleep) parked in `do_select` — the kernel `select()`
that backs `read -t`. Zero scheduler ticks accrue over the sample. The 0.00% is a real blocking
syscall, not a measurement artifact.

### 2. Does a *tight* grace still pass, or is 1000ms hiding poll-floor fires? — TIGHT GRACE PASSES.
Re-ran the correct-variant gate with grace tightened 1000ms → **50ms**:
```
[1/5] CORRECT variant (N=300, idle=10000ms, grace=50ms)
      -> missed=0 dup=0 ontime=300
      PASS
```
Fires land within 50ms of the deadline — they are **wake-driven (ms-latency)**, not poll-floor
fires (which would arrive ~10s late and fail even the 1000ms grace). The generous default grace is
not hiding anything; it is slack for slower hardware, and the proof holds far inside it.

## Honest limitations the skeptics surfaced (documented, not blockers)
- **Hardware generalization.** The proof ran in a Linux aarch64 container, not on the $5 Raspberry
  Pi demo target. Absolute latency will be larger on the Pi; the *correctness* property (poll-floor
  fallback ⇒ no permanent loss) is hardware-independent, but the ms-latency numbers must be
  re-measured on the Pi at M5 before being quoted. → tracked for M5.
- **Resolution claim.** shellmux actually runs at ms resolution here (bash 5 `read -t`); the "~1s,
  faithful to honker's `from_secs`" framing is the *floor* on bash3/dash, and is honest as a floor.
  Could be stated more crisply in docs (already noted in HANDOFF Decisions).
- **Crash mid-`mv`.** Fire-once is the property of the `mv`; a crash strictly between `mv` and
  delivery re-delivers at most once on restart — this is the documented at-most-once-modulo-crash,
  and is exactly what M1's crash-recovery test will exercise.

## Conclusion
The single falsifiable claim — 0 missed / 0 duplicate over N=5000 adversarial in-window trials at
~0% idle CPU — **survives adversarial verification**. M0 is genuinely proven, not merely green.
