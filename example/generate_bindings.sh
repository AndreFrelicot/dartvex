#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if command -v dart >/dev/null 2>&1; then
  DART_BIN="$(command -v dart)"
elif command -v flutter >/dev/null 2>&1; then
  DART_BIN="$(dirname "$(command -v flutter)")/dart"
else
  echo "error: dart or flutter must be available on PATH" >&2
  exit 1
fi

"$DART_BIN" run \
  "$ROOT_DIR/packages/dartvex_codegen/bin/dartvex_codegen.dart" generate \
  --spec-file "$ROOT_DIR/example/convex-backend/function_spec.json" \
  --output "$ROOT_DIR/example/flutter_app/lib/convex_api" \
  --client-import package:dartvex/dartvex.dart
