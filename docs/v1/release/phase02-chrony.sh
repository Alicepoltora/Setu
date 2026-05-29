#!/usr/bin/env bash
# Phase 2 — 所有节点：chrony 时间同步
# 用法：bash phase02-chrony.sh <host-alias>
source "$(dirname "$0")/lib.sh"
require_args 1 $# "phase02-chrony.sh <host-alias>"
HOST="$1"

log_step "Phase 2 @ $HOST：chrony 替换 systemd-timesyncd"

mssh "$HOST" "bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo systemctl disable --now systemd-timesyncd 2>/dev/null || true
sudo apt-get install -y -qq chrony
sudo systemctl enable --now chrony
sleep 5
chronyc tracking | grep -E 'Leap status|System time'
REMOTE

log_ok "Phase 2 完成 @ $HOST（检查 Leap status: Normal 与偏差 < 100ms）"
