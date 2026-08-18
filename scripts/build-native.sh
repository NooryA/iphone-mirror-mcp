#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${MIRROR_NATIVE_SRC:-$ROOT/native/Sources}"
OUT="${MIRROR_NATIVE_OUT:-$ROOT/dist/mirror-ctl}"
HASH_FILE="${MIRROR_NATIVE_HASH_FILE:-$OUT.src-hash}"
mkdir -p "$(dirname "$OUT")"

SOURCES=(
  "$SRC/Window.swift"
  "$SRC/Dependencies.swift"
  "$SRC/ActionLock.swift"
  "$SRC/VisualComparison.swift"
  "$SRC/ScreenPrecondition.swift"
  "$SRC/Input.swift"
  "$SRC/OverlayCursor.swift"
  "$SRC/Capture.swift"
  "$SRC/OCR.swift"
  "$SRC/Menu.swift"
  "$SRC/Diagnostics.swift"
  "$SRC/main.swift"
)
COMPILER_ARGS=(
  -O
  -warnings-as-errors
  -strict-concurrency=complete
  -parse-as-library
  -framework Cocoa
  -framework ApplicationServices
  -framework CoreGraphics
  -framework ScreenCaptureKit
  -framework ImageIO
  -framework UniformTypeIdentifiers
  -framework Vision
)

HASH="$({
  swiftc --version 2>&1
  uname -m
  printf '%s\n' "${COMPILER_ARGS[@]}"
  shasum -a 256 "$0" "${SOURCES[@]}"
} | shasum -a 256 | awk '{print $1}')"
if [[ -x "$OUT" && -f "$HASH_FILE" && "$(cat "$HASH_FILE")" == "$HASH" ]]; then
  exit 0
fi

swiftc "${COMPILER_ARGS[@]}" -o "$OUT" "${SOURCES[@]}"

codesign --force --sign - "$OUT" >/dev/null
echo "$HASH" > "$HASH_FILE"
