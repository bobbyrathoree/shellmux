#!/bin/bash
set -uo pipefail

D=$(mktemp -d)
SOCK="$D/shellmux.sock"
TOPIC="perf"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D" --unix "$SOCK" >/dev/null 2>&1 &
BROKER=$!
sleep 1

(printf 'SUB %s\n' "$TOPIC"; sleep 300) | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | (exec sleep 300) &
sleep 0.5

WFIFO=$(ls "$D/topics/$TOPIC"/sub_*.fifo 2>/dev/null | head -1)
WPID=$(basename "$WFIFO" .fifo | sed 's/sub_//')

PAD=$(head -c 400 /dev/zero | tr '\0' 'x')
PAYLOAD="evt-001-$PAD"

FLOOD=100
START=$(date +%s%3N)

for i in $(seq 1 $FLOOD); do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done

END=$(date +%s%3N)
ELAPSED=$((END - START))

DROPS=$(cat "$D/topics/$TOPIC/drops_$WPID" 2>/dev/null || echo 0)

echo "Per-write: $((ELAPSED / FLOOD))ms, Drops: $DROPS"

kill $BROKER 2>/dev/null || true

