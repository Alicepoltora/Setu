#!/bin/bash
# ============================================================================
# Run benchmark tests against the remote cluster
# Usage: ./bench.sh [--solvers N] [--txns N] [--concurrency N] [--target 1|2|3]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Default parameters
NUM_SOLVERS=3
BENCH_TXNS=1000
CONCURRENCY=200
INIT_ACCOUNTS=100
TARGET_IDX=0  # Default to running benchmark on validator-1

while [[ $# -gt 0 ]]; do
    case $1 in
        --solvers)     NUM_SOLVERS="$2"; shift 2 ;;
        --txns)        BENCH_TXNS="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --accounts)    INIT_ACCOUNTS="$2"; shift 2 ;;
        --target)      TARGET_IDX=$(($2 - 1)); shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

TARGET_HOST="${SERVERS[$TARGET_IDX]}"
TARGET_VID="${VALIDATOR_IDS[$TARGET_IDX]}"

print_header "Remote Benchmark Test"
echo "  Target: ${TARGET_VID} (${TARGET_HOST}:${HTTP_PORT})"
echo "  Solvers: ${NUM_SOLVERS}, Transactions: ${BENCH_TXNS}, Concurrency: ${CONCURRENCY}"
echo ""

# Check benchmark binary
if ! remote_exec "$TARGET_HOST" "test -f ${REMOTE_BIN}/setu-benchmark" 2>/dev/null; then
    print_err "setu-benchmark not found, please run ./build.sh first"
    exit 1
fi

# Start solver(s) connected to the target validator
echo "  Starting ${NUM_SOLVERS} Solver(s)..."
for s in $(seq 1 "$NUM_SOLVERS"); do
    remote_exec "$TARGET_HOST" "
        SOLVER_ID=solver-bench-${s} \
        SOLVER_PORT=$((SOLVER_PORT + s - 1)) \
        SOLVER_LISTEN_ADDR=127.0.0.1 \
        SOLVER_CAPACITY=100 \
        VALIDATOR_ADDRESS=127.0.0.1 \
        VALIDATOR_HTTP_PORT=${HTTP_PORT} \
        AUTO_REGISTER=true \
        RUST_LOG=warn \
        nohup ${REMOTE_BIN}/setu-solver > ${REMOTE_LOGS}/solver-bench-${s}.log 2>&1 &
    "
done
sleep 5
print_ok "${NUM_SOLVERS} Solver(s) started"

# Run benchmark
echo ""
echo "  Running Benchmark..."
remote_exec "$TARGET_HOST" "
    ${REMOTE_BIN}/setu-benchmark \
        --validator-url http://127.0.0.1:${HTTP_PORT} \
        --total ${BENCH_TXNS} \
        --concurrency ${CONCURRENCY} \
        --init-accounts ${INIT_ACCOUNTS} \
        --genesis-file ${REMOTE_CONFIG}/genesis-remote.json \
        --use-test-accounts \
        2>&1
" || true

# Clean up solver
echo ""
echo "  Cleaning up Solver processes..."
remote_exec "$TARGET_HOST" "SPID=\$(pidof setu-solver 2>/dev/null || true); [ -n \"\$SPID\" ] && kill \$SPID 2>/dev/null || true"
print_ok "Benchmark complete"
