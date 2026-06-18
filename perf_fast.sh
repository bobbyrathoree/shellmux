#!/bin/bash
set -uo pipefail

echo "====== DRAINER PERFORMANCE TEST (FAST) ======" >&2

D=$(mktemp -d)
trap "rm -rf $D; kill %1 %2 2>/dev/null || true" EXIT

SOCK="$D/shellmux.sock"
TOPIC="perf"

# Start broker
SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D" --unix "$SOCK" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Create wedged subscriber
(printf 'SUB %s\n' "$TOPIC"; sleep 300) | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | (exec sleep 300) &
sleep 0.3

WFIFO=$(ls "$D/topics/$TOPIC"/sub_*.fifo 2>/dev/null | head -1)
WPID=$(basename "$WFIFO" .fifo | sed 's/sub_//')

# Large payload to fill socket quickly
PAD=$(head -c 4000 /dev/zero | tr '\0' 'Y')
PAYLOAD="x-$PAD"

# Prime FIFO
for i in {1..40}; do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done

sleep 0.1

# Measure writes on full FIFO
N=200
START=$(date +%s%3N)
for i in $(seq 1 $N); do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done
END=$(date +%s%3N)

ELAPSED=$((END - START))
DROPS=$(cat "$D/topics/$TOPIC/drops_$WPID" 2>/dev/null || echo 0)

echo "RESULT:" >&2
echo "  Payload: ${#PAYLOAD} bytes" >&2
echo "  Writes: $N in ${ELAPSED}ms" >&2
echo "  Per-write: $ELAPSED / $N = $(echo "scale=2; $ELAPSED / $N" | bc)ms" >&2
echo "  Drops: $DROPS" >&2
echo "  Drop rate: $(echo "scale=0; $DROPS * 1000 / $ELAPSED" | bc) drops/sec" >&2

# Print structured output
echo ""
echo "PER_WRITE_MS=$(echo "scale=2; $ELAPSED / $N" | bc)"
echo "DROPS=$DROPS"
echo "ELAPSED_MS=$ELAPSED"
echo "PAYLOAD_BYTES=${#PAYLOAD}"

