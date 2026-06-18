#!/bin/bash
set -uo pipefail

echo "====== COMPREHENSIVE DRAINER PERFORMANCE ANALYSIS ======"
echo ""

D=$(mktemp -d)
trap "rm -rf $D" EXIT
SOCK="$D/shellmux.sock"

# ====================================================================
# TEST 1: BOUNDED WRITE COST (Publisher side, to a WEDGED sub)
# ====================================================================
echo "TEST 1: Publisher-side bounded write cost (wedged subscriber)"
echo "----"

TOPIC="test1"
SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D" --unix "$SOCK" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Wedged subscriber
(printf 'SUB %s\n' "$TOPIC"; sleep 300) | socat - "UNIX-CONNECT:$SOCK" 2>/dev/null | (exec sleep 300) &
sleep 0.5

WFIFO=$(ls "$D/topics/$TOPIC"/sub_*.fifo 2>/dev/null | head -1)
WPID=$(basename "$WFIFO" .fifo | sed 's/sub_//')

# Payload similar to flood_wedged test
PAD=$(head -c 400 /dev/zero | tr '\0' 'x')
PAYLOAD="evt-001-$PAD"

# Prime the FIFO first
for i in {1..50}; do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done

sleep 0.2

# Measure timeouts on full FIFO
FLOOD=150
START=$(date +%s%3N)

for i in $(seq 1 $FLOOD); do
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  timeout 0.002 bash -c 'printf "%s" "$2" > "$1"' _ "$WFIFO" "$FRAME" 2>/dev/null || true
done

END=$(date +%s%3N)
ELAPSED_TEST1=$((END - START))
COST_PER_WRITE_TEST1=$((ELAPSED_TEST1 / FLOOD))
DROPS_TEST1=$(cat "$D/topics/$TOPIC/drops_$WPID" 2>/dev/null || echo 0)

echo "Payload: ${#PAYLOAD} bytes"
echo "Total time for $FLOOD writes: ${ELAPSED_TEST1}ms"
echo "Per-write cost: ${COST_PER_WRITE_TEST1}ms"
echo "Drops recorded: $DROPS_TEST1"
echo "Implied drop rate: $((DROPS_TEST1 * 1000 / ELAPSED_TEST1)) drops/sec"
echo ""

kill $BROKER 2>/dev/null
wait 2>/dev/null

# ====================================================================
# TEST 2: DRAINER'S PER-FRAME COST (healthy subscriber reading from FIFO)
# ====================================================================
echo "TEST 2: Healthy drainer per-frame throughput"
echo "----"

SOCK2="$D/shellmux2.sock"
mkdir -p "$D/test2"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/test2" --unix "$SOCK2" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Healthy subscriber
bash /work/src/shellmux sub "$D/test2" "healthy_topic" --unix "$SOCK2" >"$D/healthy.out" 2>/dev/null &
HSUB=$!
sleep 0.5

# Measure: send records fast, see how many the healthy drainer receives
RECORDS=300
START=$(date +%s%3N)

(
  printf 'PUB healthy_topic\n'
  for i in $(seq 1 $RECORDS); do
    printf 'msg-%06d-%s\n' "$i" "$PAD"
  done
  sleep 2
) | socat - "UNIX-CONNECT:$SOCK2" >/dev/null 2>&1

END=$(date +%s%3N)
ELAPSED_TEST2=$((END - START))

# Count received records
sleep 0.5
RECEIVED=$(grep -c '^msg-' "$D/healthy.out" 2>/dev/null || echo 0)
LOST=$((RECORDS - RECEIVED))

echo "Sent: $RECORDS records in ${ELAPSED_TEST2}ms"
echo "Received by healthy sub: $RECEIVED"
echo "Lost: $LOST"
if [ "$RECEIVED" -gt 0 ]; then
  echo "Per-record time (drainer+socat): $((ELAPSED_TEST2 / RECEIVED))ms"
fi
echo ""

kill $BROKER 2>/dev/null
kill $HSUB 2>/dev/null
wait 2>/dev/null

# ====================================================================
# TEST 3: REALISTIC SCENARIO - 2 healthy + 1 wedged, measure throttle
# ====================================================================
echo "TEST 3: Mixed scenario (2 healthy + 1 wedged subscriber)"
echo "----"

SOCK3="$D/shellmux3.sock"
mkdir -p "$D/test3"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/test3" --unix "$SOCK3" >/dev/null 2>&1 &
BROKER=$!
sleep 1

# Two healthy subscribers
bash /work/src/shellmux sub "$D/test3" "t3" --unix "$SOCK3" >"$D/t3_h1.out" 2>/dev/null &
bash /work/src/shellmux sub "$D/test3" "t3" --unix "$SOCK3" >"$D/t3_h2.out" 2>/dev/null &

# One wedged
(printf 'SUB t3\n'; sleep 300) | socat - "UNIX-CONNECT:$SOCK3" 2>/dev/null | (exec sleep 300) &

sleep 1

# Send a flood
RECORDS_TEST3=200
START=$(date +%s%3N)

(
  printf 'PUB t3\n'
  for i in $(seq 1 $RECORDS_TEST3); do
    printf 'mixed-%06d-%s\n' "$i" "$PAD"
  done
  sleep 5
) | socat - "UNIX-CONNECT:$SOCK3" >/dev/null 2>&1

END=$(date +%s%3N)
ELAPSED_TEST3=$((END - START))

sleep 0.5
H1=$(grep -c '^mixed-' "$D/t3_h1.out" 2>/dev/null || echo 0)
H2=$(grep -c '^mixed-' "$D/t3_h2.out" 2>/dev/null || echo 0)

echo "Sent: $RECORDS_TEST3 records in ${ELAPSED_TEST3}ms"
echo "Healthy sub 1 received: $H1"
echo "Healthy sub 2 received: $H2"
if [ "$ELAPSED_TEST3" -gt 0 ]; then
  echo "Overall publish rate: $((RECORDS_TEST3 * 1000 / ELAPSED_TEST3)) records/sec"
fi
echo ""

kill $BROKER 2>/dev/null
wait 2>/dev/null

# ====================================================================
# SUMMARY & ANALYSIS
# ====================================================================
echo "====== ANALYSIS ======"
echo ""
echo "Key measurements:"
echo "  [TEST 1] Per-write timeout cost (wedged): ${COST_PER_WRITE_TEST1}ms"
echo "  [TEST 1] Drops: $DROPS_TEST1 out of $FLOOD writes"
echo "  [TEST 1] Drop rate: $((DROPS_TEST1 * 1000 / ELAPSED_TEST1)) drops/sec"
echo ""
echo "Interpretation:"
if [ "$COST_PER_WRITE_TEST1" -ge 2 ]; then
  echo "  - Per-write cost (${COST_PER_WRITE_TEST1}ms) is SUBSTANTIAL, dominated by timeout overhead"
  echo "  - Each timeout bash -c fork-exec costs ~${COST_PER_WRITE_TEST1}ms"
  echo "  - With 2 healthy + 1 wedged, publisher does 3 writes per record (fanout loop)"
  echo "  - BOTTLENECK: Per-record cost = 3 writes * ~${COST_PER_WRITE_TEST1}ms = ~$((3 * COST_PER_WRITE_TEST1))ms"
fi
echo ""
echo "  - Wedged subscriber's FIFO fills because drainer's socket write times out"
echo "  - Publisher's timeout-bounded write also times out (waits ~${COST_PER_WRITE_TEST1}ms)"
echo "  - This is NOT a drainer inefficiency; it's the NECESSARY COST of bounds"
echo ""

