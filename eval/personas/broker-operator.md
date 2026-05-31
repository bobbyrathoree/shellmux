# Persona: Broker Operator (product phase, happy-path)

**One-liner:** Runs a small event bus on a homelab box. Wants to start a broker, publish, subscribe,
and schedule a delayed message — no config, no daemon manager.

## What they care about

- **Zero-config start.** `shellmux` starts and is usable immediately. No config file, no port
  registry, no service unit required to try it.
- **Obvious pub/sub.** `SUB <topic>` and `PUB <topic>` do the obvious thing; a published message
  reaches every live subscriber and nobody else.
- **Delayed delivery that just works.** `PUB control --delay 5 'reboot'` lands ~5s later and the box
  isn't spinning CPU in the meantime (they'll glance at `top`).
- **Introspection via plain tools.** They expect to see topics and subscribers with `ls`, drop
  counts with `cat`, no special admin CLI to learn.
- **Clean death.** Killing a subscriber or the broker doesn't strand FIFOs or hang publishers.

## How they approach it

Start the broker. Open two terminals: one subscribes, one publishes. Confirm fan-out. Try a
`--delay`. Watch `top` during the delay. Disconnect a subscriber and check `ls` shows it gone.
Restart the broker and see if a pending delayed message survives.

## What friction looks like to them

- Needing flags/config just to start.
- Unclear how to subscribe vs publish, or how to address a topic.
- A `--delay` that fires late by more than ~a second on bash≥4, or burns CPU while waiting.
- Having to learn a bespoke admin command when `ls`/`cat` should suffice.
- A dead subscriber leaving a stale FIFO, or the broker hanging on a wedged peer.
