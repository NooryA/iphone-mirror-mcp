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
if [[ -x "$OUT" && -f "$HASH_FILE" ]]; then
  read -r CACHED_SOURCE_HASH CACHED_BINARY_HASH < "$HASH_FILE" || true
  CURRENT_BINARY_HASH="$(shasum -a 256 "$OUT" | awk '{print $1}')"
  if [[ "$CACHED_SOURCE_HASH" == "$HASH" && "$CACHED_BINARY_HASH" == "$CURRENT_BINARY_HASH" ]]; then
    exit 0
  fi
fi

TEMP_OUT="$(mktemp "${OUT}.tmp.XXXXXX")"
TEMP_HASH="$(mktemp "${HASH_FILE}.tmp.XXXXXX")"
cleanup() {
  rm -f "$TEMP_OUT" "$TEMP_HASH"
}
trap cleanup EXIT

swiftc "${COMPILER_ARGS[@]}" -o "$TEMP_OUT" "${SOURCES[@]}"

codesign --force --sign - "$TEMP_OUT" >/dev/null
BINARY_HASH="$(shasum -a 256 "$TEMP_OUT" | awk '{print $1}')"
printf '%s %s\n' "$HASH" "$BINARY_HASH" > "$TEMP_HASH"
mv -f "$TEMP_OUT" "$OUT"
mv -f "$TEMP_HASH" "$HASH_FILE"

trap - EXIT
