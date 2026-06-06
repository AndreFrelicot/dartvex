#!/usr/bin/env bash
# release_live_gate.sh — run the live Convex checks required before publishing.
#
# This is intentionally separate from CI: it requires a real Convex deployment
# with the demo backend deployed and auth configured.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

required_env=(
  CONVEX_DEPLOYMENT_URL
  CONVEX_TEST_QUERY
  CONVEX_TEST_MUTATION
  CONVEX_TEST_AUTH_TOKEN
)

missing=()
for name in "${required_env[@]}"; do
  if [ -z "${!name:-}" ]; then
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing live Convex release-gate environment variables:" >&2
  for name in "${missing[@]}"; do
    echo "  - $name" >&2
  done
  echo "" >&2
  echo "Example:" >&2
  echo "  export CONVEX_DEPLOYMENT_URL=https://your-deployment.convex.cloud" >&2
  echo "  export CONVEX_TEST_QUERY=messages:listPublic" >&2
  echo "  export CONVEX_TEST_MUTATION=messages:sendPublic" >&2
  echo "  export CONVEX_TEST_AUTH_TOKEN=\"\$(cd example/convex-backend && npm run -s token)\"" >&2
  exit 2
fi

run_in() {
  local dir="$1"
  shift
  echo ""
  echo "==> $dir: $*"
  (cd "$ROOT_DIR/$dir" && "$@")
}

run_in packages/dartvex dart test -t integration --concurrency=1
run_in packages/dartvex_local dart test test/integration/replay_integration_test.dart --concurrency=1

echo ""
echo "Live Convex release gate passed."
