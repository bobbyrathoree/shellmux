#!/bin/bash
set -uo pipefail

D=$(mktemp -d)
FIFO="$D/test.fifo"
mkfifo "$FIFO"

# The drainer loop (from shellmux)
# This simulates what the drainer subprocess does
(
  while IFS= read -r len; do
    case "$len" in *[!0-9]*|'') continue ;; esac
    IFS= read -r -N "$len" -t 0.5 payload || continue
    [ "${#payload}" -eq "$len" ] || continue
    
    # Write to stdout (simulating socket write)
    if ! timeout 0.002 bash -c 'printf "%s\n" "$1"' _ "$payload" 2>/dev/null; then
      echo "DROP" >&2
    fi
  done < "$FIFO"
) > "$D/output.txt" 2>&1 &

DRAINER=$!
sleep 0.1

# Feed records into the FIFO
RECORDS=100
PAD=$(head -c 400 /dev/zero | tr '\0' 'D')

START=$(date +%s%3N)

for i in $(seq 1 $RECORDS); do
  PAYLOAD="msg-$i-$PAD"
  FRAME="${#PAYLOAD}"$'\n'"$PAYLOAD"
  printf '%s' "$FRAME" > "$FIFO"
done

# Close the FIFO to signal EOF
exec 3<&- >/dev/null 2>&1
sleep 0.5

END=$(date +%s%3N)
ELAPSED=$((END - START))

wait $DRAINER 2>/dev/null || true

# Count output lines
COUNT=$(wc -l < "$D/output.txt")

echo "Drainer solo test:"
echo "  $RECORDS records in ${ELAPSED}ms"
echo "  Output lines: $COUNT"
echo "  Per-record: $(( ELAPSED / RECORDS ))ms"

rm -rf "$D"

