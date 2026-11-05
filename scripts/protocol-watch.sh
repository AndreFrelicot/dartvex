#!/usr/bin/env bash
# protocol-watch.sh — Detect Convex sync protocol changes
#
# Compares Dartvex against the official Convex JavaScript client (the `convex`
# npm package):
#
#   1. Structure: the message types and fields of the latest released
#      `src/browser/sync/protocol.ts` against our Dart protocol messages.
#   2. Version: the client sources Dartvex mirrors — `src/browser/sync/*.ts`,
#      `src/values/*.ts` and `src/browser/http_client.ts` — diffed between the
#      pinned release (`convexSyncApiVersion` in
#      packages/dartvex/lib/src/config.dart) and the latest release. A new
#      Convex release is reported as drift until the pin is bumped (see
#      RELEASING.md, "Track the official Convex client").
#   3. The Rust SDK's latest tag, against the value cached by the previous run
#      (only meaningful when .protocol-cache persists between runs).
#
# Usage: ./scripts/protocol-watch.sh [--structure-only]
#   --structure-only  report version drift but fail only on structural drift
#                     (used by the CI job, so a new Convex release does not
#                     turn every pull request red)
#
# Exit codes:
#   0 = no drift detected
#   1 = drift detected
#   2 = error (network, missing deps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$ROOT_DIR/.protocol-cache"
REPORT_FILE="$ROOT_DIR/.protocol-cache/drift-report.md"

STRUCTURE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --structure-only) STRUCTURE_ONLY=1 ;;
    -h | --help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

# --- Config ---
CONVEX_NPM_PACKAGE="convex"
CONVEX_RS_REPO="convex/convex-rs"
PROTOCOL_FILE="src/browser/sync/protocol.ts"
OUR_CONFIG="$ROOT_DIR/packages/dartvex/lib/src/config.dart"
OUR_MESSAGES="$ROOT_DIR/packages/dartvex/lib/src/protocol/messages.dart"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$CACHE_DIR"

echo "🔍 Convex Protocol Drift Detector"
echo "=================================="
echo ""

# --- 1. Resolve the pinned and the latest convex release ---
PINNED_VERSION=$(sed -nE "s/^const String convexSyncApiVersion = '([^']+)';/\1/p" "$OUR_CONFIG")
if [ -z "$PINNED_VERSION" ]; then
  echo -e "${RED}❌ Could not read convexSyncApiVersion from $OUR_CONFIG${NC}"
  exit 2
fi

if ! command -v npm >/dev/null 2>&1; then
  echo -e "${RED}❌ npm is required (npm view $CONVEX_NPM_PACKAGE version)${NC}"
  exit 2
fi
JS_LATEST=$(npm view "$CONVEX_NPM_PACKAGE" version 2>/dev/null || true)
if [ -z "$JS_LATEST" ]; then
  echo -e "${RED}❌ Failed to resolve the latest $CONVEX_NPM_PACKAGE version${NC}"
  exit 2
fi
echo "📌 Pinned convex (convexSyncApiVersion): $PINNED_VERSION"
echo "📦 Latest convex on npm:                 $JS_LATEST"
echo ""

# Downloads a convex release from npm and extracts its package/src into the
# cache (reused across runs once complete).
fetch_convex_src() {
  local version="$1"
  local target="$CACHE_DIR/convex-$version"
  if [ -f "$target/.complete" ]; then
    return 0
  fi
  mkdir -p "$target"
  local tarball="$CACHE_DIR/convex-$version.tgz"
  curl -sSfL -o "$tarball" \
    "https://registry.npmjs.org/$CONVEX_NPM_PACKAGE/-/$CONVEX_NPM_PACKAGE-$version.tgz" || return 1
  tar -xzf "$tarball" -C "$target" package/src || return 1
  rm -f "$tarball"
  touch "$target/.complete"
}

echo "📥 Fetching convex@$PINNED_VERSION and convex@$JS_LATEST sources from npm..."
fetch_convex_src "$PINNED_VERSION" || {
  echo -e "${RED}❌ Failed to fetch convex@$PINNED_VERSION${NC}"
  exit 2
}
fetch_convex_src "$JS_LATEST" || {
  echo -e "${RED}❌ Failed to fetch convex@$JS_LATEST${NC}"
  exit 2
}
PINNED_SRC="$CACHE_DIR/convex-$PINNED_VERSION/package"
LATEST_SRC="$CACHE_DIR/convex-$JS_LATEST/package"

LATEST_PROTOCOL=$(cat "$LATEST_SRC/$PROTOCOL_FILE" 2>/dev/null || true)
if [ -z "$LATEST_PROTOCOL" ]; then
  echo -e "${RED}❌ $PROTOCOL_FILE missing from convex@$JS_LATEST${NC}"
  exit 2
fi

# --- 2. Extract message types from JS ---
echo "🔎 Extracting JS message types..."

# Server message types (top-level only, from parseServerMessage + encodeClientMessage)
JS_SERVER_TYPES=$(echo "$LATEST_PROTOCOL" | \
  awk '/function parseServerMessage|function encodeClientMessage/,/^}/' | \
  perl -ne "while (/case [\\\"'](\\w+)[\\\"']/g) { print \"\$1\\n\" }" | sort -u)
echo "$JS_SERVER_TYPES" > "$CACHE_DIR/js-message-types.txt"

# Extract all exported types
JS_EXPORTED_TYPES=$(echo "$LATEST_PROTOCOL" | perl -ne "print \"\$1\\n\" if /^export type (\\w+)/" | sort -u)
echo "$JS_EXPORTED_TYPES" > "$CACHE_DIR/js-exported-types.txt"

# --- 3. Extract message types from our Dart ---
echo "🔎 Extracting Dart message types..."

# Top-level message types only (from ServerMessage.fromJson + ClientMessage.fromJson)
DART_SERVER_TYPES=$(awk '/factory ServerMessage\.fromJson|factory ClientMessage\.fromJson/,/^  \}/' "$OUR_MESSAGES" | \
  perl -ne "while (/case '(\\w+)'/g) { print \"\$1\\n\" }" | sort -u)
echo "$DART_SERVER_TYPES" > "$CACHE_DIR/dart-message-types.txt"

DART_CLASSES=$(perl -ne "print \"\$1\\n\" if /^class (\\w+)/" "$OUR_MESSAGES" | sort -u)
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

# --- 6. Diff the tracked client sources: pinned vs latest release ---
echo ""
echo "📝 Tracked client sources: convex@$PINNED_VERSION → convex@$JS_LATEST"

# The files Dartvex mirrors (tests and test helpers excluded).
list_tracked_files() {
  local root="$1"
  (
    cd "$root" 2>/dev/null || exit 0
    {
      find src/browser/sync src/values -maxdepth 1 -name '*.ts' 2>/dev/null
      if [ -f src/browser/http_client.ts ]; then
        echo src/browser/http_client.ts
      fi
    } | grep -vE '(\.test\.ts|test_helpers?\.ts)$' | sort -u
  )
}

VERSION_DRIFT=0
CHANGED_FILES=""
SOURCE_DIFF_FILE="$CACHE_DIR/source-diff.patch"
: >"$SOURCE_DIFF_FILE"
if [ "$PINNED_VERSION" != "$JS_LATEST" ]; then
  VERSION_DRIFT=1
  echo -e "${YELLOW}⚠️  New Convex release: $PINNED_VERSION → $JS_LATEST (review, then bump convexSyncApiVersion)${NC}"
fi
TRACKED_FILES=$({
  list_tracked_files "$PINNED_SRC"
  list_tracked_files "$LATEST_SRC"
} | sort -u)
for file in $TRACKED_FILES; do
  if ! diff -q "$PINNED_SRC/$file" "$LATEST_SRC/$file" >/dev/null 2>&1; then
    CHANGED_FILES+="$file"$'\n'
    diff -u --label "convex@$PINNED_VERSION/$file" --label "convex@$JS_LATEST/$file" \
      "$PINNED_SRC/$file" "$LATEST_SRC/$file" >>"$SOURCE_DIFF_FILE" 2>/dev/null || true
  fi
done
if [ -n "$CHANGED_FILES" ]; then
  VERSION_DRIFT=1
  echo -e "${YELLOW}⚠️  Changed since convex@$PINNED_VERSION:${NC}"
  printf '%s' "$CHANGED_FILES" | while read -r file; do
    if [ -n "$file" ]; then echo "   - $file"; fi
  done
  echo "  Full diff: $SOURCE_DIFF_FILE"
else
  echo -e "${GREEN}  ✅ No changes in tracked client sources${NC}"
fi
if [ "$VERSION_DRIFT" -eq 1 ] && [ "$STRUCTURE_ONLY" -eq 0 ]; then
  DRIFT=1
fi

# --- 7. Check Rust SDK version ---
echo ""
echo "📦 Checking Rust SDK latest version..."
RS_LATEST=$(curl -sL "https://api.github.com/repos/$CONVEX_RS_REPO/tags?per_page=1" |
  perl -ne 'if (/"name": "convex-rs\/([^"]+)"/) { print "$1\n"; exit }' || true)
RS_LATEST=${RS_LATEST:-unknown}
echo "  Latest Rust SDK: $RS_LATEST"

OUR_RS_VERSION="unknown"
if [ -f "$CACHE_DIR/tracked-rs-version.txt" ]; then
  OUR_RS_VERSION=$(cat "$CACHE_DIR/tracked-rs-version.txt")
fi
echo "  Previous run:    $OUR_RS_VERSION"

if [ "$RS_LATEST" != "$OUR_RS_VERSION" ] && [ "$OUR_RS_VERSION" != "unknown" ] && [ "$RS_LATEST" != "unknown" ]; then
  echo -e "${YELLOW}⚠️  Rust SDK updated: $OUR_RS_VERSION → $RS_LATEST${NC}"
  if [ "$STRUCTURE_ONLY" -eq 0 ]; then
    DRIFT=1
  fi
else
  echo -e "${GREEN}✅ Rust SDK version unchanged${NC}"
fi
if [ "$RS_LATEST" != "unknown" ]; then
  echo "$RS_LATEST" >"$CACHE_DIR/tracked-rs-version.txt"
fi

# --- 9. Generate report ---
echo ""
{
  echo "# Protocol Drift Report"
  echo "Generated: $(date -u +"%Y-%m-%d %H:%M UTC")"
  echo ""
  echo "## Versions"
  echo "- Pinned convex (convexSyncApiVersion): $PINNED_VERSION"
  echo "- Latest convex: $JS_LATEST"
  echo "- Rust SDK: $RS_LATEST"
  echo ""
  if [ -n "$CHANGED_FILES" ]; then
    echo "## Client sources changed since convex@$PINNED_VERSION"
    printf '%s' "$CHANGED_FILES" | while read -r file; do
      if [ -n "$file" ]; then echo "- \`$file\`"; fi
    done
    echo ""
    echo "Review them against the Dart implementation (RELEASING.md, \"Track the"
    echo "official Convex client\"), then bump \`convexSyncApiVersion\`."
    echo ""
  fi
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
