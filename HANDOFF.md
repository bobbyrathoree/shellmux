# HANDOFF — shellmux
Last updated: (scaffold seed — run `date` and update on first session)   |   Last commit: (initial scaffold)   |   Current milestone: M0 (not started)

## If you are a new agent, START HERE
This repo was just scaffolded. NO implementation exists yet. Read `PROMPT.md` (your kickoff),
then `CLAUDE.md`, then `docs/spec.md` → `docs/design.md` → `docs/plan.md` → `docs/prior-art.md`.
Your first task is **M0** — the riskiest experiment — exactly as stated in `PROMPT.md` §1 and
`docs/plan.md`. Do not build anything else until M0 passes (or fails and is reported).

## Done (with commit shas)
- Repo scaffolded: spec, design, plan, prior-art, evaluator harness, Dockerfile, PROMPT.md. (initial commit)

## In progress (exact state)
- Nothing yet. Awaiting first build session.

## Next (ordered)
1. Build the dev container from `Dockerfile`.
2. Run **M0** per `PROMPT.md` §1 / `docs/plan.md`. Capture raw output as the first demo evidence.
3. If M0 passes → proceed down `docs/plan.md` milestones. If it fails → see PROMPT.md §1 M0-fail action.

## Decisions & rationale
- (none yet)

## Dead ends (don't retry — and why)
- (none yet)

## Open questions / assumptions made
- (none yet)

## How to resume
- `cat HANDOFF.md && git log --oneline -20 && git status`
- Build/run instructions are in `CLAUDE.md` and `PROMPT.md` §6 (must run in the Linux container; host is darwin/arm64).
