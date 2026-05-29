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

./target/release/setu-validator --version

# ── 2.5 V1 ACCEPT 硬性校验：diag-root-drift 探针字符串必须存在 ─────────────
# 来源：docs/release-doc/test-v1-inner/02-build-and-deploy-flags.md
# 缺失任一即认为该二进制不是 V1 ACCEPT 的版本，拒绝继续打包
log_info "[2.5/3] 校验 diag-root-drift 探针字符串..."
MISSING_DIAG=()
for sym in leader_root_self_mismatch follower_post_apply_root_drift apply_state_change_out_of_band; do
    if ! strings target/release/setu-validator | grep -q "$sym"; then
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
cp target/release/setu-validator "$STAGE/"
cp target/release/setu-solver    "$STAGE/"
cp target/release/setu-cli       "$STAGE/"
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

# 记录 LAST_RELEASE_ID 供 phase09 自动读取
echo "$RELEASE_ID" > "$(dirname "$(readlink -f "$0")")/LAST_RELEASE_ID"

log_ok "Phase 8 完成"
log_info "RELEASE_ID = $RELEASE_ID"
log_info "下一步：bash phase09-distribute-binary.sh   # 自动读 LAST_RELEASE_ID"
