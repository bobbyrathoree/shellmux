#!/usr/bin/env bash
# tests/concurrent_frames.sh — R3: frame integrity under CONCURRENT publishers.
# ============================================================================
# THE PROPERTY (and the bug it closes). The spec promises length-prefixed framing
# means "a torn frame is detected by short read and discarded, not concatenated"
# and that "healthy subs only ever emit intact, correctly-sized records"
# (flood_wedged.sh F4). flood_wedged.sh proved that for a SINGLE publisher with
# <PIPE_BUF records. But fanout() writes each frame with a fresh open()+write()
# (one `timeout bash -c 'printf > fifo'` per record), and POSIX guarantees a write
# to a FIFO is atomic ONLY up to PIPE_BUF (4096 bytes on Linux). With TWO OR MORE
# publishers (each its own socat-forked process) concurrently fanning out records
# LARGER than PIPE_BUF to the SAME subscriber FIFO, their writes interleave in the
# pipe — and a torn/concatenated frame whose byte count happens to match the
# length prefix slips PAST the drainer's short-read guard and reaches the healthy
# subscriber corrupted (verified: 6 publishers x 6000-byte records -> ~2 corrupt
# frames delivered per run, reproducibly).
#
# THE FIX. Serialize each per-FIFO fan-out write under a PER-SUBSCRIBER flock
# (`.wlock_<pid>`), so a multi-PIPE_BUF frame is written atomically with respect
# to other concurrent publishers. The lock is per-subscriber, NOT global, so
# writes to DIFFERENT subscribers still proceed in parallel and a wedged peer
# never couples to a healthy one (the M3 isolation property is preserved). The
# write stays `timeout`-bounded, so a wedged sub is still abandoned after
# WRITE_TIMEOUT and bumps drops_<pid> — the lock changes only atomicity, not the
# backpressure contract.
#
#   G1 (concurrent large frames stay intact). N publishers concurrently flood a
#      topic with records > PIPE_BUF; a healthy subscriber receives ZERO torn or
#      concatenated frames (every delivered line is exactly one record).
#
# MUST-FAIL NEGATIVE CONTROL (G1'): the SAME scenario with SHELLMUX_NO_WLOCK=1
# (one knob: the per-FIFO write lock disabled, i.e. the pre-fix behavior) MUST
# deliver at least one corrupt frame. If the control delivers zero corrupt
# frames, the test is not exercising the interleave race and G1 proves nothing.
#
# This is OFF the missed=0/dup=0 proof axis (it is the free fan-out data plane,
# not the scheduler) — chaos_deadline.sh is re-run after this fix to confirm 0/0
# still holds.
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/concurrent_frames.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# tunables
NPUB="${NPUB:-6}"            # concurrent publishers (each a distinct letter)
FRAMELEN="${FRAMELEN:-6000}" # > PIPE_BUF (4096) so writes are non-atomic
NREC="${NREC:-60}"           # records per publisher

echo "== concurrent_frames: src/shellmux (PIPE_BUF=$(getconf PIPE_BUF / 2>/dev/null || echo '?')) =="
[ -f "$SHELLMUX" ] || { echo "MISSING $SHELLMUX"; exit 2; }

cleanup_all() { pkill -P $$ 2>/dev/null; }
trap cleanup_all EXIT

# run_frames <no_wlock(0|1)> -> sets R_RECV, R_CORRUPT for one healthy subscriber.
run_frames() {
  local no_wlock="$1"
  local d; d=$(mktemp -d); local sock="$d/s.sock"
  # generous write timeout so a HEALTHY write is never falsely abandoned mid-frame
  # under load — we are testing interleaving, not backpressure.
  SHELLMUX_NO_WLOCK="$no_wlock" SHELLMUX_WRITE_TIMEOUT=2 \
    bash "$SHELLMUX" serve "$d" --unix "$sock" >"$d/b.log" 2>&1 & local bp=$!
  sleep 1
  ( bash "$SHELLMUX" sub "$d" t --unix "$sock" >"$d/recv.txt" 2>/dev/null ) & local sub=$!
  # wait for the sub FIFO to register
  local i; for i in $(seq 1 60); do [ "$(ls "$d/topics/t"/sub_*.fifo 2>/dev/null | wc -l)" -ge 1 ] && break; sleep 0.05; done

  # build one >PIPE_BUF line per publisher, each a distinct single letter, fork-free.
  local letters=(A B C D E F G H I J K L) pids=() p L line
  for ((p=0;p<NPUB;p++)); do
    L=${letters[$p]}
    printf -v line '%*s' "$FRAMELEN" ''; line=${line// /$L}
    ( local k; for ((k=0;k<NREC;k++)); do printf '%s\n' "$line"; done \
        | SHELLMUX_WRITE_TIMEOUT=2 bash "$SHELLMUX" pub "$d" t --unix "$sock" ) & pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
  sleep 2; kill "$sub" 2>/dev/null

  R_RECV=$(grep -c . "$d/recv.txt" 2>/dev/null); R_RECV=${R_RECV:-0}
  # corrupt = a delivered line that is not exactly FRAMELEN chars of a single letter
  R_CORRUPT=$(awk -v fl="$FRAMELEN" '
    { pure=($0 ~ /^A+$/||$0 ~ /^B+$/||$0 ~ /^C+$/||$0 ~ /^D+$/||$0 ~ /^E+$/||$0 ~ /^F+$/||$0 ~ /^G+$/||$0 ~ /^H+$/||$0 ~ /^I+$/||$0 ~ /^J+$/||$0 ~ /^K+$/||$0 ~ /^L+$/);
      if (length($0)!=fl || !pure) c++ } END{print c+0}' "$d/recv.txt")
  kill "$bp" 2>/dev/null; pkill -P "$bp" 2>/dev/null
  rm -rf "$d"
}

# --- G1: the FIX — no torn/concatenated frames reach a healthy subscriber -----
run_frames 0
echo "  (locked: healthy sub received=$R_RECV frames, corrupt=$R_CORRUPT)"
if [ "$R_CORRUPT" -eq 0 ]; then
  ok "G1 concurrent >PIPE_BUF publishers delivered ZERO torn/concatenated frames"
else
  bad "G1 healthy sub got $R_CORRUPT corrupt frames under concurrent large publishers"
fi

# --- G1': the CONTROL — write lock disabled MUST corrupt -----------------------
run_frames 1
echo "  (NO_WLOCK control: healthy sub received=$R_RECV frames, corrupt=$R_CORRUPT)"
if [ "$R_CORRUPT" -gt 0 ]; then
  ok "G1' control (write lock disabled) delivered $R_CORRUPT corrupt frame(s) as required"
else
  bad "G1' control delivered ZERO corrupt frames — the interleave race isn't exercised; G1 is vacuous!"
fi

echo "== concurrent_frames result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
