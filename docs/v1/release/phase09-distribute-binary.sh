#!/usr/bin/env bash
# Phase 9 — ops → 所有 validator：分发 binary + 校验 sha256/ldd/version + 切换 symlink
# 用法：bash phase09-distribute-binary.sh [RELEASE_ID]
#   不传 RELEASE_ID 时自动读 ./LAST_RELEASE_ID
source "$(dirname "$0")/lib.sh"

RELEASE_ID="${1:-}"
if [ -z "$RELEASE_ID" ]; then
    LAST_FILE="$(dirname "$(readlink -f "$0")")/LAST_RELEASE_ID"
    if [ -f "$LAST_FILE" ]; then
        RELEASE_ID=$(cat "$LAST_FILE")
        log_info "使用上次构建的 RELEASE_ID = $RELEASE_ID"
    else
        log_err "未指定 RELEASE_ID 且无 LAST_RELEASE_ID 文件"
        log_err "用法：bash phase09-distribute-binary.sh <RELEASE_ID>"
        exit 2
    fi
fi

STAGE="${SETU_BUILD_ROOT}/${RELEASE_ID}"
if [ ! -d "$STAGE" ] || [ ! -f "$STAGE/SHA256SUMS" ]; then
    log_err "未找到 staging 目录或 SHA256SUMS：$STAGE"
    exit 1
fi

log_step "Phase 9：分发 $RELEASE_ID 到 ${#VAL_ALIASES[@]} 台 validator"

for HOST in "${VAL_ALIASES[@]}"; do
    log_info "─── $HOST ───"
    REMOTE_DIR="$SETU_HOME/bin/releases/$RELEASE_ID"

    sssh "$HOST" "mkdir -p $REMOTE_DIR"

    # 分发
    log_info "[$HOST] rsync..."
    rsync -av --chmod=u=rwX,g=rX,o= \
      -e "ssh -i $MAINT_KEY $SSH_OPTS" \
      "$STAGE/" \
      "${SETU_USER}@$(resolve_host "$HOST"):$REMOTE_DIR/"

    # 远端校验
    log_info "[$HOST] sha256 校验..."
    sssh "$HOST" "cd $REMOTE_DIR && sha256sum -c SHA256SUMS"

    log_info "[$HOST] ldd 检查..."
    if sssh "$HOST" "ldd $REMOTE_DIR/setu-validator | grep -q 'not found'"; then
        log_err "[$HOST] setu-validator 缺少动态库依赖，停止"
        sssh "$HOST" "ldd $REMOTE_DIR/setu-validator | grep 'not found'"
        exit 1
    fi

    log_info "[$HOST] ELF / 二进制健全性自检（setu-validator 未实现 clap，不能用 --version）..."
    sssh "$HOST" "file $REMOTE_DIR/setu-validator | grep -q ELF && file $REMOTE_DIR/setu-solver | grep -q ELF && file $REMOTE_DIR/setu-cli | grep -q ELF"

    # 校验通过才切 symlink
    log_info "[$HOST] 切换 current symlink（ln -sfnT）..."
    sssh "$HOST" "ln -sfnT $REMOTE_DIR $SETU_HOME/bin/current && ls -l $SETU_HOME/bin/current"

    # 清理超过 5 个旧 release
    sssh "$HOST" "cd $SETU_HOME/bin/releases && ls -1t | tail -n +6 | xargs -r rm -rf"

    log_ok "[$HOST] 分发完成"
done

log_ok "Phase 9 完成：所有 validator 已切换到 $RELEASE_ID"
log_warn "提醒：当前未重启服务（如果正在运行）。重启请用 phase11 或 systemctl restart setu-validator setu-solver"
