# Setu Testnet 服务器安装运行手册

> 日期：2026-05-29  
> 适用范围：长期存在的 Setu V1 公开测试网  
> 集群规模：3 × validator+solver 同机 + 1 × ops/builder/monitor  
> 操作系统：Ubuntu 24.04 LTS（22.04 LTS 兼容）x86_64

---

## 0. 集群拓扑与硬件

| 角色 | 数量 | 规格 | 说明 |
|---|---|---|---|
| validator+solver | 3 | 16C / 32G / 500G NVMe | 每台同时跑 setu-validator + setu-solver |
| ops/builder/monitor | 1 | 16C / 32G / 1T SSD | 编译产物、密钥仓库、Prometheus/Grafana/Loki、备份归档 |

端口规划（统一）：

| 端口 | 协议 | 用途 | 暴露面 |
|---|---|---|---|
| 22 | TCP | SSH | 仅维护 IP 白名单 |
| 8080 | TCP | Setu HTTP API `/api/v1/*` | 仅 gateway IP（公网入口由 gateway 443 反代） |
| 9000 | TCP+UDP | Anemo P2P（QUIC） | 仅 validator 互通 + ops 监控 |
| 9001 | TCP | Solver mock TEE | 仅本机回环 |
| 9100 | TCP | node_exporter | 仅 ops 抓取 |
| 9080 | TCP | promtail / json_exporter | 仅 ops 抓取 |
| 3000 | TCP | Grafana | 仅 ops 本机，nginx 反代 |
| 9090 | TCP | Prometheus | 仅 ops 本机 |
| 3100 | TCP | Loki | 仅 ops 本机 |
| 443 | TCP | nginx (Grafana TLS) | 公网（可选） |

主机名约定（与 `docs/v1/release/inventory.env` 保持一致）：

```
testnet-val-1  <VAL1_IP>
testnet-val-2  <VAL2_IP>
testnet-val-3  <VAL3_IP>
testnet-ops    <OPS_IP>        # 同时承担 gateway、builder、monitor
testnet.setu.org → <OPS_IP>  # 公网入口域名（A 记录，TTL 600）
```

维护 IP 白名单：在动手前确认并记录。本文用 `<MAINT_IP>` 占位。

---

## 1. 总体原则

1. **逐台串行**，禁止三台 validator 并行执行涉及 SSH/UFW/sshd 的阶段。
2. **每个 Phase 必须可重入**：脚本写成幂等，重跑无害。
3. **Setu 节点不装 Rust、不装 Docker、不装编译工具**。所有编译在 ops 完成，二进制 + 校验和 rsync 下发。
4. **任何破坏性变更前**先打通备用通道（如改 sshd 前先开第二个 SSH 会话验证）。
5. **5 个 checkpoint** 之间禁止跨越，详见 §3。
6. **不依赖 cargo fmt / fix**：遵循 G14，仅手动维护配置。

---

## 2. 执行 Checkpoint

| CP | 完成于 | 含义 | 回滚方式 |
|---|---|---|---|
| CP1 | Phase 5 | 安全基线建立 | 仍可用旧密码登录，删除 UFW 规则即可恢复 |
| CP2 | Phase 8 | 节点环境就绪 | 节点干净，可整机重装 |
| CP3 | Phase 14 | 编译产物 OK | ops 上重编，validator 未触动 |
| CP4 | Phase 19 | 集群上线 | symlink 回退到上一个 release |
| CP5 | Phase 25 | 监控接入 + 验收通过 | testnet 正式可用 |

---

## 3. Phase 0 — 规划与冻结

**目标**：把所有变量在动手前写死。

产出文件：`deploy/testnet/inventory.env`（手工维护，不入仓库或仅入仓库示例版）

```bash
# 节点
VAL_HOSTS=(testnet-val-1 testnet-val-2 testnet-val-3)
VAL_IPS=(<VAL1_IP> <VAL2_IP> <VAL3_IP>)
OPS_HOST=testnet-ops
OPS_IP=<OPS_IP>
GATEWAY_DOMAIN=testnet.setu.org   # 与 DNS A 记录一致

# 端口
HTTP_PORT=8080
P2P_PORT=9000
SOLVER_PORT=9001

# 维护：分层 SSH 白名单（见 §8.1）
#   ops 22 对全网开放（key + fail2ban 防护），val 22 仅放行 ops 跳板 + 运维者 IP 段
MAINT_IPS_OPS=("0.0.0.0/0")
MAINT_IPS_VAL=("$OPS_IP/32" "<OPERATOR_HOME_CIDR>")   # 例 "117.173.0.0/16"
SETU_USER=setu
SETU_GROUP=setu

# 目录
SETU_HOME=/opt/setu
SETU_BIN_DIR=$SETU_HOME/bin
SETU_DATA_DIR=$SETU_HOME/data
SETU_LOG_DIR=$SETU_HOME/logs
SETU_CONF_DIR=$SETU_HOME/conf
SETU_KEY_DIR=$SETU_HOME/keys

# 构建
CARGO_FEATURES=diag-root-drift
RUST_TOOLCHAIN=stable   # 若 repo 有 rust-toolchain.toml 则以其为准
```

**校验**：所有维护人员对该 inventory 签字确认（人工 review）。

---

## 4. Phase 1 — 所有节点：基础 apt 工具

**对象**：4 台全部。

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl wget gnupg lsb-release \
  jq rsync unzip git \
  htop iotop sysstat lsof tcpdump dnsutils net-tools \
  ufw logrotate
```

**注意**：
- 不装 `fail2ban`（key-only + UFW + 维护 IP 白名单已足够）
- 不装 `vim`/`tmux` 在 validator 上（仅 ops 装）
- 不装 `build-essential`/`pkg-config` 在 validator 上

**幂等校验**：`dpkg -l jq rsync ufw logrotate` 全部 `ii`。

---

## 5. Phase 2 — 所有节点：时间同步（chrony 替换 timesyncd）

**关键**：必须先关 `systemd-timesyncd`，否则与 chrony 冲突。

```bash
sudo systemctl disable --now systemd-timesyncd
sudo apt-get install -y chrony
sudo systemctl enable --now chrony
sleep 5
chronyc tracking
chronyc sources -v
```

**通过标准**：
- `Leap status: Normal`
- `System time` 偏差 < 100 ms
- 至少 3 个 source 为 `^*` 或 `^+`

---

## 6. Phase 3 — 所有节点：用户与目录骨架

> ⚠️ `setu` 用户 shell 必须是 `/bin/bash`（不是 `nologin`）。后续 Phase 15/16/回滚要通过 `ssh setu@<IP>` 远程执行 `rsync`/`ln`/`ls` 等命令，nologin 会让所有这些步骤直接 fail。
> 安全靠：① 仅 key 登录、② setu 无密码、③ setu 不在 sudoers —— 三项缺一不可。

```bash
sudo groupadd --system setu 2>/dev/null || true
sudo useradd --system --gid setu --home-dir /opt/setu \
  --shell /bin/bash setu 2>/dev/null || true
# 若之前用 nologin 创建过，纠正之
sudo usermod -s /bin/bash setu 2>/dev/null || true

sudo install -d -o setu -g setu -m 750 /opt/setu
sudo install -d -o setu -g setu -m 750 /opt/setu/bin
sudo install -d -o setu -g setu -m 750 /opt/setu/bin/releases
# 注意：不 mkdir /opt/setu/bin/current ！ symlink 由部署脚本创建
sudo install -d -o setu -g setu -m 750 /opt/setu/data
sudo install -d -o setu -g setu -m 750 /opt/setu/logs
sudo install -d -o setu -g setu -m 750 /opt/setu/conf
sudo install -d -o setu -g setu -m 700 /opt/setu/keys
# setu 的 .ssh 目录（下一步要装 authorized_keys）
sudo install -d -o setu -g setu -m 700 /opt/setu/.ssh
```

**给 setu 用户安装维护公钥**（用同一把 `setu_maint.pub`；后续 `ssh setu@<IP>` 才可登录）：

```bash
# 在 ops 本机执行，对每台节点 N（含 ops 自身）：
for IP in "${VAL_IPS[@]}" "$OPS_IP"; do
  ssh -i ~/.ssh/setu_maint root@$IP \
    "install -o setu -g setu -m 700 -d /opt/setu/.ssh && \
     install -o setu -g setu -m 600 /dev/null /opt/setu/.ssh/authorized_keys"
  cat ~/.ssh/setu_maint.pub | \
    ssh -i ~/.ssh/setu_maint root@$IP "cat >> /opt/setu/.ssh/authorized_keys"
done

# 验证
for IP in "${VAL_IPS[@]}" "$OPS_IP"; do
  ssh -i ~/.ssh/setu_maint -o BatchMode=yes setu@$IP "echo $IP setu-login-ok"
done
```

**调试小贴士**：调试 setu 进程用 `sudo -u setu -s /bin/bash`。

---

## 7. Phase 4 — 所有节点：SSH key 推送与验证（逐台串行）

**前置**：服务器开通后控制台拿到的 root 密码（4 台密码可能相同也可能不同，按 Contabo 实际为准）。这一阶段是整个 runbook **唯一**需要密码的环节；Phase 5 完成后密码登录被永久关闭。

### 7.1 准备维护私钥（本地或 ops 上，跑一次即可）

```bash
# 已经有 ~/.ssh/setu_maint 就跳过
ssh-keygen -t ed25519 -f ~/.ssh/setu_maint -C "setu-testnet-maint"
# passphrase 建议设；下一步用 ssh-agent 缓存，避免每个 phase 都弹窗
```

如果设了 passphrase，每个新终端先：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/setu_maint
```

### 7.2 推公钥（4 台逐台、唯一输密码的地方）

```bash
for IP in "${VAL_IPS[@]}" "$OPS_IP"; do
    echo "=== $IP ==="
    ssh-copy-id -i ~/.ssh/setu_maint.pub root@$IP
    # 提示 "root@$IP's password:" 时手动输入服务器 root 密码
done
```

> ⚠️ **不要**把密码写进 inventory.env / 脚本 / `sshpass -p`。这一段密码场景仅此一次。

### 7.3 验证 key 登录（应当**不再**问密码）

```bash
for IP in "${VAL_IPS[@]}" "$OPS_IP"; do
    ssh -i ~/.ssh/setu_maint -o PasswordAuthentication=no root@$IP \
        "hostname; uptime" \
        || { echo "FAIL: $IP key login broken"; exit 1; }
done
```

4 台全部正常打印 hostname 才算通过。

### 7.4 常见坑

- **`ssh-copy-id` 报 `Permission denied (publickey)`**：服务器 sshd 默认就禁了密码登录。需要先用 Contabo 控制台 VNC / Web Console 登录，临时改 `/etc/ssh/sshd_config`：
  ```
  PasswordAuthentication yes
  ```
  `systemctl restart ssh`，推完 key 后 Phase 5 会自动重新关闭。
- **Contabo 控制台密码请用密码管理器存档**：万一 Phase 5+ SSH 锁死，VNC 控制台登录靠的就是这个密码，丢了只能整机重装。
- **不同密码**：如果 4 台 root 密码不同，`ssh-copy-id` 会逐台分别提示，对应每台输入即可。
- **后续运维想换 key**：必须**先在控制台 VNC** 把新 key 加进 `/root/.ssh/authorized_keys`，验证新 key 可登录后再删旧 key——绝不要先删。

**禁止**：未完成 §7.3 验证前进入 Phase 5。

---

## 8. Phase 5 — 所有节点：SSH 加固 + UFW + journald（逐台串行）

**对每一台节点 N**：

### 8.1 UFW 规则（必须先允许 SSH 再 enable）

**分层白名单策略**（与 `inventory.env` 中 `MAINT_IPS_OPS` / `MAINT_IPS_VAL` 对应）：

- **ops**（跳板 / 公网入口）：22 默认对全网开放（`0.0.0.0/0`），靠 key-only + fail2ban 防护。原因：ops 本身要对外提供 80/443，22 多开不显著扩大攻击面；代价是运维便利性最高。
- **val-1/2/3**（共识节点）：22 仅放行 ops IP + 运维者家宽出口段（兑底）。主路径是 ops 跳板；ops 故障时仍可直连。

```bash
# === 22 端口 —— 分层白名单 ===
if [ "$HOST" = "$OPS_HOST" ]; then
  for ip in "${MAINT_IPS_OPS[@]}"; do
    sudo ufw allow from "$ip" to any port 22 proto tcp
  done
else
  for ip in "${MAINT_IPS_VAL[@]}"; do
    sudo ufw allow from "$ip" to any port 22 proto tcp
  done
fi

# === validator 节点：P2P 9000、HTTP 8080 仅放 gateway、监控拓取 9100/9080 仅放 ops ===
for ip in "${VAL_IPS[@]}" "$OPS_IP"; do
  sudo ufw allow from "$ip" to any port 9000 proto tcp
  sudo ufw allow from "$ip" to any port 9000 proto udp
done
sudo ufw allow from "$OPS_IP" to any port 8080 proto tcp
for ip in "${MAINT_IPS_VAL[@]}"; do
  sudo ufw allow from "$ip" to any port 8080 proto tcp   # 调试用
done
sudo ufw allow from "$OPS_IP" to any port 9100 proto tcp
sudo ufw allow from "$OPS_IP" to any port 9080 proto tcp

# === ops/gateway 节点：公网 443（Grafana + Setu 网关） + 80（certbot）===
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
```

### 8.2 sshd 关闭密码登录

```bash
# Ubuntu 22/24 的 /etc/ssh/sshd_config 默认 Include /etc/ssh/sshd_config.d/*.conf
# cloud-init 写入的 50-cloud-init.conf 会覆盖主文件，所以必须用 drop-in 文件
sudo tee /etc/ssh/sshd_config.d/99-setu-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t   # 必须 OK，否则不要 restart
sudo systemctl restart ssh
```

**强制验证**：另开一个终端 `ssh -i key maint@N "echo still-ok"`，**成功后才能关闭原会话**。

### 8.3 fail2ban（SSH 暴力扫描防护）

```bash
sudo apt-get install -y fail2ban
sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

- ops（22 对公网开放）**必装**；val（仅白名单 IP）也装上作双保险。
- `phase04-ssh-ufw.sh` 的 4.5b 已自动完成上述动作。

### 8.4 journald 限额

```bash
sudo tee /etc/systemd/journald.conf.d/setu.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald
```

---

## ✅ CHECKPOINT 1 — 安全基线建立

进入 Phase 6 前必须满足：4 台均为 key-only SSH、UFW 已 enable 且 SSH 22 在白名单中（ops = `MAINT_IPS_OPS`，val = `MAINT_IPS_VAL`）、fail2ban 已启动、journald 已限额、chrony 同步正常。

---

## 9. Phase 6 — validator：运行时库

**仅 3 台 validator**。

```bash
sudo apt-get install -y \
  libssl3 ca-certificates \
  jq curl rsync logrotate
```

**禁止**：在 validator 上安装 `libssl-dev`、`build-essential`、`pkg-config`、`clang`、`cmake`、`protoc`、`rustc`、`cargo`、`docker`。

---

## 10. Phase 7 — validator：sysctl 调优 + logrotate

**必须在 Setu 启动前生效**。

### 10.1 sysctl

```bash
sudo tee /etc/sysctl.d/99-setu.conf >/dev/null <<'EOF'
# 网络突发
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# UDP（Anemo QUIC）
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 2621440
net.core.wmem_default = 2621440

# 文件句柄
fs.file-max = 2097152
EOF
sudo sysctl --system
```

```bash
sudo tee /etc/security/limits.d/99-setu.conf >/dev/null <<'EOF'
setu soft nofile 1048576
setu hard nofile 1048576
EOF
```

### 10.2 logrotate

```bash
sudo tee /etc/logrotate.d/setu >/dev/null <<'EOF'
/opt/setu/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su setu setu
}
EOF
sudo logrotate -d /etc/logrotate.d/setu   # dry-run 必须无 error
```

**`copytruncate` 注意**：与 systemd `StandardOutput=append:` 配合时存在毫秒级日志窗口，可接受。

---

## 11. Phase 8 — validator：node_exporter + promtail

### 11.1 node_exporter（systemd 服务）

```bash
NODE_EXP_VER=1.8.2
cd /tmp
wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXP_VER}/node_exporter-${NODE_EXP_VER}.linux-amd64.tar.gz
tar xf node_exporter-${NODE_EXP_VER}.linux-amd64.tar.gz
sudo install -o root -g root -m 755 \
  node_exporter-${NODE_EXP_VER}.linux-amd64/node_exporter \
  /usr/local/bin/node_exporter

sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
curl -sf http://127.0.0.1:9100/metrics | head -3
```

### 11.2 promtail

> Loki 端点暂未存在，可先用占位 URL，待 Phase 20 后再 `systemctl restart promtail`。

```bash
PROMTAIL_VER=3.0.0
cd /tmp
wget -q https://github.com/grafana/loki/releases/download/v${PROMTAIL_VER}/promtail-linux-amd64.zip
unzip -o promtail-linux-amd64.zip
sudo install -o root -g root -m 755 promtail-linux-amd64 /usr/local/bin/promtail

sudo install -d -o root -g root -m 755 /etc/promtail
sudo tee /etc/promtail/config.yml >/dev/null <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://${OPS_IP}:3100/loki/api/v1/push

scrape_configs:
  - job_name: setu
    static_configs:
      - targets: [localhost]
        labels:
          host: $(hostname)
          job: setu
          __path__: /opt/setu/logs/*.log
EOF
sudo install -d -o root -g root -m 755 /var/lib/promtail

sudo tee /etc/systemd/system/promtail.service >/dev/null <<'EOF'
[Unit]
Description=Promtail
After=network-online.target

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now promtail
```

---

## ✅ CHECKPOINT 2 — 节点环境就绪

3 台 validator 已具备：用户/目录/sysctl/logrotate/node_exporter/promtail，全部 enable 且无错误。尚未部署 setu binary。

---

## 12. Phase 9 — ops：编译工具链

**仅 ops 一台**。

```bash
sudo apt-get install -y \
  build-essential pkg-config libssl-dev \
  clang cmake protobuf-compiler \
  vim tmux
```

安装 Rust：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
source $HOME/.cargo/env

cd /opt/setu-src/Setu   # repo 已 clone
# 若 repo 有 rust-toolchain.toml，rustup 会自动安装
rustup show
rustc --version
cargo --version
```

**校验**：`cargo --version` 输出与 `rust-toolchain.toml` 中版本匹配。

---

## 13. Phase 10 — ops：Docker + Compose

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
docker --version
docker compose version
```

**注意**：本方案监控容器全部绑定 `127.0.0.1`，所以**不修改** Docker iptables 行为，但要在 §17 中严格遵守端口绑定规则。

---

## 14. Phase 11 — ops：node_exporter + promtail（监控自身）

复用 Phase 8 步骤，对 ops 主机执行。promtail 抓取路径改为 ops 自身关心的日志（如 `/var/log/syslog`、`/opt/monitor/*/logs/*`）。

---

## 15. Phase 12 — ops：validator 密钥生成 + genesis 组装

### 15.1 在 ops 上 clone 仓库（如未 clone）

固定使用公开镜像的 `testnet/v1` 分支作为部署源（已包含本 runbook 与 `docs/v1/release/` 全套 phase 脚本）：

```bash
sudo install -d -o $USER -g $USER /opt/setu-src
git clone --branch testnet/v1 --depth 1 https://github.com/ivan-xin/Setu /opt/setu-src/Setu
cd /opt/setu-src/Setu
```

后续若需更新到 `testnet/v1` 的新 commit：`git fetch origin testnet/v1 && git reset --hard origin/testnet/v1`（仅在 ops 上执行；validator 不 clone 源码）。

### 15.2 keygen CLI 子命令

setu-cli 的真实子命令是 `validator keygen`（与 `docs/v1/release/phase07-keygen-genesis.sh` 保持一致）：

```bash
cargo run --release -p setu-cli -- validator keygen --help
```

### 15.3 生成 3 把 validator key

```bash
mkdir -p /opt/setu-src/Setu/deploy/testnet/keys
for i in 1 2 3; do
  cargo run --release -p setu-cli -- validator keygen \
    --output deploy/testnet/keys/validator-${i}.json \
    --id "validator-${i}"
done
chmod 600 deploy/testnet/keys/validator-*.json
```

> 输出文件 schema 必须包含 `node_id` / `account_address` / `public_key` / `private_key`（phase07 脚本会校验）。

### 15.4 组装 `genesis-remote.json`

推荐直接跑 `bash docs/v1/release/phase07-keygen-genesis.sh`，它会幂等生成 key + 渲染 genesis（含默认 alice/bob/charlie 账户与余额，与 deploy/dev-mult 一致）。

**产物**：`deploy/testnet/genesis-remote.json`（入仓库），`deploy/testnet/keys/*.json`（**禁止入仓库**，加入 `.gitignore`）。

---

## 16. Phase 13 — ops：编译

### 16.1 先编 Move stdlib（**强依赖**，不可跳过）

```bash
cd /opt/setu-src/Setu
bash scripts/build_stdlib.sh        # 主路径
# fallback（旧路径，仅当上面不存在时）：bash tools/move-compile/build.sh
ls setu-framework/compiled/*.mv     # 必须有产物
```

### 16.2 再编 Rust

```bash
cargo build --release \
  --features "${CARGO_FEATURES}" \
  -p setu-validator \
  -p setu-solver \
  -p setu-cli \
  -p setu-benchmark
```

校验：

```bash
ls -lh target/release/setu-validator target/release/setu-solver target/release/setu-cli
./target/release/setu-validator --version
```

---

## 17. Phase 14 — ops：打包 release artifact

```bash
RELEASE_ID=$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)
STAGE=/opt/setu-build/$RELEASE_ID
mkdir -p "$STAGE"

cp target/release/setu-validator "$STAGE/"
cp target/release/setu-solver    "$STAGE/"
cp target/release/setu-cli       "$STAGE/"
cp -r setu-framework/compiled    "$STAGE/move-stdlib"

cd "$STAGE"
sha256sum setu-validator setu-solver setu-cli > SHA256SUMS
find move-stdlib -type f -exec sha256sum {} \; >> SHA256SUMS

cat > release.info <<EOF
release_id=$RELEASE_ID
git_commit=$(git -C /opt/setu-src/Setu rev-parse HEAD)
features=$CARGO_FEATURES
built_at=$(date -u +%FT%TZ)
built_by=$USER
EOF
```

---

## ✅ CHECKPOINT 3 — 编译产物 OK

ops 上 `$STAGE/SHA256SUMS` 完整、`release.info` 已生成、`setu-validator --version` 可执行。validator 节点未受影响。

---

## 18. Phase 15 — 分发 binary 到 validator

> 推荐直接 `bash docs/v1/release/phase09-distribute-binary.sh`，它已实现下列全部步骤 + sha256 + ldd + 切 symlink + 自动清理旧 release。下文是等效手工命令，供理解/调试。

对每台 validator（用 IP，不用主机名 —— 4 台 server 之间没有内网 DNS）：

```bash
for IP in "${VAL_IPS[@]}"; do
  ssh -i ~/.ssh/setu_maint setu@$IP "mkdir -p /opt/setu/bin/releases/$RELEASE_ID"
  rsync -av --chmod=u=rwX,g=rX,o= \
    -e "ssh -i ~/.ssh/setu_maint" \
    /opt/setu-build/$RELEASE_ID/ \
    setu@$IP:/opt/setu/bin/releases/$RELEASE_ID/

  # 远端校验（read-only，setu 用户可执行）
  ssh -i ~/.ssh/setu_maint setu@$IP "cd /opt/setu/bin/releases/$RELEASE_ID && sha256sum -c SHA256SUMS"
  ssh -i ~/.ssh/setu_maint setu@$IP "ldd /opt/setu/bin/releases/$RELEASE_ID/setu-validator | grep 'not found' && exit 1 || true"
  ssh -i ~/.ssh/setu_maint setu@$IP "/opt/setu/bin/releases/$RELEASE_ID/setu-validator --version"
done
```

校验全部通过后**才**切换 symlink（**用 `-T`**）：

```bash
for IP in "${VAL_IPS[@]}"; do
  ssh -i ~/.ssh/setu_maint setu@$IP "ln -sfnT /opt/setu/bin/releases/$RELEASE_ID /opt/setu/bin/current"
  ssh -i ~/.ssh/setu_maint setu@$IP "ls -l /opt/setu/bin/current"
done
```

**保留策略**：保留最近 5 个 release，多余删除：

```bash
for IP in "${VAL_IPS[@]}"; do
  ssh -i ~/.ssh/setu_maint setu@$IP "cd /opt/setu/bin/releases && ls -1t | tail -n +6 | xargs -r rm -rf"
done
```

---

## 19. Phase 16 — 分发 genesis + 各自 key

> 推荐 `bash docs/v1/release/phase10-distribute-config.sh`。下文是等效手工命令。
> ⚠️ 远端文件名固定为 `validator.json`（不是 `.key`），systemd unit ExecStart `--key` 也指向这个名字。

```bash
# 所有节点同一个 genesis（用 IP，不用主机名）
for IP in "${VAL_IPS[@]}"; do
  rsync -av --chmod=u=rw,g=r,o= \
    -e "ssh -i ~/.ssh/setu_maint" \
    deploy/testnet/genesis-remote.json \
    setu@$IP:/opt/setu/conf/genesis.json
done

# 各自的 key（按 VAL_IPS 顺序对应 validator-1/2/3.json）
for i in "${!VAL_IPS[@]}"; do
  idx=$((i + 1))
  rsync -av --chmod=u=rw,g=,o= \
    -e "ssh -i ~/.ssh/setu_maint" \
    deploy/testnet/keys/validator-${idx}.json \
    setu@${VAL_IPS[$i]}:/opt/setu/keys/validator.json
done

for IP in "${VAL_IPS[@]}"; do
  ssh -i ~/.ssh/setu_maint setu@$IP "ls -l /opt/setu/keys/validator.json /opt/setu/conf/genesis.json"
done
```

---

## 20. Phase 17 — systemd unit 落盘（enable 但不 start）

### 20.1 setu-validator.service

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
ExecStart=/opt/setu/bin/current/setu-validator \
  --genesis /opt/setu/conf/genesis.json \
  --key /opt/setu/keys/validator.json \
  --data-dir /opt/setu/data \
  --http-listen 0.0.0.0:${HTTP_PORT} \
  --p2p-listen 0.0.0.0:${P2P_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:/opt/setu/logs/validator.log
StandardError=append:/opt/setu/logs/validator.log

# 安全沙箱
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/setu/data /opt/setu/logs
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
```

### 20.2 setu-solver.service

```bash
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
ExecStart=/opt/setu/bin/current/setu-solver \
  --validator-url http://127.0.0.1:${HTTP_PORT} \
  --listen 127.0.0.1:${SOLVER_PORT}
Restart=on-failure
RestartSec=5
StandardOutput=append:/opt/setu/logs/solver.log
StandardError=append:/opt/setu/logs/solver.log
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/setu/logs

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable setu-validator setu-solver
# 此时不 start
```

> ExecStart 中的参数名（如 `--http-listen`、`--key`）以 `setu-validator --help` 为准，必要时调整。

---

## 21. Phase 18 — 启动 validator（逐台串行）

> 推荐 `bash docs/v1/release/phase11-systemd-start.sh`（含 ExecStart flag 飞行前校验、串行启动、health 等待、journalctl 失败回显）。下文是等效手工命令。
> ⚠️ `sudo systemctl start` 必须以 **root** SSH 登录执行 —— `setu` 用户**不在 sudoers**。

```bash
# 第 1 台
ssh -i ~/.ssh/setu_maint root@${VAL_IPS[0]} "sudo systemctl start setu-validator"
sleep 5
curl -sf http://${VAL_IPS[0]}:8080/api/v1/health | jq .

# 第 2 台
ssh -i ~/.ssh/setu_maint root@${VAL_IPS[1]} "sudo systemctl start setu-validator"
sleep 5
curl -sf http://${VAL_IPS[1]}:8080/api/v1/health | jq .

# 第 3 台
ssh -i ~/.ssh/setu_maint root@${VAL_IPS[2]} "sudo systemctl start setu-validator"
sleep 5
curl -sf http://${VAL_IPS[2]}:8080/api/v1/health | jq .
```

**通过标准**：3 台 `/api/v1/health` 均返回 `status=ok`，`validator_count=3`。

---

## 22. Phase 19 — 启动 solver

```bash
for IP in "${VAL_IPS[@]}"; do
  ssh -i ~/.ssh/setu_maint root@$IP "sudo systemctl start setu-solver"
done
sleep 5
for IP in "${VAL_IPS[@]}"; do
  curl -sf http://$IP:8080/api/v1/health | jq '.solver_count'
done
```

**通过标准**：3 台均返回 `solver_count >= 1`。

---

## ✅ CHECKPOINT 4 — 集群上线

3 节点共识 + 3 solver，health 全绿。日志写入 `/opt/setu/logs/*.log`。

---

## 22b. Phase 19b — gateway：nginx 反代 + 限流（anti-spam 阶段 1）

**动机**：3 台 validator 的 8080 已在 Phase 5 UFW 阶段被限制为仅 `OPS_IP` 可达，公网用户必须经 gateway 入。本阶段在 gateway（默认复用 ops 节点）装 nginx，做 per-IP QPS / 并发限流 + 可选 TLS。

详见 [testnet-anti-spam-plan-20260529.md](./testnet-anti-spam-plan-20260529.md) §4。一键脚本：[release/phase04b-gateway.sh](./release/phase04b-gateway.sh)（无 TLS 时同样可用，仅需在 `inventory.env` 留空 `GATEWAY_DOMAIN`）。

**验收（必跑）**：

```bash
# 1. 外网扫 validator 8080 — 应全部 timeout/拒绝
for ip in "${VAL_IPS[@]}"; do
  curl -v --connect-timeout 5 http://$ip:8080/api/v1/health
done

# 2. 经 gateway 访问 — 200
curl -fsS https://${GATEWAY_DOMAIN}/api/v1/health | jq .status

# 3. 限流 — 连发 50 次写接口应看到 429
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST https://${GATEWAY_DOMAIN}/api/v1/transfer \
    -H 'content-type: application/json' -d '{}'
done | sort | uniq -c
```

> 后续 anti-spam 阶段 2-4（faucet / 签名校验 / AdmissionLimiter）不在本 runbook 范围，按计划独立交付。

---

## 23. Phase 20 — ops：监控栈（Docker Compose，全部绑回环）

> 推荐 `GRAFANA_ADMIN_PASSWORD=...  bash docs/v1/release/phase13-monitoring.sh`，它会在 gateway 节点幂等落盘以下全部配置 + `docker compose up -d` + 探活。
> 下文是等效手工命令，供理解/调试。

目录布局：

```
/opt/monitor/
├── docker-compose.yml
├── prometheus/prometheus.yml
├── loki/loki-config.yml
├── promtail/(ops 自身已在 Phase 11 装好)
├── grafana/(provisioning)
└── json_exporter/config.yml
```

### 23.1 `docker-compose.yml`

```yaml
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
    environment:
      GF_SECURITY_ADMIN_PASSWORD: __set_via_env_file__
      GF_AUTH_ANONYMOUS_ENABLED: "false"
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
```

### 23.2 `json_exporter/config.yml`

将 `/api/v1/health` 的 JSON 转成 Prometheus 指标：

```yaml
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
```

### 23.3 `loki/loki-config.yml`（启用保留）

```yaml
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
  retention_period: 720h          # 30 天

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem
```

### 23.4 启动

```bash
cd /opt/monitor
docker compose up -d
docker compose ps
```

校验：

```bash
curl -s http://127.0.0.1:9090/-/ready
curl -s http://127.0.0.1:3100/ready
curl -s http://127.0.0.1:3000/api/health
```

---

## 24. Phase 21 — nginx + TLS + basic auth 反代 Grafana

```bash
sudo apt-get install -y nginx apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd_grafana admin

# TLS 证书：可用 Let's Encrypt（公网域名）或自签
# sudo apt-get install -y certbot python3-certbot-nginx
# sudo certbot --nginx -d grafana.<your-domain>

sudo tee /etc/nginx/sites-available/grafana >/dev/null <<'EOF'
server {
    listen 443 ssl http2;
    server_name grafana.<your-domain>;

    ssl_certificate     /etc/letsencrypt/live/grafana.<your-domain>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/grafana.<your-domain>/privkey.pem;

    auth_basic "Setu Monitor";
    auth_basic_user_file /etc/nginx/.htpasswd_grafana;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/grafana /etc/nginx/sites-enabled/grafana
sudo nginx -t && sudo systemctl reload nginx
```

---

## 25. Phase 22 — Prometheus 抓取目标接入

> 下面 `prometheus.yml` 使用 hostname（`testnet-val-1` 等）作为示意；**实际部署请运行**
> `bash docs/v1/release/phase13-monitoring.sh`，该脚本会根据 `inventory.env` 中的真实 IP
> 自动渲染 targets，无需手工编辑。

`/opt/monitor/prometheus/prometheus.yml`：

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 30s

scrape_configs:
  - job_name: node
    static_configs:
      - targets:
          - testnet-val-1:9100
          - testnet-val-2:9100
          - testnet-val-3:9100
          - testnet-ops:9100

  - job_name: setu-health-json
    metrics_path: /probe
    params:
      module: [setu_health]
    static_configs:
      - targets:
          - http://testnet-val-1:8080/api/v1/health
          - http://testnet-val-2:8080/api/v1/health
          - http://testnet-val-3:8080/api/v1/health
    relabel_configs:
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
          - http://testnet-val-1:8080/api/v1/health
          - http://testnet-val-2:8080/api/v1/health
          - http://testnet-val-3:8080/api/v1/health
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox_exporter:9115
```

应用：

```bash
docker compose -f /opt/monitor/docker-compose.yml restart prometheus
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[].health' | sort | uniq -c
```

---

## 26. Phase 23 — Grafana dashboard + 告警

最小看板（手工创建或 provision JSON）：

- **Cluster Health**：`setu_solver_count`、`setu_validator_count`（按 instance）
- **DAG Throughput**：`rate(setu_dag_events_count[5m])`
- **Liveness**：`probe_success`（blackbox） + `up{job="node"}`
- **Host**：CPU/Memory/Disk/Network（node_exporter 标准面板）
- **Logs**：Loki `{job="setu"}` 关键字过滤 `ERROR|panic|finalized|leader`

告警规则（Prometheus alerting rules，最少 4 条）：

1. `up{job="node"} == 0 for 2m` → 节点失联
2. `probe_success == 0 for 2m` → HTTP API 失联
3. `setu_solver_count < 1 for 5m` → solver 掉线
4. `rate(setu_dag_events_count[10m]) == 0` → 共识停滞

> Alertmanager 可在确定告警通道（Slack/邮件/微信）后再加入 compose。

---

## 27. Phase 24 — 定时任务（cron / systemd timer）

### 27.1 每日 infra 健康巡检（ops 上）

`remote_infra_matrix.sh` 会从 ops 远程 SSH 到所有 host 收集 CPU / 内存 / 磁盘 / systemd 状态，输出对比矩阵：

```bash
sudo tee /etc/cron.d/setu-infra-matrix >/dev/null <<'EOF'
0 6 * * * setu cd /opt/setu-src/Setu && bash docs/testnet/testnet-infra/scripts/remote_infra_matrix.sh >> /var/log/setu-infra-matrix.log 2>&1
EOF
```

> 公开镜像 (`origin/testnet/v1`) 未携带 `docs/testnet/`；如果用公开版部署，请改为调用 `docs/v1/release/health_probe.sh`：
> ```bash
> 0 6 * * * setu bash /opt/setu-src/Setu/docs/v1/release/health_probe.sh >> /var/log/setu-health.log 2>&1
> ```

### 27.2 每周 RocksDB 备份（**逐台串行**，保留 quorum）

`/opt/setu-deploy/scripts/snapshot-rocksdb.sh`（IP 由 `inventory.env` 注入）：

```bash
#!/usr/bin/env bash
set -euo pipefail
source /etc/setu-deploy/hosts.env   # 由 phase12 渲染，含 SETU_HEALTH_HOSTS="val-1:IP val-2:IP ..."
MAINT_KEY="${MAINT_KEY:-$HOME/.ssh/setu_maint}"
BACKUP_ROOT=/opt/setu-backups
DATE=$(date +%F)
read -r -a HOSTS <<<"$SETU_HEALTH_HOSTS"
for entry in "${HOSTS[@]}"; do
  name="${entry%%:*}"; ip="${entry##*:}"
  echo "== snapshotting $name ($ip) =="
  # stop / start 必须 root（setu 不在 sudoers）
  ssh -i "$MAINT_KEY" root@$ip "sudo systemctl stop setu-validator setu-solver"
  mkdir -p "$BACKUP_ROOT/$name/$DATE"
  rsync -a --delete -e "ssh -i $MAINT_KEY" setu@$ip:/opt/setu/data/ "$BACKUP_ROOT/$name/$DATE/"
  ssh -i "$MAINT_KEY" root@$ip "sudo systemctl start setu-validator setu-solver"
  # 等待恢复
  for i in {1..30}; do
    curl -sf http://$ip:8080/api/v1/health >/dev/null && break
    sleep 5
  done
done
# 保留最近 4 周
find "$BACKUP_ROOT" -maxdepth 2 -type d -mtime +28 -exec rm -rf {} +
```

```bash
sudo tee /etc/cron.d/setu-backup >/dev/null <<'EOF'
0 4 * * 0 setu /opt/setu-deploy/scripts/snapshot-rocksdb.sh >> /var/log/setu-backup.log 2>&1
EOF
```

---

## 28. Phase 25 — 验收

```bash
cd /opt/setu-src/Setu
bash docs/testnet/testnet-infra/scripts/remote_infra_matrix.sh
```

通过标准：所有 stage `PASS`，无 `FAIL`，`WARN` 仅限已知（如 `SETU_RAW_TRANSFER_API_TOKEN` 未配置导致跳过）。

补充手工验收：

- 关掉任意 1 台 validator，集群仍出块（验证 BFT 容错）
- 重启 validator，自动恢复并追上 DAG
- 在 Grafana 看到所有面板有数据
- 手动触发一条告警（如 `iptables -A INPUT -p tcp --dport 8080 -j DROP`）验证 `probe_success==0` 报警，验证完毕立即恢复

---

## ✅ CHECKPOINT 5 — 测试网正式可用

所有 Phase 完成，验收全部 PASS，监控接入，备份就绪，回滚路径已验证。

---

## 29. 回滚速查

> 优先用 `bash docs/v1/release/rollback.sh <host-alias> <release_id>`：自带 BFT 护栏（先确认其它 N-1 台 health=ok 才动），自动 sha256/ldd 校验、切 symlink、等 health。

| 场景 | 操作 |
|---|---|
| binary 有 bug（首选） | `bash docs/v1/release/rollback.sh val-1 <上一个RELEASE_ID>` |
| binary 有 bug（手工） | `ssh -i ~/.ssh/setu_maint setu@$IP "ln -sfnT /opt/setu/bin/releases/<上一个RELEASE_ID> /opt/setu/bin/current"` 后接 `ssh -i ~/.ssh/setu_maint root@$IP "sudo systemctl restart setu-validator setu-solver"` |
| 配置错误 | 恢复 `/opt/setu/conf/*.bak`，`ssh -i ~/.ssh/setu_maint root@$IP "sudo systemctl restart setu-validator"` |
| 数据损坏 | `ssh -i ~/.ssh/setu_maint root@$IP "sudo systemctl stop setu-validator setu-solver"` → 从 `/opt/setu-backups/<N>/<DATE>/` 恢复 → start |
| SSH 误锁 | 控制台登录、删 `/etc/ssh/sshd_config.d/*` 错改、`systemctl restart ssh` |
| UFW 误锁 | 控制台 `ufw disable` |

> 注意：`ln -sfnT` 操作 symlink 用 `setu` 即可（owner setu），但 `systemctl restart` 必须 `root@`。

---

## 30. 关键风险点（务必复读）

1. `ln -sfnT` 必须带 `-T`，不要预先 `mkdir current`
2. chrony 装前必须 `disable systemd-timesyncd`
3. 监控容器全部绑 `127.0.0.1`，靠 nginx + TLS + basic auth 暴露 Grafana
4. logrotate / sysctl / journald 必须在 Setu 启动之前生效
5. SSH 关密码登录前必须 key 登录验证 + 双终端确认
6. 备份脚本必须**逐台串行**，保留 quorum
7. validator 节点禁止安装 Rust / Docker / 构建工具
8. 任何破坏性变更（升级、回滚、备份）**逐台串行**，不并行

---

## 31. 后续可演进项（非必需）

- Alertmanager + Slack/邮件
- Prometheus 远端写入（长期归档）
- Grafana SSO（替代 basic auth）
- 多可用区部署（当前 3 节点同区，单数据中心故障会同时影响）
- 灰度发布脚本（先升 1 台，观察 24h 再升其余）
