#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT

WHEEL="$(find "$ROOT/dist" -maxdepth 1 -name 'iphone_mirror_mcp-*.whl' -print | sort | tail -n 1)"
if [[ -z "$WHEEL" ]]; then
  echo "Build a wheel with 'uv build' before running this smoke test." >&2
  exit 1
fi

uv venv "$SMOKE_DIR/venv" >/dev/null
uv pip install --python "$SMOKE_DIR/venv/bin/python" "$WHEEL" >/dev/null
cd "$SMOKE_DIR"
MIRROR_NATIVE_CACHE_DIR="$SMOKE_DIR/cache" \
  "$SMOKE_DIR/venv/bin/python" "$ROOT/scripts/smoke-installed.py"
