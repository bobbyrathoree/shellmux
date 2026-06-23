I have the aggregator instructions. Now I'll synthesize all 12 feedback objects into the round-001 synthesis.

Key observations across the 12 objects: this is the **product phase**, satisfaction ranges 4-9 (avg ~7.4), all 12 completed. Only one challenge (prod-chaos-5000) actually exercised the headline proof spine. Let me build the synthesis.

# shellmux — Evaluator Synthesis, Product Phase, Round 001

**Inputs:** 12 feedback objects (4 personas × 3 challenges each: broker-operator, scripter-integrator, adversarial-flooder, pi-embedded-user). Phase: **product**. No prior round (this is round 1; no diff section). All 12 sessions `completed=true`. Satisfaction range 4–9, mean ≈ 7.4. Adversarial-flooder and the lowest-satisfaction persona (scripter-integrator, sat=4 on malformed-frames) are weighted most heavily per the rules.

---

## 1. Headline verdict

**The one claim is credible and the proof ran clean — verified live by the adversarial persona, not just asserted by the author.** The only session that actually exercised the headline spine (adversarial-flooder × prod-chaos-5000) ran `tests/chaos_deadline.sh` at **N_MAIN=5000** and observed **missed=0 dup=0 ontime=5000 total_fires=5000**, exit 0, ~99s, with **idle CPU sampled at 0.00%** over 5s. Critically, **all three must-fail negative controls failed as required** — naivesleep missed=120, drainfirst missed=120, nocommit dup=1770 — so this is a working falsifier, not proof theater. The flooder independently attacked the live broker (a `--delay 3` fire landed *exactly once* while 40 immediate publishes hammered the same topic inside the delay window) and the result held.

**But the proof spine was exercised by exactly one of twelve sessions.** Every other challenge touched only the "free-from-fork" perimeter (fan-out, isolation, introspection, crash-recovery, ceiling) or adjacent single-trial timing — and several of those drew real blood at the *input boundary* and in *honesty-of-docs*, which is where the remaining threats live. The contribution is earned; the surrounding contract is narrower and rougher than the docs claim.

---

## 2. Friction patterns by frequency × severity

Sorted by severity × frequency across personas. Severity is the **max** any persona assigned.

| # | Pattern | Max sev | # personas | Categories | Notes |
|---|---|---|---|---|---|
| **F1** | **`--at`/`--delay` input is unvalidated → silent server-side handler crash.** Non-numeric/empty/float `--at` or `--delay` crashes the per-connection handler with raw bash errors (`line 175: xyz: unbound variable`, `value too great for base`, `invalid arithmetic operator`) + `socat E waitpid child exited status 1`, while the **publisher gets rc=0**. Silent server-side failure, message dropped, no scriptable signal. | **medium** | 2 (scripter, flooder) — both adversarial-weighted | input-validation | Same bug, `src/shellmux:175`, found independently by the two hardest-pushing personas. Broker survives; isolation contains it. |
| **F2** | **`drops_<pid>` counter is created lazily (only on first drop) → literal documented `cat drops_*` errors on a healthy topic.** `cat $D/topics/<t>/drops_*` (DEMO.md Beat 4) → `No such file or directory`, exit 1, when nothing has dropped. | medium | 4 (operator, scripter, flooder, + implied) | docs / introspection | Most *frequent* friction in the round. All who looked for drops on a healthy topic hit it. Low individual sev but universal. |
| **F3** | **`pub` blocks ~1s per call (linger) + forks whole CLI/socat per message → serial flood ≈ 1 msg/s; the documented manual flood recipe does not work as written.** 200 serial pubs took 203s. Following DEMO.md Beat 3 literally ("loop pub, watch drops tick up") yields ~1 msg/s, the wedged buffer never fills, and **no drops file ever appears**. | medium | 3 (scripter, flooder×emphasis, operator) | performance / usability / docs | Flooder calls this a "usability landmine"; caused multiple exit-137 host-kills (root-caused as harness, not broker, leak). |
| **F4** | **Subcommand `--help` / bad-arg paths crash with `set -u` `$2`/`$1: unbound variable` instead of usage.** `sub --help`→`line 323`, `pub --help`→`line 342`, `serve <badarg>`→`line 248`. | medium | 2 (scripter, flooder) | CLI / robustness | Ugly first impression for anyone probing the CLI surface. |
| **F5** | **No "subscriber ready" signal → scripts must hardcode sleeps; a too-short sleep silently drops the message with the exact 0-byte signature of a correct off-topic miss.** | low | 2 (pi-embedded, operator-adjacent) | usability | Pi user flags this as dangerous on slow hardware: a timing bug is indistinguishable from correct behavior. |
| **F6** | **`pub` exit-code contract is undocumented.** Observed rc=0 on happy path, empty-topic, and vanished-subscriber, but no doc states whether/when nonzero ever returns. | low | 1 (scripter) | docs / contract | A scripter cannot branch on undocumented codes. |
| **F7** | **No upper bound on `--at` → unbounded far-future deferred staging.** `--at 99999999999` stages files dated ~year 2286/5138 that never fire, never GC by deadline; 20× spam → 20 persistent files. Cheap unbounded-growth vector (compounds with F1's silent rc=0). | low | 2 (scripter, flooder) | resource-exhaustion / input-validation | |
| **F8** | **Honesty lives only in DEMO.md prose, not in README top-matter or the CLI itself.** README L17 lists "crash recovery" as a built feature *before* the "at-most-once-modulo-crash" qualifier (which appears only in DEMO.md L117); `--help` says nothing about delivery semantics. | low–med | 2 (scripter, pi-embedded) | docs / discoverability | A fast README reader could over-read "recovery" as durability. |
| **F9** | **No documented way for an operator to manually wedge a sub or measure idle CPU.** SIGSTOP/raw-socat-sleep readers failed to provoke overflow; `~0% CPU` claim is true but the user must hand-roll a `/proc/<sched>/stat` tick-differ to verify it. | low | 2 (operator, flooder) | observability | Trust gap: claim is true but not turnkey-verifiable. |

### High-severity friction (called out separately — these are sev=high from individual personas)

| Pattern | Sev | Persona(s) | Category | Status |
|---|---|---|---|---|
| **H1 — Topic names are unsanitized path components → publisher-controlled `mkdir` anywhere.** `pub <state> '../../../../tmp/SHELLMUX_PWNED'` exits 0 and creates a dir **outside the state dir** (confirmed `/tmp/SHELLMUX_PWNED_1 EXISTS`). `../escape` lands a dir in the state root; whitespace word-splits (`'with space'`→`with`); `;` survives into dir names. | **high** | adversarial-flooder | input-validation / **security** | New, unmitigated. A directory-traversal/`mkdir`-anywhere primitive from untrusted topic input. No crash, but no rejection. |
| **H2 — "content-blind" / "length-prefix framing" is FALSE; delivery is newline-TERMINATED line read.** NUL bytes stripped wholesale (64→0 on a ramp), arbitrary binary mangled (16KB→16006, *different multiset*, real loss not reorder), and a payload with **no trailing newline delivers ZERO bytes** (15B→recv=0). | **high** | scripter-integrator (sat=4) | framing / data-integrity | Directly contradicts README L3 / DEMO L3 "content-blind" and the challenge's "binary/NUL deliver intact under length-prefix framing" criterion. The honest contract is "newline-delimited NUL-free text only." |
| **H3 — Overdue deferred message on reboot is silently lost (the common embedded power-off case).** If the box is off *longer than the delay*, the deadline is already past at boot; the re-armed scheduler fires the overdue record on its first scan **before any subscriber reconnects**, with no retained delivery → message gone. Measured twice: deferred-remaining→0 (consumed), fire-count=0 over 10s on a fresh sub. | **high** | pi-embedded-user | correctness / docs | Technically inside "at-most-once-modulo-crash," but undocumented — the one lossy crash case a Pi user will actually hit is the one not called out. |
| **H4 — Healthy-subscriber real-time delivery under wedged flood is FLAKY; the author's own gating test eats itself.** Identical command, identical code, two runs: Run 1 `FAIL F1` (healthy subs 992/1000 over ~60s, exit 1); Run 2 `ok F1` (1000/1000 in ~3s, exit 0). A 20× latency swing and 8 lost messages on a coin-flip. | **high** | adversarial-flooder | correctness / reliability | `tests/flood_wedged.sh` non-determinism; could fail live in front of a judge. (Operator independently saw the *same* suite hang >120s / EXIT=137 on cold start before passing on retry — corroborating instability.) |
| **H5 — Silent functional degradation under memory pressure at the subscriber ceiling.** New-subscriber fan-out silently stops delivering (empty output) once mem_avail fell below ~1GB at ~2500 subs, with **nothing** in broker.log or sub_err.log and broker_alive=yes. No drops counter, no log line, no nonzero exit. | **high** | pi-embedded-user | observability | "On an air-gapped boat I would not know my sensor bus had degraded." |

---

## 3. Claim-honesty audit

Weighting adversarial personas (flooder) and lowest-satisfaction (scripter sat=4) most heavily.

**SUPPORTED / TRUE (verified live, multiple personas):**
- `missed=0 dup=0 over N≥5000, ~0% idle CPU, must-fail controls` (README L13-18) — **SUPPORTED**, flooder live-verified at N=5000, controls all failed as required.
- `--delay 5 lands on the second` — SUPPORTED (operator: 5.031/5.034/5.038s, ~31-38ms, matches "~40ms wake").
- `~0% idle CPU during the wait / no timer wheel` — SUPPORTED, confirmed independently 4+ times via `/proc/<sched>/stat` (0 ticks) and `top`.
- `single mv commit point / fire-once` (single-trial face) — SUPPORTED as observed (deferred/ empties on fire); operators correctly note one trial is not the chaos proof.
- `stranded-FIFO bad state is impossible` — SUPPORTED (operator, scripter: publish to vanished sub = rc=0, no error).
- `forget-on-death from fork` — SUPPORTED (FIFO count 2→1 within ~2s, multiple personas).
- `writers do not accumulate per-message under wedged flood` (the `> $f &` bug is gone) — **SUPPORTED**, flooder proved it: descendants track in-flight concurrency (plateau 33@conc10, 96@conc40, recede to baseline 13), never per-message.
- `at-most-once-modulo-crash` (the honesty disclaimer itself) — TRUE/honest (scripter: every replay/ack/retain probe came back negative as documented; "no place on disk for a missed message to hide").
- `state IS the filesystem / no admin protocol` — TRUE, universally.

**OVERSTATED / FALSE / MISLEADING (flagged):**

| Claim | Doc location | Verdict | Persona | Evidence |
|---|---|---|---|---|
| "**content-blind** topic pub/sub" / "length-prefix framing / torn write detected" | README L3, DEMO L3 | **FALSE / MISLEADING** | scripter (sat=4, adversarial) | NUL stripped (64→0), binary mangled (multiset differs), unterminated payload → 0 bytes. The host doesn't just *see* every byte, it *eats* some. Honest contract is "newline-delimited NUL-free text only." |
| "the two healthy subscribers get the **ENTIRE flood at full speed**" | DEMO Beat 3 (L71-74) | **CONTRADICTED / OVERCLAIM** | flooder | Author's own `flood_wedged.sh` F1 fails ~half the time (992/1000). |
| `bash tests/flood_wedged.sh  # ~5s` | DEMO Beat 3 | **MISLEADING** | operator | Drops *are* visible, but the suite hung >120s (EXIT=137) on cold start; large run-to-run variance vs the "~5s" claim. |
| "20 subscribers… **ceiling = fd/process limits**" | DEMO B3 (L100-102) | **PARTIALLY FALSE** | pi-embedded | 110-procs-for-20-subs figure is accurate (5 procs/sub), but the *limiting resource* is **RAM (~2.4MB/sub)**, not fd (broker holds ~4 fds, ulimit 1M) or pid_max. On a 512MB Pi the wall bites at ~100-150 subs, not "thousands." Doc never states the actual number. |
| README L17 "crash recovery … implemented and tested" (no at-most-once qualifier nearby) | README L17 vs DEMO L117 | **COULD OVERPROMISE** | scripter, pi-embedded | Strong word "recovery" precedes the qualifier, which lives only in DEMO. Behavior is honest *once you read DEMO*. |
| "**a homelab event bus**" / fan-out reaches every live sub and nobody else | README L33-34 | SUPPORTED | operator | 2/3 subs received, off-topic 0 bytes, 5/5 reproducible. |

**Cosmetic:** CLAUDE.md/spec mission prose uses uppercase `SUB`/`PUB`; the actual CLI verbs are lowercase. Runnable docs (DEMO.md) are correct (operator, low sev).

*(Note: no `citation_checks` or `dismissal_survived` fields were present in any of the 12 product-phase objects — those are spec-phase fields. The `terminalphone.sh:1570` "bug-not-fix" framing was not re-audited this round, but the `> $f &` writer-accumulation leak it describes was confirmed **gone** live by the flooder, which is the behavioral corollary.)*

---

## 4. Proof status (product-leaning)

| Field | Value |
|---|---|
| Challenges that touched the deadline proof spine | **1 of 12** (adversarial-flooder × prod-chaos-5000) |
| Worst-case `missed` observed (correct variant) | **0** |
| Worst-case `dup` observed (correct variant) | **0** |
| Max trials run | **5000** (N_MAIN=5000, full gate — "not a 200-trial fig leaf") |
| `ontime` / `total_fires` | 5000 / 5000 |
| Idle CPU | 0.00% over 5s sample |
| Race window clear? | Yes — the harness instruments the pause between `next=MIN(...)` and `read -t`; flooder additionally reproduced it live (40 concurrent pubs in a `--delay 3` window → fired exactly once). |
| **Negative control present AND failing?** | **YES — all three.** naivesleep missed=120, drainfirst missed=120, nocommit dup=1770. The harness demonstrably catches lost-wakeup ordering, blind-sleep, and no-commit-point variants. |
| Proof theater? | **No** (flooder's explicit judgment: "the control is a working falsifier, not decorative"). |
| Independent corroboration (single-trial face) | broker-operator: `--delay 1/5/8` and `--at` all fired on time at ~0% CPU. pi-embedded: future-deadline deferred survives kill -9, re-arms, fires exactly once at 0.00% CPU; `crash_recovery.sh` 4/4 with its own must-fail control R2' failing as required. scripter: deferred survives kill -9, fires exactly once (occurrences:1). |

**Verdict on the proof:** This is a genuine, falsifiable pass on both required conditions (correct variant 0/0 over ≥5000; broken variants demonstrably miss/dup). It is **not** a clean-pass-with-a-dead-control. The crash path *also* carries a working negative control (R2'). This is the strongest part of the project and it holds.

**Caveat to record:** the *supporting* reliability claim around the proof's neighborhood — healthy-sub real-time delivery under flood (H4) — is flaky in the author's own test, and the *manual* flood recipe (F3) doesn't reproduce drops as documented. These don't touch the missed=0/dup=0 axis, but they sit one step away from it and could embarrass a live demo.

---

## 5. Tensions (not averaged away)

1. **Zero-config simplicity (operator/Pi) vs. scriptable contract surface (scripter/flooder).** The operator and Pi user *love* that `serve` takes a dir and a socket with no config, no registry, no service unit, and that "state IS the filesystem." The scripter and flooder want the opposite: a documented `pub` exit-code contract (F6), a `--help` that prints delivery semantics, input validation/rejection on `--at` (F1), topic-name sanitization (H1), and a `--no-linger`/batch publish path (F3). More contract surface erodes the "150 lines, no admin protocol" elegance the operators came for.

2. **"Content-blind" as a marketing virtue (operator/Pi happy with byte-exact text) vs. literal binary-safety (scripter).** Operators round-tripped punctuation-heavy text byte-for-byte and were delighted. The scripter took "content-blind" at its word, fed it NUL/binary/unterminated payloads, and lost data silently (H2). Same claim, opposite verdict depending on whether you read it as "doesn't parse your text" or "preserves arbitrary bytes."

3. **Lossy-but-visible backpressure as a feature (scripter wants the visible loss signal) vs. silent-loss-is-dangerous (Pi user).** The scripter explicitly praised counted-and-dropped (`drops_*=354`) over hidden buffering — "the integrator's exact wish." The Pi user, in the *opposite* corner, hit silent loss at the memory ceiling (H5) and on overdue-reboot (H3) where there is no drops counter, no log line — and calls silent degradation "the worst possible failure mode" for an air-gapped box. The disagreement is really about *which* loss is visible: backpressure drops are counted; ceiling/overdue drops are not.

4. **`pub` linger as correctness vs. as throughput tax.** The ~1s linger guarantees delivery on the happy path (operators rely on it), but makes flooding ~1 msg/s and makes the documented flood/abuse workflows painful (flooder, scripter F3). One persona's safety margin is another's throughput ceiling.

---

## 6. Single sharpest unresolved threat to the one claim

**The proof spine itself is solid and falsifiable — the sharpest unresolved threat is not *inside* the chaos gate but *adjacent* to it, at the unvalidated input boundary that feeds the same scheduler: a non-numeric/out-of-range `--at` is accepted by the publisher (rc=0) yet crashes the per-connection handler server-side and silently drops the message (F1), while far-future `--at` parks unbounded never-firing records in `deferred/` (F7) — both found independently by the two most adversarial personas.** The chaos test proves the scheduler fires *legitimate, well-formed* deadlines race-free; it does **not** exercise what happens when the data that *derives* those deadlines is hostile. The one claim is "data-derived deadline scheduler, race-free against concurrent publishes" — and the data path that derives the deadline has no validation, fails silently, and can be poisoned with garbage that either crashes a handler or accumulates forever. A skeptic's next move is precisely there: feed the data-derived scheduler bad data and watch the "proven" property degrade into a silent server-side crash that the 5000-trial harness never sees because the harness only ever stages well-formed records.