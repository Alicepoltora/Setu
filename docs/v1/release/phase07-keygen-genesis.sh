#!/usr/bin/env bash
# Phase 7 @ ops — 生成 validator key + 渲染 genesis-remote.json
#
# 输入：inventory.env 的 HOSTS / VAL_ALIASES / P2P_PORT / KEY_DIR_LOCAL / GENESIS_LOCAL
# 输出：
#   $KEY_DIR_LOCAL/validator-{1..N}.json   (mode 600, JSON 含 public_key/private_key/mnemonic)
#   $GENESIS_LOCAL                          (chain_id=setu-testnet)
#
# 幂等：若 key 已存在则跳过 keygen；genesis 若已存在则比对差异并提示是否覆盖
source "$(dirname "$0")/lib.sh"
log_step "Phase 7 @ ops：keygen + render genesis"

command -v jq >/dev/null || { log_err "需要 jq：brew install jq / apt install -y jq"; exit 1; }

cd "$SETU_SRC"
source "$HOME/.cargo/env" 2>/dev/null || true

mkdir -p "$KEY_DIR_LOCAL" "$(dirname "$GENESIS_LOCAL")"

# ── 1. 生成 keypair（setu-cli validator keygen） ─────────────────────────────
for i in "${!VAL_ALIASES[@]}"; do
    idx=$((i + 1))
    out="$KEY_DIR_LOCAL/validator-${idx}.json"
    if [ -f "$out" ]; then
        log_warn "$out 已存在，跳过 keygen"
        continue
    fi
    log_info "生成 validator-${idx} keypair"
    cargo run --release -p setu-cli -- validator keygen \
        --output "$out" \
        --id "validator-${idx}"
done
chmod 600 "$KEY_DIR_LOCAL"/validator-*.json
ls -l "$KEY_DIR_LOCAL"

# ── 2. 校验 key 文件结构 ────────────────────────────────────────────────────
for i in "${!VAL_ALIASES[@]}"; do
    idx=$((i + 1))
    key="$KEY_DIR_LOCAL/validator-${idx}.json"
    for field in node_id account_address public_key private_key; do
        if ! jq -e ".$field" "$key" >/dev/null; then
            log_err "$key 缺少字段 .$field"; exit 1
        fi
    done
done
log_ok "key 文件结构 OK"

# ── 3. 渲染 genesis-remote.json ────────────────────────────────────────────
# 默认账户（alice/bob/charlie）地址与 deploy/dev-mult/ 保持一致，方便 CLI 复用
# 余额：100 万 SETU × 10^8 decimals = 100_000_000_000_000 atomic units
# 拆分：每账户 5 个 coin object → 每个 20 万 SETU，便于同发送方并行
ACCOUNT_BALANCE="${ACCOUNT_BALANCE:-100000000000000}"
COINS_PER_ACCOUNT="${COINS_PER_ACCOUNT:-5}"
log_info "默认账户余额：${ACCOUNT_BALANCE} atomic (≈ $((ACCOUNT_BALANCE / 100000000)) SETU)，拆 ${COINS_PER_ACCOUNT} coins"

DEFAULT_ACCOUNTS=$(jq -n \
    --argjson bal "$ACCOUNT_BALANCE" \
    --argjson cpa "$COINS_PER_ACCOUNT" \
    '[
      {address:"0xc0a6c424ac7157ae408398df7e5f4552091a69125d5dfcb7b8c2659029395bdf",name:"alice",  balance:$bal,coins_per_account:$cpa},
      {address:"0xeedf1a9c68b3f4a8b1a1032b2b5ad5c4795c026514f8317c7a215e218dccd6cf",name:"bob",    balance:$bal,coins_per_account:$cpa},
      {address:"0x75bf18e34f9add02a2fe5a146813eb9362372eef6200f3b1dbc3f819671cba69",name:"charlie",balance:$bal,coins_per_account:$cpa}
    ]')

CHAIN_ID="${CHAIN_ID:-setu-testnet}"
TS="${GENESIS_TIMESTAMP:-2026-06-01T00:00:00Z}"

# 收集 validator 数组
VAL_JSON="[]"
for i in "${!VAL_ALIASES[@]}"; do
    idx=$((i + 1))
    alias="${VAL_ALIASES[$i]}"
    ip="$(resolve_host "$alias")"
    pk="$(jq -r '.public_key' "$KEY_DIR_LOCAL/validator-${idx}.json")"
    [ -n "$ip" ] && [[ "$ip" != REPLACE-* ]] || { log_err "HOSTS[$alias] 未配置（$ip）"; exit 1; }
    [ ${#pk} -eq 64 ] || { log_err "validator-${idx} public_key 长度异常：${#pk}"; exit 1; }
    VAL_JSON=$(echo "$VAL_JSON" | jq \
        --arg id "validator-${idx}" \
        --arg addr "$ip" \
        --argjson port "$P2P_PORT" \
        --arg pk "$pk" \
        '. + [{id:$id, address:$addr, p2p_port:$port, public_key:$pk}]')
done

NEW_GENESIS=$(jq -n \
    --arg cid "$CHAIN_ID" \
    --arg ts "$TS" \
    --argjson accs "$DEFAULT_ACCOUNTS" \
    --argjson vals "$VAL_JSON" \
    '{chain_id:$cid, timestamp:$ts, accounts:$accs, subnet_id:"ROOT", validators:$vals}')

if [ -f "$GENESIS_LOCAL" ]; then
    if diff -q <(jq -S . "$GENESIS_LOCAL") <(echo "$NEW_GENESIS" | jq -S .) >/dev/null; then
        log_ok "$GENESIS_LOCAL 已存在且内容一致，跳过写入"
    else
        log_warn "$GENESIS_LOCAL 已存在但内容不一致："
        diff <(jq -S . "$GENESIS_LOCAL") <(echo "$NEW_GENESIS" | jq -S .) || true
        if confirm "覆盖现有 genesis？"; then
            echo "$NEW_GENESIS" | jq . > "$GENESIS_LOCAL"
            log_ok "已覆盖 $GENESIS_LOCAL"
        else
            log_warn "保留现有 genesis，未修改"
        fi
    fi
else
    echo "$NEW_GENESIS" | jq . > "$GENESIS_LOCAL"
    log_ok "写入 $GENESIS_LOCAL"
fi

# ── 4. 最终校验 ─────────────────────────────────────────────────────────────
jq -e '.chain_id and .validators and (.validators | length > 0)' "$GENESIS_LOCAL" >/dev/null \
    || { log_err "genesis JSON 校验失败"; exit 1; }

log_ok "Phase 7 完成"
log_info "key 目录：$KEY_DIR_LOCAL"
log_info "genesis：$GENESIS_LOCAL"
log_warn "确保 .gitignore 已忽略 deploy/testnet/keys/ 与 deploy/testnet/genesis-remote.json"
