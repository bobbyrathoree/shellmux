#!/usr/bin/env bash
# tests/run_all.sh — run every shellmux test suite and print a one-line summary.
#
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/run_all.sh
#   # fast M0 chaos for CI:  N_MAIN=400 bash tests/run_all.sh
#
# The M0 chaos gate dominates runtime; override N_MAIN for a quick pass. Each
# suite carries its own must-fail negative control (see the suite headers).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${N_MAIN:=5000}" "${N_NEG:=120}" "${N_DUP:=60}"

declare -a SUITES=(
  "smoke.sh"            # M0 tracer: due-now / near-deadline / fire-once
  "chaos_deadline.sh"   # M0 GATE: 0 missed / 0 dup over N>=5000 + 3 controls
  "crash_recovery.sh"   # M1: deferred re-arm + outbox recovery + at-most-once
  "sub_lifecycle.sh"    # M2: SUB register / forget-on-death / TCP + no-trap control
  "flood_wedged.sh"     # M3: bounded fan-out, ps flat, drops visible + leaky control
  "deferred_pub.sh"     # M3b: --delay/--at fire at the deadline + fire-now control
  "introspection.sh"    # M4: ls/cat state + GC reaper (preserves live state)
)

pass=0 fail=0
echo "============================================================"
echo " shellmux — full test suite"
echo " bash $BASH_VERSION   N_MAIN=$N_MAIN"
echo "============================================================"
for s in "${SUITES[@]}"; do
  printf '\n>>> %s\n' "$s"
  if N_MAIN="$N_MAIN" N_NEG="$N_NEG" N_DUP="$N_DUP" bash "$HERE/$s"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "    !!! $s FAILED"
  fi
done

echo ""
echo "============================================================"
echo " SUITES: pass=$pass fail=$fail of ${#SUITES[@]}"
echo "============================================================"
[ "$fail" -eq 0 ]
