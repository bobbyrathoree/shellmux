# shellmux — the 1-page demo

A content-blind topic pub/sub broker built from `socat`-fork + FIFOs + `flock`.
Two of the three things people pay clustered brokers for — per-subscriber
isolation and forget-on-death — fall out of fork-per-connection **for free**.
The one hard contribution, **proven live**, is a *data-derived deadline
scheduler* that fires timed messages **race-free against concurrent publishes,
with ~0% idle CPU and no timer wheel**, in a language with no threads, no
atomics, and only advisory locks.

## Setup (≈30s)

```bash
docker build -t shellmux-dev .
docker run --rm -it -v "$PWD:/work" -w /work shellmux-dev bash
```

Everything below runs **inside that container** (Debian bookworm, bash 5.2,
socat 1.7.4). The eventual target is a literal $5 Raspberry Pi — the real
dependency set is **bash≥4 + coreutils + util-linux(`flock`) + socat**, not
"zero deps".

## Beat 1 — lead with the hard thing: the deadline chaos proof

```bash
bash tests/chaos_deadline.sh        # ~2m45s for the full N=5000 gate
# quick:  N_MAIN=400 bash tests/chaos_deadline.sh
```

What the judge sees:

```
[1/5] CORRECT     missed=0 dup=0 ontime=5000 total_fires=5000   over N=5000   PASS
[2/5] naivesleep  missed=120/120        control fails as required
[3/5] drainfirst  missed=120/120        control fails as required
[4/5] nocommit    dup=1770              control fails as required
[5/5] idle CPU    0.00%                 PASS
```

Every one of 5000 trials lands a publish in the **exact** window between
"scheduler computed `next = MIN(run_at)`" and "scheduler entered the blocking
`read -t`" — the precise race that a naive `sleep $((next-now))` loses. shellmux
fires **0 missed, 0 duplicate**, at **0.00% idle CPU**. The proof is only a proof
because three deliberately-broken schedulers (each one knob off `src/sched.sh`)
are shown to **fail** on their predicted axis. This survived an adversarial
4-lens verification (`docs/evidence/M0-adversarial-verdict.md`).

## Beat 2 — the scheduler fires a real publish, on the second, at ~0% CPU

```bash
D=$(mktemp -d); SOCK=$D/s.sock
bash src/shellmux serve "$D" --unix "$SOCK" &  BROKER=$!   # no config
bash src/shellmux sub  "$D" control --unix "$SOCK" &  SUBSC=$!  # a subscriber
echo reboot-now | bash src/shellmux pub "$D" control --delay 5 --unix "$SOCK"
# top shows ~0% the whole 5s; the line lands on the second.
ls "$D"/deferred/      # the pending deadline, as a filename: <run_at_ms>.<seq>
# teardown (reap the broker subtree + the subscriber; broker shutdown EOFs subs):
kill "$SUBSC" "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
```

`tests/deferred_pub.sh` proves this: `--delay`/`--at` fire **at** the deadline
(~40ms, wake-driven — not early, not poll-late), with the scheduler idle
(0 CPU ticks) during the wait.

## Beat 3 — the backpressure path, honestly

```bash
bash tests/flood_wedged.sh           # ~5s
```

Three subscribers on a topic, one deliberately **wedged** (never reads its
socket); flood the topic over a single held-open connection. The two healthy
subscribers get the whole flood at full speed *while the connection stays open*;
the wedged subscriber's ring overflows and `cat drops_<wedged>` ticks up (that
overload loss is **visible — counted, never silent**); and the publisher's process
count stays **flat (~15)**. The must-fail control flips one knob to terminalphone's
`printf > $f &` pattern and the count **balloons to ~1300** — the leak we replaced,
made visible.

> *Honest caveat (the one loss that is NOT counted):* the `drops_<pid>` counter
> covers the wedged-subscriber **ring-overflow** path. A different, inherent loss is
> NOT counted — if a fast publisher **closes its connection before the broker has
> finished ingesting an in-flight burst**, the unflushed tail is gone (fork-per-
> connection socat: when the source closes, unread bytes vanish), with no `drops`
> tick and nothing in `broker.log`. Hold the connection briefly after the last write
> (the `pub` helper lingers `SHELLMUX_PUB_LINGER`s, default 1, for exactly this), or
> treat fast-disconnect tail loss as expected. So "never silent" is true for
> backpressure overflow, not for publisher-disconnect truncation.

## Beat 4 — the whole broker is `ls` and `cat`

```bash
ls "$D"/topics/                              # topics are directories
ls "$D"/topics/control/sub_*.fifo | wc -l    # live subscriber count
cat "$D"/topics/control/drops_* 2>/dev/null || echo "no drops"   # per-sub drops (file appears on first drop)
ls "$D"/deferred/ | sort | head -1           # the next deadline
```

No admin protocol. State *is* the filesystem (`tests/introspection.sh`). A
`drops_<pid>` file is created lazily on the *first* dropped record, so a healthy
topic has none — hence the `2>/dev/null || echo "no drops"`.

## Run everything

```bash
bash tests/run_all.sh                # all 10 suites, each with its must-fail control
N_MAIN=400 bash tests/run_all.sh     # fast (~90s)
bash tests/bench.sh                  # throughput + footprint
```

## Measured numbers

**Correctness is hardware-independent and re-proven on real ARM64.** The N=5000 chaos
gate fires `missed=0 dup=0` at 0.00% idle CPU on the 14-core dev container, on a
2 GB AWS Graviton box, AND on a 0.5 GB Graviton box *under active OOM pressure* —
identical result every time (`docs/evidence/R3-aws-graviton.md`).

Throughput and the subscriber ceiling are hardware-DEPENDENT — state the platform:

```
Dev container (Linux aarch64, bash 5.2, 14 vCPU):
  B1  immediate publish:  1 sub ~1360 msg/s ;  3 subs ~480 msg/s/sub
  B2  idle scheduler:     0 CPU ticks over 3s (~0%)
  B3  20 subscribers:     20 FIFOs, ~110 procs (~5 procs + ~2.4 MB RAM per sub)

AWS Graviton bare metal (ARM64, AL2023, real dep set — NOT a container):
  t4g.small (2 vCPU): B1 ~52-60 msg/s/sub ; idle 0 ticks ; 400 subs linear, sched RSS 3.4 MB
  t4g.nano  (2 vCPU, 0.5 GB ≈ Pi RAM): B1 ~54-59 msg/s/sub ; ceiling ~150-175 subs then OOM
```

**Throughput is fork-bound** (one `timeout bash -c` per record per sub): on a 2-vCPU
ARM box it is **tens of msg/s/sub**, ~20× below the 14-core container — so quote the
small-hardware figure, not the container's, for a $5-Pi audience. The **subscriber
ceiling is RAM-bound** (~2.6 MB/sub measured: socat + handler + drainer); on the
0.5 GB Graviton box the wall bit at **~150-175 subscribers** — validating the
"~100-150 on a 512 MB Pi" estimate on real hardware. (Graviton cores are faster than
a Pi's, so these throughputs are an *upper* bound for an actual Pi; the RAM ceiling
transfers directly.)

## Why it's honest (the things we do NOT claim)

- **Not lossless.** Backpressure is best-effort; the ring is lossy under
  sustained overload *for that one wedged subscriber only*, exposed via
  `drops_$pid`. "Make the bad state impossible" is claimed **only** for the
  stranded-FIFO case (a write to a vanished pipe is a harmless ENOENT/ENXIO).
- **Not fork-free.** Each bounded write is a `timeout bash -c` (~0.5–10ms here);
  the claim is *no per-message process **accumulation*** — proven by the flat
  process count, not "zero forks".
- **Not POSIX-anywhere.** Needs bash≥4, `flock`, `timeout`, `socat`; sub-second
  timers need bash≥4 fractional `read -t` (whole-second floor on bash3/dash —
  faithful to honker's own `Duration::from_secs`).
- **Not binary-clean transport.** A record is **one newline-delimited line of
  NUL-free text**: NUL bytes are stripped, and **each newline-terminated line is
  delivered as its own separate record** (a multi-line payload fans out as N records,
  one per line — not one truncated record, not one multi-line blob), while an
  unterminated trailing line waits for a newline before it is delivered.
  "Content-blind" means the broker never *parses* your payload — not that it
  preserves arbitrary bytes. **Frame integrity holds under concurrent publishers,
  including records larger than PIPE_BUF (4 KiB):** each per-subscriber fan-out
  write is serialized under a per-sub `flock`, so two publishers streaming big
  records to the same subscriber can't interleave bytes into a torn/concatenated
  frame. The lock is per-subscriber (not global), so a wedged peer still never
  blocks a healthy one (`tests/concurrent_frames.sh`, `SHELLMUX_NO_WLOCK=1`
  must-fail control).
- **Not a serious broker.** No persistence, acks, wildcards, auth/TLS (delegate
  to `socat OPENSSL`/SSH), or clustering. **No retained delivery, by design:** a
  message is delivered only to subscribers connected *at publish time* — a
  subscriber that is offline during a live publish (even with the broker healthy)
  permanently misses it; there is no replay. The crash face of this is
  **at-most-once-modulo-crash:** a deferred message whose deadline elapsed while the
  broker was down fires immediately on restart into whoever is connected *then* — a
  subscriber that reconnects later does not receive it (and if the deadline is
  already overdue at restart, it can fire before *any* subscriber reconnects, racing
  them). That's the expected face of the guarantee, not a bug.
- **Hostile input is rejected, not silently mishandled.** Topic names are
  `[A-Za-z0-9._-]+` (no `../` traversal that `mkdir`s outside the state dir);
  `--at`/`--delay` must be a non-negative integer within `SHELLMUX_MAX_DEFER_S`
  (default 1yr) or the publish returns nonzero with a reason. The data path that
  *derives* the scheduler's deadlines is validated before it reaches the proven
  core (`tests/input_validation.sh`, `SHELLMUX_NO_VALIDATE=1` must-fail control).
- **Line count:** `src/sched.sh` is 186 lines; `src/shellmux` is 504 (fan-out +
  bounded drainer + deferred PUB + client helpers + reaper + input validation +
  the corrupt-deferred skip guard and the per-sub fan-out write lock added in R3).
  The "~150 lines" pitch is the *scheduler*, which is the contribution; the
  broker around it is honest plumbing.

The brag is small and correct: a race-free, data-derived deadline scheduler in
shell, proven by 5000 adversarial trials with a must-fail negative control — on
hardware cheaper than lunch.
