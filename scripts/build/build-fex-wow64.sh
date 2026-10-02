#!/usr/bin/env bash
# Rebuild FEX's WoW64 module (shipped as aarch64-windows/xtajit.dll) from the
# pinned FEX plus fex-wow64.patch. The tracked binary predates the patch.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$ROOT/FEX"
PATCH="$ROOT/scripts/build/fex-wow64.patch"
LOG="$ROOT/FEX/build-wow64.log"

"$ROOT/scripts/build/setup-llvm-mingw.sh"

if ! git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
  git -C "$SRC" apply "$PATCH"
fi

if ! "$ROOT/build/fex-wow64/build.sh" >"$LOG" 2>&1; then
  tail -60 "$LOG"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    # Job logs are not always readable through the API; annotations are.
    msg="$( (grep -B2 -A8 -m3 -E "error:|Error|FAILED" "$LOG" || tail -30 "$LOG") | head -40 | sed 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g')"
    echo "::error title=FEX WoW64 build failed::$msg"
  fi
  exit 1
fi
tail -3 "$LOG"
