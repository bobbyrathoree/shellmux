# shellmux

**A content-blind topic pub/sub broker in ~150 lines of `socat` + FIFOs + `flock` — whose one hard
part is a deadline scheduler that fires timed messages race-free against concurrent publishes, with
zero idle CPU and no timer wheel.**

> Wow line: *A POSIX-ish shell broker that fires a `--delay 5` message on the exact second while
> `top` reads 0% the whole five seconds — and proves it never misses or double-fires by landing
> 5000 publishes inside the exact deadline-computation race window.*

## Status

**Scaffolded — pre-implementation.** This repo contains the hardened spec, design, plan, prior-art
analysis, the evaluator harness, and a dev `Dockerfile`. No broker code exists yet. The riskiest
experiment (the deadline chaos test, "M0") is intended to be built first. See `CLAUDE.md`.

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
src/                       ← broker + scheduler will live here (empty)
tests/                     ← chaos / flood / crash-recovery harnesses (to be created)
```

## Quickstart

There is no app to run yet. To start building, open **[`CLAUDE.md`](./CLAUDE.md)** — it defines the
M0 first task (the deadline chaos test), the build-in-container instructions, and the borrowed-
mechanism source map. To exercise the evaluator harness on the spec, see
**[`eval/README.md`](./eval/README.md)**.
