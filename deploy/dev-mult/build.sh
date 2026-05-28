#!/bin/bash
# ============================================================================
# Build + distribute: sync source to build server, cargo build, distribute binaries to all nodes
# Usage: ./build.sh [--skip-sync] [--skip-distribute]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

SKIP_SYNC=false
SKIP_DIST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-sync)       SKIP_SYNC=true; shift ;;
        --skip-distribute) SKIP_DIST=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Expand CARGO_FEATURES LOCALLY (not inside the remote heredoc). ssh does not
# forward env vars, so ${CARGO_FEATURES} must be interpolated before the
# command is sent over the wire.
LOCAL_FEATURE_FLAGS=""
if [ -n "${CARGO_FEATURES:-}" ]; then
    LOCAL_FEATURE_FLAGS="--features ${CARGO_FEATURES}"
fi

SOURCE_FINGERPRINT_TOOL="${SCRIPT_DIR}/source_fingerprint.py"
LOCAL_SOURCE_FINGERPRINT="$(python3 "${SOURCE_FINGERPRINT_TOOL}" "${PROJECT_DIR}")"
LOCAL_GIT_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

copy_remote_artifact_atomically() {
    local host="$1"
    local artifact="$2"
    local executable="${3:-0}"
    local tmp_path="${REMOTE_BIN}/.${artifact}.new.$$"
    local attempt

    for attempt in 1 2 3 4 5; do
        if remote_to_remote_copy "$BUILD_SERVER" "${REMOTE_BIN}/${artifact}" "$host" "$tmp_path"; then
            if [ "$executable" = "1" ]; then
                if remote_exec "$host" "chmod +x '${tmp_path}' && mv -f '${tmp_path}' '${REMOTE_BIN}/${artifact}'"; then
                    return 0
                fi
            elif remote_exec "$host" "mv -f '${tmp_path}' '${REMOTE_BIN}/${artifact}'"; then
                return 0
            fi
        fi

        print_warn "${host}: failed to distribute ${artifact}, retry ${attempt}/5"
        sleep 5
    done

    print_err "${host}: failed to distribute ${artifact}"
    return 1
}

# Single-rsync distribution: pushes all requested artifacts from BUILD_SERVER
# to target host in ONE ssh connection instead of N. rsync writes each file to
# a hidden tmp then renames (atomic per file), so we still get the same
# crash-safety as copy_remote_artifact_atomically without N handshakes.
# Returns 0 on success, non-zero if rsync missing or transfer failed; caller
# should fall back to copy_remote_artifact_atomically.
distribute_bundle_via_rsync() {
    local host="$1"
    shift
    local artifacts=("$@")
    local rsync_check
    rsync_check="$(remote_exec "$BUILD_SERVER" "command -v rsync >/dev/null 2>&1 && echo ok || echo missing" 2>/dev/null | tr -d '[:space:]')"
    if [ "$rsync_check" != "ok" ]; then
        return 2
    fi

    local file_args=""
    local f
    for f in "${artifacts[@]}"; do
        file_args="${file_args} '${REMOTE_BIN}/${f}'"
    done

    local attempt
    for attempt in 1 2 3; do
        if remote_exec "$BUILD_SERVER" "
            SSHPASS='${SSH_PWD}' rsync -az --partial \\
                -e 'sshpass -e ssh ${INNER_SSH_OPTS}' \\
                ${file_args} \\
                '${SSH_USER}@${host}:${REMOTE_BIN}/'
        "; then
            return 0
        fi
        print_warn "${host}: rsync distribution failed, retry ${attempt}/3"
        sleep 5
    done
    return 1
}

print_header "Setu Build & Distribute"
echo "  Source fingerprint: ${LOCAL_SOURCE_FINGERPRINT}"
echo "  Git commit: ${LOCAL_GIT_COMMIT}"
if [ -n "$LOCAL_FEATURE_FLAGS" ]; then
    echo "  Feature flags: ${LOCAL_FEATURE_FLAGS}"
fi

# ── Step 1: Sync source to build server ──────────────────────────────────
if [ "$SKIP_SYNC" = false ]; then
    print_step 1 5 "Syncing source to build server (${BUILD_SERVER})..."
    
    # Ensure remote source directory exists
    remote_exec "$BUILD_SERVER" "mkdir -p ${REMOTE_SRC}"
    
    remote_sync "${PROJECT_DIR}/" "$BUILD_SERVER" "${REMOTE_SRC}/"
    print_ok "Source sync complete"
else
    print_step 1 5 "Skipping source sync"
fi

# ── Step 2: Compile Move stdlib bytecode ───────────────────────────────
# The validator binary embeds setu-framework/compiled/*.mv at compile time.
# The build server regenerates these files from setu-framework/sources/ before
# cargo build so the remote binary always carries the current stdlib bytecode.
print_step 2 5 "Compiling Move stdlib (.mv bytecode)..."
remote_exec "$BUILD_SERVER" "
    set -eo pipefail
    source \"\$HOME/.cargo/env\" 2>/dev/null || true
    cd ${REMOTE_SRC}

    # Build move-compile if not present
    if [ ! -x tools/move-compile/target/release/move-compile ]; then
        echo '  building tools/move-compile...'
        (cd tools/move-compile && cargo build --release --quiet)
    fi

    # Compile setu-framework sources → compiled/*.mv
    mkdir -p setu-framework/compiled
    ./tools/move-compile/target/release/move-compile \\
        setu-framework/sources \\
        --out setu-framework/compiled \\
        --addr setu=0x1 \\
        --addr std=0x1

    # Sanity: must have at least 15 .mv files now (matches build.rs modules[] list)
    count=\$(ls setu-framework/compiled/*.mv 2>/dev/null | wc -l)
    if [ \"\$count\" -lt 15 ]; then
        echo \"FATAL: only \$count .mv files compiled, expected >=15\"
        exit 1
    fi
    echo \"  ✓ \$count stdlib modules compiled\"
"
print_ok "stdlib compilation complete"

# ── Step 3: Remote compile ────────────────────────────────────────────────
print_step 3 5 "Compiling on build server (release)..."
echo "  Build targets: setu-validator, setu-solver, setu-cli, setu-benchmark"
echo "  (First-time build may take 20-40 minutes, please be patient...)"

if [ -n "$LOCAL_FEATURE_FLAGS" ]; then
    echo "  [build] forwarding feature flags to remote: ${LOCAL_FEATURE_FLAGS}"
fi

remote_exec "$BUILD_SERVER" "
    set -eo pipefail
    source \"\$HOME/.cargo/env\" 2>/dev/null || true
    cd ${REMOTE_SRC}

    # Optional diag feature for validator only. Solver/cli/benchmark don't
    # declare this feature, so we must split into two cargo invocations.
    FEATURE_FLAGS='${LOCAL_FEATURE_FLAGS}'
    if [ -n \"\$FEATURE_FLAGS\" ]; then
        echo \"  [build] validator uses \$FEATURE_FLAGS\"
    fi

    # validator — carries optional feature
    cargo build --release \\
        -p setu-validator \\
        \$FEATURE_FLAGS \\
        2>&1

    # solver / cli / benchmark — never carry the feature
    cargo build --release \\
        -p setu-solver \\
        -p setu-cli \\
        -p setu-benchmark \\
        2>&1
"
print_ok "Compilation complete"

# ── Step 4: Copy binaries to bin directory ───────────────────────────────
print_step 4 5 "Installing binaries on build server..."
remote_exec "$BUILD_SERVER" "
    set -eo pipefail
    install_bin() {
        name=\"\$1\"
        src=\"${REMOTE_SRC}/target/release/\${name}\"
        tmp=\"${REMOTE_BIN}/.\${name}.new.\$\$\"
        cp \"\$src\" \"\$tmp\"
        chmod +x \"\$tmp\"
        mv -f \"\$tmp\" \"${REMOTE_BIN}/\${name}\"
    }

    install_bin setu-validator
    install_bin setu-solver
    if [ -f ${REMOTE_SRC}/target/release/setu-cli ]; then install_bin setu-cli; fi
    if [ -f ${REMOTE_SRC}/target/release/setu-benchmark ]; then install_bin setu-benchmark; fi

    cat > ${REMOTE_BIN}/setu-build-info.env <<'EOF'
SETU_SOURCE_FINGERPRINT=${LOCAL_SOURCE_FINGERPRINT}
SETU_GIT_COMMIT=${LOCAL_GIT_COMMIT}
SETU_FEATURE_FLAGS=${LOCAL_FEATURE_FLAGS}
SETU_BUILD_TIME_UTC=${BUILD_TIME_UTC}
EOF

    ls -lh ${REMOTE_BIN}/
    cat ${REMOTE_BIN}/setu-build-info.env
"
print_ok "Build server (${BUILD_SERVER}) binaries ready"

# ── Step 5: Distribute to other servers ─────────────────────────────────────
if [ "$SKIP_DIST" = false ]; then
    print_step 5 5 "Distributing binaries to other servers..."
    for i in "${!SERVERS[@]}"; do
        if [ "$i" -eq 0 ]; then
            continue  # Skip the build server itself
        fi
        local_host="${SERVERS[$i]}"
        echo "    → ${VALIDATOR_IDS[$i]} (${local_host})"

        # Ensure remote directory exists
        remote_exec "$local_host" "mkdir -p ${REMOTE_BIN}"

        # Collect artifacts that actually exist (optional binaries may be missing)
        bundle=(setu-validator setu-solver setu-build-info.env)
        for opt in setu-cli setu-benchmark; do
            if remote_exec "$BUILD_SERVER" "[ -f '${REMOTE_BIN}/${opt}' ]" 2>/dev/null; then
                bundle+=("$opt")
            fi
        done

        # Preferred: distribute all artifacts in a single rsync (1 SSH connection vs N)
        if distribute_bundle_via_rsync "$local_host" "${bundle[@]}"; then
            print_ok "${local_host}: rsync distributed ${#bundle[@]} artifact(s) successfully"
        else
            print_warn "${local_host}: rsync unavailable or failed, falling back to per-file scp"
            # Critical binaries: error if they fail
            for bin_name in setu-validator setu-solver; do
                copy_remote_artifact_atomically "$local_host" "$bin_name" 1
            done
            # Optional binaries: silently skip on failure
            for bin_name in setu-cli setu-benchmark; do
                copy_remote_artifact_atomically "$local_host" "$bin_name" 1 2>/dev/null || true
            done
            copy_remote_artifact_atomically "$local_host" "setu-build-info.env" 0
        fi

        remote_exec "$local_host" "chmod +x ${REMOTE_BIN}/setu-validator ${REMOTE_BIN}/setu-solver 2>/dev/null; chmod +x ${REMOTE_BIN}/setu-cli ${REMOTE_BIN}/setu-benchmark 2>/dev/null; true"
    done
    print_ok "Binary distribution complete"
else
    print_step 5 5 "Skipping binary distribution"
fi

echo ""
print_ok "Build complete!"
echo ""
echo "  Binary location: ${REMOTE_BIN}/"
echo "  Next step: ./deploy.sh   # Distribute config and start"
