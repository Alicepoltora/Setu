# Setu Testnet 服务器安装手册（最小可用版）

> 日期：2026-05-29
> 适用阶段：V1 测试网首次落地、单人运维
> 配套文档：完整版见 [testnet-server-install-runbook-20260529.md](testnet-server-install-runbook-20260529.md)
> 目标：**半天内**把 3 validator + 1 ops 跑起来，且具备最低限度的可观测/可回滚能力
> 升级路径：当出现"外部用户在用 / 宕机会被催 / 需要告警叫醒"任一条件时，按完整版升级

---

## 0. 与完整版的差异（一次说清）

| 维度 | 完整版 | 本最小版 |
|---|---|---|
| 监控栈 | Prometheus+Grafana+Loki+json/blackbox+nginx+TLS | 1 个 shell `health_probe.sh` + cron + tail log |
| 日志聚合 | Loki + Promtail | `ssh + tail -f` |
| 备份 | 每周 RocksDB rsync | **暂不做**（V1 数据可重 genesis） |
| systemd 沙箱 | 启用 NoNewPrivileges/ProtectSystem 等 | **不启用**（方便调试） |
| journald 限额 | 启用 | **暂不做**（磁盘满了再加） |
| Docker | ops 装 | **不装** |
| nginx/TLS | 反代 Grafana | **不装**（无 Grafana） |
| node_exporter/promtail | validator + ops 全装 | **不装** |
| Phase 数 | 26 | 12 |

**未做的事不会阻塞 V1 测试网运行**，全部放在 §13 演进清单。

---

## 1. 硬件与拓扑

| 角色 | 数量 | 规格 |
|---|---|---|
| validator+solver | 3 | 16C / 32G / 500G NVMe |
| ops/builder | 1 | 16C / 32G / 1T SSD |

主机名 / IP：

```
testnet-val-1  173.212.239.161
testnet-val-2  5.189.163.210
testnet-val-3  5.189.136.19
testnet-ops    <ops-ip>
```

端口：

| 端口 | 用途 | 暴露 |
|---|---|---|
| 22 | SSH | 维护 IP 白名单 |
| 8080 | HTTP API | 仅 gateway IP（公网入口由 gateway 443 反代） |
| 9000 TCP+UDP | P2P (Anemo QUIC) | validator 互通 + ops |
| 9001 | solver | 本机回环 |

OS：Ubuntu 24.04 LTS（22.04 兼容）x86_64

---

## 2. 操作原则（精简版）

1. **逐台串行**：涉及 SSH/UFW/sshd 的 Phase 一台做完再下一台
2. **改 sshd 前**双终端验证 key 登录
3. **Setu 节点不装** Rust / Docker / 编译器
4. **不并行**任何升级/重启操作

---

## 3. Phase 1 — 所有节点：基础工具 + inventory

### 3.1 在 ops 上准备 inventory

`~/setu-inventory.env`（不入仓库）：

```bash
VAL_HOSTS=(testnet-val-1 testnet-val-2 testnet-val-3)
VAL_IPS=(173.212.239.161 5.189.163.210 5.189.136.19)
OPS_IP=<ops-ip>
MAINT_IPS=(<MAINT_IP>)

HTTP_PORT=8080
P2P_PORT=9000
SOLVER_PORT=9001

SETU_HOME=/opt/setu
CARGO_FEATURES=diag-root-drift
```

### 3.2 4 台节点安装基础工具

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl wget gnupg \
  jq rsync unzip git \
  htop lsof ufw logrotate
```

ops 额外装：

```bash
sudo apt-get install -y vim tmux
```

---

## 4. Phase 2 — 所有节点：chrony 时间同步

```bash
sudo systemctl disable --now systemd-timesyncd
sudo apt-get install -y chrony
sudo systemctl enable --now chrony
sleep 5
chronyc tracking | grep -E 'Leap status|System time'
```

**通过标准**：`Leap status: Normal`，偏差 < 100 ms。

---

## 5. Phase 3 — 所有节点：用户 + 目录

```bash
sudo groupadd --system setu 2>/dev/null || true
sudo useradd --system --gid setu --home-dir /opt/setu \
  --shell /usr/sbin/nologin setu 2>/dev/null || true

sudo install -d -o setu -g setu -m 750 /opt/setu
sudo install -d -o setu -g setu -m 750 /opt/setu/bin
sudo install -d -o setu -g setu -m 750 /opt/setu/bin/releases
# 注意：不要 mkdir /opt/setu/bin/current，由 ln -sfnT 创建
sudo install -d -o setu -g setu -m 750 /opt/setu/data
sudo install -d -o setu -g setu -m 750 /opt/setu/logs
sudo install -d -o setu -g setu -m 750 /opt/setu/conf
sudo install -d -o setu -g setu -m 700 /opt/setu/keys
```

调试时切换：`sudo -u setu -s /bin/bash`

---

## 6. Phase 4 — 所有节点：SSH key + UFW + 关密码（**逐台串行**）

**严格顺序**：key 推 → key 验证 → UFW 加规则 → UFW enable → 改 sshd → 第二终端验证 → 关旧终端。

对每台节点 N：

### 6.1 推 key

```bash
ssh-copy-id -i ~/.ssh/setu_maint.pub maint@<N>
ssh -i ~/.ssh/setu_maint maint@<N> "echo key-login-ok"   # 必须 ok
```

### 6.2 UFW（必须先允许 SSH 再 enable）

在 N 上：

```bash
for ip in "${MAINT_IPS[@]}"; do
  sudo ufw allow from "$ip" to any port 22 proto tcp
done

# validator 节点：
for ip in "${VAL_IPS[@]}" "$OPS_IP"; do
  sudo ufw allow from "$ip" to any port 9000 proto tcp
  sudo ufw allow from "$ip" to any port 9000 proto udp
done
# HTTP 8080 仅放行 gateway IP（默认 OPS_IP），公网入口由 gateway 443 反代 —— 参见 §6b
sudo ufw allow from "$OPS_IP" to any port 8080 proto tcp
for ip in "${MAINT_IPS[@]}"; do
  sudo ufw allow from "$ip" to any port 8080 proto tcp   # 调试口
done

# gateway/ops 节点：开 443 + 80（certbot）
# sudo ufw allow 443/tcp
# sudo ufw allow 80/tcp

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
```

### 6.3 关密码登录

```bash
# Ubuntu 22/24 用 drop-in 配置，避免被 /etc/ssh/sshd_config.d/50-cloud-init.conf 覆盖
sudo tee /etc/ssh/sshd_config.d/99-setu-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t   # 必须 OK
sudo systemctl restart ssh
```

**强制**：开第二个终端 `ssh -i key maint@N "echo still-ok"`，成功后才关原终端。

---

## 6b. Phase 4b — gateway（默认 ops）：nginx + 限流

**动机**：防 anti-spam。公网用户只能打到 gateway；gateway 用 nginx 做 per-IP 限流 后反代到 3 台 validator。详见 [testnet-anti-spam-plan-20260529.md](./testnet-anti-spam-plan-20260529.md) 阶段 1。

一键脚本：[release/phase04b-gateway.sh](./release/phase04b-gateway.sh)。

手动最简版本（仅 HTTP，后期再 certbot 加 TLS）：

```bash
sudo apt-get install -y nginx
sudo tee /etc/nginx/conf.d/setu.conf >/dev/null <<'EOF'
limit_req_zone  $binary_remote_addr zone=setu_write:10m rate=5r/s;
limit_req_zone  $binary_remote_addr zone=setu_read:10m  rate=50r/s;
limit_conn_zone $binary_remote_addr zone=setu_conn:10m;

upstream setu_validators {
    server 173.212.239.161:8080 max_fails=3 fail_timeout=10s;
    server 5.189.163.210:8080   max_fails=3 fail_timeout=10s;
    server 5.189.136.19:8080    max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 80;
    server_name _;
    client_max_body_size 1m;
    limit_conn setu_conn 20;

    location ~ ^/api/v1/(move/ptb|move/call|transfer|batch|user/register|subnet/register|governance/) {
        limit_req zone=setu_write burst=10 nodelay;
        proxy_pass http://setu_validators;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    location /api/v1/ {
        limit_req zone=setu_read burst=100 nodelay;
        proxy_pass http://setu_validators;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    location / { return 404; }
}
EOF
sudo nginx -t && sudo systemctl reload nginx
```

**验收**：

```bash
# 外网：3 台 validator 8080 应全部 timeout/拒绝
curl -v --connect-timeout 5 http://173.212.239.161:8080/api/v1/health
# gateway：200
curl -fsS http://<OPS_IP>/api/v1/health | jq .status
# 限流：连发 50 次写接口应出 429
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    http://<OPS_IP>/api/v1/transfer -H 'content-type: application/json' -d '{}'
done | sort | uniq -c
```

---

## 7. Phase 5 — validator：运行时库 + sysctl + logrotate

仅 3 台 validator 执行。

```bash
sudo apt-get install -y libssl3 ca-certificates jq curl rsync logrotate
```

sysctl（**必须在 Setu 启动前**）：

```bash
sudo tee /etc/sysctl.d/99-setu.conf >/dev/null <<'EOF'
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
fs.file-max = 2097152
EOF
sudo sysctl --system

sudo tee /etc/security/limits.d/99-setu.conf >/dev/null <<'EOF'
setu soft nofile 1048576
setu hard nofile 1048576
EOF
```

logrotate：

```bash
sudo tee /etc/logrotate.d/setu >/dev/null <<'EOF'
/opt/setu/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
sudo logrotate -d /etc/logrotate.d/setu   # dry-run 必须无 error
```

---

## 8. Phase 6 — ops：编译工具链

仅 ops 一台。

```bash
sudo apt-get install -y \
  build-essential pkg-config libssl-dev \
  clang cmake protobuf-compiler

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
source $HOME/.cargo/env

# Clone repo
sudo install -d -o $USER -g $USER /opt/setu-src
git clone <repo-url> /opt/setu-src/Setu
cd /opt/setu-src/Setu
rustup show          # 自动按 rust-toolchain.toml 安装
cargo --version
```

---

## 9. Phase 7 — ops：keygen + genesis

```bash
cd /opt/setu-src/Setu
cargo run --release -p setu-cli -- --help    # 先确认 keygen 子命令名

mkdir -p deploy/testnet/keys
for i in 1 2 3; do
  cargo run --release -p setu-cli -- <keygen-subcmd> \
    --scheme ed25519 \
    --output deploy/testnet/keys/validator-${i}.key
done
chmod 600 deploy/testnet/keys/validator-*.key
```

参考 `genesis-multi.json` 写 `deploy/testnet/genesis-remote.json`，把 3 把 key 派生的 validator 地址 + 初始账户写入。

**产物**：
- `deploy/testnet/genesis-remote.json`（可入仓库）
- `deploy/testnet/keys/*.key`（**禁止入仓库**，加 `.gitignore`）

---

## 10. Phase 8 — ops：编译

```bash
cd /opt/setu-src/Setu

# 1. 先编 Move stdlib（强依赖）
bash tools/move-compile/build.sh   # 或 scripts/build_stdlib.sh（以 repo 实际为准）
ls setu-framework/compiled/*.mv    # 必须有产物

# 2. 再编 Rust
cargo build --release \
  --features "${CARGO_FEATURES}" \
  -p setu-validator -p setu-solver -p setu-cli -p setu-benchmark

./target/release/setu-validator --version
```

打包：

```bash
RELEASE_ID=$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)
STAGE=/opt/setu-build/$RELEASE_ID
mkdir -p "$STAGE"
cp target/release/setu-validator target/release/setu-solver target/release/setu-cli "$STAGE/"
cp -r setu-framework/compiled "$STAGE/move-stdlib"
cd "$STAGE"
sha256sum setu-validator setu-solver setu-cli > SHA256SUMS
echo "$RELEASE_ID" > release.id
```

---

## 11. Phase 9 — 分发 binary

对每台 validator N：

```bash
ssh setu@N "mkdir -p /opt/setu/bin/releases/$RELEASE_ID"
rsync -av --chmod=u=rwX,g=rX,o= \
  /opt/setu-build/$RELEASE_ID/ \
  setu@N:/opt/setu/bin/releases/$RELEASE_ID/

# 校验
ssh setu@N "cd /opt/setu/bin/releases/$RELEASE_ID && sha256sum -c SHA256SUMS"
ssh setu@N "ldd /opt/setu/bin/releases/$RELEASE_ID/setu-validator | grep 'not found' && exit 1 || true"
ssh setu@N "/opt/setu/bin/releases/$RELEASE_ID/setu-validator --version"

# 校验通过才切 symlink（注意 -T）
ssh setu@N "ln -sfnT /opt/setu/bin/releases/$RELEASE_ID /opt/setu/bin/current"
```

---

## 12. Phase 10 — 分发 genesis + key

```bash
for N in "${VAL_HOSTS[@]}"; do
  rsync -av --chmod=u=rw,g=r,o= \
    deploy/testnet/genesis-remote.json \
    setu@$N:/opt/setu/conf/genesis.json
done

rsync -av --chmod=u=rw,g=,o= deploy/testnet/keys/validator-1.key setu@testnet-val-1:/opt/setu/keys/validator.key
rsync -av --chmod=u=rw,g=,o= deploy/testnet/keys/validator-2.key setu@testnet-val-2:/opt/setu/keys/validator.key
rsync -av --chmod=u=rw,g=,o= deploy/testnet/keys/validator-3.key setu@testnet-val-3:/opt/setu/keys/validator.key
```

---

## 13. Phase 11 — systemd unit + 启动

每台 validator：

```bash
sudo tee /etc/systemd/system/setu-validator.service >/dev/null <<EOF
[Unit]
Description=Setu Validator
After=network-online.target chrony.service
Wants=network-online.target

[Service]
User=setu
Group=setu
WorkingDirectory=/opt/setu
Environment=RUST_LOG=info,setu_consensus=debug
ExecStart=/opt/setu/bin/current/setu-validator \\
  --genesis /opt/setu/conf/genesis.json \\
  --key /opt/setu/keys/validator.json \\
  --data-dir /opt/setu/data \\
  --http-listen 0.0.0.0:${HTTP_PORT} \\
  --p2p-listen 0.0.0.0:${P2P_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:/opt/setu/logs/validator.log
StandardError=append:/opt/setu/logs/validator.log

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
WorkingDirectory=/opt/setu
Environment=RUST_LOG=info
ExecStart=/opt/setu/bin/current/setu-solver \\
  --validator-url http://127.0.0.1:${HTTP_PORT} \\
  --listen 127.0.0.1:${SOLVER_PORT}
Restart=on-failure
RestartSec=5
StandardOutput=append:/opt/setu/logs/solver.log
StandardError=append:/opt/setu/logs/solver.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable setu-validator setu-solver
```

> ExecStart 参数以 `setu-validator --help` 为准。

启动（**逐台**）：

```bash
ssh setu@testnet-val-1 "sudo systemctl start setu-validator"
sleep 5
curl -sf http://testnet-val-1:8080/api/v1/health | jq .

ssh setu@testnet-val-2 "sudo systemctl start setu-validator"
sleep 5
curl -sf http://testnet-val-2:8080/api/v1/health | jq .

ssh setu@testnet-val-3 "sudo systemctl start setu-validator"
sleep 5
curl -sf http://testnet-val-3:8080/api/v1/health | jq .

# 3 台都 health=ok 再启 solver
for N in "${VAL_HOSTS[@]}"; do
  ssh setu@$N "sudo systemctl start setu-solver"
done
sleep 5
for N in "${VAL_HOSTS[@]}"; do
  echo "== $N =="
  curl -sf http://$N:8080/api/v1/health | jq '{s:.status, v:.validator_count, sv:.solver_count}'
done
```

**通过标准**：3 台 `status=ok`，`validator_count=3`，`solver_count>=1`。

---

## 14. Phase 12 — 验收 + 轻量监控

### 14.1 跑验收 matrix

```bash
cd /opt/setu-src/Setu
bash docs/testnet/testnet-infra/scripts/remote_infra_matrix.sh
```

通过标准：所有 stage `PASS`，无 `FAIL`。

### 14.2 轻量监控（替代 Prometheus/Grafana 全套）

在 ops 上：

```bash
sudo install -d -o $USER -g $USER /opt/setu-deploy/scripts
cat > /opt/setu-deploy/scripts/health_probe.sh <<'EOF'
#!/usr/bin/env bash
LOG=/var/log/setu-health.log
for N in testnet-val-1 testnet-val-2 testnet-val-3; do
  resp=$(curl -sf --max-time 5 http://$N:8080/api/v1/health)
  if [ -z "$resp" ]; then
    echo "$(date -u +%FT%TZ) DOWN $N" | sudo tee -a $LOG >/dev/null
  else
    summary=$(echo "$resp" | jq -c '{s:.status,v:.validator_count,sv:.solver_count,e:.dag_events_count}')
    echo "$(date -u +%FT%TZ) $N $summary" | sudo tee -a $LOG >/dev/null
  fi
done
EOF
chmod +x /opt/setu-deploy/scripts/health_probe.sh
sudo touch /var/log/setu-health.log
sudo chown $USER /var/log/setu-health.log

# cron 每分钟一次
( crontab -l 2>/dev/null; echo "* * * * * /opt/setu-deploy/scripts/health_probe.sh" ) | crontab -
```

日常巡检：

```bash
# 查最近 30 分钟健康
tail -n 90 /var/log/setu-health.log

# 远程看日志
ssh setu@testnet-val-1 "tail -f /opt/setu/logs/validator.log"

# 看 DAG 进度是否在涨
for N in testnet-val-1 testnet-val-2 testnet-val-3; do
  curl -sf http://$N:8080/api/v1/health | jq -r ".dag_events_count // 0"
done
```

---

## 15. 回滚速查

| 场景 | 操作 |
|---|---|
| binary 有 bug | `ssh setu@N "ln -sfnT /opt/setu/bin/releases/<上一个RELEASE_ID> /opt/setu/bin/current && sudo systemctl restart setu-validator setu-solver"` |
| 单 validator 异常 | `sudo systemctl restart setu-validator setu-solver` |
| 集群整体异常 | 三台依次 stop → 检查 genesis/key/conf 一致 → 依次 start |
| SSH 误锁 | VPS 控制台登录 → 删错改 → restart ssh |
| UFW 误锁 | VPS 控制台 `ufw disable` |
| 数据彻底坏 | 三台 stop → `rm -rf /opt/setu/data/*` → 重启（V1 阶段可重 genesis） |

---

## 16. 关键风险点（务必复读）

1. `ln -sfnT` 必须带 `-T`，不要预先 `mkdir current`
2. chrony 装前必须 `disable systemd-timesyncd`
3. sysctl/logrotate 必须在 Setu 启动**之前**生效
4. 关 SSH 密码登录前必须 key 登录 + 双终端验证
5. 任何升级/重启**逐台串行**，保留 quorum
6. validator 节点禁止装 Rust / Docker / 编译器
7. key 文件权限 `600`、目录 `700`，禁止入仓库

---

## 17. 升级到完整版的触发条件

出现以下**任一**条件，按 [完整版手册](testnet-server-install-runbook-20260529.md) 补齐：

- 有外部用户在用，宕机会被催
- 需要被告警叫醒（半夜也要）
- 日志量太大，ssh tail 看不过来
- 数据有了真实价值，不能重 genesis
- 团队人数 > 1，需要标准化运维流程
- 需要灰度发布 / 多版本并存

补齐时按这个顺序：
1. Grafana + Prometheus + node_exporter（看趋势）
2. json_exporter 接 `/api/v1/health`（看业务指标）
3. RocksDB 备份脚本 + cron（保数据）
4. Loki + Promtail（聚合日志）
5. nginx + TLS + basic auth（暴露 Grafana）
6. Alertmanager + 告警通道（被叫醒）
7. systemd 安全沙箱（生产加固）

---

## 18. 预期工时

| 阶段 | 预计耗时 |
|---|---|
| Phase 1–5（4 台基础环境 + validator 调优） | 1.5 小时 |
| Phase 6（ops 编译环境 + Rust 安装） | 0.5–1 小时（Rust 编译器拉取） |
| Phase 7（keygen + genesis） | 0.5 小时 |
| Phase 8（首次编译 stdlib + cargo build release） | 1–2 小时 |
| Phase 9–10（分发） | 0.5 小时 |
| Phase 11（systemd + 启动 + health 校验） | 0.5 小时 |
| Phase 12（验收 + 轻量监控） | 0.5 小时 |
| **合计** | **半天到 1 天** |

后续每次发新版本（不变动 OS）：Phase 8 → 9 → 11 重启，约 15 分钟。
