//! StateSyncClient — v3 catch-up RPC client over the `/setu` route.
//!
//! Reuses the existing `SetuMessage` envelope and `AnemoNetworkService::send_to_peer`
//! pattern (see `broadcaster/anemo_adapter.rs`) so no changes to the network crate
//! are required. Intended consumer is the validator startup catch-up loop (PR-3).

use bytes::Bytes;
use setu_network_anemo::{AnemoNetworkService, PeerId};
use setu_types::{ConsensusFrame, Event, EventId};
use std::sync::Arc;
use std::time::Duration;
use tokio::time::timeout;
use tracing::{debug, info, warn};

use crate::protocol::SetuMessage;

const SETU_ROUTE: &str = "/setu";
/// Per-peer RPC timeout. Catch-up is best-effort: if a peer is slow we move on.
const PER_PEER_TIMEOUT: Duration = Duration::from_secs(3);
/// Defensive cap on a single batch. Server-side enforces its own MAX_BATCH=64.
const MAX_BATCH: u32 = 64;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("no connected peers available")]
    NoPeers,
    #[error("all peers failed: {0}")]
    AllPeersFailed(String),
    #[error("peer returned unexpected message variant")]
    UnexpectedVariant,
    #[error("serialize error: {0}")]
    Serialize(String),
    #[error("deserialize error: {0}")]
    Deserialize(String),
}

pub struct StateSyncClient {
    network: Arc<AnemoNetworkService>,
    local_id: String,
}

impl StateSyncClient {
    pub fn new(network: Arc<AnemoNetworkService>, local_id: String) -> Self {
        Self { network, local_id }
    }

    /// Pull finalized CFs with `anchor.depth > after_depth` from any reachable
    /// peer. Returns `(cfs, highest_finalized_depth_of_peer)`. `cfs` is empty
    /// when the peer is at or below `after_depth`, which PR-3 uses as the
    /// "no progress" signal to stop catch-up.
    pub async fn pull_finalized_after_depth(
        &self,
        after_depth: u64,
    ) -> Result<(Vec<ConsensusFrame>, u64), SyncError> {
        let req = SetuMessage::RequestFinalizedCFs {
            after_depth,
            limit: MAX_BATCH,
            requester_id: self.local_id.clone(),
        };
        let bytes = encode(&req)?;

        let peers = self.network.get_connected_peers();
        if peers.is_empty() {
            return Err(SyncError::NoPeers);
        }

        let mut last_err = String::new();
        for peer_id_str in peers {
            let peer_id = match parse_peer_id(&peer_id_str) {
                Ok(id) => id,
                Err(e) => {
                    last_err = e;
                    continue;
                }
            };

            match timeout(
                PER_PEER_TIMEOUT,
                self.network.send_to_peer(peer_id, SETU_ROUTE, bytes.clone()),
            )
            .await
            {
                Ok(Ok(resp_bytes)) => {
                    let resp: SetuMessage = decode(&resp_bytes)?;
                    match resp {
                        SetuMessage::FinalizedCFsResponse {
                            cfs,
                            highest_finalized_depth,
                            responder_id,
                        } => {
                            info!(
                                peer = %responder_id,
                                count = cfs.len(),
                                highest = highest_finalized_depth,
                                after_depth,
                                "pulled finalized CFs",
                            );
                            return Ok((cfs, highest_finalized_depth));
                        }
                        other => {
                            warn!(
                                got = ?other.message_type(),
                                "expected FinalizedCFsResponse"
                            );
                            return Err(SyncError::UnexpectedVariant);
                        }
                    }
                }
                Ok(Err(e)) => {
                    last_err = format!("{}: {}", peer_id_str, e);
                    debug!(peer = %peer_id_str, error = %e, "send_to_peer failed");
                }
                Err(_) => {
                    last_err = format!("{}: timeout", peer_id_str);
                    debug!(peer = %peer_id_str, "timeout pulling finalized CFs");
                }
            }
        }

        Err(SyncError::AllPeersFailed(last_err))
    }

    /// Pull events by IDs from any reachable peer. Reuses the existing
    /// `RequestEvents`/`EventsResponse` round-trip — included here so the
    /// PR-3 catch-up loop has a single client surface for both CF and Event
    /// retrieval.
    pub async fn pull_events_by_ids(
        &self,
        ids: &[EventId],
    ) -> Result<Vec<Event>, SyncError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let req = SetuMessage::RequestEvents {
            event_ids: ids.to_vec(),
            requester_id: self.local_id.clone(),
        };
        let bytes = encode(&req)?;

        let peers = self.network.get_connected_peers();
        if peers.is_empty() {
            return Err(SyncError::NoPeers);
        }

        let mut last_err = String::new();
        for peer_id_str in peers {
            let peer_id = match parse_peer_id(&peer_id_str) {
                Ok(id) => id,
                Err(e) => {
                    last_err = e;
                    continue;
                }
            };

            match timeout(
                PER_PEER_TIMEOUT,
                self.network.send_to_peer(peer_id, SETU_ROUTE, bytes.clone()),
            )
            .await
            {
                Ok(Ok(resp_bytes)) => {
                    let resp: SetuMessage = decode(&resp_bytes)?;
                    match resp {
                        SetuMessage::EventsResponse { events, .. } => return Ok(events),
                        other => {
                            warn!(got = ?other.message_type(), "expected EventsResponse");
                            return Err(SyncError::UnexpectedVariant);
                        }
                    }
                }
                Ok(Err(e)) => last_err = format!("{}: {}", peer_id_str, e),
                Err(_) => last_err = format!("{}: timeout", peer_id_str),
            }
        }
        Err(SyncError::AllPeersFailed(last_err))
    }
}

fn encode(msg: &SetuMessage) -> Result<Bytes, SyncError> {
    bincode::serialize(msg)
        .map(Bytes::from)
        .map_err(|e| SyncError::Serialize(e.to_string()))
}

fn decode(bytes: &[u8]) -> Result<SetuMessage, SyncError> {
    bincode::deserialize(bytes).map_err(|e| SyncError::Deserialize(e.to_string()))
}

/// Parse a hex-encoded 32-byte peer ID. Matches the format produced by
/// `AnemoNetworkService::get_connected_peers()`.
fn parse_peer_id(s: &str) -> Result<PeerId, String> {
    let bytes = hex::decode(s).map_err(|e| format!("invalid peer id hex: {}", e))?;
    if bytes.len() != 32 {
        return Err(format!("peer id must be 32 bytes, got {}", bytes.len()));
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&bytes);
    Ok(PeerId(arr))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_request_finalized_cfs_roundtrip() {
        let msg = SetuMessage::RequestFinalizedCFs {
            after_depth: 5,
            limit: 32,
            requester_id: "alice".to_string(),
        };
        let bytes = encode(&msg).expect("encode");
        let decoded = decode(&bytes).expect("decode");
        match decoded {
            SetuMessage::RequestFinalizedCFs { after_depth, limit, requester_id } => {
                assert_eq!(after_depth, 5);
                assert_eq!(limit, 32);
                assert_eq!(requester_id, "alice");
            }
            other => panic!("unexpected variant: {:?}", other.message_type()),
        }
    }

    #[test]
    fn parse_peer_id_valid() {
        let hex_id = "a".repeat(64);
        assert!(parse_peer_id(&hex_id).is_ok());
    }

    #[test]
    fn parse_peer_id_wrong_length() {
        assert!(parse_peer_id("dead").is_err());
    }

    #[test]
    fn parse_peer_id_invalid_hex() {
        assert!(parse_peer_id("not-hex-at-all").is_err());
    }
}
