#!/usr/bin/env bash
# protocol-history.sh — Analyze Convex protocol evolution over time
# Fetches commit history for protocol-related files and generates a timeline.
#
# Usage: ./scripts/protocol-history.sh [--since 2023-01-01]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT="$ROOT_DIR/docs/protocol-evolution.md"

SINCE="${2:-2023-01-01}"

echo "📜 Convex Protocol Evolution Analysis"
echo "======================================"
echo "Since: $SINCE"
echo ""

{
echo "# Convex Sync Protocol Evolution"
echo ""
echo "> Auto-generated: $(date -u +"%Y-%m-%d %H:%M UTC")"
echo "> Analyzing changes since $SINCE"
echo ""

# --- JS SDK protocol changes ---
echo "## convex-js — Protocol Changes"
echo ""
echo "Source: \`src/browser/sync/protocol.ts\`"
echo ""
echo "| Date | Commit | Description | Impact |"
echo "|------|--------|-------------|--------|"

curl -s "https://api.github.com/repos/get-convex/convex-js/commits?path=src/browser/sync/protocol.ts&per_page=50&since=${SINCE}T00:00:00Z" | \
  jq -r '.[] | [.commit.committer.date, .sha[0:7], (.commit.message | split("\n")[0])] | @tsv' | \
  while IFS=$'\t' read -r date sha msg; do
    short_date=$(echo "$date" | cut -c1-10)
    # Classify impact
    impact="🟢"
    if echo "$msg" | grep -qiE "break|remov|delet|split|chunk"; then
      impact="🔴"
    elif echo "$msg" | grep -qiE "add|support|feat|new"; then
      impact="🟡"
    fi
    echo "| $short_date | \`$sha\` | $msg | $impact |"
  done

echo ""

# --- JS SDK client changes ---
echo "## convex-js — Client State Machine Changes"
echo ""
echo "Source: \`src/browser/sync/client.ts\`"
echo ""
echo "| Date | Commit | Description | Impact |"
echo "|------|--------|-------------|--------|"

curl -s "https://api.github.com/repos/get-convex/convex-js/commits?path=src/browser/sync/client.ts&per_page=50&since=${SINCE}T00:00:00Z" | \
  jq -r '.[] | [.commit.committer.date, .sha[0:7], (.commit.message | split("\n")[0])] | @tsv' | \
  while IFS=$'\t' read -r date sha msg; do
    short_date=$(echo "$date" | cut -c1-10)
    impact="🟢"
    if echo "$msg" | grep -qiE "break|remov|delet|split|chunk"; then
      impact="🔴"
    elif echo "$msg" | grep -qiE "add|support|feat|new|auth"; then
      impact="🟡"
    fi
    echo "| $short_date | \`$sha\` | $msg | $impact |"
  done

echo ""

# --- Rust SDK releases ---
echo "## convex-rs — Release Timeline"
echo ""
echo "| Version | Date | Notable Changes |"
echo "|---------|------|-----------------|"

curl -s "https://api.github.com/repos/get-convex/convex-rs/tags?per_page=20" | \
  jq -r '.[].name' | while read -r tag; do
    version=$(echo "$tag" | sed 's|convex-rs/||')
    sha=$(curl -s "https://api.github.com/repos/get-convex/convex-rs/git/refs/tags/$tag" | jq -r '.object.sha // empty')
    if [ -n "$sha" ]; then
      date=$(curl -s "https://api.github.com/repos/get-convex/convex-rs/commits/$sha" | jq -r '.commit.committer.date // empty' | cut -c1-10)
      echo "| $version | $date | — |"
    fi
  done

echo ""

# --- Frequency analysis ---
echo "## Protocol Change Frequency"
echo ""

JS_PROTOCOL_COUNT=$(curl -s "https://api.github.com/repos/get-convex/convex-js/commits?path=src/browser/sync/protocol.ts&per_page=50&since=${SINCE}T00:00:00Z" | jq 'length')
JS_CLIENT_COUNT=$(curl -s "https://api.github.com/repos/get-convex/convex-js/commits?path=src/browser/sync/client.ts&per_page=50&since=${SINCE}T00:00:00Z" | jq 'length')
RS_TAG_COUNT=$(curl -s "https://api.github.com/repos/get-convex/convex-rs/tags?per_page=20" | jq 'length')

YEARS=$(( ($(date +%s) - $(date -d "$SINCE" +%s)) / 31536000 + 1 ))

echo "- **protocol.ts commits since $SINCE:** $JS_PROTOCOL_COUNT (~$(( JS_PROTOCOL_COUNT / YEARS ))/year)"
echo "- **client.ts commits since $SINCE:** $JS_CLIENT_COUNT (~$(( JS_CLIENT_COUNT / YEARS ))/year)"
echo "- **Rust SDK releases (all time):** $RS_TAG_COUNT"
echo ""

# --- Risk assessment ---
echo "## Risk Assessment for Our SDK"
echo ""
echo "### Low Risk (1-2 changes/year)"
echo "- Message type enum (Transition, MutationResponse, etc.) — very stable"
echo "- Basic request/response shape — unchanged since v0.1"
echo "- Auth flow (Authenticate message) — stable"
echo ""
echo "### Medium Risk (2-4 changes/year)"
echo "- New optional fields on existing messages (clientTs, serverTs)"
echo "- New message types (TransitionChunk added Oct 2025)"
echo "- Auth improvements (token refresh, leeway)"
echo ""
echo "### High Risk (potential future)"
echo "- Major protocol version bump (hasn't happened yet)"
echo "- Binary protocol replacing JSON (no signs of this)"
echo "- New auth mechanisms (OAuth2 PKCE, etc.)"
echo ""
echo "### Recommendation"
echo "- Run \`protocol-watch.sh\` weekly in CI"
echo "- Subscribe to convex-js releases on GitHub"
echo "- Monitor \`#announcements\` on Convex Discord"
echo "- Budget ~2-4 hours/quarter for protocol updates"

} > "$REPORT"

echo ""
echo "📄 Report saved: $REPORT"
echo "Done!"
