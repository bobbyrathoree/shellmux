#!/bin/bash
set -uo pipefail

echo "Fork cost analysis"

# Test fork cost
START=$(date +%s%3N)
for i in {1..100}; do
  timeout 0.002 bash -c 'printf "x"' >/dev/null 2>&1 || true
done
END=$(date +%s%3N)

echo "100 timeout+bash forks: $((END - START))ms"
echo "Per-fork: $(( (END - START) / 100 ))ms"

