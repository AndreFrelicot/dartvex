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

FIELD_DRIFT_REPORT=""

extract_js_type_block() {
  local type_name="$1"
  printf '%s\n' "$LATEST_PROTOCOL" |
    awk -v type_name="$type_name" '
      $0 ~ "^(export[[:space:]]+)?type[[:space:]]+" type_name "[[:space:]]*=[[:space:]]*\\{" {
        inside = 1
        next
      }
      inside && /^[[:space:]]*};/ {
        inside = 0
      }
      inside {
        print
      }
    '
}

extract_js_object_fields() {
  local type_name="$1"
  extract_js_type_block "$type_name" |
    sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)\??:[[:space:]]*.*/\1/p' |
    sort -u
}

extract_js_authenticate_fields() {
  {
    extract_js_object_fields "AdminAuthentication"
    printf '%s\n' "$LATEST_PROTOCOL" |
      awk '
        /^export type Authenticate =/ {
          inside = 1
        }
        inside {
          print
        }
        inside && /^[[:space:]]*};/ {
          inside = 0
        }
      ' |
      sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)\??:[[:space:]]*.*/\1/p'
  } | sort -u
}

extract_js_response_fields() {
  local success_type="$1"
  local failed_type="$2"
  {
    extract_js_object_fields "$success_type"
    extract_js_object_fields "$failed_type"
  } | sort -u
}

extract_dart_class_body() {
  local class_name="$1"
  awk -v class_name="$class_name" '
    $0 ~ "^class[[:space:]]+" class_name "[[:space:]]" {
      inside = 1
    }
    inside {
      print
    }
    inside && /^}/ {
      inside = 0
    }
  ' "$OUR_MESSAGES"
}

extract_dart_to_json_fields() {
  local class_name="$1"
  extract_dart_class_body "$class_name" |
    awk '
      /Map<String, dynamic> toJson\(\)/ {
        inside = 1
        next
      }
      inside && /^[[:space:]]*}[[:space:]]*$/ {
        inside = 0
      }
      inside {
        print
      }
    ' |
    sed -nE "s/.*'([A-Za-z_][A-Za-z0-9_]*)':[[:space:]]*.*/\1/p" |
    sort -u
}

field_list_for_display() {
  local file="$1"
  tr '\n' ' ' < "$file" | sed 's/[[:space:]]*$//'
}

compare_message_fields() {
  local message_name="$1"
  local js_fields="$2"
  local dart_fields="$3"
  local js_file="$CACHE_DIR/js-fields-$message_name.txt"
  local dart_file="$CACHE_DIR/dart-fields-$message_name.txt"

  printf '%s\n' "$js_fields" | sed '/^$/d' | sort -u > "$js_file"
  printf '%s\n' "$dart_fields" | sed '/^$/d' | sort -u > "$dart_file"

  echo "  $message_name JS fields:   $(field_list_for_display "$js_file")"
  echo "  $message_name Dart fields: $(field_list_for_display "$dart_file")"

  local missing_fields
  local extra_fields
  missing_fields=$(comm -23 "$js_file" "$dart_file")
  extra_fields=$(comm -13 "$js_file" "$dart_file")

  if [ -n "$missing_fields" ]; then
    echo -e "${RED}  🔴 $message_name fields missing in Dart:${NC}"
    echo "$missing_fields" | while read -r field; do echo "     - $field"; done
    FIELD_DRIFT_REPORT+=$'\n'"### $message_name missing in Dart"$'\n'
    FIELD_DRIFT_REPORT+="$(echo "$missing_fields" | sed 's/^/- `/' | sed 's/$/`/')"$'\n'
    DRIFT=1
  fi

  if [ -n "$extra_fields" ]; then
    echo -e "${YELLOW}  ⚠️  $message_name fields in Dart NOT in JS:${NC}"
    echo "$extra_fields" | while read -r field; do echo "     - $field"; done
    FIELD_DRIFT_REPORT+=$'\n'"### $message_name extra in Dart"$'\n'
    FIELD_DRIFT_REPORT+="$(echo "$extra_fields" | sed 's/^/- `/' | sed 's/$/`/')"$'\n'
    DRIFT=1
  fi

  if [ -z "$missing_fields" ] && [ -z "$extra_fields" ]; then
    echo -e "${GREEN}  ✅ $message_name fields match${NC}"
  fi
}

for MESSAGE_NAME in Connect Add Mutation Action Authenticate Transition TransitionChunk MutationResponse ActionResponse AuthError; do
  case "$MESSAGE_NAME" in
    Connect)
      JS_FIELDS=$(extract_js_object_fields "Connect")
      ;;
    Add)
      JS_FIELDS=$(extract_js_object_fields "AddQuery")
      ;;
    Mutation)
      JS_FIELDS=$(extract_js_object_fields "MutationRequest")
      ;;
    Action)
      JS_FIELDS=$(extract_js_object_fields "ActionRequest")
      ;;
    Authenticate)
      JS_FIELDS=$(extract_js_authenticate_fields)
      ;;
    MutationResponse)
      JS_FIELDS=$(extract_js_response_fields "MutationSuccess" "MutationFailed")
      ;;
    ActionResponse)
      JS_FIELDS=$(extract_js_response_fields "ActionSuccess" "ActionFailed")
      ;;
    *)
      JS_FIELDS=$(extract_js_object_fields "$MESSAGE_NAME")
      ;;
  esac

  DART_FIELDS=$(extract_dart_to_json_fields "$MESSAGE_NAME")
  compare_message_fields "$MESSAGE_NAME" "$JS_FIELDS" "$DART_FIELDS"
done

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
  if [ -n "$FIELD_DRIFT_REPORT" ]; then
    echo ""
    echo "## Field Drift"
    echo "$FIELD_DRIFT_REPORT"
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
