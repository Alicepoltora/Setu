#!/bin/bash
# ============================================================================
# Restart all validator nodes
# Usage: ./restart.sh [1|2|3|all]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET="${1:-all}"

print_header "Restart Setu Validator Cluster"

bash "${SCRIPT_DIR}/stop.sh" "$TARGET"
sleep 2
bash "${SCRIPT_DIR}/start.sh" "$TARGET"
