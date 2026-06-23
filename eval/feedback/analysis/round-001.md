I now have enough grounding. I note F1 (`src/shellmux:175`) maps to the `--at` arithmetic line `run_at_ms=$(( at * 1000 ))` — confirmed unvalidated. F4 maps to the `set -u` `$2` accesses in `--at`/`--delay` shift-2 and in `sub`/`pub` arg parsing. H1 maps to `mkdir -p "$td"` with raw `$topic`. H2 maps to the README/DEMO "content-blind" wording vs the newline-delimited drainer. H4 is the `flood_wedged.sh` F1 timing-dependent assertion. All trace to real lines.

I have everything needed to write the roadmap.

# shellmux — Analyst Roadmap, Product Phase, Round 001

## 0. Does this round threaten the one claim? — NO. Priority zero is unoccupied.

The headline claim is **intact and earned**. The single session that exercised the proof spine (adversarial-flooder × prod-chaos-5000) ran the full gate at `N_MAIN=5000` and observed `missed=0 dup=0 ontime=5000 total_fires=5000` at 0.00% idle CPU, **and all three must-fail controls failed as required** (naivesleep missed=120, drainfirst missed=120, nocommit dup=1770). The flooder's explicit verdict — "a working falsifier, not decorative" — is the finding we most needed and did not get to assert ourselves. The crash path carries its own working negative control (R2'). The proof did not regress; the negative control is not dead. There is no stop-the-line bug.

**One thing to record and watch, not act on at P0:** the sharpest *adjacent* threat (synthesis §6 + F1 + F7) is that the data path which *derives* the deadline — `--at`/`--delay` parsing — is unvalidated, fails silently server-side, and is never exercised by the 5000-trial harness (the harness only ever stages well-formed records). This does not falsify the proven property; the scheduler still fires well-formed deadlines race-free. But it is the first place a skeptic will push next, and it is cheap to close. It is the **#1 roadmap item below**, not P0, because it does not threaten the proof — it threatens the *story around* the proof.

Everything else lives on the free-from-fork perimeter (fan-out, framing honesty, introspection, ceiling) or in doc-honesty. None of it touches the missed=0/dup=0 axis.

---

## 1. Prioritized roadmap (quick, cheap, high-confidence first)

### R1 — Validate & reject `--at`/`--delay` at the publisher control line (F1, F7, §6)
- **Addresses:** F1 (unvalidated `--at`/`--delay` → silent server-side handler crash at `src/shellmux:175` `run_at_ms=$(( at * 1000 ))`, publisher still gets rc=0) and F7 (no upper bound on `--at` → unbounded far-future deferred staging). Both found independently by the two adversarial-weighted personas; this is the analyst's named sharpest-adjacent threat.
- **Classification:** `incremental`.
- **Feasibility & cost:** Cheap and contained. In the `PUB` branch of `_handle`, after parsing `at`/`delay`, gate them through a numeric + range check before the `$(( ... ))` arithmetic: `case "$at" in ''|*[!0-9]*) <reject> ;; esac` and reject `run_at_ms` more than a bounded horizon past `now` (e.g. `SHELLMUX_MAX_DEFER_S`, default ~1 year). On rejection the handler should emit one diagnostic line back over the socket and exit non-zero so the *publisher* can surface it — closing the "rc=0 on garbage" gap (ties to F6). ~6–10 lines. Stays well inside the 374-line broker budget. No new dependency. No scheduler change — the scheduler keeps seeing only well-formed records, so it **cannot** disturb the proof.
- **Watch for friction elsewhere:** keep the reject path content-blind about *payloads* — only the control line is parsed. Do not let validation leak into per-record handling.
- **Verification (next round):** re-run the scripter/flooder "feed `--at xyz` / `--delay 1.5` / `--at 99999999999`" probes — expect a clean rejection (publisher sees nonzero rc + a one-line reason), `broker.log` free of `unbound variable`/`value too great for base`, and `ls deferred/` showing **no** year-5138 files after the far-future spam.

### R2 — Sanitize topic names to a single safe path segment (H1)
- **Addresses:** H1 (high-sev, flooder): `pub <state> '../../../../tmp/SHELLMUX_PWNED'` exits 0 and `mkdir`s **outside** the state dir; `../escape`, whitespace word-split, `;` survive into dir names. A publisher-controlled `mkdir`-anywhere primitive from untrusted input.
- **Classification:** `incremental`.
- **Feasibility & cost:** Cheap. Both `SUB` and `PUB` build `td="$dir/topics/$topic"` then `mkdir -p`. Add one guard rejecting any topic containing `/`, `..`, leading `.`, whitespace, or shell metacharacters — reduce to a whitelisted charset (`[A-Za-z0-9._-]+`) and reject otherwise. `case "$topic" in *[!A-Za-z0-9._-]*|''|.*) exit 1 ;; esac`. ~3–5 lines, applied in both branches (or a shared helper). No dependency, no scheduler contact.
- **Watch for friction elsewhere:** this slightly narrows the "topics are just subdirs, name them anything" ergonomic the operators liked. The whitelist is generous enough (alnum + `._-`) that the homelab/sensor use cases are unaffected; document the charset in one line.
- **Verification (next round):** re-run the flooder traversal probe — `pub` with `../../tmp/X`, `'with space'`, `a;b` must all be **rejected** (nonzero rc, nothing created), and `/tmp/SHELLMUX_PWNED*` must not exist after the run.

### R3 — Fix the `--help` / bad-arg `set -u` crashes; print usage instead (F4)
- **Addresses:** F4 (sub `--help`→`line 323`, pub `--help`→`line 342`, serve `<badarg>`→`line 248` — all `$2`/`$1: unbound variable`). Ugly first impression for anyone probing the CLI; two adversarial personas.
- **Classification:** `incremental`.
- **Feasibility & cost:** Cheap. The crashes are bare `local dir="$1" topic="$2"` / `shift 2` under `set -u`. Add an arg-count/`--help` guard at the top of `sub`, `pub`, and the `serve` arg loop that prints the usage block (already in the file header, lines 17–24) and exits 0. ~6–9 lines total. No dependency, no scheduler contact.
- **Verification (next round):** re-run the CLI-probe sessions — `sub --help`, `pub --help`, `serve bogus` print usage and exit cleanly, no `unbound variable` in stderr.

### R4 — Doc truth-up: "content-blind" framing claim, README crash-recovery qualifier, ceiling resource, drops-counter recipe (H2, F8, F2, ceiling claim)
- **Addresses:** H2 (high-sev, scripter sat=4): "content-blind"/"length-prefix framing" is contradicted — NUL stripped (64→0), binary multiset altered, unterminated payload → 0 bytes; honest contract is "newline-delimited, NUL-free text." F8: README L17 lists "crash recovery" before the at-most-once qualifier that only appears in DEMO. Ceiling claim: limiting resource is **RAM (~2.4MB/sub, ~100–150 subs on a 512MB Pi)**, not fd/pid. F2: DEMO Beat 4 `cat drops_*` errors on a healthy topic (no file until first drop).
- **Classification:** `doc-fix` (cheapest, highest-confidence — do these first, in parallel with R1–R3).
- **Feasibility & cost:** Trivial, zero code risk. Four edits:
  1. **README L3 / DEMO L3:** replace "content-blind" as a *capability* with the honest contract — "the broker parses only the one-line control header and never your payload; delivery is **newline-delimited, NUL-free text** (a payload's bytes up to the first newline; binary/NUL is not preserved)." Keep "content-blind" only in the existing "simplicity note, not a security feature" sense (already correct at README L37–38), not as a binary-safety promise. *(Note: this is a doc-fix because the honest contract already matches the code; we are aligning the words to the line-oriented drainer at `src/shellmux:138–142`, not changing behavior. Do NOT take this as a mandate to build length-prefix-on-the-wire binary safety — see §2.)*
  2. **README L13/L17:** move the "at-most-once-modulo-crash" qualifier up next to the word "crash recovery" so a fast reader cannot over-read durability.
  3. **DEMO Beat 3 ceiling line:** state the real wall — RAM-bound at ~2.4MB/sub, ~100–150 subs on a 512MB Pi — instead of "ceiling = fd/process limits."
  4. **DEMO Beat 4:** change `cat drops_*` to a form that does not error on a healthy topic (e.g. `cat drops_* 2>/dev/null || echo "no drops"`), or note that the file appears only after the first drop. (This is the doc half of F2; the code half is optional — see R7.)
- **Verification (next round):** re-run the scripter framing probe expecting the doc to now *predict* the newline/NUL behavior (claim-honesty audit flips H2 from FALSE to SUPPORTED-as-qualified); operator follows DEMO Beat 4 verbatim with no exit-1.

### R5 — Make `flood_wedged.sh` F1 deterministic (or reframe the assertion to the honest property) (H4)
- **Addresses:** H4 (high-sev, flooder): identical command, two runs — Run 1 FAIL F1 (992/1000, ~60s), Run 2 ok (1000/1000, ~3s). A coin-flip that could fail live in front of a judge; operator independently saw the same suite hang >120s / EXIT=137 on cold start.
- **Classification:** `incremental` (test-only; **does not touch the broker or scheduler**).
- **Feasibility & cost:** Moderate, and the *right* fix is mostly about what the test asserts. The test's own header (lines 7–11) already concedes "we do NOT claim healthy subs run at full speed regardless of a wedged peer" — yet F1 asserts an exact `h1>=FLOOD && h2>=FLOOD` within a `DRAIN_CAP`, which is a *timing* assertion that races the wedged-write-timeout accounting. Two options, cheapest first: (a) **raise/relax the drain budget and the readiness barrier** so the eventual-completeness property (no *permanent* starvation) is what's measured, not a wall-clock deadline — i.e. wait until counts stop advancing, then assert completeness, decoupling the pass from a 60s cap; (b) if intermittent *loss* (992/1000, not just slowness) is real, that is a genuine bounded-write/early-teardown bug in the flood path worth a `diagnose` pass — but the synthesis evidence (Run 2 = 1000/1000) points to a timing/teardown race in the *harness* (the operator's EXIT=137 cold-start corroborates harness instability), not a fan-out correctness defect. Start with (a); escalate to (b) only if relaxed timing still loses records.
- **Watch for friction elsewhere:** do not "fix" flakiness by widening `WRITE_TIMEOUT` in the broker — that would couple healthy subs more tightly to a wedged peer. Keep the change in the test.
- **Verification (next round):** run `flood_wedged.sh` 5× back-to-back in the container — expect 5/5 pass with stable elapsed, no EXIT=137. Re-run on a cold start to confirm the >120s hang is gone.

### R6 — Document/observe the overdue-deferred-on-reboot loss and the memory-ceiling silent degradation (H3, H5)
- **Addresses:** H3 (high-sev, Pi): box off longer than the delay → re-armed scheduler fires the overdue record before any subscriber reconnects → message gone, undocumented (the one lossy crash case a Pi user actually hits). H5 (high-sev, Pi): new-subscriber fan-out silently stops at the ~2500-sub / sub-1GB-mem ceiling with nothing in any log — "on an air-gapped boat I would not know my sensor bus had degraded."
- **Classification:** **H3 = `doc-fix`** (in scope); **H5 = `incremental`, observability only** (lower priority, optional this round).
- **Feasibility & cost:**
  - **H3 (do now, cheap):** This is *correct behavior inside* "at-most-once-modulo-crash" — the fix is to **name it**. Add one bullet to the crash-recovery / limitations section: "A deferred message whose deadline elapsed while the broker was down fires immediately on restart, into whatever subscribers are connected *at that moment* — with no retained delivery, a subscriber that reconnects later will not receive it. This is the expected face of at-most-once-modulo-crash, not a bug." Do **not** add retained delivery (that is replay/persistence — §2).
  - **H5 (optional, defer if budget-tight):** A cheap observability nudge only — e.g. have a failed `mkfifo`/registration in the `SUB` handler write one line to `broker.log` instead of silently `exit 1` at `src/shellmux:115`. ~2 lines. Do **not** attempt memory admission control or backpressure on subscriber count — that is architectural and out of budget. If even the log line risks the line budget, downgrade H5 to a documented limitation ("subscriber count is RAM-bound; degradation past the ceiling is silent — monitor `mem_avail`").
- **Verification (next round):** Pi-persona re-reads limitations and finds H3 predicted (audit flips from "undocumented" to "documented honest limit"); H5, if touched, shows a `broker.log` line on a failed registration.

### R7 (optional, lowest priority) — Eagerly create `drops_<pid>=0` at subscriber registration (F2 code half)
- **Addresses:** F2 (most *frequent* friction; universal) — the `cat drops_*` error on a healthy topic. R4.4 already fixes the doc; this would fix the *behavior* so introspection is uniform.
- **Classification:** `incremental`.
- **Feasibility & cost:** Cheap (one `printf '0\n' > "$td/drops_$$"` at SUB registration), but it interacts with the reaper (`_reap` removes stale `drops_<pid>` whose FIFO is gone — fine) and adds a file per sub. Marginal. Lower confidence on whether it's worth the line vs the pure doc-fix. Do only if R1–R6 land with budget to spare.
- **Verification:** `ls topics/<t>/drops_*` shows a zeroed counter immediately after a sub connects, no first-drop required.

---

## 2. What NOT to do — punt list (protect the budget and the framing)

These were asked for (explicitly or implicitly) by personas and must stay out of scope:

- **Do NOT build wire-level length-prefix binary safety / NUL preservation.** H2 is a *doc-honesty* fix (R4.1), not a mandate to make the drainer byte-exact for arbitrary binary. Re-engineering the FIFO frame path to preserve NUL/binary would mean abandoning the line-oriented `read` model (`src/shellmux:138–142`) — that is an `architectural` change to the data plane for a use case (binary blobs over a shell text broker) the project explicitly does not target. The honest contract ("newline-delimited NUL-free text") is *fine*; just stop claiming more.
- **Do NOT add retained delivery / persistence / replay** to solve H3. The Pi user's overdue-reboot loss is *defined* as in-scope by "at-most-once-modulo-crash." Retain/replay is the exact punted feature. Document it (R6/H3); do not build it.
- **Do NOT add acks / at-least-once / a publish-receipt protocol.** F6 (undocumented `pub` exit code) is satisfied by R1 surfacing a nonzero rc on *rejected* control lines plus a one-line doc of the existing rc contract — not by adding an app-level delivery ack. The scripter's "I can't branch on undocumented codes" is met by documenting, not by inventing acks.
- **Do NOT add wildcards / topic hierarchies / subscription patterns.** Not requested strongly; pure scope creep.
- **Do NOT add auth / TLS / access control.** H1 is solved by *input sanitization* (R2), not by an auth layer. "The host sees every byte" stays an honest non-goal.
- **Do NOT add a `--no-linger` / batched high-throughput publish path (F3).** The ~1 msg/s serial-pub ceiling is a *documented honesty* problem, not a throughput-feature gap. Fix it as a doc-fix: correct DEMO Beat 3 so the flood recipe uses a *single held-open connection streaming many records* (as `flood_wedged.sh` already does at lines 111–116) rather than a serial `loop pub` that forks socat per message. Chasing throughput risks the linger-as-correctness guarantee operators rely on (synthesis tension #4) and bloats the broker. **(Folding this DEMO Beat 3 correction into R4 as a fifth doc edit is the right home for it.)**
- **Do NOT touch the scheduler, the `mv` commit point, the wake-FIFO discipline, or the bounded drainer's core loop** for any item above. Every roadmap item is reachable without editing `src/sched.sh` or the six-point discipline. Guard the core.

---

## 3. Effort & risk

| Item | Effort | Risk |
|---|---|---|
| R4 (doc truth-up, incl. F3 DEMO recipe) | ~30–45 min | none (docs) |
| R3 (CLI usage guards) | ~20 min | low |
| R2 (topic sanitization) | ~20 min | low |
| R1 (`--at`/`--delay` validation + reject rc) | ~45 min | low–med (must not regress legitimate deferred path — re-run `deferred_pub.sh` + `chaos_deadline.sh` after) |
| R6/H3 (doc) | ~10 min | none |
| R5 (flood test determinism) | ~1–2 hr | med (test-only, but root-causing 992/1000 if it's real loss could expand) |
| R6/H5, R7 (optional) | ~15 min each | low |

**Single biggest delivery risk this round:** the standing risk (backpressure/broker code outgrowing the budget) is **not** the threat this round — R1–R3 add ~15–25 lines total to a 374-line broker. The real risk is **R5 scope-expanding**: if the 992/1000 flood loss turns out to be a genuine fan-out/teardown bug rather than a harness timing race, diagnosing it could consume the round. Mitigate by timeboxing R5 to the relax-the-assertion fix (option a) first; only escalate to a `diagnose` pass if relaxed timing still drops records. Crucially, **none of R1–R6 require touching the scheduler**, so the proof is insulated regardless of how R5 goes — gate every code change behind a re-run of `chaos_deadline.sh` (must stay `missed=0 dup=0`) before it's considered done.

---

## 4. The single change that would most move the project this round

**R1 — add ~8 lines of `--at`/`--delay` validation that rejects non-numeric/empty/float and out-of-horizon values at the publisher control line, returning a nonzero rc + one-line reason to the publisher (and never staging the garbage record).**

Rationale: it closes the one finding that sits *adjacent to the proven claim* — the unvalidated data path that *derives* the very deadlines the scheduler is proven to fire race-free (synthesis §6). It simultaneously resolves F1 (silent server-side crash), F7 (unbounded far-future staging), and the actionable half of F6 (a now-meaningful nonzero `pub` rc). It was found independently by both adversarial-weighted personas, costs almost nothing in the line budget, and provably cannot disturb the scheduler (it only ever *removes* malformed records before they reach `deferred/`).

**Success metric (next round):** the scripter and flooder re-run their `--at`/`--delay` abuse probes and observe — (1) `pub` returns nonzero with a one-line reason on `--at xyz`, `--delay 1.5`, empty, and `--at 99999999999`; (2) `broker.log` contains **zero** `unbound variable` / `value too great for base` / `invalid arithmetic operator` lines across all probes; (3) `ls deferred/` shows **no** far-future (year-2286+) records after 20× far-future spam; and (4) `chaos_deadline.sh` still reports `missed=0 dup=0` over N≥5000 — proving the fix touched the input boundary and not the proof.