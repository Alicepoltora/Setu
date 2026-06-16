#!/usr/bin/env bash
# 公共函数库，所有 phaseNN.sh 通过 `source lib.sh` 引入
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 加载 inventory ──────────────────────────────────────────────────────────
if [ ! -f "${_SCRIPT_DIR}/inventory.env" ]; then
    echo "ERROR: ${_SCRIPT_DIR}/inventory.env 不存在。请 cp inventory.env.example inventory.env 并填值。" >&2
    exit 2
fi
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/inventory.env"

# ── 颜色输出 ────────────────────────────────────────────────────────────────
_color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
log_info() { echo "$(_color '1;34' '[INFO]') $*"; }
log_ok()   { echo "$(_color '1;32' '[ OK ]') $*"; }
log_warn() { echo "$(_color '1;33' '[WARN]') $*"; }
log_err()  { echo "$(_color '1;31' '[ERR ]') $*" >&2; }
log_step() { echo; echo "$(_color '1;36' '===')" "$*" "$(_color '1;36' '===')"; }

# ── 主机别名解析 ────────────────────────────────────────────────────────────
resolve_host() {
    local alias="$1"
    if [ -z "${HOSTS[$alias]:-}" ]; then
        log_err "未知主机别名：$alias（在 inventory.env 的 HOSTS 中定义）"
        exit 2
    fi
    echo "${HOSTS[$alias]}"
}

# 维护用户 SSH（用于 Phase 1-4 配置阶段）
mssh() {
    local alias="$1"; shift
    local ip; ip=$(resolve_host "$alias")
    # shellcheck disable=SC2086
    ssh -i "$MAINT_KEY" $SSH_OPTS "${MAINT_USER}@${ip}" "$@"
}

# setu 用户 SSH（用于 Phase 5+ 服务管理）
sssh() {
    local alias="$1"; shift
    local ip; ip=$(resolve_host "$alias")
    # shellcheck disable=SC2086
    ssh -i "$MAINT_KEY" $SSH_OPTS "${SETU_USER}@${ip}" "$@"
}

# 维护用户 rsync
mrsync() {
    local alias="$1"; shift
    local src="$1"; shift
    local dst="$1"; shift
    local ip; ip=$(resolve_host "$alias")
    rsync -av -e "ssh -i $MAINT_KEY $SSH_OPTS" "$src" "${MAINT_USER}@${ip}:${dst}" "$@"
}

# setu 用户 rsync
srsync() {
    local alias="$1"; shift
    local src="$1"; shift
    local dst="$1"; shift
    local ip; ip=$(resolve_host "$alias")
    rsync -av -e "ssh -i $MAINT_KEY $SSH_OPTS" "$src" "${SETU_USER}@${ip}:${dst}" "$@"
}

# 期望参数数量校验
require_args() {
    local need="$1"; shift
    local got="$1"; shift
    local usage="$1"
    if [ "$got" -lt "$need" ]; then
        log_err "用法：$usage"
        exit 2
    fi
}

# 人工确认
confirm() {
    local prompt="${1:-继续？}"
    read -r -p "$(_color '1;33' "$prompt [y/N]: ")" reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) log_warn "已中止"; exit 1 ;;
    esac
}
