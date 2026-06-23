#!/usr/bin/env bash
# tests/corrupt_deferred.sh — R3: a corrupt on-disk deferred record must cost a
# scan-skip, NEVER halt the scheduler (global-liveness robustness).
# ============================================================================
# THE PROPERTY. State is the filesystem (the project's own introspection model is
# `ls`/`cat` on the state dir), so a deferred record can become malformed two
# ways the validated broker PUB path cannot: a publisher crashed mid-write of the
# `deferred/<run_at_ms>.<seq>` file, or any raw/adversarial producer writing into
# the filesystem-native state dir. A deferred filename whose run_at prefix is not
# a non-negative integer (e.g. `deferred/0corrupt.1`) used to poison the
# scheduler's `next=MIN(run_at)` arithmetic: scan_min assigned the bareword into
# `min`, and the main loop's `to_ms=$(( next - now ))` then hit `set -u` ->
# `unbound variable` -> the scheduler DIED. Because nothing fires while it is
# dead, ONE corrupt file blocked delivery of EVERY other pending well-formed
# record until an operator cleaned it up — a global-liveness denial of service.
#
# The fix is consistent with the scheduler's existing robustness posture ("a
# spurious/dropped wake costs one directory scan, never a missed message"): a
# malformed deferred filename costs one skip, never a halt. scan_min and fire_due
# skip any deferred entry whose prefix is not [0-9]+.
#
#   C1 (corrupt file is survived). With a corrupt `deferred/0corrupt.1` present
#      (it lexically sorts BEFORE numeric names, so it is the first MIN candidate
#      — the worst case), a valid due-now record STILL fires and the scheduler is
#      STILL ALIVE afterward. Off the missed=0/dup=0 proof axis (corrupt files are
#      unreachable through the validated broker), but a real liveness guarantee.
#
# MUST-FAIL NEGATIVE CONTROL (C1'): the SAME scenario with SCHED_NO_SKIP_CORRUPT=1
# (one knob: the skip guard disabled, i.e. the pre-fix behavior) MUST crash the
# scheduler so the valid record never fires. If the control does NOT crash, the
# guard is not load-bearing and C1 proves nothing.
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/corrupt_deferred.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHED="$ROOT/src/sched.sh"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local e=$EPOCHREALTIME; REPLY=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }
else
  now_ms() { REPLY=$(date +%s%3N); }
fi

echo "== corrupt_deferred: src/sched.sh =="
[ -f "$SCHED" ] || { echo "MISSING $SCHED"; exit 2; }

# run_corrupt <no_skip(0|1)> -> sets R_FIRED (1 if VALIDPAY in fires.log) and
# R_ALIVE (1 if the scheduler process was still running before teardown).
run_corrupt() {
  local no_skip="$1"
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/deferred" "$dir/outbox"
  mkfifo "$dir/wake.fifo"
  : > "$dir/fires.log"

  # a CORRUPT deferred record: non-numeric run_at prefix, sorts before numerics
  # (worst case — it becomes the first MIN candidate).
  printf 'corrupt-body' > "$dir/deferred/0corrupt.1"
  # a VALID due-now record: run_at_ms in the past so it is immediately due.
  now_ms; local due=$(( REPLY - 1000 ))
  printf 'VALIDPAY' > "$dir/deferred/${due}.222"

  SCHED_NO_SKIP_CORRUPT="$no_skip" SCHED_IDLE_POLL_MS=300 \
    bash "$SCHED" "$dir" >"$dir/sched.log" 2>&1 &
  local sp=$!

  # poke to wake the scheduler immediately, then give it time to scan+fire.
  printf 'x' > "$dir/wake.fifo" 2>/dev/null || true
  sleep 1

  R_ALIVE=0; kill -0 "$sp" 2>/dev/null && R_ALIVE=1
  R_FIRED=0; grep -q 'VALIDPAY' "$dir/fires.log" 2>/dev/null && R_FIRED=1

  kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  R_LOG="$(tr '\n' '|' < "$dir/sched.log")"
  rm -rf "$dir"
}

# --- C1: the FIX — corrupt file survived, valid record fires, sched alive -----
run_corrupt 0
if [ "$R_FIRED" = 1 ] && [ "$R_ALIVE" = 1 ]; then
  ok "C1 corrupt deferred file skipped; valid record fired and scheduler stayed alive"
else
  bad "C1 corrupt deferred file broke the scheduler (fired=$R_FIRED alive=$R_ALIVE; log: $R_LOG)"
fi

# --- C1': the CONTROL — skip disabled MUST crash on the same input ------------
run_corrupt 1
if [ "$R_FIRED" = 0 ] || [ "$R_ALIVE" = 0 ]; then
  ok "C1' control (skip disabled) DIED on the corrupt file as required (fired=$R_FIRED alive=$R_ALIVE)"
else
  bad "C1' control did NOT crash (fired=$R_FIRED alive=$R_ALIVE) — the skip guard is not load-bearing!"
fi

echo "== corrupt_deferred result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
