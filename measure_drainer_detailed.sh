#!/bin/bash
set -uo pipefail

D=$(mktemp -d)
SOCK="$D/shellmux.sock"
TOPIC="perf"

# Start broker
SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D" --unix "$SOCK" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Start ONE healthy subscriber
bash /work/src/shellmux sub "$D" "$TOPIC" --unix "$SOCK" >"$D/healthy.out" 2>/dev/null &
HSUB=$!
sleep 0.5

# Publish records and time them
RECORDS=100
PAD=$(head -c 400 /dev/zero | tr '\0' 'P')

START=$(date +%s%3N)

(
  printf 'PUB %s\n' "$TOPIC"
  for i in $(seq 1 $RECORDS); do
    printf 'msg-%06d-%s\n' "$i" "$PAD"
  done
  sleep 2
) | socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1

END=$(date +%s%3N)
ELAPSED=$((END - START))

sleep 0.5
COUNT=$(grep -c '^msg-' "$D/healthy.out" 2>/dev/null || echo 0)

echo "Published: $RECORDS records in ${ELAPSED}ms"
echo "Received: $COUNT records"
echo "Throughput: $(( RECORDS * 1000 / ELAPSED )) records/sec"
echo "Per-record: $(( ELAPSED / RECORDS ))ms"

kill $BROKER $HSUB 2>/dev/null || true

