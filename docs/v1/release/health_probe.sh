#!/usr/bin/env bash
# health_probe.sh — cron 每分钟调用，将 3 节点 /api/v1/health 简要记录到日志
# 部署位置：/opt/setu-deploy/scripts/health_probe.sh
# 日志：/var/log/setu-health.log（按需配合 logrotate 轮转）
#
# 注意：本脚本独立运行（不 source lib.sh），节点 IP 硬编码或从环境变量读取
# 若 IP 变更，请同步修改 HOSTS 数组

set -euo pipefail

# ── 配置源 ─────────────────────────────────────────────
# 优先读 /etc/setu-deploy/hosts.env（phase12 会从 inventory.env 渲染）
# 復原为环境变量 SETU_HEALTH_HOSTS，最后 fallback 到默认
CONF=/etc/setu-deploy/hosts.env
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

if [ -n "${SETU_HEALTH_HOSTS:-}" ]; then
    # 格式："val-1:1.2.3.4 val-2:5.6.7.8 ..."
    read -r -a HOSTS <<<"$SETU_HEALTH_HOSTS"
else
    # 无 fallback：不手写旧 IP，避免 hosts.env 丢失后静默探错 IP
    echo "[health_probe] FATAL: $CONF 缺失且未设置 SETU_HEALTH_HOSTS" >&2
    echo "[health_probe] 请重跑 phase12-verify.sh 重新渲染 $CONF" >&2
    exit 1
fi
HTTP_PORT="${HTTP_PORT:-8080}"
LOG="${SETU_HEALTH_LOG:-/var/log/setu-health.log}"

# Gateway 联通探测（使用入口 URL；phase12 会从 inventory 渲染 GATEWAY_HEALTH_URL）
GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-}"

# TLS 证书到期探测（仅在配了 GATEWAY_DOMAIN 时生效）
GATEWAY_DOMAIN="${GATEWAY_DOMAIN:-}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"

# ── 探测 ────────────────────────────────────────────────────────────────────
ts=$(date -u +%FT%TZ)
for entry in "${HOSTS[@]}"; do
    name="${entry%%:*}"
    ip="${entry##*:}"
    resp=$(curl -sf --max-time 5 "http://${ip}:${HTTP_PORT}/api/v1/health" 2>/dev/null || echo "")
    if [ -z "$resp" ]; then
        echo "$ts DOWN $name $ip" >> "$LOG"
        continue
    fi
    # 提取关键字段
    summary=$(echo "$resp" | jq -c '{s:.status, v:.validator_count, sv:.solver_count, e:.dag_events_count, up:.uptime_seconds}' 2>/dev/null || echo '{"parse":"err"}')
    echo "$ts $name $summary" >> "$LOG"
done

# ── Gateway 入口探测 ────────────────────────────────────────────
if [ -n "$GATEWAY_HEALTH_URL" ]; then
    gw_resp=$(curl -sfk --max-time 5 "$GATEWAY_HEALTH_URL" 2>/dev/null || echo "")
    if [ -z "$gw_resp" ]; then
        echo "$ts GATEWAY-DOWN $GATEWAY_HEALTH_URL" >> "$LOG"
    else
        gw_sum=$(echo "$gw_resp" | jq -c '{s:.status, v:.validator_count}' 2>/dev/null || echo '{"parse":"err"}')
        echo "$ts gateway $gw_sum" >> "$LOG"
    fi
fi

# ── TLS 证书到期探测（Let's Encrypt 90 天、默认余 14 天告警）──────────────────
if [ -n "$GATEWAY_DOMAIN" ] && command -v openssl >/dev/null; then
    expiry=$(echo | openssl s_client -servername "$GATEWAY_DOMAIN" \
                -connect "${GATEWAY_DOMAIN}:443" 2>/dev/null \
                | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry" ]; then
        expiry_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        if [ "$expiry_ts" -gt 0 ]; then
            days_left=$(( (expiry_ts - $(date +%s)) / 86400 ))
            if [ "$days_left" -lt "$CERT_WARN_DAYS" ]; then
                echo "$ts CERT-EXPIRING $GATEWAY_DOMAIN ${days_left}d" >> "$LOG"
            fi
        fi
    else
        echo "$ts CERT-PROBE-FAIL $GATEWAY_DOMAIN" >> "$LOG"
    fi
fi
