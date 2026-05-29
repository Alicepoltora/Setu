#!/usr/bin/env bash
# rollback.sh — 把单台 validator 回退到指定 release_id
# 用法：bash rollback.sh <host-alias> <release_id>
# 示例：bash rollback.sh val-1 20260530-103000-abc1234
source "$(dirname "$0")/lib.sh"
require_args 2 $# "rollback.sh <host-alias> <release_id>"
HOST="$1"
RELEASE_ID="$2"

log_step "回滚 $HOST → $RELEASE_ID"

# ── BFT 护栏：必须保证其它 validator 都在 health=ok 后才能动本台 ────────────────
log_info "检查其它 validator 是否 health=ok…"
UNHEALTHY=()
for peer in "${VAL_ALIASES[@]}"; do
    [ "$peer" = "$HOST" ] && continue
    peer_ip=$(resolve_host "$peer")
    if curl -sf --max-time 5 "http://${peer_ip}:${HTTP_PORT}/api/v1/health" \
         | jq -e '.status == "ok"' >/dev/null 2>&1; then
        log_ok "  $peer ok"
    else
        UNHEALTHY+=("$peer")
    fi
done
if [ "${#UNHEALTHY[@]}" -gt 0 ]; then
    log_err "其它 validator 不健康：${UNHEALTHY[*]}"
    log_err "现在回滚 $HOST 会同时带走 ≥2 台，超过 BFT 容错阈值。中止。"
    log_err "如确需强制回滚，请手动下令（并承担中断出块的后果）。"
    exit 1
fi

# 校验 release 存在
if ! sssh "$HOST" "test -d $SETU_HOME/bin/releases/$RELEASE_ID"; then
    log_err "[$HOST] 未找到 release：$SETU_HOME/bin/releases/$RELEASE_ID"
    log_info "可用 release："
    sssh "$HOST" "ls -1t $SETU_HOME/bin/releases | head -10"
    exit 1
fi

# 校验 sha256 / 可执行
log_info "校验 sha256..."
sssh "$HOST" "cd $SETU_HOME/bin/releases/$RELEASE_ID && sha256sum -c SHA256SUMS"
sssh "$HOST" "$SETU_HOME/bin/releases/$RELEASE_ID/setu-validator --version"

# 切 symlink
log_info "切换 current symlink..."
sssh "$HOST" "ln -sfnT $SETU_HOME/bin/releases/$RELEASE_ID $SETU_HOME/bin/current && ls -l $SETU_HOME/bin/current"

# 重启服务
log_info "重启 setu-validator + setu-solver..."
mssh "$HOST" "sudo systemctl restart setu-validator setu-solver"

# 等 health=ok
IP=$(resolve_host "$HOST")
log_info "等待 health=ok..."
ok=0
for i in {1..30}; do
    if curl -sf --max-time 3 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        ok=1; break
    fi
    sleep 2
done

if [ "$ok" -eq 1 ]; then
    log_ok "[$HOST] 回滚完成，health=ok"
else
    log_err "[$HOST] 60s 内未恢复 health=ok"
    mssh "$HOST" "sudo journalctl -u setu-validator -n 50 --no-pager" || true
    exit 1
fi

# ── 活性校验：dag_events_count 需在 30s 内增长，避免“health=ok 但卡块” ────────
log_info "采样 dag_events_count 增长（60s 窗口）..."
base=$(curl -sf --max-time 5 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -r '.dag_events_count // 0')
sleep 60
curr=$(curl -sf --max-time 5 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -r '.dag_events_count // 0')
if [ "$curr" -gt "$base" ]; then
    log_ok "[$HOST] dag_events_count 增长 $base → $curr，回滚后节点参与出块"
else
    log_err "[$HOST] dag_events_count 未增长（$base），节点 health=ok 但可能未参与共识"
    log_err "请检查 journalctl -u setu-validator 与其他 peer 连接状态后再评估是否需手动下一步"
    exit 1
fi
