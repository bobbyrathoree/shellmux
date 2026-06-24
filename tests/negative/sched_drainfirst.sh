#!/usr/bin/env bash
# tests/negative/sched_drainfirst.sh
# ============================================================================
# DELIBERATELY BROKEN NEGATIVE CONTROL — DO NOT USE IN PRODUCTION.
# ============================================================================
# Byte-for-byte copy of src/sched.sh with EXACTLY ONE discipline point violated.
# `diff src/sched.sh tests/negative/sched_drainfirst.sh` shows the single knob.
#
# VIOLATION: the literal inverse of the borrowed ordering rule —
#     "recv first, then drain — the opposite order would lose a wakeup when a
#      publish lands between refill and drain."
# This variant DRAINS the wake-FIFO (consumes all buffered poke bytes with a
# non-blocking read loop) and THEN blocks on a fresh read. A poke that the
# publisher sent while the scheduler was computing/frozen is consumed by the
# drain WITHOUT being matched to a post-drain rescan-block, so the subsequent
# blocking read has nothing buffered and sleeps the stale idle_poll. The
# deadline is missed until the poll floor — exactly the lost wakeup the rule
# warns about.
#
# EXPECTED under the chaos harness: missed > 0.
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

  # vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv THE ONE BROKEN ADDITION vvvvvvvvvvvvvvvvvvvvvvv
  # CORRECT has NO drain here. BROKEN drains buffered pokes BEFORE blocking,
  # consuming the publisher's wake so the block below sleeps the stale idle_poll.
  # (-t 0.001, not -t 0: read -t 0 is a non-consuming availability probe — it
  #  would spin forever; a tiny positive timeout actually consumes the byte.)
  while read -N 1 -t 0.001 -u 4 _ 2>/dev/null; do :; done
  # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ THE ONE BROKEN ADDITION ^^^^^^^^^^^^^^^^^^^^^^^

  read -N 1 -t "$to_s" -u 4 _ || true

  fire_due
done
