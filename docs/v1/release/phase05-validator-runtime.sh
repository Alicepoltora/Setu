#!/usr/bin/env bash
# Phase 5 — validator：运行时库 + sysctl + logrotate
# 用法：bash phase05-validator-runtime.sh <val-host-alias>
source "$(dirname "$0")/lib.sh"
require_args 1 $# "phase05-validator-runtime.sh <val-host-alias>"
HOST="$1"

if ! [[ "$HOST" =~ ^val- ]]; then
    log_err "Phase 5 仅适用于 validator 节点（别名应以 val- 开头）"
    exit 2
fi

log_step "Phase 5 @ $HOST：运行时库 + sysctl + logrotate"

mssh "$HOST" "bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── runtime libs ───────────────────────────────────────────────────────────
sudo apt-get install -y -qq libssl3 ca-certificates jq curl rsync logrotate

# ── sysctl 调优 ────────────────────────────────────────────────────────────
sudo tee /etc/sysctl.d/99-setu.conf >/dev/null <<'EOF'
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
fs.file-max = 2097152
EOF
sudo sysctl --system >/dev/null

# ── file descriptor limit ──────────────────────────────────────────────────
sudo tee /etc/security/limits.d/99-setu.conf >/dev/null <<'EOF'
setu soft nofile 1048576
setu hard nofile 1048576
EOF

# ── logrotate（必须在 Setu 启动前生效） ────────────────────────────────────
sudo tee /etc/logrotate.d/setu >/dev/null <<'EOF'
/opt/setu/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su setu setu
    create 0640 setu setu
}
EOF
sudo logrotate -d /etc/logrotate.d/setu >/dev/null   # dry-run 必须无 error
REMOTE

log_ok "Phase 5 完成 @ $HOST"
