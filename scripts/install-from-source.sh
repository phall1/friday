#!/bin/bash
# One-command install from source: build, package, and install Friday.app.
# Idempotent — safe to re-run; it replaces any previously installed copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "install-from-source: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 ($2)"; }

# --- Host checks (Friday is arm64-only and refuses Rosetta) ------------------
[[ "$(uname -m)" == "arm64" ]] || die "requires Apple Silicon (arm64); found $(uname -m)."
[[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')" == "0" ]] \
  || die "running under Rosetta; re-run from a native arm64 shell."
[[ "$(uname -r)" =~ ^2[3-9] ]] || true # informational only; the app itself gates macOS 14+ at runtime

need node "https://nodejs.org (Node 24 required unless using FRIDAY_PM=bun)"
need npm "ships with Node.js"
need zig "https://ziglang.org (0.16.0 required)"
need codesign "ships with macOS / Xcode CLT"

ZIG_MAJOR_MINOR="$(zig version)"
[[ "$ZIG_MAJOR_MINOR" == 0.16.0 ]] || die "Zig 0.16.0 required, found $ZIG_MAJOR_MINOR."

# --- Package manager: pick your poison ---------------------------------------
# npm is the default (matches package-lock.json). Bun is fully supported for
# install speed; patch-package still applies the same patches to node_modules.
PM="${FRIDAY_PM:-npm}"
case "$PM" in
  bun)
    need bun "https://bun.sh (or use FRIDAY_PM=npm)"
    ;;
  npm)
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
    [[ "$NODE_MAJOR" -ge 24 ]] || die "Node 24+ required, found $(node -v)."
    ;;
  *)
    die "FRIDAY_PM must be npm or bun (got '$PM')."
    ;;
esac

# --- Signing identity (hardened runtime requires a real identity) ------------
IDENTITY="${FRIDAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  die "no Apple Development signing identity found in the login keychain.
Friday's hardened runtime library validation needs a real identity to sign the
embedded NeMo dylibs. Install Xcode Command Line Tools, sign into Xcode (or add
a free 'Apple Development' certificate via Xcode), or export
FRIDAY_SIGN_IDENTITY='<identity hash>'."
fi

# --- Package manager: pick your poison ---------------------------------------
# npm is the default (matches package-lock.json). Bun is fully supported for
# install speed; patch-package still applies the same patches to node_modules.
PM="${FRIDAY_PM:-npm}"
case "$PM" in
  bun)
    need bun "https://bun.sh (or use FRIDAY_PM=npm)"
    echo "==> installing toolchain deps (bun)"
    bun install --ignore-scripts
    bunx --bun patch-package --error-on-fail
    ;;
  npm)
    echo "==> installing toolchain deps (npm)"
    npm ci --ignore-scripts
    npx patch-package --error-on-fail
    ;;
  *)
    die "FRIDAY_PM must be npm or bun (got '$PM')."
    ;;
esac

echo "==> building (arm64, ReleaseFast)"
FRIDAY_SIGN_IDENTITY="$IDENTITY" npm run package

APP="$ROOT/zig-out/package/Friday.app"
codesign --verify --deep --strict "$APP" || die "packaged app failed codesign verification."

# --- Install -----------------------------------------------------------------
INSTALL_DIR="/Applications"
if ! mkdir -p "$INSTALL_DIR" 2>/dev/null || [[ ! -w "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi
TARGET="$INSTALL_DIR/Friday.app"

if pgrep -xq friday; then
  echo "==> quitting a running Friday"
  pkill -x friday || true
  sleep 1
fi

rm -rf "$TARGET"
ditto "$APP" "$TARGET"
codesign --verify --deep --strict "$TARGET"

echo "==> installed $TARGET (version $(node -p "require('./app.json').version"))"
echo "    Launch it from Spotlight, or: open '$TARGET'"
echo "    First launch asks for Microphone, Input Monitoring, and Accessibility."
