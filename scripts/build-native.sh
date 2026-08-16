#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/Sources"
OUT="$ROOT/dist/mirror-ctl"
HASH_FILE="$ROOT/dist/.src-hash"
mkdir -p "$ROOT/dist"

HASH="$(cat "$SRC"/*.swift | shasum -a 256 | awk '{print $1}')"
if [[ -x "$OUT" && -f "$HASH_FILE" && "$(cat "$HASH_FILE")" == "$HASH" ]]; then
  exit 0
fi

swiftc -O -parse-as-library -o "$OUT" \
  "$SRC/Window.swift" \
  "$SRC/Input.swift" \
  "$SRC/SkyLight.swift" \
  "$SRC/OverlayCursor.swift" \
  "$SRC/Capture.swift" \
  "$SRC/OCR.swift" \
  "$SRC/Menu.swift" \
  "$SRC/main.swift" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -framework Vision

codesign --force --sign - "$OUT" >/dev/null
echo "$HASH" > "$HASH_FILE"
