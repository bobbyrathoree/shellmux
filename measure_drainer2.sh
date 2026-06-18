#!/bin/bash
set -uo pipefail

D=$(mktemp -d)
SOCK="$D/shellmux.sock"
TOPIC="perf"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D" --unix "$SOCK" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Create wedged subscriber - this is key: connects but never reads its socket
(printf 'SUB %s\n' "$TOPIC"; sleep 300) | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | (exec sleep 300) &
WEDGED=$!
sleep 0.5

WFIFO=$(ls "$D/topics/$TOPIC"/sub_*.fifo 2>/dev/null | head -1)
WPID=$(basename "$WFIFO" .fifo | sed 's/sub_//')

# Larger payload to fill socket/FIFO faster
PAD=$(head -c 4000 /dev/zero | tr '\0' 'X')
PAYLOAD="evt-001-$PAD"

echo "Payload size: ${#PAYLOAD} bytes" >&2

# First, prime the FIFO by sending enough data to fill the socket/FIFO buffer (~64KB)
echo "Priming FIFO..." >&2
for i in {1..50}; do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done

sleep 0.1

# Now measure the actual drainer timeout cost
FLOOD=100
echo "Measuring $FLOOD timeouts on full FIFO..." >&2
START=$(date +%s%3N)

for i in $(seq 1 $FLOOD); do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done

END=$(date +%s%3N)
ELAPSED=$((END - START))

DROPS=$(cat "$D/topics/$TOPIC/drops_$WPID" 2>/dev/null || echo 0)

echo "Per-write: $((ELAPSED / FLOOD))ms, Total: ${ELAPSED}ms, Drops: $DROPS" >&2

kill $BROKER 2>/dev/null || true
kill $WEDGED 2>/dev/null || true

echo "RESULT: $((ELAPSED / FLOOD))ms per write, $DROPS drops"

