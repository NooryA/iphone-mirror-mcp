#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-native.sh"
cd "$ROOT"
exec uv run iphone-mirror-mcp
