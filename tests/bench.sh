#!/usr/bin/env bash
# tests/bench.sh — honest throughput + resource benchmarks, IN THE CONTAINER.
# These are Linux-container numbers (Debian bookworm, bash 5.2, this host's CPU),
# NOT the $5 Raspberry Pi demo target — the Pi will be slower. State the platform.
#
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/bench.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"
now_ms() { date +%s%3N; }

cleanup_all() { pkill -P $$ 2>/dev/null; }
trap cleanup_all EXIT

echo "============================================================"
echo " shellmux benchmarks (Linux container — NOT the Pi target)"
echo " $(uname -srm) | bash $BASH_VERSION | nproc=$(nproc)"
echo "============================================================"

D="$(mktemp -d)"; SOCK="$D/s.sock"
bash "$SHELLMUX" serve "$D" --unix "$SOCK" >"$D/broker.log" 2>&1 & BROKER=$!
sleep 1

# --- B1: immediate-publish throughput to N healthy subs ---------------------
# Fresh topic per run (no cross-run ghost FIFOs); time until the SLOWEST sub has
# all M records; publish in the background (the client lingers, holding open).
M=2000
for NS in 1 3; do
  TP="bench$NS"
  subs=()
  for i in $(seq 1 "$NS"); do
    bash "$SHELLMUX" sub "$D" "$TP" --unix "$SOCK" >"$D/$TP.s$i" 2>/dev/null & subs+=($!)
  done
  for _ in $(seq 1 100); do [ "$(ls "$D/topics/$TP"/sub_*.fifo 2>/dev/null | wc -l)" -eq "$NS" ] && break; sleep 0.05; done
  t0=$(now_ms)
  ( printf 'PUB %s\n' "$TP"; for i in $(seq 1 $M); do printf 'm-%06d\n' "$i"; done; sleep 5 ) \
    | socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 &
  pub=$!
  minc=0
  for _ in $(seq 1 600); do
    minc=$M
    for i in $(seq 1 "$NS"); do
      c=$(grep -c '^m-' "$D/$TP.s$i" 2>/dev/null); c=$(( c + 0 ))
      [ "$c" -lt "$minc" ] && minc=$c
    done
    [ "$minc" -ge "$M" ] && break
    sleep 0.05
  done
  t1=$(now_ms)
  kill "$pub" 2>/dev/null
  ms=$(( t1 - t0 )); rate=$(( M * 1000 / (ms>0?ms:1) ))
  printf 'B1 immediate: %d msgs -> %d healthy sub(s): all got %d/%d in %dms = ~%d msg/s/sub\n' "$M" "$NS" "$minc" "$M" "$ms" "$rate"
  for p in "${subs[@]}"; do kill "$p" 2>/dev/null; done
  sleep 0.5
done

# --- B2: idle resource footprint --------------------------------------------
sleep 1
sched_pid=$(pgrep -f 'sched.sh' | head -1)
nproc_broker=$(pgrep -P "$BROKER" 2>/dev/null | wc -l)
if [ -n "$sched_pid" ] && [ -r "/proc/$sched_pid/stat" ]; then
  rd() { local s; s=$(< "/proc/$sched_pid/stat"); local r="${s#*) }"; set -- $r; REPLY=$(( ${12} + ${13} )); }
  rd; a=$REPLY; sleep 3; rd; b=$REPLY
  printf 'B2 idle: scheduler CPU over 3s = %d ticks (~0%%); broker direct children = %d\n' "$(( b - a ))" "$nproc_broker"
fi

# --- B3: per-subscriber footprint (fd/process) ------------------------------
NS=20
subs=()
for i in $(seq 1 "$NS"); do
  bash "$SHELLMUX" sub "$D" many --unix "$SOCK" >/dev/null 2>&1 & subs+=($!)
done
for _ in $(seq 1 100); do [ "$(ls "$D/topics/many"/sub_*.fifo 2>/dev/null | wc -l)" -eq "$NS" ] && break; sleep 0.05; done
nf=$(ls "$D/topics/many"/sub_*.fifo 2>/dev/null | wc -l)
total_procs=$(ps -e 2>/dev/null | wc -l)
printf 'B3 %d concurrent subscribers: %d FIFOs, %d total procs in container\n' "$NS" "$nf" "$total_procs"
printf '   (each sub = 1 socat + 1 handler + 1 drainer; the ceiling is fd/process limits)\n'
for p in "${subs[@]}"; do kill "$p" 2>/dev/null; done

kill "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
rm -rf "$D"
echo "============================================================"
echo " NOTE: these are container numbers. On a \$5 Pi expect lower"
echo " throughput and a lower subscriber ceiling — measure there for the slide."
echo "============================================================"
