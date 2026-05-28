#!/bin/bash
# ============================================================================
# Full deployment: sync source -> build -> distribute binaries -> distribute config/keys -> start
# Usage: ./deploy.sh [--skip-build] [--no-start]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

SKIP_BUILD=false
NO_START=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build) SKIP_BUILD=true; shift ;;
        --no-start)   NO_START=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

print_header "Setu Multi-Validator Full Deployment"
echo "  Servers: ${SERVERS[*]}"
echo "  Build server: ${BUILD_SERVER}"
echo ""

# ── Step 1: Build binaries ──────────────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    echo "━━━ [1/4] Build & distribute binaries ━━━"
    bash "${SCRIPT_DIR}/build.sh"
else
    echo "━━━ [1/4] Skipping build ━━━"
fi

# ── Step 2: Distribute config files ─────────────────────────────────────────
echo ""
echo "━━━ [2/4] Distribute config files ━━━"
for i in "${!SERVERS[@]}"; do
    host="${SERVERS[$i]}"
    vid="${VALIDATOR_IDS[$i]}"
    echo "  → ${vid} (${host})"
    
    # Ensure directories exist
    remote_exec "$host" "mkdir -p ${REMOTE_CONFIG} ${REMOTE_KEYS}"
    
    # Copy genesis-remote.json
    remote_copy "${SCRIPT_DIR}/genesis-remote.json" "$host" "${REMOTE_CONFIG}/genesis-remote.json"
done
print_ok "genesis-remote.json distributed to all nodes"

# ── Step 3: Distribute / check key files ────────────────────────────────────
echo ""
echo "━━━ [3/4] Check key files ━━━"
KEYS_READY=true
for i in "${!SERVERS[@]}"; do
    host="${SERVERS[$i]}"
    vid="${VALIDATOR_IDS[$i]}"
    local_key="${PROJECT_DIR}/keys/${vid}.key"
    
    # Try to copy key from local
    if [ -f "$local_key" ]; then
        remote_copy "$local_key" "$host" "${REMOTE_KEYS}/${vid}.key"
        print_ok "${vid}: key copied from local"
    elif remote_exec "$host" "test -f ${REMOTE_KEYS}/${vid}.key" 2>/dev/null; then
        print_ok "${vid}: remote key already exists"
    else
        print_warn "${vid}: key file missing!"
        echo "    local path:  ${local_key}"
        echo "    remote path: ${host}:${REMOTE_KEYS}/${vid}.key"
        KEYS_READY=false
    fi
done

if [ "$KEYS_READY" = false ]; then
    echo ""
    print_warn "Some keys are missing. Options:"
    echo "    1) Generate locally: cd ${PROJECT_DIR} && cargo run -p setu-cli -- gen-key generate --scheme ed25519 --output keys/validator-N.key"
    echo "    2) Generate remotely: ./keygen.sh"
    echo "    3) Continue without keys (signature verification will be skipped)"
    echo ""
    read -p "  Continue with deployment? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ── Step 4: Verify deployment readiness ─────────────────────────────────────
echo ""
echo "━━━ [4/4] Verify deployment readiness ━━━"
for i in "${!SERVERS[@]}"; do
    host="${SERVERS[$i]}"
    vid="${VALIDATOR_IDS[$i]}"
    
    # Check binary
    if remote_exec "$host" "test -f ${REMOTE_BIN}/setu-validator" 2>/dev/null; then
        print_ok "${vid}: binary ready"
    else
        print_err "${vid}: setu-validator binary missing!"
    fi
    
    # Check genesis
    if remote_exec "$host" "test -f ${REMOTE_CONFIG}/genesis-remote.json" 2>/dev/null; then
        print_ok "${vid}: genesis config ready"
    else
        print_err "${vid}: genesis-remote.json missing!"
    fi
done

# ── Start ───────────────────────────────────────────────────────────────────
if [ "$NO_START" = false ]; then
    echo ""
    bash "${SCRIPT_DIR}/start.sh" all
else
    echo ""
    print_ok "Deployment complete (not started)"
    echo "  Start manually: ./start.sh all"
fi
