#!/usr/bin/env bash
# tests/deferred_pub.sh — M3b: deferred (--at / --delay) PUB through the scheduler.
# ============================================================================
# Ties the broker back to its one hard contribution: a deferred publish is staged
# as a deferred/<run_at_ms>.<seq> file (stage-then-poke), the M0 scheduler fires
# it when due, and delivery lands in the SAME topic fan-out as an immediate PUB.
#
#   D1 (--delay fires near the deadline, not before). A subscriber on topic T;
#      `pub T --delay 1` delivers nothing for ~1s, then the record arrives within
#      a small grace of the 1s deadline. (Not early, not idle_poll-late.)
#   D2 (--at <epoch> fires at the absolute deadline). Same, with an absolute time.
#   D3 (idle CPU ~0 during the wait). While the deferred record waits, the
#      scheduler is blocked in read -t (no busy-spin) — the M0 property, end-to-end.
#
# MUST-FAIL NEGATIVE CONTROL (D1'): a scheduler that fires IMMEDIATELY (ignores
# run_at) delivers the --delay record early. If the broken variant ALSO waits,
# the test isn't proving the deadline is honored. Realized by pointing serve at a
# fire-now scheduler via SCHED_OVERRIDE (test-only).
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/deferred_pub.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
now_ms() { date +%s%3N; }

echo "== deferred_pub: src/shellmux =="
[ -f "$SHELLMUX" ] || { echo "MISSING $SHELLMUX"; exit 2; }

# Reap any lingering background pub pipelines (each holds a `sleep` linger) so the
# container's PID 1 doesn't see stray children and return nonzero on exit.
cleanup_all() { pkill -P $$ 2>/dev/null; }
trap cleanup_all EXIT

# first_fire_ms <outfile>: ms-epoch when the first 'evt' line appeared, or empty.
# We approximate arrival time by polling the subscriber output file.
wait_arrival() { # $1=outfile $2=timeout_ms ; echoes arrival_ms or empty
  local out=$1 to=$2 dl; dl=$(( $(now_ms) + to ))
  while [ "$(now_ms)" -lt "$dl" ]; do
    if grep -q '^evt' "$out" 2>/dev/null; then now_ms; return 0; fi
    sleep 0.02
  done
  return 1
}

start_broker() { # $1=dir $2=sock ; extra env from caller
  bash "$SHELLMUX" serve "$1" --unix "$2" >"$1/broker.log" 2>&1 &
  echo $!
}
start_sub() { # $1=dir $2=sock $3=topic $4=outfile
  bash "$SHELLMUX" sub "$1" "$3" --unix "$2" >"$4" 2>/dev/null &
  echo $!
}

# arrival_delta <dir> <outfile> <pat> <deadline_ms>: poll for <pat>, echo
# (arrival_ms - deadline_ms). A single window check then proves not-early AND
# not-late. NOTE: the `pub` client BLOCKS for the whole delay (it holds the
# connection open), so we always publish in the BACKGROUND and time arrival
# against the deadline we computed up front.
arrival_delta() {
  local out=$2 pat=$3 dl=$4
  local hard=$(( dl + 4000 ))
  while [ "$(now_ms)" -lt "$hard" ]; do
    if grep -q "$pat" "$out" 2>/dev/null; then echo $(( $(now_ms) - dl )); return 0; fi
    sleep 0.02
  done
  echo "TIMEOUT"; return 1
}

# --- D1: --delay 1 fires near the 1s deadline (not early, not idle_poll-late) -
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"
sleep 1
SUB="$(start_sub "$D" "$SOCK" clock "$D/d1.out")"
sleep 0.5
deadline=$(( $(now_ms) + 1000 ))
printf 'tick\n' | bash "$SHELLMUX" pub "$D" clock --delay 1 --unix "$SOCK" >/dev/null 2>&1 &
delta="$(arrival_delta "$D" "$D/d1.out" '^tick' "$deadline")"
if [ "$delta" = "TIMEOUT" ]; then
  bad "D1 --delay 1 never arrived within 4s of the deadline"
elif [ "$delta" -ge -300 ] && [ "$delta" -le 1300 ]; then
  ok "D1 --delay 1 fired AT the deadline (arrival ${delta}ms relative — not early, not poll-late)"
else
  bad "D1 --delay 1 fired off-deadline (delta=${delta}ms; <-300 = early, >1300 = poll-late)"
fi
kill "$SUB" "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
rm -rf "$D"

# --- D2: --at <epoch+2s> fires at the absolute deadline ---------------------
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"
sleep 1
SUB="$(start_sub "$D" "$SOCK" clock "$D/d2.out")"
sleep 0.5
at=$(( $(date +%s) + 2 ))
deadline=$(( at * 1000 ))
printf 'atfire\n' | bash "$SHELLMUX" pub "$D" clock --at "$at" --unix "$SOCK" >/dev/null 2>&1 &
delta="$(arrival_delta "$D" "$D/d2.out" '^atfire' "$deadline")"
if [ "$delta" = "TIMEOUT" ]; then
  bad "D2 --at never arrived within 4s of the deadline"
elif [ "$delta" -ge -1100 ] && [ "$delta" -le 1300 ]; then
  ok "D2 --at <epoch+2> delivered at the absolute deadline (arrival ${delta}ms relative)"
else
  bad "D2 --at fired off-deadline (delta=${delta}ms)"
fi
kill "$SUB" "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
rm -rf "$D"

# --- D3: idle CPU ~0 while a deferred record waits --------------------------
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"
sleep 1
# background the pub (it blocks for the whole delay holding the connection open).
printf 'later\n' | bash "$SHELLMUX" pub "$D" clock --delay 5 --unix "$SOCK" >/dev/null 2>&1 &
# find the scheduler pid (child of broker running sched.sh)
sleep 0.5
SCHED_PID="$(pgrep -f 'sched.sh' | head -1)"
if [ -n "$SCHED_PID" ] && [ -r "/proc/$SCHED_PID/stat" ]; then
  read_ticks() { local s; s=$(< "/proc/$SCHED_PID/stat"); local r="${s#*) }"; set -- $r; REPLY=$(( ${12} + ${13} )); }
  read_ticks; t0=$REPLY
  sleep 2
  read_ticks; t1=$REPLY
  d=$(( t1 - t0 ))
  if [ "$d" -le 5 ]; then
    ok "D3 scheduler idle during the deferred wait ($d CPU ticks over 2s)"
  else
    bad "D3 scheduler burned CPU while waiting ($d ticks over 2s)"
  fi
else
  bad "D3 could not find scheduler pid to sample"
fi
kill "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
rm -rf "$D"

# --- D1' NEGATIVE CONTROL: a fire-now scheduler delivers early --------------
# Point serve at a broken scheduler that ignores run_at (fires on first scan).
D="$(mktemp -d)"; SOCK="$D/s.sock"
SCHED_OVERRIDE="$ROOT/tests/negative/sched_firenow.sh" \
  bash "$SHELLMUX" serve "$D" --unix "$SOCK" >"$D/broker.log" 2>&1 &
BROKER=$!
sleep 1
SUB="$(start_sub "$D" "$SOCK" clock "$D/dc.out")"
sleep 0.5
printf 'tooearly\n' | bash "$SHELLMUX" pub "$D" clock --delay 5 --unix "$SOCK" >/dev/null 2>&1 &
# Within ~1.5s (well before the 5s deadline), a CORRECT scheduler has delivered
# nothing; the fire-now control delivers immediately. Poll briefly.
got=""
for _ in $(seq 1 60); do
  if grep -q '^tooearly' "$D/dc.out" 2>/dev/null; then got=1; break; fi
  sleep 0.025
done
if [ -n "$got" ]; then
  ok "D1' control (must fire early): fire-now scheduler delivered before the 5s deadline"
else
  bad "D1' control did NOT fire early — D1/D2 deadline proof is vacuous!"
fi
kill "$SUB" "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
rm -rf "$D"

echo "== deferred_pub result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
