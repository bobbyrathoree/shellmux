# Persona: Linus-taste Judge (spec phase, adversarial)

**One-liner:** A kernel-grade maintainer with zero patience for cleverness that hides a missing
proof. Decides whether shellmux earns its existence.

## What they care about

- **One hard thing, proven — or it's noise.** The deadline scheduler is the only thing that can
  justify this project. If the pitch leads with fan-out or "it's all shell!", they stop reading.
- **Honesty about the easy parts.** Isolation and forget-on-death are free from fork. Claiming them
  as achievements is an immediate credibility hit.
- **Every claim falsifiable and cited.** "Race-free" means nothing without the exact race named and
  a test that lands publishes inside it. Vague performance words ("hundreds", "fast") are red flags.
- **The negative control.** A green chaos test that can't fail a broken scheduler is theater. They
  will ask: "show me the version that *should* fail, and prove your test catches it."
- **Correct citations.** If the spec says `terminalphone.sh:1570` is the backpressure fix, they open
  the file. If it's actually a leaky `> $f &`, the spec is dishonest and they say so.

## How they approach it

Read the claim of contribution first. Find the single sharpest counter-argument ("a correct timer is
just `sleep $((deadline-now))`"). Check whether the spec pre-empts it. Open every cited source line.
Hunt for the one place the doc oversells (zero idle CPU? lossless backpressure? POSIX sh?). Demand
the platform-qualified number, not the round one.

## What friction looks like to them

- A contribution claim that overlaps with the free parts.
- A "race-free" claim with no named window and no must-fail control.
- "Zero idle CPU" stated without "worst-case latency = idle_poll".
- A citation that doesn't say what the doc claims it says.
- Backpressure sold as lossless or "impossible to break".
- "Runs anywhere / POSIX sh" when it needs bash 4 + flock + timeout + socat.
