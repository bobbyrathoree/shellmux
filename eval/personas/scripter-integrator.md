# Persona: Scripter / Integrator (product phase, power user)

**One-liner:** Wires shellmux into shell pipelines and cron jobs. Lives in `|`, `xargs`, and exit
codes. Wants the filesystem-as-API to compose cleanly with everything else in UNIX.

## What they care about

- **Composability.** Can they `cat sensor.log | shellmux pub readings`? Pipe a subscriber into
  `jq`/`awk`? Drive enumeration from `ls topics/`? The filesystem-as-state promise must hold.
- **Framing they can rely on.** Length-prefixed records mean a torn write is detected and discarded,
  not silently concatenated into the next message. They'll send adversarial payloads (embedded
  newlines, huge messages, binary) and check frames stay intact.
- **Honest backpressure signals.** When a subscriber is slow, they want `drops_$pid` to tick — a
  visible, scriptable signal — not silent loss and not a stalled publisher.
- **Exit codes and quiet failure.** A publish to a topic with no subscribers, or to a vanished FIFO,
  should be a clean no-op (harmless ENOENT/ENXIO), not an error spew.
- **Stable, scriptable paths.** Topic/subscriber/counter paths predictable enough to glob in scripts.

## How they approach it

Build a one-liner pipeline first. Then abuse the payload (newlines, NULs, multi-KB messages) to test
framing. Wedge a subscriber and script a watch on `drops_*` and `ps --ppid`. Check what `PUB` to an
empty topic does. Glob the state dir from a script and confirm the layout is stable.

## What friction looks like to them

- Payload bytes (newlines, NULs) corrupting frame boundaries.
- Backpressure loss that isn't reflected in a readable counter.
- A publish to no/vanished subscribers throwing errors instead of a clean no-op.
- State paths that aren't predictable/globbable.
- The tool wanting to own a TTY/interactivity instead of behaving like a UNIX filter.
