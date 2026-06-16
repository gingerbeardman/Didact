#!/bin/bash
# Build and run the Didact DDC dump CLI from the app's own DDC sources.
# The compiled binary is cached under build/ and only rebuilt when a source
# changes. Usage: ./Tools/dump.sh [path/to/config.json]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Didact"
BIN="$ROOT/build/btnq-dump"
SOURCES=(
  "$SRC/AppleSiliconDDC.swift"
  "$SRC/AppleSiliconDDCBridge.swift"
  "$SRC/DDCProbe.swift"
  "$SRC/MonitorConfig.swift"
  "$ROOT/Tools/dump.swift"
)

needs_build=0
[ -x "$BIN" ] || needs_build=1
for s in "${SOURCES[@]}"; do [ "$s" -nt "$BIN" ] && needs_build=1; done

if [ "$needs_build" = 1 ]; then
  mkdir -p "$ROOT/build"
  swiftc -O -suppress-warnings -framework CoreDisplay "${SOURCES[@]}" -o "$BIN"
fi

cd "$ROOT"
"$BIN" "$@"
