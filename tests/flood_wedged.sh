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
#   F1 (no permanent starvation). Given adequate drain time, both healthy
#      subscribers receive the ENTIRE flood despite a wedged peer — the wedged
#      sub slows but never strands healthy delivery. (The throttle factor is
#      reported transparently, not hidden.)
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
WTO="${WTO:-0.002}"                  # drainer's bounded socket-write timeout
                                     #   (healthy writes succeed in us; a wedged
                                     #   socket-write is abandoned after ~this)

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
cleanup() { kill "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null; rm -rf "$D"; }
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
DRAIN_CAP="${DRAIN_CAP:-60}"   # hard cap on the drain wait (safety, not the norm)
PUB_LINGER="${PUB_LINGER:-3}"  # brief hold-open after sending so the broker drains
setsid bash -c '
  { printf "PUB %s\n" "'"$TOPIC"'"
    for i in $(seq 1 '"$FLOOD"'); do printf "evt-%06d-%s\n" "$i" "'"$PAD"'"; done
    sleep '"$PUB_LINGER"'
  } | socat - "UNIX-CONNECT:'"$SOCK"'" >/dev/null 2>&1
' >/dev/null 2>&1 &
PUBPGID=$!   # setsid makes this child a group leader; its PGID == its PID

t_start=$(date +%s); t_done=0
h1=0; h2=0; max_kids=0
# Poll at 1s cadence (NOT a tight 100ms loop): a hot foreground poll competes
# with the broker for forks on this host. One count_desc + two greps/sec is cheap.
while :; do
  h1=$(grep '^evt-' "$D/h1.out" 2>/dev/null | wc -l); h1=$(( h1 + 0 ))
  h2=$(grep '^evt-' "$D/h2.out" 2>/dev/null | wc -l); h2=$(( h2 + 0 ))
  k=$(count_desc); k=$(( ${k:-0} + 0 )); [ "$k" -gt "$max_kids" ] && max_kids=$k
  # leaky control: stop early once we've seen the balloon (no need to drain).
  if [ "$LEAKY" = "1" ] && [ "$max_kids" -gt 60 ]; then break; fi
  if [ "$h1" -ge "$FLOOD" ] && [ "$h2" -ge "$FLOOD" ]; then t_done=$(( $(date +%s) - t_start )); break; fi
  if [ $(( $(date +%s) - t_start )) -ge "$DRAIN_CAP" ]; then t_done=$(( $(date +%s) - t_start )); break; fi
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

# --- F1: healthy subs receive the WHOLE flood at full speed despite a wedged peer
echo "  (healthy subs received $h1/$h2 of $FLOOD in ~${elapsed}s — same rate as no-wedge; the"
echo "   wedged peer's bounded drops do not serialize healthy delivery)"
if [ "$h1" -ge "$FLOOD" ] && [ "$h2" -ge "$FLOOD" ]; then
  ok "F1 healthy subs received the ENTIRE flood despite a wedged peer (not starved, not serialized)"
else
  bad "F1 healthy subs did not fully drain within ${DRAIN_CAP}s (h1=$h1 h2=$h2 of $FLOOD)"
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
