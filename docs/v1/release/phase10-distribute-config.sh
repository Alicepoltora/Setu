#!/usr/bin/env bash
# Phase 10 — ops → 所有 validator：分发 genesis + 各自 key
# 用法：bash phase10-distribute-config.sh
#
# 依赖：phase07 产物
#   - $GENESIS_LOCAL (同一个文件发给所有节点)
#   - $KEY_DIR_LOCAL/validator-{1,2,3}.json (按 VAL_ALIASES 顺序对应)
source "$(dirname "$0")/lib.sh"

log_step "Phase 10：分发 genesis + key"

if [ ! -f "$GENESIS_LOCAL" ]; then
    log_err "未找到 genesis：$GENESIS_LOCAL"
    exit 1
fi

idx=1
for HOST in "${VAL_ALIASES[@]}"; do
    KEY_FILE="$KEY_DIR_LOCAL/validator-${idx}.json"
    if [ ! -f "$KEY_FILE" ]; then
        log_err "未找到 $KEY_FILE，先跑 phase07"
        exit 1
    fi

    log_info "─── $HOST ← validator-${idx}.json ───"

    # genesis
    rsync -av --chmod=u=rw,g=r,o= \
      -e "ssh -i $MAINT_KEY $SSH_OPTS" \
      "$GENESIS_LOCAL" \
      "${SETU_USER}@$(resolve_host "$HOST"):$SETU_HOME/conf/genesis.json"

    # key（仅自己可读）
    rsync -av --chmod=u=rw,g=,o= \
      -e "ssh -i $MAINT_KEY $SSH_OPTS" \
      "$KEY_FILE" \
      "${SETU_USER}@$(resolve_host "$HOST"):$SETU_HOME/keys/validator.json"

    sssh "$HOST" "ls -l $SETU_HOME/conf/genesis.json $SETU_HOME/keys/validator.json"
    log_ok "[$HOST] 配置分发完成"

    idx=$((idx + 1))
done

log_ok "Phase 10 完成"
