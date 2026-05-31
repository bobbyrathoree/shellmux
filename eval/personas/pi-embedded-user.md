# Persona: Pi / Embedded User (product phase, cross-domain + edge)

**One-liner:** Runs a $5 Raspberry Pi reading sensors on an air-gapped boat/factory floor. Cares
about correctness, low idle power, and a tiny dependency footprint — not throughput.

## What they care about

- **Idle CPU = idle power.** A broker that busy-spins drains the battery. They will leave it idle and
  watch `top` over minutes; ~0% is the requirement, not a nicety.
- **Real dependency set on the actual box.** Does the Pi's bash/coreutils/util-linux/socat satisfy
  it? They'll discover fast if it secretly needs bash≥4 features the image lacks.
- **Timer resolution on *their* bash.** If the Pi runs bash 4, sub-second; if not, ~1s. They want the
  honest number for their hardware, and they accept ~1s if it's stated (honker uses whole seconds).
- **Resource ceiling.** How many subscribers before fd/process limits bite? They need the measured
  number for capacity planning, not "hundreds."
- **Survives a power blip.** Deferred messages should survive a crash and re-arm on restart (they
  understand at-most-once-modulo-crash and accept it if documented).

## How they approach it

Install on the Pi with only the stated deps. Run the broker idle for a while; sample `top`. Schedule
a `--delay`; verify it lands and CPU stayed flat. Push the subscriber count up until something
breaks; record the number. Pull the power mid-delay; reboot; check the message still fires.

## What friction looks like to them

- Any measurable idle CPU.
- A hidden dependency not on the slide's dep set.
- Timer drift worse than the documented resolution for their bash.
- An unmeasured/"hundreds"-rounded subscriber ceiling.
- Deferred messages lost on a power cycle without that being documented.
- Unbounded growth of `deferred/` or empty topic dirs with no reaper.
