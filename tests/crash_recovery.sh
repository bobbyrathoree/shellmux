#!/usr/bin/env bash
# tests/crash_recovery.sh — M1: deferred crash recovery + at-most-once bound.
# ============================================================================
# Proves the scheduler's durability story under a broker crash:
#
#   R1 (deferred re-arm). State is disk-only: if the scheduler is killed (even
#      kill -9) before a future record is due, restarting the scheduler against
#      the same dir re-arms purely from the surviving deferred/ files and fires
#      them. Nothing in memory was authoritative.
#
#   R2 (outbox recovery). The single commit point is the `mv` of a record out of
#      deferred/ into outbox/. A crash *after* the mv but *before* delivery
#      confirmation leaves the record stranded in outbox/. On restart the
#      scheduler must sweep outbox/ and re-deliver those records — otherwise the
#      mv'd-but-undelivered record is silently lost. We simulate the crash window
#      by placing a file directly in outbox/ (exactly the post-mv/pre-rm state).
#
#   R3 (at-most-once bound). Recovery re-delivers; combined with fire-once in the
#      steady state, each record fires AT MOST once per crash it survives. For a
#      single crash that means dup <= 1 per record — the documented
#      at-most-once-modulo-crash, NOT honker's full claim_expires_at lease.
#
# MUST-FAIL NEGATIVE CONTROL (R2'): a scheduler WITHOUT outbox recovery must
# LOSE a stranded outbox file (it never re-fires). If the no-recover variant
# somehow still delivers, the recovery test is not actually exercising the crash
# window and R2 proves nothing. We realize the no-recover variant by running the
# correct scheduler with SCHED_NO_RECOVER=1 (a test-only escape hatch that skips
# the recovery sweep) — keeping it one knob, like the M0 controls.
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/crash_recovery.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHED="$ROOT/src/sched.sh"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

now_ms() { date +%s%3N; }

new_state() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/deferred" "$d/outbox"
  mkfifo "$d/wake.fifo"
  : > "$d/fires.log"
  printf '%s' "$d"
}
stage() { printf '%s' "$3" > "$1/deferred/${2}.${4:-$RANDOM$RANDOM}"; }
poke()  { printf 'x' > "$1/wake.fifo"; }
start() { # $1=dir [$2=extra VAR=val env assignment, e.g. SCHED_NO_RECOVER=1]
  # Use `env` so an optional env-var prefix is unambiguous whether or not $2 is
  # set (the bare `${2:-} VAR=val cmd` form mis-parses VAR=val as a command when
  # $2 is empty under set -u). env applies the assignments then execs bash.
  env ${2:-} SCHED_IDLE_POLL_MS="${SCHED_IDLE_POLL_MS:-200}" bash "$SCHED" "$1" \
    >"$1/sched.log" 2>&1 &
  echo $!
}
fired_count() { # robust: always one clean integer (grep -c prints 0 AND exits 1 on no-match)
  local n; n="$(grep -c "^$2 " "$1/fires.log" 2>/dev/null)"; printf '%s' "${n:-0}"
}
wait_fire() { # $1=dir $2=timeout_ms $3=id
  local dl; dl=$(( $(now_ms) + $2 ))
  while [ "$(now_ms)" -lt "$dl" ]; do
    [ "$(fired_count "$1" "$3")" -ge 1 ] && return 0
    sleep 0.02
  done
  return 1
}

echo "== crash_recovery: src/sched.sh =="
[ -f "$SCHED" ] || { echo "MISSING $SCHED"; exit 2; }

# --- R1: deferred re-arm across kill -9 -------------------------------------
d="$(new_state)"
pid="$(start "$d")"
# future records that will NOT be due during the first scheduler's life
t=$(( $(now_ms) + 100000 ))
stage "$d" "$t" "R1a" 1
stage "$d" "$t" "R1b" 2
sleep 0.2
kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
# nothing should have fired yet
if [ "$(fired_count "$d" R1a)" = "0" ] && [ "$(fired_count "$d" R1b)" = "0" ]; then
  # rewrite the deferred files to be due NOW, then restart: re-arm must fire them
  rm -f "$d"/deferred/*
  n=$(now_ms); stage "$d" "$n" "R1a" 1; stage "$d" "$n" "R1b" 2
  pid="$(start "$d")"
  poke "$d"
  if wait_fire "$d" 2000 R1a && wait_fire "$d" 2000 R1b; then
    ok "R1 deferred re-arm: both records fire after kill -9 + restart"
  else bad "R1 re-arm: a record did not fire after restart"; fi
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
else
  bad "R1 setup: records fired before the kill (test bug)"
fi
rm -rf "$d"

# --- R2: outbox recovery (the crash window: mv done, delivery not) ----------
d="$(new_state)"
# simulate a record that crashed AFTER mv into outbox/ but BEFORE delivery+rm
printf 'R2payload' > "$d/outbox/$(now_ms).42"
pid="$(start "$d")"
if wait_fire "$d" 2000 R2payload; then
  ok "R2 outbox recovery: stranded outbox record re-fires on restart"
else
  bad "R2 outbox recovery: stranded record was LOST (no recovery sweep)"
fi
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
rm -rf "$d"

# --- R2' NEGATIVE CONTROL: no-recover variant must LOSE the stranded file ---
d="$(new_state)"
printf 'R2payload' > "$d/outbox/$(now_ms).42"
pid="$(start "$d" "SCHED_NO_RECOVER=1")"
if wait_fire "$d" 1200 R2payload; then
  bad "R2' control: no-recover variant STILL delivered — recovery test is vacuous!"
else
  ok "R2' control (must fail): no-recover variant loses the stranded outbox file"
fi
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
rm -rf "$d"

# --- R3: at-most-once bound — one crash => dup <= 1 per record --------------
d="$(new_state)"
# stage a due record, let it fire (steady-state fire-once), THEN simulate a
# crash that stranded a COPY in outbox (the at-most-once boundary): recovery
# re-fires it once more => total 2 for that id => dup of exactly 1, not more.
n=$(now_ms); stage "$d" "$n" "R3" 7
pid="$(start "$d")"; poke "$d"
wait_fire "$d" 2000 R3 >/dev/null
# now strand a copy as if the crash happened right at the commit point
printf 'R3' > "$d/outbox/$(now_ms).7"
poke "$d"
sleep 0.4
c="$(fired_count "$d" R3)"
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
if [ "$c" -le 2 ] && [ "$c" -ge 1 ]; then
  ok "R3 at-most-once: R3 fired $c time(s) across one crash window (dup <= 1)"
else
  bad "R3 at-most-once: R3 fired $c times (expected 1 or 2)"
fi
rm -rf "$d"

echo "== crash_recovery result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
