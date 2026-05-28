#!/bin/bash
# ============================================================================
# Start validator + solver nodes
# Usage: ./start.sh [1|2|3|all] [--no-solver]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET="${1:-all}"
NO_SOLVER=false
for arg in "$@"; do
    case "$arg" in
        --no-solver) NO_SOLVER=true ;;
    esac
done

retry_remote_exec() {
    local host="$1"
    shift
    local attempt
    for attempt in 1 2 3 4 5; do
        if remote_exec "$host" "$@"; then
            return 0
        fi
        print_warn "${host}: SSH operation failed, retry ${attempt}/5"
        sleep 3
    done
    return 1
}

start_validator() {
    local idx="$1"
    local host="${SERVERS[$idx]}"
    local vid="${VALIDATOR_IDS[$idx]}"
    local peers
    local callback_addr
    local governance_timeout_secs
    peers=$(get_peer_validators "$idx")
    callback_addr="${VALIDATOR_CALLBACK_ADDR:-${host}:${HTTP_PORT}}"
    governance_timeout_secs="${GOVERNANCE_TIMEOUT_SECS:-300}"

    echo "  Starting ${vid} (${host})..."

    # Check that the binary exists
    if ! retry_remote_exec "$host" "test -f ${REMOTE_BIN}/setu-validator" >/dev/null 2>&1; then
        print_err "${vid}: setu-validator binary not found, please run ./build.sh first"
        return 1
    fi

    # Check whether it is already running
    if remote_exec "$host" "pidof setu-validator" &>/dev/null; then
        print_warn "${vid}: already running; stopping first..."
        retry_remote_exec "$host" "kill \$(pidof setu-validator) 2>/dev/null || true; sleep 2" >/dev/null 2>&1 || true
    fi

    # Start the validator
    local output
    output=$(retry_remote_exec "$host" "
        cd ${REMOTE_BASE}
        nohup env \
            NODE_ID=${vid} \
            VALIDATOR_HTTP_PORT=${HTTP_PORT} \
            VALIDATOR_P2P_PORT=${P2P_PORT} \
            VALIDATOR_LISTEN_ADDR=0.0.0.0 \
            PEER_VALIDATORS='${peers}' \
            GENESIS_FILE=${REMOTE_CONFIG}/genesis-remote.json \
            VALIDATOR_KEY_FILE=${REMOTE_KEYS}/${vid}.key \
            VALIDATOR_DB_PATH=${REMOTE_DATA}/db \
            VALIDATOR_CALLBACK_ADDR=${callback_addr} \
            GOVERNANCE_TIMEOUT_SECS=${governance_timeout_secs} \
            SETU_RAW_TRANSFER_API_TOKEN='${SETU_RAW_TRANSFER_API_TOKEN:-}' \
            RUST_LOG='${RUST_LOG}' \
            ${REMOTE_BIN}/setu-validator \
                < /dev/null \
            >> ${REMOTE_LOGS}/validator.log 2>&1 &
        
        sleep 1
        if pidof setu-validator > /dev/null 2>&1; then
            echo 'STARTED'
        else
            echo 'FAILED'
        fi
    " 2>&1) || {
        print_err "${vid}: SSH connection failed (${host})"
        return 1
    }
    
    if echo "$output" | grep -q 'STARTED'; then
        print_ok "${vid} started (HTTP=${host}:${HTTP_PORT}, P2P=${host}:${P2P_PORT}, callback=${callback_addr})"
    else
        print_err "${vid} failed to start! Check logs: ./logs.sh $((idx+1))"
    fi
}

start_solver() {
    local idx="$1"
    local host="${SERVERS[$idx]}"
    local sid="solver-$((idx + 1))"

    echo "  Starting ${sid} (${host})..."

    # Check that the binary exists
    if ! retry_remote_exec "$host" "test -f ${REMOTE_BIN}/setu-solver" >/dev/null 2>&1; then
        print_warn "${sid}: setu-solver binary not found, skipping"
        return 1
    fi

    # Check whether it is already running
    if remote_exec "$host" "pidof setu-solver" &>/dev/null; then
        print_warn "${sid}: already running; stopping first..."
        retry_remote_exec "$host" "kill \$(pidof setu-solver) 2>/dev/null || true; sleep 2" >/dev/null 2>&1 || true
    fi

    # Start solver — connects to local validator
    local output
    output=$(retry_remote_exec "$host" "
        cd ${REMOTE_BASE}
        nohup env \\
            SOLVER_ID=${sid} \\
            SOLVER_LISTEN_ADDR=0.0.0.0 \\
            SOLVER_PORT=${SOLVER_PORT} \\
            SOLVER_CAPACITY=100 \\
            VALIDATOR_ADDRESS=${host} \\
            VALIDATOR_HTTP_PORT=${HTTP_PORT} \\
            AUTO_REGISTER=true \\
            HEARTBEAT_INTERVAL=30 \\
            RUST_LOG='info,setu_solver=debug' \\
            ${REMOTE_BIN}/setu-solver \\
                < /dev/null \
            >> ${REMOTE_LOGS}/solver.log 2>&1 &

        sleep 2
        if pidof setu-solver > /dev/null 2>&1; then
            echo 'STARTED'
        else
            echo 'FAILED'
        fi
    " 2>&1) || {
        print_err "${sid}: SSH connection failed (${host})"
        return 1
    }

    if echo "$output" | grep -q 'STARTED'; then
        print_ok "${sid} started (${host}:${SOLVER_PORT}, connected to validator ${host}:${HTTP_PORT})"
    else
        print_err "${sid} failed to start! Check logs: ./logs.sh $((idx+1)) solver"
    fi
}

# ── Main logic ──────────────────────────────────────────────────────────────────
print_header "Start Setu Validator + Solver Cluster"

case "$TARGET" in
    1) start_validator 0 ;;
    2) start_validator 1 ;;
    3) start_validator 2 ;;
    all)
        for i in "${!SERVERS[@]}"; do
            start_validator "$i"
            # Stagger node starts so seed peer becomes ready first
            if [ "$i" -lt $((${#SERVERS[@]} - 1)) ]; then
                echo "  Waiting 3 seconds..."
                sleep 3
            fi
        done
        ;;
    *)
        echo "Usage: $0 [1|2|3|all]"
        exit 1
        ;;
esac

# Health check (validator)
echo ""
echo "  Waiting for validators to become ready..."
sleep 5

echo ""
echo "━━━ Validator Status ━━━"
for i in "${!SERVERS[@]}"; do
    host="${SERVERS[$i]}"
    vid="${VALIDATOR_IDS[$i]}"
    if wait_for_health "$host" "$HTTP_PORT" 10; then
        print_ok "${vid} (${host}:${HTTP_PORT}) — healthy"
    else
        print_warn "${vid} (${host}:${HTTP_PORT}) — not responding (may still be starting)"
    fi
done

# Start Solver
if [ "$NO_SOLVER" = false ]; then
    echo ""
    echo "━━━ Start Solver ━━━"
    case "$TARGET" in
        1) start_solver 0 ;;
        2) start_solver 1 ;;
        3) start_solver 2 ;;
        all)
            for i in "${!SERVERS[@]}"; do
                start_solver "$i"
            done
            ;;
    esac

    # Wait for solver registration
    echo ""
    echo "  Waiting for Solver registration with Validator..."
    sleep 5

    echo ""
    echo "━━━ Solver Registration Status ━━━"
    for i in "${!SERVERS[@]}"; do
        host="${SERVERS[$i]}"
        vid="${VALIDATOR_IDS[$i]}"
        health=$(curl -sf --connect-timeout 3 "http://${host}:${HTTP_PORT}/api/v1/health" 2>/dev/null || echo "")
        solver_count=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('solver_count',0))" 2>/dev/null || echo "0")
        if [ "$solver_count" -gt 0 ] 2>/dev/null; then
            print_ok "${vid}: solver_count=${solver_count}"
        else
            print_warn "${vid}: solver_count=0 (solver may still be registering)"
        fi
    done
fi

echo ""
echo "  View logs: ./logs.sh [1|2|3] [validator|solver]"
echo "  Check status: ./status.sh"
