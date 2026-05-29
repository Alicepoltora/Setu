#!/usr/bin/env bash
# Phase 4b @ gateway (默认复用 ops) — 安装 nginx + 限流 + 可选 TLS
# Anti-spam 方案阶段 1：把公网入口收口到 gateway，并施加 per-IP 限流
#
# 用法：bash phase04b-gateway.sh
#
# 前置：phase04 已在 gateway 节点完成（UFW 已 enable 且放行 80/443）
# 产物：/etc/nginx/conf.d/setu.conf，公网 https://${GATEWAY_DOMAIN}/api/v1/* 反代到 3 台 validator
source "$(dirname "$0")/lib.sh"
log_step "Phase 4b @ ${GATEWAY_ALIAS:-ops}：nginx 网关 + 限流"

GW="${GATEWAY_ALIAS:-ops}"
GW_IP=$(resolve_host "$GW")
[ -n "$GW_IP" ] && [[ "$GW_IP" != REPLACE-* ]] || { log_err "GATEWAY_ALIAS=$GW 未在 HOSTS 中配置"; exit 1; }

# 收集 validator upstream
UPSTREAM_LINES=""
for alias in "${VAL_ALIASES[@]}"; do
    ip=$(resolve_host "$alias")
    UPSTREAM_LINES+="    server ${ip}:${HTTP_PORT} max_fails=3 fail_timeout=10s;"$'\n'
done

# TLS 模式判定
USE_TLS=0
if [ -n "${GATEWAY_DOMAIN:-}" ] && [[ "$GATEWAY_DOMAIN" != REPLACE-* ]]; then
    USE_TLS=1
    log_info "TLS 模式：domain=$GATEWAY_DOMAIN"
else
    log_warn "未配置 GATEWAY_DOMAIN，使用纯 HTTP（仅适合内部测试）"
fi

# ── 1. 装 nginx（+ certbot）─────────────────────────────────────────────────
log_info "[1] 安装 nginx"
mssh "$GW" "sudo apt-get update -qq && sudo apt-get install -y nginx" >/dev/null

if [ "$USE_TLS" = "1" ]; then
    mssh "$GW" "sudo apt-get install -y certbot python3-certbot-nginx" >/dev/null
fi

# ── 2. 渲染 nginx 配置 ─────────────────────────────────────────────────────
log_info "[2] 生成 /etc/nginx/conf.d/setu.conf"

if [ "$USE_TLS" = "1" ]; then
    SERVER_NAME="$GATEWAY_DOMAIN"
    LISTEN_LINE="listen ${GATEWAY_HTTPS_PORT:-443} ssl http2;"
    # 证书路径待 certbot 写入；先用占位，certbot --nginx 会自动接管
    TLS_LINES=$(cat <<EOT
    ssl_certificate     /etc/letsencrypt/live/${GATEWAY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${GATEWAY_DOMAIN}/privkey.pem;
EOT
)
    REDIRECT_BLOCK="server { listen 80; server_name ${GATEWAY_DOMAIN}; return 301 https://\$host\$request_uri; }"
else
    SERVER_NAME="_"
    LISTEN_LINE="listen 80;"
    TLS_LINES=""
    REDIRECT_BLOCK=""
fi

NGINX_CONF=$(cat <<EOF
# Setu testnet gateway — anti-spam phase 1
limit_req_zone  \$binary_remote_addr zone=setu_write:10m rate=${GATEWAY_RATE_WRITE:-5r/s};
limit_req_zone  \$binary_remote_addr zone=setu_read:10m  rate=${GATEWAY_RATE_READ:-50r/s};
limit_conn_zone \$binary_remote_addr zone=setu_conn:10m;

# 访问日志格式：记 IP + 耗时 + 限流状态 + request_id，便于与 validator 端日志关联
log_format setu_main '\$remote_addr - \$remote_user [\$time_iso8601] '
                    '"\$request" \$status \$body_bytes_sent '
                    'rt=\$request_time uct=\$upstream_connect_time urt=\$upstream_response_time '
                    'limit_req=\$limit_req_status limit_conn=\$limit_conn_status '
                    'req_id=\$request_id ua="\$http_user_agent"';

upstream setu_validators {
${UPSTREAM_LINES}    keepalive 32;
}

${REDIRECT_BLOCK}

server {
    ${LISTEN_LINE}
    server_name ${SERVER_NAME};

${TLS_LINES}

    access_log /var/log/nginx/setu-access.log setu_main;
    error_log  /var/log/nginx/setu-error.log warn;

    client_max_body_size 1m;
    client_body_timeout  10s;
    send_timeout         10s;
    proxy_read_timeout   30s;
    limit_conn setu_conn ${GATEWAY_MAX_CONN:-20};

    # 写接口（限流严格）—— 枚举真实写路由，避免前缀误匹配。
    # 与 setu-validator/src/network/service.rs::start_http_server() 保持一致。
    # 读但用 POST 的（不收取）：transfer/status、user/{account,balance,power,flux,credentials}、
    # user/profile/:addr、events GET —— 不走这里，落到下面读道。
    location ~ ^/api/v1/(register/(solver|validator|subnet)|transfer\$|transfers/batch|event\$|heartbeat|user/(register|transfer|profile\$|subnet/(join|leave))|governance/(propose|callback|register-system-subnet)|move/(call|publish|upgrade|ptb)) {
        limit_req zone=setu_write burst=${GATEWAY_BURST_WRITE:-10} nodelay;
        proxy_pass http://setu_validators;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Request-Id \$request_id;
    }

    # 读接口
    location /api/v1/ {
        limit_req zone=setu_read burst=${GATEWAY_BURST_READ:-100} nodelay;
        proxy_pass http://setu_validators;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Request-Id \$request_id;
    }

    location = /api/v1/health { proxy_pass http://setu_validators; }
    location / { return 404; }
}
EOF
)

# 写到远端
echo "$NGINX_CONF" | mssh "$GW" "sudo tee /etc/nginx/conf.d/setu.conf >/dev/null"
mssh "$GW" "sudo rm -f /etc/nginx/sites-enabled/default"

# ── 2b. logrotate： setu-access.log / setu-error.log 保留 30 天 ─────────────────
log_info "[2b] 下发 logrotate 片段…"
mssh "$GW" "sudo tee /etc/logrotate.d/setu-nginx >/dev/null" <<'REMOTE'
/var/log/nginx/setu-access.log /var/log/nginx/setu-error.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid)
    endscript
}
REMOTE

# ── 3. 语法检查 + reload ───────────────────────────────────────────────────
log_info "[3] nginx -t"
if ! mssh "$GW" "sudo nginx -t" 2>&1 | tee /tmp/nginx-t.log | grep -q "syntax is ok"; then
    log_err "nginx 配置语法错误，未 reload。日志在 /tmp/nginx-t.log"
    cat /tmp/nginx-t.log
    exit 1
fi
mssh "$GW" "sudo systemctl enable --now nginx && sudo systemctl reload nginx"
log_ok "nginx 已启动"

# ── 4. TLS 签发（可选）─────────────────────────────────────────────────────
if [ "$USE_TLS" = "1" ]; then
    log_info "[4] certbot 签发 TLS（需 ${GATEWAY_DOMAIN} 已解析到 ${GW_IP}）"
    if [ -z "${GATEWAY_TLS_EMAIL:-}" ] || [[ "$GATEWAY_TLS_EMAIL" == REPLACE-* ]]; then
        log_warn "GATEWAY_TLS_EMAIL 未配置，跳过 certbot；请稍后手工执行："
        echo "  ssh ${MAINT_USER}@${GW_IP} 'sudo certbot --nginx -d ${GATEWAY_DOMAIN}'"
    else
        mssh "$GW" "sudo certbot --nginx -d ${GATEWAY_DOMAIN} \
            --non-interactive --agree-tos -m ${GATEWAY_TLS_EMAIL} --redirect" \
            || log_warn "certbot 失败：请检查 DNS 解析 / 80 端口可达；可稍后手工重试"
    fi
fi

# ── 5. 自检 ─────────────────────────────────────────────────────────────────
log_info "[5] 自检"
if [ "$USE_TLS" = "1" ]; then
    URL="https://${GATEWAY_DOMAIN}/api/v1/health"
else
    URL="http://${GW_IP}/api/v1/health"
fi
log_info "  GET $URL"
if curl -fsS --max-time 10 "$URL" >/dev/null 2>&1; then
    log_ok "  网关 → validator health OK"
else
    log_warn "  health 请求失败。这是预期的：phase11 还未启动 validator。"
    log_warn "  phase11 成功后重跑： curl -fsS '$URL'"
fi

# 外网扫描提示
log_warn "请在本机或其它外网机器执行以下命令，应当全部 timeout/拒绝："
for alias in "${VAL_ALIASES[@]}"; do
    vip=$(resolve_host "$alias")
    echo "    curl -v --connect-timeout 5 http://${vip}:${HTTP_PORT}/api/v1/health"
done

log_ok "Phase 4b 完成"
log_info "公网入口：$URL"
log_info "限流：写 ${GATEWAY_RATE_WRITE:-5r/s} burst=${GATEWAY_BURST_WRITE:-10}，读 ${GATEWAY_RATE_READ:-50r/s} burst=${GATEWAY_BURST_READ:-100}"
log_info "访问日志：${GW}:/var/log/nginx/setu-access.log（含 IP / 耗时 / 限流状态 / request_id）"
log_warn "⚠️  若将来在本 gateway 前面加上 CDN/Cloudflare/CF Tunnel，\$remote_addr 会变成 CDN 回源 IP，"
log_warn "   per-IP 限流完全失效。必须同时补上以下 nginx 配置（本脚本未启用）："
log_warn "     set_real_ip_from <CDN-IP-CIDR>;  real_ip_header X-Forwarded-For;  real_ip_recursive on;"
