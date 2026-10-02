#!/usr/bin/env bash
# Rebuild the native D3D12 layer (arm64ec-windows/madeira_d3d12.dll, also
# shipped as d3d12.dll) from madeira-d3d12/src/pe. The tracked binaries
# predate the source in this tree.
#
# build/madeira-d3d12/build-pe.sh links against DXMT's winemetal import
# library, which only exists after a DXMT PE build. Derive one from the
# shipped winemetal.dll instead.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
PE="$ROOT/app/Madeira/arm64ec-windows"
LIBDIR="$ROOT/dxmt/build-arm64ec/src/winemetal"
OUT="$ROOT/build/madeira-d3d12/out-pe"
LOG="$ROOT/build/madeira-d3d12/build-pe.log"

"$ROOT/scripts/build/setup-llvm-mingw.sh"

mkdir -p "$LIBDIR"
if [[ ! -f "$LIBDIR/libwinemetal.a" ]]; then
  {
    echo "LIBRARY winemetal.dll"
    echo "EXPORTS"
    "$MINGW/llvm-readobj" --coff-exports "$PE/winemetal.dll" | awk '$1 == "Name:" && $2 !~ /[#$]/ { print "  " $2 }'
  } > "$LIBDIR/winemetal.def"
  "$MINGW/llvm-dlltool" -m arm64ec -d "$LIBDIR/winemetal.def" -D winemetal.dll -l "$LIBDIR/libwinemetal.a"
fi

rm -f "$OUT/madeira_d3d12.dll" "$OUT/d3d12.dll"
# The script goes on to build guest test programs; only the DLL matters here.
"$ROOT/build/madeira-d3d12/build-pe.sh" >"$LOG" 2>&1 || true
if [[ ! -s "$OUT/madeira_d3d12.dll" || ! -s "$OUT/d3d12.dll" ]]; then
  tail -60 "$LOG"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    msg="$( (grep -B2 -A8 -m4 -E "error:|undefined symbol" "$LOG" || tail -30 "$LOG") | head -40 | sed 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g')"
    echo "::error title=madeira_d3d12.dll build failed::$msg"
  fi
  exit 1
fi
grep -E "built [0-9]+ bytes" "$LOG" | head -1
cp "$OUT/madeira_d3d12.dll" "$PE/madeira_d3d12.dll"
cp "$OUT/d3d12.dll" "$PE/d3d12.dll"
