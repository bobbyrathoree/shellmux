# Contributing to shellmux

Thanks for considering a contribution. shellmux is small on purpose, and it has **one unusual rule
that is non-negotiable**. Read it before you write code — it's the reason the project is trustworthy.

## The one rule: every correctness test ships a must-fail negative control

A passing test proves nothing unless you've shown it can *fail*. So in this repo, **every test that
asserts a correctness property also runs a deliberately-broken variant and asserts that it fails on
the expected axis.** If the broken variant passes too, the test isn't exercising the property and the
green checkmark is theater.

This is enforced by convention, not tooling, and it's the whole ethos. Concretely:

- The deadline proof (`tests/chaos_deadline.sh`) ships three broken schedulers in `tests/negative/`
  (`naivesleep`, `drainfirst`, `nocommit`), each **exactly one knob** off `src/sched.sh`, and asserts
  each one misses or duplicates. You can `diff src/sched.sh tests/negative/<x>.sh` to see the single
  violated discipline point.
- The other suites gate their fix behind a one-knob environment flag and assert the bug returns when
  it's set: `SHELLMUX_NO_VALIDATE=1` (input boundary), `SHELLMUX_NO_TRAP=1` (forget-on-death),
  `SHELLMUX_LEAKY_WRITE=1` (the process-leak we replaced), `SHELLMUX_NO_WLOCK=1` (frame interleave),
  `SCHED_NO_SKIP_CORRUPT=1` (corrupt-file DoS), `SCHED_NO_RECOVER=1` (crash recovery).

**If you add a feature or fix a bug, your test must include a control that fails without your change.**
A PR without one will be asked to add it. (See the [`tdd`](https://github.com/) red-green discipline:
write the failing test first, confirm it fails *for the right reason*, then make it pass.)

## The second rule: honesty over hype

shellmux is aimed at a skeptical audience. We state true, platform-qualified numbers and name our
limits out loud (lossy backpressure, no persistence, fork-bound throughput, the real dependency set).
Don't add a claim the code can't back, and don't soften a limit that's real. If a doc sentence and the
code disagree, the **code wins** and the doc gets fixed. Borrowed mechanisms must cite a real
`file:line` that actually says what you claim (`docs/prior-art.md`, `CLAUDE.md`).

## What's in scope / out of scope

**In scope:** correctness hardening, the scheduler, the fan-out/backpressure path, ergonomics
(flags, error messages, introspection), docs, portability within the Linux + bash≥4 dep set, tests.

**Out of scope (deliberate, documented punts — see `docs/spec.md`):** persistence/replay, acks /
at-least-once / retry, wildcard or hierarchical topics, auth/TLS (delegate to `socat OPENSSL`/SSH),
clustering/HA, payload parsing. A PR that adds one of these will likely be declined — open an issue to
discuss first. **Do not touch `src/sched.sh`'s `mv` commit point or the wake-FIFO discipline** for an
unrelated change; those are load-bearing for the proof.

## Development setup

The host toolchain is pinned to a Linux container (macOS bash 3.2 lacks fractional `read -t`,
`flock`, and `timeout` — developing on bare macOS will mislead you).

```bash
docker build -t shellmux-dev .
docker run --rm -it -v "$PWD:/work" -w /work shellmux-dev bash
```

Inside the container:

```bash
bash tests/run_all.sh                 # all 10 suites, each with its control (~3 min; N_MAIN=400 for ~90s)
bash tests/chaos_deadline.sh          # just the deadline proof (the spine)
bash tests/<suite>.sh                 # a single suite while iterating
```

Source is two files: `src/shellmux` (the broker — serve/sub/pub, fan-out, drainer, reaper, input
validation) and `src/sched.sh` (the deadline scheduler — the contribution). Tests are in `tests/`,
broken controls in `tests/negative/`.

## Submitting a change

1. Branch from `master`.
2. Write the failing test (with its must-fail control) **first**; confirm it fails for the right reason.
3. Make it pass with the smallest change that does so.
4. Run the **full** suite in the container — it must stay green, and **`chaos_deadline.sh` must still
   report `missed=0 dup=0` over N=5000** (any change near the scheduler must re-prove the spine).
5. Keep style consistent with the surrounding code (the files are heavily commented with *why*, not
   just *what* — match that). Update the relevant docs in the same PR if behavior changed.
6. Open a PR describing what property you added/fixed and pointing at the test + its control.

## Reporting bugs

Open an issue with: the exact commands, the platform (`uname -a`, `bash --version`, `socat -V`), and
what you expected vs. saw. If it's a correctness claim ("a message was missed/duplicated"), a minimal
reproducible script is hugely valuable — that's exactly the kind of finding this project wants.

## Code of conduct

Be respectful and assume good faith. Technical disagreement is welcome; make it about the code and the
evidence.
