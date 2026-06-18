#!/bin/bash
set -uo pipefail

D=$(mktemp -d)
trap "rm -rf $D; pkill -f 'socat' 2>/dev/null || true" EXIT

# CONTROL: Healthy sub alone
echo "=== CONTROL: Single healthy subscriber ==="

SOCK1="$D/s1.sock"
mkdir -p "$D/t1"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/t1" --unix "$SOCK1" >/dev/null 2>&1 &
B1=$!
sleep 1

bash /work/src/shellmux sub "$D/t1" "t" --unix "$SOCK1" >"$D/c1.out" 2>/dev/null &
sleep 0.3

PAD=$(head -c 400 /dev/zero | tr '\0' 'C')
START=$(date +%s%3N)
(printf 'PUB t\n'; for i in {1..100}; do printf 'c-%06d-%s\n' "$i" "$PAD"; done; sleep 1) | socat - "UNIX-CONNECT:$SOCK1" >/dev/null 2>&1
END=$(date +%s%3N)

kill $B1 2>/dev/null || true
sleep 0.2

CONTROL_MS=$((END - START))
echo "1 healthy sub: 100 records in ${CONTROL_MS}ms = $(( CONTROL_MS / 100 ))ms/record"

# TEST 1: Three healthy subs
echo ""
echo "=== TEST 1: Three healthy subscribers ==="

SOCK2="$D/s2.sock"
mkdir -p "$D/t2"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/t2" --unix "$SOCK2" >/dev/null 2>&1 &
B2=$!
sleep 1

for j in {1..3}; do
  bash /work/src/shellmux sub "$D/t2" "t" --unix "$SOCK2" >"$D/t1_h$j.out" 2>/dev/null &
done
sleep 0.3

START=$(date +%s%3N)
(printf 'PUB t\n'; for i in {1..100}; do printf 'h-%06d-%s\n' "$i" "$PAD"; done; sleep 1) | socat - "UNIX-CONNECT:$SOCK2" >/dev/null 2>&1
END=$(date +%s%3N)

kill $B2 2>/dev/null || true
sleep 0.2

TEST1_MS=$((END - START))
echo "3 healthy subs: 100 records in ${TEST1_MS}ms = $(( TEST1_MS / 100 ))ms/record"
echo "Slowdown vs 1 sub: $(( TEST1_MS * 100 / CONTROL_MS ))% (expected 3x from 1 fork -> 3 forks)"

# TEST 2: 3 subs (2 healthy + 1 wedged)
echo ""
echo "=== TEST 2: 2 healthy + 1 wedged subscriber ==="

SOCK3="$D/s3.sock"
mkdir -p "$D/t3"

SHELLMUX_WRITE_TIMEOUT="0.002" bash /work/src/shellmux serve "$D/t3" --unix "$SOCK3" >/dev/null 2>&1 &
B3=$!
sleep 1

bash /work/src/shellmux sub "$D/t3" "t" --unix "$SOCK3" >"$D/t2_h1.out" 2>/dev/null &
bash /work/src/shellmux sub "$D/t3" "t" --unix "$SOCK3" >"$D/t2_h2.out" 2>/dev/null &

# Wedged: reads SUB, then blocks everything
{
  printf 'SUB t\n'
  dd if=/dev/zero bs=1M count=10000 2>/dev/null
} | socat - "UNIX-CONNECT:$SOCK3" 2>/dev/null | ( exec cat >/dev/null &) &

sleep 0.5

START=$(date +%s%3N)
(printf 'PUB t\n'; for i in {1..100}; do printf 'w-%06d-%s\n' "$i" "$PAD"; done; sleep 2) | socat - "UNIX-CONNECT:$SOCK3" >/dev/null 2>&1
END=$(date +%s%3N)

kill $B3 2>/dev/null || true

TEST2_MS=$((END - START))
echo "2 healthy + 1 wedged: 100 records in ${TEST2_MS}ms = $(( TEST2_MS / 100 ))ms/record"
echo "Slowdown vs 3 healthy: $(( TEST2_MS * 100 / TEST1_MS ))%"
echo "Slowdown vs 1 healthy: $(( TEST2_MS * 100 / CONTROL_MS ))%"

echo ""
echo "=== ATTRIBUTION ==="
echo "Per-record cost BREAKDOWN:"
echo "  1 sub (healthy): ~$(( CONTROL_MS / 100 ))ms"
echo "  3 subs (all healthy): ~$(( TEST1_MS / 100 ))ms (3x fork cost)"
echo "  3 subs (2 healthy + 1 wedged): ~$(( TEST2_MS / 100 ))ms (includes timeout-blocked writes)"
echo ""
echo "The wedged sub adds ~$(( (TEST2_MS - TEST1_MS) / 100 ))ms per record"

