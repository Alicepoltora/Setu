#!/usr/bin/env bash
# Phase 6 — ops：编译工具链 + Rust
# 用法：bash phase06-ops-toolchain.sh
# 注意：本脚本在 ops 本机执行（ssh 自己），不通过 ssh
source "$(dirname "$0")/lib.sh"

log_step "Phase 6 @ ops：编译工具链 + Rust"

# 通过比对本机所有 IP 是否包含 inventory 中 ops 的 IP 来判定
ops_ip=$(resolve_host ops 2>/dev/null || true)
if [ -n "$ops_ip" ]; then
    local_ips=$(hostname -I 2>/dev/null || ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1)
    if ! echo "$local_ips" | tr ' ' '\n' | grep -qx "$ops_ip"; then
        log_warn "本机 IP 不含 ops 的 IP ($ops_ip)，确认你在 ops 节点上执行"
        confirm "继续？"
    fi
fi

# ── 系统依赖 ────────────────────────────────────────────────────────────────
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential pkg-config libssl-dev \
  clang cmake protobuf-compiler

# ── Rust（按 repo 的 rust-toolchain.toml 安装） ────────────────────────────
if ! command -v rustup >/dev/null; then
    log_info "安装 rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"

# ── repo 准备 ───────────────────────────────────────────────────────────────
if [ ! -d "$SETU_SRC/.git" ]; then
    log_err "未找到 repo：$SETU_SRC"
    log_err "请先 git clone <repo-url> $SETU_SRC"
    exit 1
fi
cd "$SETU_SRC"

# 触发 rust-toolchain.toml 自动安装
rustup show
rustc --version
cargo --version

log_ok "Phase 6 完成。Rust: $(rustc --version)"
