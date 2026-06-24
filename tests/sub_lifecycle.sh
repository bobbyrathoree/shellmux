#!/usr/bin/env bash
# tests/sub_lifecycle.sh — M2: subscriber lifecycle over socat-fork.
# ============================================================================
# Proves the acceptor + SUB handler + per-subscriber FIFO + forget-on-death:
#
#   S1 (SUB registers a mailbox). A client connects over a UNIX socket and sends
#      "SUB <topic>". The broker forks a handler that mkdir's the topic and
#      mkfifo's topics/<topic>/sub_<pid>.fifo. Liveness IS the existence of that
#      FIFO — `ls` shows it.
#   S2 (forget-on-death). When the client disconnects (socket EOF / kill), the
#      handler's EXIT trap unlinks its FIFO. The next `ls` never sees it. This is
#      the shell analog of the reference queue's opportunistic
#      "disconnected => drop" leaf prune.
#   S3 (concurrent subscribers are isolated). Two clients on the same topic get
#      two distinct FIFOs (socat fork => one process each). Killing one leaves
#      the other's FIFO intact.
#   S4 (TCP transport works too). The same SUB over TCP-LISTEN registers a FIFO.
#
# MUST-FAIL NEGATIVE CONTROL (S2'): a handler WITHOUT the EXIT trap must LEAVE a
# stranded FIFO after the client is killed. If the no-trap variant also cleans
# up, then S2 isn't really testing the trap (something else removes the FIFO)
# and the forget-on-death proof is vacuous. Realized with SHELLMUX_NO_TRAP=1
# (one-knob test escape hatch in _handle).
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/sub_lifecycle.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

now_ms() { date +%s%3N; }
# wait up to $2 ms for glob $1 to match exactly $3 files
wait_count() { # $1=glob $2=timeout_ms $3=want
  local dl; dl=$(( $(now_ms) + $2 ))
  while [ "$(now_ms)" -lt "$dl" ]; do
    local n; n=$(ls $1 2>/dev/null | wc -l)
    [ "$n" -eq "$3" ] && return 0
    sleep 0.03
  done
  return 1
}
fifo_count() { ls "$1"/sub_*.fifo 2>/dev/null | wc -l | tr -d ' '; }

# Hold a subscriber connection open in the background; echo its shell PID so we
# can kill it. It sends the control line then sleeps (stays connected).
sub_unix() { # $1=sock $2=topic
  ( printf 'SUB %s\n' "$2"; sleep 30 ) | socat - "UNIX-CONNECT:$1" >/dev/null 2>&1 &
  echo $!
}
sub_tcp() { # $1=port $2=topic
  ( printf 'SUB %s\n' "$2"; sleep 30 ) | socat - "TCP-CONNECT:127.0.0.1:$1" >/dev/null 2>&1 &
  echo $!
}

echo "== sub_lifecycle: src/shellmux =="
[ -f "$SHELLMUX" ] || { echo "MISSING $SHELLMUX — RED (expected before GREEN)"; exit 2; }

D="$(mktemp -d)"; SOCK="$D/shellmux.sock"; PORT=$(( 20000 + (RANDOM % 20000) ))
mkdir -p "$D/topics"
# start the broker (UNIX + TCP). Broker backgrounds socat + scheduler.
bash "$SHELLMUX" serve "$D" --unix "$SOCK" --tcp "$PORT" >"$D/broker.log" 2>&1 &
BROKER=$!
# give socat listeners time to bind
sleep 1

cleanup() { kill "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT

# --- S1: SUB registers a mailbox FIFO ---------------------------------------
c1="$(sub_unix "$SOCK" weather)"
if wait_count "$D/topics/weather/sub_*.fifo" 3000 1; then
  ok "S1 SUB over UNIX registers topics/weather/sub_*.fifo"
else
  bad "S1 SUB did not create a FIFO (broker.log: $(tr '\n' '|' < "$D/broker.log"))"
fi

# --- S2: forget-on-death (EXIT trap unlinks on disconnect) ------------------
kill -9 "$c1" 2>/dev/null; wait "$c1" 2>/dev/null
if wait_count "$D/topics/weather/sub_*.fifo" 3000 0; then
  ok "S2 disconnect unlinks the FIFO (forget-on-death)"
else
  bad "S2 FIFO survived disconnect (count=$(fifo_count "$D/topics/weather"))"
fi

# --- S3: concurrent isolation ----------------------------------------------
a="$(sub_unix "$SOCK" sensors)"; b="$(sub_unix "$SOCK" sensors)"
if wait_count "$D/topics/sensors/sub_*.fifo" 3000 2; then
  kill -9 "$a" 2>/dev/null; wait "$a" 2>/dev/null
  if wait_count "$D/topics/sensors/sub_*.fifo" 3000 1; then
    ok "S3 two subs isolated; killing one leaves the other's FIFO"
  else bad "S3 surviving sub's FIFO count=$(fifo_count "$D/topics/sensors") (want 1)"; fi
  kill -9 "$b" 2>/dev/null; wait "$b" 2>/dev/null
else
  bad "S3 two concurrent subs did not yield 2 FIFOs (count=$(fifo_count "$D/topics/sensors"))"
fi

# --- S4: TCP transport ------------------------------------------------------
t="$(sub_tcp "$PORT" overtcp)"
if wait_count "$D/topics/overtcp/sub_*.fifo" 3000 1; then
  ok "S4 SUB over TCP registers a FIFO"
else
  bad "S4 SUB over TCP did not create a FIFO"
fi
kill -9 "$t" 2>/dev/null; wait "$t" 2>/dev/null

# --- S2' NEGATIVE CONTROL: no-trap handler must STRAND the FIFO -------------
kill "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null; wait "$BROKER" 2>/dev/null
sleep 0.3
SOCK2="$D/notrap.sock"
SHELLMUX_NO_TRAP=1 bash "$SHELLMUX" serve "$D" --unix "$SOCK2" >"$D/broker2.log" 2>&1 &
BROKER=$!
sleep 1
c="$(sub_unix "$SOCK2" leaky)"
if wait_count "$D/topics/leaky/sub_*.fifo" 3000 1; then
  kill -9 "$c" 2>/dev/null; wait "$c" 2>/dev/null
  # without the trap, the FIFO must REMAIN after disconnect
  sleep 1
  if [ "$(fifo_count "$D/topics/leaky")" -ge 1 ]; then
    ok "S2' control (must strand): no-trap handler leaves the FIFO after disconnect"
    # clean the stranded file ourselves
    rm -f "$D"/topics/leaky/sub_*.fifo
  else
    bad "S2' control: no-trap FIFO was cleaned anyway — S2 is vacuous!"
  fi
else
  bad "S2' setup: no-trap SUB did not create a FIFO"
fi

echo "== sub_lifecycle result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
