# Setu 测试网 Anti-Spam 完整方案

> 日期：2026-05-29  
> 范围：Setu 公开测试网防滥用的短期止血 + 中期方案  
> 适用环境：`deploy/dev-mult` 三节点测试网（validator-1/2/3）以及后续公开 testnet  
> 状态：方案稿，待评审

---

## 1. 背景与问题

Setu 当前测试网**没有任何经济层 anti-spam**：

- 用户不消耗 gas fee，余额永不扣减；
- `gas_budget` 只是 Move VM 的**执行预算上限**（单笔 PTB 资源天花板），不是付费；
- HTTP API（`/api/v1/move/ptb`、`/api/v1/move/call`、`/api/v1/transfer`、`/api/v1/batch`、各类 `*_register` 等写入口）**裸跑在 `0.0.0.0:8080`**，没有限流、没有身份校验、没有配额；
- `sender` 字段若未强校验签名即被信任，攻击者可以伪造身份。

直接后果：

1. 任意用户/脚本可以无限制提交交易（即便交易内部 budget 受限），耗尽 validator CPU / 内存 / 磁盘 / DAG 带宽；
2. 多 validator 间轮询提交可放大攻击 N 倍；
3. 没有任何用户身份维度，无法定位/封禁滥用者。

详细背景参考 `docs/analysis/gas-functionality-current-state-20260512.md`。

---

## 2. 方案总览

四件套（按上线顺序）：

```
Day 1 ── 网关 + 收口 validator 端口      （止血）
Day 2-N ── faucet 服务 + 签名校验补齐    （建立身份）
最后  ── 内置 AdmissionLimiter           （链路级配额）
```

| 层 | 作用 | 防御对象 |
|---|---|---|
| 网关限流 | per-IP QPS / 并发 / 请求体大小 | 脚本刷量、慢速攻击、超大请求 |
| Faucet | 反女巫 + 签发 short-TTL token + 派发测试币 | 大规模身份伪造、白嫖 |
| 签名校验 | 保证 `sender` 不可伪造 | 借他人身份绕过 quota |
| AdmissionLimiter | per-sender / per-token rpm + 日额 + 在飞上限 + 失败计数 | 已认证用户的滥用 |

业界对照（参见 §8）：这是 EVM L2 公共 RPC 的标准最小组合，覆盖 90%+ 测试网刷量场景。

---

## 3. 当前部署现状（基线）

来自 `deploy/dev-mult/`：

| 节点 | 公网 IP | 监听 |
|---|---|---|
| validator-1 | 173.212.239.161 | HTTP 8080 (0.0.0.0)，P2P 9000 |
| validator-2 | 5.189.163.210   | HTTP 8080 (0.0.0.0)，P2P 9000 |
| validator-3 | 5.189.136.19    | HTTP 8080 (0.0.0.0)，P2P 9000 |

监听地址写在 `setu-validator/src/network/types.rs:55-56`（默认）以及 `deploy/dev-mult/config.sh`、`tps-test-single.sh`（`VALIDATOR_LISTEN_ADDR=0.0.0.0`）。

启动入口 `setu-validator/src/network/service.rs:595` 调用 `TcpListener::bind(http_listen_addr)`，没有任何 axum 中间件做限流。

---

## 4. 阶段 1：Day 1 网关 + 收口端口

### 4.1 目标

- 公网用户**只能**打到 gateway；
- validator 的 8080 **只接受 gateway IP**；
- validator 的 9000 **只接受其它 validator IP**；
- 写接口在 gateway 层有 per-IP 速率与并发上限。

### 4.2 拓扑

```
       用户 / SDK
           │ 443 (HTTPS)
           ▼
   ┌───────────────┐
   │  gateway      │  nginx + 限流 + TLS
   └───────┬───────┘
           │ 8080
   ┌───────┼───────┐
   ▼       ▼       ▼
 v1:8080 v2:8080 v3:8080   ← 仅 gateway IP
 v1:9000 ↔ v2:9000 ↔ v3:9000 ← 仅其它 validator IP
```

### 4.3 步骤

**Step 1 — gateway 机器（10 分钟）**

- 推荐独立 1C2G 小机，故障域隔离，后续 faucet 也部署在此；
- 短期可复用 validator-1，注意 gateway 故障 = validator-1 不可达。

**Step 2 — nginx 配置（1-2 小时）**

`/etc/nginx/conf.d/setu.conf`：

```nginx
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
    listen 443 ssl http2;
    server_name testnet.setu.example;

    ssl_certificate     /etc/letsencrypt/live/testnet.setu.example/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/testnet.setu.example/privkey.pem;

    client_max_body_size 1m;
    client_body_timeout  10s;
    send_timeout         10s;
    proxy_read_timeout   30s;
    limit_conn setu_conn 20;

    # 写接口
    location ~ ^/api/v1/(move/ptb|move/call|transfer|batch|user/register|subnet/register|governance/) {
        limit_req zone=setu_write burst=10 nodelay;
        proxy_pass http://setu_validators;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 读接口
    location /api/v1/ {
        limit_req zone=setu_read burst=100 nodelay;
        proxy_pass http://setu_validators;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location = /api/v1/health { proxy_pass http://setu_validators; }
    location / { return 404; }
}

server { listen 80; return 301 https://$host$request_uri; }
```

TLS（可选 Day 1）：

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d testnet.setu.example
```

**Step 3 — validator 防火墙（30 分钟，最关键）**

每台 validator 上：

```bash
GW_IP=<gateway-public-ip>

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow from $GW_IP to any port 8080 proto tcp

ufw allow from 173.212.239.161 to any port 9000 proto tcp
ufw allow from 5.189.163.210   to any port 9000 proto tcp
ufw allow from 5.189.136.19    to any port 9000 proto tcp

ufw enable
ufw status numbered
```

⚠️ 必须注意：

1. **先在一台上跑通再推全部**，避免一次性锁出 SSH。建议 `ufw --dry-run enable` 先看规则。
2. solver 跨机部署时要为 `solver -> validator` 加白名单；同机走 `127.0.0.1` 不需要。
3. benchmark / SDK 机器直连 validator 立刻不通，必须切到 gateway 或临时加白。

**Step 4 — 收紧监听地址（20 分钟，可选但强烈推荐）**

改 `deploy/dev-mult/config.sh`、`tps-test-single.sh` 等：

```bash
# 原：VALIDATOR_LISTEN_ADDR=0.0.0.0
# 新（内网网卡）
VALIDATOR_LISTEN_ADDR=<内网IP>
```

P2P 9000 仍需绑公网，靠防火墙白名单。

如果 gateway 与 validator 跨机房无内网，HTTP 仍绑公网，**完全依赖防火墙**——必要时再加一层 iptables 双重保险：

```bash
iptables -A INPUT -p tcp --dport 8080 -s $GW_IP -j ACCEPT
iptables -A INPUT -p tcp --dport 8080 -j DROP
```

**Step 5 — 验证（30 分钟）**

```bash
# 从 gateway：应通
curl -fsS https://testnet.setu.example/api/v1/health

# 从外网他机：应不通
curl -v --connect-timeout 5 http://173.212.239.161:8080/api/v1/health
curl -v --connect-timeout 5 http://5.189.163.210:8080/api/v1/health
curl -v --connect-timeout 5 http://5.189.136.19:8080/api/v1/health

# 限流：连发 50 次写接口
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST https://testnet.setu.example/api/v1/move/ptb \
    -H 'content-type: application/json' -d '{}'
done | sort | uniq -c
# 期望：400/422 + 429 混合
```

**Step 6 — 切换客户端（30 分钟）**

- 内部 SDK / `setu-benchmark` / `setu-cli` 默认 URL 改 `https://testnet.setu.example`；
- 通知所有内部使用者，旧 `IP:8080` 当天起不可用；
- 更新 `deploy/dev-mult/README.md` 与对外文档。

### 4.4 Day 1 验收清单

- [ ] 公网扫描 3 台 validator 的 8080，全部不通；
- [ ] 9000 端口只对其它 2 个 validator 开放；
- [ ] gateway 443 可访问，`/api/v1/health` 返回 200；
- [ ] 同 IP 连发 > 5 req/s 写接口看到 429；
- [ ] benchmark 走 gateway 跑一次冒烟，TPS 正常；
- [ ] 3 validator 间 P2P 正常（consensus log 无断连）。

### 4.5 Day 1 不要做

- 不动 Rust 代码（AdmissionLimiter 留到阶段 4）；
- 不动 faucet（独立任务，并行启动）；
- 不上 Cloudflare（先稳定基础链路）；
- nginx 不做 JWT 校验（token 体系尚未定义）。

### 4.6 工作量

实际投入 **4-6 小时**，含一次"被自己锁出 SSH"的概率事件，留半天 buffer。

---

## 5. 阶段 2：Faucet 服务（3-5 天）

### 5.1 职责

1. 反女巫认证：GitHub OAuth / 邮箱 + Captcha（任选其一作 MVP，推荐 GitHub OAuth）；
2. 地址冷却（如 24h 每地址只能领一次）；
3. IP 冷却（同 IP 每小时最多 N 次申请）；
4. 每日额度（per-account、per-IP）；
5. 调 Setu 内置 transfer API 给申请地址打测试币；
6. 签发 short-TTL token（JWT 或 HMAC，TTL 建议 15-60 分钟）；
7. 暴露 `POST /faucet/request`、`POST /faucet/token/refresh`。

### 5.2 技术选型

- 语言：Rust（与 Setu 同栈）或 Node.js（faucet 生态更成熟）；
- 存储：SQLite（单实例足够）或 Redis（多实例时切换）；
- 部署：与 gateway 同机，path 走 `/faucet/*`。

### 5.3 Token 设计

```
HMAC(secret, "{quota_id}|{exp_ts}") = signature
token = base64url({quota_id}.{exp_ts}.{signature})
```

- `quota_id`：faucet 分配的稳定标识（非 Setu sender），与 GitHub user / 邮箱 hash 绑定；
- TTL 短：减少撤销难度，到期重新申请；
- validator 端只校签名 + 过期，无需查数据库（无状态）。

### 5.4 与 AdmissionLimiter 的契约（先定，再开工）

```
请求头：Authorization: Bearer <token>
失败响应：
  401  无 token / token 失效
  403  token 有效但 quota_id 被封
  429  超额
```

### 5.5 风险

- 反女巫策略需产品/运营对齐（GitHub vs 邮箱 vs Discord vs Gitcoin Passport），决策不在 5 天内；
- faucet 自己也要受 gateway 限流，避免被刷爆；
- secret 管理：HMAC key 通过环境变量注入，不入 git。

---

## 6. 阶段 3：签名校验补齐（2-4 天）

### 6.1 目标

所有写入口（PTB、MoveCall、transfer、batch、user/subnet/governance register）都**强校验** `sender` 对应的签名，缺失即拒。

### 6.2 工作项

1. 审计 `setu-validator/src/network/service.rs` 中所有 POST 路由，列出"当前是否校验 sender 签名"的清单；
2. 抽取公共中间件 `verify_sender_signature(req) -> Result<SenderId, _>`，挂在写路由前；
3. 为每个入口补单测：合法签名通过、错误签名 401、缺失签名 401；
4. 更新 SDK 与 benchmark 工具，确保所有请求都带签名（已有的不变）；
5. 在 `tests/smoke` 增加签名失败用例。

### 6.3 风险

- **最容易超期的一项**：不同入口现有签名要求不一致，统一过程容易破坏现有 SDK；
- 必须先把签名格式规范写清（哪些字段进签名、nonce/timestamp 怎么算），再改代码；
- 与 AdmissionLimiter 的 `sender` 来源对齐：limiter 用的应是**校验后的** `SenderId`，不是请求体里的字段。

---

## 7. 阶段 4：AdmissionLimiter（3-5 天）

### 7.1 定位

validator 内的 axum middleware，挂在所有写路由前，**早于** PTB decode / TaskPreparer / TEE / DAG 提交。

### 7.2 接口

```rust
pub struct AdmissionLimiter { /* ... */ }

pub struct AdmissionDecision {
    pub quota_id: QuotaId,
    pub sender:   SenderId,
}

impl AdmissionLimiter {
    pub async fn check(&self, req: &Request) -> Result<AdmissionDecision, AdmissionError>;
    pub async fn record_result(&self, quota_id: &QuotaId, outcome: Outcome);
}

pub enum AdmissionError {
    MissingToken,        // 401
    InvalidToken,        // 401
    TokenExpired,        // 401
    QuotaIdRevoked,      // 403
    RpmExceeded,         // 429
    DailyQuotaExceeded,  // 429
    InFlightExceeded,    // 429
    WireDecodeFailed,    // 400（仍要计数）
}

pub enum Outcome { Success, ClientError, ServerError }
```

### 7.3 策略

| 维度 | 默认值 | 备注 |
|---|---|---|
| per-token rpm | 60 | 可按 quota_id 等级调整 |
| per-token daily | 5000 | 失败也计数 |
| per-token in-flight | 8 | 防慢速堆积 |
| wire decode 失败计数 | ✅ | 防畸形包零成本攻击 |
| ServerError 计数 | ✅（半权重） | 防探测 |

### 7.4 多 validator 一致性

短期靠 gateway 收口实现"逻辑单点"，limiter 在每个 validator 本地 `DashMap` 计数足够；中期接 Redis 共享计数（faucet 同台即可）。

### 7.5 metrics

`admission_total{outcome=...,route=...}`、`admission_inflight{route=...}`，接 Prometheus。

### 7.6 风险

- 接入位置要在 PTB decode **之前**，否则畸形包仍消耗 CPU；
- 失败计数容易漏（client disconnect、超时），需在 axum tower middleware 的 `on_response` / `on_eos` 都覆盖；
- 单机内存计数在 validator 重启后清零——可接受（测试网），上线前明确写在文档里。

---

## 8. 业界做法对照

| 项目 | 主防御 | 副防御 | Setu 是否已具备 |
|---|---|---|---|
| Ethereum Sepolia / Holesky | 真 gas + faucet 主网余额门槛 | 公共 RPC 网关 + API key | ❌ 全部缺 |
| Sui / Aptos / Solana devnet | 真 gas + faucet 地址/IP 冷却 + Captcha | Mysten/Aptos/官方 RPC 网关 | ❌ 全部缺 |
| Cosmos 系测试网 | `min-gas-prices` + 强 nonce | Discord faucet 日额 | ❌ 全部缺 |
| Polkadot Westend/Rococo | 真 fee + faucet quota | 治理白名单 validator | ❌ 全部缺 |
| Filecoin Calibration / Near | 真 fee + faucet quota | API key | ❌ 全部缺 |
| Infura / Alchemy / QuickNode (跨链) | API key + per-key QPS | Cloudflare | ❌ Setu 无 |

**结论**：业界没有任何主流测试网靠"链节点裸奔"。最低限度是 **faucet + gas** 或 **faucet + 网关 + API key**。Setu 当前缺前一种（无 gas），所以只能走后一种。本方案的四件套即等价于 EVM L2 公共 RPC 的标准最小集合。

Setu 中期独立工作（不在本方案，但建议跟进）：

- **强 nonce / per-sender pending 上限**：链层最便宜的 anti-spam，参考 EVM mempool；
- **真实 gas fee + tokenomics**：长期根本解。

---

## 9. 复核：之前结论的修订

| 早期说法 | 复核结论 |
|---|---|
| 阶段 1 = 网关限流，0.5-1.5 天 | ✅ 但必须**同时**收紧 validator 防火墙，否则只加 nginx 无效。 |
| 阶段 2 MVP = 2-4 天 | 偏乐观，真实 3-5 天（Setu 写入口分散）。 |
| 用 sender 字段做限额 | ⚠️ 必须先做阶段 3 签名校验，否则 sender 可伪造。 |
| 失败请求计入 quota | ✅ 且 **wire decode 失败**也要计数，否则畸形包零成本。 |
| JWT/HMAC 离线验证 | ✅ 但 TTL 必须短（15-60min），避免撤销难。 |
| per-token quota 单机内存够 | ⚠️ 仅在 gateway 收口的前提下成立；用户绕过 gateway 直连 validator 时会被 N 倍放大——所以阶段 1 的防火墙是 quota 体系的**前置依赖**。 |

---

## 10. 总工作量与排期

| 阶段 | 内容 | 工作量 | 依赖 |
|---|---|---|---|
| 阶段 1 | 网关 + 收口端口 | 0.5-1 天 | 无（立即可做） |
| 阶段 2 | Faucet 服务 | 3-5 天 | 反女巫策略决策 |
| 阶段 3 | 签名校验补齐 | 2-4 天 | 签名规范文档 |
| 阶段 4 | AdmissionLimiter | 3-5 天 | 阶段 2 token 格式、阶段 3 SenderId |
| 阶段 5 | 集成 + e2e + 文档 | 2-3 天 | 前 4 阶段完成 |

- **MVP（可挡 90% 脚本刷量）**：阶段 1 + 阶段 2 简版 + 阶段 3 关键入口 + 阶段 4 简版 ≈ **6-8 个工作日**
- **稳定可对外发布**：四件套全做完 + 阶段 5 ≈ **11-17 个工作日（2.5-3.5 周）**
- **1 人兼职（50%）**：×2，按 5-7 周排期

并行节奏建议：

```
Day 1            阶段 1（止血）
Day 2 ─┬─ 阶段 2 faucet         （独立）
       └─ 阶段 3 签名审计       （独立）
faucet token 格式定稿后 ── 阶段 4 AdmissionLimiter
全部完成后 ── 阶段 5 集成 + 文档
```

---

## 11. 隐藏成本提醒

- **反女巫策略决策**（GitHub vs 邮箱 vs Discord vs Captcha）需要产品/运营介入，不在以上工作量内；
- **内部生态迁移**：现有 SDK / demo / benchmark / 内部 dashboard 都没带 token，限速一上线全部 429，通知和迁移再算 1-2 天；
- **运维 runbook**：gateway 故障切换、faucet 私钥轮换、token 撤销流程，至少各写一份；
- **多 validator 一致性长期化**：当 testnet 公开扩展到 N 个 validator 时，单机内存 quota 必须升级到共享存储，预留 2-3 天。

---

## 12. 不在本方案的事

- 真实 gas fee / tokenomics（长期解，独立 RFC）；
- 强 nonce 与 mempool 准入策略（链层独立优化）；
- Move VM 真实 gas meter 替换 InstructionCountGasMeter（与 `docs/analysis/gas-functionality-current-state-20260512.md` 跟进项关联）；
- 反 DDoS（L3/L4）——交由 Cloudflare / 云厂商 WAF，本方案不覆盖。

---

## 13. 参考

- `docs/analysis/gas-functionality-current-state-20260512.md`
- `setu-validator/src/network/service.rs`
- `setu-validator/src/network/types.rs`
- `deploy/dev-mult/config.sh`、`deploy/dev-mult/README.md`
- `crates/setu-protocol/src/solver_http.rs`
- `types/src/resource.rs`
