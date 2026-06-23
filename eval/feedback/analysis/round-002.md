# shellmux — Analyst Roadmap, Product Phase, Round 002

**Inputs:** 12 round-2 feedback objects (4 personas × 3 challenges), product_version `a82ae2a`
(post-R1 fixes). No `synthesis/round-002.md` was produced — the aggregator returned `undefined`
for every metric because it read the wrong keys (objects carry `satisfaction_score`,
`friction_points[].is_new`, `claim_audit`, not `satisfaction`/`frictions`). I recomputed the
round directly from the raw objects.

**Recomputed round-2 metrics (analyst, from raw):**
- Completion: **12/12**.
- Mean satisfaction: **8.08** (up from round-001 7.58). Range 6–9; no sat=4 outlier this round
  (round-1's worst was scripter sat=4 on framing — now 9).
- Friction points: 25 total, 21 self-tagged `is_new=true` → a naive novelty rate of **84%**.
  **That number is an artifact of agent self-tagging and must not be taken at face value.** After
  de-duplication (the *same* "truncated at first newline" doc-wording nit is independently
  re-reported by 6 of 12 sessions and tagged new each time; the same crash-recovery race is one
  finding split across 2 sessions), the count of **genuinely distinct, credible, previously-unseen
  findings is 4** — and *all four are doc-honesty or test-hygiene, not correctness threats*. The
  true credible-novelty rate is **4/25 ≈ 16%** by friction count, or, weighting by what a skeptic
  would actually act on, **0 new credible threats to the one claim**.

---

## 0. Does this round threaten the one claim? — NO. Priority zero is unoccupied.

The headline claim **held again, and harder than round-1.** The adversarial-flooder re-ran the full
gate at `N_MAIN=5000` and reported `missed=0 dup=0 ontime=5000 total_fires=5000`, idle CPU
**0.00%**, with **all three must-fail controls failing on their predicted axis** (naivesleep
missed=120/120, drainfirst missed=120/120, nocommit dup=1770). The flooder's own verdict: *"I came
to break the headline claim and could not… the proof is falsifiable, theater-free."* It explicitly
pre-empted the standing dismissal ("this is just sleep and the controls are rigged") by noting the
three controls fail on three *distinct* axes a single rigged threshold could not produce. The
pi-embedded persona separately ran `crash_recovery.sh` 4/4 incl. its must-fail control R2'.

**No round-2 finding lands on the missed=0/dup=0 axis.** Every new finding is on the
free-from-fork perimeter (fan-out semantics, publisher-disconnect, drops accounting) or in
doc-wording. The round-1 input-boundary hardening (F1/F4/F7/H1) was re-probed by three personas
and **stays fixed**: `--at xyz`, `--delay 1.5`, `--delay -5`, `--at 99999999999`, `pub '../../tmp/PWNED'`,
`'.hidden'`, `a/b`, `''` all return rc=1 with a clean one-line reason, `deferred/` stays empty, and
`broker.log` is free of unbound/arithmetic/syntax errors. That is a clean **re-confirmation**, which
is exactly what a converging loop should look like.

---

## 1. What is genuinely new this round (de-duplicated, classified)

Four distinct credible findings. None is a correctness threat to the proof. Ordered by how much a
skeptic would weight them.

### N1 — `flood_wedged.sh` F1 is STILL flaky; round-1's "RESOLVED" is falsified (H4 regressed)
- **Severity:** high (flooder). **Classification:** `incremental` (test-only; does NOT touch broker/scheduler).
- **Finding:** Across 3 consecutive runs, **run 2 FAILED** — one *healthy* subscriber received
  999/1000 and took ~60s vs ~3s on the passing runs. Round-001 closed H4 as RESOLVED with the
  guidance "run it 2–3×"; running it exactly 2–3× falsifies that. This is the one round-1 item
  that **regressed** (the delta claimed "5× back-to-back all pass"; the flooder saw 1/3 fail).
- **Why it matters:** It is the *supporting* reliability claim one step from the proof, and the
  doc says healthy subs get "the ENTIRE flood at full speed" — contradicted ~1 of 3 runs. It could
  fail live in front of a judge. It does **not** touch missed=0/dup=0.
- **Root-cause direction (for the implementer, not the analyst to fix):** R1's fix reaped
  *client-side* orphans but the residual flake is a wall-clock *timing* assertion (`h>=FLOOD within
  DRAIN_CAP`) racing the wedged-write-timeout accounting — same diagnosis the R1 analyst gave under
  its R5. The honest property is **eventual completeness (no permanent starvation)**, not a 3s
  wall-clock deadline. R1 patched the orphan leak but left the timing assertion; that is why it
  re-surfaced. Fix the *assertion* (wait until counts stop advancing, then assert completeness),
  do not widen the broker's `WRITE_TIMEOUT`.

### N2 — Publisher-disconnect truncation on the held-open streaming path is SILENT (no drops, no log)
- **Severity:** high (flooder, 2 sessions). **Classification:** `doc-fix` (primary) + optional `incremental` (observability).
- **Finding:** Streaming 2000–3000 lines over a single held-open `socat` connection (the path DEMO
  calls "the volume path") and then disconnecting *before the broker finishes ingest/fan-out* drops
  the unflushed tail — **even with zero wedged subscribers** (two healthy subs each got an identical
  contiguous prefix m-1..~m-1144 of 2000, then silence). A 0.5s→5s trailing hold fixes it, proving
  it is a publisher-disconnect-vs-ingest race, not a fan-out defect. Crucially **`drops_$pid` never
  ticks and `broker.log` stays empty** — so this loss is *silent*, which contradicts the
  "lossy, but **visible — never silent**" promise (DEMO L71) and "healthy subs get the ENTIRE flood
  at full speed."
- **Why it matters:** Two doc claims are literally false for the natural fast-publisher-then-exit
  pattern. This is honesty, not correctness — the broker is behaving as a fork-per-connection
  socat acceptor must (when the source closes, in-flight unread bytes are gone). But the docs
  oversell it.
- **In-scope fix is the doc.** An accepted-vs-delivered counter (the flooder's suggestion) is an
  *optional* observability nicety — see §3, gated hard against budget/scope.

### N3 — "a payload is truncated at its first newline" is wrong; the broker LINE-SPLITS (multi-record)
- **Severity:** low–medium (reported by 6 of 12 sessions — the round's most *frequent* friction).
  **Classification:** `doc-fix`.
- **Finding:** `printf 'a\nb\nc\n' | pub … weather` delivers **three** records (a, b, c), not one
  record truncated to `a`. README L44 / DEMO L124 say "truncated at its first newline." The
  observable contract is **line-splitting: each newline-terminated line becomes its own record.**
  Multiple personas note the *behavior* is fine and friendlier than truncation — only the sentence
  is wrong. This is a one-word class of fix and is the single cheapest, highest-confidence,
  most-corroborated item in the round.

### N4 — `pub` with no args exits 0 (usage), but `shellmux` / `shellmux boguscmd` exit 1 — inconsistent
- **Severity:** low (scripter). **Classification:** `incremental` (tiny) or `doc-fix`.
- **Finding:** A scripter checking `$?` can't distinguish "I forgot required args" (rc=0 from
  `pub` printing usage) from "bad subcommand" (rc=1). R1 added the `usage()` guard for `--help`
  (rc=0, correct), but bare `pub`/`sub` with *missing required args* should signal an error (rc≠0),
  not success. ~2-line fix: `--help` → usage rc=0; missing-required-arg → usage-to-stderr rc=2.

**Everything else** in the 25 is either (a) an explicitly-punted item re-stated (no-acks/no-replay,
no subscriber-ready signal F5, ceiling-observability H5 — all tagged `is_new=false` or framed as
"known punt"), or (b) trivia (`pstree` not in the container; empty topic dirs not reaped; pid→sub
name mapping). These are low-value and several are scope-creep magnets — handled in §2.

---

## 2. Prioritized roadmap

Quick/cheap/high-confidence first. Nothing here touches `src/sched.sh`, the `mv` commit point,
the wake-FIFO discipline, or the bounded drainer core. Gate every code change behind a re-run of
`chaos_deadline.sh` (must stay `missed=0 dup=0`).

| # | Item | Class | Effort | Addresses |
|---|---|---|---|---|
| **A1** | **Doc truth-up bundle** — (i) replace "truncated at its first newline" with "each newline-terminated line is delivered as its own record; an unterminated tail waits for a newline; NUL is stripped" (README L44, DEMO L124); (ii) qualify "healthy subs get the ENTIRE flood at full speed" and "lossy but visible — never silent" with the held-open-disconnect caveat: *"a publisher that closes before the broker finishes ingesting an in-flight burst loses the unflushed tail silently — hold the connection briefly after the last write, or treat fast-disconnect loss as expected"*; (iii) move the healthy-broker offline-subscriber loss next to the crash qualifier (scripter: docs frame no-retained-delivery only around crash). | `doc-fix` | ~30 min | N2, N3, scripter at-least-once nit |
| **A2** | **Make `flood_wedged.sh` F1 deterministic** — convert the wall-clock `h>=FLOOD within DRAIN_CAP` assertion into an eventual-completeness assertion (poll until healthy-sub counts stop advancing, then assert completeness; keep a generous absolute ceiling only as a hang-guard). Do **not** touch the broker. | `incremental` (test) | ~1–2 hr | N1 (H4 regression) |
| **A3** | **Arg-rc consistency** — bare `pub`/`sub` with missing required args prints usage to stderr and exits 2; `--help` stays rc=0. | `incremental` (~2 lines) | ~15 min | N4 |
| **A4 (optional)** | **DEMO teardown line** — add the `kill $BPID; pkill -P $BPID` teardown to DEMO Beat 2 so copy-paste doesn't leak a broker/socat/sub per run (scripter onboarding nit). | `doc-fix` | ~5 min | scripter fp-004 |

**Single biggest delivery risk this round:** **A2 scope-expanding.** If the residual flood flake
is genuine *loss* (999/1000) rather than slowness, an implementer could be tempted to chase it into
the broker's fan-out/teardown path. The evidence (the 5s-hold fixes N2; flood_wedged passes 2/3 and
4/4 on the *sibling* wedged metric) points to a harness-timing/teardown race, not a fan-out
correctness defect. **Timebox A2 to the assertion-relaxation fix; escalate to a `diagnose` pass
only if eventual-completeness still loses records.** None of A1–A4 require touching the scheduler,
so the proof is insulated regardless.

---

## 3. What NOT to do — punt list (protect scope and the framing)

- **Do NOT add an accepted-vs-delivered counter / publisher-side flush-ack for N2.** It is tempting
  ("make the silent loss visible"), but a delivered counter on the held-open burst path means
  threading per-record accounting through the ingest path — code growth on the data plane for a
  failure mode that is *inherent* to fork-per-connection socat (source closes → unread bytes gone).
  The honest fix is the doc caveat (A1.ii). The broker already grew 374→452 lines since R1; do not
  spend more on a nice-to-have.
- **Do NOT build retained delivery / replay / persistence** for the overdue-on-restart race or the
  offline-subscriber loss. The pi-embedded "overdue fire races the reconnecting sub (3/5 lost)" and
  the scripter "offline sub permanently loses live publishes" are the **exact, defined face of
  at-most-once-modulo-crash and no-retained-delivery**. They are correct behavior; document the
  *healthy-broker* offline case too (A1.iii). Building retain/replay is the headline punted feature.
- **Do NOT add acks / at-least-once / retry.** Re-stated again this round (scripter, `is_new=false`).
  Still out of scope.
- **Do NOT add a subscriber-ready handshake (F5).** Re-wished again; still a punt. A readiness
  signal is real ergonomic surface but it is not a correctness bug and it grows the protocol.
- **Do NOT add memory-ceiling admission control / backpressure-on-sub-count (H5).** Re-stated as a
  known punt; the persona could not even trigger it in an 8GB container this round. At most a
  one-line `broker.log` entry on a failed `mkfifo`/registration — and even that is optional, not
  this round's priority.
- **Do NOT reap empty topic dirs, add pid→sub-name mapping, or install pstree.** Trivia; bounded
  growth; not worth code on the data plane.
- **Do NOT touch `src/sched.sh`, the `mv` commit point, the wake-FIFO `exec 4>` discipline, or the
  bounded drainer loop** for anything above. Guard the core.
- **RSS-vs-MemAvailable ceiling number (pi sat=9 nit):** at most a one-word doc qualifier
  ("RSS double-counts shared pages; sharing-aware delta is ~5–6 MB/sub") — fold into A1 only if
  trivially cheap; otherwise leave it.

---

## 4. DoD #5 convergence call — **CONVERGED (correctness). Ship the proof.**

**Call: the evaluator loop has converged on the dimension that defines the project — the one
falsifiable claim — across round-001 and round-002.**

Justification against the DoD #5 bar (novelty < ~10% for two rounds AND no NEW credible threat to
missed=0/dup=0):

1. **Two-round novelty trend on credible threats to the claim:** round-001 surfaced exactly one
   *adjacent* class (the unvalidated input boundary that derives deadlines — F1/F7/H1) plus a
   test-hygiene bug (H4). All were fixed at the source with tests + must-fail controls. **Round-002
   re-probed all of them and re-confirmed them fixed**, and found **zero new findings that touch
   the missed=0/dup=0/zero-idle-CPU axis.** New *credible* findings this round = 4, all doc-honesty
   or test-hygiene. New credible *threats to the one claim* = **0**. By the metric that matters
   (threats to the proven property), novelty went 1→0 — well under 10% for two rounds.

2. **The raw 84% `is_new` rate does NOT block convergence.** It is agent self-tagging inflation:
   6 sessions independently re-report the same line-splitting doc nit and each tags it new; the
   crash race is one finding double-counted. De-duplicated credible novelty is ~16% by count and
   **0% on the claim axis.** DoD #5's "novelty rate" is about *credible new threats*, not raw
   friction-string uniqueness. The substance re-confirms; only the surface wording multiplies.

3. **The proof itself strengthened, not just held:** an adversarial user who set out to break it
   could not, the three controls each failed on a distinct axis (pre-empting the "rigged controls"
   dismissal), and mean satisfaction rose 7.58→8.08 with the round-1 sat=4 outlier resolved to 9.

**One regression to fix before "ship it" is unqualified (A2):** the `flood_wedged.sh` F1 flake
(N1) is a *test-hygiene* regression of a round-1 claim — it does not threaten the proof, but it
contradicts a DoD demo criterion ("two healthy subs stay real-time") and could embarrass a live
run. Convergence is on the **claim**; the remaining work (A1–A3) is perimeter polish, with A2 the
only item with a real (test-only) bug behind it.

**Verdict: CONVERGED on correctness. The loop has done its job — it found the one adjacent threat
in R1, it was fixed, and R2 re-confirmed with no new claim-level threat. Further product rounds
would mostly re-report doc-wording and re-state punts (diminishing returns). Park the loop after
the A1–A3 perimeter polish lands; do not run a round-003 expecting new correctness signal.**

---

## 5. The single change that would most move the project this round

**A1 — the doc truth-up bundle (N3 + N2 + N3-adjacent).**

Rationale: it is the cheapest, highest-confidence, most-corroborated work (N3 alone was reported by
half the sessions), and it closes the *only* category that recurred this round — claim-honesty.
After R1 hardened the input boundary, doc-honesty is the last place a skeptic draws blood: the
broker line-splits but the doc says "truncates," and it can drop a fast publisher's tail silently
while the doc promises "never silent." Aligning the words to the true behavior converts the round's
dominant friction (claim-audit "overstated" verdicts) into "supported," which is precisely the
signal a converged loop wants on its final pass.

*If "most move the project" is read as the only item with a real bug behind it rather than the
highest-volume one, then* **A2** *(deterministic flood test)* *is the runner-up — it is the one
round-2 finding that is an actual regression, not just a wording gap. Do A1 first (cheap, closes
the most friction), A2 second (closes the one regression).*

**Success metric (next round, if run):** (1) the claim-audit framing verdicts that read
"overstated" this round (truncation, "ENTIRE flood at full speed," "never silent") read
"supported" against the corrected docs; (2) `flood_wedged.sh` passes 5/5 back-to-back with stable
elapsed and no EXIT=137; (3) `chaos_deadline.sh` still reports `missed=0 dup=0` over N≥5000 —
proving every change stayed off the proof axis.
