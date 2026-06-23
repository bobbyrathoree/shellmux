#!/usr/bin/env bash
# tests/introspection.sh — M4: the filesystem IS the admin interface + GC reaper.
# ============================================================================
# shellmux has no admin protocol: every piece of broker state is inspectable with
# plain `ls`/`cat`, and stale state is swept by a reaper. This test asserts both.
#
#   I1 (topics are directories). `ls topics/` enumerates live topics.
#   I2 (subscriber liveness = FIFO existence). `ls topics/<t>/sub_*.fifo | wc -l`
#      is the live subscriber count; it drops when a subscriber disconnects.
#   I3 (drops are cat-able). `cat topics/<t>/drops_<pid>` shows a subscriber's
#      dropped-record count.
#   I4 (deferred queue is inspectable). `ls deferred/` shows pending timed records;
#      `sort` over the names reveals the next deadline (the scheduler's MIN scan).
#   I5 (GC reaper). `shellmux _reap <dir>` removes: a stale drops_<pid> whose
#      sub_<pid>.fifo no longer exists, and an empty topic directory. It must NOT
#      remove a live subscriber's FIFO, a live drops file, or a non-empty topic.
#
# MUST-FAIL NEGATIVE CONTROL (I5'): assert that BEFORE the reap, the stale
# drops_<pid> file is present — otherwise "the reaper removed it" proves nothing
# (it might have never existed). And assert the reaper leaves LIVE state intact.
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/introspection.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
now_ms() { date +%s%3N; }

echo "== introspection: src/shellmux =="
[ -f "$SHELLMUX" ] || { echo "MISSING $SHELLMUX"; exit 2; }

cleanup_all() { pkill -P $$ 2>/dev/null; }
trap cleanup_all EXIT

D="$(mktemp -d)"; SOCK="$D/s.sock"
bash "$SHELLMUX" serve "$D" --unix "$SOCK" >"$D/broker.log" 2>&1 & BROKER=$!
sleep 1

# a live subscriber on topic 'weather'
bash "$SHELLMUX" sub "$D" weather --unix "$SOCK" >"$D/w.out" 2>/dev/null & SUB=$!
for _ in $(seq 1 60); do [ "$(ls "$D/topics/weather"/sub_*.fifo 2>/dev/null | wc -l)" -ge 1 ] && break; sleep 0.05; done

# --- I1: topics are directories ---------------------------------------------
if [ -d "$D/topics/weather" ] && ls "$D/topics" | grep -qx weather; then
  ok "I1 topics are directories (ls topics/ shows 'weather')"
else
  bad "I1 topic dir not visible via ls"
fi

# --- I2: subscriber liveness = FIFO existence -------------------------------
n=$(ls "$D/topics/weather"/sub_*.fifo 2>/dev/null | wc -l)
if [ "$n" -eq 1 ]; then
  ok "I2 live subscriber count via ls sub_*.fifo = $n"
else
  bad "I2 expected 1 live sub FIFO, got $n"
fi

# capture the live sub's pid (from its FIFO name) for the reaper test
LIVE_FIFO="$(ls "$D/topics/weather"/sub_*.fifo 2>/dev/null | head -1)"
LIVE_PID="${LIVE_FIFO##*/sub_}"; LIVE_PID="${LIVE_PID%.fifo}"

# --- I3: drops are cat-able (create one by hand to assert the read path) ----
printf '7\n' > "$D/topics/weather/drops_$LIVE_PID"
if [ "$(cat "$D/topics/weather/drops_$LIVE_PID" 2>/dev/null)" = "7" ]; then
  ok "I3 drops_<pid> is a plain cat-able counter (=7)"
else
  bad "I3 drops_<pid> not readable"
fi

# --- I4: deferred queue is inspectable --------------------------------------
printf 'later\n' | bash "$SHELLMUX" pub "$D" weather --delay 30 --unix "$SOCK" >/dev/null 2>&1 &
for _ in $(seq 1 60); do [ "$(ls "$D/deferred" 2>/dev/null | wc -l)" -ge 1 ] && break; sleep 0.05; done
dn=$(ls "$D/deferred" 2>/dev/null | wc -l)
nextname="$(ls "$D/deferred" 2>/dev/null | sort | head -1)"
if [ "$dn" -ge 1 ] && [ -n "$nextname" ]; then
  ok "I4 deferred queue visible via ls (pending=$dn, next=$nextname)"
else
  bad "I4 deferred queue not visible (pending=$dn)"
fi

# --- I5 setup: create a STALE drops file (pid with no FIFO) + an empty topic -
STALE_PID=999999
printf '3\n' > "$D/topics/weather/drops_$STALE_PID"   # no sub_999999.fifo exists
: > "$D/topics/weather/.wlock_$STALE_PID"             # stale per-sub fan-out lock (no FIFO)
mkdir -p "$D/topics/_emptytopic"                       # empty topic dir
# I5' control precondition: the stale files must exist before reaping.
if [ -e "$D/topics/weather/drops_$STALE_PID" ] && [ -e "$D/topics/weather/.wlock_$STALE_PID" ] && [ -d "$D/topics/_emptytopic" ]; then
  ok "I5' precondition: stale drops_$STALE_PID, .wlock_$STALE_PID and empty topic exist before reap"
else
  bad "I5' precondition failed (test bug)"
fi

# --- I5: reap ---------------------------------------------------------------
bash "$SHELLMUX" _reap "$D" 2>/dev/null
stale_gone=0; stalelock_gone=0; live_kept=0; livefifo_kept=0; empty_gone=0
[ -e "$D/topics/weather/drops_$STALE_PID" ] || stale_gone=1
[ -e "$D/topics/weather/.wlock_$STALE_PID" ] || stalelock_gone=1
[ -e "$D/topics/weather/drops_$LIVE_PID" ] && live_kept=1
[ -p "$LIVE_FIFO" ] && livefifo_kept=1
[ -d "$D/topics/_emptytopic" ] || empty_gone=1
if [ "$stale_gone" = 1 ] && [ "$stalelock_gone" = 1 ] && [ "$empty_gone" = 1 ]; then
  ok "I5 reaper removed the stale drops file, stale .wlock AND the empty topic dir"
else
  bad "I5 reaper missed stale state (drops_gone=$stale_gone wlock_gone=$stalelock_gone empty_gone=$empty_gone)"
fi
if [ "$live_kept" = 1 ] && [ "$livefifo_kept" = 1 ] && [ -d "$D/topics/weather" ]; then
  ok "I5 reaper PRESERVED live state (live drops, live FIFO, non-empty topic)"
else
  bad "I5 reaper destroyed live state (drops=$live_kept fifo=$livefifo_kept) — too aggressive!"
fi

kill "$SUB" "$BROKER" 2>/dev/null; pkill -P "$BROKER" 2>/dev/null
rm -rf "$D"

echo "== introspection result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
