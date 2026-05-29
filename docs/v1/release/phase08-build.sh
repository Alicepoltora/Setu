#!/usr/bin/env bash
# Phase 8 — ops：编译 Move stdlib + cargo build release，打包 artifact
# 用法：bash phase08-build.sh
# 输出：$SETU_BUILD_ROOT/<RELEASE_ID>/，并将 RELEASE_ID 写入 ./LAST_RELEASE_ID
source "$(dirname "$0")/lib.sh"
log_step "Phase 8 @ ops：编译 + 打包"

cd "$SETU_SRC"
source "$HOME/.cargo/env"

# ── 1. 编 Move stdlib（强依赖，不可跳过） ──────────────────────────────────
log_info "[1/3] 编译 Move stdlib..."
if [ -x "./scripts/build_stdlib.sh" ]; then
    bash ./scripts/build_stdlib.sh
elif [ -x "./tools/move-compile/build.sh" ]; then
    bash ./tools/move-compile/build.sh
else
    log_err "找不到 stdlib 编译脚本（scripts/build_stdlib.sh 或 tools/move-compile/build.sh）"
    exit 1
fi

if ! ls setu-framework/compiled/*.mv >/dev/null 2>&1; then
    log_err "stdlib 编译失败：未找到 setu-framework/compiled/*.mv"
    exit 1
fi
log_ok "stdlib 编译完成"

# ── 2. 编 Rust release ─────────────────────────────────────────────────────
log_info "[2/3] cargo build --release（features: ${CARGO_FEATURES}）..."
cargo build --release \
  --features "$CARGO_FEATURES" \
  -p setu-validator -p setu-solver -p setu-cli -p setu-benchmark

# 注意：setu-validator 未使用 clap，--version/--help 都会被忽略并直接启动节点，
# 因此用 file/ls 做最小烟雾测试，真正的二进制有效性由下面的 strings 校验保证。
# 注：setu-cli 这个 package 的二进制产物名为 `setu`（见 setu-cli/Cargo.toml [[bin]]）
ls -lh ./target/release/setu-validator ./target/release/setu-solver ./target/release/setu
file ./target/release/setu-validator | grep -q ELF || { log_err "setu-validator 不是 ELF 可执行文件"; exit 1; }

# ── 2.5 V1 ACCEPT 硬性校验：diag-root-drift 探针字符串必须存在 ─────────────
# 来源：docs/release-doc/test-v1-inner/02-build-and-deploy-flags.md
# 缺失任一即认为该二进制不是 V1 ACCEPT 的版本，拒绝继续打包
log_info "[2.5/3] 校验 diag-root-drift 探针字符串..."
MISSING_DIAG=()
# 注意：必须用 grep -c 而非 grep -q：本脚本启用 set -o pipefail，
# grep -q 命中后立即关闭管道，strings 收到 SIGPIPE 退出非零，整条 pipeline 被判失败。
DIAG_STRINGS=$(strings target/release/setu-validator)
for sym in leader_root_self_mismatch follower_post_apply_root_drift apply_state_change_out_of_band; do
    if [ "$(printf '%s\n' "$DIAG_STRINGS" | grep -c -F "$sym")" -eq 0 ]; then
        MISSING_DIAG+=("$sym")
    fi
done
if [ "${#MISSING_DIAG[@]}" -gt 0 ]; then
    log_err "setu-validator 二进制缺失 diag-root-drift 探针：${MISSING_DIAG[*]}"
    log_err "请确认 inventory.env 中 CARGO_FEATURES 包含 diag-root-drift 并重新编译"
    exit 1
fi
log_ok "diag-root-drift 3 个探针字符串均存在"

# ── 3. 打包 ─────────────────────────────────────────────────────────────────
RELEASE_ID=$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)
STAGE="${SETU_BUILD_ROOT}/${RELEASE_ID}"
log_info "[3/3] 打包到 $STAGE"

mkdir -p "$STAGE"
# 在 cd 之前预先计算 LAST_RELEASE_ID 的写入路径，避免 readlink -f "$0" 在 cd 后解析到 STAGE。
LAST_ID_FILE="$(dirname "$(readlink -f "$0")")/LAST_RELEASE_ID"
cp target/release/setu-validator "$STAGE/"
cp target/release/setu-solver    "$STAGE/"
cp target/release/setu              "$STAGE/setu-cli"
cp -r setu-framework/compiled    "$STAGE/move-stdlib"

cd "$STAGE"
sha256sum setu-validator setu-solver setu-cli > SHA256SUMS
find move-stdlib -type f -exec sha256sum {} \; >> SHA256SUMS

cat > release.info <<EOF
release_id=$RELEASE_ID
git_commit=$(git -C "$SETU_SRC" rev-parse HEAD)
git_branch=$(git -C "$SETU_SRC" rev-parse --abbrev-ref HEAD)
features=$CARGO_FEATURES
built_at=$(date -u +%FT%TZ)
built_by=$USER
built_on=$(hostname)
EOF

# 记录 LAST_RELEASE_ID 供 phase09 自动读取（路径在 cd 之前已预先求出）
echo "$RELEASE_ID" > "$LAST_ID_FILE"

log_ok "Phase 8 完成"
log_info "RELEASE_ID = $RELEASE_ID"
log_info "下一步：bash phase09-distribute-binary.sh   # 自动读 LAST_RELEASE_ID"
