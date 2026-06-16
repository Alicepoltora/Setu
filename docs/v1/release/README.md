# Setu Testnet 部署脚本集（最小可用版）

> 配套手册：[testnet-server-install-runbook-minimal-20260529.md](../testnet-server-install-runbook-minimal-20260529.md)
> 使用前提：已在 ops 上 clone 仓库，已用 root/sudo 用户能 ssh 到 3 台 validator

---

## 1. 总览

所有脚本设计为在 **ops 节点**上执行；脚本内部通过 `ssh` 操作远端 validator。每个脚本对应手册一个 Phase。

| 脚本 | 对应 Phase | 执行对象 | 是否需要逐台串行 |
|---|---|---|---|
| `phase01-base.sh <host>` | Phase 1 基础工具 | 单台远端 | 否 |
| `phase02-chrony.sh <host>` | Phase 2 时间同步 | 单台远端 | 否 |
| `phase03-user-dirs.sh <host>` | Phase 3 用户/目录 | 单台远端 | 否 |
| `phase04-ssh-ufw.sh <host>` | Phase 4 SSH+UFW | 单台远端 | **是**（且双终端验证） |
| `phase04b-gateway.sh` | Phase 4b nginx 网关+限流 | gateway（默认 ops） | — |
| `phase05-validator-runtime.sh <host>` | Phase 5 运行时调优 | 单台 validator | 否 |
| `phase06-ops-toolchain.sh` | Phase 6 编译工具链 | ops 本机 | — |
| `phase07-keygen-genesis.sh` | Phase 7 keygen+genesis | ops 本机 | — |
| `phase08-build.sh` | Phase 8 编译 | ops 本机 | — |
| `phase09-distribute-binary.sh <release_id>` | Phase 9 分发 binary | ops→所有 validator | — |
| `phase10-distribute-config.sh` | Phase 10 分发 genesis+key | ops→所有 validator | — |
| `phase11-systemd-start.sh` | Phase 11 systemd+启动 | ops→所有 validator（串行） | **是** |
| `phase12-verify.sh` | Phase 12 验收+监控 | ops 本机 | — |
| `phase13-monitoring.sh` | Phase 13 监控栈（可选） | ops 本机 + docker compose | — |
| `health_probe.sh` | 监控（cron 调用） | ops 本机 | — |
| `rollback.sh <host> <release_id>` | 回滚 | ops→单台 validator | — |

---

## 2. 准备工作

```bash
cp inventory.env.example inventory.env
vim inventory.env       # 填入 IP / SSH 用户 / 维护 IP 等
chmod +x *.sh
```

`inventory.env` **禁止入仓库**。在脚本同目录会自动 source。

### 2.1 SSH bootstrap（phase01 之前必须完成）

phase01+ 都以 `${MAINT_USER}@<host>` 身份用 key 登录。运行它们之前必须先拿着初始 root 密码把 `${MAINT_KEY}.pub` 推到全部 4 台机器——**这是整套流程唯一需要输入密码的环节**。

```bash
source ./inventory.env

# 1) 准备维护密钥（已有则跳过）
[ -f "$MAINT_KEY" ] || ssh-keygen -t ed25519 -f "$MAINT_KEY" -C "setu-testnet-maint"

# 2) 若设了 passphrase，加进 ssh-agent，避免后续 phase 反复弹窗
eval "$(ssh-agent -s)" && ssh-add "$MAINT_KEY"

# 3) 逐台推 key（每台提示一次 root 密码）
for h in val-1 val-2 val-3 ops; do
    ip="${HOSTS[$h]}"
    echo "=== ssh-copy-id $h ($ip) ==="
    ssh-copy-id -i "${MAINT_KEY}.pub" "${MAINT_USER}@${ip}"
done

# 4) 验证 key 登录（不应再问密码）
for h in val-1 val-2 val-3 ops; do
    mssh "$h" "hostname; uptime" || { echo "FAIL: $h"; exit 1; }
done
```

4 台都正常打印 hostname 才能进阶段 A。

> ⚠️ 若 ssh-copy-id 直接报 `Permission denied (publickey)`，说明服务器 sshd 默认就禁了密码登录。需要先在 Contabo 控制台 VNC/Web Console 登录，临时把 `/etc/ssh/sshd_config` 改 `PasswordAuthentication yes` + `systemctl restart ssh`，推完 key 后 phase04 会重新关掉。详见 runbook §7.4。

---

## 3. 推荐执行顺序

```bash
# === 阶段 A：4 台节点基础环境（顺序无要求，可并行） ===
for h in val-1 val-2 val-3 ops; do bash phase01-base.sh $h; done
for h in val-1 val-2 val-3 ops; do bash phase02-chrony.sh $h; done
for h in val-1 val-2 val-3 ops; do bash phase03-user-dirs.sh $h; done

# === 阶段 B：SSH 加固（必须逐台串行 + 双终端验证） ===
bash phase04-ssh-ufw.sh val-1     # 完成 + 双终端验证 OK 后才动下一台
bash phase04-ssh-ufw.sh val-2
bash phase04-ssh-ufw.sh val-3
bash phase04-ssh-ufw.sh ops

# === 阶段 B'：网关（anti-spam 阶段 1）===
# 在 phase04 之后、phase11 启动 validator 之前执行。
# 它会在 gateway 装 nginx，并依赖 phase04 已把 HTTP_PORT 限制为 GATEWAY_IP 可达。
bash phase04b-gateway.sh

# === 阶段 C：validator 调优 ===
for h in val-1 val-2 val-3; do bash phase05-validator-runtime.sh $h; done

# === 阶段 D：ops 编译环境 + 构建 ===
bash phase06-ops-toolchain.sh
bash phase07-keygen-genesis.sh
bash phase08-build.sh            # 输出 RELEASE_ID 记下来

# === 阶段 E：分发 + 启动 ===
bash phase09-distribute-binary.sh <RELEASE_ID>
bash phase10-distribute-config.sh
bash phase11-systemd-start.sh    # 内部已串行启动

# === 阶段 F：验收 ===
bash phase12-verify.sh

# === 阶段 G（可选）：监控栈 ===
# 前置：phase06 已在 ops 装上 docker + compose；phase01 已在 4 台装上 node_exporter。
# Loki 暂未启用（无日志 shipper）。详见脚本开头注释。
read -rsp 'grafana admin pw: ' GRAFANA_ADMIN_PASSWORD; echo; export GRAFANA_ADMIN_PASSWORD
bash phase13-monitoring.sh
```

---

## 4. 重要原则

1. **`phase04` 必须人在场**：UFW + sshd 改动可能锁住自己。脚本会在关键步骤暂停，要求你**在第二个终端确认 key 仍能登录**。
2. **`phase11` 内部串行**：1 号 health=ok 才启 2 号，依此类推。
3. **`phase09` 切换 symlink 前会自动校验** sha256 + ldd + `--version`，任一失败立刻停止。
4. **inventory.env 是唯一配置入口**，所有脚本读取它，不要在脚本内 hardcode。
5. **公网入口只走 gateway**：phase04 已把三台 validator 的 8080 限制为仅 `GATEWAY_ALIAS` 可达；phase04b 装 nginx + 限流 + 可选 TLS。外网应仅能通过 gateway 的 443 访问 `/api/v1/*`。

### 4.1 公网流量、IP 记录与限流

- **唯一对外 IP**：`ops`（=gateway）的 443/80。validator 8080 在 UFW 层只放 `GATEWAY_ALIAS` 和 `MAINT_IPS`，普通用户直连 timeout。
- **访问日志**：`/var/log/nginx/setu-access.log`，自定义 `setu_main` 格式，记录
  `$remote_addr / request / status / $request_time / $upstream_response_time / $limit_req_status / $request_id`，
  保留 30 天（phase04b 同时下发 `/etc/logrotate.d/setu-nginx`）。
- **per-IP 限流**（由 phase04b 渲染 nginx 配置，可在 `inventory.env` 调）：

  | 维度 | 默认值 | 超限响应 |
  |---|---|---|
  | 写接口 (`/transfer` `/batch` `/move/*` `/user/register` `/subnet/register` `/governance/*`) | `5r/s` + burst 10 | HTTP 429 |
  | 读接口 (其余 `/api/v1/*`) | `50r/s` + burst 100 | HTTP 429 |
  | 同 IP 并发连接 | 20 | HTTP 503 |
  | 请求体大小 | 1 MB | HTTP 413 |

- **触发限流的 IP** 出现在 access log 的 `limit_req=REJECTED` / `limit_conn=REJECTED` 字段，可用
  `awk '$0 ~ /limit_req=REJECTED/ {print $1}' /var/log/nginx/setu-access.log | sort | uniq -c | sort -rn | head` 排行。
- ⚠️ **CDN/反代警告**：当前 `$remote_addr` 是直连 IP。若将来在 gateway 前再加一层 Cloudflare / CF Tunnel / ALB，
  所有请求源 IP 都会变成 CDN 回源 IP，限流瞬间失效（反而打死自己）。必须同时在 `phase04b-gateway.sh` 渲染的 `server {}` 内补：
  ```nginx
  set_real_ip_from <CDN-IP-CIDR>;   # 重复一次/段
  real_ip_header X-Forwarded-For;
  real_ip_recursive on;
  ```
### 4.2 phase11 完成后的公网入口终验

phase04b 在 phase11 之前跑，health 探测不可避免地 502（validator 还未起）。phase11 走完后才能真正验证入口贯通：

```bash
# 设置入口 URL：有 GATEWAY_DOMAIN 用 https，没有就用 ops IP 的 http
source inventory.env
. ./lib.sh
GW_IP=$(resolve_host "${GATEWAY_ALIAS:-ops}")
if [ -n "$GATEWAY_DOMAIN" ] && [[ "$GATEWAY_DOMAIN" != REPLACE-* ]]; then
    URL="https://${GATEWAY_DOMAIN}"
else
    URL="http://${GW_IP}"
fi

# 1) 公网 → gateway → validator 贯通
curl -fsS "$URL/api/v1/health" | jq '{status,validator_count,solver_count}'

# 2) 外网直扫 validator 8080 应全部 timeout/拒绝
for h in "${VAL_ALIASES[@]}"; do
    ip=$(resolve_host "$h")
    curl -v --connect-timeout 5 "http://${ip}:${HTTP_PORT}/api/v1/health" 2>&1 \
        | grep -E 'Connected|timed out|refused' | head -1
done

# 3) 写接口限流生效验证（连发 50 次应该看到大量 429）
for i in $(seq 1 50); do
    curl -s -o /dev/null -w '%{http_code}\n' \
        -X POST "$URL/api/v1/transfer" \
        -H 'content-type: application/json' -d '{}'
done | sort | uniq -c
```
---

## 5. 升级与回滚

### 5.1 升级（新 binary）

```bash
bash phase08-build.sh                       # 生成新 RELEASE_ID（写入 LAST_RELEASE_ID）
bash phase09-distribute-binary.sh            # 仅分发，不重启；自动检查 sha256/ldd/--version
bash phase11-systemd-start.sh --restart      # 串行重启，1 台 health=ok 才动下一台
```

**重要**：phase09 只切了 symlink，不重启服务。必须跟 `phase11 --restart` 才生效。

### 5.2 回滚单台

```bash
# 查询某节点的可用 release
ssh setu@val-1 "ls -1t /opt/setu/bin/releases | head -5"

# 切回某个 release
bash rollback.sh val-1 20260530-103000-abc1234
```

脚本会在动手前检查其它两台 health，防止一次打倒 BFT。

---

## 6. 升级到完整版

当出现"外部用户在用 / 需要告警 / 团队 > 1 人"时，按手册 §17 顺序补齐 Prometheus/Grafana/Loki/备份/nginx 等。
