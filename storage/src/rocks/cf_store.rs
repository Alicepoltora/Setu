//! RocksDB implementation of CFStore
//!
//! This provides persistent storage for ConsensusFrames.
//! It uses the SetuDB wrapper with a dedicated ColumnFamily.
//!
//! ## Key Design Decisions
//!
//! 1. **Composite Keys**: Uses prefix keys for different indexes
//! 2. **Status Tracking**: Separate indexes for pending and finalized CFs
//! 3. **API Compatible**: Maintains the same async API as in-memory CFStore
//!
//! ## Key Layout
//!
//! All data is stored in ColumnFamily::ConsensusFrames:
//! - `cf:{cf_id}` -> ConsensusFrame (main CF data)
//! - `pending:{seq}:{cf_id}` -> () (pending index, seq is insertion order)
//! - `finalized:{seq}:{cf_id}` -> () (finalized index, seq is finalization order)
//! - `finalized_depth:{depth:016x}:{cf_id}` -> () (v3: depth-ordered finalized index)
//! - `meta:pending_seq` -> u64 (next pending sequence number)
//! - `meta:finalized_seq` -> u64 (next finalized sequence number)

use crate::rocks::core::{SetuDB, ColumnFamily};
use setu_types::{ConsensusFrame, CFId, CFStatus, SetuResult, SetuError};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tracing::debug;

/// Key prefixes for different data types in ConsensusFrames CF
mod key_prefix {
    pub const CF: &[u8] = b"cf:";
    pub const PENDING: &[u8] = b"pending:";
    pub const FINALIZED: &[u8] = b"finalized:";
    /// v3: depth-ordered secondary index over finalized CFs.
    /// Key layout: `finalized_depth:{depth:016x}:{cf_id}` -> ().
    /// Lexicographic byte order over the hex-padded depth gives ascending
    /// numeric order, which is exactly what `get_finalized_after_depth`
    /// needs.
    pub const FINALIZED_DEPTH: &[u8] = b"finalized_depth:";
    pub const META_PENDING_SEQ: &[u8] = b"meta:pending_seq";
    pub const META_FINALIZED_SEQ: &[u8] = b"meta:finalized_seq";
}

/// RocksDB-backed CFStore implementation
pub struct RocksDBCFStore {
    db: Arc<SetuDB>,
    /// Counter for pending CF insertion order
    pending_seq: AtomicU64,
    /// Counter for finalized CF order
    finalized_seq: AtomicU64,
}

impl RocksDBCFStore {
    /// Create a new RocksDBCFStore with an owned SetuDB
    pub fn new(db: SetuDB) -> Self {
        let db = Arc::new(db);
        Self::from_shared(db)
    }
    
    /// Create from a shared SetuDB instance
    pub fn from_shared(db: Arc<SetuDB>) -> Self {
        // Load sequence counters from storage
        let pending_seq = db.get_raw::<u64>(ColumnFamily::ConsensusFrames, key_prefix::META_PENDING_SEQ)
            .ok()
            .flatten()
            .unwrap_or(0);
            
        let finalized_seq = db.get_raw::<u64>(ColumnFamily::ConsensusFrames, key_prefix::META_FINALIZED_SEQ)
            .ok()
            .flatten()
            .unwrap_or(0);
        
        let store = Self {
            db,
            pending_seq: AtomicU64::new(pending_seq),
            finalized_seq: AtomicU64::new(finalized_seq),
        };

        // v3: backfill the depth-ordered secondary index if pre-v3 data
        // exists without it. Best-effort; logs on failure but does not
        // refuse to open the store (callers may then observe an empty
        // bounded read until the next mark_finalized rebuilds the index).
        if let Err(e) = store.backfill_finalized_depth_index() {
            tracing::warn!(error = %e, "finalized_depth backfill failed");
        }

        store
    }
    
    /// Get the underlying database reference
    pub fn db(&self) -> &SetuDB {
        &self.db
    }
    
    // =========================================================================
    // Key Construction Helpers
    // =========================================================================
    
    fn cf_key(cf_id: &CFId) -> Vec<u8> {
        let mut key = Vec::with_capacity(key_prefix::CF.len() + cf_id.len());
        key.extend_from_slice(key_prefix::CF);
        key.extend_from_slice(cf_id.as_bytes());
        key
    }
    
    fn pending_key(seq: u64, cf_id: &CFId) -> Vec<u8> {
        // Format: pending:{seq:016x}:{cf_id}
        let seq_str = format!("{:016x}", seq);
        let mut key = Vec::with_capacity(
            key_prefix::PENDING.len() + seq_str.len() + 1 + cf_id.len()
        );
        key.extend_from_slice(key_prefix::PENDING);
        key.extend_from_slice(seq_str.as_bytes());
        key.push(b':');
        key.extend_from_slice(cf_id.as_bytes());
        key
    }
    
    fn finalized_key(seq: u64, cf_id: &CFId) -> Vec<u8> {
        // Format: finalized:{seq:016x}:{cf_id}
        let seq_str = format!("{:016x}", seq);
        let mut key = Vec::with_capacity(
            key_prefix::FINALIZED.len() + seq_str.len() + 1 + cf_id.len()
        );
        key.extend_from_slice(key_prefix::FINALIZED);
        key.extend_from_slice(seq_str.as_bytes());
        key.push(b':');
        key.extend_from_slice(cf_id.as_bytes());
        key
    }

    fn finalized_depth_key(depth: u64, cf_id: &CFId) -> Vec<u8> {
        // Format: finalized_depth:{depth:016x}:{cf_id}
        let depth_str = format!("{:016x}", depth);
        let mut key = Vec::with_capacity(
            key_prefix::FINALIZED_DEPTH.len() + depth_str.len() + 1 + cf_id.len()
        );
        key.extend_from_slice(key_prefix::FINALIZED_DEPTH);
        key.extend_from_slice(depth_str.as_bytes());
        key.push(b':');
        key.extend_from_slice(cf_id.as_bytes());
        key
    }

    /// Extract `(depth, cf_id)` from a `finalized_depth:` key.
    fn extract_depth_and_cf_id(key: &[u8]) -> Option<(u64, CFId)> {
        let prefix_len = key_prefix::FINALIZED_DEPTH.len();
        if key.len() <= prefix_len + 16 + 1 {
            return None;
        }
        let depth_hex = std::str::from_utf8(&key[prefix_len..prefix_len + 16]).ok()?;
        let depth = u64::from_str_radix(depth_hex, 16).ok()?;
        if key[prefix_len + 16] != b':' {
            return None;
        }
        let cf_id = String::from_utf8(key[prefix_len + 16 + 1..].to_vec()).ok()?;
        Some((depth, cf_id))
    }
    
    /// Extract cf_id from a pending/finalized key
    fn extract_cf_id_from_index_key(key: &[u8], prefix: &[u8]) -> Option<CFId> {
        // Key format: {prefix}{seq:016x}:{cf_id}
        // seq is 16 hex chars, plus a colon
        let prefix_len = prefix.len();
        let seq_len = 16 + 1; // 16 hex chars + colon
        
        if key.len() > prefix_len + seq_len {
            String::from_utf8(key[prefix_len + seq_len..].to_vec()).ok()
        } else {
            None
        }
    }

    // =========================================================================
    // Core Storage Operations
    // =========================================================================

    /// Store a consensus frame
    pub async fn store(&self, cf: ConsensusFrame) -> SetuResult<()> {
        let cf_id = cf.id.clone();
        let is_finalized = cf.status == CFStatus::Finalized;
        
        let mut batch = self.db.batch();
        
        // Store CF
        let cf_key = Self::cf_key(&cf_id);
        self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &cf_key, &cf)
            .map_err(|e| SetuError::StorageError(e.to_string()))?;
        
        // Add to appropriate index
        if is_finalized {
            let seq = self.finalized_seq.fetch_add(1, Ordering::SeqCst);
            let finalized_key = Self::finalized_key(seq, &cf_id);
            self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &finalized_key, &())
                .map_err(|e| SetuError::StorageError(e.to_string()))?;

            // v3: also write depth-ordered secondary index atomically.
            let depth_key = Self::finalized_depth_key(cf.anchor.depth, &cf_id);
            self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &depth_key, &())
                .map_err(|e| SetuError::StorageError(e.to_string()))?;

            // Update sequence counter
            self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, key_prefix::META_FINALIZED_SEQ, &(seq + 1))
                .map_err(|e| SetuError::StorageError(e.to_string()))?;
        } else {
            let seq = self.pending_seq.fetch_add(1, Ordering::SeqCst);
            let pending_key = Self::pending_key(seq, &cf_id);
            self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &pending_key, &())
                .map_err(|e| SetuError::StorageError(e.to_string()))?;
            
            // Update sequence counter
            self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, key_prefix::META_PENDING_SEQ, &(seq + 1))
                .map_err(|e| SetuError::StorageError(e.to_string()))?;
        }
        
        self.db.write_batch(batch)
            .map_err(|e| SetuError::StorageError(e.to_string()))?;
        
        debug!(cf_id = %cf_id, finalized = is_finalized, "Stored CF to RocksDB");
        Ok(())
    }
    
    /// Get a consensus frame by ID
    pub async fn get(&self, cf_id: &CFId) -> Option<ConsensusFrame> {
        let cf_key = Self::cf_key(cf_id);
        self.db.get_raw(ColumnFamily::ConsensusFrames, &cf_key)
            .ok()
            .flatten()
    }
    
    /// Mark a pending CF as finalized
    pub async fn mark_finalized(&self, cf_id: &CFId) -> SetuResult<()> {
        // Get current CF
        let mut cf = match self.get(cf_id).await {
            Some(cf) => cf,
            None => return Err(SetuError::InvalidData(format!("CF not found: {}", cf_id))),
        };
        
        if cf.status == CFStatus::Finalized {
            return Ok(()); // Already finalized
        }
        
        // Update status
        cf.finalize();
        
        let mut batch = self.db.batch();
        
        // Update CF
        let cf_key = Self::cf_key(cf_id);
        self.db
            .batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &cf_key, &cf)
            .map_err(|e| SetuError::StorageError(format!("Failed to update CF status: {}", e)))?;
        
        // Remove from pending index (need to find the key)
        let pending_keys = match self.db.prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::PENDING) {
            Ok(keys) => keys,
            Err(e) => return Err(SetuError::StorageError(format!("Failed to scan pending CF index: {}", e))),
        };
        
        for key in pending_keys {
            if let Some(id) = Self::extract_cf_id_from_index_key(&key, key_prefix::PENDING) {
                if &id == cf_id {
                    let _ = self.db.batch_delete_raw(&mut batch, ColumnFamily::ConsensusFrames, &key);
                    break;
                }
            }
        }
        
        // Add to finalized index
        let seq = self.finalized_seq.fetch_add(1, Ordering::SeqCst);
        let finalized_key = Self::finalized_key(seq, cf_id);
        self.db
            .batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &finalized_key, &())
            .map_err(|e| SetuError::StorageError(format!("Failed to update finalized CF index: {}", e)))?;

        // v3: write depth-ordered secondary index atomically in the same batch.
        let depth_key = Self::finalized_depth_key(cf.anchor.depth, cf_id);
        self.db
            .batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &depth_key, &())
            .map_err(|e| SetuError::StorageError(format!("Failed to update finalized_depth index: {}", e)))?;

        // Update sequence counter
        self.db
            .batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, key_prefix::META_FINALIZED_SEQ, &(seq + 1))
            .map_err(|e| SetuError::StorageError(format!("Failed to update finalized CF sequence: {}", e)))?;
        
        self.db
            .write_batch(batch)
            .map_err(|e| SetuError::StorageError(format!("Failed to write mark_finalized batch: {}", e)))?;
        Ok(())
    }
    
    /// Get all pending consensus frames
    pub async fn get_pending(&self) -> Vec<ConsensusFrame> {
        let pending_keys = match self.db.prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::PENDING) {
            Ok(keys) => keys,
            Err(_) => return Vec::new(),
        };
        
        let mut cfs = Vec::new();
        for key in pending_keys {
            if let Some(cf_id) = Self::extract_cf_id_from_index_key(&key, key_prefix::PENDING) {
                if let Some(cf) = self.get(&cf_id).await {
                    cfs.push(cf);
                }
            }
        }
        cfs
    }
    
    /// Get all finalized consensus frames
    pub async fn get_finalized(&self) -> Vec<ConsensusFrame> {
        let finalized_keys = match self.db.prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED) {
            Ok(keys) => keys,
            Err(_) => return Vec::new(),
        };
        
        let mut cfs = Vec::new();
        for key in finalized_keys {
            if let Some(cf_id) = Self::extract_cf_id_from_index_key(&key, key_prefix::FINALIZED) {
                if let Some(cf) = self.get(&cf_id).await {
                    cfs.push(cf);
                }
            }
        }
        cfs
    }
    
    /// Get the latest finalized CF
    pub async fn latest_finalized(&self) -> Option<ConsensusFrame> {
        let finalized_keys = match self.db.prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED) {
            Ok(keys) => keys,
            Err(_) => return None,
        };
        
        // Keys are sorted, so the last one is the most recent
        finalized_keys.last().and_then(|key| {
            Self::extract_cf_id_from_index_key(key, key_prefix::FINALIZED)
                .and_then(|cf_id| {
                    // We need to block here since we're in a sync context
                    // This is a limitation - in production, this should be async all the way
                    let cf_key = Self::cf_key(&cf_id);
                    self.db.get_raw(ColumnFamily::ConsensusFrames, &cf_key)
                        .ok()
                        .flatten()
                })
        })
    }
    
    /// Count finalized CFs
    pub async fn finalized_count(&self) -> usize {
        self.db.prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED)
            .map(|keys| keys.len())
            .unwrap_or(0)
    }
    
    /// Count pending CFs
    pub async fn pending_count(&self) -> usize {
        self.db.prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::PENDING)
            .map(|keys| keys.len())
            .unwrap_or(0)
    }

    // =========================================================================
    // v3 bounded-read API (post-restart-finality-stall-v3)
    // =========================================================================

    /// Return finalized CFs with `anchor.depth > after_depth`, sorted
    /// ascending by depth, capped at `limit`. See `CFStoreBackend` for the
    /// full contract.
    pub async fn get_finalized_after_depth(
        &self,
        after_depth: u64,
        limit: usize,
    ) -> SetuResult<Vec<ConsensusFrame>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let keys = self.db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
            .map_err(|e| SetuError::StorageError(format!("finalized_depth scan failed: {}", e)))?;
        // prefix_scan_keys returns lexicographically ordered keys; with a
        // hex-padded depth this is ascending numeric order.
        let mut out = Vec::with_capacity(limit.min(keys.len()));
        for key in keys {
            let Some((depth, cf_id)) = Self::extract_depth_and_cf_id(&key) else {
                continue;
            };
            if depth <= after_depth {
                continue;
            }
            if let Some(cf) = self.get(&cf_id).await {
                out.push(cf);
                if out.len() >= limit {
                    break;
                }
            }
        }
        Ok(out)
    }

    /// Highest `anchor.depth` among finalized CFs, or 0 if none.
    pub async fn highest_finalized_depth(&self) -> SetuResult<u64> {
        let keys = self.db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
            .map_err(|e| SetuError::StorageError(format!("finalized_depth scan failed: {}", e)))?;
        Ok(keys.last()
            .and_then(|k| Self::extract_depth_and_cf_id(k))
            .map(|(d, _)| d)
            .unwrap_or(0))
    }

    /// Populate `finalized_depth:` from the existing `finalized:` index
    /// when the secondary index is empty. Runs once at startup. No-op when
    /// the depth index is already populated.
    fn backfill_finalized_depth_index(&self) -> SetuResult<()> {
        let depth_keys = self.db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
            .map_err(|e| SetuError::StorageError(format!("finalized_depth scan failed: {}", e)))?;
        if !depth_keys.is_empty() {
            return Ok(());
        }
        let finalized_keys = self.db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED)
            .map_err(|e| SetuError::StorageError(format!("finalized scan failed: {}", e)))?;
        if finalized_keys.is_empty() {
            return Ok(());
        }
        tracing::info!(
            count = finalized_keys.len(),
            "v3 backfilling finalized_depth index from pre-v3 finalized index"
        );
        let mut batch = self.db.batch();
        let mut written = 0usize;
        for key in finalized_keys {
            let Some(cf_id) = Self::extract_cf_id_from_index_key(&key, key_prefix::FINALIZED) else {
                continue;
            };
            let cf_key = Self::cf_key(&cf_id);
            let Ok(Some(cf)) = self.db.get_raw::<ConsensusFrame>(ColumnFamily::ConsensusFrames, &cf_key) else {
                continue;
            };
            let depth_key = Self::finalized_depth_key(cf.anchor.depth, &cf_id);
            self.db.batch_put_raw(&mut batch, ColumnFamily::ConsensusFrames, &depth_key, &())
                .map_err(|e| SetuError::StorageError(format!("backfill batch_put failed: {}", e)))?;
            written += 1;
        }
        if written > 0 {
            self.db.write_batch(batch)
                .map_err(|e| SetuError::StorageError(format!("backfill write failed: {}", e)))?;
        }
        Ok(())
    }

    /// Probe on-disk ConsensusFrame blobs for codec/schema compatibility.
    ///
    /// Pick the first key under `finalized:`, resolve its `cf:{id}` blob, and
    /// attempt a BCS decode into the current `ConsensusFrame` type. Read-only,
    /// O(1) under the assumption that schema breaks are uniform across blobs.
    /// Must be called at startup BEFORE any reader path consumes CFs, because
    /// `get()` and friends use `.ok().flatten()` and would silently turn a
    /// schema-mismatch into "no data" — leading to a silent fork.
    pub fn validate_schema(&self) -> SetuResult<()> {
        let keys = self.db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED)
            .map_err(|e| SetuError::StorageError(format!("schema probe: scan failed: {}", e)))?;
        let Some(index_key) = keys.into_iter().next() else {
            return Ok(());
        };
        let Some(cf_id) = Self::extract_cf_id_from_index_key(&index_key, key_prefix::FINALIZED) else {
            return Err(SetuError::StorageError(format!(
                "schema probe: corrupt finalized index key (length {})",
                index_key.len()
            )));
        };
        let cf_key = Self::cf_key(&cf_id);
        match self.db.get_raw::<ConsensusFrame>(ColumnFamily::ConsensusFrames, &cf_key) {
            Ok(Some(_)) => Ok(()),
            Ok(None) => Err(SetuError::StorageError(format!(
                "schema probe: finalized index references missing CF blob {} — DB inconsistent",
                cf_id
            ))),
            Err(e) => Err(SetuError::StorageError(format!(
                "CF schema mismatch detected: cf_id={} cannot be decoded into the current \
                 ConsensusFrame schema. This release added a `round` field to ConsensusFrame \
                 and is not backward-compatible with pre-v3 on-disk blobs.\n\n\
                 Remediation:\n\
                 1. Stop the validator process.\n\
                 2. Back up data/ for forensics: `mv data data.bak-$(date +%s)`.\n\
                 3. Wipe CF storage: `rm -rf data/`.\n\
                 4. Restart; the validator will catch up from peers via the v3 \
                 finalized-CF pull RPC.\n\n\
                 Underlying decode error: {}",
                cf_id, e
            ))),
        }
    }
}

impl Clone for RocksDBCFStore {
    fn clone(&self) -> Self {
        Self {
            db: Arc::clone(&self.db),
            pending_seq: AtomicU64::new(self.pending_seq.load(Ordering::SeqCst)),
            finalized_seq: AtomicU64::new(self.finalized_seq.load(Ordering::SeqCst)),
        }
    }
}

impl std::fmt::Debug for RocksDBCFStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RocksDBCFStore")
            .field("db", &"<SetuDB>")
            .field("pending_seq", &self.pending_seq.load(Ordering::SeqCst))
            .field("finalized_seq", &self.finalized_seq.load(Ordering::SeqCst))
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use setu_types::{Anchor, VLCSnapshot, VectorClock};

    fn make_test_cf(depth: u64, validator: &str) -> ConsensusFrame {
        let anchor = Anchor::new(
            vec![format!("event-{}", depth)],
            VLCSnapshot {
                vector_clock: VectorClock::new(),
                logical_time: depth * 10,
                physical_time: depth * 10_000,
            },
            format!("state_root_{}", depth),
            None,
            depth,
        );
        ConsensusFrame::new(0, anchor, validator.to_string())
    }

    fn open_store() -> (RocksDBCFStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("temp dir must be created");
        let db = SetuDB::open_default(dir.path()).expect("test db must open");
        (RocksDBCFStore::new(db), dir)
    }

    async fn store_finalized(store: &RocksDBCFStore, depth: u64, validator: &str) -> CFId {
        let cf = make_test_cf(depth, validator);
        let id = cf.id.clone();
        store.store(cf).await.expect("store must succeed");
        store.mark_finalized(&id).await.expect("mark_finalized must succeed");
        id
    }

    #[tokio::test]
    async fn rocks_get_finalized_after_depth_basic() {
        let (store, _dir) = open_store();
        for depth in [7u64, 3, 5, 9, 1] {
            store_finalized(&store, depth, "v1").await;
        }
        let result = store
            .get_finalized_after_depth(0, 100)
            .await
            .expect("query must succeed");
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![1, 3, 5, 7, 9]);
    }

    #[tokio::test]
    async fn rocks_get_finalized_after_depth_limit() {
        let (store, _dir) = open_store();
        for d in 1u64..=10 {
            store_finalized(&store, d, "v1").await;
        }
        let result = store
            .get_finalized_after_depth(0, 3)
            .await
            .expect("query must succeed");
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![1, 2, 3]);
    }

    #[tokio::test]
    async fn rocks_mark_finalized_writes_depth_index_atomically() {
        let (store, _dir) = open_store();
        let cf = make_test_cf(42, "v1");
        let id = cf.id.clone();
        store.store(cf).await.unwrap();
        store.mark_finalized(&id).await.unwrap();

        // Both finalized:{seq} and finalized_depth:{depth} must reference this cf_id.
        let finalized_keys = store
            .db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED)
            .unwrap();
        let depth_keys = store
            .db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
            .unwrap();
        assert_eq!(finalized_keys.len(), 1, "finalized index has one entry");
        assert_eq!(depth_keys.len(), 1, "finalized_depth index has one entry");

        let (depth, parsed_id) =
            RocksDBCFStore::extract_depth_and_cf_id(&depth_keys[0]).expect("parseable");
        assert_eq!(depth, 42);
        assert_eq!(parsed_id, id);
    }

    #[tokio::test]
    async fn rocks_backfill_runs_when_depth_index_missing() {
        let dir = tempfile::tempdir().expect("temp dir must be created");
        // Step 1: open store, write finalized CFs the normal way.
        let ids: Vec<CFId> = {
            let db = SetuDB::open_default(dir.path()).expect("open db");
            let store = RocksDBCFStore::new(db);
            let mut ids = Vec::new();
            for depth in [5u64, 2, 8] {
                ids.push(store_finalized(&store, depth, "v1").await);
            }
            ids
        };

        // Step 2: simulate pre-v3 data by deleting all finalized_depth entries.
        {
            let db = SetuDB::open_default(dir.path()).expect("reopen db");
            let depth_keys = db
                .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
                .unwrap();
            let mut batch = db.batch();
            for key in depth_keys {
                db.batch_delete_raw(&mut batch, ColumnFamily::ConsensusFrames, &key)
                    .unwrap();
            }
            db.write_batch(batch).unwrap();
            // Confirm the deletion took.
            let after = db
                .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
                .unwrap();
            assert!(after.is_empty(), "depth index must be empty before backfill");
        }

        // Step 3: re-open RocksDBCFStore; backfill should run automatically.
        let db = SetuDB::open_default(dir.path()).expect("reopen db post-wipe");
        let store = RocksDBCFStore::new(db);
        let result = store
            .get_finalized_after_depth(0, 100)
            .await
            .expect("query must succeed");
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![2, 5, 8], "backfill produced depth-sorted result");
        assert_eq!(result.len(), ids.len());
    }

    #[tokio::test]
    async fn rocks_backfill_skipped_when_depth_index_present() {
        let (store, _dir) = open_store();
        store_finalized(&store, 1, "v1").await;
        let before = store
            .db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
            .unwrap();
        assert_eq!(before.len(), 1);

        // Invoking backfill again must be a no-op (no duplicate keys, no panic).
        store
            .backfill_finalized_depth_index()
            .expect("backfill must not error on populated index");
        let after = store
            .db
            .prefix_scan_keys(ColumnFamily::ConsensusFrames, key_prefix::FINALIZED_DEPTH)
            .unwrap();
        assert_eq!(after.len(), 1, "no duplicate entries written");
    }

    #[tokio::test]
    async fn rocks_highest_finalized_depth() {
        let (store, _dir) = open_store();
        assert_eq!(store.highest_finalized_depth().await.unwrap(), 0);

        // pending at depth 9 must be ignored
        let pending_cf = make_test_cf(9, "v1");
        store.store(pending_cf).await.unwrap();
        store_finalized(&store, 5, "v2").await;
        store_finalized(&store, 3, "v2").await;

        assert_eq!(store.highest_finalized_depth().await.unwrap(), 5);
    }

    #[tokio::test]
    async fn rocks_reopen_preserves_depth_query() {
        let dir = tempfile::tempdir().expect("temp dir must be created");
        {
            let db = SetuDB::open_default(dir.path()).unwrap();
            let store = RocksDBCFStore::new(db);
            for d in [4u64, 1, 7, 2] {
                store_finalized(&store, d, "v1").await;
            }
        }
        // Reopen and re-query
        let db = SetuDB::open_default(dir.path()).unwrap();
        let store = RocksDBCFStore::new(db);
        let result = store
            .get_finalized_after_depth(1, 100)
            .await
            .expect("query");
        let depths: Vec<u64> = result.iter().map(|cf| cf.anchor.depth).collect();
        assert_eq!(depths, vec![2, 4, 7]);
        assert_eq!(store.highest_finalized_depth().await.unwrap(), 7);
    }

    #[tokio::test]
    async fn rocks_get_finalized_after_depth_strict_greater_than() {
        let (store, _dir) = open_store();
        store_finalized(&store, 5, "v1").await;
        let from_five = store
            .get_finalized_after_depth(5, 10)
            .await
            .expect("query");
        assert!(from_five.is_empty(), "depth == after_depth must be excluded");
        let from_four = store
            .get_finalized_after_depth(4, 10)
            .await
            .expect("query");
        assert_eq!(from_four.len(), 1);
    }

    // ========================================================================
    // Schema guard tests (PR-4b prerequisite)
    // ========================================================================

    #[test]
    fn validate_schema_passes_on_empty_db() {
        let (store, _dir) = open_store();
        store
            .validate_schema()
            .expect("empty DB must pass schema probe");
    }

    #[tokio::test]
    async fn validate_schema_passes_on_current_schema() {
        let (store, _dir) = open_store();
        for depth in [1u64, 2, 3] {
            store_finalized(&store, depth, "v1").await;
        }
        store
            .validate_schema()
            .expect("CFs written via current schema must decode cleanly");
    }

    #[tokio::test]
    async fn validate_schema_rejects_undecodable_blob() {
        let (store, _dir) = open_store();
        let id = store_finalized(&store, 1, "v1").await;

        // Overwrite the cf:{id} blob with bytes that BCS cannot decode as
        // ConsensusFrame. Using put_raw with a Vec<u8> serialises as length-
        // prefix + payload, which is structurally incompatible with the CF
        // layout — same failure shape an older on-disk schema would produce.
        let cf_key = RocksDBCFStore::cf_key(&id);
        store
            .db
            .put_raw(
                ColumnFamily::ConsensusFrames,
                &cf_key,
                &b"not-a-consensus-frame".to_vec(),
            )
            .expect("overwrite with garbage must succeed");

        let err = store
            .validate_schema()
            .expect_err("schema probe must reject undecodable blob");
        let msg = format!("{}", err);
        assert!(
            msg.contains("CF schema mismatch"),
            "error message must flag schema mismatch, got: {}",
            msg
        );
        assert!(
            msg.contains(&id),
            "error message must include the offending cf_id, got: {}",
            msg
        );
    }
}
