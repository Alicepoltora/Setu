#!/bin/bash
# ============================================================================
# Generate validator keypairs and update genesis-remote.json
# Use setu-cli on the build server to generate ed25519 keys
# Usage: ./keygen.sh
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

print_header "Generate Validator Keypairs"

# Check for local jq (needed to update genesis-remote.json)
if ! command -v jq &>/dev/null; then
    print_warn "jq not installed; cannot auto-update public keys in genesis-remote.json"
    echo "  macOS install: brew install jq"
    echo "  Keys will still be generated, but public keys must be updated manually"
    echo ""
fi

# Check that setu-cli exists on the build server
echo "  Checking setu-cli..."
if ! remote_exec "$BUILD_SERVER" "test -f ${REMOTE_BIN}/setu-cli" 2>/dev/null; then
    print_err "setu-cli not found, please run ./build.sh first"
    exit 1
fi

# Generate a key for each validator
PUB_KEYS=()
for i in "${!VALIDATOR_IDS[@]}"; do
    vid="${VALIDATOR_IDS[$i]}"
    host="${SERVERS[$i]}"
    key_file="${REMOTE_KEYS}/${vid}.key"
    
    print_step $((i+1)) ${#VALIDATOR_IDS[@]} "Generating key for ${vid}..."
    
    # Generate the key on the build server
    output=$(remote_exec "$BUILD_SERVER" "
        ${REMOTE_BIN}/setu-cli gen-key generate \
            --scheme ed25519 \
            --output ${REMOTE_KEYS}/${vid}.key \
            --json 2>/dev/null || echo 'KEYGEN_FAILED'
    ")
    
    if echo "$output" | grep -q 'KEYGEN_FAILED'; then
        print_err "Key generation failed: ${vid}"
        exit 1
    fi

    # Extract the public key
    pub_key=$(remote_exec "$BUILD_SERVER" "
        ${REMOTE_BIN}/setu-cli gen-key inspect ${REMOTE_KEYS}/${vid}.key 2>/dev/null \
            | grep -i 'public.*key' | head -1 | awk '{print \$NF}' \
            || echo ''
    ")
    
    # If inspect can't extract it, try the JSON output
    if [ -z "$pub_key" ]; then
        pub_key=$(echo "$output" | jq -r '.public_key // empty' 2>/dev/null || echo "")
    fi

    PUB_KEYS+=("$pub_key")
    echo "    public key: ${pub_key:0:16}..."
    
    # Distribute the key to the corresponding server
    if [ "$i" -ne 0 ]; then
        echo "    → distributing to ${host}"
        remote_exec "$host" "mkdir -p ${REMOTE_KEYS}"
        remote_to_remote_copy "$BUILD_SERVER" "${key_file}" "$host" "${key_file}"
    fi
done

echo ""
print_ok "All keys generated and distributed"

# Update the public_key fields in the local genesis-remote.json
if ! command -v jq &>/dev/null; then
    print_warn "jq not installed, skipping genesis-remote.json update"
    echo "  Please manually fill the following public keys into genesis-remote.json:"
    for i in "${!VALIDATOR_IDS[@]}"; do
        echo "    ${VALIDATOR_IDS[$i]}: ${PUB_KEYS[$i]}"
    done
elif [ ${#PUB_KEYS[@]} -eq ${#VALIDATOR_IDS[@]} ] && [ -n "${PUB_KEYS[0]}" ]; then
    echo ""
    echo "  Updating public keys in genesis-remote.json..."
    
    local_genesis="${SCRIPT_DIR}/genesis-remote.json"
    
    for i in "${!VALIDATOR_IDS[@]}"; do
        vid="${VALIDATOR_IDS[$i]}"
        pk="${PUB_KEYS[$i]}"
        if [ -n "$pk" ]; then
            # Use jq to update the corresponding validator's public_key
            tmp=$(mktemp)
            jq --arg vid "$vid" --arg pk "$pk" \
                '(.validators[] | select(.id == $vid)).public_key = $pk' \
                "$local_genesis" > "$tmp" && mv "$tmp" "$local_genesis"
        fi
    done
    
    print_ok "genesis-remote.json updated"
    echo "  Please re-run ./deploy.sh to distribute the updated config"
else
    print_warn "Failed to obtain some public keys; please update genesis-remote.json manually"
fi
