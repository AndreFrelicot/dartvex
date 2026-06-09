#!/usr/bin/env bash
# Refreshes example/convex-backend/function_spec.json from a live Convex
# deployment, then regenerates the typed Dart bindings.
#
# Unlike generate_bindings.sh (which reads the already-committed spec), this
# pulls a fresh `npx convex function-spec` dump. A raw dump bakes the real
# deployment URL into the JSON, so the dump is piped through the codegen
# `scrub` subcommand to replace the URL with a placeholder before it is ever
# written to the committed file.
#
# Requires: a Convex deployment configured for example/convex-backend, plus
# dart (or flutter) and npx on PATH.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/example/convex-backend"
SPEC_FILE="$BACKEND_DIR/function_spec.json"
CODEGEN_BIN="$ROOT_DIR/packages/dartvex_codegen/bin/dartvex_codegen.dart"

if command -v dart >/dev/null 2>&1; then
  DART_BIN="$(command -v dart)"
elif command -v flutter >/dev/null 2>&1; then
  DART_BIN="$(dirname "$(command -v flutter)")/dart"
else
  echo "error: dart or flutter must be available on PATH" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "error: npx must be available on PATH" >&2
  exit 1
fi

echo "Fetching function-spec from the live deployment and scrubbing the URL..."
# Stage the result in a temp file so a failed dump or scrub never truncates the
# committed spec (a direct '> function_spec.json' would clobber it on failure).
TMP_SPEC="$(mktemp)"
trap 'rm -f "$TMP_SPEC"' EXIT

(cd "$BACKEND_DIR" && npx convex function-spec) \
  | "$DART_BIN" run "$CODEGEN_BIN" scrub >"$TMP_SPEC"

mv "$TMP_SPEC" "$SPEC_FILE"
trap - EXIT

echo "Wrote scrubbed spec to $SPEC_FILE"
echo "Regenerating typed bindings..."
bash "$ROOT_DIR/example/generate_bindings.sh"

echo "Done. Confirm the spec still uses the placeholder URL:"
grep -n '"url"' "$SPEC_FILE" || true
