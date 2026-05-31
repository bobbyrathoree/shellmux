# shellmux — Evaluator Harness

This is a **phase-aware** evaluator loop. It scores the project with simulated reviewers/users,
synthesizes patterns, assesses feasibility, and feeds a prioritized roadmap back into the build.
**No rounds have been run yet — this directory is scaffolding.** Running a round is a deliberate
act; see the mechanics below.

## Two phases

shellmux has no app yet, so the harness runs in **spec phase** today and **graduates** to **product
phase** the moment M0 builds (the deadline chaos test goes green and `src/shellmux` accepts
`SUB`/`PUB`).

| | Phase: `spec` (now) | Phase: `product` (after M0) |
|---|---|---|
| What is evaluated | `docs/spec.md`, `design.md`, `plan.md`, `prior-art.md` | the running broker + scheduler |
| How evaluators interact | read the docs, attack the claims | run `src/shellmux`, publish/subscribe, fire `--delay`, wedge a sub, read `drops_*`, run the chaos test |
| Verification | citation checks, internal-consistency checks, prior-art search | stdout/stderr, `ls`/`cat`/`ps` introspection, `missed=/dup=` counters |
| Personas | adversarial reviewer, prior-art skeptic, feasibility realist, Linus-taste judge (+ early product personas) | broker operator, scripter/integrator, Pi/embedded user, migrator, adversarial flooder |

Each challenge in `challenges/bank.json` is tagged `"phase":"spec"` or `"phase":"product"`. A round
runs only the challenges for the current phase. The same personas file
(`personas/`) covers both phases; some personas are spec-leaning (the Linus judge), some are
product-leaning (the Pi user), and several apply to both.

## Round mechanics

```
Evaluators (4-6 personas × challenges)  →  evaluate / use + report structured feedback (JSON)
        ↓
Aggregator                               →  synthesize patterns across all feedback (frequency × severity)
        ↓
Analyst                                  →  read synthesis + docs/code (READ-ONLY), assess feasibility, order fixes
        ↓
Implement top priorities                 →  edit the spec/design (spec phase) or the broker (product phase)
        ↓
Next round                               →  measure DELTA: did the same challenge score better? any NEW friction?
```

- **Spec phase, implement step** = sharpen the docs: kill or qualify a weak claim, add a citation,
  fix an inconsistency, fold in a prior-art rebuttal. The "delta" is whether the next round's
  reviewers stop hitting that objection.
- **Product phase, implement step** = change the broker/scheduler/tests. The headline metric is the
  M0 chaos result (`missed=0 dup=0` over N≥5000) plus per-challenge satisfaction delta.

Combine aggregator + analyst into one agent for small (2-3 evaluator) sanity rounds. Always dispatch
evaluators on the strongest model. Each evaluator gets an isolated working dir and its own feedback
output file; product-phase evaluators additionally get an isolated broker instance (unique `$DIR`
and ports) — zero shared state between evaluators.

## Directory map

```
eval/
  README.md                 ← this file
  personas/                 ← one .md per persona (reviewers + users)
  challenges/
    bank.json               ← spec-phase + product-phase challenges (tagged by phase)
    regression.json         ← challenges promoted after severe+persistent friction (starts empty)
  prompts/
    evaluator.md            ← base evaluator prompt + the feedback JSON schema
    aggregator.md           ← synthesis prompt (patterns, tensions, round diff)
    analyst.md              ← feasibility/ordering prompt (reads synthesis + docs/code)
  feedback/
    raw/round-NNN/          ← per-session feedback JSON
    synthesis/round-NNN.md  ← aggregator output
    analysis/round-NNN.md   ← analyst output
```

## Running a round (when you decide to)

1. Pick the phase (`spec` until M0 builds, then `product`). Select that phase's challenges from
   `challenges/bank.json`. Use arena mode: one shared challenge to all personas + one unique each.
2. For each `(persona × challenge)`: allocate an isolated dir (and, in product phase, a broker
   instance), dispatch an evaluator agent with `prompts/evaluator.md` + the persona file, collect
   JSON into `feedback/raw/round-NNN/`.
3. Dispatch the aggregator (`prompts/aggregator.md`) over all raw feedback →
   `feedback/synthesis/round-NNN.md`.
4. Dispatch the analyst (`prompts/analyst.md`) over the synthesis + the docs (spec phase) or the
   source (product phase) → `feedback/analysis/round-NNN.md`.
5. Implement the top priorities. Tag the commit / bump the round. Re-run the SAME challenge next
   round and read the delta.
6. Promote any `severity ≥ high AND persistent ≥ 2 rounds` friction into `regression.json`; retire
   it after it scores `resolved` for 2 consecutive rounds.

**Convergence:** track novelty (new vs persistent friction). When `new` drops below ~10% of total
for 2+ rounds, you are converging. In spec phase, convergence means the claims have stopped drawing
new credible objections — the signal to start building M0.
