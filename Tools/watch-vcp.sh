#!/bin/bash
# Read one VCP code forever. Defaults to D7 every 2 seconds.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Didact"
BIN="$ROOT/build/btnq-read-vcp"
CODE="${1:-d7}"
INTERVAL="${2:-2}"
SOURCES=(
  "$SRC/AppleSiliconDDC.swift"
  "$SRC/AppleSiliconDDCBridge.swift"
  "$ROOT/Tools/read-vcp.swift"
)

needs_build=0
[ -x "$BIN" ] || needs_build=1
for source in "${SOURCES[@]}"; do [ "$source" -nt "$BIN" ] && needs_build=1; done

if [ "$needs_build" = 1 ]; then
  mkdir -p "$ROOT/build/module-cache"
  swiftc -O -suppress-warnings -framework CoreDisplay \
    -module-cache-path "$ROOT/build/module-cache" \
    "${SOURCES[@]}" -o "$BIN"
fi

while :; do
  "$BIN" "$CODE" || true
  sleep "$INTERVAL"
done
