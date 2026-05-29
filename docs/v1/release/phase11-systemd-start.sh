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

# ── 飞行前校验：二进制存在且是 ELF（setu-validator 不实现 clap，--help/--version 会被当作启动参数）
FIRST_VAL="${VAL_ALIASES[0]}"
log_info "飞行前校验：@ $FIRST_VAL 检查二进制 ELF"
if ! sssh "$FIRST_VAL" "file $SETU_HOME/bin/current/setu-validator | grep -q ELF && file $SETU_HOME/bin/current/setu-solver | grep -q ELF"; then
    log_err "二进制 ELF 自检失败，先跑 phase09"
    exit 1
fi
log_ok "飞行前校验通过"

# ── 计算每台 validator 的 PEER_VALIDATORS（去掉自身） ───────────────────────
peer_list_for() {
    local self_alias="$1"
    local self_ip; self_ip="$(resolve_host "$self_alias")"
    local peers=""
    local h ip
    for h in "${VAL_ALIASES[@]}"; do
        ip="$(resolve_host "$h")"
        [ "$ip" = "$self_ip" ] && continue
        if [ -n "$peers" ]; then peers="${peers},${ip}:${P2P_PORT}"
        else peers="${ip}:${P2P_PORT}"
        fi
    done
    echo "$peers"
}

# ── 写 unit ────────────────────────────────────────────────────────────────
idx=1
for HOST in "${VAL_ALIASES[@]}"; do
    HOST_IP="$(resolve_host "$HOST")"
    NODE_ID="validator-${idx}"
    PEERS="$(peer_list_for "$HOST")"
    CALLBACK_ADDR="${HOST_IP}:${HTTP_PORT}"

    log_info "[$HOST] 写 systemd unit (NODE_ID=$NODE_ID, peers=$PEERS)..."
    mssh "$HOST" "NODE_ID='$NODE_ID' HOST_IP='$HOST_IP' PEERS='$PEERS' CALLBACK_ADDR='$CALLBACK_ADDR' HTTP_PORT=$HTTP_PORT P2P_PORT=$P2P_PORT SOLVER_PORT=$SOLVER_PORT SETU_HOME=$SETU_HOME bash -s" <<'REMOTE'
set -euo pipefail

ts=$(date -u +%Y%m%dT%H%M%SZ)
for u in setu-validator.service setu-solver.service; do
    [ -f "/etc/systemd/system/$u" ] && sudo cp -a "/etc/systemd/system/$u" "/etc/systemd/system/${u}.bak.${ts}" || true
done

sudo tee /etc/systemd/system/setu-validator.service >/dev/null <<EOF
[Unit]
Description=Setu Validator
After=network-online.target chrony.service
Wants=network-online.target

[Service]
User=setu
Group=setu
WorkingDirectory=${SETU_HOME}
# 兜底 RUST_LOG；phase10 渲染的 /opt/setu/conf/env 可覆盖 + 注入 SETU_RAW_TRANSFER_API_TOKEN
Environment=RUST_LOG=info
# 运行时配置（setu-validator 全部走环境变量，无 CLI flag）
Environment=NODE_ID=${NODE_ID}
Environment=GENESIS_FILE=${SETU_HOME}/conf/genesis.json
# 必须指向 phase10 派生的 base64 sidecar；JSON 文件喂给 setu_keys::load_keypair 会
# 触发 "Invalid byte 123, offset 0"，validator 静默降级、strict 模式丢光所有 CF 票
Environment=VALIDATOR_KEY_FILE=${SETU_HOME}/keys/validator.key
Environment=VALIDATOR_DB_PATH=${SETU_HOME}/data/db
Environment=VALIDATOR_LISTEN_ADDR=0.0.0.0
Environment=VALIDATOR_HTTP_PORT=${HTTP_PORT}
Environment=VALIDATOR_P2P_PORT=${P2P_PORT}
Environment=VALIDATOR_CALLBACK_ADDR=${CALLBACK_ADDR}
Environment=PEER_VALIDATORS=${PEERS}
EnvironmentFile=-/opt/setu/conf/env
ExecStart=${SETU_HOME}/bin/current/setu-validator
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
# setu-solver 全部走环境变量
Environment=SOLVER_ID=solver-${NODE_ID##*-}
Environment=SOLVER_LISTEN_ADDR=127.0.0.1
Environment=SOLVER_PORT=${SOLVER_PORT}
Environment=SOLVER_CAPACITY=100
Environment=VALIDATOR_ADDRESS=127.0.0.1
Environment=VALIDATOR_HTTP_PORT=${HTTP_PORT}
Environment=AUTO_REGISTER=true
Environment=HEARTBEAT_INTERVAL=30
EnvironmentFile=-/opt/setu/conf/env
ExecStart=${SETU_HOME}/bin/current/setu-solver
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

# 确保 data/logs 目录存在且属主 setu
sudo install -d -o setu -g setu -m 750 ${SETU_HOME}/data ${SETU_HOME}/logs

sudo systemctl daemon-reload
sudo systemctl enable setu-validator setu-solver >/dev/null
REMOTE
    log_ok "[$HOST] systemd unit 已落盘"
    idx=$((idx + 1))
done

# ── 全部启动 validator（不串行 wait，因为 peer 连接阻塞 HTTP 启动）──────────
# main.rs 在起 HTTP 前会串行重试 5 次连接每个 peer（每次最长 ~30s），
# 串行 + per-host wait 会形成循环依赖（val-1 等 val-2 起来，val-2 还没启）。
for HOST in "${VAL_ALIASES[@]}"; do
    log_info "[$HOST] systemctl $ACTION setu-validator..."
    mssh "$HOST" "sudo systemctl $ACTION setu-validator"
done

# ── 统一等待 health=healthy（每节点最长 180s） ────────────────────────────
for HOST in "${VAL_ALIASES[@]}"; do
    IP=$(resolve_host "$HOST")
    log_info "[$HOST] 等待 health=healthy..."
    ok=0
    for i in $(seq 1 90); do
        if curl -sf --max-time 3 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -e '.status == "healthy"' >/dev/null 2>&1; then
            ok=1; break
        fi
        sleep 2
    done

    if [ "$ok" -ne 1 ]; then
        log_err "[$HOST] 180s 内未达到 health=healthy"
        mssh "$HOST" "sudo journalctl -u setu-validator -n 80 --no-pager" || true
        exit 1
    fi
    log_ok "[$HOST] validator health=healthy"
done

# ── 启动 solver ─────────────────────────────────────────────────────────────
for HOST in "${VAL_ALIASES[@]}"; do
    log_info "[$HOST] systemctl $ACTION setu-solver..."
    mssh "$HOST" "sudo systemctl $ACTION setu-solver"
done

sleep 5
for HOST in "${VAL_ALIASES[@]}"; do
    IP=$(resolve_host "$HOST")
    summary=$(curl -sf --max-time 3 "http://${IP}:${HTTP_PORT}/api/v1/health" | jq -c '{s:.status, v:.validator_count, sv:.solver_count, dag:.dag_events_count}')
    log_info "[$HOST] $summary"
done

log_ok "Phase 11 完成"
