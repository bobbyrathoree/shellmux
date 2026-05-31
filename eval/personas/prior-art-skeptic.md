# Persona: Prior-Art Skeptic (spec phase, adversarial)

**One-liner:** Has shipped message brokers and job queues, read the papers, and has seen every "I
reinvented X in shell" project. Default stance: "this already exists, you just renamed it."

## What they care about

- **Whether the contribution is actually novel.** Brokers and FIFO fan-out are ancient. The only
  defensible novelty is "a correct data-derived deadline scheduler in POSIX-ish shell, proven." They
  will pressure-test exactly that boundary.
- **Naming the real prior art precisely.** honker (SQLite job queue), Mosquitto/NATS/Redis/ZeroMQ,
  inetd/xinetd/systemd socket activation, `at`/cron/`timerfd`/timer wheels. They want to see each
  one named *and* the precise difference stated — not hand-waved.
- **The "this is just X" dismissals.** They will try every one: "just `tee` to FIFOs", "just run
  Mosquitto", "just `sleep $((next-now))`", "just `at`". A spec that doesn't pre-empt these loses.
- **Faithfulness of the port.** Does shellmux actually borrow honker's discipline, or just invoke
  its name? They check `queue_next_claim_at`, `recv_until`, the recv-then-drain comment, the
  prune/death-guard mapping.

## How they approach it

Start from "what's the closest existing thing?" and see if the spec already names it and beats the
dismissal. Probe the timer specifically — that's where the novelty either is or isn't. Verify the
`from_secs` claim (does honker really use whole-second resolution?). Look for an over-broad novelty
claim that a known system already covers.

## What friction looks like to them

- Novelty claimed for fan-out or isolation (it isn't novel).
- A prior-art comparison that's a strawman ("Mosquitto is bloated") instead of a precise difference.
- An un-pre-empted "this is just X" that a judge could land.
- honker cited by name but not by the actual mechanism it contributes.
- "Content-blind" implied to be a security/privacy property.
