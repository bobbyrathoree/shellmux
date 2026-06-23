#!/usr/bin/env bash
# tests/input_validation.sh — R-round-001: validate the data that DERIVES the deadline.
# ============================================================================
# The M0 chaos proof shows the scheduler fires WELL-FORMED deadlines race-free.
# It says nothing about what happens when the data that derives those deadlines
# is hostile. The round-1 product evaluators (adversarial-flooder, scripter-
# integrator) found, independently, that the input boundary fails silently:
#
#   F1  `pub T --at xyz`     -> handler crashes server-side (`$2: unbound`/arith
#                              error), message silently dropped, publisher rc=0.
#   F7  `pub T --at 9e10`    -> a year-5138 record parks in deferred/ forever.
#   H1  `pub '../../x'`      -> topic name is an unsanitized path component, so
#                              the broker mkdir's a directory OUTSIDE the state
#                              dir (a publisher-controlled mkdir-anywhere primitive).
#   F4  `sub --help`         -> `$2: unbound variable` crash under `set -u`.
#
# This suite pins the FIX: the broker must REJECT hostile control input at the
# boundary (nonzero rc, one-line reason, nothing staged/created) and never let
# it reach the scheduler or the filesystem outside topics/.
#
# MUST-FAIL NEGATIVE CONTROL: every validation gate is behind SHELLMUX_NO_VALIDATE=1.
# With validation DISABLED the suite asserts the bugs COME BACK (handler crash,
# far-future staging, traversal mkdir). A reviewer can `SHELLMUX_NO_VALIDATE=1`
# to watch the exact failure the gate prevents — the must-fail-control discipline,
# made one-knob auditable like SHELLMUX_NO_TRAP / SHELLMUX_LEAKY_WRITE / SCHED_NO_RECOVER.
#
# Run in the dev container:
#   docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/input_validation.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHELLMUX="$ROOT/src/shellmux"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "== input_validation: src/shellmux =="
[ -f "$SHELLMUX" ] || { echo "MISSING $SHELLMUX"; exit 2; }

cleanup_all() { pkill -P $$ 2>/dev/null; }
trap cleanup_all EXIT

# start_broker <dir> <sock> [env...] — echoes broker pid
start_broker() { local d="$1" s="$2"; shift 2; bash "$SHELLMUX" serve "$d" --unix "$s" >"$d/b.log" 2>&1 & echo $!; }
stop_broker()  { kill "$1" 2>/dev/null; pkill -P "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# V1 — bad --at/--delay is REJECTED at the publisher, handler does NOT crash.
#   The publisher returns nonzero; broker.log carries NO unbound/arith error.
# ---------------------------------------------------------------------------
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"; sleep 1
v1_ok=1
for badarg in "--at xyz" "--delay 1.5" "--at -5" "--delay abc"; do
  printf 'p\n' | bash "$SHELLMUX" pub "$D" t1 $badarg --unix "$SOCK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || { v1_ok=0; echo "    ($badarg was ACCEPTED, rc=0)"; }
done
sleep 0.3
if grep -qE 'unbound variable|invalid arithmetic|syntax error' "$D/b.log" 2>/dev/null; then
  v1_ok=0; echo "    (broker.log shows a server-side crash:)"; grep -E 'unbound|arithmetic|syntax' "$D/b.log" | head -2
fi
if [ "$v1_ok" = 1 ]; then ok "V1 malformed --at/--delay rejected (pub rc!=0, no handler crash in broker.log)"
else bad "V1 malformed --at/--delay not cleanly rejected"; fi
stop_broker "$BROKER"; rm -rf "$D"

# ---------------------------------------------------------------------------
# V2 — a far-future --at is REJECTED, not parked in deferred/ forever (F7).
# ---------------------------------------------------------------------------
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"; sleep 1
printf 'p\n' | bash "$SHELLMUX" pub "$D" t1 --at 99999999999 --unix "$SOCK" >/dev/null 2>&1
rc=$?; sleep 0.3
parked="$(ls "$D/deferred/" 2>/dev/null)"
if [ "$rc" -ne 0 ] && [ -z "$parked" ]; then
  ok "V2 far-future --at rejected (pub rc=$rc, deferred/ empty)"
else
  bad "V2 far-future --at parked a record (rc=$rc, deferred/=[$parked])"
fi
stop_broker "$BROKER"; rm -rf "$D"

# ---------------------------------------------------------------------------
# V3 — a LEGITIMATE --delay still works end-to-end (no over-rejection / no
#   regression of the deferred path the chaos proof depends on).
# ---------------------------------------------------------------------------
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"; sleep 1
bash "$SHELLMUX" sub "$D" clock --unix "$SOCK" >"$D/c.out" 2>/dev/null &
sleep 0.5
printf 'tick\n' | bash "$SHELLMUX" pub "$D" clock --delay 1 --unix "$SOCK" >/dev/null 2>&1 &
got=""
for _ in $(seq 1 80); do
  grep -q '^tick' "$D/c.out" 2>/dev/null && { got=1; break; }
  sleep 0.05
done
if [ -n "$got" ]; then ok "V3 legitimate --delay 1 still fires (validation does not over-reject)"
else bad "V3 legitimate --delay 1 did NOT fire — validation broke the deferred path"; fi
stop_broker "$BROKER"; rm -rf "$D"

# ---------------------------------------------------------------------------
# V4 — a hostile topic name does NOT create a dir outside topics/ (H1).
#   Traversal, absolute-ish, and metacharacter names are rejected; the publish
#   to a vanished/illegal topic is a clean no-op, not a filesystem write.
# ---------------------------------------------------------------------------
D="$(mktemp -d)"; SOCK="$D/s.sock"
BROKER="$(start_broker "$D" "$SOCK")"; sleep 1
TARGET="/tmp/SHELLMUX_PWNED_$$"; rm -rf "$TARGET"
printf 'x\n' | bash "$SHELLMUX" pub "$D" "../../../../../../tmp/SHELLMUX_PWNED_$$" --unix "$SOCK" >/dev/null 2>&1
sleep 0.4
escaped=0
[ -d "$TARGET" ] && { escaped=1; rm -rf "$TARGET"; }
# also ensure no dir climbed out of topics/ into the state root
climbed=0
for d in "$D"/*/; do
  case "$(basename "$d")" in topics|deferred|outbox) ;; *) climbed=1 ;; esac
done
if [ "$escaped" = 0 ] && [ "$climbed" = 0 ]; then
  ok "V4 hostile topic name created NO dir outside topics/ (traversal rejected)"
else
  bad "V4 hostile topic name escaped (outside=$escaped, climbed-into-state-root=$climbed)"
fi
# a normal topic still works
bash "$SHELLMUX" sub "$D" weather --unix "$SOCK" >/dev/null 2>/dev/null &
sleep 0.5
if [ -d "$D/topics/weather" ]; then ok "V4b legitimate topic 'weather' still registers"
else bad "V4b legitimate topic name was over-rejected"; fi
stop_broker "$BROKER"; rm -rf "$D"

# ---------------------------------------------------------------------------
# V5 — `sub --help` / `pub --help` print usage and DO NOT crash under set -u (F4).
# ---------------------------------------------------------------------------
out_sub="$(bash "$SHELLMUX" sub --help 2>&1)"; rc_sub=$?
out_pub="$(bash "$SHELLMUX" pub --help 2>&1)"; rc_pub=$?
if ! printf '%s%s' "$out_sub" "$out_pub" | grep -qE 'unbound variable'; then
  ok "V5 sub/pub --help do not crash with 'unbound variable' (rc_sub=$rc_sub rc_pub=$rc_pub)"
else
  bad "V5 sub/pub --help still crash under set -u"; printf '%s\n' "$out_sub" "$out_pub" | grep unbound | head -2
fi

# ---------------------------------------------------------------------------
# V6 — arg-rc contract a scripter can branch on (round-002 N4). Explicit help is
# success (rc 0, usage on STDOUT); a MISSING-required-arg invocation is an error
# (rc 2, usage on STDERR); a bad subcommand is rc 1. Before R2, bare `pub` exited
# 0 (printing usage), indistinguishable on `$?` from a happy `--help`.
# ---------------------------------------------------------------------------
bash "$SHELLMUX" sub --help >/dev/null 2>&1; rc_help=$?       # explicit help -> 0
bash "$SHELLMUX" sub        >/dev/null 2>&1; rc_noarg=$?      # missing args   -> 2
help_on_stdout="$(bash "$SHELLMUX" pub --help 2>/dev/null)"  # help text on stdout
err_on_stderr="$(bash "$SHELLMUX" pub 2>&1 >/dev/null)"      # error text on stderr
if [ "$rc_help" -eq 0 ] && [ "$rc_noarg" -eq 2 ] \
   && [ -n "$help_on_stdout" ] && [ -n "$err_on_stderr" ]; then
  ok "V6 arg-rc contract: --help rc0/stdout, missing-arg rc2/stderr (scriptable \$?)"
else
  bad "V6 arg-rc contract wrong (rc_help=$rc_help rc_noarg=$rc_noarg help_stdout='${help_on_stdout:0:20}' err_stderr='${err_on_stderr:0:20}')"
fi

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL (must FAIL the fix): SHELLMUX_NO_VALIDATE=1 brings the bugs
# back. If validation disabled does NOT reproduce a crash + traversal, the gate
# is decorative and the V1/V4 passes prove nothing.
# ---------------------------------------------------------------------------
echo "  -- negative control: SHELLMUX_NO_VALIDATE=1 must REGRESS --"
D="$(mktemp -d)"; SOCK="$D/s.sock"
SHELLMUX_NO_VALIDATE=1 bash "$SHELLMUX" serve "$D" --unix "$SOCK" >"$D/b.log" 2>&1 &
BROKER=$!; export SHELLMUX_NO_VALIDATE=1; sleep 1
# bad --at should now crash the handler again
printf 'p\n' | bash "$SHELLMUX" pub "$D" t1 --at xyz --unix "$SOCK" >/dev/null 2>&1
# hostile topic should now escape again
TARGET="/tmp/SHELLMUX_PWNED_NC_$$"; rm -rf "$TARGET"
printf 'x\n' | bash "$SHELLMUX" pub "$D" "../../../../../../tmp/SHELLMUX_PWNED_NC_$$" --unix "$SOCK" >/dev/null 2>&1
sleep 0.5
nc_crash=0; grep -qE 'unbound variable|invalid arithmetic|syntax error' "$D/b.log" 2>/dev/null && nc_crash=1
nc_escape=0; [ -d "$TARGET" ] && { nc_escape=1; rm -rf "$TARGET"; }
unset SHELLMUX_NO_VALIDATE
if [ "$nc_crash" = 1 ] || [ "$nc_escape" = 1 ]; then
  ok "NC control regressed as required (handler_crash=$nc_crash traversal_escape=$nc_escape)"
else
  bad "NC control did NOT regress — validation gate is decorative, V1/V4 prove nothing!"
fi
stop_broker "$BROKER"; rm -rf "$D"

echo "== input_validation result: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
