#!/usr/bin/env bash
# install.sh — put `shellmux` on your PATH (and check you can actually run it).
#
#   ./install.sh                 # install to ~/.local  (bin/ + libexec/)
#   ./install.sh --prefix /usr/local   # system-wide (may need sudo)
#   ./install.sh --uninstall     # remove what a prior install put down
#   ./install.sh --check         # only verify dependencies, install nothing
#
# Layout: shellmux + sched.sh are siblings (the broker resolves the scheduler as
# its own dirname/sched.sh), so both go into <prefix>/libexec/shellmux/ and a tiny
# wrapper at <prefix>/bin/shellmux execs the real script. This keeps the two files
# together no matter where bin/ is symlinked from.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
ACTION=install

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --uninstall) ACTION=uninstall; shift ;;
    --check) ACTION=check; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_RST=$'\033[0m'
[ -t 1 ] || { C_GRN=; C_RED=; C_YEL=; C_RST=; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*"; }

LIBEXEC="$PREFIX/libexec/shellmux"
BIN="$PREFIX/bin"
WRAPPER="$BIN/shellmux"

# ---------------------------------------------------------------------------
# dependency check — the REAL dep set (not "coreutils + socat"). Fatal deps stop
# the install; the bash-version note is a capability warning, not a hard stop.
# ---------------------------------------------------------------------------
check_deps() {
  local missing=0
  say "Checking dependencies (Linux + real dep set):"
  # bash >= 4 for fractional `read -t` (sub-second timers). bash 3 still runs but
  # at ~1s resolution — faithful to the reference's whole-second floor, just coarser.
  local bv="${BASH_VERSINFO[0]:-0}"
  if [ "$bv" -ge 4 ]; then ok "bash $BASH_VERSION (>= 4: sub-second timers)"
  else warn "bash $BASH_VERSION (< 4: timers fall back to ~1s resolution — still correct, just coarser)"; fi

  for dep in socat flock timeout mkfifo; do
    if command -v "$dep" >/dev/null 2>&1; then ok "$dep: $(command -v "$dep")"
    else err "$dep: NOT FOUND"; missing=1; fi
  done

  if [ "$(uname -s)" != "Linux" ]; then
    warn "uname is $(uname -s), not Linux — FIFO/flock/fractional-read semantics are only"
    warn "  guaranteed on Linux. On macOS use the Docker dev container (see README)."
  fi

  if [ "$missing" -ne 0 ]; then
    err "Missing required dependency. Install it and re-run:"
    say "    Debian/Ubuntu : sudo apt-get install -y socat util-linux coreutils"
    say "    Fedora/RHEL   : sudo dnf install -y socat util-linux coreutils"
    say "    Alpine        : sudo apk add bash socat util-linux coreutils"
    return 1
  fi
  return 0
}

do_install() {
  check_deps || exit 1
  say ""
  say "Installing to prefix: $PREFIX"
  [ -f "$HERE/src/shellmux" ] && [ -f "$HERE/src/sched.sh" ] || {
    err "src/shellmux and src/sched.sh not found next to install.sh"; exit 1; }

  mkdir -p "$LIBEXEC" "$BIN"
  install -m 0755 "$HERE/src/shellmux" "$LIBEXEC/shellmux"
  install -m 0755 "$HERE/src/sched.sh" "$LIBEXEC/sched.sh"
  ok "broker + scheduler -> $LIBEXEC/"

  # wrapper: exec the real broker so $0/dirname resolves sched.sh as its sibling.
  cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
exec "$LIBEXEC/shellmux" "\$@"
EOF
  chmod 0755 "$WRAPPER"
  ok "wrapper -> $WRAPPER"

  # smoke: prove the freshly-installed binary actually runs.
  if "$WRAPPER" --version >/dev/null 2>&1; then
    ok "smoke: $("$WRAPPER" --version) runs from $WRAPPER"
  else
    err "smoke FAILED: installed wrapper did not run"; exit 1
  fi

  say ""
  case ":$PATH:" in
    *":$BIN:"*) ok "$BIN is already on your PATH — run: shellmux --help" ;;
    *) warn "$BIN is NOT on your PATH. Add it:"
       say "    echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
       say "  then run:  shellmux --help" ;;
  esac
  say "${C_GRN}Done.${C_RST}"
}

do_uninstall() {
  local removed=0
  [ -e "$WRAPPER" ] && { rm -f "$WRAPPER"; ok "removed $WRAPPER"; removed=1; }
  [ -d "$LIBEXEC" ] && { rm -rf "$LIBEXEC"; ok "removed $LIBEXEC"; removed=1; }
  [ "$removed" -eq 0 ] && warn "nothing found under $PREFIX (was it installed with a different --prefix?)"
  say "${C_GRN}Uninstalled.${C_RST}"
}

case "$ACTION" in
  check)     check_deps && say "${C_GRN}All dependencies present.${C_RST}" ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac
