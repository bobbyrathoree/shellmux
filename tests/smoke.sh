#!/usr/bin/env bash
# tests/smoke.sh — M0 tracer-bullet smoke test for src/sched.sh
#
# This is the TDD tracer: the smallest end-to-end proof that the scheduler's
# core path works (stage a due record -> it fires). It is NOT the chaos proof
# (that is chaos_deadline.sh); it exists to drive src/sched.sh into existence
# one behavior at a time and to serve as a fast post-change smoke check.
#
# Run inside the Linux dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/smoke.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHED="$ROOT/src/sched.sh"

pass=0 fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

now_ms() { date +%s%3N; }

# Fresh state dir per test.
new_state() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/deferred" "$d/outbox"
  mkfifo "$d/wake.fifo"
  : > "$d/fires.log"
  printf '%s' "$d"
}

# Stage a deferred record: deferred/<run_at_ms>.<seq> with content = id.
stage() {
  local dir=$1 run_at_ms=$2 id=$3 seq=${4:-$RANDOM$RANDOM}
  printf '%s' "$id" > "$dir/deferred/${run_at_ms}.${seq}"
}

poke() { printf 'x' > "$1/wake.fifo"; }

# Wait up to $2 ms for id $3 to appear in fires.log; echo its fire_ms or empty.
wait_fire() {
  local dir=$1 timeout_ms=$2 id=$3 deadline fire
  deadline=$(( $(now_ms) + timeout_ms ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    fire="$(grep -m1 "^${id} " "$dir/fires.log" 2>/dev/null | awk '{print $2}')"
    [ -n "$fire" ] && { printf '%s' "$fire"; return 0; }
    sleep 0.01
  done
  return 1
}

start_sched() { # $1=dir ; extra env via caller
  # Redirect sched's stdout/stderr to a log so it does NOT inherit (and hold
  # open forever) the command-substitution pipe of `pid="$(start_sched ...)"`.
  SCHED_IDLE_POLL_MS="${SCHED_IDLE_POLL_MS:-30000}" bash "$SCHED" "$1" \
    >"$1/sched.log" 2>&1 &
  echo $!
}

echo "== smoke: src/sched.sh =="
[ -f "$SCHED" ] || { echo "MISSING $SCHED — RED (expected before GREEN)"; exit 2; }

# --- T1: a record already due fires promptly --------------------------------
d="$(new_state)"
pid="$(start_sched "$d")"
stage "$d" "$(now_ms)" "T1"
poke "$d"
if f="$(wait_fire "$d" 2000 T1)"; then ok "T1 due-now record fires"; else bad "T1 did not fire"; fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
rm -rf "$d"

# --- T2: a future record fires at ~run_at (not early, not idle_poll late) ----
d="$(new_state)"
pid="$(start_sched "$d")"
target=$(( $(now_ms) + 700 ))
stage "$d" "$target" "T2"
poke "$d"
if f="$(wait_fire "$d" 3000 T2)"; then
  delta=$(( f - target ))
  # allow [-50, +400] ms slop; must NOT fire >1s early (would be a bug)
  if [ "$delta" -ge -50 ] && [ "$delta" -le 400 ]; then ok "T2 future record fires near deadline (delta=${delta}ms)"
  else bad "T2 fired off-deadline (delta=${delta}ms)"; fi
else bad "T2 did not fire"; fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
rm -rf "$d"

# --- T3: fire-once — a record appears in fires.log exactly once -------------
d="$(new_state)"
pid="$(start_sched "$d")"
stage "$d" "$(now_ms)" "T3"
poke "$d"; poke "$d"; poke "$d"   # redundant pokes must not cause duplicate fire
wait_fire "$d" 2000 T3 >/dev/null
sleep 0.3
n="$(grep -c '^T3 ' "$d/fires.log" 2>/dev/null || echo 0)"
if [ "$n" = "1" ]; then ok "T3 fires exactly once under redundant pokes"; else bad "T3 fired $n times (want 1)"; fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
rm -rf "$d"

echo "== smoke result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
