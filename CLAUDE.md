# shellmux — agent onboarding brief

You are opening a pristine repo. This file is your entry point. Read it fully before doing anything.

## Mission (one paragraph)

shellmux is a content-blind topic pub/sub broker built from `socat`-fork, FIFOs, and `flock`,
in roughly 150 lines of shell. Two of the three things people pay clustered brokers for —
per-subscriber isolation and forget-on-death — fall out of fork-per-connection *for free* and are
not the contribution. The contribution is **one hard thing, proven**: a *data-derived deadline
scheduler* that fires timed (`--at` / `--delay`) messages **race-free against concurrent
publishes, with zero idle CPU and no timer wheel**, in a language with no threads, no atomics, and
only advisory locks. Everything else is honestly a refactor of prior art.

### The single falsifiable claim this project must prove

> Over **N ≥ 5000** adversarial-timing trials — each landing a publish inside the exact window
> between "scheduler computed `next = MIN(run_at)`" and "scheduler entered the blocking
> `read -t`" — shellmux fires **0 missed and 0 duplicate** deadline deliveries, while idle CPU
> stays ~0%.

If that number is not 0/0 over 5000 trials, the project has failed its reason to exist. Do not
dress up the easy parts (fan-out, isolation) as the achievement. They are free.

## Start here (read order)

1. `docs/spec.md` — **canonical source of truth.** What/why, hardened. Do not contradict it.
2. `docs/design.md` — how it works: components, control/data flow, borrowed-mechanism adaptation.
3. `docs/plan.md` — milestone sequence (M0 first), tests, the negative control, effort, risk.
4. `docs/prior-art.md` — how we differ, and the "this is just X" dismissals you must survive.
5. `docs/_redteam-verdict.md` — the adversarial Linus-persona verdict. Internalize its patches.
6. `docs/_partner-plan.md` — a partner sketch (folded into `plan.md`; spec wins on conflicts).
7. `eval/README.md` — the phase-aware evaluator loop (scaffolded, not yet run).

## M0 — the riskiest experiment, as your literal first task

**Build the deadline scheduler and its chaos test BEFORE the broker.** The broker exists only to
exercise this. Do not write the socat acceptor first.

- **Create:** `src/sched.sh` (standalone scheduler loop) and `tests/chaos_deadline.sh` (the harness).
- **Scheduler discipline (non-negotiable, from honker):**
  1. State lives on disk as `deferred/<run_at>.<seq>` files. Nothing in memory is authoritative.
  2. Each loop: `next = MIN(run_at)` over filenames, then `read -t $((min(idle_poll, next-now)))`
     on a long-lived wake-FIFO held open with `exec 4>`.
  3. A delayed publish stages the file **first**, *then* pokes the wake-FIFO (stage-then-poke;
     the reverse loses the wake — see honker `lib.rs:1105-1106`).
  4. Every wake (poke OR timeout) triggers a **full `deferred/` re-scan**. A dropped/spurious
     wake costs one directory scan, never a missed message.
  5. The `idle_poll` timeout is the correctness floor: even if *every* wake is lost, the next poll
     rescans and fires. The wake only improves *latency*.
  6. The single commit point per due record is the `mv` of the deferred file into the fan-out
     path. Fire-once is the property of that `mv`.
- **The harness must inject the race:** instrument the scheduler so a test hook can pause it
  between `next=MIN(...)` and `read -t`, fire a publish whose deadline is *now* into that pause,
  then release. Repeat N ≥ 5000 with jittered timing.
- **Pass/fail:** the harness prints `missed=0 dup=0` over N ≥ 5000 trials AND a `top`/`ps` sample
  during an idle stretch shows ~0% scheduler CPU. **Any** missed or duplicate fire = FAIL.
- **Negative control (mandatory):** the harness must also run a *deliberately broken* scheduler
  variant (poke-then-stage, OR sleep-without-rescan) and assert it **DOES** miss/dup fires. A test
  that cannot fail the wrong implementation proves nothing. See `docs/plan.md`.

Only after 0/0 over 5000 is green do you move to M1+ (acceptor, handler, fan-out, drainer).

## Build / run (host is darwin/arm64 — read this carefully)

The host is macOS/arm64. **The toolchain is pinned to a Linux container** for FIFO + `flock` +
fractional-`read -t` consistency. macOS ships bash 3.2 (no fractional `read -t`, ~1s resolution)
and BSD coreutils (`timeout` absent, `flock` absent) — do NOT develop or measure on bare macOS.

```bash
# Build the dev container (do this in-container work — NOT on bare macOS):
docker build -t shellmux-dev .
# Run with a TTY; nothing privileged is required (plain UNIX FIFOs/flock):
docker run --rm -it -v "$PWD:/work" -w /work shellmux-dev bash
# Inside the container:
bash tests/chaos_deadline.sh        # M0 gate
```

Toolchain caveats:
- **bash ≥ 4** is required for fractional `read -t` (sub-100ms wake latency). On bash 3 / dash the
  resolution is ~1s — and that is *faithful*, because honker's reference itself uses
  `Duration::from_secs` (whole seconds). State the platform-qualified number; never claim better.
- Real dependency set is **bash≥4 + coreutils (`mkfifo`, `timeout`) + util-linux (`flock`) +
  `socat`** — not "coreutils + socat." The zero-deps claim is false; do not make it.
- The eventual demo target is a literal $5 Raspberry Pi (Linux, the real dep set). Benchmarks must
  be stated on that hardware, not hand-waved as "hundreds."

## Borrowed mechanisms (study these exact files/symbols)

Every line below was verified to exist as cited. Read the source before re-expressing it in shell.

| shellmux mechanism | Borrowed from — concrete source file:symbol | Notes / verified |
|---|---|---|
| Next-deadline = `MIN(run_at)` over pending state | `honker/honker-core/src/honker_ops.rs:536-558` `queue_next_claim_at` (`SELECT COALESCE(MIN(deadline),0)`) | We re-express the SQL over `deferred/<run_at>.<seq>` filenames. ✓ verified |
| Block-until-deadline, recv-then-drain | `honker/packages/honker-rs/src/lib.rs:828` (`recv_until` call) + `:1558-1582` (impl) | `read -t $((min(idle,next-now)))` on wake-FIFO. ✓ verified |
| Whole-second resolution is correct, not a downgrade | `honker/packages/honker-rs/src/lib.rs:1572` `Duration::from_secs((unix_sec-now))` | Justifies our ~1s floor on bash3/dash. ✓ verified |
| Stage-then-poke ordering rule | `honker/packages/honker-rs/src/lib.rs:1105-1106` comment: *"recv first, then drain — the opposite order would lose a wakeup"* | We adopt as "stage the file, **then** poke the wake-FIFO." ✓ verified |
| Subscriber forget-on-death (leaf prune) | `honker/honker-core/src/lib.rs:957-960` `list.retain(... Disconnected => false)` | Maps to our subscriber `EXIT`-trap unlink + `[ -p ]` skip. ✓ verified |
| Broker shutdown = fail-loud-for-all | `honker/honker-core/src/lib.rs:908-916` `WatcherDeathGuard::drop` (clears *all* senders) | Maps to **broker** `pkill -P`, NOT a single subscriber death. (Draft inverted this — keep it correct.) ✓ verified |
| socat-fork acceptor shape | `terminalphone/terminalphone.sh:1206`, `:1350` (`socat TCP-LISTEN:...,reuseaddr`) | terminalphone uses `SYSTEM:`; shellmux uses `EXEC:` + `,fork`. Same model. ✓ verified |
| Per-client FIFO mailbox + drainer + keepalive | `terminalphone.sh:1518-1520` (`mkfifo out_$ID.fifo`), `:1540-1544` (drainer `while read`), `:1546` (`exec 3>`) | ✓ verified |
| `[ -p ]`-guarded fan-out loop | `terminalphone.sh:1567-1572` (`for f in out_*.fifo; [ -p "$f" ] || continue`) | ✓ verified |
| **The BUG we replace (not cite as the fix)** | `terminalphone.sh:1570` `printf '%s\n' "$line" > "$f" 2>/dev/null &` | A *blocking* write backgrounded with `&` → one stuck process per message to a wedged sub = fd/process leak. We replace it with a bounded ring drainer. ✓ verified |
| flock'd shared counters | `terminalphone.sh:1585-1590` (`( flock 9; ... ) 9>...lock`) | ✓ verified |
| Cleanup of forked handlers | `terminalphone.sh:1674` `pkill -P "$socat_pid"` | ✓ verified |
| Persistent fd binding pattern | `terminalphone.sh:1886-1887` (`exec 3<recv; exec 4>send`) | Model for our `exec 4>` wake-FIFO holder. ✓ verified |

**Honesty note for the agent:** terminalphone does its FIFO unlink at the *end of the handler
script* (`:1590`), not via an explicit `trap ... EXIT`. shellmux hardens that into an `EXIT` trap
so cleanup fires on signal/crash too — borrowed *in spirit*, improved in fact. Say so; don't cite
a trap line that isn't there.

## House rules

1. **One falsifiable claim, proven live.** The M0 chaos test (0/0 over 5000) is the demo's spine.
   Lead with it. Everything else is supporting cast.
2. **Honesty about limits.** Backpressure is lossy and best-effort — never claim lossless or
   "impossible." "Make the bad state impossible" is claimed **only** for the stranded-FIFO case
   (a write to a vanished pipe is a harmless ENOENT/ENXIO). Timer resolution, dep set, throughput
   ceiling: state the true platform-qualified numbers.
3. **Cite real sources.** Every borrowed-mechanism claim must point at a file:line that actually
   says what you claim. If you can't find it, you can't claim it.
4. **The differential/adversarial test must have a must-fail negative control.** A broken
   scheduler variant (poke-then-stage or no-rescan) MUST be shown to miss/dup. No negative
   control = no proof.

## Definition of done (hackathon demo)

- M0 green: `tests/chaos_deadline.sh` prints `missed=0 dup=0` over N ≥ 5000; negative control
  visibly fails the broken variant; idle CPU ~0% on a `top` sample.
- `src/shellmux` (~150 lines, `wc -l` fits one screen) accepts `SUB`/`PUB` over UNIX + TCP via
  socat-fork; topics are subdirs; per-subscriber FIFO + bounded ring drainer + visible `drops_$pid`.
- `--at` / `--delay` deferred delivery works through the M0 scheduler; lands on the second with
  `top` at ~0% the whole delay.
- Wedged-subscriber flood test: two healthy subs stay real-time, `drops_<wedged>` ticks up, and a
  live `ps --ppid $PUB | wc -l` stays **flat** (proves writers don't accumulate — the `> $f &` bug
  is gone).
- Deferred crash-recovery test: deferred files survive a broker kill; scheduler re-arms on restart;
  documented as at-most-once-modulo-crash.
- All introspection via `ls`/`cat` on the filesystem.

## Evaluator loop

The repo carries a **phase-aware** evaluator harness (`eval/`). In the current pre-code phase it
scores the spec/design (adversarial reviewer, prior-art skeptic, feasibility realist, Linus-taste
judge). Once M0 builds it graduates to product-usage evaluators (real users of the tool). Rounds
are **not run yet** — this is scaffolding. To run a round, read `eval/README.md` and follow the
`evaluators → aggregator → analyst → implement → measure delta` mechanics. Personas live in
`eval/personas/`, challenges in `eval/challenges/bank.json`, pipeline prompts in `eval/prompts/`.

## Recommended skills (Matt Pocock's "Skills For Real Engineers")

Installed as plugin `mattpocock-skills` (source: `/Users/bobbyrathore/Documents/WildProjects/skills`).
Use them — see `PROMPT.md` §7b for the phase mapping. Quick reference:

- `grill-with-docs` — grill yourself against the spec/design before M0 and each milestone.
- `tdd` — the core build loop (pairs with our must-fail-negative-control discipline).
- `diagnose` — disciplined failure loop when M0 or a milestone breaks.
- `handoff` — compact the conversation at session end (complements the persistent `HANDOFF.md`).
- `to-prd` / `to-issues` — turn `docs/plan.md` into trackable issues.
- `zoom-out` — when lost in the borrowed source repos.
