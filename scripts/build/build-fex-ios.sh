#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
SRC="$ROOT/FEX"
BUILD="$SRC/build-ios"
OUT="$BUILD/FEXCore/Source/libFEXCore.a"

if [[ -f "$OUT" && -f "$BUILD/FEXCore/Source/libJemallocLibs.a" ]]; then
  echo "FEX iOS: cached"
  exit 0
fi

# Options mirror build/fex-ios/build.sh. Do not define FEX_IOS_HOST here: in
# this FEX fork it selects the code for FEX running as a Windows PE under Wine
# on iOS (xtajit.dll, xtajit64.dll), which calls Win32 APIs and symbols that
# only those modules define. The native library the app links uses __APPLE__.

# The pinned FEX logs a Win32 VirtualQuery region dump from iOS-host code
# (IosLogUnimplementedCASPAL), which does not compile against the iOS SDK.
# Keep the log line, drop the region dump.
python3 - "$SRC/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
if "MEMORY_BASIC_INFORMATION mbi" in s:
    s, n = re.subn(r"  MEMORY_BASIC_INFORMATION mbi \{\};.*?mbi\.State\);\n",
                   '  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={}",\n'
                   '                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15);\n',
                   s, count=1, flags=re.S)
    if n != 1:
        raise SystemExit(f"expected VirtualQuery block not found in {p}")
    p.write_text(s)
PY

# AllocatorHooks.cpp (JemallocLibs) uses IOS_RPM_GUARD() in its
# ENABLE_FEX_ALLOCATOR=OFF branch, but only defines it when the allocator is
# on. With the allocator off the guard is a no-op, so drop that use.
python3 - "$SRC/FEXCore/Source/Utils/AllocatorHooks.cpp" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = "size_t malloc_usable_size(void* ptr) {\n  IOS_RPM_GUARD();\n#ifdef __APPLE__\n  return ::malloc_size(ptr);"
if old in s:
    p.write_text(s.replace(old, old.replace("  IOS_RPM_GUARD();\n", ""), 1))
PY

# Core.cpp drains a diagnostic snapshot from FEX's rpmalloc fork, which is not
# linked with ENABLE_FEX_ALLOCATOR=OFF. Give it a weak "nothing to report" stub.
python3 - "$SRC/FEXCore/Source/Interface/Core/Core.cpp" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = "int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out);\n}\n"
stub = "__attribute__((weak)) int rpm_cas_snapshot_take(struct rpm_cas_snapshot*) { return 0; }\n"
if stub not in s:
    if old not in s:
        raise SystemExit(f"expected rpm_cas_snapshot_take declaration not found in {p}")
    p.write_text(s.replace(old, old[:-2] + stub + "}\n", 1))
PY

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DBUILD_STEAM_SUPPORT=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_ASSERTIONS=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_CCACHE=OFF \
  -DTUNE_CPU=generic \
  -DTUNE_ARCH=generic

# The Xcode project links these archives from FEX/build-ios.
cmake --build "$BUILD" --target FEXCore FEXCore_Base JemallocLibs --parallel "$JOBS"
for lib in "$OUT" "$BUILD/FEXCore/Source/libJemallocLibs.a"; do
  [[ -f "$lib" ]] || { echo "ERROR: FEX build did not produce $lib" >&2; exit 1; }
done
