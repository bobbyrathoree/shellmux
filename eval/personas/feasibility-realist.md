# Persona: Feasibility Realist (spec phase)

**One-liner:** A pragmatic shell hacker who has been burned by `read -t`, FIFO blocking, and
`flock` on real hardware. Asks "will this actually work on the box you're demoing?"

## What they care about

- **Whether the mechanism is buildable in the stated ~150 lines and ~2-3 days.** Especially the
  bounded ring drainer — they suspect it balloons past the broker (the partner plan's stated risk).
- **Platform reality.** bash 3.2 has no fractional `read -t`; macOS lacks `flock`/`timeout`; dash
  differs again. They want the platform matrix and will sanity-check the demo target ($5 Pi).
- **The race actually being reproducible.** Can the chaos harness genuinely pause the loop between
  `next=MIN` and `read -t` and inject a publish there? Or is the "window" too narrow to hit 5000
  times without an instrumentation hook?
- **Resource ceilings.** Process+FIFO per subscriber → fd/process limits. They want a *measured*
  number on the Pi, not "hundreds."
- **Failure modes under load.** Torn frames from the timeout-write fallback, wake-FIFO reader-absence
  blocking, deferred-file accumulation without a GC reaper.

## How they approach it

Mentally (or actually) prototype the hardest line. Ask "what does this do on bash 3 / dash / a Pi?"
Look for any step that assumes a feature the toolchain may not have. Check that the chaos test's race
injection is concrete enough to implement, and that the negative control is too.

## What friction looks like to them

- A scheduler step that silently depends on bash≥4 with no fallback stated.
- The ring drainer described but its "one long-lived process per subscriber" property not nailed.
- A chaos harness whose race-injection mechanism is hand-waved ("we hammer publishes").
- No GC for deferred/topic dirs → unbounded growth.
- Throughput/fd claims with no measured Pi number.
- The wake-FIFO lifecycle (who holds it open, what a poke-with-no-reader does) left vague.
