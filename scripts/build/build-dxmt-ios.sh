#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BUILD="$ROOT/build/dxmt-ios"
OUT="$ROOT/app/Madeira/libdxmt_combined.a"

if [[ -f "$OUT" ]]; then
  echo "DXMT iOS: cached"
  exit 0
fi

# Xcode installs the Metal compiler separately on recent releases. It is safe to
# call this repeatedly; xcodebuild returns immediately when already installed.
xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true

if ! "$BUILD/build.sh"; then
  # build.sh only prints OK/FAILED per object and leaves the compiler output in
  # obj/<name>.err. Show it, and in GitHub Actions also raise it as an
  # annotation so it is visible on the run summary and through the API.
  for err in "$BUILD"/obj/*.err; do
    grep -q "error:" "$err" 2>/dev/null || continue
    name="$(basename "$err" .err)"
    echo "----- $name: compiler errors -----"
    grep -B2 -A6 "error:" "$err" | head -80
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      msg="$(grep -B2 -A6 "error:" "$err" | head -30 | sed 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g')"
      echo "::error title=DXMT compile failed ($name)::$msg"
    fi
  done
  exit 1
fi

shopt -s nullglob
objs=("$BUILD"/obj/*.o)
llvm_libs=("$ROOT"/toolchains/llvm-ios-build/lib/*.a)
(( ${#objs[@]} > 0 )) || { echo "ERROR: DXMT produced no object files" >&2; exit 1; }
(( ${#llvm_libs[@]} > 0 )) || { echo "ERROR: LLVM iOS static libraries are missing" >&2; exit 1; }

xcrun -sdk iphoneos libtool -static -o "$BUILD/libdxmt_combined.a" "${objs[@]}" "${llvm_libs[@]}"
cp "$BUILD/libdxmt_combined.a" "$OUT"
