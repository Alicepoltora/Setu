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

    # setu-cli keygen 产出 KeypairData JSON，但 setu_keys::load_keypair（即 setu-validator
    # / setu-solver 真正使用的加载器，见 crates/setu-keys/src/keypair_file.rs）期望
    # base64(ED25519_FLAG=0x00 || 32B secret)。两者文件名同为 *.json/*.key 但格式不兼容。
    # 若直接喂 JSON，validator 会得到 "Decoding error: Invalid byte 123, offset 0" 并
    # 静默降级到无 keypair 模式 → strict 签名打开 → 所有 CF vote 被丢弃 → 共识停滞，
    # 但 health 仍报 healthy（dag 只增长本地创世 batch），极难察觉。
    # 故在分发前从 JSON 派生 base64 sidecar（.key），phase11 unit 将 VALIDATOR_KEY_FILE
    # 指向该 sidecar；JSON 仍保留以便人类审计 / setu-cli 复用。
    KEY_B64_FILE="$KEY_DIR_LOCAL/validator-${idx}.key"
    if [ ! -f "$KEY_B64_FILE" ]; then
        log_info "[$HOST] 派生 base64 keypair sidecar：$(basename "$KEY_B64_FILE")"
        for tool in jq xxd base64; do
            command -v "$tool" >/dev/null 2>&1 || { log_err "$tool 未安装，无法派生 sidecar"; exit 1; }
        done
        hex=$(jq -r .private_key "$KEY_FILE")
        if [ -z "$hex" ] || [ "$hex" = "null" ]; then
            log_err "$KEY_FILE 缺少 .private_key 字段"; exit 1
        fi
        if [ "${#hex}" -ne 64 ]; then
            log_err "$KEY_FILE .private_key 长度异常（期望 64 hex 字符，实得 ${#hex}）"; exit 1
        fi
        umask 077
        ( printf '\x00'; printf '%s' "$hex" | xxd -r -p ) | base64 > "$KEY_B64_FILE"
        chmod 600 "$KEY_B64_FILE"
    fi

    log_info "─── $HOST ← validator-${idx}.{json,key} ───"

    # genesis
    rsync -av --chmod=u=rw,g=r,o= \
      -e "ssh -i $MAINT_KEY $SSH_OPTS" \
      "$GENESIS_LOCAL" \
      "${SETU_USER}@$(resolve_host "$HOST"):$SETU_HOME/conf/genesis.json"

    # key JSON（人类审计/CLI 复用，仅自己可读）
    rsync -av --chmod=u=rw,g=,o= \
      -e "ssh -i $MAINT_KEY $SSH_OPTS" \
      "$KEY_FILE" \
      "${SETU_USER}@$(resolve_host "$HOST"):$SETU_HOME/keys/validator.json"

    # key base64 sidecar（validator/solver 实际加载）
    rsync -av --chmod=u=rw,g=,o= \
      -e "ssh -i $MAINT_KEY $SSH_OPTS" \
      "$KEY_B64_FILE" \
      "${SETU_USER}@$(resolve_host "$HOST"):$SETU_HOME/keys/validator.key"

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

    sssh "$HOST" "ls -l $SETU_HOME/conf/genesis.json $SETU_HOME/keys/validator.json $SETU_HOME/keys/validator.key"
    log_ok "[$HOST] 配置分发完成"

    idx=$((idx + 1))
done

log_ok "Phase 10 完成"
