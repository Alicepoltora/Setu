//! Setu Message Handler Implementation
//!
//! This module implements the `GenericMessageHandler` trait from the network layer,
//! providing Setu-specific message handling logic. This moves the business logic
//! from the network layer to the application layer.

use crate::protocol::{NetworkEvent, SetuMessage, SerializedEvent};
use async_trait::async_trait;
use bytes::Bytes;
use setu_network_anemo::{GenericMessageHandler, HandleResult, HandlerError};
use setu_types::{ConsensusFrame, Event};
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{debug, error, warn};

/// Route path for Setu protocol messages
pub const SETU_ROUTE: &str = "/setu";

/// Storage trait required by the message handler
///
/// This trait abstracts the storage operations needed for message handling,
/// allowing different storage backends to be used.
///
/// ## Three-Layer Query Requirement
/// 
/// Implementations MUST support three-layer query (DAG → EventStore) to ensure
/// events can be found even after GC. Use `ConsensusEngine::get_events_by_ids_three_layer()`
/// or equivalent logic:
/// 
/// ```ignore
/// // Step 1: Query DAG (hot data)
/// let mut results = Vec::new();
/// let dag = dag_manager.dag().read().await;
/// for id in event_ids {
///     if let Some(event) = dag.get_event(id) {
///         results.push(event.clone());
///     } else {
///         store_query_ids.push(id.clone());
///     }
/// }
/// 
/// // Step 2: Query EventStore for misses (cold data)
/// if !store_query_ids.is_empty() {
///     let store_events = event_store.get_events_batch(&store_query_ids).await;
///     results.extend(store_events);
/// }
/// ```
#[async_trait]
pub trait MessageHandlerStore: Send + Sync + 'static {
    /// Get events by their IDs
    /// 
    /// **IMPORTANT**: Implementation must use three-layer query (DAG → EventStore)
    /// to find events that may have been GC'd from the active DAG.
    async fn get_events_by_ids(&self, event_ids: &[String]) -> Result<Vec<SerializedEvent>, String>;
    
    /// Store events
    async fn store_events(&self, events: Vec<SerializedEvent>) -> Result<(), String>;

    /// v3 catch-up: return finalized CFs with `anchor.depth > after_depth`,
    /// sorted ascending by depth, capped at `limit`.
    /// Also returns the responder's `highest_finalized_depth` so the caller
    /// can detect end-of-stream without an extra round-trip.
    async fn get_finalized_cfs_after_depth(
        &self,
        after_depth: u64,
        limit: u32,
    ) -> Result<(Vec<ConsensusFrame>, u64), String>;
}

/// Setu protocol message handler
///
/// This handler implements the `GenericMessageHandler` trait, processing
/// incoming Setu protocol messages and producing responses.
pub struct SetuMessageHandler<S> {
    store: Arc<S>,
    local_node_id: String,
    event_tx: mpsc::Sender<NetworkEvent>,
}

impl<S> SetuMessageHandler<S>
where
    S: MessageHandlerStore,
{
    /// Create a new Setu message handler
    pub fn new(
        store: Arc<S>,
        local_node_id: String,
        event_tx: mpsc::Sender<NetworkEvent>,
    ) -> Self {
        Self {
            store,
            local_node_id,
            event_tx,
        }
    }
    
    async fn handle_message(&self, message: SetuMessage) -> Result<Option<SetuMessage>, HandlerError> {
        match message {
            SetuMessage::RequestEvents { event_ids, requester_id } => {
                debug!(
                    "Processing RequestEvents from {}: {} event(s) requested",
                    requester_id,
                    event_ids.len()
                );
                
                match self.store.get_events_by_ids(&event_ids).await {
                    Ok(serialized_events) => {
                        // Convert SerializedEvent to Event by deserializing the data field
                        let events: Vec<Event> = serialized_events
                            .into_iter()
                            .filter_map(|se| bincode::deserialize(&se.data).ok())
                            .collect();
                        
                        debug!("Found {} events to return", events.len());
                        Ok(Some(SetuMessage::EventsResponse {
                            events,
                            responder_id: self.local_node_id.clone(),
                        }))
                    }
                    Err(e) => {
                        warn!("Failed to get events: {}", e);
                        Ok(Some(SetuMessage::EventsResponse {
                            events: Vec::new(),
                            responder_id: self.local_node_id.clone(),
                        }))
                    }
                }
            }
            
            SetuMessage::Ping { timestamp, nonce } => {
                debug!("Processing Ping request");
                Ok(Some(SetuMessage::Pong { timestamp, nonce }))
            }

            SetuMessage::RequestFinalizedCFs { after_depth, limit, requester_id } => {
                // Cap limit defensively at MAX_BATCH; storage layer also enforces its own bounds.
                const MAX_BATCH: u32 = 64;
                let effective_limit = limit.min(MAX_BATCH);
                debug!(
                    "Processing RequestFinalizedCFs from {}: after_depth={}, limit={} (effective {})",
                    requester_id, after_depth, limit, effective_limit
                );
                match self
                    .store
                    .get_finalized_cfs_after_depth(after_depth, effective_limit)
                    .await
                {
                    Ok((cfs, highest_finalized_depth)) => {
                        debug!(
                            "Returning {} finalized CFs (highest_depth={})",
                            cfs.len(),
                            highest_finalized_depth
                        );
                        Ok(Some(SetuMessage::FinalizedCFsResponse {
                            cfs,
                            highest_finalized_depth,
                            responder_id: self.local_node_id.clone(),
                        }))
                    }
                    Err(e) => {
                        warn!("Failed to query finalized CFs: {}", e);
                        Ok(Some(SetuMessage::FinalizedCFsResponse {
                            cfs: Vec::new(),
                            highest_finalized_depth: 0,
                            responder_id: self.local_node_id.clone(),
                        }))
                    }
                }
            }
            
            SetuMessage::EventBroadcast { event, sender_id } => {
                debug!(
                    "Processing EventBroadcast from {}: event_id={}",
                    sender_id,
                    event.id
                );
                
                // Notify application layer with backpressure (await instead of try_send)
                // This ensures events are not dropped during high load
                if let Err(e) = self.event_tx.send(NetworkEvent::EventReceived {
                    peer_id: sender_id.clone(),
                    event: event.clone(),
                }).await {
                    // Channel closed indicates system shutdown
                    warn!(
                        event_id = %event.id,
                        error = %e,
                        "Event channel closed - system may be shutting down"
                    );
                }
                
                // Event enters DAG via event_tx → MessageRouter → receive_event_from_network().
                // Persistence happens later when CF is finalized (persist_finalized_anchor).
                // No need to pre-write to EventStore here — that would cause:
                //   1. Write amplification (event stored twice)
                //   2. Unverified data in EventStore (bypasses router's verify_id check)
                
                Ok(None) // EventBroadcast doesn't require a response
            }
            
            SetuMessage::CFProposal { cf, proposer_id } => {
                debug!("Received CFProposal from {}: cf_id={}", proposer_id, cf.id);
                // Use send().await for backpressure instead of try_send to prevent dropping CF proposals
                // CF proposals are critical for consensus - dropping them causes consensus to stall
                if let Err(e) = self.event_tx.send(NetworkEvent::CFProposal {
                    peer_id: proposer_id.clone(),
                    cf: cf.clone(),
                }).await {
                    error!(
                        cf_id = %cf.id,
                        error = %e,
                        "CF channel closed - system may be shutting down"
                    );
                }
                Ok(None)
            }
            
            SetuMessage::CFVote { vote } => {
                debug!("Received CFVote: cf_id={}, voter={}", vote.cf_id, vote.validator_id);
                // Use send().await for backpressure instead of try_send to prevent dropping votes
                // Votes are critical for reaching quorum - dropping them prevents finalization
                if let Err(e) = self.event_tx.send(NetworkEvent::VoteReceived {
                    peer_id: vote.validator_id.clone(),
                    vote: vote.clone(),
                }).await {
                    error!(
                        cf_id = %vote.cf_id,
                        voter = %vote.validator_id,
                        error = %e,
                        "Vote channel closed - system may be shutting down"
                    );
                }
                Ok(None)
            }
            
            SetuMessage::CFFinalized { cf, sender_id } => {
                debug!("Received CFFinalized from {}: cf_id={}", sender_id, cf.id);
                // Use send().await for backpressure instead of try_send for consistency
                // CFFinalized notifications should not be dropped as they help with state sync
                if let Err(e) = self.event_tx.send(NetworkEvent::CFFinalized {
                    peer_id: sender_id.clone(),
                    cf: cf.clone(),
                }).await {
                    warn!(
                        cf_id = %cf.id,
                        error = %e,
                        "Finalized channel closed - system may be shutting down"
                    );
                }
                Ok(None)
            }
            
            // Response messages should not be received as requests
            SetuMessage::EventsResponse { .. }
            | SetuMessage::Pong { .. }
            | SetuMessage::FinalizedCFsResponse { .. } => {
                warn!("Received response message as request - ignoring");
                Ok(None)
            }
        }
    }
}

#[async_trait]
impl<S> GenericMessageHandler for SetuMessageHandler<S>
where
    S: MessageHandlerStore,
{
    async fn handle(&self, route: &str, body: Bytes) -> HandleResult {
        if route != SETU_ROUTE {
            return Ok(None);
        }
        
        // Deserialize the incoming message
        let message: SetuMessage = bincode::deserialize(&body)
            .map_err(|e| HandlerError::Deserialize(e.to_string()))?;
        
        debug!("Received message: {:?}", std::mem::discriminant(&message));
        
        // Handle the message
        match self.handle_message(message).await? {
            Some(response) => {
                let bytes = bincode::serialize(&response)
                    .map_err(|e| HandlerError::Serialize(e.to_string()))?;
                Ok(Some(Bytes::from(bytes)))
            }
            None => Ok(None),
        }
    }
    
    fn routes(&self) -> Vec<&'static str> {
        vec![SETU_ROUTE]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::NetworkEvent;
    use setu_types::VLCSnapshot;
    use std::collections::HashMap;
    use tokio::sync::RwLock;
    
    /// Mock store for testing
    struct MockStore {
        events: RwLock<HashMap<String, SerializedEvent>>,
        finalized_cfs: RwLock<Vec<ConsensusFrame>>,
    }
    
    impl MockStore {
        fn new() -> Self {
            Self {
                events: RwLock::new(HashMap::new()),
                finalized_cfs: RwLock::new(Vec::new()),
            }
        }
        
        async fn add_event(&self, event: SerializedEvent) {
            self.events.write().await.insert(event.id.clone(), event);
        }

        async fn add_finalized_cf(&self, cf: ConsensusFrame) {
            self.finalized_cfs.write().await.push(cf);
        }
    }
    
    #[async_trait]
    impl MessageHandlerStore for MockStore {
        async fn get_events_by_ids(&self, event_ids: &[String]) -> Result<Vec<SerializedEvent>, String> {
            let events = self.events.read().await;
            Ok(event_ids
                .iter()
                .filter_map(|id| events.get(id).cloned())
                .collect())
        }
        
        async fn store_events(&self, events: Vec<SerializedEvent>) -> Result<(), String> {
            let mut store = self.events.write().await;
            for event in events {
                store.insert(event.id.clone(), event);
            }
            Ok(())
        }

        async fn get_finalized_cfs_after_depth(
            &self,
            after_depth: u64,
            limit: u32,
        ) -> Result<(Vec<ConsensusFrame>, u64), String> {
            let cfs = self.finalized_cfs.read().await;
            let mut matching: Vec<ConsensusFrame> = cfs
                .iter()
                .filter(|cf| cf.anchor.depth > after_depth)
                .cloned()
                .collect();
            matching.sort_by_key(|cf| cf.anchor.depth);
            matching.truncate(limit as usize);
            let highest = cfs.iter().map(|cf| cf.anchor.depth).max().unwrap_or(0);
            Ok((matching, highest))
        }
    }
    
    #[tokio::test]
    async fn test_ping_handler() {
        let store = Arc::new(MockStore::new());
        let (event_tx, _event_rx) = mpsc::channel(100);
        let handler = SetuMessageHandler::new(store, "test_node".to_string(), event_tx);
        
        let request = SetuMessage::Ping { timestamp: 12345, nonce: 99 };
        let request_bytes = Bytes::from(bincode::serialize(&request).unwrap());
        
        let result = handler.handle(SETU_ROUTE, request_bytes).await.unwrap();
        assert!(result.is_some());
        
        let response: SetuMessage = bincode::deserialize(&result.unwrap()).unwrap();
        match response {
            SetuMessage::Pong { timestamp, nonce } => {
                assert_eq!(timestamp, 12345);
                assert_eq!(nonce, 99);
            }
            _ => panic!("Expected Pong response"),
        }
    }
    
    #[tokio::test]
    async fn test_event_broadcast_handler() {
        let store = Arc::new(MockStore::new());
        let (event_tx, mut event_rx) = mpsc::channel(100);
        let handler = SetuMessageHandler::new(store, "test_node".to_string(), event_tx);
        
        let event = Event::genesis("sender".to_string(), VLCSnapshot::default());
        let event_id = event.id.clone();
        
        let request = SetuMessage::EventBroadcast {
            event,
            sender_id: "sender".to_string(),
        };
        let request_bytes = Bytes::from(bincode::serialize(&request).unwrap());
        
        let result = handler.handle(SETU_ROUTE, request_bytes).await.unwrap();
        assert!(result.is_none()); // Broadcast has no response
        
        // Verify network event was sent
        let network_event = event_rx.try_recv().unwrap();
        match network_event {
            NetworkEvent::EventReceived { peer_id, event } => {
                assert_eq!(peer_id, "sender");
                assert_eq!(event.id, event_id);
            }
            _ => panic!("Expected EventReceived"),
        }
    }
    
    #[tokio::test]
    async fn test_request_events_handler() {
        let store = Arc::new(MockStore::new());
        let (event_tx, _) = mpsc::channel(100);
        
        // Add a test event to the store
        let event = Event::genesis("creator".to_string(), VLCSnapshot::default());
        let event_id = event.id.clone();
        let serialized = SerializedEvent {
            seq: 1,
            id: event_id.clone(),
            data: bincode::serialize(&event).unwrap(),
        };
        store.add_event(serialized).await;
        
        let handler = SetuMessageHandler::new(store, "test_node".to_string(), event_tx);
        
        let request = SetuMessage::RequestEvents {
            event_ids: vec![event_id.clone()],
            requester_id: "requester".to_string(),
        };
        let request_bytes = Bytes::from(bincode::serialize(&request).unwrap());
        
        let result = handler.handle(SETU_ROUTE, request_bytes).await.unwrap();
        assert!(result.is_some());
        
        let response: SetuMessage = bincode::deserialize(&result.unwrap()).unwrap();
        match response {
            SetuMessage::EventsResponse { events, responder_id } => {
                assert_eq!(responder_id, "test_node");
                assert_eq!(events.len(), 1);
                assert_eq!(events[0].id, event_id);
            }
            _ => panic!("Expected EventsResponse"),
        }
    }

    // ---- v3 RequestFinalizedCFs tests ------------------------------------

    fn make_cf_with_depth(depth: u64) -> ConsensusFrame {
        let anchor = setu_types::Anchor::new(
            Vec::new(),
            VLCSnapshot::default(),
            format!("state-{}", depth),
            None,
            depth,
        );
        ConsensusFrame::new(0, anchor, "proposer".to_string())
    }

    async fn make_handler_with_cfs(depths: &[u64]) -> (Arc<MockStore>, SetuMessageHandler<MockStore>) {
        let store = Arc::new(MockStore::new());
        for d in depths {
            store.add_finalized_cf(make_cf_with_depth(*d)).await;
        }
        let (event_tx, _rx) = mpsc::channel(8);
        let handler = SetuMessageHandler::new(Arc::clone(&store), "node-a".to_string(), event_tx);
        (store, handler)
    }

    async fn dispatch(handler: &SetuMessageHandler<MockStore>, msg: SetuMessage) -> Option<SetuMessage> {
        let bytes = Bytes::from(bincode::serialize(&msg).unwrap());
        let resp = handler.handle(SETU_ROUTE, bytes).await.unwrap();
        resp.map(|b| bincode::deserialize::<SetuMessage>(&b).unwrap())
    }

    #[tokio::test]
    async fn request_finalized_cfs_returns_after_depth() {
        let (_store, handler) = make_handler_with_cfs(&[1, 3, 5, 7, 9]).await;
        let resp = dispatch(&handler, SetuMessage::RequestFinalizedCFs {
            after_depth: 4,
            limit: 10,
            requester_id: "b".to_string(),
        }).await.expect("response");
        match resp {
            SetuMessage::FinalizedCFsResponse { cfs, highest_finalized_depth, responder_id } => {
                assert_eq!(responder_id, "node-a");
                assert_eq!(highest_finalized_depth, 9);
                let depths: Vec<u64> = cfs.iter().map(|c| c.anchor.depth).collect();
                assert_eq!(depths, vec![5, 7, 9]);
            }
            other => panic!("expected FinalizedCFsResponse, got {:?}", other.message_type()),
        }
    }

    #[tokio::test]
    async fn request_finalized_cfs_respects_limit() {
        let depths: Vec<u64> = (1..=100).collect();
        let (_, handler) = make_handler_with_cfs(&depths).await;
        let resp = dispatch(&handler, SetuMessage::RequestFinalizedCFs {
            after_depth: 0,
            limit: 10,
            requester_id: "b".to_string(),
        }).await.expect("response");
        if let SetuMessage::FinalizedCFsResponse { cfs, .. } = resp {
            assert_eq!(cfs.len(), 10);
            // ascending and all > 0
            for w in cfs.windows(2) {
                assert!(w[0].anchor.depth < w[1].anchor.depth);
            }
            assert!(cfs.iter().all(|c| c.anchor.depth > 0));
        } else {
            panic!("wrong variant");
        }
    }

    #[tokio::test]
    async fn request_finalized_cfs_caps_at_max_batch() {
        let depths: Vec<u64> = (1..=200).collect();
        let (_, handler) = make_handler_with_cfs(&depths).await;
        let resp = dispatch(&handler, SetuMessage::RequestFinalizedCFs {
            after_depth: 0,
            limit: u32::MAX,
            requester_id: "b".to_string(),
        }).await.expect("response");
        if let SetuMessage::FinalizedCFsResponse { cfs, .. } = resp {
            assert_eq!(cfs.len(), 64, "MAX_BATCH should cap at 64");
        } else {
            panic!("wrong variant");
        }
    }

    #[tokio::test]
    async fn request_finalized_cfs_empty_store() {
        let (_, handler) = make_handler_with_cfs(&[]).await;
        let resp = dispatch(&handler, SetuMessage::RequestFinalizedCFs {
            after_depth: 0,
            limit: 10,
            requester_id: "b".to_string(),
        }).await.expect("response");
        if let SetuMessage::FinalizedCFsResponse { cfs, highest_finalized_depth, .. } = resp {
            assert!(cfs.is_empty());
            assert_eq!(highest_finalized_depth, 0);
        } else {
            panic!("wrong variant");
        }
    }

    #[tokio::test]
    async fn finalized_cfs_response_as_request_ignored() {
        let (_, handler) = make_handler_with_cfs(&[]).await;
        let resp = dispatch(&handler, SetuMessage::FinalizedCFsResponse {
            cfs: vec![],
            highest_finalized_depth: 0,
            responder_id: "x".to_string(),
        }).await;
        assert!(resp.is_none());
    }

    #[tokio::test]
    async fn request_finalized_cfs_serialize_roundtrip() {
        let cf = make_cf_with_depth(7);
        let msg = SetuMessage::FinalizedCFsResponse {
            cfs: vec![cf.clone()],
            highest_finalized_depth: 7,
            responder_id: "node-a".to_string(),
        };
        let bytes = bincode::serialize(&msg).unwrap();
        let decoded: SetuMessage = bincode::deserialize(&bytes).unwrap();
        if let SetuMessage::FinalizedCFsResponse { cfs, highest_finalized_depth, responder_id } = decoded {
            assert_eq!(cfs.len(), 1);
            assert_eq!(cfs[0].anchor.depth, 7);
            assert_eq!(highest_finalized_depth, 7);
            assert_eq!(responder_id, "node-a");
        } else {
            panic!("wrong variant");
        }
    }
}
