#!/bin/bash
# ============================================================================
# Quick update: sync source -> incremental build -> distribute binaries -> restart
# For rapid iterative deployment after code changes
# Usage: ./update.sh [--no-restart]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

NO_RESTART=false
if [ "${1:-}" = "--no-restart" ]; then
    NO_RESTART=true
fi

print_header "Quick Update Deployment"

START_TIME=$(date +%s)

# Step 1: Sync + build + distribute
bash "${SCRIPT_DIR}/build.sh"

# Step 2: Restart
if [ "$NO_RESTART" = false ]; then
    echo ""
    bash "${SCRIPT_DIR}/restart.sh" all
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
print_ok "Update complete (elapsed ${ELAPSED}s)"
