# shellmux — Round-001 Delta (implement → measure)

This closes the round-1 evaluator loop: what was implemented in response to the
synthesis/analysis, and the measured result. Round 2 (if run) re-runs the same
challenges and diffs against this.

## Headline: the one claim held; the perimeter was hardened

The product-phase round (12 persona×challenge agents that actually drove the
running broker) returned **avg satisfaction 7.6/10, 12/12 completed**. Crucially,
the adversarial-flooder ran the **full N=5000 chaos gate live** and independently
confirmed `missed=0 dup=0 ontime=5000` with all three must-fail controls failing
("a working falsifier, not decorative"). **The single falsifiable claim survived
an adversarial product user.** Every fix below was gated on `chaos_deadline.sh`
still reporting `missed=0 dup=0` — and it does.

## Findings reproduced independently before fixing (no agent hallucination)

All five high-severity findings were re-run by hand against `HEAD=7cc3bd8` and
reproduced exactly as reported:

| ID | Finding | Reproduced | Status after R1 |
|----|---------|-----------|-----------------|
| F1 | `pub --at xyz` / `--delay 1.5` → server-side handler crash (`$2: unbound` / arith error), message dropped, publisher rc=0 | yes (`line 175: xyz: unbound variable`) | **RESOLVED** — rejected at boundary, clean nonzero rc |
| F7 | `pub --at 99999999999` → year-5138 record parked in `deferred/` forever | yes (`deferred/99999999999000.x`) | **RESOLVED** — rejected (horizon `SHELLMUX_MAX_DEFER_S`, default 1yr) |
| H1 | `pub '../../../tmp/PWNED'` → `mkdir` **outside** the state dir (traversal primitive) | yes (`/tmp/SHELLMUX_PWNED_1` created) | **RESOLVED** — topic name whitelisted `[A-Za-z0-9._-]+`, no leading dot |
| F4 | `sub --help` / `pub --help` → `$2: unbound variable` crash under `set -u` | yes (`line 323`/`342`) | **RESOLVED** — `usage()` guard prints help, rc=0 |
| H2 | "content-blind"/"length-prefix framing" overstated — NUL stripped, binary mangled, unterminated payload → 0 bytes | yes (NUL `a\0b\0c`→`abc`; no-newline→0 bytes) | **RESOLVED (doc)** — README/DEMO now state the honest contract: newline-delimited NUL-free text, not binary transport |
| H4 | `flood_wedged.sh` F1 flaky (992/1000 one run, 1000/1000 next); operator saw cold-start hang >120s / EXIT 137 | yes — diagnosed as **test orphan-accumulation**, not a broker defect (broker is 1000/1000 every isolated run) | **RESOLVED** — cleanup trap now reaps client-side pids + `pkill -P $$`; 5× back-to-back all pass, no orphan pileup |
| H3 | overdue-deferred-on-reboot silently lost; undocumented | n/a (correct behavior, just unnamed) | **RESOLVED (doc)** — named in DEMO "at-most-once-modulo-crash" |
| ceiling | DEMO said "ceiling = fd/process limits"; real limit is RAM | confirmed ~2.4MB/sub | **RESOLVED (doc)** — DEMO now states RAM-bound, ~100–150 subs on a 512MB Pi |
| F2 | DEMO `cat drops_*` errors on a healthy topic (no file until first drop) | yes | **RESOLVED (doc)** — recipe now `... 2>/dev/null || echo "no drops"`, with a note |

## What was deliberately NOT done (scope guarded)

Per the analyst's punt list and the project's "one small correct thing" framing:
- **No wire-level binary safety / NUL preservation** — H2 is a doc-honesty fix, not
  a mandate to abandon the line-oriented drainer for arbitrary-binary transport.
- **No retained delivery / replay / persistence** for H3 — that is the punted
  feature; the overdue-reboot loss is the *defined* face of at-most-once-modulo-crash.
- **No acks / at-least-once** — F6 (undocumented pub rc) is met by R1 returning a
  meaningful nonzero rc on rejection + documenting it, not by a delivery protocol.
- **No `--no-linger` / batch publish path** — the ~1msg/s serial-pub ceiling is a
  documented-honesty issue; the held-open streaming path (what `flood_wedged.sh`
  uses) already exists for throughput.

## Measured no-regression

- `chaos_deadline.sh`: **missed=0 dup=0 ontime=5000** over N=5000 (full gate),
  three controls fail as required, idle CPU 0.00%.
- All prior suites green; new `tests/input_validation.sh` 7/7 + must-fail
  `SHELLMUX_NO_VALIDATE=1` control regresses as required.
- `run_all.sh` now **8/8 suites**.

## Convergence call

Round 1 surfaced a genuine, previously-unexercised class (the **input boundary
that derives the deadlines** — the analyst's sharpest-adjacent threat) plus a
real test-hygiene bug (H4). Both are now closed at the source with tests + must-
fail controls, and the rest were doc-honesty fixes. The remaining unaddressed
items are all explicitly-punted scope (binary transport, replay, acks, throughput)
— not new credible threats to the one claim. A round 2 would mostly re-confirm
resolution; the loop is at convergence for *correctness*. Parked unless ergonomics
iteration is desired. The headline claim is proven, adversarially verified, and
now its data-input perimeter is hardened too.
