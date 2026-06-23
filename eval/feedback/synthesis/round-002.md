# shellmux — Evaluator Synthesis, Product Phase, Round 002

**Inputs:** 12 feedback objects (4 personas × 3 challenges — the exact round-001 pairs, for an
apples-to-apples delta). Phase: **product**. product_version `a82ae2a` (post-R1). All 12 sessions
`completed=true`. Satisfaction range 6–9, mean **8.08** (round-001 was 7.58). Adversarial-flooder
and the round-1 lowest-satisfaction pair (scripter × malformed-frames, was sat=4) weighted heavily.

> **Provenance note.** The round-2 aggregator agent hit a transient API error and did not emit this
> file; it was reconstructed from the 12 raw objects (all metrics recomputed directly from
> `friction_points[].is_new`, `satisfaction_score`, etc.) and cross-checked against the independently
> verified findings in this session's journal. The analyst (`analysis/round-002.md`) recomputed the
> same metrics from raw and agrees.

---

## 1. Headline verdict

**The one claim held again — and harder than round-1.** The adversarial-flooder re-ran the full gate
at `N_MAIN=5000` and reported `missed=0 dup=0 ontime=5000 total_fires=5000`, idle CPU **0.00%**, with
**all three must-fail controls failing on their predicted axis** (naivesleep missed=120/120,
drainfirst missed=120/120, nocommit dup=1770). The flooder's verdict: it set out to break the claim
and could not, and noted the three controls fail on three *distinct* axes a single rigged threshold
could not produce — pre-empting the "this is just sleep / rigged controls" dismissal. The flooder
*raised* its score 8→9. The round-1 input-boundary hardening (F1/F4/F7/H1) was re-probed by three
personas and **stays fixed**. No round-2 finding lands on the missed=0/dup=0 axis.

---

## 2. Friction patterns by frequency × severity

Sorted by severity × frequency. Severity = max any persona assigned. The naive `is_new` tally is
25 friction points, 21 self-tagged new (84%) — **but this is agent self-tagging inflation**: the
same line-splitting doc nit (N3) is independently re-reported and re-tagged-new by 6 of 12 sessions,
and the crash race is one finding split across 2 sessions. De-duplicated, there are **4 distinct
credible new findings, all doc-honesty or test-hygiene — 0 on the claim axis.**

| # | Pattern | Max sev | # sessions | Category | New? |
|---|---|---|---|---|---|
| **N3** | **"a payload is truncated at its first newline" is wrong — the broker LINE-SPLITS.** `printf 'a\nb\nc\n' \| pub` delivers THREE records (a, b, c), not one truncated to `a`. README L44 / DEMO L124 mis-state the contract; the *behavior* is fine (no loss, friendlier than truncation) — only the sentence is wrong. | low–med | **6 of 12** | claim-honesty / docs | yes (doc) |
| **N1** | **`flood_wedged.sh` F1 STILL flaky (H4 regressed).** Flooder saw run 2 of 3 FAIL — one *healthy* sub got 999/1000 at ~60s vs ~3s on passing runs. Round-1 closed H4 with "run 2–3×"; running exactly 2–3× falsifies it. The one round-1 item that regressed. | high | 1 (flooder) | correctness-proof (test) | persistent/regressed |
| **N2** | **Held-open streaming PUB silently drops the publisher's unflushed tail on early disconnect** — even with zero wedged subs (both healthy subs got an identical contiguous prefix then silence; a 0.5s→5s trailing hold fixes it). `drops_$pid` never ticks and `broker.log` stays empty → contradicts "lossy but **visible — never silent**" (DEMO L71) and "healthy subs get the ENTIRE flood at full speed." | high | 1 (flooder, 2 fps) | claim-honesty / error-handling | yes (doc) |
| **N4** | **`pub`/`sub` with missing required args exits 0 (prints usage), but `shellmux`/`shellmux boguscmd` exit 1** — a scripter can't distinguish "forgot args" from "bad subcommand" on `$?`. | low | 1 (scripter) | ergonomics | yes (tiny code) |
| P-H3 | **Overdue-deferred-on-restart races the reconnecting subscriber and is lost most of the time** (pi: 3/5 lost on a true power cut). This is the *defined face* of at-most-once-modulo-crash — correct behavior, documented in DEMO; the pi user wants it stated more prominently. | high (pi) | 1 | correctness/docs | punt (re-stated) |
| P-F5 | **No "subscriber-ready" signal** → scripts hardcode a sleep; a too-short sleep silently misses. Re-wished; compounds the crash-recovery path. | medium | 2 | ergonomics | punt (re-stated) |
| P-H5 | **Silent functional degradation at the memory ceiling** — could NOT be triggered in an 8GB container this round; re-stated as a known observability punt. | medium | 1 | observability | punt (re-stated) |
| P-acks | **No at-least-once / acks / replay; a healthy-broker offline subscriber permanently loses live publishes.** Confirmed honest (matches docs); scripter notes the docs frame no-retained-delivery mostly around the *crash* case, under-stating the *healthy* offline case. | low | 1 | missing-feature | punt (re-stated) |
| trivia | `pstree` absent in container; empty topic dirs not reaped by name; no pid→sub-name map; RSS double-counts shared pages (~14MB RSS vs sharing-aware ~5–6MB/sub). | low | 3 | ergonomics | low-value |

---

## 3. Claim-honesty audit

**SUPPORTED / re-confirmed (multiple personas, this round):**
- `missed=0 dup=0 over N=5000, ~0% idle CPU, 3 must-fail controls` — **re-confirmed live** by the
  flooder at the full N=5000 gate; controls fail on three distinct axes.
- Input-boundary rejection (R1): `--at xyz`, `--delay 1.5`, `--delay -5`, `--at 99999999999`,
  `'../../tmp/PWNED'`, `'.hidden'`, `a/b`, `''` all → rc=1 + clean reason, `deferred/` empty,
  `broker.log` free of unbound/arith/syntax errors. **Stays fixed.**
- `--delay N` fires on the second at ~0% CPU; crash_recovery 4/4 incl. its must-fail R2'.
- forget-on-death, fan-out reaches exactly live same-topic subs, state-is-the-filesystem.

**OVERSTATED / FALSE (flagged — all doc-honesty, fixed in this session's A1):**
| Claim | Location | Verdict | Evidence |
|---|---|---|---|
| "a payload is truncated at its first newline" | README L44, DEMO L124 | **FALSE** | broker line-splits → N records (verified by 6 sessions + maintainer re-run) |
| "healthy subs get the ENTIRE flood at full speed" | DEMO Beat 3 | **OVERSTATED** | held-open early-disconnect drops the tail; flood F1 flaky ~1/3 |
| "lossy, but visible — never silent" | DEMO Beat 3 | **OVERSTATED** | publisher-disconnect tail loss is silent (no drops, no log) |
| no-retained-delivery framed around crash only | README L46-49 | **INCOMPLETE** | healthy-broker offline subscriber also loses live publishes |

## 4. Proof status (product-leaning)

| Field | Value |
|---|---|
| Sessions touching the proof spine | 1 of 12 (flooder × prod-chaos-5000), + crash_recovery (pi) |
| Worst-case missed / dup (correct variant) | **0 / 0** |
| Max trials | **5000** (full gate) |
| ontime / total_fires | 5000 / 5000 |
| Idle CPU | 0.00% |
| Negative control present AND failing? | **YES — all three, on distinct axes** (naivesleep 120, drainfirst 120, nocommit dup=1770) |
| Proof theater? | **No** (flooder: "falsifiable, theater-free") |

**Verdict on the proof: HELD and STRENGTHENED.** An adversarial user set out to break it and could
not; the controls fail on three distinct axes; the maintainer's own out-of-band adversarial re-proof
(4 attacks, incl. an elapsed-distribution probe showing all 8000 fires at 0–5ms, never the poll
floor; idle = real `do_select` kernel block, 0 ticks) returned NOT-REFUTED at high confidence.

## 5. Tensions (not averaged away)

1. **Zero-config simplicity (operator/pi) vs. scriptable contract surface (scripter/flooder).**
   Unchanged from round-1; operators love the no-config FS-as-state, scripters want documented rc
   contracts and a ready-signal. The R1 input validation already added the contract surface that
   most mattered; remaining asks (ready-signal, acks) erode the "150 lines" elegance and stay punted.
2. **"Never silent" backpressure as a feature vs. the silent publisher-disconnect tail (N2).** The
   visible-loss `drops_$pid` promise is true for the wedged-subscriber ring path but NOT for the
   fast-publisher-then-exit path, where loss is inherent to fork-per-connection socat and silent.
   The honest resolution is the doc caveat (A1), not a delivered-vs-accepted counter on the data plane.

## 6. Round diff (vs round-001)

- **Resolved (re-confirmed fixed):** F1, F4, F7, H1 (input boundary) — re-probed by 3 personas, all
  reject cleanly. F2 (drops recipe), H2 (content-blind doc), ceiling-resource doc — all hold.
- **Persistent:** F5 (no ready-signal), H5 (mem-ceiling observability), no-acks/replay/persistence —
  all explicitly-punted non-goals, honestly documented, re-stated by personas.
- **New (credible, de-duplicated):** N3 (truncation→line-split doc), N2 (held-open disconnect silent
  tail, doc), N4 (arg-rc inconsistency). Plus low-value trivia.
- **Regressed:** **N1 — `flood_wedged.sh` F1 flake** (round-1 marked H4 "resolved 5×/5×"; flooder
  saw 1/3 fail). Test-hygiene only; the broker is 1000/1000 in isolation.
- **Novelty rate:** raw 84% (`is_new` self-tag, inflated by 6× re-report of N3). **De-duplicated
  credible novelty ≈ 16% by count; 0% on the claim axis** (zero new threats to missed=0/dup=0).
- **Avg satisfaction:** **7.58 → 8.08 (+0.50)**; the round-1 sat=4 outlier (malformed-frames) → 9.

## 7. Single sharpest unresolved threat to the one claim

**There is none on the claim axis.** The sharpest *adjacent* item is N1 — the `flood_wedged.sh` F1
flake — a *supporting* reliability claim (healthy subs stay real-time under a wedged flood) that is a
test-harness wall-clock-assertion race, not a fan-out defect (broker is 1000/1000 isolated). It could
embarrass a live demo but does not touch missed=0/dup=0. The doc-honesty items (N2/N3) are the last
place a skeptic draws blood, and they are wording, not behavior. The proof itself is unthreatened.
