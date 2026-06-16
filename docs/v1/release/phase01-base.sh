#!/usr/bin/env bash
# Phase 1 — 所有节点：基础 apt 工具
# 用法：bash phase01-base.sh <host-alias>
# 示例：bash phase01-base.sh val-1
source "$(dirname "$0")/lib.sh"
require_args 1 $# "phase01-base.sh <host-alias>"
HOST="$1"

log_step "Phase 1 @ ${HOST}：基础工具安装"

mssh "$HOST" "bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \
  ca-certificates curl wget gnupg \
  jq rsync unzip git \
  htop lsof ufw logrotate \
  prometheus-node-exporter
echo "[remote] base packages installed"
REMOTE

# ops 额外装 vim/tmux
if [ "$HOST" = "ops" ]; then
    log_info "$HOST 是 ops，额外装 vim/tmux"
    mssh "$HOST" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vim tmux"
fi

log_ok "Phase 1 完成 @ $HOST"
