#!/usr/bin/env bash
# protocol-diff-rs.sh — Deep-compare our Dart implementation against Rust SDK source
# Checks structural parity: message types, state machine states, value encoding.
#
# Usage: ./scripts/protocol-diff-rs.sh [path-to-convex-rs]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RS_DIR="${1:-$ROOT_DIR/ref/convex-rs}"
DART_DIR="$ROOT_DIR/packages/dartvex/lib/src"
RS_SRC_DIR="$RS_DIR/src"
RS_SYNC_TYPES_DIR="$RS_DIR/sync_types/src"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔬 Dart ↔ Rust SDK Structural Comparison"
echo "=========================================="
echo "Rust:  $RS_DIR"
echo "Dart:  $DART_DIR"
echo ""

ISSUES=0

count_refs() {
  local pattern="$1"
  local dir="$2"
  if command -v rg >/dev/null 2>&1; then
    { rg -i -l -e "$pattern" "$dir" 2>/dev/null || true; } | wc -l | tr -d ' '
  else
    { grep -REil "$pattern" "$dir" 2>/dev/null || true; } | wc -l | tr -d ' '
  fi
}

require_dir() {
  local dir="$1"
  local label="$2"
  if [ ! -d "$dir" ]; then
    echo -e "${RED}❌ Missing $label: $dir${NC}"
    exit 2
  fi
}

require_dir "$RS_DIR" "Rust SDK checkout"
require_dir "$RS_SRC_DIR" "Rust SDK src directory"
require_dir "$RS_SYNC_TYPES_DIR" "Rust sync_types source directory"
require_dir "$DART_DIR" "Dart SDK source directory"

# --- 1. Compare sync_types ---
echo "📦 sync_types comparison"
echo "------------------------"

# Rust sync_types structs
RS_STRUCTS=$(grep -rhoE 'pub struct [[:alnum:]_]+' "$RS_SYNC_TYPES_DIR/" 2>/dev/null | sed 's/pub struct //' | sort -u)
RS_ENUMS=$(grep -rhoE 'pub enum [[:alnum:]_]+' "$RS_SYNC_TYPES_DIR/" 2>/dev/null | sed 's/pub enum //' | sort -u)

echo "  Rust sync_types structs: $(echo "$RS_STRUCTS" | wc -w)"
echo "  Rust sync_types enums:   $(echo "$RS_ENUMS" | wc -w)"
echo ""

# Key types we must implement
CRITICAL_TYPES=(
  "Transition"
  "StateVersion"
  "ClientMessage"
  "ServerMessage"
)

echo "  Critical type coverage:"
for ct in "${CRITICAL_TYPES[@]}"; do
  if grep -REq "class $ct|sealed class $ct|typedef $ct" "$DART_DIR/" 2>/dev/null; then
    echo -e "    ${GREEN}✅ $ct${NC}"
  else
    echo -e "    ${RED}❌ $ct — MISSING${NC}"
    ISSUES=$((ISSUES + 1))
  fi
done

if grep -Rq "queryId" "$DART_DIR/" 2>/dev/null; then
  echo -e "    ${GREEN}✅ QueryId represented as int fields${NC}"
else
  echo -e "    ${RED}❌ queryId fields — MISSING${NC}"
  ISSUES=$((ISSUES + 1))
fi

if grep -REq "querySetVersion|querySet" "$DART_DIR/" 2>/dev/null; then
  echo -e "    ${GREEN}✅ QuerySetVersion represented as int state${NC}"
else
  echo -e "    ${RED}❌ querySetVersion state — MISSING${NC}"
  ISSUES=$((ISSUES + 1))
fi

# --- 2. Compare base_client state machine ---
echo ""
echo "🔄 State Machine comparison"
echo "---------------------------"

# Rust base_client: look for state/transition patterns
RS_STATES=$(grep -rhoE 'enum [[:alnum:]_]*State[[:alnum:]_]*' "$RS_SRC_DIR/base_client/" 2>/dev/null | sort -u || true)
echo "  Rust states: $RS_STATES"

# Our Dart states
DART_STATES=$(grep -rhoE 'enum [[:alnum:]_]*State[[:alnum:]_]*|sealed class [[:alnum:]_]*State[[:alnum:]_]*' "$DART_DIR/sync/" 2>/dev/null | sort -u || true)
echo "  Dart states: $DART_STATES"

# --- 3. Compare WebSocket manager ---
echo ""
echo "🌐 WebSocket Manager comparison"
echo "--------------------------------"

# Rust: check reconnection/backoff patterns
RS_BACKOFF=$(grep -RniE 'backoff|reconnect|retry' "$RS_SRC_DIR/sync/web_socket_manager.rs" 2>/dev/null | wc -l | tr -d ' ')
DART_BACKOFF=$(grep -RniE 'backoff|reconnect|retry' "$DART_DIR/transport/" 2>/dev/null | wc -l | tr -d ' ')
echo "  Rust backoff/reconnect references:  $RS_BACKOFF"
echo "  Dart backoff/reconnect references:  $DART_BACKOFF"
if [ "$RS_BACKOFF" -eq 0 ]; then
  echo -e "  ${RED}❌ Rust backoff/reconnect references not found${NC}"
  ISSUES=$((ISSUES + 1))
fi
if [ "$DART_BACKOFF" -eq 0 ]; then
  echo -e "  ${RED}❌ Dart backoff/reconnect references not found${NC}"
  ISSUES=$((ISSUES + 1))
fi

# --- 4. Compare value encoding ---
echo ""
echo "📐 Value Encoding comparison"
echo "----------------------------"

# Rust value types
RS_VALUE_VARIANTS=$(grep -hoE 'pub fn [[:alnum:]_]+' "$RS_SYNC_TYPES_DIR/types/json.rs" 2>/dev/null | sed 's/pub fn //' | sort -u || true)
echo "  Rust JSON value methods: $(echo "$RS_VALUE_VARIANTS" | wc -w)"
if [ ! -f "$RS_SYNC_TYPES_DIR/types/json.rs" ]; then
  echo -e "  ${RED}❌ Rust JSON value source missing${NC}"
  ISSUES=$((ISSUES + 1))
fi

# Dart value handling
DART_VALUE_FILES=$(find "$DART_DIR" -name "*value*" -o -name "*json*" -o -name "*encode*" 2>/dev/null | wc -l)
echo "  Dart value-related files: $DART_VALUE_FILES"

# --- 5. Check for Rust features we might be missing ---
echo ""
echo "🔍 Feature gap analysis"
echo "------------------------"

FEATURE_KEYS=(
  "Ping"
  "TransitionChunk"
  "journal"
  "ConvexError"
  "logLines"
  "setAuth"
  "connectionCount"
  "maxObservedTimestamp"
  "clientId"
)
FEATURE_PATTERNS=(
  "Ping|ServerMessage::Ping|Message::Ping"
  "TransitionChunk"
  "journal"
  "ConvexError|ConvexException|errorData|error_data"
  "logLines|log_lines"
  "setAuth|set_auth|Authenticate"
  "connectionCount|connection_count"
  "maxObservedTimestamp|max_observed_timestamp"
  "clientId|client_id"
)
FEATURE_DESCRIPTIONS=(
  "Pong heartbeat"
  "chunked transitions"
  "query journals"
  "structured errors"
  "server log lines"
  "auth token management"
  "reconnect counting"
  "timestamp tracking"
  "client identification"
)

for index in "${!FEATURE_KEYS[@]}"; do
  keyword="${FEATURE_KEYS[$index]}"
  pattern="${FEATURE_PATTERNS[$index]}"
  desc="${FEATURE_DESCRIPTIONS[$index]}"
  RS_HAS=$(count_refs "$pattern" "$RS_DIR")
  DART_HAS=$(count_refs "$pattern" "$DART_DIR")

  if [ "$RS_HAS" -gt 0 ] && [ "$DART_HAS" -gt 0 ]; then
    echo -e "  ${GREEN}✅ $desc ($keyword)${NC} — RS:$RS_HAS refs, Dart:$DART_HAS refs"
  elif [ "$RS_HAS" -gt 0 ] && [ "$DART_HAS" -eq 0 ]; then
    echo -e "  ${RED}❌ $desc ($keyword)${NC} — in Rust but NOT in Dart!"
    ISSUES=$((ISSUES + 1))
  else
    echo -e "  ${YELLOW}⚪ $desc ($keyword)${NC} — RS:$RS_HAS, Dart:$DART_HAS"
  fi
done

# --- 6. Struct field comparison for Transition ---
echo ""
echo "📋 Transition struct fields"
echo "---------------------------"

echo "  Rust:"
RUST_TRANSITION_FIELDS=$(
  awk '
    /^[[:space:]]+Transition \{/ { in_transition = 1; next }
    in_transition && /^[[:space:]]+\},/ { exit }
    in_transition { print }
  ' "$RS_SYNC_TYPES_DIR/types/mod.rs" 2>/dev/null |
    grep -E '^[[:space:]]+[[:alnum:]_]+:' |
    head -10 || true
)
if [ -n "$RUST_TRANSITION_FIELDS" ]; then
  echo "$RUST_TRANSITION_FIELDS"
else
  echo -e "  ${RED}❌ Transition fields not found in Rust sync_types${NC}"
  ISSUES=$((ISSUES + 1))
fi

echo "  Dart:"
DART_TRANSITION_FIELDS=$(
  awk '/^class Transition extends ServerMessage/,/^}/' "$ROOT_DIR/packages/dartvex/lib/src/protocol/messages.dart" |
    grep 'final ' |
    head -10 || true
)
if [ -n "$DART_TRANSITION_FIELDS" ]; then
  echo "$DART_TRANSITION_FIELDS"
else
  echo -e "  ${RED}❌ Transition class fields not found in Dart implementation${NC}"
  ISSUES=$((ISSUES + 1))
fi

# --- Summary ---
echo ""
echo "=========================================="
if [ $ISSUES -eq 0 ]; then
  echo -e "${GREEN}✅ No structural issues detected${NC}"
else
  echo -e "${RED}🔴 $ISSUES issues found — review above${NC}"
  exit 1
fi
