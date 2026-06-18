# shellmux

**A content-blind topic pub/sub broker built from `socat` + FIFOs + `flock` — whose one hard part is
a deadline scheduler (`src/sched.sh`, 167 lines — one screen) that fires timed messages race-free
against concurrent publishes, with ~0% idle CPU and no timer wheel.**

> Wow line: *A POSIX-ish shell broker that fires a `--delay 5` message on the exact second while
> `top` reads 0% the whole five seconds — and proves it never misses or double-fires by landing
> 5000 publishes inside the exact deadline-computation race window.*

## Status

**Built and green — M0 through M5.** The single falsifiable claim is **proven**: over **N=5000**
adversarial-timing trials the deadline scheduler fires **0 missed / 0 duplicate** at **~0% idle CPU**,
and the proof survives three must-fail negative controls plus a 4-lens adversarial verification. The
broker around it (socat-fork acceptor, per-subscriber FIFO + bounded ring drainer, `--at`/`--delay`
deferred delivery through that scheduler, forget-on-death, crash recovery, GC reaper) is implemented
and tested. Reproduce from a clean checkout:

```bash
docker build -t shellmux-dev .
docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/run_all.sh   # all 7 suites
# fast pass (~90s):  ... -e N_MAIN=400 bash tests/run_all.sh
```

The 1-page demo script is **[`DEMO.md`](./DEMO.md)**; current state and decisions live in
**[`HANDOFF.md`](./HANDOFF.md)**; per-milestone evidence is in `docs/evidence/`.

## What it is (and isn't)

shellmux gives you correct fan-out plus correct *timing* for the large class of deployments that do
not need a clustered broker: sensors on a boat, CI runners on a LAN, a homelab event bus, an
air-gapped factory floor. Per-subscriber isolation and forget-on-death come free from
fork-per-connection. The earned contribution is **race-free, zero-busy-spin deadline delivery**.

It is **not** a competitor to Mosquitto / NATS / Redis / ZeroMQ on throughput, persistence, or
clustering, and it is **not** privacy/E2EE (the host sees every byte — "content-blind" is a
simplicity note, not a security feature). See `docs/prior-art.md`.

## Repo map

```
CLAUDE.md                  ← read this first (agent onboarding brief)
README.md                  ← you are here
Dockerfile                 ← Linux dev container (bash≥4, socat, util-linux, coreutils)
docs/
  spec.md                  ← canonical source of truth (what/why)
  design.md                ← how it works (components, flow, borrowed-mechanism adaptation)
  plan.md                  ← milestones (M0 first), tests, negative control, risk
  prior-art.md             ← how we differ; the "this is just X" dismissals to survive
  _redteam-verdict.md      ← adversarial Linus-persona review (input material)
  _partner-plan.md         ← partner sketch (input material, folded into plan.md)
eval/
  README.md                ← the phase-aware evaluator loop
  personas/                ← reviewer + user personas
  challenges/              ← challenge bank (spec-phase + product-phase) + regression bank
  prompts/                 ← evaluator / aggregator / analyst pipeline prompts
  feedback/                ← raw / synthesis / analysis output (per round)
DEMO.md                    ← the 1-page demo script (what to run, what the judge sees)
HANDOFF.md                 ← current state, decisions, dead-ends (the project's brain)
src/
  sched.sh                 ← the deadline scheduler (THE contribution), 167 lines
  shellmux                 ← the broker: serve/sub/pub + fan-out + drainer + reaper, 374 lines
tests/
  chaos_deadline.sh        ← M0 GATE: 0 missed/0 dup over N≥5000 + 3 must-fail controls
  smoke.sh                 ← M0 tracer smoke
  crash_recovery.sh        ← M1 deferred re-arm + outbox recovery
  sub_lifecycle.sh         ← M2 SUB register / forget-on-death / TCP
  flood_wedged.sh          ← M3 bounded fan-out (ps flat) + leaky must-fail control
  deferred_pub.sh          ← M3b --delay/--at fire at the deadline + fire-now control
  introspection.sh         ← M4 ls/cat state + GC reaper
  bench.sh                 ← throughput + footprint
  run_all.sh               ← run every suite
  negative/                ← the deliberately-broken must-fail control schedulers
docs/evidence/             ← captured run output per milestone
```

## Quickstart

Build the container and run the suite (above), or follow **[`DEMO.md`](./DEMO.md)** for the live
demo. The deadline chaos proof is the spine — start there:

```bash
docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/chaos_deadline.sh
```

Agent onboarding and the borrowed-mechanism source map are in **[`CLAUDE.md`](./CLAUDE.md)**; the
evaluator harness is in **[`eval/README.md`](./eval/README.md)**.
