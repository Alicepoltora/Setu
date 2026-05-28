#!/bin/bash
# ============================================================================
# One-time server initialization: install Rust toolchain, system deps, create directories, generate keys
# Usage: ./setup.sh [1|2|3|all]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET="${1:-all}"

setup_server() {
    local idx="$1"
    local host="${SERVERS[$idx]}"
    local vid="${VALIDATOR_IDS[$idx]}"

    echo ""
    echo "━━━ Initializing ${vid} (${host}) ━━━"

    # 1) Create directories
    print_step 1 4 "Creating directory structure..."
    remote_exec "$host" "
        mkdir -p ${REMOTE_BIN} ${REMOTE_KEYS} ${REMOTE_CONFIG} ${REMOTE_DATA}/db ${REMOTE_LOGS}
    "
    print_ok "Directories created"

    # 2) Install system dependencies
    print_step 2 4 "Installing system dependencies..."
    remote_exec "$host" "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq \
            build-essential pkg-config libssl-dev libclang-dev cmake \
            protobuf-compiler curl git unzip jq sshpass \
            > /dev/null 2>&1
    "
    print_ok "System dependencies ready"

    # 3) Install Rust only on the build server (server-1)
    if [ "$idx" -eq 0 ]; then
        print_step 3 4 "Installing Rust toolchain (build server)..."
        remote_exec "$host" "
            if ! command -v rustup &>/dev/null; then
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
            fi
            source \"\$HOME/.cargo/env\"
            rustup update stable 2>/dev/null || true
            rustc --version
            cargo --version
        "
        print_ok "Rust toolchain ready"
    else
        print_step 3 4 "Skipping Rust install (non-build server)"
    fi

    # 4) Network & firewall configuration
    print_step 4 4 "Configuring network parameters & firewall..."
    remote_exec "$host" "
        # Increase socket buffers — Anemo P2P needs ≥ 2MB
        sysctl -w net.core.wmem_max=8388608 2>/dev/null || true
        sysctl -w net.core.rmem_max=8388608 2>/dev/null || true
        sysctl -w net.core.wmem_default=2097152 2>/dev/null || true
        sysctl -w net.core.rmem_default=2097152 2>/dev/null || true
        grep -q 'wmem_max' /etc/sysctl.conf || {
            echo 'net.core.wmem_max=8388608'    >> /etc/sysctl.conf
            echo 'net.core.rmem_max=8388608'    >> /etc/sysctl.conf
            echo 'net.core.wmem_default=2097152' >> /etc/sysctl.conf
            echo 'net.core.rmem_default=2097152' >> /etc/sysctl.conf
        }
    "
    remote_exec "$host" "
        # Try ufw
        if command -v ufw &>/dev/null; then
            ufw allow ${HTTP_PORT}/tcp 2>/dev/null || true
            ufw allow ${P2P_PORT}/udp 2>/dev/null || true
            ufw allow ${P2P_PORT}/tcp 2>/dev/null || true
            ufw allow ${SOLVER_PORT}/tcp 2>/dev/null || true
        fi
        # Try iptables (if ufw is unavailable)
        if command -v iptables &>/dev/null; then
            iptables -I INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p udp --dport ${P2P_PORT} -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p tcp --dport ${P2P_PORT} -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p tcp --dport ${SOLVER_PORT} -j ACCEPT 2>/dev/null || true
        fi
    "
    print_ok "Firewall rules added (HTTP=${HTTP_PORT}, P2P=${P2P_PORT})"
}

# ── Main logic ──────────────────────────────────────────────────────────────────
print_header "Setu Multi-Validator Server Initialization"

# Check for local sshpass
if ! command -v sshpass &>/dev/null; then
    print_warn "sshpass not installed; will use SSH key authentication"
    echo "  macOS install: brew install esolitos/ipa/sshpass"
    echo ""
fi

case "$TARGET" in
    1) setup_server 0 ;;
    2) setup_server 1 ;;
    3) setup_server 2 ;;
    all)
        for i in "${!SERVERS[@]}"; do
            setup_server "$i"
        done
        ;;
    *)
        echo "Usage: $0 [1|2|3|all]"
        exit 1
        ;;
esac

echo ""
print_ok "Initialization complete!"
echo ""
echo "Next step: ./build.sh   # Build and distribute binaries"
