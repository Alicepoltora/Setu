#!/bin/bash
# ============================================================================
# Setu Multi-Validator remote deployment configuration
# ============================================================================

# ── .env loading ─────────────────────────────────────────────────────────
# All sensitive values (IPs, passwords) are loaded from deploy/.env (format: KEY = value)
# See deploy/.env.example for the template
_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [ ! -f "$_ENV_FILE" ]; then
    echo "ERROR: deploy/.env not found. Copy deploy/.env.example to deploy/.env and fill in values."
    exit 1
fi

_read_env() { grep "^$1" "$_ENV_FILE" | cut -d'=' -f2 | tr -d ' '; }

_fail_if_env_placeholder() {
    local key="$1"
    local value="$2"
    case "$value" in
        ""|"1.2.3.4"|"5.6.7.8"|"9.10.11.12"|"your-ssh-password-here")
            echo "ERROR: deploy/.env contains placeholder or empty value for ${key}. Restore real dev-mult credentials before running remote scripts."
            exit 2
            ;;
    esac
}

# ── Server list (loaded from .env) ─────────────────────────────────────────────────
SERVERS=(
    "$(_read_env 'VALIDATOR-NODE-IP-01')"
    "$(_read_env 'VALIDATOR-NODE-IP-02')"
    "$(_read_env 'VALIDATOR-NODE-IP-03')"
)

_fail_if_env_placeholder 'VALIDATOR-NODE-IP-01' "${SERVERS[0]}"
_fail_if_env_placeholder 'VALIDATOR-NODE-IP-02' "${SERVERS[1]}"
_fail_if_env_placeholder 'VALIDATOR-NODE-IP-03' "${SERVERS[2]}"

VALIDATOR_IDS=(
    "validator-1"
    "validator-2"
    "validator-3"
)

# ── SSH configuration ───────────────────────────────────────────────────────────────
SSH_USER=$(_read_env 'VALIDATOR-NODE-USERNAME')
SSH_PWD=$(_read_env 'VALIDATOR-NODE-PWD')
SSH_USER="${SSH_USER:-root}"
_fail_if_env_placeholder 'VALIDATOR-NODE-PWD' "$SSH_PWD"

# ControlMaster multiplexing: one TCP+auth handshake per (user,host,port) reused
# for N subsequent ssh/scp/rsync. Mitigates sshd MaxStartups / fail2ban
# rate-limiting observed during deploy bursts (bug 20260421-deploy-ssh-flakiness).
# %C = hash(user+host+port), short and collision-free across our 3 nodes.
SSH_CTRL_DIR="${SSH_CTRL_DIR:-/tmp}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=${SSH_CTRL_DIR}/setu-ssh-%C -o ControlPersist=300"

# Options passed inline to ssh/scp/rsync running ON a remote host (inter-VM hop in
# remote_to_remote_copy). Mirrors SSH_OPTS but uses a distinct control path so
# the remote side does not collide with local sockets and so we can clean them
# independently. /tmp on Contabo Ubuntu is world-writable and persistent enough.
INNER_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=/tmp/setu-bs-%C -o ControlPersist=300"

# Best-effort cleanup of local ControlMaster sockets on shell exit.
_cleanup_ssh_control_sockets() {
    rm -f "${SSH_CTRL_DIR}"/setu-ssh-* 2>/dev/null || true
}
trap _cleanup_ssh_control_sockets EXIT

# Build server (default: first host)
BUILD_SERVER="${SERVERS[0]}"

# ── Remote paths ──────────────────────────────────────────────────────────────────────
REMOTE_BASE="/opt/setu"
REMOTE_SRC="${REMOTE_BASE}/src"
REMOTE_BIN="${REMOTE_BASE}/bin"
REMOTE_KEYS="${REMOTE_BASE}/keys"
REMOTE_CONFIG="${REMOTE_BASE}/config"
REMOTE_DATA="${REMOTE_BASE}/data"
REMOTE_LOGS="${REMOTE_BASE}/logs"

# ── Port configuration ──────────────────────────────────────────────────────
HTTP_PORT=8080          # HTTP API port (uniform across all nodes)
P2P_PORT=9000           # P2P port (uniform across all nodes)
SOLVER_PORT=9001        # Solver port

# ── Log level ─────────────────────────────────────────────────────────────
RUST_LOG="info,setu_validator=debug,consensus=debug"

# ── Local project paths ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ============================================================================
# SSH helper functions
# ============================================================================

# Execute a command on a remote host
remote_exec() {
    local host="$1"
    shift
    if command -v sshpass &>/dev/null; then
        sshpass -p "$SSH_PWD" ssh $SSH_OPTS "${SSH_USER}@${host}" "$@"
    else
        ssh $SSH_OPTS "${SSH_USER}@${host}" "$@"
    fi
}

# Copy a file (local -> remote)
remote_copy() {
    local src="$1"
    local host="$2"
    local dest="$3"
    if command -v sshpass &>/dev/null; then
        sshpass -p "$SSH_PWD" scp $SSH_OPTS -r "$src" "${SSH_USER}@${host}:${dest}"
    else
        scp $SSH_OPTS -r "$src" "${SSH_USER}@${host}:${dest}"
    fi
}

# Sync a directory remotely (incremental)
remote_sync() {
    local src="$1"
    local host="$2"
    local dest="$3"
    local rsync_opts="--delete"
    if [ "${4:-}" = "--no-delete" ]; then
        rsync_opts=""
    fi

    local exclude_opts=(
        --exclude 'target/'
        --exclude '.git/'
        --exclude '.github/'
        --exclude 'logs/'
        --exclude 'deploy/'
        --exclude 'docs/'
        --exclude 'ai/'
        --exclude 'keys/'
        --exclude 'tests/'
        --exclude 'docker/'
        --exclude 'scripts/'
        --exclude 'setu-framework/compiled/'
        --exclude '*.md'
        --exclude '*.log'
    )

    if command -v sshpass &>/dev/null; then
        SSHPASS="$SSH_PWD" rsync -az $rsync_opts \
            "${exclude_opts[@]}" \
            -e "sshpass -e ssh $SSH_OPTS" \
            "$src" "${SSH_USER}@${host}:${dest}"
    else
        rsync -az $rsync_opts \
            "${exclude_opts[@]}" \
            -e "ssh $SSH_OPTS" \
            "$src" "${SSH_USER}@${host}:${dest}"
    fi
}

# Server-to-server copy: run scp on from_host to push directly to to_host
# (avoids the double-auth issue of scp -3; uses the SSHPASS env var to avoid
# quoting issues with the password)
# Uses INNER_SSH_OPTS to enable ControlMaster on BUILD_SERVER, mitigating
# sshd MaxStartups / fail2ban rate-limiting on the inter-VM hop.
remote_to_remote_copy() {
    local from_host="$1"
    local from_path="$2"
    local to_host="$3"
    local to_path="$4"
    remote_exec "$from_host" \
        "SSHPASS='${SSH_PWD}' sshpass -e scp ${INNER_SSH_OPTS} '${from_path}' '${SSH_USER}@${to_host}:${to_path}'"
}

# Wait for a service to become healthy
wait_for_health() {
    local host="$1"
    local port="$2"
    local max_wait="${3:-30}"
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if curl -sf --connect-timeout 2 "http://${host}:${port}/api/v1/health" &>/dev/null; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Build the PEER_VALIDATORS list (excluding self)
get_peer_validators() {
    local self_index="$1"
    local peers=""
    for i in "${!SERVERS[@]}"; do
        if [ "$i" -ne "$self_index" ]; then
            if [ -n "$peers" ]; then
                peers="${peers},"
            fi
            peers="${peers}${SERVERS[$i]}:${P2P_PORT}"
        fi
    done
    echo "$peers"
}

# Print a separator/header line
print_header() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    printf "║  %-56s ║\n" "$1"
    echo "╚════════════════════════════════════════════════════════════╝"
}

print_step() {
    echo "  [$1/${2}] $3"
}

print_ok() {
    echo "  ✓ $1"
}

print_warn() {
    echo "  ⚠ $1"
}

print_err() {
    echo "  ✗ $1"
}
