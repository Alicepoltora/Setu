#!/bin/bash
#
# Setu TPS Benchmark Test Script
# ===============================
# 
# Features:
#   1. Disable proxy
#   2. Create log directory
#   3. Start Validator and Solver (counts are configurable)
#   4. Run Benchmark test
#   5. Collect logs and results
#
# Usage:
#   ./scripts/tps_test.sh [OPTIONS]
#
# Examples:
#   ./scripts/tps_test.sh                           # Default configuration
#   ./scripts/tps_test.sh -s 3 -t 1000 -c 100       # 3 solvers, 1000 transactions, concurrency 100
#   ./scripts/tps_test.sh --solvers 5 --sustained  # 5 solvers, sustained mode
#

set -e

# ============================================================================
# Default configuration
# ============================================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE_DIR="${PROJECT_ROOT}/logs"

# Service configuration
NUM_VALIDATORS=1          # Number of validators (currently only 1 is supported)
NUM_SOLVERS=1             # Number of solvers
VALIDATOR_PORT=8080       # Validator port
SOLVER_BASE_PORT=9001     # Solver base port

# Benchmark configuration
TOTAL_REQUESTS=500        # Total requests
CONCURRENCY=50            # Concurrency
WARMUP_REQUESTS=50        # Warmup requests
USE_TEST_ACCOUNTS=true    # Use test accounts
INIT_ACCOUNTS=100         # Number of test accounts to initialize (0=skip init, use seed accounts)
INIT_ACCOUNT_BALANCE=100000  # Initial balance per test account
COINS_PER_ACCOUNT=5       # Coin objects per account (multi-coin model; more = higher per-account parallelism, recommended >=5)
BENCHMARK_MODE="burst"    # Mode: burst, sustained, ramp
SUSTAINED_DURATION=30     # sustained mode duration (seconds)
SUSTAINED_TPS=100         # sustained mode target TPS
RAMP_START=10             # ramp mode starting TPS
RAMP_STEP=10              # ramp mode TPS increment per step
RAMP_STEP_DURATION=10     # ramp mode duration per step (seconds)
RAMP_DURATION=60          # ramp mode total time (seconds)
USE_BATCH=false           # Use batch API
BATCH_SIZE=50             # Batch size

# Other configuration
MOCK_TEE=true             # Use Mock TEE
RUST_LOG_LEVEL="warn"     # Log level: error, warn, info, debug, trace
WAIT_STARTUP=5            # Service startup wait time (seconds)
HEALTH_CHECK_RETRIES=10   # Health check retry count

# ============================================================================
# Colored output
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}==>${NC} $1"; }

# ============================================================================
# Help information
# ============================================================================
show_help() {
    cat << EOF
Setu TPS Benchmark Test Script

Usage: $0 [OPTIONS]

Service configuration:
  -s, --solvers NUM       Number of solvers (default: $NUM_SOLVERS)
  -p, --port PORT         Validator port (default: $VALIDATOR_PORT)
  --mock-tee              Use Mock TEE (default: $MOCK_TEE)
  --real-tee              Use real TEE

Benchmark configuration:
  -t, --requests NUM      Total requests (default: $TOTAL_REQUESTS)
  -c, --concurrency NUM   Concurrency (default: $CONCURRENCY)
  -w, --warmup NUM        Warmup requests (default: $WARMUP_REQUESTS)
  --no-test-accounts      Do not use test accounts
  --init-accounts NUM     Test accounts to initialize (default: $INIT_ACCOUNTS, 0=use seed accounts)
  --init-balance NUM      Initial balance per test account (default: $INIT_ACCOUNT_BALANCE)
  --coins-per-account N   Coin objects per account (default: $COINS_PER_ACCOUNT, multi-coin model; more = higher concurrency)

Benchmark modes:
  --burst                 Burst mode (default)
  --sustained             Sustained mode
  --sustained-duration S  Sustained mode duration (default: $SUSTAINED_DURATIONs)
  --sustained-tps TPS     Sustained mode target TPS (default: $SUSTAINED_TPS)
  --ramp                  Ramp mode
  --ramp-start TPS        Ramp mode starting TPS (default: $RAMP_START)
  --ramp-step TPS         Ramp mode TPS increment per step (default: $RAMP_STEP)
  --ramp-step-duration S  Ramp mode duration per step (default: $RAMP_STEP_DURATIONs)
  --ramp-duration S       Ramp mode total duration (default: $RAMP_DURATIONs)
  --batch                 Enable batch API mode
  --batch-size SIZE       Batch size (default: $BATCH_SIZE)

Log configuration:
  -l, --log-level LEVEL   Log level: error,warn,info,debug,trace (default: $RUST_LOG_LEVEL)
  --log-dir DIR           Log directory (default: $LOG_BASE_DIR)

Other:
  -h, --help              Show help
  --dry-run               Show configuration only, do not execute

Examples:
  $0                                    # Default configuration test
  $0 -s 3 -t 1000 -c 100               # 3 solvers, 1000 requests, concurrency 100
  $0 --solvers 5 --sustained           # 5 solvers, sustained mode
  $0 -s 2 -t 5000 -c 200 -l info       # High-load test, info logs
  $0 --init-accounts 100 -c 100        # Initialize 100 accounts, concurrency 100
  $0 --init-accounts 200 -c 200 --batch  # High-concurrency batch test

EOF
    exit 0
}

# ============================================================================
# Parse arguments
# ============================================================================
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--solvers)
            NUM_SOLVERS="$2"
            shift 2
            ;;
        -p|--port)
            VALIDATOR_PORT="$2"
            shift 2
            ;;
        --mock-tee)
            MOCK_TEE=true
            shift
            ;;
        --real-tee)
            MOCK_TEE=false
            shift
            ;;
        -t|--requests)
            TOTAL_REQUESTS="$2"
            shift 2
            ;;
        -c|--concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        -w|--warmup)
            WARMUP_REQUESTS="$2"
            shift 2
            ;;
        --no-test-accounts)
            USE_TEST_ACCOUNTS=false
            shift
            ;;
        --init-accounts)
            INIT_ACCOUNTS="$2"
            shift 2
            ;;
        --init-balance)
            INIT_ACCOUNT_BALANCE="$2"
            shift 2
            ;;
        --coins-per-account)
            COINS_PER_ACCOUNT="$2"
            shift 2
            ;;
        --burst)
            BENCHMARK_MODE="burst"
            shift
            ;;
        --sustained)
            BENCHMARK_MODE="sustained"
            shift
            ;;
        --sustained-duration)
            SUSTAINED_DURATION="$2"
            shift 2
            ;;
        --sustained-tps)
            SUSTAINED_TPS="$2"
            shift 2
            ;;
        --ramp)
            BENCHMARK_MODE="ramp"
            shift
            ;;
        --ramp-start)
            RAMP_START="$2"
            shift 2
            ;;
        --ramp-step)
            RAMP_STEP="$2"
            shift 2
            ;;
        --ramp-step-duration)
            RAMP_STEP_DURATION="$2"
            shift 2
            ;;
        --ramp-duration)
            RAMP_DURATION="$2"
            shift 2
            ;;
        --batch)
            USE_BATCH=true
            shift
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        -l|--log-level)
            RUST_LOG_LEVEL="$2"
            shift 2
            ;;
        --log-dir)
            LOG_BASE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown argument: $1"
            show_help
            ;;
    esac
done

# ============================================================================
# Create log directory
# ============================================================================
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TEST_LOG_DIR="${LOG_BASE_DIR}/${TIMESTAMP}"
VALIDATOR_LOG="${TEST_LOG_DIR}/validator.log"
BENCHMARK_LOG="${TEST_LOG_DIR}/benchmark.log"
RESULT_FILE="${TEST_LOG_DIR}/result.txt"
CONFIG_FILE="${TEST_LOG_DIR}/config.json"

create_log_dir() {
    log_step "Create log directory: ${TEST_LOG_DIR}"
    mkdir -p "${TEST_LOG_DIR}"
    
    # Collect system info
    local cpu_info=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || cat /proc/cpuinfo 2>/dev/null | grep "model name" | head -1 | cut -d: -f2 || echo "Unknown")
    local cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "Unknown")
    local memory_gb=$(echo "scale=1; $(sysctl -n hw.memsize 2>/dev/null || grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2*1024}' || echo 0) / 1073741824" | bc 2>/dev/null || echo "Unknown")
    
    # Save configuration
    cat > "${CONFIG_FILE}" << EOF
{
    "timestamp": "${TIMESTAMP}",
    "system": {
        "cpu": "${cpu_info}",
        "cpu_cores": ${cpu_cores},
        "memory_gb": ${memory_gb},
        "os": "$(uname -s) $(uname -r)"
    },
    "services": {
        "num_validators": ${NUM_VALIDATORS},
        "num_solvers": ${NUM_SOLVERS},
        "validator_port": ${VALIDATOR_PORT},
        "solver_base_port": ${SOLVER_BASE_PORT},
        "mock_tee": ${MOCK_TEE}
    },
    "benchmark": {
        "mode": "${BENCHMARK_MODE}",
        "total_requests": ${TOTAL_REQUESTS},
        "concurrency": ${CONCURRENCY},
        "warmup_requests": ${WARMUP_REQUESTS},
        "use_test_accounts": ${USE_TEST_ACCOUNTS},
        "init_accounts": ${INIT_ACCOUNTS},
        "init_account_balance": ${INIT_ACCOUNT_BALANCE},
        "coins_per_account": ${COINS_PER_ACCOUNT},
        "sustained_duration": ${SUSTAINED_DURATION},
        "sustained_tps": ${SUSTAINED_TPS},
        "ramp_start": ${RAMP_START},
        "ramp_step": ${RAMP_STEP},
        "ramp_step_duration": ${RAMP_STEP_DURATION},
        "ramp_duration": ${RAMP_DURATION},
        "use_batch": ${USE_BATCH},
        "batch_size": ${BATCH_SIZE}
    },
    "logging": {
        "rust_log_level": "${RUST_LOG_LEVEL}",
        "log_dir": "${TEST_LOG_DIR}"
    }
}
EOF
    log_ok "Configuration saved to ${CONFIG_FILE}"
}

# ============================================================================
# Disable proxy
# ============================================================================
disable_proxy() {
    log_step "Disabling proxy settings"
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    export NO_PROXY="127.0.0.1,localhost,*"
    log_ok "Proxy disabled"
}

# ============================================================================
# Clean up old processes
# ============================================================================
cleanup_processes() {
    log_step "Cleaning up old processes"
    pkill -f "setu-validator" 2>/dev/null || true
    pkill -f "setu-solver" 2>/dev/null || true
    sleep 1
    
    # Confirm port has been released
    for port in $(seq $VALIDATOR_PORT $VALIDATOR_PORT) $(seq $SOLVER_BASE_PORT $((SOLVER_BASE_PORT + NUM_SOLVERS - 1))); do
        if lsof -i :$port >/dev/null 2>&1; then
            log_warn "Port $port is still in use; forcing release"
            lsof -i :$port | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null || true
        fi
    done
    sleep 1
    log_ok "Old processes cleaned up"
}

# ============================================================================
# Clean database
# ============================================================================
cleanup_database() {
    log_step "Cleaning database"
    # Confirm no leftover processes are holding the database
    local retries=0
    while [ $retries -lt 5 ]; do
        if ! pgrep -f "setu-validator" >/dev/null 2>&1 && ! pgrep -f "setu-solver" >/dev/null 2>&1; then
            break
        fi
        retries=$((retries + 1))
        log_info "Waiting for processes to exit completely... ($retries/5)"
        sleep 1
    done
    rm -rf "${PROJECT_ROOT}/example_db"
    log_ok "Database cleaned"
}

# ============================================================================
# Start Validator
# ============================================================================
start_validator() {
    log_step "Starting Validator"
    
    local tee_flag=""
    if [ "$MOCK_TEE" = true ]; then
        tee_flag="--mock-tee"
    fi
    
    # Explicitly set env vars to disable proxy and configure Validator
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    NO_PROXY="127.0.0.1,localhost,*" \
    RUST_LOG="${RUST_LOG_LEVEL}" \
    VALIDATOR_HTTP_PORT="${VALIDATOR_PORT}" \
    VALIDATOR_LISTEN_ADDR="127.0.0.1" \
    "${PROJECT_ROOT}/target/release/setu-validator" ${tee_flag} \
        >> "${VALIDATOR_LOG}" 2>&1 &
    
    VALIDATOR_PID=$!
    echo $VALIDATOR_PID > "${TEST_LOG_DIR}/validator.pid"
    
    log_info "Validator PID: ${VALIDATOR_PID}"
    log_info "Waiting for Validator to start..."
    sleep ${WAIT_STARTUP}
    
    # Check health (with retries)
    local retries=0
    while [ $retries -lt $HEALTH_CHECK_RETRIES ]; do
        if curl -s "http://127.0.0.1:${VALIDATOR_PORT}/api/v1/health" 2>/dev/null | grep -q "healthy"; then
            log_ok "Validator started successfully"
            return 0
        fi
        retries=$((retries + 1))
        log_info "Waiting for Validator to be ready... ($retries/$HEALTH_CHECK_RETRIES)"
        sleep 1
    done
    
    log_error "Validator failed to start"
    cat "${VALIDATOR_LOG}"
    exit 1
}

# ============================================================================
# Start Solvers
# ============================================================================
start_solvers() {
    log_step "Starting ${NUM_SOLVERS} Solver(s)"
    
    local tee_flag=""
    if [ "$MOCK_TEE" = true ]; then
        tee_flag="--mock-tee"
    fi
    
    for i in $(seq 1 $NUM_SOLVERS); do
        local solver_port=$((SOLVER_BASE_PORT + i - 1))
        local solver_log="${TEST_LOG_DIR}/solver_${i}.log"
        
        # Configure Solver via env vars (instead of CLI args)
        # Explicitly set env vars to disable proxy
        env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        NO_PROXY="127.0.0.1,localhost,*" \
        SOLVER_ID="solver_${i}" \
        SOLVER_PORT="${solver_port}" \
        VALIDATOR_ADDRESS="127.0.0.1" \
        VALIDATOR_HTTP_PORT="${VALIDATOR_PORT}" \
        RUST_LOG="${RUST_LOG_LEVEL}" \
        "${PROJECT_ROOT}/target/release/setu-solver" \
            ${tee_flag} \
            >> "${solver_log}" 2>&1 &
        
        local solver_pid=$!
        echo $solver_pid >> "${TEST_LOG_DIR}/solver.pids"
        log_info "Solver ${i} PID: ${solver_pid}, Port: ${solver_port}"
    done
    
    log_info "Waiting for Solvers to start..."
    
    # Wait for all solvers to register (with retries)
    local retries=0
    local solver_count=0
    while [ $retries -lt $HEALTH_CHECK_RETRIES ]; do
        solver_count=$(curl -s "http://127.0.0.1:${VALIDATOR_PORT}/api/v1/health" 2>/dev/null | grep -o '"solver_count":[0-9]*' | grep -o '[0-9]*' || echo "0")
        if [ "$solver_count" -ge "$NUM_SOLVERS" ]; then
            log_ok "All ${NUM_SOLVERS} solver(s) started (registered: ${solver_count})"
            return 0
        fi
        retries=$((retries + 1))
        log_info "Waiting for Solver registration... ($solver_count/$NUM_SOLVERS) [$retries/$HEALTH_CHECK_RETRIES]"
        sleep 1
    done
    
    log_warn "Solver startup may be incomplete (expected: ${NUM_SOLVERS}, registered: ${solver_count})"
}

# ============================================================================
# Run Benchmark
# ============================================================================
run_benchmark() {
    log_step "Running Benchmark test"
    
    # Check whether the Validator process is still running
    if [ -f "${TEST_LOG_DIR}/validator.pid" ]; then
        local vpid=$(cat "${TEST_LOG_DIR}/validator.pid")
        if ! kill -0 "$vpid" 2>/dev/null; then
            log_error "Validator process (PID: $vpid) has exited!"
            log_error "Last 20 lines of logs:"
            tail -20 "${VALIDATOR_LOG}" 2>/dev/null
            exit 1
        fi
        log_ok "Validator process (PID: $vpid) is running"
    fi
    
    local benchmark_args="-t ${TOTAL_REQUESTS} -c ${CONCURRENCY}"
    
    if [ "$USE_TEST_ACCOUNTS" = true ]; then
        benchmark_args="${benchmark_args} --use-test-accounts"
    fi
    
    # Account initialization parameters
    if [ "$INIT_ACCOUNTS" -gt 0 ]; then
        benchmark_args="${benchmark_args} --init-accounts ${INIT_ACCOUNTS} --init-account-balance ${INIT_ACCOUNT_BALANCE} --coins-per-account ${COINS_PER_ACCOUNT}"
    fi
    
    if [ "$WARMUP_REQUESTS" -gt 0 ]; then
        benchmark_args="${benchmark_args} --warmup ${WARMUP_REQUESTS}"
    fi
    
    # Batch API parameters
    if [ "$USE_BATCH" = true ]; then
        benchmark_args="${benchmark_args} --use-batch --batch-size ${BATCH_SIZE}"
    fi
    
    # Add parameters based on mode
    case $BENCHMARK_MODE in
        sustained)
            benchmark_args="${benchmark_args} -m sustained --duration ${SUSTAINED_DURATION} --target-tps ${SUSTAINED_TPS}"
            ;;
        ramp)
            benchmark_args="${benchmark_args} -m ramp --duration ${RAMP_DURATION} --ramp-start ${RAMP_START} --ramp-step ${RAMP_STEP} --ramp-step-duration ${RAMP_STEP_DURATION}"
            ;;
        *)
            # burst mode is the default
            benchmark_args="${benchmark_args} -m burst"
            ;;
    esac
    
    log_info "Benchmark args: ${benchmark_args}"
    echo "Benchmark args: ${benchmark_args}" >> "${RESULT_FILE}"
    echo "======================================" >> "${RESULT_FILE}"
    
    # Run Benchmark (proxy explicitly disabled)
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    NO_PROXY="127.0.0.1,localhost,*" \
    "${PROJECT_ROOT}/target/release/setu-benchmark" \
        -u "http://127.0.0.1:${VALIDATOR_PORT}" \
        ${benchmark_args} \
        2>&1 | tee -a "${BENCHMARK_LOG}" "${RESULT_FILE}"
    
    log_ok "Benchmark complete"
}

# ============================================================================
# Collect results
# ============================================================================
collect_results() {
    log_step "Collecting test results"
    
    # Extract key metrics (with stricter regex)
    local tps=$(grep "Final TPS" "${RESULT_FILE}" | grep -o "TPS: [0-9.]*" | grep -o "[0-9.]*" || echo "N/A")
    local success_rate=$(grep "Final TPS" "${RESULT_FILE}" | grep -o "Success Rate: [0-9.]*%" | grep -o "[0-9.]*%" || echo "N/A")
    local p99=$(grep "Final TPS" "${RESULT_FILE}" | grep -o "P99 Latency: [0-9.]*ms" | grep -o "[0-9.]*" || echo "N/A")
    [ "$p99" != "N/A" ] && p99="${p99} ms"
    
    # Batch mode info
    local batch_info=""
    if [ "$USE_BATCH" = true ]; then
        batch_info=" (batch: ${BATCH_SIZE})"
    fi
    
    # Account init info
    local init_info=""
    if [ "$INIT_ACCOUNTS" -gt 0 ]; then
        init_info=" (init: ${INIT_ACCOUNTS} accounts)"
    fi

    # Generate summary
    cat >> "${RESULT_FILE}" << EOF

======================================
Test Summary
======================================
Timestamp:       ${TIMESTAMP}
Number of solvers:  ${NUM_SOLVERS}
Total requests:     ${TOTAL_REQUESTS}
Concurrency:       ${CONCURRENCY}
Mode:         ${BENCHMARK_MODE}${batch_info}${init_info}
Batch API:      ${USE_BATCH}
Batch size:     ${BATCH_SIZE}
Init accounts:   ${INIT_ACCOUNTS}

Results:
  TPS:          ${tps}
  Success rate:       ${success_rate}
  P99 latency:     ${p99}
======================================
EOF

    log_ok "Results saved to: ${RESULT_FILE}"
    
    # Display summary
    echo ""
    echo "=============================================="
    echo -e "${GREEN}Test complete!${NC}"
    echo "=============================================="
    echo "  Log directory:   ${TEST_LOG_DIR}"
    echo "  Solver count: ${NUM_SOLVERS}"
    echo "  Total requests:     ${TOTAL_REQUESTS}"
    echo "  Concurrency:       ${CONCURRENCY}"
    if [ "$INIT_ACCOUNTS" -gt 0 ]; then
        echo "  Init accounts: ${INIT_ACCOUNTS}"
    fi
    if [ "$USE_BATCH" = true ]; then
        echo "  Batch mode:   yes (batch_size=${BATCH_SIZE})"
    fi
    echo ""
    echo -e "  ${CYAN}TPS:${NC}        ${tps}"
    echo -e "  ${CYAN}Success rate:${NC}     ${success_rate}"
    echo -e "  ${CYAN}P99 latency:${NC}    ${p99}"
    echo "=============================================="
}

# ============================================================================
# Cleanup function
# ============================================================================
cleanup() {
    log_step "Cleaning up processes"
    pkill -f "setu-validator" 2>/dev/null || true
    pkill -f "setu-solver" 2>/dev/null || true
    log_ok "Processes cleaned up"
}

# ============================================================================
# Show configuration (dry-run)
# ============================================================================
show_config() {
    echo ""
    echo "=============================================="
    echo "Test Configuration (Dry Run)"
    echo "=============================================="
    echo "Service configuration:"
    echo "  Validator count: ${NUM_VALIDATORS}"
    echo "  Number of solvers:    ${NUM_SOLVERS}"
    echo "  Validator port: ${VALIDATOR_PORT}"
    echo "  Solver base port: ${SOLVER_BASE_PORT}"
    echo "  Mock TEE:       ${MOCK_TEE}"
    echo ""
    echo "Benchmark configuration:"
    echo "  Mode:           ${BENCHMARK_MODE}"
    echo "  Total requests:       ${TOTAL_REQUESTS}"
    echo "  Concurrency:         ${CONCURRENCY}"
    echo "  Warmup requests:       ${WARMUP_REQUESTS}"
    echo "  Use test accounts:   ${USE_TEST_ACCOUNTS}"
    if [ "$INIT_ACCOUNTS" -gt 0 ]; then
        echo "  Init accounts:     ${INIT_ACCOUNTS}"
        echo "  Account initial balance:   ${INIT_ACCOUNT_BALANCE}"
        echo "  Coins per account:     ${COINS_PER_ACCOUNT}"
    fi
    if [ "$USE_BATCH" = true ]; then
        echo "  Batch mode:       yes"
        echo "  Batch size:       ${BATCH_SIZE}"
    fi
    if [ "$BENCHMARK_MODE" = "sustained" ]; then
        echo "  Duration:       ${SUSTAINED_DURATION}s"
        echo "  Target TPS:       ${SUSTAINED_TPS}"
    fi
    if [ "$BENCHMARK_MODE" = "ramp" ]; then
        echo "  Ramp start TPS:    ${RAMP_START}"
        echo "  Ramp step:       ${RAMP_STEP} TPS/step"
        echo "  Step duration:       ${RAMP_STEP_DURATION}s"
        echo "  Total duration:         ${RAMP_DURATION}s"
    fi
    echo ""
    echo "Log configuration:"
    echo "  Log level:       ${RUST_LOG_LEVEL}"
    echo "  Log directory:       ${TEST_LOG_DIR}"
    echo "=============================================="
}

# ============================================================================
# Configuration validation
# ============================================================================
validate_config() {
    log_step "Validating configuration"
    local warnings=0
    
    # Check ratio of INIT_ACCOUNTS to CONCURRENCY
    if [ "$INIT_ACCOUNTS" -gt 0 ] && [ "$INIT_ACCOUNTS" -lt "$CONCURRENCY" ]; then
        log_warn "INIT_ACCOUNTS($INIT_ACCOUNTS) < CONCURRENCY($CONCURRENCY): high coin contention; recommend INIT_ACCOUNTS >= CONCURRENCY * 2"
        warnings=$((warnings + 1))
    fi
    
    # Check COINS_PER_ACCOUNT
    if [ "$INIT_ACCOUNTS" -gt 0 ] && [ "$COINS_PER_ACCOUNT" -lt 2 ] && [ "$CONCURRENCY" -gt "$INIT_ACCOUNTS" ]; then
        log_warn "COINS_PER_ACCOUNT($COINS_PER_ACCOUNT) is too low and concurrency exceeds account count; recommend increasing to >= 2"
        warnings=$((warnings + 1))
    fi
    
    # Check that warmup count does not exceed total requests
    if [ "$WARMUP_REQUESTS" -ge "$TOTAL_REQUESTS" ]; then
        log_warn "WARMUP_REQUESTS($WARMUP_REQUESTS) >= TOTAL_REQUESTS($TOTAL_REQUESTS): warmup count is too large"
        warnings=$((warnings + 1))
    fi
    
    if [ $warnings -eq 0 ]; then
        log_ok "Configuration validation passed"
    else
        log_warn "Found ${warnings} configuration warning(s) (continuing)"
    fi
}

# ============================================================================
# Main flow
# ============================================================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           Setu TPS Benchmark Test                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        show_config
        exit 0
    fi
    
    # Check binaries
    if [ ! -f "${PROJECT_ROOT}/target/release/setu-validator" ] || \
       [ ! -f "${PROJECT_ROOT}/target/release/setu-solver" ] || \
       [ ! -f "${PROJECT_ROOT}/target/release/setu-benchmark" ]; then
        log_error "Please build first: cargo build --release"
        exit 1
    fi
    
    # Install cleanup hook
    trap cleanup EXIT
    
    # Run test flow
    disable_proxy
    create_log_dir
    validate_config
    cleanup_processes
    cleanup_database
    start_validator
    start_solvers
    run_benchmark
    collect_results
    
    log_ok "Test complete!"
}

# Run main flow
main
