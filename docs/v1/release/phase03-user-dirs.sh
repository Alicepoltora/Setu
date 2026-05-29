#!/usr/bin/env bash
# Phase 3 — 所有节点：setu 用户 + 目录骨架
# 用法：bash phase03-user-dirs.sh <host-alias>
source "$(dirname "$0")/lib.sh"
require_args 1 $# "phase03-user-dirs.sh <host-alias>"
HOST="$1"

log_step "Phase 3 @ $HOST：用户与目录"

mssh "$HOST" "SETU_HOME='$SETU_HOME' bash -s" <<'REMOTE'
set -euo pipefail
sudo groupadd --system setu 2>/dev/null || true
# shell 用 /bin/bash：后续 phase09/10/rollback 通过 sssh 远程执行命令需要可登录 shell
# 安全靠：仅 key 登录、无密码、sudoers 中无授权
sudo useradd --system --gid setu --home-dir "$SETU_HOME" \
  --shell /bin/bash setu 2>/dev/null || true
# 若之前用 nologin 创建过，纠正之
sudo usermod -s /bin/bash setu 2>/dev/null || true

sudo install -d -o setu -g setu -m 750 "$SETU_HOME"
sudo install -d -o setu -g setu -m 750 "$SETU_HOME/bin"
sudo install -d -o setu -g setu -m 750 "$SETU_HOME/bin/releases"
# 注意：不 mkdir current；symlink 由 phase09 用 ln -sfnT 创建
sudo install -d -o setu -g setu -m 750 "$SETU_HOME/data"
sudo install -d -o setu -g setu -m 750 "$SETU_HOME/logs"
sudo install -d -o setu -g setu -m 750 "$SETU_HOME/conf"
sudo install -d -o setu -g setu -m 700 "$SETU_HOME/keys"

# 防止 phase09 才发现没装 setu 的 authorized_keys
sudo install -d -o setu -g setu -m 700 "$SETU_HOME/.ssh"

ls -ld "$SETU_HOME" "$SETU_HOME"/{bin,data,logs,conf,keys}
REMOTE

# 把维护 key 也加到 setu 用户，便于后续 sssh 操作
log_info "为 setu 用户安装维护 key（来自 ${MAINT_KEY}.pub）"
if [ ! -f "${MAINT_KEY}.pub" ]; then
    log_warn "${MAINT_KEY}.pub 不存在，跳过 setu 用户 SSH key 安装（后续 phase 将失败）"
else
    PUBKEY=$(cat "${MAINT_KEY}.pub")
    mssh "$HOST" "echo '$PUBKEY' | sudo tee -a $SETU_HOME/.ssh/authorized_keys >/dev/null && \
                  sudo chown setu:setu $SETU_HOME/.ssh/authorized_keys && \
                  sudo chmod 600 $SETU_HOME/.ssh/authorized_keys"
    log_ok "setu 用户已加 authorized_keys"
fi

log_ok "Phase 3 完成 @ $HOST"
