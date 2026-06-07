#!/usr/bin/env bash
# tests/chaos_deadline.sh — THE M0 proof harness (and its must-fail controls).
# ============================================================================
# Proves the single falsifiable claim:
#
#   Over N >= 5000 adversarial-timing trials — each landing a publish inside the
#   exact window between "scheduler computed next = MIN(run_at)" and "scheduler
#   entered the blocking read -t" — shellmux fires 0 missed and 0 duplicate
#   deadline deliveries, while idle CPU stays ~0%.
#
# HOW THE RACE IS INJECTED (deterministically, not probabilistically)
#   src/sched.sh has a test hook (SCHED_HOOK=1): between `next=MIN(...)` and the
#   blocking read it writes 'p' to a paused-FIFO and blocks on a release-FIFO.
#   This freezes the loop in the EXACT race window. The harness, while the loop
#   is frozen there, stages a due-now record and pokes the wake-FIFO (a publish
#   landing inside the window), then releases. So the publish lands inside the
#   window on 100% of trials — strictly more adversarial than a harness that
#   merely hopes to hit the window with random timing.
#
#   Lockstep barrier: after releasing trial i, the harness reads the NEXT 'p'.
#   The scheduler only emits that 'p' after completing its timed read AND
#   fire_due for iteration i and looping back to the top. So "next 'p' seen" is
#   a precise barrier meaning "iteration i fully processed" — the harness needs
#   no sleeps/polling to know the fire is done.
#
# TWO FAILURE AXES, classified independently:
#   missed — a trial whose record did NOT fire within `grace` ms of its deadline
#            (a correct scheduler fires within milliseconds via the wake; a
#            broken one fires only on the idle_poll floor, far beyond grace).
#   dup    — any record id that appears in fires.log more than once (fire-once
#            is violated; the single mv commit point is what prevents this).
#
# MUST-FAIL NEGATIVE CONTROLS (a green test that can't fail a wrong impl proves
# nothing). Each control is src/sched.sh with EXACTLY ONE discipline violated:
#   naivesleep — blind `sleep` instead of blocking on the wake-FIFO  => missed>0
#   drainfirst — drains the wake before blocking (honker's lost wakeup) => missed>0
#   nocommit   — fires in place, no mv commit point                  => dup>0
# The harness asserts each control DOES fail on its axis. If a control passes
# clean, the harness is not exercising the race — the whole proof is void.
#
# Run in the Linux dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/chaos_deadline.sh
#   # quick iteration:  N_MAIN=300 bash tests/chaos_deadline.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHED_CORRECT="$ROOT/src/sched.sh"
SCHED_NAIVE="$HERE/negative/sched_naivesleep.sh"
SCHED_DRAIN="$HERE/negative/sched_drainfirst.sh"
SCHED_NOCOMMIT="$HERE/negative/sched_nocommit.sh"

# --- tunables (env-overridable for fast iteration) --------------------------
N_MAIN="${N_MAIN:-5000}"        # correct-variant trials (the gate: >=5000)
N_NEG="${N_NEG:-120}"           # miss-axis control trials
N_DUP="${N_DUP:-60}"            # dup-axis control trials
IDLE_MAIN_MS="${IDLE_MAIN_MS:-10000}"  # large: a lost wake => 10s-late => instant miss
GRACE_MAIN_MS="${GRACE_MAIN_MS:-1000}" # correct fires in ~ms; 1s grace is generous
IDLE_NEG_MS="${IDLE_NEG_MS:-250}"      # control cadence is bottlenecked by this
GRACE_NEG_MS="${GRACE_NEG_MS:-120}"    # < IDLE_NEG so a poll-floor fire = miss
CPU_THRESH="${CPU_THRESH:-5.0}"        # idle CPU% ceiling (expect ~0)

# fork-free now_ms via $REPLY (see src/sched.sh for rationale).
if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local e=$EPOCHREALTIME; REPLY=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }
else
  now_ms() { REPLY=$(date +%s%3N); }
fi

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RST=$'\033[0m'
[ -t 1 ] || { C_RED=; C_GRN=; C_YEL=; C_RST=; }

# ----------------------------------------------------------------------------
# run_chaos <sched_script> <N> <idle_ms> <grace_ms>
#   Drives N adversarial trials against <sched_script>. Sets globals:
#     R_MISSED  R_DUP  R_ONTIME  R_TOTAL_FIRES
# ----------------------------------------------------------------------------
run_chaos() {
  local sched=$1 N=$2 idle_ms=$3 grace_ms=$4
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/deferred" "$dir/outbox"
  mkfifo "$dir/wake.fifo" "$dir/hook_paused.fifo" "$dir/hook_release.fifo" "$dir/dummy.fifo"
  : > "$dir/fires.log"

  # Start the scheduler with the chaos hook armed.
  SCHED_HOOK=1 SCHED_IDLE_POLL_MS="$idle_ms" bash "$sched" "$dir" \
    >"$dir/sched.log" 2>&1 &
  local spid=$!

  # Harness-side fds: read paused (5), write release (6), micro-sleep (3),
  # tail fires.log (9). All held open so FIFOs never block on open / see EOF.
  exec 5<>"$dir/hook_paused.fifo"
  exec 6<>"$dir/hook_release.fifo"
  exec 3<>"$dir/dummy.fifo"
  exec 9<"$dir/fires.log"

  # fork-free micro-sleep: read with timeout on a FIFO that never gets data.
  msleep() { read -t "$1" -u 3 _ 2>/dev/null || true; }

  # Incrementally drain newly-appended fire lines into tallies (O(N) total).
  declare -A fire_cnt fire_ms
  R_TOTAL_FIRES=0
  drain_fires() {
    local pl fm
    while IFS=' ' read -r pl fm <&9; do
      fire_cnt[$pl]=$(( ${fire_cnt[$pl]:-0} + 1 ))
      fire_ms[$pl]=$fm
      R_TOTAL_FIRES=$(( R_TOTAL_FIRES + 1 ))
    done
  }

  R_MISSED=0; R_ONTIME=0
  local i target id elapsed pw

  read -N 1 -u 5 _ || true        # p#1: scheduler frozen post first (empty) scan

  for (( i = 1; i <= N; i++ )); do
    id="C$i"
    # jittered pause width: vary how long the loop sits frozen post-MIN before
    # the publish lands (the "jittered timing" the spec asks for). 0..3 ms.
    pw=$(( RANDOM % 4 ))
    (( pw > 0 )) && msleep "0.00$pw"

    now_ms; target=$REPLY
    # stage-then-poke (the publisher discipline): file FIRST, then the wake.
    printf '%s' "$id" > "$dir/deferred/${target}.${i}"
    (( RANDOM % 3 == 0 )) && msleep 0.001     # jitter stage->poke gap
    printf 'x' > "$dir/wake.fifo"
    (( RANDOM % 3 == 0 )) && msleep 0.001     # jitter poke->release gap
    printf 'r' >&6                            # release: scheduler proceeds

    read -N 1 -u 5 _ || true        # p#(i+1): iteration i fully processed (barrier)
    drain_fires

    # classify trial i
    if [ "${fire_cnt[$id]:-0}" -ge 1 ]; then
      elapsed=$(( ${fire_ms[$id]} - target ))
      if [ "$elapsed" -ge -50 ] && [ "$elapsed" -le "$grace_ms" ]; then
        R_ONTIME=$(( R_ONTIME + 1 ))
      else
        R_MISSED=$(( R_MISSED + 1 ))          # fired, but past grace (poll-floor late)
      fi
    else
      R_MISSED=$(( R_MISSED + 1 ))            # never fired within the barrier
    fi
  done

  # tear down scheduler, then final drain to catch any late/duplicate fires.
  kill -TERM "$spid" 2>/dev/null
  wait "$spid" 2>/dev/null
  drain_fires

  # dup = total fire lines minus the number of distinct ids that ever fired.
  local uniq=${#fire_cnt[@]}
  R_DUP=$(( R_TOTAL_FIRES - uniq ))
  (( R_DUP < 0 )) && R_DUP=0

  exec 5>&- 6>&- 3>&- 9>&-
  rm -rf "$dir"
}

# ----------------------------------------------------------------------------
# idle_cpu_check — start the correct scheduler idle, sample CPU over 5s.
#   Sets R_CPU_PCT.
# ----------------------------------------------------------------------------
idle_cpu_check() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/deferred" "$dir/outbox"
  mkfifo "$dir/wake.fifo"
  : > "$dir/fires.log"
  SCHED_IDLE_POLL_MS=2000 bash "$SCHED_CORRECT" "$dir" >"$dir/sched.log" 2>&1 &
  local spid=$!
  msleep_top() { local f; f="$dir/dummy2"; sleep "$1"; }  # plain sleep ok here (rare)
  sleep 0.5
  local clk; clk=$(getconf CLK_TCK 2>/dev/null || echo 100)
  read_cpu_ticks() { # -> REPLY = utime+stime ticks for $spid
    local s rest
    s=$(< "/proc/$spid/stat") || { REPLY=0; return; }
    rest=${s#*) }
    set -- $rest
    REPLY=$(( ${12} + ${13} ))   # utime + stime (fields 14,15 overall)
  }
  read_cpu_ticks; local t0=$REPLY
  sleep 5
  read_cpu_ticks; local t1=$REPLY
  kill -TERM "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  local dticks=$(( t1 - t0 ))
  # cpu% = (dticks / clk) / 5s * 100  ; compute in integer hundredths
  R_CPU_PCT=$(awk -v d="$dticks" -v c="$clk" 'BEGIN{printf "%.2f", (d/c)/5.0*100.0}')
  rm -rf "$dir"
}

# ============================================================================
# main
# ============================================================================
fail=0
echo "============================================================"
echo " shellmux M0 — deadline scheduler chaos proof"
echo " bash $BASH_VERSION"
echo "============================================================"

echo
echo "${C_YEL}[1/5] CORRECT variant — the gate (N=$N_MAIN, idle=${IDLE_MAIN_MS}ms, grace=${GRACE_MAIN_MS}ms)${C_RST}"
echo "      src/sched.sh : publish lands in the [MIN,read] window every trial."
run_chaos "$SCHED_CORRECT" "$N_MAIN" "$IDLE_MAIN_MS" "$GRACE_MAIN_MS"
echo "      -> missed=$R_MISSED dup=$R_DUP ontime=$R_ONTIME total_fires=$R_TOTAL_FIRES"
if [ "$R_MISSED" -eq 0 ] && [ "$R_DUP" -eq 0 ] && [ "$R_ONTIME" -eq "$N_MAIN" ]; then
  echo "      ${C_GRN}PASS: missed=0 dup=0 over N=$N_MAIN${C_RST}"
else
  echo "      ${C_RED}FAIL: expected missed=0 dup=0 ontime=$N_MAIN${C_RST}"; fail=1
fi

echo
echo "${C_YEL}[2/5] NEGATIVE CONTROL: naivesleep (must MISS) — N=$N_NEG${C_RST}"
echo "      blind sleep ignores the wake -> fires only on the idle_poll floor."
run_chaos "$SCHED_NAIVE" "$N_NEG" "$IDLE_NEG_MS" "$GRACE_NEG_MS"
echo "      -> missed=$R_MISSED dup=$R_DUP ontime=$R_ONTIME"
if [ "$R_MISSED" -gt 0 ]; then
  echo "      ${C_GRN}PASS (control failed as required): missed=$R_MISSED > 0${C_RST}"
else
  echo "      ${C_RED}FAIL: control did NOT miss — harness is not exercising the race!${C_RST}"; fail=1
fi

echo
echo "${C_YEL}[3/5] NEGATIVE CONTROL: drainfirst (must MISS) — N=$N_NEG${C_RST}"
echo "      drains the wake before blocking (honker's lost-wakeup ordering)."
run_chaos "$SCHED_DRAIN" "$N_NEG" "$IDLE_NEG_MS" "$GRACE_NEG_MS"
echo "      -> missed=$R_MISSED dup=$R_DUP ontime=$R_ONTIME"
if [ "$R_MISSED" -gt 0 ]; then
  echo "      ${C_GRN}PASS (control failed as required): missed=$R_MISSED > 0${C_RST}"
else
  echo "      ${C_RED}FAIL: control did NOT miss — harness is not exercising the race!${C_RST}"; fail=1
fi

echo
echo "${C_YEL}[4/5] NEGATIVE CONTROL: nocommit (must DUP) — N=$N_DUP${C_RST}"
echo "      fires in place with no mv commit point -> re-fires every rescan."
run_chaos "$SCHED_NOCOMMIT" "$N_DUP" "$IDLE_NEG_MS" "$GRACE_NEG_MS"
echo "      -> missed=$R_MISSED dup=$R_DUP ontime=$R_ONTIME total_fires=$R_TOTAL_FIRES"
if [ "$R_DUP" -gt 0 ]; then
  echo "      ${C_GRN}PASS (control failed as required): dup=$R_DUP > 0${C_RST}"
else
  echo "      ${C_RED}FAIL: control did NOT dup — dup detection is broken!${C_RST}"; fail=1
fi

echo
echo "${C_YEL}[5/5] IDLE CPU — correct scheduler, 5s idle sample${C_RST}"
idle_cpu_check
echo "      -> scheduler idle CPU = ${R_CPU_PCT}% (threshold ${CPU_THRESH}%)"
if awk -v a="$R_CPU_PCT" -v b="$CPU_THRESH" 'BEGIN{exit !(a < b)}'; then
  echo "      ${C_GRN}PASS: idle CPU ${R_CPU_PCT}% < ${CPU_THRESH}%${C_RST}"
else
  echo "      ${C_RED}FAIL: idle CPU ${R_CPU_PCT}% >= ${CPU_THRESH}%${C_RST}"; fail=1
fi

echo
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo "${C_GRN} M0 RESULT: PASS — missed=0 dup=0 over N=$N_MAIN; all 3 controls${C_RST}"
  echo "${C_GRN}            failed as required; idle CPU ~${R_CPU_PCT}%.${C_RST}"
else
  echo "${C_RED} M0 RESULT: FAIL — see above.${C_RST}"
fi
echo "============================================================"
exit "$fail"
