# HANDOFF — shellmux
Last updated: 2026-06-06 22:37 PDT   |   Last commit: (M0 commit, see git log)   |   Current milestone: **M0 PASSED** → next is M1

## If you are a new agent, START HERE
M0 — the riskiest experiment, the project's whole reason to exist — is **GREEN**.
`tests/chaos_deadline.sh` fires **0 missed / 0 duplicate over N=5000** adversarial-timing trials
(publish injected into the exact `[next=MIN → blocking read]` window every trial), at **0.00% idle
CPU**, and all **three must-fail negative controls fail on their predicted axis**. Evidence:
`docs/evidence/M0-chaos-run.txt`. To reproduce: build the container (`docker build -t shellmux-dev .`)
then `docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/chaos_deadline.sh`
(~2m45s for N=5000; use `-e N_MAIN=200 -e N_NEG=40 -e N_DUP=20` for a ~15s smoke).
Next task: **M1** (crash-safe re-arm of the deferred scheduler) per `docs/plan.md`, then M2 (acceptor).

## Done (with commit shas)
- Repo scaffolded (commit aeb9198 + e871e52 + e602872).
- **M0 — deadline chaos proof: PASS.** (this session's M0 commit)
  - `src/sched.sh` — the scheduler (136 lines), six-point discipline realized.
  - `tests/chaos_deadline.sh` — proof harness, deterministic in-window race injection via lockstep hook.
  - `tests/negative/sched_{naivesleep,drainfirst,nocommit}.sh` — three must-fail controls, each
    EXACTLY one discipline violation (diff-able to one knob).
  - `tests/smoke.sh` — fast tracer-bullet smoke (T1 due-now fires, T2 fires near deadline, T3 fire-once).
  - `docs/evidence/M0-chaos-run.txt` — the canonical N=5000 run output.

## In progress (exact state)
- Nothing mid-edit. M0 is closed and verified; tree is buildable & green.

## Adversarial verification — DONE (PROMPT §3/§7.2): claim SURVIVES
- 4 skeptic lenses (correctness, negative-control, prior-art-fidelity, measurement-validity) each
  told to *refute* the 0/0 claim → **4/4 returned HOLDS at high confidence; none refuted.**
- Two recurring "major" concerns probed independently and settled (docs/evidence/M0-adversarial-verdict.md):
  (1) 0.00% idle CPU is real — scheduler sits in kernel `do_select` (state S), 0 ticks over 3s.
  (2) tightening grace 1000ms→50ms still passes missed=0 → fires are wake-driven (ms), not poll-floor.
- Limitations the skeptics surfaced, to carry forward (not blockers): re-measure latency on the Pi
  at M5; crash-mid-`mv` at-most-once is M1's job to test; ms-vs-~1s resolution wording could be crisper.

## Next (ordered)
1. **M1** — crash-safe re-arm: on startup the scheduler rebuilds `next` purely from existing
   `deferred/` files. Test: stage files, kill sched.sh, restart, assert all fire (≤1 dup per file
   crashed mid-`mv`, matching documented at-most-once-modulo-crash). `tests/crash_recovery.sh`.
3. **M2** — socat-fork acceptor + SUB handler + per-subscriber FIFO (UNIX + TCP).
4. **M3** — length-prefixed fan-out + bounded ring drainer + drops_$pid.
5. **M4** — death cleanup (`EXIT` trap unlink, `[ -p ]` skip, `pkill -P`) + introspection.
6. **M5** — Pi demo + benchmarks.

## Decisions & rationale (so nobody relitigates them)
- **Wake reader uses `read -N 1`, NOT line mode.** A poke is a single newline-less byte; a
  line-oriented `read` consumes it but blocks forever waiting for a `\n` that never comes (and the
  rw-held fd never EOFs). Caught in the primitive smoke test before writing the scheduler. This is
  load-bearing — line-mode would silently break every wake.
- **`trap 'exit 0'`, NOT `trap 'running=0'`.** bash *retries* an interrupted `read` after a
  non-exiting trap, so a signal landing while blocked in `read -N 1` never breaks the loop and
  `wait` hangs. Verified both the bug and the fix with a minimal repro. `exit 0` terminates
  immediately regardless of where blocked; the `running` flag still handles graceful EOF stop.
- **Time in milliseconds, fork-free via `$EPOCHREALTIME` + `$REPLY` convention.** The loop runs hot
  under the harness; `$(date)` per call would fork N times. `now_ms` sets `$REPLY` (no subshell).
  Falls back to `date +%s%3N` on bash<5. Deferred files are `deferred/<run_at_ms>.<seq>`.
  Resolution is ms here; the ~1s floor claim is for bash3/dash and remains honest (honker uses
  `from_secs`). Files sort lexically == numerically only while epoch-ms stays 13 digits — true until
  year 2286, fine.
- **Deterministic in-window injection beats probabilistic.** The chaos hook freezes the loop in the
  EXACT `[MIN, read]` window and the harness stages+pokes while frozen, so the race lands inside the
  window on 100% of trials — strictly more adversarial than random timing hoping to hit it.
- **Two independent failure axes:** `missed` (per-trial: fired within `grace` ms of deadline?) and
  `dup` (final: any id fired ≥2×?). With idle=10000ms ≫ grace=1000ms, a lost-wake fire only happens
  at the 10s poll floor → unambiguously scored missed. Correct→both 0; naive/drainfirst→missed;
  nocommit→dup.
- **Negative controls are separate files, each one-knob from src/sched.sh** (diffable), kept in
  `tests/negative/`. A reviewer can `diff src/sched.sh tests/negative/<x>.sh` and see the single
  violated discipline point. This is the must-fail-control discipline made auditable.
- **Container is the only dev/test surface.** Host is darwin/arm64 bash 3.2 (no fractional read -t,
  no flock/socat). All runs are `docker run ... shellmux-dev`.

## Dead ends (don't retry — and why)
- `pid="$(start_sched)"` where the backgrounded sched inherits the command-substitution stdout pipe
  → `$(...)` hangs forever waiting for EOF on a pipe the long-lived child holds open. Fix: redirect
  the scheduler's stdout/stderr to a log file so only `echo $!` flows through the capture pipe.
- `trap 'running=0'` to stop the loop on signal — does NOT work (read-retry, see Decisions).
- `while read -N1 -t 0` to drain a FIFO — `read -t 0` is a *non-consuming availability probe*, so
  it spins forever. Use a tiny positive timeout (`-t 0.001`) to actually consume.

## Open questions / assumptions made
- Idle-CPU measured via `/proc/<pid>/stat` utime+stime delta over 5s == 0 ticks → 0.00%. Sound on
  Linux; the adversarial workflow is double-checking the measurement isn't masking a busy-spin.
- Container arch under Docker Desktop on arm64 mac: assumed arm64 (native), confirm in workflow.
  Pi-target latency is the place grace=1000ms could be hiding real slowness — to validate at M5.

## How to resume
- `cat HANDOFF.md && git log --oneline -20 && git status`
- Build: `docker build -t shellmux-dev .`
- M0 gate: `docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/chaos_deadline.sh`
- Fast smoke: `docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/smoke.sh`
- Fast chaos: add `-e N_MAIN=200 -e N_NEG=40 -e N_DUP=20` to the chaos run.
