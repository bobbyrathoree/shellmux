#!/bin/bash
set -uo pipefail

RECORDS=100
PAD=$(head -c 400 /dev/zero | tr '\0' 'X')

START=$(date +%s%3N)

for i in $(seq 1 $RECORDS); do
  PAYLOAD="msg-$i-$PAD"
  if ! timeout 0.002 bash -c 'printf "%s\n" "$1"' _ "$PAYLOAD" 2>/dev/null; then
    true
  fi
done

END=$(date +%s%3N)
ELAPSED=$((END - START))

echo "$RECORDS frames in ${ELAPSED}ms = $(( ELAPSED / RECORDS ))ms per frame"

