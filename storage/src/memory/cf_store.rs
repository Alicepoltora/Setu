//! CFStore - In-memory Consensus Frame storage
//!
//! This module provides an in-memory implementation of consensus frame storage,
//! supporting pending and finalized frame tracking with concurrent access.

use dashmap::DashMap;
use setu_types::{CFId, CFStatus, ConsensusFrame, SetuError, SetuResult};
use std::sync::Arc;
use tokio::sync::RwLock;

/// In-memory storage for Consensus Frames with concurrent access
///
/// CFStore uses DashMap for the main frame storage (lock-free access),
/// while pending/finalized lists use RwLock for ordered operations.
///
/// - `frames`: DashMap storing all consensus frames by ID (lock-free)
/// - `pending`: Vector of pending (not yet finalized) frame IDs (ordered)
/// - `finalized`: Vector of finalized frame IDs (ordered)
#[derive(Debug)]
pub struct CFStore {
    frames: Arc<DashMap<CFId, ConsensusFrame>>,
    pending: Arc<RwLock<Vec<CFId>>>,
    finalized: Arc<RwLock<Vec<CFId>>>,
}

impl CFStore {
    /// Create a new empty CFStore
    pub fn new() -> Self {
        Self {
            frames: Arc::new(DashMap::new()),
            pending: Arc::new(RwLock::new(Vec::new())),
            finalized: Arc::new(RwLock::new(Vec::new())),
        }
    }

    /// Store a consensus frame
    ///
    /// The frame is automatically added to either the pending or finalized
    /// list based on its current status.
    pub async fn store(&self, cf: ConsensusFrame) -> SetuResult<()> {
        let cf_id = cf.id.clone();
        let is_finalized = cf.status == CFStatus::Finalized;

        // Insert into DashMap (lock-free)
        self.frames.insert(cf_id.clone(), cf);

        // Update ordered lists
        if is_finalized {
            let mut finalized = self.finalized.write().await;
            finalized.push(cf_id);
        } else {
            let mut pending = self.pending.write().await;
            pending.push(cf_id);
        }

        Ok(())
    }

    /// Get a consensus frame by ID
    pub async fn get(&self, cf_id: &CFId) -> Option<ConsensusFrame> {
        self.frames.get(cf_id).map(|r| r.value().clone())
    }

    /// Mark a pending CF as finalized
    ///
    /// This updates the frame's status and moves it from the pending
    /// list to the finalized list.
    pub async fn mark_finalized(&self, cf_id: &CFId) -> SetuResult<()> {
        // Update frame status in DashMap
        let Some(mut cf) = self.frames.get_mut(cf_id) else {
            return Err(SetuError::InvalidData(format!("CF not found: {}", cf_id)));
        };
        cf.finalize();
        drop(cf);

        // Move from pending to finalized
        let mut pending = self.pending.write().await;
        pending.retain(|id| id != cf_id);
        drop(pending);

        let mut finalized = self.finalized.write().await;
        if !finalized.iter().any(|id| id == cf_id) {
            finalized.push(cf_id.clone());
        }
        Ok(())
    }

    /// Get all pending consensus frames
    pub async fn get_pending(&self) -> Vec<ConsensusFrame> {
        let pending = self.pending.read().await;

        pending
            .iter()
            .filter_map(|id| self.frames.get(id).map(|r| r.value().clone()))
            .collect()
    }

    /// Get all finalized consensus frames
    pub async fn get_finalized(&self) -> Vec<ConsensusFrame> {
        let finalized = self.finalized.read().await;

        finalized
            .iter()
            .filter_map(|id| self.frames.get(id).map(|r| r.value().clone()))
            .collect()
    }

    /// Get the latest finalized CF
    pub async fn latest_finalized(&self) -> Option<ConsensusFrame> {
        let finalized = self.finalized.read().await;
        finalized
            .last()
            .and_then(|id| self.frames.get(id).map(|r| r.value().clone()))
    }

    /// Count finalized CFs
    pub async fn finalized_count(&self) -> usize {
        self.finalized.read().await.len()
    }

    /// Count pending CFs
    pub async fn pending_count(&self) -> usize {
        self.pending.read().await.len()
    }

    /// Return finalized CFs with `anchor.depth > after_depth`, sorted
    /// ascending by depth, capped at `limit`. See `CFStoreBackend` trait
    /// doc-comment for the full contract.
    pub async fn get_finalized_after_depth(
        &self,
        after_depth: u64,
        limit: usize,
    ) -> Vec<ConsensusFrame> {
        if limit == 0 {
            return Vec::new();
        }
        let finalized = self.finalized.read().await;
        let mut matching: Vec<ConsensusFrame> = finalized
            .iter()
            .filter_map(|id| self.frames.get(id).map(|r| r.value().clone()))
            .filter(|cf| cf.anchor.depth > after_depth)
            .collect();
        matching.sort_by_key(|cf| cf.anchor.depth);
        matching.truncate(limit);
        matching
    }

    /// Highest `anchor.depth` among finalized CFs, or 0 if none.
    pub async fn highest_finalized_depth(&self) -> u64 {
        let finalized = self.finalized.read().await;
        finalized
            .iter()
            .filter_map(|id| self.frames.get(id).map(|r| r.value().anchor.depth))
            .max()
            .unwrap_or(0)
    }
}

impl Clone for CFStore {
    fn clone(&self) -> Self {
        Self {
            frames: Arc::clone(&self.frames),
            pending: Arc::clone(&self.pending),
            finalized: Arc::clone(&self.finalized),
        }
    }
}

impl Default for CFStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use setu_types::{Anchor, VLCSnapshot, VectorClock};

    fn create_test_cf(depth: u64, validator: &str) -> ConsensusFrame {
        let anchor = Anchor::new(
            vec!["event1".to_string()],
            VLCSnapshot {
                vector_clock: VectorClock::new(),
                logical_time: depth * 10,
                physical_time: depth * 10000,
            },
            format!("state_root_{}", depth),
            None,
            depth,
        );
        ConsensusFrame::new(0, anchor, validator.to_string())
    }

    #[tokio::test]
    async fn test_cf_store_basic() {
        let store = CFStore::new();

        let cf = create_test_cf(0, "validator1");
        let cf_id = cf.id.clone();

        store.store(cf).await.unwrap();
        assert_eq!(store.pending_count().await, 1);
        assert_eq!(store.finalized_count().await, 0);

        let retrieved = store.get(&cf_id).await;
        assert!(retrieved.is_some());
    }

    #[tokio::test]
    async fn test_cf_store_finalization() {
        let store = CFStore::new();

        let cf = create_test_cf(0, "validator1");
        let cf_id = cf.id.clone();

        store.store(cf).await.unwrap();
        assert_eq!(store.pending_count().await, 1);

        store.mark_finalized(&cf_id).await.unwrap();
        assert_eq!(store.pending_count().await, 0);
        assert_eq!(store.finalized_count().await, 1);

        store.mark_finalized(&cf_id).await.unwrap();
        assert_eq!(store.finalized_count().await, 1);

        let latest = store.latest_finalized().await;
        assert!(latest.is_some());
        assert_eq!(latest.unwrap().id, cf_id);
    }

    #[tokio::test]
    async fn test_cf_store_multiple_frames() {
        let store = CFStore::new();

        let cf1 = create_test_cf(0, "validator1");
        let cf2 = create_test_cf(1, "validator2");
        let cf1_id = cf1.id.clone();
        let cf2_id = cf2.id.clone();

        store.store(cf1).await.unwrap();
        store.store(cf2).await.unwrap();
        assert_eq!(store.pending_count().await, 2);

        store.mark_finalized(&cf1_id).await.unwrap();
        assert_eq!(store.pending_count().await, 1);
        assert_eq!(store.finalized_count().await, 1);

        let pending = store.get_pending().await;
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, cf2_id);

        let finalized = store.get_finalized().await;
        assert_eq!(finalized.len(), 1);
        assert_eq!(finalized[0].id, cf1_id);
    }

    #[tokio::test]
    async fn test_f1_cf_store_mark_finalized_missing_cf_returns_error() {
        let store = CFStore::new();
        let result = store.mark_finalized(&"missing-cf".to_string()).await;
        assert!(result.is_err());
    }

    // =========================================================================
    // PR-1 (post-restart-finality-stall-v3) — bounded depth-ordered reads
    // =========================================================================

    async fn store_finalized(store: &CFStore, depth: u64, validator: &str) -> CFId {
        let cf = create_test_cf(depth, validator);
        let id = cf.id.clone();
        store.store(cf).await.unwrap();
        store.mark_finalized(&id).await.unwrap();
        id
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_empty_store() {
        let store = CFStore::new();
        let result = store.get_finalized_after_depth(0, 10).await;
        assert!(result.is_empty());
        assert_eq!(store.highest_finalized_depth().await, 0);
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_single_cf() {
        let store = CFStore::new();
        store_finalized(&store, 5, "v1").await;

        let from_zero = store.get_finalized_after_depth(0, 10).await;
        assert_eq!(from_zero.len(), 1);
        assert_eq!(from_zero[0].anchor.depth, 5);

        // strict `>`: depth==after_depth must be excluded
        let from_five = store.get_finalized_after_depth(5, 10).await;
        assert!(from_five.is_empty());

        assert_eq!(store.highest_finalized_depth().await, 5);
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_orders_ascending() {
        let store = CFStore::new();
        // insertion order intentionally non-monotone
        for depth in [7u64, 3, 5, 9, 1] {
            store_finalized(&store, depth, "v1").await;
        }
        let result = store.get_finalized_after_depth(0, 100).await;
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![1, 3, 5, 7, 9]);
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_respects_after() {
        let store = CFStore::new();
        for d in 1u64..=10 {
            store_finalized(&store, d, "v1").await;
        }
        let result = store.get_finalized_after_depth(4, 100).await;
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![5, 6, 7, 8, 9, 10]);
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_respects_limit() {
        let store = CFStore::new();
        for d in 1u64..=10 {
            store_finalized(&store, d, "v1").await;
        }
        let result = store.get_finalized_after_depth(0, 3).await;
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![1, 2, 3]);
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_limit_zero() {
        let store = CFStore::new();
        store_finalized(&store, 1, "v1").await;
        store_finalized(&store, 2, "v1").await;
        let result = store.get_finalized_after_depth(0, 0).await;
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn v3_get_finalized_after_depth_skips_pending() {
        let store = CFStore::new();
        // pending CF at depth 4
        let pending_cf = create_test_cf(4, "v1");
        store.store(pending_cf).await.unwrap();
        // finalized CF at depth 3
        store_finalized(&store, 3, "v2").await;

        let result = store.get_finalized_after_depth(0, 100).await;
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].anchor.depth, 3);
    }

    #[tokio::test]
    async fn v3_highest_finalized_depth_ignores_pending() {
        let store = CFStore::new();
        // pending at depth 9
        let pending_cf = create_test_cf(9, "v1");
        store.store(pending_cf).await.unwrap();
        // finalized at depth 5
        store_finalized(&store, 5, "v2").await;
        assert_eq!(store.highest_finalized_depth().await, 5);
    }
}
