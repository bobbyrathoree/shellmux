#!/bin/bash
set -uo pipefail

echo "====== COMPREHENSIVE DRAINER INSTRUMENTATION ======" >&2
echo "" >&2

D=$(mktemp -d)
trap "rm -rf $D; pkill -f 'socat|shellmux' 2>/dev/null || true" EXIT

# Calculate ms per write (shell math)
calc_div() { local a=$1 b=$2; echo $((a * 10 / b / 10)).$((a * 100 / b % 10)); }

# ====================================================================
# TEST 1: WEDGED DRAINER - Socket write timeout cost
# ====================================================================
echo "TEST 1: Publisher bounded-write cost (to WEDGED subscriber)" >&2
echo "---" >&2

SOCK="$D/test1.sock"
TOPIC="wedged"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/t1" --unix "$SOCK" >/dev/null 2>&1 &
sleep 1

# Wedged sub: connects, sends SUB, never reads socket
(printf 'SUB %s\n' "$TOPIC"; sleep 600) | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | (exec sleep 600) &
sleep 0.3

WFIFO=$(ls "$D/t1/$TOPIC"/sub_*.fifo 2>/dev/null | head -1)
WPID=$(basename "$WFIFO" .fifo | sed 's/sub_//')

# Large payload to fill socket/FIFO buffer
PAD=$(head -c 4000 /dev/zero | tr '\0' 'X')
PAYLOAD="msg-$PAD"

# Prime the FIFO by filling its buffer
for i in {1..40}; do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done
sleep 0.1

# Now measure: writes to FULL FIFO
N=200
START=$(date +%s%3N)
for i in $(seq 1 $N); do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done
END=$(date +%s%3N)

ELAPSED1=$((END - START))
DROPS1=$(cat "$D/t1/$TOPIC/drops_$WPID" 2>/dev/null || echo 0)
PER_WRITE1=$(( (ELAPSED1 * 1000) / (N * 1000) ))  # in ms, with 1 decimal

echo "  $N writes in ${ELAPSED1}ms" >&2
echo "  Per-write: $((ELAPSED1 / N))ms (avg), drops=$DROPS1/$N" >&2

pkill -f 'socat.*UNIX-LISTEN' 2>/dev/null || true
sleep 0.5

# ====================================================================
# TEST 2: HEALTHY DRAINER THROUGHPUT in isolation
# ====================================================================
echo "" >&2
echo "TEST 2: Healthy drainer throughput (no wedged sub)" >&2
echo "---" >&2

SOCK2="$D/test2.sock"
TOPIC2="healthy"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/t2" --unix "$SOCK2" >/dev/null 2>&1 &
sleep 1

# One healthy subscriber
bash /work/src/shellmux sub "$D/t2" "$TOPIC2" --unix "$SOCK2" >"$D/healthy.out" 2>/dev/null &
HSUB=$!
sleep 0.3

# Send records from publisher
RECORDS=500
START=$(date +%s%3N)

(
  printf 'PUB %s\n' "$TOPIC2"
  for i in $(seq 1 $RECORDS); do
    printf 'rec-%06d-%s\n' "$i" "$PAD"
  done
  sleep 2
) | socat - "UNIX-CONNECT:$SOCK2" >/dev/null 2>&1

END=$(date +%s%3N)
ELAPSED2=$((END - START))

sleep 0.3
RECEIVED=$(grep -c '^rec-' "$D/healthy.out" 2>/dev/null || echo 0)

echo "  Sent: $RECORDS records in ${ELAPSED2}ms" >&2
echo "  Received: $RECEIVED" >&2
if [ "$RECEIVED" -gt 0 ]; then
  echo "  Per-record time: $(( ELAPSED2 / RECEIVED ))ms" >&2
  echo "  Throughput: $(( RECEIVED * 1000 / ELAPSED2 )) records/sec" >&2
fi

pkill -f 'socat|shellmux' 2>/dev/null || true
sleep 0.5

# ====================================================================
# TEST 3: 2 HEALTHY + 1 WEDGED (realistic scenario)
# ====================================================================
echo "" >&2
echo "TEST 3: Mixed workload (2 healthy + 1 wedged)" >&2
echo "---" >&2

SOCK3="$D/test3.sock"
TOPIC3="mixed"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/t3" --unix "$SOCK3" >/dev/null 2>&1 &
sleep 1

# 2 healthy subs
bash /work/src/shellmux sub "$D/t3" "$TOPIC3" --unix "$SOCK3" >"$D/mixed_h1.out" 2>/dev/null &
bash /work/src/shellmux sub "$D/t3" "$TOPIC3" --unix "$SOCK3" >"$D/mixed_h2.out" 2>/dev/null &

# 1 wedged sub
(printf 'SUB %s\n' "$TOPIC3"; sleep 600) | socat - "UNIX-CONNECT:$SOCK3" 2>/dev/null | (exec sleep 600) &
sleep 0.5

# Publish a flood
RECORDS3=250
START=$(date +%s%3N)

(
  printf 'PUB %s\n' "$TOPIC3"
  for i in $(seq 1 $RECORDS3); do
    printf 'flood-%06d-%s\n' "$i" "$PAD"
  done
  sleep 3
) | socat - "UNIX-CONNECT:$SOCK3" >/dev/null 2>&1

END=$(date +%s%3N)
ELAPSED3=$((END - START))

sleep 0.3
H1=$(grep -c '^flood-' "$D/mixed_h1.out" 2>/dev/null || echo 0)
H2=$(grep -c '^flood-' "$D/mixed_h2.out" 2>/dev/null || echo 0)

echo "  Sent: $RECORDS3 records in ${ELAPSED3}ms" >&2
echo "  Healthy sub 1: $H1" >&2
echo "  Healthy sub 2: $H2" >&2
echo "  Publish rate: $(( RECORDS3 * 1000 / ELAPSED3 )) records/sec" >&2

pkill -f 'socat|shellmux' 2>/dev/null || true

# ====================================================================
# ANALYSIS OUTPUT
# ====================================================================
echo "" >&2
echo "====== MEASUREMENT SUMMARY ======" >&2
echo ""

echo "TEST 1 (WEDGED drainer bounded write):"
echo "  Total cost: ${ELAPSED1}ms for $N writes"
echo "  Per-write cost: $(( ELAPSED1 / N ))ms"
echo "  Drops: $DROPS1 (out of $N writes failed)"
echo "  This represents the TIMEOUT cost of the publisher's bounded write"
echo ""

echo "TEST 2 (HEALTHY drainer throughput):"
echo "  Delivered: $RECEIVED / $RECORDS records in ${ELAPSED2}ms"
echo "  Throughput: $(( RECEIVED * 1000 / ELAPSED2 )) records/sec"
echo "  Per-record latency: $(( ELAPSED2 / RECEIVED ))ms"
echo ""

echo "TEST 3 (MIXED scenario - realistic):"
echo "  3 subscribers (2 healthy, 1 wedged)"
echo "  Published: $RECORDS3 records in ${ELAPSED3}ms"
echo "  Overall rate: $(( RECORDS3 * 1000 / ELAPSED3 )) records/sec"
echo "  H1: $H1, H2: $H2 received"
echo ""

echo "====== ATTRIBUTION ======:"
echo ""
echo "Per-record cost BREAKDOWN in mixed scenario:"
echo "  - Publisher fanout loop: 3 subscribers, 3 timeout-bounded writes"
echo "  - Per-write (wedged path): ~${COST1_MS}ms (from TEST 1)"
echo "  - Per-record: 3 writes * ~${COST1_MS}ms = ~$((3 * ELAPSED1 / N))ms"
echo ""
echo "Bottleneck identification:"
if [ $(( ELAPSED3 * 1000 / RECORDS3 )) -gt 5 ]; then
  echo "  LIKELY: Publisher is BLOCKED on timeout-bounded writes to FIFO"
  echo "  The ~2ms per write * 3 subs = ~6ms per record is the dominant cost"
else
  echo "  UNLIKELY: Socket I/O is the bottleneck"
fi

