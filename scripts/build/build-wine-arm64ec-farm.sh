#!/usr/bin/env bash
# The rest of Wine's 64-bit (ARM64EC) DLLs.
#
# app/Madeira/arm64ec-windows tracks the DLLs Madeira was brought up with. A
# 64-bit game that asks for any other system DLL fails ("Library FOO.dll not
# found", or a WinRT/COM activation that returns "module not found"), and the
# gap only shows by running that game. The 32-bit set (build/wine-i386/build.sh)
# already ships every module for the same reason; this does the same for 64-bit:
# every DLL the configured tree has a rule for, minus the SKIP list, and never a
# name the tracked set already has (those are Madeira's own builds).
#
# Output: app/Madeira/arm64ec-windows-extra/ (cached in CI), then copied into
# arm64ec-windows without replacing anything, with a list of the added names in
# madeira-extra-dlls.txt (env.MADEIRA_EXTRA_DLLS = 0 leaves them out of a
# prefix at run time, see WineProcessBridge.m).
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
WINE="$ROOT/wine"
TREE="$WINE/build-arm64ec"
FARM="$ROOT/app/Madeira/arm64ec-windows"
OUT="$ROOT/app/Madeira/arm64ec-windows-extra"
LIST="madeira-extra-dlls.txt"
LOG="$TREE/madeira-arm64ec-farm.log"
export PATH="$MINGW:$PATH"

install_extras() {
  local added=0 bytes=0 f b
  for f in "$OUT"/*; do
    b="$(basename "$f")"
    [[ "$b" == "$LIST" ]] && continue
    [[ -e "$FARM/$b" ]] && continue
    cp "$f" "$FARM/$b"; added=$((added + 1)); bytes=$((bytes + $(wc -c < "$f")))
  done
  cp "$OUT/$LIST" "$FARM/$LIST"
  echo "== arm64ec extras: $(grep -c . "$OUT/$LIST") built, $added copied into arm64ec-windows ($((bytes / 1048576)) MB) =="
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=Extra 64-bit Wine DLLs::$(grep -c . "$OUT/$LIST") DLLs, $(du -sm "$OUT" | cut -f1) MB uncompressed"
  fi
}

if [[ -s "$OUT/$LIST" ]]; then
  echo "Wine ARM64EC extra DLLs: cached"
  install_extras
  exit 0
fi

[[ -x "$MINGW/llvm-strip" ]] || { echo "ERROR: llvm-mingw not found at $MINGW" >&2; exit 1; }
if [[ ! -f "$TREE/Makefile" ]]; then
  echo "Configuring Wine (ARM64EC)..."
  mkdir -p "$TREE"
  # The same configuration build-wine.sh gives this tree.
  (cd "$TREE" && ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
fi

EXT_RE='\.(dll|ocx|ax|acm|cpl|tlb)$'
SKIP_REASON=(
  "wintypes.dll=built with a patch by build-wine-pe-extra.sh"
  "winevulkan.dll|vulkan-1.dll=no Vulkan; graphics go through DXMT and madeira_d3d12"
  "opencl.dll|wpcap.dll=wrappers over host unix libraries that are not built for iOS"
  "d3d8.dll|ddraw.dll=wined3d frontends; wined3d has no backend in this port"
  "wow64.dll|wow64win.dll|wow64cpu.dll|xtajit.dll|xtajit64.dll=WoW64 host modules; Madeira ships its own"
  "winegstreamer.dll|ir50_32.dll=64-bit processes get no winegstreamer unix side by default (docs/MEDIA.md); shipping the PE half would change how media fails"
)
SKIP=()
for e in "${SKIP_REASON[@]}"; do IFS='|' read -r -a n <<< "${e%%=*}"; SKIP+=("${n[@]}"); done
is_in() { local x="$1"; shift; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }
TRACKED="$(git -C "$ROOT" ls-files app/Madeira/arm64ec-windows | xargs -n1 basename | tr '[:upper:]' '[:lower:]')"

TARGETS=()
while IFS= read -r t; do
  b="$(basename "$t")"
  is_in "$b" "${SKIP[@]}" && continue
  grep -qx "$b" <<< "$TRACKED" && continue
  TARGETS+=("$t")
done < <(grep -oE '^dlls/[^/]+/arm64ec-windows/[^/ :]+' "$TREE/Makefile" | grep -E "$EXT_RE" | sort -u)
[[ ${#TARGETS[@]} -gt 0 ]] || { echo "ERROR: no arm64ec targets found in $TREE/Makefile" >&2; exit 1; }
echo "== building ${#TARGETS[@]} arm64ec modules =="

# Type libraries that other modules' IDL imports (stdole2.tlb above all) have no
# make dependency from their users: build every .tlb first, tracked or not.
TLBS=()
while IFS= read -r t; do TLBS+=("$t"); done < <(grep -oE '^dlls/[^/]+/arm64ec-windows/[^/ :]+\.tlb' "$TREE/Makefile" | sort -u)

# A module that does not build for ARM64EC is left out and named; the rest ship.
set +e
[[ ${#TLBS[@]} -gt 0 ]] && make -C "$TREE" -k -j"$JOBS" "${TLBS[@]}" > "$LOG.tlb" 2>&1
make -C "$TREE" -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1
set -e
rm -rf "$OUT"; mkdir -p "$OUT"
FAILED=()
for t in "${TARGETS[@]}"; do
  b="$(basename "$t")"
  if [[ ! -s "$TREE/$t" ]]; then FAILED+=("$b"); continue; fi
  cp "$TREE/$t" "$OUT/$b"
  case "$b" in *.tlb) ;; *) "$MINGW/llvm-strip" --strip-debug "$OUT/$b" || true ;; esac
  echo "$b" >> "$OUT/$LIST.tmp"
done
built=$(( ${#TARGETS[@]} - ${#FAILED[@]} ))
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "== ${#FAILED[@]} modules did not build: ${FAILED[*]}"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=ARM64EC modules that did not build (${#FAILED[@]})::${FAILED[*]}"
    msg="$( { ls "$TREE"/dlls/stdole2.tlb/ 2>&1 | head -5; grep -c . "$LOG.tlb" 2>/dev/null; tail -4 "$LOG.tlb" 2>/dev/null; grep -m2 -B6 -E "cannot find" "$LOG" || tail -20 "$LOG"; } | cut -c1-400 | head -30 | sed 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g')"
    echo "::warning title=First build errors::$msg"
  fi
fi
# Fewer than half is a broken tree or toolchain, not a few unsupported modules.
if [[ $built -lt $(( ${#TARGETS[@]} / 2 )) ]]; then
  tail -60 "$LOG"
  echo "ERROR: only $built of ${#TARGETS[@]} modules built" >&2
  exit 1
fi
mv "$OUT/$LIST.tmp" "$OUT/$LIST"
install_extras
