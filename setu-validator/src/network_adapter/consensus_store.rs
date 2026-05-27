//! ConsensusEngineStore - wraps ConsensusEngine as MessageHandlerStore
//!
//! Provides three-layer event query (DAG → EventStore) for SetuMessageHandler.
//! store_events uses EventStoreBackend directly to avoid VLC/CF side effects.

use crate::protocol::SerializedEvent;
use super::setu_handler::MessageHandlerStore;
use consensus::ConsensusEngine;
use setu_storage::{CFStoreBackend, EventStoreBackend};
use setu_types::ConsensusFrame;
use std::sync::Arc;
use tracing::warn;

/// Wraps ConsensusEngine + EventStoreBackend + CFStoreBackend as MessageHandlerStore
pub struct ConsensusEngineStore {
    engine: Arc<ConsensusEngine>,
    /// Direct storage backend — bypasses receive_event_from_network to avoid side effects
    event_store: Arc<dyn EventStoreBackend>,
    /// CF storage backend — exposes finalized CF reads for v3 catch-up
    cf_store: Arc<dyn CFStoreBackend>,
}

impl ConsensusEngineStore {
    pub fn new(
        engine: Arc<ConsensusEngine>,
        event_store: Arc<dyn EventStoreBackend>,
        cf_store: Arc<dyn CFStoreBackend>,
    ) -> Self {
        Self { engine, event_store, cf_store }
    }
}

#[async_trait::async_trait]
impl MessageHandlerStore for ConsensusEngineStore {
    async fn get_events_by_ids(&self, event_ids: &[String]) -> Result<Vec<SerializedEvent>, String> {
        let events = self.engine.get_events_by_ids_three_layer(event_ids).await;
        Ok(events.into_iter().map(|e| SerializedEvent {
            seq: 0,
            id: e.id.clone(),
            data: bincode::serialize(&e).unwrap_or_default(),
        }).collect())
    }

    async fn store_events(&self, events: Vec<SerializedEvent>) -> Result<(), String> {
        for se in events {
            if let Ok(event) = bincode::deserialize::<setu_types::Event>(&se.data) {
                // N4 fix: Verify envelope ID matches deserialized event ID
                if event.id != se.id {
                    warn!("store_events: ID mismatch: envelope={}, event={}, dropping", se.id, event.id);
                    continue;
                }
                if let Err(e) = self.event_store.store(event).await {
                    warn!("store_events: failed to store event {}: {:?}", se.id, e);
                }
            }
        }
        Ok(())
    }

    async fn get_finalized_cfs_after_depth(
        &self,
        after_depth: u64,
        limit: u32,
    ) -> Result<(Vec<ConsensusFrame>, u64), String> {
        let cfs = self
            .cf_store
            .get_finalized_after_depth(after_depth, limit as usize)
            .await
            .map_err(|e| format!("get_finalized_after_depth: {:?}", e))?;
        let highest = self
            .cf_store
            .highest_finalized_depth()
            .await
            .map_err(|e| format!("highest_finalized_depth: {:?}", e))?;
        Ok((cfs, highest))
    }
}
