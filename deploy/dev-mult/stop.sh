#!/bin/bash
# ============================================================================
# Stop validator + solver nodes
# Usage: ./stop.sh [1|2|3|all]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET="${1:-all}"

stop_validator() {
    local idx="$1"
    local host="${SERVERS[$idx]}"
    local vid="${VALIDATOR_IDS[$idx]}"

    echo "  Stopping ${vid} (${host})..."

    local output
    output=$(remote_exec "$host" "
        # Stop Solver first
        SPID=\$(pidof setu-solver 2>/dev/null || true)
        if [ -n \"\$SPID\" ]; then
            kill \$SPID 2>/dev/null || true
            sleep 1
            kill -9 \$SPID 2>/dev/null || true
            echo 'SOLVER_STOPPED'
        fi
        # Then stop Validator
        VPID=\$(pidof setu-validator 2>/dev/null || true)
        if [ -n \"\$VPID\" ]; then
            kill \$VPID 2>/dev/null || true
            sleep 2
            kill -9 \$VPID 2>/dev/null || true
            echo 'STOPPED'
        else
            echo 'NOT_RUNNING'
        fi
    " 2>&1) || {
        print_err "${vid}: SSH connection failed (${host})"
        return 1
    }
    
    if echo "$output" | grep -q 'SOLVER_STOPPED'; then
        print_ok "${vid} solver stopped"
    fi
    if echo "$output" | grep -q 'STOPPED'; then
        print_ok "${vid} validator stopped"
    elif echo "$output" | grep -q 'NOT_RUNNING'; then
        echo "    ${vid} is not running"
    fi
}

# ── Main logic ──────────────────────────────────────────────────────────────────
print_header "Stop Setu Validator + Solver Cluster"

case "$TARGET" in
    1) stop_validator 0 ;;
    2) stop_validator 1 ;;
    3) stop_validator 2 ;;
    all)
        for i in "${!SERVERS[@]}"; do
            stop_validator "$i"
        done
        ;;
    *)
        echo "Usage: $0 [1|2|3|all]"
        exit 1
        ;;
esac

echo ""
print_ok "Done"
