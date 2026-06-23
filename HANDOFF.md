# HANDOFF — shellmux
Last updated: 2026-06-22 (R2 session)   |   Branch: master (clean)   |   **STATUS: COMPLETE — all 5 DoD items met; evaluator loop CONVERGED over two rounds**

## If you are a new agent, START HERE
**The build is done and green, M0 through M5, the product-phase evaluator loop has run TWICE, and
DoD #5 (convergence) is now MET — not parked.** The single falsifiable claim is PROVEN and
ADVERSARIALLY RE-CONFIRMED (three independent ways this session): `tests/chaos_deadline.sh` fires
**0 missed / 0 duplicate over N=5000** adversarial-timing trials (publish injected into the exact
`[next=MIN → blocking read]` window every trial), at **0.00% idle CPU**, with three must-fail negative
controls. Around it: M1 crash recovery, M2 socat-fork acceptor + per-sub FIFO + forget-on-death
(UNIX+TCP), M3 bounded fan-out drainer (`ps` flat vs leaky control), M3b deferred `--at`/`--delay`
firing through the scheduler, M4 GC reaper + ls/cat introspection, M5 demo + benchmarks. R1 added
input-boundary hardening; **R2 (this session) ran a second evaluator round, measured two-round
convergence, and landed the round-2 perimeter polish** (doc truth-up, deterministic flood test,
scriptable arg rc). Reproduce from clean:
`docker build -t shellmux-dev . && docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/run_all.sh`
(**8 suites, 8/8 green**; `-e N_MAIN=400` for a ~90s pass). Demo: `DEMO.md`. Evidence: `docs/evidence/`.
Evaluator artifacts: `eval/feedback/{raw,synthesis,analysis}/round-001*` and `round-002*`.
**ALL WORK IS ON `master`, working tree clean** (the prior HANDOFF's "unmerged branch
`chore/cleanup-and-eval-loop`" note was stale — corrected this session; everything is committed to
`master`). The ONLY remaining optional, non-blocking item is re-measuring benchmarks on a real $5 Pi
(correctness properties are hardware-independent; only the throughput ceiling needs the real box).

## Done (with commit shas)
- Repo scaffolded (commit aeb9198 + e871e52 + e602872).
- **M0 — deadline chaos proof: PASS.** (this session's M0 commit)
  - `src/sched.sh` — the scheduler (136 lines), six-point discipline realized.
  - `tests/chaos_deadline.sh` — proof harness, deterministic in-window race injection via lockstep hook.
  - `tests/negative/sched_{naivesleep,drainfirst,nocommit}.sh` — three must-fail controls, each
    EXACTLY one discipline violation (diff-able to one knob).
  - `tests/smoke.sh` — fast tracer-bullet smoke (T1 due-now fires, T2 fires near deadline, T3 fire-once).
  - `docs/evidence/M0-chaos-run.txt` — the canonical N=5000 run output.
  - `docs/evidence/M0-adversarial-verdict.md` — 4/4 skeptic lenses HOLDS + 2 confirmation probes.
- **M1 — deferred crash recovery: PASS.** (this session's M1 commit)
  - `src/sched.sh` +startup outbox-recovery sweep: a record stranded in `outbox/` (crashed after the
    `mv` commit point but before delivery+rm) is re-delivered on restart, then rm'd. Realizes
    at-most-once-modulo-crash. Deferred re-arm needed no code (scan_min reads disk every iter).
  - `tests/crash_recovery.sh` — R1 deferred re-arm across kill -9, R2 outbox recovery, R2' must-fail
    no-recover control (LOSES the file), R3 at-most-once bound (dup<=1 per crash). All green.
  - `docs/evidence/M1-crash-recovery-run.txt`. Verified NO M0 regression (chaos still 0/0).
- **M2 — acceptor + SUB handler + per-subscriber FIFO: PASS.** (this session's M2 commit)
  - `src/shellmux` (172 lines): subcommand dispatch — `serve <dir> [--unix P] [--tcp PORT]` starts
    the scheduler + a `socat ... ,fork EXEC:'bash <self> _handle <dir>'` acceptor per transport;
    `_handle` reads one control line, on `SUB <topic>` does mkdir+mkfifo sub_$$.fifo, EXIT-trap
    unlink, drainer (pumps FIFO→socket), `exec 3>` keepalive, blocks until stdin EOF. `sub`/`pub`
    client helpers connect via socat. PUB verb is a STUB until M3.
  - `tests/sub_lifecycle.sh`: S1 SUB/UNIX registers FIFO, S2 disconnect unlinks (forget-on-death),
    S3 concurrent isolation, S4 SUB/TCP, S2' must-fail no-trap control strands the FIFO. All green.
  - `docs/evidence/M2-sub-lifecycle-run.txt`. NO M0/M1 regression (smoke 3/3, crash 4/4, chaos 0/0).
- **M3 — length-prefixed fan-out + bounded drainer + drops_$pid: PASS.** (this session's M3 commit)
  - `src/shellmux` (~290 lines): PUB now delivers. `fanout()` writes each sub's FIFO with a single
    serial `timeout $wto bash -c 'printf > fifo'` (NO `&`) — kernel pipe buffer (64KiB) is the ring;
    wedged write times out → drop + flock'd `drops_<pid>`. The drainer reads length-prefixed frames
    (`<len>\n<bytes>`), validates the byte count (3-layer torn-frame defense), and does a bounded
    socket write (drops on socket-timeout, never on read-timeout). REPLACES terminalphone's
    `> $f &` leak (terminalphone.sh:1570).
  - Design chosen via a design-exploration workflow (3 candidates judged): "kernel-buffer-as-ring"
    won decisively over two explicit-ring variants (which had a re-emit-the-window bug). `cut_the_claim`
    was false — the design is genuinely one-long-lived-process-per-sub.
  - `tests/flood_wedged.sh`: F1 healthy subs get the whole flood at full speed despite a wedged peer,
    F2 drops visible, F3 publisher process count FLAT (~15), F4 framing intact; F3' must-fail leaky
    control balloons to ~1300 procs. `docs/evidence/M3-flood-wedged-run.txt`. NO M0/M1/M2 regression.
- **M3b — deferred (`--at`/`--delay`) PUB through the scheduler: PASS.** (this session's M3b commit)
  - PUB stages `deferred/<run_at_ms>.<seq>` (content `<topic>\n<payload>`) then pokes wake.fifo
    (stage-then-poke). `src/sched.sh` got a pluggable `deliver()`: default = append to fires.log
    (M0 chaos UNCHANGED), or `SCHED_FIRE_HOOK` = `shellmux _fire <file>` which fans the payload into
    the topic. `serve` exports SCHED_FIRE_HOOK + SHELLMUX_DIR. `--delay` wins over `--at` (honker
    precedence). Added `now_ms` to src/shellmux (PUB path needs it).
  - `tests/deferred_pub.sh`: D1 `--delay 1` fires AT the deadline (~40ms), D2 `--at` absolute, D3
    scheduler idle (0 CPU ticks) during the wait, D1' must-fail fire-now control
    (`tests/negative/sched_firenow.sh`, one knob = due-check removed) delivers early.
  - `docs/evidence/M3b-deferred-pub-run.txt`. **M0 chaos N=5000 STILL 0/0** after the sched change.
- **M4 — GC reaper + ls/cat introspection: PASS.** (commit 2463501)
  - `src/shellmux _reap <dir>`: removes stale `drops_<pid>` (no matching FIFO), empty topic dirs,
    orphaned deferred files older than `SHELLMUX_DEFERRED_TTL`; preserves all live state. `serve`
    runs it on a slow loop (`SHELLMUX_REAP_INTERVAL`, default 30s). `tests/introspection.sh` 7/7.
- **M5 — DEMO.md + run-all + benchmarks: PASS.** (commit 1a4e88b)
  - `DEMO.md` (the 1-page demo), `tests/run_all.sh` (all 7 suites, each with its control),
    `tests/bench.sh`. Container numbers: ~1360 msg/s 1-sub, ~480/sub 3-sub, idle 0 ticks, 20 subs =
    20 FIFOs/~110 procs. `docs/evidence/M5-bench-run.txt`.
- **DoD doc truth-up.** README rewritten from "pre-implementation" to as-built; spec.md got an
  as-built honesty note reconciling the line count (sched 167 / shellmux 374 vs the "~150" pitch =
  the scheduler) and the not-fork-free framing.
- **chore — removed 12 orphaned M3-era scratch scripts (1040 lines).** (commit d18b555)
  Root-level `measure_drainer*.sh`, `perf_*.sh`, `fork_cost_test.sh`, `tight_loop_test.sh`,
  `truly_wedged_test.sh`, `final_attribution.sh`, `shellmux_instrumented.sh` — referenced by nothing
  in tests/docs/src (the shipped benchmark is `tests/bench.sh`). Also gitignored `/.eval-scratch/`.
- **R1 — product-phase evaluator loop + input-boundary hardening: DONE.** (commits 01125e1, 04798b3)
  - Ran the product-phase loop (DoD #5): 12 persona×challenge agents that DROVE the running broker
    via Docker → aggregator → analyst. Artifacts in `eval/feedback/{raw,synthesis,analysis}/round-001`.
    Avg satisfaction 7.6/10, 12/12 completed. Flooder ran the full N=5000 gate live → 0/0 confirmed.
  - Analyst's #1 finding: the data path that DERIVES deadlines (`--at`/`--delay` + topic name) was
    unvalidated and failed silently — never exercised by the chaos harness. All 5 high-sev findings
    reproduced by hand before fixing (no hallucination): F1 (`--at xyz` crashes handler), F7 (far-future
    parks forever), H1 (`../../tmp/x` mkdir's outside state dir), F4 (`--help` set -u crash), H2
    ("content-blind" overstated vs newline-text reality).
  - Fix (`src/shellmux` +78 lines): `valid_topic` (whitelist `[A-Za-z0-9._-]+`, no leading dot) +
    `valid_deadline` (non-neg int within `SHELLMUX_MAX_DEFER_S`, default 1yr), server-side in `_handle`
    (load-bearing — raw socat bypasses client helpers) AND client-side in `sub`/`pub`; `usage()` guard.
    ALL behind `SHELLMUX_NO_VALIDATE=1` (must-fail control, one-knob auditable).
  - `tests/input_validation.sh` (V1–V5 + V4b + NC control); added to `run_all.sh` (now 8 suites).
  - Fixed `flood_wedged.sh` orphan leak (the flaky-F1 / operator cold-start-hang report): cleanup
    reaped only the broker subtree, not the script's own subscribers/wedged-socat/`sleep 300`. Now
    reaps client pids + `pkill -P $$`. 5× back-to-back all green, no orphan pileup. Broker was always
    correct (1000/1000 isolated); this was test hygiene.
  - Doc truth-up: README/DEMO honest delivery contract (newline-delimited NUL-free text, H2),
    at-most-once overdue-reboot loss named (H3), ceiling = RAM ~2.4MB/sub not fd (ceiling claim),
    `cat drops_*` healthy-topic recipe (F2), line count 374→452.
  - **NO REGRESSION:** chaos still missed=0 dup=0 ontime=5000 over N=5000; all 8 suites green. The
    fix touches only the input boundary — never `src/sched.sh` or the mv commit point.
- **R2 — second product-phase evaluator round + convergence + perimeter polish: DONE.** (this session)
  - Ran round-002: the SAME 12 persona×challenge pairs as R1 (apples-to-apples), driving the live
    broker in isolated Docker instances, re-testing every R1 finding + hunting new friction →
    aggregator (synthesis) → analyst (DoD #5 convergence call). Artifacts:
    `eval/feedback/{raw,synthesis,analysis}/round-002*`.
  - **Result: CONVERGED.** Mean satisfaction 7.58→**8.08** (+0.50); the R1 worst pair
    (scripter×malformed-frames) 4→9; **12/12 completed**. All R1 fixes (F1/F4/F7/H1 input boundary)
    re-probed by 3 personas and re-confirmed FIXED. Credible new threats to the missed=0/dup=0 axis:
    **1 (R1) → 0 (R2)**. Raw `is_new`=84% is agent self-tag inflation (6 sessions re-report the same
    one doc nit); de-duplicated credible novelty ≈16% by count, **0% on the claim axis**. DoD #5 met.
  - **Independent triangulation of the spine (3 ways this session):** (1) I re-ran the full N=5000
    gate live → 0/0; (2) an adversarial-verification subagent ran 4 attacks incl. an elapsed-
    distribution probe (8000 trials, every fire 0–5ms, never the poll floor → fires are wake-driven,
    not grace-hidden) + confirmed idle = real `do_select` kernel block (0 ticks) → NOT-REFUTED at
    high confidence; (3) the round-2 flooder ran the gate live → 0/0, scored it 9/10.
  - **Citation-fidelity audit (subagent + my own re-check):** 15/16 borrowed citations exact; the
    `:1670` bug-not-fix framing is correct (not inverted); the absent-`trap EXIT` honesty note is
    itself honest. ONE drift fixed: `pkill -P` is terminalphone.sh **:1676**, not :1674 (which is the
    adjacent `kill`); cited as `:1674-1676` now across CLAUDE.md/spec/design/prior-art/src headers.
  - **Round-2 roadmap A1–A4 landed (all off the proof axis; gated on chaos still 0/0):**
    - A1 doc truth-up: replaced the wrong "a payload is truncated at its first newline" (the broker
      LINE-SPLITS → N records, verified by 6 personas + my own re-run) with the true line-splitting
      contract; added the held-open-disconnect SILENT tail-loss caveat (N2, contradicted "never
      silent"); named the healthy-broker offline-subscriber loss next to the crash qualifier. (README, DEMO)
    - A2 made `flood_wedged.sh` F1 deterministic (N1, the one R1 regression): two test-only root
      causes fixed — (i) fixed 3s linger truncated the publisher tail under load → hold the connection
      open for the whole measurement + assert EVENTUAL COMPLETENESS (quiesce, not wall-clock);
      (ii) over-aggressive 2ms drainer timeout false-dropped HEALTHY writes under contention → 20ms
      (still 2.5× under the broker's 0.05 default; wedged path still overflows, drops ~280). Result:
      **6/6 serial + 8/8 parallel** (the contended condition that flaked ~1/3 before). Broker UNTOUCHED.
    - A3 scriptable arg rc (N4): `--help`/`-h` → rc 0 on stdout; missing-required-arg → rc 2 on stderr;
      bad subcommand → rc 1. New test `input_validation.sh` V6 pins it (now 8 cases). +6 lines (452→458).
    - A4 DEMO Beat 2 teardown line so copy-paste doesn't leak a broker/socat/sub.
  - Doc line-count reconciled to 458 across README/DEMO/spec; fixed a stale spec.md `src/shellmux`
    figure (still said 374 pre-R1) caught while truthing up.
  - **NO REGRESSION:** full `run_all.sh` 8/8 green, chaos missed=0 dup=0 ontime=5000 over N=5000.

## In progress (exact state)
- Nothing mid-edit. ALL milestones (M0–M5) closed; DoD #5 converged over two rounds; every suite
  green (8/8); docs reconciled to code; all work committed to `master` (clean tree).

## Open / optional (NOT blockers — ALL 5 Definition-of-Done items are met)
- **Evaluator loop (PROMPT §4, DoD #5): CONVERGED over two rounds — DONE, not parked.** Round-001
  surfaced the one adjacent threat (unvalidated input boundary) + a test flake; both fixed. Round-002
  re-probed and re-confirmed them fixed and found **zero new threats to the one claim** (credible
  novelty 1→0 on the claim axis; satisfaction 7.58→8.08). Round-2's roadmap (A1–A4) is landed. A
  round-003 would, by the analyst's call, mostly re-report doc-wording and re-state punts — run it
  only if iterating on ergonomics, not for correctness signal. See
  `eval/feedback/analysis/round-002.md` for the explicit convergence call.
- **Pi benchmarks (the one genuine remaining follow-up):** numbers are container-measured and labelled
  as such; re-measure on a real $5 Pi before quoting on a slide (correctness properties are
  hardware-independent; the throughput ceiling is not). DEMO states the ceiling is RAM-bound
  (~2.4MB/sub, ~100–150 on a 512MB Pi). Not a blocker for the proof or the demo.
- **Line-budget:** `src/shellmux` is now 458 lines (374 pre-R1; +78 input validation, +6 R2 arg-rc).
  Still honest in DEMO/spec ("~150" = the scheduler `src/sched.sh` at 167, the contribution; the
  broker is plumbing). Trim is optional.

## Adversarial verification — DONE (PROMPT §3/§7.2): claim SURVIVES
- 4 skeptic lenses (correctness, negative-control, prior-art-fidelity, measurement-validity) each
  told to *refute* the 0/0 claim → **4/4 returned HOLDS at high confidence; none refuted.**
- Two recurring "major" concerns probed independently and settled (docs/evidence/M0-adversarial-verdict.md):
  (1) 0.00% idle CPU is real — scheduler sits in kernel `do_select` (state S), 0 ticks over 3s.
  (2) tightening grace 1000ms→50ms still passes missed=0 → fires are wake-driven (ms), not poll-floor.
- Limitations the skeptics surfaced, to carry forward (not blockers): re-measure latency on the Pi
  at M5; crash-mid-`mv` at-most-once is M1's job to test; ms-vs-~1s resolution wording could be crisper.

## Next (ordered)
All build milestones (M0–M5) are DONE and all 5 DoD items are met (evaluator loop CONVERGED over
two rounds this session). The ONLY remaining work is optional and non-blocking: re-measure
benchmarks on a real $5 Pi (correctness is hardware-independent; only the throughput ceiling needs
the box). A round-003 evaluator pass is NOT needed for correctness — run it only if iterating on
ergonomics. See "Open / optional" above.

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
- **(M2) socat `EXEC:` execvp's the first token directly — NO shell.** An env-var prefix
  (`VAR=val bash ...`) is taken as the *program name* and fails `execvp` with ENOENT. Pass config to
  forked handlers by `export`-ing into socat's environment (socat propagates it), not as a command
  prefix. Use `,fork` for one handler process per connection.
- **(M2) The handler's `INFIFO` is a script-global, NOT `local`.** The `EXIT` trap runs in top-level
  scope; a function-local is out of scope there and under `set -u` the trap aborts before the `rm`,
  so forget-on-death would silently never fire. A handler process serves exactly one connection, so
  a global is correct. (Verified: the bug manifested as `line 1: INFIFO: unbound variable` + a
  stranded FIFO that the no-trap control couldn't be distinguished from.)
- **(M3) Backpressure design = "kernel pipe buffer IS the ring."** Chosen via a 3-candidate design
  workflow. The publisher does ONE serial `timeout $wto bash -c 'printf > fifo'` per sub per record
  (NO `&`). Healthy sub: ~µs. Wedged sub: its 64KiB FIFO fills, the write times out (zero partial
  bytes), we drop + bump `drops_<pid>` under flock. Drainer reads length-prefixed frames, validates
  the byte count, bounded-writes the socket. NOT fork-free (each write is a ~0.5-10ms `timeout
  bash -c`); the honest claim is "no per-message process ACCUMULATION" — proven by F3 (flat ~15
  procs) vs the leaky control (~1300). `SHELLMUX_WRITE_TIMEOUT` tunes the wedged-abandon latency;
  it is read by BOTH fanout and drainer, so `serve` exports it to forked handlers.
- **(M3) `pub` lingers after stdin EOF.** No app-level ack, so closing the instant `cat` EOFs lets
  the broker be torn down with records still in the socket buffer (~40% loss on a burst). `pub`
  holds the connection `SHELLMUX_PUB_LINGER`s (default 1) so the broker drains. Honest limit: a
  burst longer than the linger can lose its tail — documented, not hidden.

## Dead ends (don't retry — and why)
- `pid="$(start_sched)"` where the backgrounded sched inherits the command-substitution stdout pipe
  → `$(...)` hangs forever waiting for EOF on a pipe the long-lived child holds open. Fix: redirect
  the scheduler's stdout/stderr to a log file so only `echo $!` flows through the capture pipe.
- `trap 'running=0'` to stop the loop on signal — does NOT work (read-retry, see Decisions).
- `while read -N1 -t 0` to drain a FIFO — `read -t 0` is a *non-consuming availability probe*, so
  it spins forever. Use a tiny positive timeout (`-t 0.001`) to actually consume.
- **(M3, big one) `( ...; sleep N ) | socat &` then `kill "$!"; wait "$!"` HANGS ~N seconds.** In a
  `A | B &` pipeline, `$!` is **B** (socat), and `wait` on any pipeline member blocks on the WHOLE
  pipeline — including the orphaned `sleep N` linger that `kill $!` never reached. This made the M3
  flood test MIS-REPORT a true ~1s delivery as ~90s, sending me on a long false hunt for a broker
  "throttle" that did not exist. Diagnosed by a multi-agent workflow whose synthesis measured
  `kill+wait took 88s` directly. Fix: run the publisher under `setsid`, `kill -- -$PGID` the whole
  group, and NEVER `wait` on it; capture elapsed at completion INSIDE the poll loop, not after
  teardown. LESSON: when a "performance" number looks absurd, suspect the measurement harness first.

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
