#!/usr/bin/env bash
# protocol-watch.sh — Detect Convex sync protocol changes
# Compares our protocol implementation against convex-js canonical source.
# Run in CI or manually: ./scripts/protocol-watch.sh
#
# Exit codes:
#   0 = no drift detected
#   1 = drift detected (new message types, fields, or structural changes)
#   2 = error (network, missing deps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$ROOT_DIR/.protocol-cache"
REPORT_FILE="$ROOT_DIR/.protocol-cache/drift-report.md"

# --- Config ---
CONVEX_JS_REPO="get-convex/convex-js"
CONVEX_RS_REPO="get-convex/convex-rs"
PROTOCOL_FILE="src/browser/sync/protocol.ts"
CLIENT_FILE="src/browser/sync/client.ts"
OUR_MESSAGES="$ROOT_DIR/packages/dartvex/lib/src/protocol/messages.dart"
OUR_STATE_VERSION="$ROOT_DIR/packages/dartvex/lib/src/protocol/state_version.dart"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$CACHE_DIR"

echo "🔍 Convex Protocol Drift Detector"
echo "=================================="
echo ""

# --- 1. Fetch latest convex-js protocol.ts ---
echo "📥 Fetching latest protocol.ts from $CONVEX_JS_REPO..."
LATEST_PROTOCOL=$(curl -sL "https://raw.githubusercontent.com/$CONVEX_JS_REPO/main/$PROTOCOL_FILE" 2>/dev/null) || {
  echo -e "${RED}❌ Failed to fetch protocol.ts${NC}"
  exit 2
}

if [ -z "$LATEST_PROTOCOL" ]; then
  echo -e "${RED}❌ Empty response for protocol.ts${NC}"
  exit 2
fi

# Save for diffing
echo "$LATEST_PROTOCOL" > "$CACHE_DIR/protocol-latest.ts"

# --- 2. Extract message types from JS ---
echo "🔎 Extracting JS message types..."

# Server message types (top-level only, from parseServerMessage + encodeClientMessage)
JS_SERVER_TYPES=$(echo "$LATEST_PROTOCOL" | \
  awk '/function parseServerMessage|function encodeClientMessage/,/^}/' | \
  grep -oP "case ['\"](\w+)['\"]" | sed "s/case ['\"]//;s/['\"]$//" | sort -u)
echo "$JS_SERVER_TYPES" > "$CACHE_DIR/js-message-types.txt"

# Extract all exported types
JS_EXPORTED_TYPES=$(echo "$LATEST_PROTOCOL" | grep -oP "^export type (\w+)" | sed 's/^export type //' | sort -u)
echo "$JS_EXPORTED_TYPES" > "$CACHE_DIR/js-exported-types.txt"

# --- 3. Extract message types from our Dart ---
echo "🔎 Extracting Dart message types..."

# Top-level message types only (from ServerMessage.fromJson + ClientMessage.fromJson)
DART_SERVER_TYPES=$(awk '/factory ServerMessage\.fromJson|factory ClientMessage\.fromJson/,/^  \}/' "$OUR_MESSAGES" | \
  grep -oP "case '(\w+)'" | sed "s/case '//;s/'$//" | sort -u)
echo "$DART_SERVER_TYPES" > "$CACHE_DIR/dart-message-types.txt"

DART_CLASSES=$(grep -oP "^class (\w+)" "$OUR_MESSAGES" | sed 's/^class //' | sort -u)
echo "$DART_CLASSES" > "$CACHE_DIR/dart-classes.txt"

# --- 4. Compare ---
echo ""
echo "📊 Comparison Results"
echo "---------------------"

DRIFT=0

# Check for new JS message types not in Dart
MISSING_IN_DART=$(comm -23 "$CACHE_DIR/js-message-types.txt" "$CACHE_DIR/dart-message-types.txt")
if [ -n "$MISSING_IN_DART" ]; then
  echo -e "${RED}🔴 NEW message types in JS not in our Dart:${NC}"
  echo "$MISSING_IN_DART" | while read -r t; do echo "   - $t"; done
  DRIFT=1
else
  echo -e "${GREEN}✅ All JS message types present in Dart${NC}"
fi

# Check for types in Dart not in JS (removed?)
EXTRA_IN_DART=$(comm -13 "$CACHE_DIR/js-message-types.txt" "$CACHE_DIR/dart-message-types.txt")
if [ -n "$EXTRA_IN_DART" ]; then
  echo -e "${YELLOW}⚠️  Message types in Dart NOT in JS (possibly removed upstream):${NC}"
  echo "$EXTRA_IN_DART" | while read -r t; do echo "   - $t"; done
  DRIFT=1
else
  echo -e "${GREEN}✅ No stale message types in Dart${NC}"
fi

# --- 5. Check field-level drift for key types ---
echo ""
echo "🔬 Field-level analysis..."

# Extract fields from Transition in JS
JS_TRANSITION_FIELDS=$(echo "$LATEST_PROTOCOL" | awk '/^export type Transition = \{/,/\};/' | grep -oP '^\s+(\w+)' | sed 's/^ *//' | sort -u)
# Extract fields from Transition in Dart
DART_TRANSITION_FIELDS=$(
  awk '/^class Transition extends ServerMessage/,/^}/' "$OUR_MESSAGES" |
    sed -nE 's/^[[:space:]]*final[[:space:]]+[^;=]+[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*;/\1/p' |
    sort -u
)

echo "  Transition JS fields:   $(echo $JS_TRANSITION_FIELDS | tr '\n' ' ')"
echo "  Transition Dart fields: $(echo $DART_TRANSITION_FIELDS | tr '\n' ' ')"

# --- 6. Check Rust SDK version ---
echo ""
echo "📦 Checking Rust SDK latest version..."
RS_LATEST=$(curl -s "https://api.github.com/repos/$CONVEX_RS_REPO/tags?per_page=1" | grep -oP '"name": "convex-rs/([^"]+)"' | head -1 | sed 's/"name": "convex-rs\///' | sed 's/"//')
echo "  Latest Rust SDK: $RS_LATEST"

# Check our tracked version
OUR_RS_VERSION="unknown"
if [ -f "$CACHE_DIR/tracked-rs-version.txt" ]; then
  OUR_RS_VERSION=$(cat "$CACHE_DIR/tracked-rs-version.txt")
fi
echo "  Our tracked:     $OUR_RS_VERSION"

if [ "$RS_LATEST" != "$OUR_RS_VERSION" ] && [ "$OUR_RS_VERSION" != "unknown" ]; then
  echo -e "${YELLOW}⚠️  Rust SDK updated: $OUR_RS_VERSION → $RS_LATEST${NC}"
  DRIFT=1
else
  echo -e "${GREEN}✅ Rust SDK version matches${NC}"
fi

# Save current version
echo "$RS_LATEST" > "$CACHE_DIR/tracked-rs-version.txt"

# --- 7. Check JS SDK version ---
echo ""
echo "📦 Checking JS SDK latest version..."
JS_LATEST=$(npm view convex version 2>/dev/null || echo "unknown")
echo "  Latest JS SDK: $JS_LATEST"

if [ -f "$CACHE_DIR/tracked-js-version.txt" ]; then
  OUR_JS_VERSION=$(cat "$CACHE_DIR/tracked-js-version.txt")
  if [ "$JS_LATEST" != "$OUR_JS_VERSION" ]; then
    echo -e "${YELLOW}⚠️  JS SDK updated: $OUR_JS_VERSION → $JS_LATEST${NC}"
  fi
fi
echo "$JS_LATEST" > "$CACHE_DIR/tracked-js-version.txt"

# --- 8. Generate diff if previous protocol cached ---
if [ -f "$CACHE_DIR/protocol-previous.ts" ]; then
  echo ""
  echo "📝 Diff since last check:"
  DIFF=$(diff "$CACHE_DIR/protocol-previous.ts" "$CACHE_DIR/protocol-latest.ts" || true)
  if [ -n "$DIFF" ]; then
    echo "$DIFF" | head -50
    DRIFT=1
  else
    echo -e "${GREEN}  No changes in protocol.ts${NC}"
  fi
fi

# Rotate cache
cp "$CACHE_DIR/protocol-latest.ts" "$CACHE_DIR/protocol-previous.ts"

# --- 9. Generate report ---
echo ""
{
  echo "# Protocol Drift Report"
  echo "Generated: $(date -u +"%Y-%m-%d %H:%M UTC")"
  echo ""
  echo "## Versions"
  echo "- Rust SDK: $RS_LATEST"
  echo "- JS SDK: $JS_LATEST"
  echo ""
  echo "## Message Types"
  echo "- JS types: $(echo "$JS_SERVER_TYPES" | wc -w)"
  echo "- Dart types: $(echo "$DART_SERVER_TYPES" | wc -w)"
  if [ -n "$MISSING_IN_DART" ]; then
    echo ""
    echo "### ❌ Missing in Dart"
    echo "$MISSING_IN_DART" | while read -r t; do echo "- \`$t\`"; done
  fi
  if [ -n "$EXTRA_IN_DART" ]; then
    echo ""
    echo "### ⚠️ Extra in Dart"
    echo "$EXTRA_IN_DART" | while read -r t; do echo "- \`$t\`"; done
  fi
  echo ""
  echo "## Drift: $([ $DRIFT -eq 0 ] && echo '✅ None' || echo '🔴 Detected')"
} > "$REPORT_FILE"

echo "📄 Report saved: $REPORT_FILE"

# --- Exit ---
if [ $DRIFT -eq 0 ]; then
  echo -e "\n${GREEN}✅ No protocol drift detected.${NC}"
  exit 0
else
  echo -e "\n${RED}🔴 Protocol drift detected! Review changes above.${NC}"
  exit 1
fi
