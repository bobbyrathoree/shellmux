# Persona: Adversarial Flooder (product + spec phase, adversarial)

**One-liner:** Impatient and hostile. Wedges subscribers, floods topics, kills processes at the
worst moment, and lands publishes inside the deadline race on purpose. Wants to break the one claim.

## What they care about

- **Breaking the headline claim.** They will try to produce a missed or duplicate deadline fire:
  land a publish in the compute-before-block window, poke the wake-FIFO at pathological times, kill
  the scheduler mid-`mv`, send concurrent pokes. If `missed=0 dup=0` does not survive, they win.
- **The backpressure leak.** They wedge a subscriber (`socat … | (read x; sleep 999)`) and flood it,
  watching `ps --ppid $PUB | wc -l`. If background writers accumulate (the old `> $f &` bug), the
  isolation claim is false and they say so.
- **Garbage input.** They paste binary, half-frames, oversized length prefixes, bogus `--at` values
  (past, far future, non-numeric), and `SUB`/`PUB` to weird topic names. They expect no crash, no
  hang, no silent corruption.
- **Resource exhaustion.** They open many subscribers, abandon connections half-open, and spam topic
  creation to see if anything is unbounded (deferred files, empty dirs, fds).

## How they approach it

Assume the demo is staged and try the thing the author didn't script. Hit the race harder than 5000
trials. Kill at every boundary (`before mv`, `after mv before delivery`, broker death mid-flood).
Feed malformed frames and out-of-range deadlines. Abandon connections to leak fds.

## What friction looks like to them (and is gold for the project)

- Any reproducible missed/duplicate deadline fire.
- Background writer/fd count rising under a flood (leak).
- A crash, hang, or frame corruption from malformed input.
- A bogus `--at`/`--delay` accepted into a state that never fires or fires forever.
- Unbounded growth they can trigger (deferred files, topic dirs, half-open connections).
- A missing must-fail negative control — meaning the proof is unfalsifiable theater.
