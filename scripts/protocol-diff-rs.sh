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

# --- 1. Compare sync_types ---
echo "📦 sync_types comparison"
echo "------------------------"

# Rust sync_types structs
RS_STRUCTS=$(grep -rhoP 'pub struct (\w+)' "$RS_DIR/sync_types/src/" 2>/dev/null | sed 's/pub struct //' | sort -u)
RS_ENUMS=$(grep -rhoP 'pub enum (\w+)' "$RS_DIR/sync_types/src/" 2>/dev/null | sed 's/pub enum //' | sort -u)

echo "  Rust sync_types structs: $(echo "$RS_STRUCTS" | wc -w)"
echo "  Rust sync_types enums:   $(echo "$RS_ENUMS" | wc -w)"
echo ""

# Key types we must implement
CRITICAL_TYPES=(
  "Transition"
  "StateVersion"
  "QueryId"
  "QuerySetVersion"
  "ClientMessage"
  "ServerMessage"
)

echo "  Critical type coverage:"
for ct in "${CRITICAL_TYPES[@]}"; do
  if grep -rq "class $ct\|sealed class $ct\|typedef $ct" "$DART_DIR/" 2>/dev/null; then
    echo -e "    ${GREEN}✅ $ct${NC}"
  else
    echo -e "    ${RED}❌ $ct — MISSING${NC}"
    ISSUES=$((ISSUES + 1))
  fi
done

# --- 2. Compare base_client state machine ---
echo ""
echo "🔄 State Machine comparison"
echo "---------------------------"

# Rust base_client: look for state/transition patterns
RS_STATES=$(grep -rhoP 'enum \w*State\w*' "$RS_DIR/src/base_client/" 2>/dev/null | sort -u || true)
echo "  Rust states: $RS_STATES"

# Our Dart states
DART_STATES=$(grep -rhoP 'enum \w*State\w*|sealed class \w*State\w*' "$DART_DIR/sync/" 2>/dev/null | sort -u || true)
echo "  Dart states: $DART_STATES"

# --- 3. Compare WebSocket manager ---
echo ""
echo "🌐 WebSocket Manager comparison"
echo "--------------------------------"

# Rust: check reconnection/backoff patterns
RS_BACKOFF=$(grep -rn 'backoff\|reconnect\|retry' "$RS_DIR/src/sync/web_socket_manager.rs" 2>/dev/null | wc -l)
DART_BACKOFF=$(grep -rn 'backoff\|reconnect\|retry' "$DART_DIR/transport/" 2>/dev/null | wc -l)
echo "  Rust backoff/reconnect references:  $RS_BACKOFF"
echo "  Dart backoff/reconnect references:  $DART_BACKOFF"

# --- 4. Compare value encoding ---
echo ""
echo "📐 Value Encoding comparison"
echo "----------------------------"

# Rust value types
RS_VALUE_VARIANTS=$(grep -oP 'pub fn (\w+)' "$RS_DIR/sync_types/src/types/json.rs" 2>/dev/null | sed 's/pub fn //' | sort -u || true)
echo "  Rust JSON value methods: $(echo "$RS_VALUE_VARIANTS" | wc -w)"

# Dart value handling
DART_VALUE_FILES=$(find "$DART_DIR" -name "*value*" -o -name "*json*" -o -name "*encode*" 2>/dev/null | wc -l)
echo "  Dart value-related files: $DART_VALUE_FILES"

# --- 5. Check for Rust features we might be missing ---
echo ""
echo "🔍 Feature gap analysis"
echo "------------------------"

FEATURES=(
  "Ping:Pong heartbeat"
  "TransitionChunk:chunked transitions"
  "journal:query journals"
  "ConvexError:structured errors"
  "logLines:server log lines"
  "setAuth:auth token management"
  "connectionCount:reconnect counting"
  "maxObservedTimestamp:timestamp tracking"
  "clientId:client identification"
)

for feat in "${FEATURES[@]}"; do
  keyword="${feat%%:*}"
  desc="${feat#*:}"
  RS_HAS=$(grep -rlc "$keyword" "$RS_DIR/src/" 2>/dev/null | awk '{s+=$1}END{print s+0}')
  DART_HAS=$(grep -rlc "$keyword" "$DART_DIR/" 2>/dev/null | awk '{s+=$1}END{print s+0}')

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
grep -A 20 'pub struct Transition' "$RS_DIR/sync_types/src/types/mod.rs" 2>/dev/null | grep 'pub ' | head -10 || echo "  (not found in expected location)"

echo "  Dart:"
awk '/^class Transition extends ServerMessage/,/^}/' "$ROOT_DIR/packages/dartvex/lib/src/protocol/messages.dart" | grep 'final ' | head -10

# --- Summary ---
echo ""
echo "=========================================="
if [ $ISSUES -eq 0 ]; then
  echo -e "${GREEN}✅ No structural issues detected${NC}"
else
  echo -e "${RED}🔴 $ISSUES issues found — review above${NC}"
fi
