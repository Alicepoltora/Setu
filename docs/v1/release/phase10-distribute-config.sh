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

# ── 0. 渲染运行时 env 文件（V1 ACCEPT 硬性要求） ────────────────────────────
# 来源：docs/release-doc/test-v1-inner/02-build-and-deploy-flags.md
# - SETU_RAW_TRANSFER_API_TOKEN: funding fixture / P1 / benchmark 必需，3 台必须一致
# - RUST_LOG: 保留 BUG-010 / consensus::diag 关键 tracing 输出
# 缺 token 时仅警告并跳过（允许"只刷 genesis"场景）；下游 phase12 会做闭环校验。
RENDER_ENV=1
if [ -z "${SETU_RAW_TRANSFER_API_TOKEN:-}" ]; then
    log_warn "未检测到 SETU_RAW_TRANSFER_API_TOKEN 环境变量，将跳过 /opt/setu/conf/env 渲染"
    log_warn "  如需启用 raw transfer / funding fixture，请："
    log_warn "    export SETU_RAW_TRANSFER_API_TOKEN=\"\$(cat /tmp/setu-raw-token)\""
    log_warn "  然后重跑 phase10 + phase11 --restart"
    RENDER_ENV=0
fi

idx=1
for HOST in "${VAL_ALIASES[@]}"; do
    KEY_FILE="$KEY_DIR_LOCAL/validator-${idx}.json"
    if [ ! -f "$KEY_FILE" ]; then
        log_err "未找到 ${KEY_FILE}，先跑 phase07"
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

    # 运行时 env 文件：root 拥有 / setu 组可读 / 0640
    # 注意：用 mssh（root）写入 /opt/setu/conf/env，避免 setu 用户对自己拥有的 secret 文件持有写权
    if [ "$RENDER_ENV" = "1" ]; then
        # token 不进 ssh 命令行（避免 ps 泄漏），通过 stdin 传入远端 install
        # shellcheck disable=SC2087
        printf 'SETU_RAW_TRANSFER_API_TOKEN=%s\nRUST_LOG=%s\n' \
            "$SETU_RAW_TRANSFER_API_TOKEN" \
            "setu=info,consensus=info,consensus::diag=info" \
            | ssh -i "$MAINT_KEY" $SSH_OPTS \
                "${MAINT_USER}@$(resolve_host "$HOST")" \
                'sudo install -d -o root -g setu -m 750 /opt/setu/conf && sudo install -m 640 -o root -g setu /dev/stdin /opt/setu/conf/env'
        log_ok "[$HOST] /opt/setu/conf/env 已渲染（root:setu 0640）"
    fi

    sssh "$HOST" "ls -l $SETU_HOME/conf/genesis.json $SETU_HOME/keys/validator.json"
    log_ok "[$HOST] 配置分发完成"

    idx=$((idx + 1))
done

log_ok "Phase 10 完成"
