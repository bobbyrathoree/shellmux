#!/usr/bin/env bash
# tests/negative/sched_nocommit.sh
# ============================================================================
# DELIBERATELY BROKEN NEGATIVE CONTROL — DO NOT USE IN PRODUCTION.
# ============================================================================
# Byte-for-byte copy of src/sched.sh with EXACTLY ONE discipline point violated.
# `diff src/sched.sh tests/negative/sched_nocommit.sh` shows the single knob.
#
# VIOLATION: discipline point #6 — the single commit point. The correct
# scheduler does `mv "$f" "$dest"` to remove the record from deferred/ as it
# fires; fire-once is the property of that mv. This variant fires by reading the
# file IN PLACE (no mv, no rm), so the record stays in deferred/ and fires AGAIN
# on the very next rescan, and the next, and the next. Every redundant wake or
# poll re-delivers it.
#
# EXPECTED under the chaos harness: dup > 0.  This is the control that proves
# the harness can actually detect duplicate fires (not just misses).
set -uo pipefail

DIR="${1:?usage: sched.sh <state_dir>}"
IDLE_POLL_MS="${SCHED_IDLE_POLL_MS:-1000}"
HOOK="${SCHED_HOOK:-0}"

if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local e=$EPOCHREALTIME; REPLY=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }
else
  now_ms() { REPLY=$(date +%s%3N); }
fi

exec 4<>"$DIR/wake.fifo"

hook_on=0
if [ "$HOOK" = "1" ] && [ -p "$DIR/hook_paused.fifo" ] && [ -p "$DIR/hook_release.fifo" ]; then
  exec 7<>"$DIR/hook_paused.fifo"
  exec 8<>"$DIR/hook_release.fifo"
  hook_on=1
fi

running=1
trap 'exit 0' TERM INT   # exit (not running=0): bash retries reads after a non-exiting trap

scan_min() {
  local f b ra min=""
  for f in "$DIR"/deferred/*; do
    [ -e "$f" ] || continue
    b=${f##*/}; ra=${b%%.*}
    if [ -z "$min" ] || [ "$ra" -lt "$min" ]; then min=$ra; fi
  done
  printf '%s' "$min"
}

fire_due() {
  local now f b ra payload
  now_ms; now=$REPLY
  for f in "$DIR"/deferred/*; do
    [ -e "$f" ] || continue
    b=${f##*/}; ra=${b%%.*}
    if [ "$ra" -le "$now" ]; then
      # vvvvvvvvvvvvvvvvvvvvvvvvvv THE ONE BROKEN BLOCK vvvvvvvvvvvvvvvvvvvvvvvvvv
      # CORRECT: mv "$f" "$dest" (single commit point) then deliver then rm.
      # BROKEN: read in place, NO mv/rm -> record persists, re-fires every scan.
      payload=$(cat "$f" 2>/dev/null)
      printf '%s %s\n' "$payload" "$now" >> "$DIR/fires.log"
      # (intentionally no `mv`, no `rm` — the record stays due forever)
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^ THE ONE BROKEN BLOCK ^^^^^^^^^^^^^^^^^^^^^^^^^^
    fi
  done
}

mkdir -p "$DIR/outbox"

while [ "$running" = 1 ]; do
  next=$(scan_min)

  if [ "$hook_on" = 1 ]; then
    printf 'p' >&7
    read -N 1 -u 8 _ || running=0
  fi

  now_ms; now=$REPLY
  if [ -n "$next" ]; then
    to_ms=$(( next - now ))
    (( to_ms < 0 )) && to_ms=0
    (( to_ms > IDLE_POLL_MS )) && to_ms=$IDLE_POLL_MS
  else
    to_ms=$IDLE_POLL_MS
  fi
  printf -v to_s '%d.%03d' $(( to_ms / 1000 )) $(( to_ms % 1000 ))

  read -N 1 -t "$to_s" -u 4 _ || true

  fire_due
done
