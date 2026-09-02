#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

remove_generated_root() {
  local root="$1"
  case "$root" in
    "$ROOT/zig-out"|"$ROOT/.zig-cache"|"$ROOT/.native/cache") ;;
    *)
      echo "Refusing to remove unexpected path: $root" >&2
      exit 2
      ;;
  esac

  if [[ -e "$root" || -L "$root" ]]; then
    rm -rf "$root"
    printf 'Removed %s\n' "$root"
  fi
}

remove_generated_root "$ROOT/zig-out"
remove_generated_root "$ROOT/.zig-cache"
remove_generated_root "$ROOT/.native/cache"
