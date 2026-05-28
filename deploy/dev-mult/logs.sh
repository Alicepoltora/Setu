#!/bin/bash
# ============================================================================
# View remote logs
# Usage: ./logs.sh [1|2|3|all] [--tail N] [--follow] [--grep PATTERN]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET="${1:-all}"
TAIL_N=100
FOLLOW=false
GREP_PATTERN=""

# First argument is a flag rather than a node number — default TARGET=all
if [[ "$TARGET" == -* ]]; then
    TARGET="all"
    # Don't shift; let the while loop handle all arguments
else
    shift 2>/dev/null || true
fi
while [[ $# -gt 0 ]]; do
    case $1 in
        --tail|-n)   TAIL_N="$2"; shift 2 ;;
        --follow|-f) FOLLOW=true; shift ;;
        --grep|-g)   GREP_PATTERN="$2"; shift 2 ;;
        *) shift ;;
    esac
done

show_logs() {
    local idx="$1"
    local host="${SERVERS[$idx]}"
    local vid="${VALIDATOR_IDS[$idx]}"

    echo "━━━ ${vid} (${host}) ━━━"

    local cmd="tail -n ${TAIL_N} ${REMOTE_LOGS}/validator.log"
    if [ -n "$GREP_PATTERN" ]; then
        cmd="${cmd} | grep --color=always '${GREP_PATTERN}'"
    fi

    if [ "$FOLLOW" = true ]; then
        cmd="tail -f ${REMOTE_LOGS}/validator.log"
        if [ -n "$GREP_PATTERN" ]; then
            cmd="${cmd} | grep --line-buffered --color=always '${GREP_PATTERN}'"
        fi
        echo "  (Ctrl+C to exit)"
        remote_exec "$host" "$cmd" || true
    else
        remote_exec "$host" "$cmd" 2>/dev/null || echo "  (no logs)"
        echo ""
    fi
}

case "$TARGET" in
    1) show_logs 0 ;;
    2) show_logs 1 ;;
    3) show_logs 2 ;;
    all)
        if [ "$FOLLOW" = true ]; then
            echo "follow mode supports a single node only; please specify a node: ./logs.sh 1 -f"
            exit 1
        fi
        for i in "${!SERVERS[@]}"; do
            show_logs "$i"
        done
        ;;
    *)
        echo "Usage: $0 [1|2|3|all] [--tail N] [--follow] [--grep PATTERN]"
        echo ""
        echo "Examples:"
        echo "  $0 1 -f              # Tail validator-1 logs in real time"
        echo "  $0 all -n 50         # Last 50 lines from all nodes"
        echo "  $0 2 --grep ERROR    # Error logs from validator-2"
        echo "  $0 all --grep 'CF.*finalize'  # CF finalize logs from all nodes"
        exit 1
        ;;
esac
