#!/usr/bin/env bash
# Phase 11 — ops → 所有 validator：systemd unit + 串行启动 + health 校验
# 用法：bash phase11-systemd-start.sh [--restart]
#   --restart  对已启动的节点执行 restart 而非 start（用于升级 binary 后）
source "$(dirname "$0")/lib.sh"

ACTION=start
if [ "${1:-}" = "--restart" ]; then
    ACTION=restart
fi

log_step "Phase 11：systemd unit 部署 + 串行启动（action=${ACTION}）"

# ── 飞行前校验：ExecStart 使用的 flag 是否真实存在 ──────────────────────────
FIRST_VAL="${VAL_ALIASES[0]}"
log_info "飞行前校验：@ $FIRST_VAL 运行 setu-validator --help 检查 flag"
help_out=$(mssh "$FIRST_VAL" "$SETU_HOME/bin/current/setu-validator --help 2>&1" || true)
if [ -z "$help_out" ]; then
    log_err "无法获取 setu-validator --help 输出，检查二进制是否已由 phase09 分发"
    exit 1
fi
MISSING=()
for f in --genesis --key --data-dir --http-listen --p2p-listen; do
    echo "$help_out" | grep -q -- "$f" || MISSING+=("$f")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    log_err "setu-validator --help 中未出现以下 flag，本脚本与二进制不匹配：${MISSING[*]}"
    log_err "请对比 setu-validator --help 输出修正 ExecStart"
    echo "---- setu-validator --help 输出前 60 行 ----"
    echo "$help_out" | head -60
    exit 1
fi
log_ok "飞行前校验通过：ExecStart 中的 flag 都存在"

# ── 写 unit ────────────────────────────────────────────────────────────────
for HOST in "${VAL_ALIASES[@]}"; do
    log_info "[$HOST] 写 systemd unit..."
    mssh "$HOST" "HTTP_PORT=$HTTP_PORT P2P_PORT=$P2P_PORT SOLVER_PORT=$SOLVER_PORT SETU_HOME=$SETU_HOME bash -s" <<'REMOTE'
set -euo pipefail

sudo tee /etc/systemd/system/setu-validator.service >/dev/null <<EOF
[Unit]
Description=Setu Validator
After=network-online.target chrony.service
Wants=network-online.target

[Service]
User=setu
Group=setu
WorkingDirectory=${SETU_HOME}
# RUST_LOG 兑底；phase10 渲染的 /opt/setu/conf/env 可覆盖为 V1 ACCEPT 推荐值
# 同时加载 SETU_RAW_TRANSFER_API_TOKEN（文件不存在不报错）
Environment=RUST_LOG=info
EnvironmentFile=-/opt/setu/conf/env
ExecStart=${SETU_HOME}/bin/current/setu-validator \\
  --genesis ${SETU_HOME}/conf/genesis.json \\
  --key ${SETU_HOME}/keys/validator.json \\
  --data-dir ${SETU_HOME}/data \\
  --http-listen 0.0.0.0:${HTTP_PORT} \\
  --p2p-listen 0.0.0.0:${P2P_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:${SETU_HOME}/logs/validator.log
StandardError=append:${SETU_HOME}/logs/validator.log

# 安全沙箱
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${SETU_HOME}/data ${SETU_HOME}/logs
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/setu-solver.service >/dev/null <<EOF
[Unit]
Description=Setu Solver
After=setu-validator.service
Requires=setu-validator.service

[Service]
User=setu
Group=setu
WorkingDirectory=${SETU_HOME}
Environment=RUST_LOG=info
EnvironmentFile=-/opt/setu/conf/env
ExecStart=${SETU_HOME}/bin/current/setu-solver \\
  --validator-url http://127.0.0.1:${HTTP_PORT} \\
  --listen 127.0.0.1:${SOLVER_PORT}
Restart=on-failure
RestartSec=5
StandardOutput=append:${SETU_HOME}/logs/solver.log
StandardError=append:${SETU_HOME}/logs/solver.log

# 安全沙箱
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${SETU_HOME}/data ${SETU_HOME}/logs
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable setu-validator setu-solver >/dev/null
REMOTE
    log_ok "[$HOST] systemd unit 已落盘"
done

# ── 串行启动 validator ─────────────────────────────────────────────────────
for HOST in "${VAL_ALIASES[@]}"; do
    IP=$(resolve_host "$HOST")
    log_info "[$HOST] systemctl $ACTION setu-validator..."
    mssh "$HOST" "sudo systemctl $ACTION setu-validator"

    log_info "[$HOST] 等待 health=ok..."
    ok=0
    for i in {1..30}; do
        if curl -sf --max-time 3 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -e '.status == "ok"' >/dev/null 2>&1; then
            ok=1; break
        fi
        sleep 2
    done

    if [ "$ok" -ne 1 ]; then
        log_err "[$HOST] 60s 内未达到 health=ok，停止后续启动"
        mssh "$HOST" "sudo journalctl -u setu-validator -n 50 --no-pager" || true
        exit 1
    fi
    log_ok "[$HOST] validator health=ok"
done

# ── 启动 solver ─────────────────────────────────────────────────────────────
for HOST in "${VAL_ALIASES[@]}"; do
    log_info "[$HOST] systemctl $ACTION setu-solver..."
    mssh "$HOST" "sudo systemctl $ACTION setu-solver"
done

sleep 5
for HOST in "${VAL_ALIASES[@]}"; do
    IP=$(resolve_host "$HOST")
    summary=$(curl -sf --max-time 3 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -c '{s:.status, v:.validator_count, sv:.solver_count}')
    log_info "[$HOST] $summary"
done

log_ok "Phase 11 完成"
