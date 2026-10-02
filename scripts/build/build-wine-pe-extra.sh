#!/usr/bin/env bash
# Stock Wine PE modules a game needs that are not among the tracked binaries in
# app/Madeira/arm64ec-windows (the DLL farm linked into every prefix).
#
# wintypes.dll: combase loads it for RoGetActivationFactory. Without it a
# C++/WinRT caller gets 0x8007007e and throws.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
TREE="$ROOT/wine/build-arm64ec"
FARM="$ROOT/app/Madeira/arm64ec-windows"
LOG="$TREE/madeira-pe-extra.log"
export PATH="$MINGW:$PATH"

[[ -f "$TREE/Makefile" ]] || { echo "ERROR: $TREE is not configured (run build-wine.sh first)" >&2; exit 1; }

for module in wintypes; do
  target="dlls/$module/arm64ec-windows/$module.dll"
  if ! make -C "$TREE" -j"$JOBS" "$target" >"$LOG" 2>&1 || [[ ! -s "$TREE/$target" ]]; then
    tail -60 "$LOG"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      msg="$( (grep -B2 -A8 -m4 -E "error:|Error |No rule" "$LOG" || tail -30 "$LOG") | head -40 | sed 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g')"
      echo "::error title=Wine PE module $module failed::$msg"
    fi
    exit 1
  fi
  cp "$TREE/$target" "$FARM/$module.dll"
  "$MINGW/llvm-strip" --strip-debug "$FARM/$module.dll" || true
  echo "$module.dll: $(wc -c < "$FARM/$module.dll") bytes"
done
