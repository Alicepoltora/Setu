#!/usr/bin/env bash
# phase13-monitoring.sh — 在 ops/gateway 节点起监控栈（Prometheus + Loki + Grafana + json/blackbox exporter）
# 对应 runbook §23（Phase 20）+ §25（Phase 22 抓取目标）。
# Grafana dashboard / 告警规则不在脚本范围 —— 见 runbook §26。
#
# 前置：phase10 (ops Docker) 已执行；inventory.env 已配 GATEWAY_ALIAS 等。
# 用法：bash phase13-monitoring.sh

source "$(dirname "$0")/lib.sh"
log_step "Phase 13 — ops：监控栈 (docker compose)"

GATEWAY="${GATEWAY_ALIAS:-ops}"
MONITOR_DIR="${MONITOR_DIR:-/opt/monitor}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
    log_err "GRAFANA_ADMIN_PASSWORD 未设置。请 export 后再跑（避免入仓 / 入 history）。"
    log_err "示例：read -rsp 'grafana admin pw: ' GRAFANA_ADMIN_PASSWORD; export GRAFANA_ADMIN_PASSWORD"
    exit 2
fi

# ── 1. 拼 validator 抓取目标（用 inventory.env 中真实 IP） ─────────────────────
val_targets_node=""
val_targets_health=""
for alias in "${VAL_ALIASES[@]}"; do
    ip=$(resolve_host "$alias")
    val_targets_node+="          - ${ip}:9100"$'\n'
    val_targets_health+="          - http://${ip}:${HTTP_PORT}/api/v1/health"$'\n'
done
ops_ip=$(resolve_host "$GATEWAY")

# ── 2. 在 gateway 上落盘所有配置 ───────────────────────────────────────────────
log_info "[1] 创建 ${MONITOR_DIR} 目录结构"
mssh "$GATEWAY" "sudo install -d -o root -g root -m 755 \
    ${MONITOR_DIR} \
    ${MONITOR_DIR}/prometheus \
    ${MONITOR_DIR}/loki \
    ${MONITOR_DIR}/json_exporter \
    ${MONITOR_DIR}/grafana/provisioning/datasources \
    ${MONITOR_DIR}/grafana/provisioning/dashboards"

log_info "[2] 写 docker-compose.yml"
COMPOSE=$(cat <<EOF
services:
  prometheus:
    image: prom/prometheus:v2.54.1
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=30d
      - --storage.tsdb.retention.size=50GB
    volumes:
      - ./prometheus:/etc/prometheus
      - prom-data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"

  loki:
    image: grafana/loki:3.0.0
    restart: unless-stopped
    command: -config.file=/etc/loki/loki-config.yml
    volumes:
      - ./loki:/etc/loki
      - loki-data:/loki
    ports:
      - "127.0.0.1:3100:3100"

  grafana:
    image: grafana/grafana:11.1.0
    restart: unless-stopped
    env_file: ./grafana/grafana.env
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    ports:
      - "127.0.0.1:3000:3000"

  json_exporter:
    image: prometheuscommunity/json-exporter:v0.7.0
    restart: unless-stopped
    command:
      - --config.file=/config/config.yml
    volumes:
      - ./json_exporter:/config
    ports:
      - "127.0.0.1:7979:7979"

  blackbox_exporter:
    image: prom/blackbox-exporter:v0.25.0
    restart: unless-stopped
    ports:
      - "127.0.0.1:9115:9115"

volumes:
  prom-data:
  loki-data:
  grafana-data:
EOF
)
echo "$COMPOSE" | mssh "$GATEWAY" "sudo tee ${MONITOR_DIR}/docker-compose.yml >/dev/null"

log_info "[3] 写 grafana/grafana.env（仅 root 可读，含 admin password）"
mssh "$GATEWAY" "sudo tee ${MONITOR_DIR}/grafana/grafana.env >/dev/null <<EOF
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
GF_AUTH_ANONYMOUS_ENABLED=false
EOF
sudo chmod 600 ${MONITOR_DIR}/grafana/grafana.env"

log_info "[4] 写 prometheus.yml（抓 node_exporter + json_exporter + blackbox）"
PROM=$(cat <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 30s

scrape_configs:
  - job_name: node
    static_configs:
      - targets:
${val_targets_node}          - ${ops_ip}:9100

  - job_name: setu-health-json
    metrics_path: /probe
    params:
      module: [setu_health]
    static_configs:
      - targets:
${val_targets_health}    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: json_exporter:7979

  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
${val_targets_health}    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox_exporter:9115
EOF
)
echo "$PROM" | mssh "$GATEWAY" "sudo tee ${MONITOR_DIR}/prometheus/prometheus.yml >/dev/null"

log_info "[5] 写 json_exporter/config.yml（/api/v1/health → metrics）"
JSONX=$(cat <<'EOF'
modules:
  setu_health:
    metrics:
      - name: setu_solver_count
        path: "{ .solver_count }"
        help: Solver count reported by validator health endpoint
      - name: setu_validator_count
        path: "{ .validator_count }"
      - name: setu_dag_events_count
        path: "{ .dag_events_count }"
      - name: setu_uptime_seconds
        path: "{ .uptime_seconds }"
EOF
)
echo "$JSONX" | mssh "$GATEWAY" "sudo tee ${MONITOR_DIR}/json_exporter/config.yml >/dev/null"

log_info "[6] 写 loki-config.yml（filesystem + 30 天保留）"
LOKI=$(cat <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 720h

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem
EOF
)
echo "$LOKI" | mssh "$GATEWAY" "sudo tee ${MONITOR_DIR}/loki/loki-config.yml >/dev/null"

log_info "[7] 写 grafana datasource provisioning（Prometheus + Loki）"
DS=$(cat <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
EOF
)
echo "$DS" | mssh "$GATEWAY" "sudo tee ${MONITOR_DIR}/grafana/provisioning/datasources/setu.yml >/dev/null"

# ── 3. 启动 ────────────────────────────────────────────────────────────────────
log_info "[8] docker compose up -d"
mssh "$GATEWAY" "cd ${MONITOR_DIR} && sudo docker compose pull && sudo docker compose up -d"
mssh "$GATEWAY" "cd ${MONITOR_DIR} && sudo docker compose ps"

# ── 4. 自检（仅看本机回环端口）─────────────────────────────────────────────────
log_info "[9] 等待 30s 后探活"
sleep 30
fail=0
for url in \
    "http://127.0.0.1:9090/-/ready" \
    "http://127.0.0.1:3100/ready" \
    "http://127.0.0.1:3000/api/health" \
    "http://127.0.0.1:7979/probe?module=setu_health&target=http://${ops_ip}:${HTTP_PORT}/api/v1/health"
do
    if mssh "$GATEWAY" "curl -sf --max-time 5 '$url' >/dev/null"; then
        log_ok "  $url"
    else
        log_err "  $url FAIL"
        fail=1
    fi
done

[ "$fail" -eq 0 ] && log_ok "Phase 13 done — 监控栈已上线（仅绑 127.0.0.1，需 Phase 14 反代）" || exit 1
