//! Durable anti-replay marker for V2 user-signed transfers (design D4).
//!
//! Every admitted V2 transfer consumes a `(from, client_nonce)` idempotency
//! key by creating a marker object in ROOT state as part of the transfer
//! event's state changes. Admission rejects a request whose marker already
//! exists; concurrent duplicates are resolved by the apply-layer
//! create-conflict check (R15, `storage/src/state/manager.rs`), which skips
//! the duplicate event atomically.
//!
//! The marker value is JSON, following the existing convention for non-coin
//! `oid:` values (subnet-meta / user-membership, R6-ISSUE-1): it classifies
//! as `StorageFormat::Unknown` and never enters the coin indexes.
//!
//! Shared by `user_handler` (admission precheck + digest) and `tee_executor`
//! (marker state-change append).

use serde::{Deserialize, Serialize};
use setu_types::ObjectId;

/// Domain tag for the marker object id derivation
const NONCE_DOMAIN: &[u8] = b"SETU_USER_TRANSFER_NONCE_V1";

/// Domain tag for the request digest
const DIGEST_DOMAIN: &[u8] = b"SETU_TRANSFER_DIGEST_V2:";

/// Client nonce constraints (design D3.3)
pub const CLIENT_NONCE_MIN_LEN: usize = 8;
pub const CLIENT_NONCE_MAX_LEN: usize = 128;

/// Validate the client nonce charset/length: 8-128 chars of `[A-Za-z0-9._:-]`.
pub fn validate_client_nonce(nonce: &str) -> Result<(), String> {
    if nonce.len() < CLIENT_NONCE_MIN_LEN || nonce.len() > CLIENT_NONCE_MAX_LEN {
        return Err(format!(
            "client_nonce length must be {}-{} characters",
            CLIENT_NONCE_MIN_LEN, CLIENT_NONCE_MAX_LEN
        ));
    }
    if !nonce
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'))
    {
        return Err("client_nonce may only contain [A-Za-z0-9._:-]".to_string());
    }
    Ok(())
}

/// `request_digest = blake3("SETU_TRANSFER_DIGEST_V2:" || canonical_v2_message_bytes)`
/// (design D4, R6-ISSUE-3). Pins the digest to every signed axis at once.
pub fn request_digest(canonical_message: &str) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    hasher.update(DIGEST_DOMAIN);
    hasher.update(canonical_message.as_bytes());
    *hasher.finalize().as_bytes()
}

/// Deterministic marker object id from the length-prefixed key material
/// (design D4, R6-ISSUE-2). Length prefixes are mandatory: addresses come in
/// two valid lengths (0x+40 / 0x+64 hex) and the nonce charset includes hex
/// characters, so raw concatenation would make field boundaries ambiguous.
pub fn nonce_object_id(normalized_from: &str, client_nonce: &str) -> ObjectId {
    let mut hasher = blake3::Hasher::new();
    hasher.update(NONCE_DOMAIN);
    hasher.update(&(normalized_from.len() as u16).to_le_bytes());
    hasher.update(normalized_from.as_bytes());
    hasher.update(&(client_nonce.len() as u16).to_le_bytes());
    hasher.update(client_nonce.as_bytes());
    ObjectId::new(*hasher.finalize().as_bytes())
}

/// Canonical `oid:{hex}` state key for the marker (G11). Must route through
/// `parse_state_change_key` so the R15 create-conflict check applies.
pub fn marker_state_key(id: &ObjectId) -> String {
    setu_types::object_key(id)
}

/// Marker value stored in ROOT state (design D4). JSON on purpose — opaque to
/// runtime, classified `StorageFormat::Unknown`, invisible to coin indexes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserTransferNonceV1 {
    /// Always "UserTransferNonceV1"
    pub kind: String,
    /// Normalized sender address
    pub from: String,
    pub client_nonce: String,
    /// 0x-hex of the 32-byte request digest
    pub request_digest: String,
    /// Canonical subnet string: "ROOT" or 0x+64hex
    pub subnet_id: String,
    pub amount_raw: u64,
    /// User-signed timestamp; bounded by the admission freshness window, and
    /// the future D4.1 retention sweep keys expiry off it
    pub timestamp_ms: u64,
}

impl UserTransferNonceV1 {
    pub const KIND: &'static str = "UserTransferNonceV1";

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        normalized_from: &str,
        client_nonce: &str,
        request_digest: [u8; 32],
        subnet_canonical: &str,
        amount_raw: u64,
        timestamp_ms: u64,
    ) -> Self {
        Self {
            kind: Self::KIND.to_string(),
            from: normalized_from.to_string(),
            client_nonce: client_nonce.to_string(),
            request_digest: format!("0x{}", hex::encode(request_digest)),
            subnet_id: subnet_canonical.to_string(),
            amount_raw,
            timestamp_ms,
        }
    }

    /// Serialized marker bytes for the create state change
    pub fn to_json_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("UserTransferNonceV1 is always JSON-serializable")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_object_id_is_deterministic() {
        let a = nonce_object_id("0xabc1", "nonce-0001");
        let b = nonce_object_id("0xabc1", "nonce-0001");
        assert_eq!(a, b);
        assert_ne!(a, nonce_object_id("0xabc1", "nonce-0002"));
        assert_ne!(a, nonce_object_id("0xabc2", "nonce-0001"));
    }

    // Test #24 (design §9): length-prefixed key material is injective across
    // shifted (from, nonce) boundaries and across 40/64-hex address forms.
    #[test]
    fn nonce_key_material_is_length_prefixed_and_injective() {
        // from_b extends from_a with a prefix of nonce_a; raw concatenation
        // would collide, length prefixes must not.
        let from_a = "0xaabbccdd";
        let nonce_a = "11223344-rest-of-nonce";
        let from_b = format!("{}11223344", from_a);
        let nonce_b = "-rest-of-nonce";
        assert_eq!(
            format!("{}{}", from_a, nonce_a),
            format!("{}{}", from_b, nonce_b),
            "test precondition: raw concatenations must be identical"
        );
        assert_ne!(nonce_object_id(from_a, nonce_a), nonce_object_id(&from_b, nonce_b));

        // 40-hex vs 64-hex address forms never collide
        let short = format!("0x{}", "ab".repeat(20));
        let long = format!("0x{}", "ab".repeat(32));
        assert_ne!(
            nonce_object_id(&short, "shared-nonce-1"),
            nonce_object_id(&long, "shared-nonce-1")
        );
    }

    #[test]
    fn client_nonce_validation_bounds_and_charset() {
        assert!(validate_client_nonce("abcd1234").is_ok());
        assert!(validate_client_nonce(&"a".repeat(128)).is_ok());
        assert!(validate_client_nonce("uuid-1234.5678:abc_DEF").is_ok());
        assert!(validate_client_nonce("short").is_err());
        assert!(validate_client_nonce(&"a".repeat(129)).is_err());
        assert!(validate_client_nonce("bad nonce!").is_err());
        assert!(validate_client_nonce("bad;nonce1").is_err());
    }

    #[test]
    fn marker_state_key_is_oid_hex() {
        let id = nonce_object_id("0xabc1", "nonce-0001");
        let key = marker_state_key(&id);
        assert!(key.starts_with("oid:"));
        assert_eq!(key.len(), 4 + 64);
    }

    #[test]
    fn marker_json_shape() {
        let marker = UserTransferNonceV1::new("0xab", "nonce-12345", [7u8; 32], "ROOT", 100, 1_778_390_000_000);
        let bytes = marker.to_json_bytes();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["kind"], "UserTransferNonceV1");
        assert_eq!(value["amount_raw"], 100);
        assert!(value["request_digest"].as_str().unwrap().starts_with("0x"));
    }
}
