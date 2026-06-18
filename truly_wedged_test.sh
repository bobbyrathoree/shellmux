#!/bin/bash
set -uo pipefail

echo "=== TRUE WEDGED SUB TEST ===" >&2

D=$(mktemp -d)
trap "rm -rf $D; pkill -f 'socat' 2>/dev/null || true" EXIT

SOCK="$D/shellmux.sock"
TOPIC="test"

# Start broker
SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D" --unix "$SOCK" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Start 2 healthy subs
bash /work/src/shellmux sub "$D" "$TOPIC" --unix "$SOCK" >"$D/h1.out" 2>/dev/null &
H1=$!
bash /work/src/shellmux sub "$D" "$TOPIC" --unix "$SOCK" >"$D/h2.out" 2>/dev/null &
H2=$!

# Create a TRUE wedged subscriber using dd to block stdin read
# This keeps the socket open but NEVER reads from it - even blocking on a write
{
  printf 'SUB %s\n' "$TOPIC"
  # Use dd to ensure socat writes have somewhere to go but we never read
  dd if=/dev/zero bs=1024 count=1000000 2>/dev/null
} | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | ( exec cat > /dev/null &) &
WEDGED=$!

sleep 1

echo "Starting publish..." >&2
START=$(date +%s%3N)

# Publish records
PAD=$(head -c 400 /dev/zero | tr '\0' 'y')
(
  printf 'PUB %s\n' "$TOPIC"
  for i in $(seq 1 200); do
    printf 'msg-%06d-%s\n' "$i" "$PAD"
  done
  sleep 2
) | socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1

END=$(date +%s%3N)
ELAPSED=$((END - START))

sleep 0.5

H1_COUNT=$(grep -c '^msg-' "$D/h1.out" 2>/dev/null || echo 0)
H2_COUNT=$(grep -c '^msg-' "$D/h2.out" 2>/dev/null || echo 0)

echo "Results:" >&2
echo "  Time: ${ELAPSED}ms" >&2
echo "  H1: $H1_COUNT, H2: $H2_COUNT" >&2
if [ "$ELAPSED" -gt 0 ]; then
  echo "  Rate: $(( 200 * 1000 / ELAPSED )) records/sec" >&2
fi

# Check for drops
DROPS=$(find "$D/topics/$TOPIC" -name "drops_*" -exec cat {} \; 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
echo "  Drops: $DROPS" >&2

kill $BROKER 2>/dev/null || true
kill $WEDGED 2>/dev/null || true

