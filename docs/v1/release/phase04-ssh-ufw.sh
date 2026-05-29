#!/usr/bin/env bash
# Phase 4 — 所有节点：SSH key + UFW + 关密码登录
# ⚠️ 危险阶段：可能锁死自己。脚本会暂停要求人工双终端确认。
# 用法：bash phase04-ssh-ufw.sh <host-alias>
source "$(dirname "$0")/lib.sh"
require_args 1 $# "phase04-ssh-ufw.sh <host-alias>"
HOST="$1"
IP=$(resolve_host "$HOST")

log_step "Phase 4 @ $HOST ($IP)：SSH 加固 + UFW"

# ── 选择本台 host 应用的 MAINT_IPS（分层白名单）────────────────────────────
# 兼容旧 inventory.env（仅有 MAINT_IPS 单数组）：自动落到两个角色。
if [[ "$HOST" == "${GATEWAY_ALIAS:-ops}" ]]; then
    if [ -n "${MAINT_IPS_OPS+x}" ] && [ "${#MAINT_IPS_OPS[@]}" -gt 0 ]; then
        MAINT_LIST=("${MAINT_IPS_OPS[@]}")
    elif [ -n "${MAINT_IPS+x}" ] && [ "${#MAINT_IPS[@]}" -gt 0 ]; then
        log_warn "未配置 MAINT_IPS_OPS，回退到旧的 MAINT_IPS（建议升级到分层白名单）"
        MAINT_LIST=("${MAINT_IPS[@]}")
    else
        log_err "MAINT_IPS_OPS 未定义且 MAINT_IPS 为空，请检查 inventory.env"
        exit 1
    fi
else
    if [ -n "${MAINT_IPS_VAL+x}" ] && [ "${#MAINT_IPS_VAL[@]}" -gt 0 ]; then
        MAINT_LIST=("${MAINT_IPS_VAL[@]}")
    elif [ -n "${MAINT_IPS+x}" ] && [ "${#MAINT_IPS[@]}" -gt 0 ]; then
        log_warn "未配置 MAINT_IPS_VAL，回退到旧的 MAINT_IPS（建议升级到分层白名单）"
        MAINT_LIST=("${MAINT_IPS[@]}")
    else
        log_err "MAINT_IPS_VAL 未定义且 MAINT_IPS 为空，请检查 inventory.env"
        exit 1
    fi
fi

# 安全纱门：MAINT_LIST 不能是占位符，否则 ufw enable 后会锁死
for _ip in "${MAINT_LIST[@]}"; do
    if [[ "$_ip" == *REPLACE* ]] || [[ -z "$_ip" ]]; then
        log_err "MAINT_IPS 仍是占位符 ($_ip)，请在 inventory.env 中填入真实公网 IP/CIDR"
        log_err "继续会在 ufw enable 后锁死 SSH。中止。"
        exit 1
    fi
done

# 提示当前连接的源 IP是否在名单里，防止漏填
my_src_ip=$(who am i 2>/dev/null | awk '{gsub(/[()]/,"",$5); print $5}')
if [ -n "$my_src_ip" ]; then
    hit=0
    for _ip in "${MAINT_LIST[@]}"; do
        # 简化匹配：0.0.0.0/0 必命中；其它只看前缀是否相同（粗略）
        if [ "$_ip" = "0.0.0.0/0" ]; then hit=1; break; fi
        prefix="${_ip%%/*}"
        if [ "$prefix" = "$my_src_ip" ]; then hit=1; break; fi
    done
    if [ "$hit" -eq 0 ]; then
        log_warn "当前 SSH 源 IP $my_src_ip 不在 host=$HOST 的白名单中（可能是 CIDR 段匹配未识别）"
        log_warn "白名单为：${MAINT_LIST[*]}"
        confirm "确认继续？"
    fi
fi
log_warn "本阶段可能锁住 SSH。开始前请确认："
log_warn "  1. ${MAINT_KEY} 私钥本地存在且能登录 ${MAINT_USER}@${IP}"
log_warn "  2. 你能访问 VPS 控制台（紧急救援）"
confirm "已确认，继续？"

# 步骤 4.1：先验证 key 登录可用
log_info "[4.1] 验证 key 登录..."
if mssh "$HOST" "echo key-login-ok" | grep -q key-login-ok; then
    log_ok "key 登录验证通过"
else
    log_err "key 登录失败，请先用 ssh-copy-id 推送 key"
    exit 1
fi

# 步骤 4.2：UFW 规则（先放行 SSH 再 enable）
log_info "[4.2] 配置 UFW 规则..."

# 构造 UFW 规则脚本
UFW_SCRIPT=""
for ip in "${MAINT_LIST[@]}"; do
    UFW_SCRIPT+="sudo ufw allow from ${ip} to any port 22 proto tcp"$'\n'
done

# validator 节点开 P2P 与 HTTP
if [[ "$HOST" =~ ^val- ]]; then
    # HTTP 8080 仅放行 gateway IP（anti-spam 阶段 1）
    # 同时保留 MAINT_LIST 白名单，便于本机调试
    gw_ip=$(resolve_host "${GATEWAY_ALIAS:-ops}")
    UFW_SCRIPT+="sudo ufw allow from ${gw_ip} to any port ${HTTP_PORT} proto tcp"$'\n'
    for mip in "${MAINT_LIST[@]}"; do
        UFW_SCRIPT+="sudo ufw allow from ${mip} to any port ${HTTP_PORT} proto tcp"$'\n'
    done
    for alias in "${VAL_ALIASES[@]}" ops; do
        peer_ip=$(resolve_host "$alias")
        # 跳过自己（可选；ufw 会去重）
        UFW_SCRIPT+="sudo ufw allow from ${peer_ip} to any port ${P2P_PORT} proto tcp"$'\n'
        UFW_SCRIPT+="sudo ufw allow from ${peer_ip} to any port ${P2P_PORT} proto udp"$'\n'
    done
    # 监控抓取端口：node_exporter 9100 / promtail-or-json_exporter 9080，仅放行 ops
    UFW_SCRIPT+="sudo ufw allow from ${gw_ip} to any port 9100 proto tcp"$'\n'
    UFW_SCRIPT+="sudo ufw allow from ${gw_ip} to any port 9080 proto tcp"$'\n'
fi

# ops/gateway 节点：公网开 443（由 phase04b 装 nginx）
if [[ "$HOST" == "${GATEWAY_ALIAS:-ops}" ]]; then
    UFW_SCRIPT+="sudo ufw allow ${GATEWAY_HTTPS_PORT:-443}/tcp"$'\n'
    UFW_SCRIPT+="sudo ufw allow 80/tcp"$'\n'  # certbot HTTP-01 验证
fi
# 默认策略
UFW_SCRIPT+="sudo ufw default deny incoming"$'\n'
UFW_SCRIPT+="sudo ufw default allow outgoing"$'\n'
UFW_SCRIPT+="sudo ufw --force enable"$'\n'
UFW_SCRIPT+="sudo ufw status verbose"$'\n'

echo "$UFW_SCRIPT" | mssh "$HOST" "bash -s"
log_ok "UFW 已 enable"

# 步骤 4.3：关密码登录前的双终端验证
log_warn "[4.3] 即将关闭 SSH 密码登录。"
log_warn "请打开第二个终端，执行以下命令并确认成功："
echo "    ssh -i ${MAINT_KEY} ${MAINT_USER}@${IP} \"echo still-ok\""
confirm "第二个终端 key 登录成功？"

# 步骤 4.4：sshd drop-in（避免 /etc/ssh/sshd_config.d/50-cloud-init.conf 覆盖）
log_info "[4.4] 写 sshd drop-in /etc/ssh/sshd_config.d/99-setu-hardening.conf..."
mssh "$HOST" "bash -s" <<'REMOTE'
set -euo pipefail
sudo cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.before-setu
sudo tee /etc/ssh/sshd_config.d/99-setu-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t   # 语法检查
sudo systemctl restart ssh
REMOTE

log_warn "[4.5] 请在第二个终端再次验证可登录："
echo "    ssh -i ${MAINT_KEY} ${MAINT_USER}@${IP} \"echo after-restart-ok\""
confirm "新会话仍可登录？"

# 步骤 4.5b：fail2ban（仅当本台 host 的 22 对全网开放时强制装；其它情况建议装）
log_info "[4.5b] 安装 fail2ban（防 SSH 暴力扫描）..."
mssh "$HOST" "bash -s" <<'REMOTE'
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
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
sudo systemctl restart fail2ban
# 等 socket 就绪后再自检（最多 15s）
for i in $(seq 1 15); do
    if sudo fail2ban-client ping >/dev/null 2>&1; then break; fi
    sleep 1
done
sudo fail2ban-client status sshd >/dev/null
REMOTE
log_ok "fail2ban 已启用（sshd jail: 10m 内失败 5 次封 1h）"

# 步骤 4.6：journald 限额（避免日志无限增长）
log_info "[4.6] 配置 journald 限额（2G / 14day）..."
mssh "$HOST" "bash -s" <<'REMOTE'
set -euo pipefail
sudo install -d -m 755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/setu.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald
REMOTE
log_ok "journald 限额已生效"

log_ok "Phase 4 完成 @ $HOST"
