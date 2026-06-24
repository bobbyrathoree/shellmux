#!/usr/bin/env bash
# tests/negative/sched_firenow.sh
# ============================================================================
# DELIBERATELY BROKEN NEGATIVE CONTROL for tests/deferred_pub.sh (D1').
# A copy of src/sched.sh with EXACTLY ONE change: the due-check
# `if [ "$ra" -le "$now" ]` is removed, so it fires EVERY deferred record on the
# first scan, IGNORING its run_at. A deferred publish therefore arrives BEFORE
# its deadline. The test asserts this control DOES fire early; if it waited like
# the real scheduler, the D1/D2 "fires at the deadline" proof would be vacuous.
# ============================================================================
# (original header follows)
# src/sched.sh — shellmux data-derived deadline scheduler (THE contribution).
#
# Fires timed (deferred) records race-free against concurrent publishes, with
# zero idle CPU and no timer wheel. State lives ENTIRELY on disk; nothing in
# memory is authoritative.
#
# Ported discipline (from a durable-deadline job scheduler; mechanisms borrowed,
# not invented here):
#   - next = MIN(run_at) over pending state.  (the queue's `SELECT MIN(deadline)`)
#   - block-until-deadline, then re-read.      (its recv-until-deadline + drain)
#   - whole-second resolution is faithful, not a downgrade.  (the reference uses
#     a whole-second timer, so our ~1s floor matches it)
#   - stage-then-poke ordering ("recv first, then drain — the opposite order
#     would lose a wakeup").
#
# The six-point discipline (docs/design.md), realized below:
#   1. State on disk as deferred/<run_at_ms>.<seq>. (publisher writes these)
#   2. Each loop: next = MIN(run_at) over filenames, then a single blocking
#      read with timeout = min(idle_poll, next-now) on a long-lived wake-FIFO.
#   3. Publishers stage the file FIRST, then poke the wake-FIFO (publisher side).
#   4. Every wake (poke OR timeout) triggers a FULL deferred/ re-scan.
#   5. The idle_poll timeout is the correctness floor: even if every wake is
#      lost, the next poll rescans and fires. The wake only improves latency.
#   6. The single commit point per due record is the `mv` out of deferred/.
#      Fire-once is the property of that mv.
#
# Usage:  bash src/sched.sh <state_dir>
#   <state_dir> must contain: deferred/ (dir), wake.fifo (fifo). The scheduler
#   creates outbox/ and appends fired records to fires.log as "<payload> <ms>".
#
# Env:
#   SCHED_IDLE_POLL_MS   poll-fallback ceiling in ms (default 1000).
#   SCHED_HOOK           if "1" AND hook_paused.fifo/hook_release.fifo exist in
#                        <state_dir>, the loop pauses between next=MIN and the
#                        blocking read, for the chaos harness to inject a race.
set -uo pipefail

DIR="${1:?usage: sched.sh <state_dir>}"
IDLE_POLL_MS="${SCHED_IDLE_POLL_MS:-1000}"
HOOK="${SCHED_HOOK:-0}"

# now_ms -> sets $REPLY to current unix time in ms. The REPLY convention (vs
# echo + command substitution) avoids a subshell fork on every call, which
# matters because the loop runs hot under the chaos harness. Prefer bash>=5
# $EPOCHREALTIME (a pure builtin, no fork); fall back to `date +%s%3N` on
# bash 4 (one fork/call — still fine, the loop blocks most of the time).
if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local e=$EPOCHREALTIME; REPLY=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }
else
  now_ms() { REPLY=$(date +%s%3N); }
fi

# --- wake FIFO held open read+write so a poke buffers even when not reading,
#     and the reader never sees EOF when pokers come and go (a long-lived
#     receiver holding the channel open, as in the borrowed relay's exec-held fd). ---
exec 4<>"$DIR/wake.fifo"

# --- optional chaos hook: a second pair of FIFOs lets the harness freeze the
#     loop in the exact window between "next computed" and "read entered". ---
hook_on=0
if [ "$HOOK" = "1" ] && [ -p "$DIR/hook_paused.fifo" ] && [ -p "$DIR/hook_release.fifo" ]; then
  exec 7<>"$DIR/hook_paused.fifo"
  exec 8<>"$DIR/hook_release.fifo"
  hook_on=1
fi

running=1
# NOTE: a bare `trap 'running=0'` does NOT work here — bash retries an
# interrupted `read` after a non-exiting trap, so a signal that lands while the
# loop is blocked in `read -N 1` would never break out. `exit 0` terminates
# immediately regardless of where we are blocked. The `running` flag still
# provides a graceful stop when a wake-FIFO read returns EOF.
trap 'exit 0' TERM INT

# next = MIN(run_at_ms) over deferred/<run_at_ms>.<seq> filenames.
# Echoes the min, or empty if no pending records. (the queue's next-claim-at query.)
scan_min() {
  local f b ra min=""
  for f in "$DIR"/deferred/*; do
    [ -e "$f" ] || continue            # glob-no-match guard
    b=${f##*/}; ra=${b%%.*}
    if [ -z "$min" ] || [ "$ra" -lt "$min" ]; then min=$ra; fi
  done
  printf '%s' "$min"
}

# deliver <outbox_file>: the pluggable delivery step. By default (standalone /
# M0 chaos) it appends "<payload> <fire_ms>" to fires.log — so the chaos test is
# byte-identical to before. The broker sets SCHED_FIRE_HOOK to a command that is
# invoked as `$SCHED_FIRE_HOOK <outbox_file>` to fan the record into a topic.
# Either way the record has ALREADY left deferred/ via the mv commit point, so
# fire-once holds regardless of what delivery does.
deliver() {
  local dest=$1 now=$2
  if [ -n "${SCHED_FIRE_HOOK:-}" ]; then
    $SCHED_FIRE_HOOK "$dest"
  else
    printf '%s %s\n' "$(cat "$dest" 2>/dev/null)" "$now" >> "$DIR/fires.log"
  fi
}

# Fire every due record: mv out of deferred/ (THE commit point), then deliver.
# A record that has left deferred/ cannot be seen by a later scan -> fire-once.
fire_due() {
  local now f b ra dest
  now_ms; now=$REPLY
  for f in "$DIR"/deferred/*; do
    [ -e "$f" ] || continue
    b=${f##*/}; ra=${b%%.*}
    # vvvv THE ONE BROKEN CHANGE: no `[ "$ra" -le "$now" ]` due-check — fire NOW.
    dest="$DIR/outbox/$b"
    if mv "$f" "$dest" 2>/dev/null; then
      deliver "$dest" "$now"
      rm -f "$dest"
    fi
    # ^^^^ fires every record on first scan, ignoring run_at (delivers early).
  done
}

mkdir -p "$DIR/outbox"

# --- startup crash recovery (M1) --------------------------------------------
# The single commit point is the `mv` of a record out of deferred/ into outbox/.
# A crash *after* that mv but *before* delivery+rm leaves the record stranded in
# outbox/. On startup we sweep outbox/ and re-deliver any survivor, then rm it.
# This realizes at-most-once-modulo-crash: a record that crashed at the commit
# boundary fires at most once more on restart (NOT the reference's full claim-lease
# machinery — explicitly punted). Deferred re-arm needs no special code: scan_min
# reads deferred/ from disk every iteration, so surviving pending files re-arm by
# construction. SCHED_NO_RECOVER=1 skips this sweep (test-only negative control).
if [ "${SCHED_NO_RECOVER:-0}" != "1" ]; then
  for f in "$DIR"/outbox/*; do
    [ -e "$f" ] || continue
    now_ms; deliver "$f" "$REPLY"
    rm -f "$f"
  done
fi

while [ "$running" = 1 ]; do
  next=$(scan_min)                                   # (2) next = MIN(run_at)

  # ---- CHAOS HOOK: between MIN and the blocking read (the race window) ----
  if [ "$hook_on" = 1 ]; then
    printf 'p' >&7                                   # "I am paused, post-MIN"
    read -N 1 -u 8 _ || running=0                    # block until harness releases
  fi

  now_ms; now=$REPLY
  if [ -n "$next" ]; then
    to_ms=$(( next - now ))
    (( to_ms < 0 )) && to_ms=0
    (( to_ms > IDLE_POLL_MS )) && to_ms=$IDLE_POLL_MS
  else
    to_ms=$IDLE_POLL_MS                               # (5) poll floor when idle
  fi
  printf -v to_s '%d.%03d' $(( to_ms / 1000 )) $(( to_ms % 1000 ))

  # (2) one blocking read; -N 1 so a newline-less 1-byte poke wakes us (a
  # line-oriented read would hang on a poke that carries no newline). Wake on
  # poke OR timeout; either way we fall through to the full rescan. While
  # blocked here the process is in a syscall -> ~0% CPU.
  read -N 1 -t "$to_s" -u 4 _ || true

  fire_due                                            # (4) full rescan + (6) fire
done
