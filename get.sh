#!/usr/bin/env bash
# get.sh — one-line installer for shellmux.
#
# Quick install (trusts this script — read it first if you'd rather not):
#   curl -fsSL https://raw.githubusercontent.com/bobbyrathoree/shellmux/master/get.sh | bash
#
# Inspect-first (recommended):
#   curl -fsSL https://raw.githubusercontent.com/bobbyrathoree/shellmux/master/get.sh -o get-shellmux.sh
#   less get-shellmux.sh        # read what it does
#   bash get-shellmux.sh
#
# What it does: checks the dependency set, downloads a pinned shellmux release
# tarball, and installs `shellmux` to ~/.local (bin/ wrapper + libexec/). It does
# NOT run as root, does NOT touch system dirs, and is fully removed by:
#   shellmux ... ; rm -rf ~/.local/libexec/shellmux ~/.local/bin/shellmux
#
# Env knobs:
#   SHELLMUX_VERSION   release tag to install (default: the pinned one below)
#   PREFIX             install prefix (default: ~/.local)
set -euo pipefail

REPO="bobbyrathoree/shellmux"
# Pinned by default so a piped one-liner can't silently change under you. Override
# with SHELLMUX_VERSION=latest to track the newest release, or a specific tag.
DEFAULT_VERSION="v0.1.1"
VERSION="${SHELLMUX_VERSION:-$DEFAULT_VERSION}"
PREFIX="${PREFIX:-$HOME/.local}"

C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_RST=$'\033[0m'
[ -t 1 ] || { C_GRN=; C_RED=; C_YEL=; C_RST=; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '%sshellmux install failed:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

say "shellmux installer (version: $VERSION, prefix: $PREFIX)"

# --- platform + dependency gate --------------------------------------------
[ "$(uname -s)" = "Linux" ] || warn "uname is $(uname -s), not Linux — FIFO/flock/fractional-read semantics are only guaranteed on Linux; on macOS use the Docker dev container instead (see README)."

missing=()
for dep in bash socat flock timeout mkfifo tar; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
# a fetcher
if command -v curl >/dev/null 2>&1; then FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then FETCH="wget -qO-"
else missing+=("curl-or-wget"); fi

if [ "${#missing[@]}" -gt 0 ]; then
  say ""
  die "missing dependencies: ${missing[*]}
    Debian/Ubuntu : sudo apt-get install -y bash socat util-linux coreutils curl
    Fedora/RHEL   : sudo dnf install -y     bash socat util-linux coreutils curl
    Alpine        : sudo apk add            bash socat util-linux coreutils curl"
fi
ok "dependencies present (bash, socat, flock, timeout, mkfifo)"

bv="${BASH_VERSINFO[0]:-0}"
[ "$bv" -ge 4 ] && ok "bash $BASH_VERSION (>= 4: sub-second timers)" \
                || warn "bash $BASH_VERSION (< 4: timers fall back to ~1s — still correct, just coarser)"

# --- download + extract the pinned release ----------------------------------
TARURL="https://github.com/$REPO/archive/refs/tags/$VERSION.tar.gz"
[ "$VERSION" = "latest" ] && TARURL="https://github.com/$REPO/archive/refs/heads/master.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "  downloading $TARURL"
$FETCH "$TARURL" > "$TMP/src.tar.gz" || die "download failed from $TARURL"
tar xzf "$TMP/src.tar.gz" -C "$TMP" || die "extract failed (corrupt tarball?)"
SRCDIR="$(find "$TMP" -maxdepth 1 -type d -name 'shellmux-*' | head -1)"
[ -n "$SRCDIR" ] && [ -f "$SRCDIR/src/shellmux" ] && [ -f "$SRCDIR/src/sched.sh" ] \
  || die "downloaded tarball does not contain src/shellmux + src/sched.sh"
ok "fetched shellmux $VERSION"

# --- install (libexec keeps shellmux + sched.sh siblings; bin/ is a wrapper) -
LIBEXEC="$PREFIX/libexec/shellmux"
BIN="$PREFIX/bin"
mkdir -p "$LIBEXEC" "$BIN"
install -m 0755 "$SRCDIR/src/shellmux" "$LIBEXEC/shellmux"
install -m 0755 "$SRCDIR/src/sched.sh" "$LIBEXEC/sched.sh"
cat > "$BIN/shellmux" <<EOF
#!/usr/bin/env bash
exec "$LIBEXEC/shellmux" "\$@"
EOF
chmod 0755 "$BIN/shellmux"
ok "installed -> $BIN/shellmux (broker+scheduler in $LIBEXEC/)"

# --- smoke + PATH guidance --------------------------------------------------
if "$BIN/shellmux" --version >/dev/null 2>&1; then
  ok "smoke: $("$BIN/shellmux" --version) runs"
else
  die "installed wrapper did not run"
fi

say ""
case ":$PATH:" in
  *":$BIN:"*) say "${C_GRN}Done.${C_RST} Run:  shellmux --help" ;;
  *) say "${C_GRN}Done.${C_RST} Add $BIN to your PATH:"
     say "    echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
     say "  then:  shellmux --help" ;;
esac
