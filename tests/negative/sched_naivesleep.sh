#!/usr/bin/env bash
# tests/negative/sched_naivesleep.sh
# ============================================================================
# DELIBERATELY BROKEN NEGATIVE CONTROL — DO NOT USE IN PRODUCTION.
# ============================================================================
# This is a byte-for-byte copy of src/sched.sh with EXACTLY ONE discipline
# point violated, so `diff src/sched.sh tests/negative/sched_naivesleep.sh`
# shows the single knob.
#
# VIOLATION: discipline point #2/#4 — instead of BLOCKING ON THE WAKE-FIFO with
# `read -N 1 -t`, this variant does a blind `sleep "$to_s"`. It is the canonical
# "just sleep $((next-now))" dismissal made real. Because `next` was computed
# BEFORE the publish landed in the race window, `to_s` is the stale idle_poll;
# the scheduler sleeps the full idle_poll, ignoring the poke entirely, and only
# fires on the next rescan — idle_poll LATE. The chaos harness counts that as a
# MISS (deadline whooshed by; fired only on the poll floor).
#
# EXPECTED under the chaos harness: missed > 0.  If this passes clean, the
# harness is not exercising the race and the whole proof is void.
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
  local now f b ra dest payload
  now_ms; now=$REPLY
  for f in "$DIR"/deferred/*; do
    [ -e "$f" ] || continue
    b=${f##*/}; ra=${b%%.*}
    if [ "$ra" -le "$now" ]; then
      dest="$DIR/outbox/$b"
      if mv "$f" "$dest" 2>/dev/null; then
        payload=$(cat "$dest" 2>/dev/null)
        printf '%s %s\n' "$payload" "$now" >> "$DIR/fires.log"
        rm -f "$dest"
      fi
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

  # vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv THE ONE BROKEN LINE vvvvvvvvvvvvvvvvvvvvvvvvvvv
  # CORRECT would be: read -N 1 -t "$to_s" -u 4 _ || true   (wake on poke OR timeout)
  # BROKEN: blind sleep ignores the wake-FIFO poke -> sleeps the stale idle_poll.
  sleep "$to_s"
  # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ THE ONE BROKEN LINE ^^^^^^^^^^^^^^^^^^^^^^^^^^^

  fire_due
done
