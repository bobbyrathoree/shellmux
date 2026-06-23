#!/usr/bin/env bash
# tests/flood_wedged.sh — M3: bounded fan-out under a wedged subscriber.
# ============================================================================
# THE M3 properties, stated HONESTLY (this project's ethos). A deliberately
# wedged subscriber (socket never drained) must NOT: (a) make the publisher
# accumulate background processes, (b) silently swallow its overflow, or (c)
# PERMANENTLY starve healthy subscribers. It MAY throttle the publisher's
# fan-out rate — with a single-threaded shell publisher and only timeout-bounded
# writes (no threads, no O_NONBLOCK), a wedged peer costs the fan-out loop ~one
# write-timeout per record. We do NOT claim healthy subs run at full speed
# regardless of a wedged peer; we claim no permanent loss, no leak, no silent drop.
#
#   F1 (no permanent starvation). Both healthy subscribers receive the ENTIRE
#      flood despite a wedged peer — the wedged sub slows but never strands healthy
#      delivery. Asserted as EVENTUAL COMPLETENESS (poll until delivery quiesces,
#      then assert completeness on what arrived), NOT a wall-clock deadline, so a
#      slow-but-progressing drain on a contended host passes; only a true plateau
#      below FLOOD fails. (Round-002 A2 hardened this against a host-contention
#      flake — see the QUIESCE_S / PUB_LINGER / WTO notes below.)
#   F2 (drops are visible, never silent). topics/<t>/drops_<wedged> ticks up as
#      the wedged subscriber's path overflows. Lossy-but-honest.
#   F3 (publisher does NOT accumulate processes — THE headline claim). The max
#      count of broker-descendant processes sampled across the flood stays
#      small/flat. A leaky publisher's count would climb with the message rate.
#   F4 (length-prefixed framing survives). Frames are `<decimal-len>\n<bytes>`;
#      a torn frame is caught by the drainer's short-read and discarded, never
#      concatenated. Healthy subs only ever emit intact, correctly-sized records.
#
# MUST-FAIL NEGATIVE CONTROL (F3'): a leaky-writer variant (the `> $f &` pattern,
# SHELLMUX_LEAKY_WRITE=1) must make the publisher's child-process count BALLOON
# under the same flood. If the leaky variant ALSO stays flat, F3 is vacuous.
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/flood_wedged.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# tunables (env-overridable)
FLOOD="${FLOOD:-1000}"               # records in the burst
PAYLOAD_PAD="${PAYLOAD_PAD:-400}"    # payload size: big enough that the wedged
                                     #   path (socket+socat+pipe buffers ~300KB)
                                     #   overflows and drops register
WTO="${WTO:-0.02}"                   # drainer's bounded socket-write timeout for
                                     #   THIS TEST (a healthy write completes in us;
                                     #   a wedged socket-write is abandoned after
                                     #   ~this). NOT the broker default (0.05) — the
                                     #   test deliberately tightens it so the wedged
                                     #   path overflows quickly and drops register.
                                     #   Round-002 A2/N1: the prior 0.002 (2ms) was
                                     #   TOO tight — under host CPU contention an
                                     #   occasional HEALTHY socket-write exceeded 2ms
                                     #   and false-dropped one record (the 999/1000
                                     #   flake the flooder hit under concurrent load).
                                     #   20ms gives healthy writes realistic headroom
                                     #   while still overflowing the wedged peer
                                     #   (drops stay in the hundreds), so F1 measures
                                     #   broker completeness, not drainer timing jitter.

echo "== flood_wedged: src/shellmux =="
[ -f "$SHELLMUX" ] || { echo "MISSING $SHELLMUX"; exit 2; }

D="$(mktemp -d)"; SOCK="$D/shellmux.sock"; TOPIC=sensors
mkdir -p "$D/topics"
LEAKY="${SHELLMUX_LEAKY_WRITE:-0}"
# WTO governs the DRAINER's bounded socket write (where backpressure lives), so it
# must be set on `serve` — the drainer runs in a serve-forked handler.
SHELLMUX_LEAKY_WRITE="$LEAKY" SHELLMUX_WRITE_TIMEOUT="$WTO" \
  bash "$SHELLMUX" serve "$D" --unix "$SOCK" >"$D/broker.log" 2>&1 &
BROKER=$!
sleep 1
# Cleanup must reap BOTH the broker subtree (pkill -P) AND the client-side procs
# this script spawns directly — the subscribers, the wedged socat, and its
# detached `sleep 300`. Those are children of THIS script, not of $BROKER, so
# pkill -P "$BROKER" alone leaves them orphaned; run the suite back-to-back and
# the orphaned sleeps/subs accumulate until a later cold start contends and hangs
# (the operator persona's ">120s / EXIT 137 on cold start" and the flaky-F1 report).
# `pkill -P $$` sweeps every direct child of this script; we also kill the named
# pids explicitly in case a grandchild (socat | sleep) re-parented to init.
cleanup() {
  kill "$BROKER" "${H1:-}" "${H2:-}" "${WEDGED:-}" 2>/dev/null
  pkill -P "$BROKER" 2>/dev/null
  pkill -P $$ 2>/dev/null
  rm -rf "$D"
}
trap cleanup EXIT

# payload: a fixed-width tag we can validate, padded to PAYLOAD_PAD bytes.
# (the flood itself is generated inline in the setsid publisher below.)
PAD="$(head -c "$PAYLOAD_PAD" /dev/zero | tr '\0' 'x')"

# two healthy subscribers (drain normally), one wedged (socket never read).
bash "$SHELLMUX" sub "$D" "$TOPIC" --unix "$SOCK" >"$D/h1.out" 2>/dev/null & H1=$!
bash "$SHELLMUX" sub "$D" "$TOPIC" --unix "$SOCK" >"$D/h2.out" 2>/dev/null & H2=$!
( printf 'SUB %s\n' "$TOPIC"; sleep 300 ) | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | ( exec sleep 300 ) & WEDGED=$!

for _ in $(seq 1 100); do
  [ "$(ls "$D/topics/$TOPIC"/sub_*.fifo 2>/dev/null | wc -l)" -eq 3 ] && break
  sleep 0.05
done
nf=$(ls "$D/topics/$TOPIC"/sub_*.fifo 2>/dev/null | wc -l)
[ "$nf" -eq 3 ] || { bad "setup: expected 3 sub FIFOs, got $nf (broker.log: $(tr '\n' '|' <"$D/broker.log"))"; echo "== flood_wedged result: pass=$pass fail=$fail =="; exit 1; }

# Count ALL broker descendants from ONE `ps` snapshot (single fork; the awk does
# the tree walk in-process). Continuous/recursive sampling is avoided on purpose:
# any busy concurrent poller measurably starves the broker's own fan-out forks on
# a fork-bound host (observer effect; measured to inflate a 3s drain to ~60s).
# We therefore sample SPARSELY (every ~2s) from inside the main poll loop instead
# of running a hot background sampler.
count_desc() {
  ps -eo pid=,ppid= 2>/dev/null | awk -v root="$BROKER" '
    { pp[$1]=$2 }
    END { c=0
      for (p in pp) { q=p
        while (q!="" && q!="1" && q!="0") {
          if (pp[q]==root) { c++; break }
          q=pp[q]
        }
      }
      print c }'
}

# --- launch the flood publisher over a held-open connection so the broker can
#     drain its backlog without the client-EOF race truncating the tail. -------
# The publisher runs in its OWN PROCESS GROUP (setsid) so teardown can signal the
# whole group (the PUB-line emitter + its `sleep` linger + socat) at once. This
# is deliberate: a naive `( ...; sleep N ) | socat &` records `$!` = socat, and
# `wait $!` then blocks on the WHOLE pipeline — including the orphaned `sleep N`
# linger — which once made this test mis-report a ~1s delivery as ~90s. We kill
# the group and never `wait` on it.
# F1 asserts EVENTUAL COMPLETENESS (no permanent starvation), NOT a wall-clock
# deadline. Round-001 closed H4 (F1 flake) by reaping client orphans, but the
# assertion was still a fixed 60s cap doubling as both hang-guard AND deadline —
# so on a CONTENDED host (round-002's flooder ran this alongside 11 other docker
# evaluators) a slow-but-progressing drain hit the cap at 999/1000 and F1 failed,
# though the broker would have completed. The fix (round-002 A2/N1): poll until
# delivery QUIESCES (publisher group exited AND no new records on either healthy
# sub for QUIESCE_S), then assert completeness on what arrived — a plateau AT
# FLOOD passes, a plateau BELOW FLOOD is genuine permanent starvation and fails.
# A slow-but-progressing drain keeps its time (every advance resets the quiesce
# timer); only HANG_GUARD bounds the wall clock, and only as a never-hang backstop.
QUIESCE_S="${QUIESCE_S:-15}"   # declare delivery quiesced after this many seconds with NO new records
HANG_GUARD="${HANG_GUARD:-180}" # absolute backstop so a truly stuck run fails loud, never forever
# The publisher HOLDS THE CONNECTION OPEN until THIS SCRIPT tears it down (below),
# not for a fixed interval. A fixed brief linger (was 3s) under host contention
# closed the socket before the broker finished ingesting the in-flight burst, so
# the unflushed TAIL was lost (round-002 N2 — publisher-disconnect truncation,
# inherent to fork-per-connection socat, NOT broker starvation). Holding the
# connection open for the whole measurement removes that confound, so F1 measures
# true broker completeness: a plateau below FLOOD *with the connection still open*
# is genuine starvation; a plateau at FLOOD is success. The big linger never
# actually elapses — the poll loop kills the publisher group the moment delivery
# completes or quiesces.
PUB_LINGER="${PUB_LINGER:-600}"
setsid bash -c '
  { printf "PUB %s\n" "'"$TOPIC"'"
    for i in $(seq 1 '"$FLOOD"'); do printf "evt-%06d-%s\n" "$i" "'"$PAD"'"; done
    sleep '"$PUB_LINGER"'
  } | socat - "UNIX-CONNECT:'"$SOCK"'" >/dev/null 2>&1
' >/dev/null 2>&1 &
PUBPGID=$!   # setsid makes this child a group leader; its PGID == its PID

t_start=$(date +%s); t_done=0
h1=0; h2=0; max_kids=0
last_progress=$t_start; prev_sum=-1
# Poll at 1s cadence (NOT a tight 100ms loop): a hot foreground poll competes
# with the broker for forks on this host. One count_desc + two greps/sec is cheap.
while :; do
  h1=$(grep '^evt-' "$D/h1.out" 2>/dev/null | wc -l); h1=$(( h1 + 0 ))
  h2=$(grep '^evt-' "$D/h2.out" 2>/dev/null | wc -l); h2=$(( h2 + 0 ))
  k=$(count_desc); k=$(( ${k:-0} + 0 )); [ "$k" -gt "$max_kids" ] && max_kids=$k
  now=$(date +%s)
  # leaky control: stop early once we've seen the balloon (no need to drain).
  if [ "$LEAKY" = "1" ] && [ "$max_kids" -gt 60 ]; then break; fi
  # COMPLETE: both healthy subs got the whole flood — done, keep the elapsed.
  if [ "$h1" -ge "$FLOOD" ] && [ "$h2" -ge "$FLOOD" ]; then t_done=$(( now - t_start )); break; fi
  # track delivery progress: any new record on either sub resets the quiesce timer,
  # so a slow-but-advancing drain is NEVER failed for being slow — only a true
  # plateau (no progress for QUIESCE_S) ends the wait.
  cur_sum=$(( h1 + h2 ))
  if [ "$cur_sum" -ne "$prev_sum" ]; then prev_sum=$cur_sum; last_progress=$now; fi
  # QUIESCED: no new records on EITHER healthy sub for QUIESCE_S seconds. Because
  # the publisher holds its connection open the whole time (PUB_LINGER), the broker
  # always has adequate ingest time, so a plateau here is delivery genuinely
  # stopping — not the publisher truncating its tail on early disconnect. Whatever
  # arrived is final: assert completeness below (plateau at FLOOD = pass, plateau
  # below = permanent starvation = fail). QUIESCE_S (15s) is far above any
  # legitimate inter-record gap (the wedged peer costs only ~WTO≈2ms per record),
  # so a 15s stall unambiguously means delivery has stopped advancing. This
  # decouples the verdict from wall-clock: a host so slow the drain takes minutes
  # still passes as long as it keeps making progress toward FLOOD.
  if [ $(( now - last_progress )) -ge "$QUIESCE_S" ]; then t_done=$(( now - t_start )); break; fi
  # absolute backstop: never hang forever (a genuinely stuck broker fails loud).
  if [ $(( now - t_start )) -ge "$HANG_GUARD" ]; then t_done=$(( now - t_start )); break; fi
  sleep 1
done
# kill the whole publisher process group WITHOUT waiting (the linger sleep would block wait).
kill -- -"$PUBPGID" 2>/dev/null

total_drops=0
for df in "$D/topics/$TOPIC"/drops_*; do
  [ -e "$df" ] || continue
  v=$(cat "$df" 2>/dev/null); total_drops=$(( total_drops + ${v:-0} ))
done
elapsed=$t_done

if [ "$LEAKY" = "1" ]; then
  # NEGATIVE-CONTROL RUN: we only care that the process count BALLOONED.
  echo "  (leaky mode) max broker-descendant procs during flood = $max_kids"
  if [ "$max_kids" -gt 50 ]; then
    ok "F3' control (must balloon): leaky \`> \$f &\` writer accumulated $max_kids processes"
  else
    bad "F3' control did NOT balloon (max=$max_kids) — F3 would be vacuous!"
  fi
  echo "== flood_wedged result: pass=$pass fail=$fail (LEAKY control) =="
  [ "$fail" -eq 0 ]; exit $?
fi

# --- F1: healthy subs receive the WHOLE flood despite a wedged peer (eventual
#         completeness — no permanent starvation; slow is allowed, lossy is not).
echo "  (healthy subs received $h1/$h2 of $FLOOD in ~${elapsed}s; the wedged peer's"
echo "   bounded drops do not permanently starve healthy delivery — verdict is on"
echo "   completeness after delivery quiesced, not on wall-clock speed)"
if [ "$h1" -ge "$FLOOD" ] && [ "$h2" -ge "$FLOOD" ]; then
  ok "F1 healthy subs received the ENTIRE flood despite a wedged peer (not starved)"
else
  bad "F1 healthy subs PERMANENTLY starved: delivery plateaued at h1=$h1 h2=$h2 of $FLOOD (quiesced/${HANG_GUARD}s-guard, not a speed cap)"
fi

# --- F2: drops visible for the wedged sub -----------------------------------
if [ "$total_drops" -gt 0 ]; then
  ok "F2 wedged-sub overflow is visible (sum drops_*=$total_drops), never silent"
else
  bad "F2 no drops recorded despite a wedged subscriber under flood"
fi

# --- F3: publisher process count stayed flat --------------------------------
if [ "$max_kids" -le 30 ]; then
  ok "F3 publisher did NOT accumulate processes (max broker-descendants=$max_kids)"
else
  bad "F3 publisher accumulated processes (max=$max_kids — looks like the > \$f & leak)"
fi

# --- F4: framing integrity --------------------------------------------------
bad_frames=$(grep -vcE "^evt-[0-9]{6}-x{$PAYLOAD_PAD}\$" "$D/h1.out" 2>/dev/null); bad_frames=${bad_frames:-0}
if [ "$bad_frames" -eq 0 ]; then
  ok "F4 healthy sub frames are all intact/well-formed (no torn/concatenated records)"
else
  bad "F4 healthy sub had $bad_frames malformed frames (torn-write corruption)"
fi

echo "== flood_wedged result: pass=$pass fail=$fail (max_descendants=$max_kids, drops=$total_drops) =="
[ "$fail" -eq 0 ]
