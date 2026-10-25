#!/usr/bin/env bash
# Rebuild DXMT's 64-bit (ARM64EC) d3d11.dll with the patches in scripts/build
# applied, and install it over the tracked app/Madeira/arm64ec-windows/d3d11.dll.
#
# The tracked DLL is built from the pinned dxmt; this build exists for the
# patches Madeira carries on top of the pin. It links against the Wine tree that
# build-wine.sh configures (wine/build-arm64ec): winecrt0, the ntdll and dbghelp
# import libraries and winebuild, which DXMT's winemetal target needs. Only
# d3d11.dll is installed; winemetal.dll and dxgi.dll stay the tracked ones.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
TREE="$ROOT/wine/build-arm64ec"
D="$ROOT/dxmt"
B="$D/build-pe-arm64ec"
OUT="$ROOT/build/dxmt-pe"
FARM="$ROOT/app/Madeira/arm64ec-windows"
LOG="$OUT/build.log"
mkdir -p "$OUT"

if [[ -s "$OUT/d3d11.dll" ]]; then
  echo "DXMT ARM64EC d3d11.dll: cached"
  cp "$OUT/d3d11.dll" "$FARM/d3d11.dll"
  exit 0
fi

fail() {
  tail -60 "$LOG"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    msg="$( (grep -A8 -m4 -E "error:|Error [0-9]|No rule|undefined symbol|ERROR:" "$LOG" || tail -30 "$LOG") | head -40 | sed 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g')"
    echo "::error title=DXMT d3d11.dll build failed ($1)::$msg"
  fi
  exit 1
}

[[ -f "$TREE/Makefile" ]] || { echo "ERROR: $TREE is not configured (run build-wine.sh first)" >&2; exit 1; }
export PATH="$MINGW:$PATH"

echo "Building the Wine pieces DXMT links against..."
make -C "$TREE" -j"$JOBS" tools/winebuild/winebuild \
  libs/winecrt0/arm64ec-windows/libwinecrt0.a \
  dlls/ntdll/arm64ec-windows/libntdll.a \
  dlls/dbghelp/arm64ec-windows/libdbghelp.a >"$LOG" 2>&1 || fail "wine"

X="$OUT/dxmt-cross-arm64ec.txt"
cat > "$X" <<EOF
[binaries]
c = '$MINGW/arm64ec-w64-mingw32-clang'
cpp = '$MINGW/arm64ec-w64-mingw32-clang++'
ar = '$MINGW/arm64ec-w64-mingw32-ar'
strip = '$MINGW/arm64ec-w64-mingw32-strip'
windres = '$MINGW/arm64ec-w64-mingw32-windres'
dlltool = '$MINGW/arm64ec-w64-mingw32-dlltool'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

echo "Building DXMT d3d11.dll (ARM64EC)..."
if [[ ! -f "$B/build.ninja" ]]; then
  (cd "$D" && SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    meson setup --cross-file "$X" --native-file build-osx.txt --buildtype release \
      -Dwine_build_path="$TREE" "$B") >>"$LOG" 2>&1 || fail "configure"
fi
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" ninja -C "$B" -j"$JOBS" src/d3d11/d3d11.dll >>"$LOG" 2>&1 || fail "compile"

"$MINGW/llvm-strip" --strip-debug -o "$OUT/d3d11.dll" "$B/src/d3d11/d3d11.dll"
"$MINGW/llvm-readobj" --coff-exports "$OUT/d3d11.dll" | grep -q "Name: MadeiraSharedTextureLookup" \
  || { echo "ERROR: d3d11.dll lacks MadeiraSharedTextureLookup" >>"$LOG"; rm -f "$OUT/d3d11.dll"; fail "exports"; }
echo "d3d11.dll: $(wc -c < "$OUT/d3d11.dll") bytes (tracked: $(wc -c < "$FARM/d3d11.dll"))"
cp "$OUT/d3d11.dll" "$FARM/d3d11.dll"
