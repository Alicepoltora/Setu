use setu_types::{
    Anchor, ConsensusConfig, ConsensusFrame, EventId, Vote,
};
use crate::anchor_builder::{AnchorBuilder, AnchorBuildResult, AnchorBuildError, PendingAnchorBuild};
use crate::dag::Dag;
use crate::outcome_sink::OutcomeSink;
use crate::vlc::VLC;
use setu_storage::SharedStateManager;
use setu_storage::subnet_state::GlobalStateManager;
use std::collections::HashMap;
use std::sync::Arc;

/// Decision outcome for a ConsensusFrame
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CFDecision {
    Finalize,  // 2/3+1 approve votes
    Reject,    // 1/3+1 reject votes
    Timeout,   // Exceeded timeout threshold
}

/// Legacy DagFolder - kept for backward compatibility
/// For new code, use AnchorBuilder directly or through ConsensusManager
#[derive(Debug)]
pub struct DagFolder {
    config: ConsensusConfig,
    last_anchor: Option<Anchor>,
    anchor_depth: u64,
    last_fold_vlc: u64,
}

impl DagFolder {
    pub fn new(config: ConsensusConfig) -> Self {
        Self {
            config,
            last_anchor: None,
            anchor_depth: 0,
            last_fold_vlc: 0,
        }
    }

    pub fn should_fold(&self, current_vlc: &VLC) -> bool {
        let delta = current_vlc.logical_time().saturating_sub(self.last_fold_vlc);
        delta >= self.config.vlc_delta_threshold
    }

    pub fn fold(&mut self, dag: &Dag, vlc: &VLC, state_root: String) -> Option<Anchor> {
        if !self.should_fold(vlc) {
            return None;
        }

        let from_depth = self.anchor_depth;
        let to_depth = dag.max_depth();

        let events = dag.get_events_in_range(from_depth, to_depth);
        
        if events.len() < self.config.min_events_per_cf {
            return None;
        }

        let event_ids: Vec<EventId> = events
            .iter()
            .take(self.config.max_events_per_cf)
            .map(|e| e.id.clone())
            .collect();

        let anchor = Anchor::new(
            event_ids,
            vlc.snapshot(),
            state_root,
            self.last_anchor.as_ref().map(|a| a.id.clone()),
            to_depth,
        );

        self.last_anchor = Some(anchor.clone());
        self.anchor_depth = to_depth + 1;
        self.last_fold_vlc = vlc.logical_time();

        Some(anchor)
    }

    pub fn last_anchor(&self) -> Option<&Anchor> {
        self.last_anchor.as_ref()
    }

    pub fn anchor_depth(&self) -> u64 {
        self.anchor_depth
    }
}

/// Role classification for a CF that was discarded by `check_finalization`
/// due to a state-apply error. Used by `ApplyFailure` for diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyFailureRole {
    /// Leader path: `commit_build` returned a non-`SnapshotMismatch` error.
    LeaderCommitError,
    /// Leader path: `commit_build` returned `SnapshotMismatch`, follower fallback
    /// (`apply_follower_finalized_cf`) then returned an error.
    LeaderFollowerFallback,
    /// Follower path: deferred apply (`apply_follower_finalized_cf`) returned an error.
    Follower,
}

/// Diagnostic record for a CF that reached quorum but failed state-apply.
///
/// Stored on `ConsensusManager` and overwritten on every new apply failure.
/// The failed CF is NOT pushed into `finalized_cfs` and the engine does NOT
/// persist/broadcast/advance-round for it. Events referenced by the failed CF
/// remain in `dag.events` and will be re-folded into a future CF.
#[derive(Debug, Clone)]
pub struct ApplyFailure {
    pub cf_id: String,
    pub anchor_id: String,
    pub anchor_depth: u64,
    pub role: ApplyFailureRole,
    pub reason: String,
}

/// ConsensusManager with integrated AnchorBuilder for Merkle tree management
/// 
/// This manager handles:
/// - Anchor creation with full Merkle tree computation (via AnchorBuilder)
/// - ConsensusFrame creation, voting, and finalization
/// - State management across all subnets
///
/// ## Deferred Commit Mode
/// 
/// Uses a deferred commit pattern for safe state management:
/// - `try_create_cf()` calls `prepare_build()` which computes but doesn't modify state
/// - On finalization, `commit_build()` applies the pending state changes
/// - On rejection/timeout, pending_builds are simply discarded (no rollback needed)
pub struct ConsensusManager {
    config: ConsensusConfig,
    /// AnchorBuilder handles DAG folding with Merkle tree updates
    anchor_builder: AnchorBuilder,
    /// Legacy folder (kept for backward compatibility, not used in main flow)
    #[allow(dead_code)]
    legacy_folder: DagFolder,
    /// Pending ConsensusFrames awaiting votes
    pending_cfs: HashMap<String, ConsensusFrame>,
    /// Pending anchor builds awaiting finalization (cf_id -> PendingAnchorBuild)
    pending_builds: HashMap<String, PendingAnchorBuild>,
    /// Events collected for each pending CF (cf_id -> events).
    /// Stored on CF arrival so they can be applied at finalization time,
    /// avoiding out-of-order pre-apply issues on Followers.
    pending_cf_events: HashMap<String, Vec<setu_types::Event>>,
    /// Votes received before their CF proposal arrived.
    /// In P2P networks, votes can arrive before proposals due to network ordering.
    /// These are replayed when the CF is received via `receive_cf`.
    buffered_votes: HashMap<String, Vec<Vote>>,
    /// Finalized ConsensusFrames
    finalized_cfs: Vec<ConsensusFrame>,
    /// Set of anchor IDs that have been persisted to storage
    /// Used to safely garbage collect finalized_cfs
    persisted_anchor_ids: std::collections::HashSet<String>,
    /// This validator's ID
    local_validator_id: String,
    /// Last build result for diagnostics
    last_build_result: Option<AnchorBuildResult>,
    /// Most recent apply-failure observed by `check_finalization`.
    /// Overwritten on each failure; cleared on construction.
    /// Read by tests and operational diagnostics; never persisted or broadcast.
    last_apply_failure: Option<ApplyFailure>,
}

impl ConsensusManager {
    /// Create a new ConsensusManager with AnchorBuilder
    pub fn new(config: ConsensusConfig, validator_id: String) -> Self {
        Self {
            config: config.clone(),
            anchor_builder: AnchorBuilder::new(config.clone()),
            legacy_folder: DagFolder::new(config),
            pending_cfs: HashMap::new(),
            pending_builds: HashMap::new(),
            pending_cf_events: HashMap::new(),
            buffered_votes: HashMap::new(),
            finalized_cfs: Vec::new(),
            persisted_anchor_ids: std::collections::HashSet::new(),
            local_validator_id: validator_id,
            last_build_result: None,
            last_apply_failure: None,
        }
    }
    
    /// Create with a shared GlobalStateManager (for state persistence and sharing)
    pub fn with_shared_state_manager(
        config: ConsensusConfig, 
        validator_id: String,
        state_manager: Arc<SharedStateManager>,
    ) -> Self {
        Self {
            config: config.clone(),
            anchor_builder: AnchorBuilder::with_shared_state_manager(config.clone(), state_manager),
            legacy_folder: DagFolder::new(config),
            pending_cfs: HashMap::new(),
            pending_builds: HashMap::new(),
            pending_cf_events: HashMap::new(),
            buffered_votes: HashMap::new(),
            finalized_cfs: Vec::new(),
            persisted_anchor_ids: std::collections::HashSet::new(),
            local_validator_id: validator_id,
            last_build_result: None,
            last_apply_failure: None,
        }
    }

    /// R5 · Inject an outcome sink; forwarded to the underlying AnchorBuilder.
    ///
    /// Default = no sink (`ingest_outcomes` short-circuits). Called once by
    /// `ConsensusEngine::set_outcomes_sink` during validator initialization.
    pub fn set_outcomes_sink(&mut self, sink: Arc<dyn OutcomeSink>) {
        self.anchor_builder.set_outcomes_sink(sink);
    }

    /// Try to create a ConsensusFrame with full Merkle tree computation
    /// 
    /// Uses deferred commit mode:
    /// 1. Calls prepare_build() which computes but doesn't modify state
    /// 2. Stores PendingAnchorBuild for later commit on finalization
    /// 3. Creates ConsensusFrame for voting
    pub fn try_create_cf(
        &mut self,
        dag: &Dag,
        vlc: &VLC,
    ) -> Option<ConsensusFrame> {
        // BUG-010 Step 2: enforce one open pending_build per local proposer.
        // current_round only advances after the local proposer's own CF finalizes,
        // so any entry in pending_builds belongs to the current round / current
        // anchor depth. Creating a second CF here would prepare against the same
        // pre-state base and inevitably hit SnapshotMismatch on the loser CF.
        if !self.pending_builds.is_empty() {
            tracing::debug!(
                pending_builds = self.pending_builds.len(),
                "try_create_cf skipped: pending_build already open for current round"
            );
            return None;
        }

        // D1: compute the set of event-ids already referenced by in-flight CFs
        // (leader's pending_builds + follower's pending_cf_events). Passed to
        // prepare_build so the pending-status selection excludes them.
        let in_flight = self.collect_in_flight_event_ids();
        // Use AnchorBuilder.prepare_build (deferred commit mode)
        match self.anchor_builder.prepare_build(dag, vlc, &in_flight) {
            Ok(pending_build) => self.finalize_pending_build(pending_build),
            Err(AnchorBuildError::DeltaNotReached { required, current }) => {
                tracing::debug!(required, current, "CF not created: DeltaNotReached");
                None
            }
            Err(AnchorBuildError::InsufficientEvents { required, found }) => {
                tracing::debug!(required, found, "CF not created: InsufficientEvents");
                None
            }
            Err(AnchorBuildError::NoEvents) => {
                tracing::debug!("CF not created: NoEvents");
                None
            }
            Err(e) => {
                // Log error but don't crash
                tracing::error!(error = %e, "AnchorBuilder error");
                None
            }
        }
    }

    /// Common post-build logic: create CF from anchor, store pending_build.
    fn finalize_pending_build(&mut self, pending_build: PendingAnchorBuild) -> Option<ConsensusFrame> {
        let anchor = pending_build.anchor.clone();
        tracing::info!(
            anchor_id = %anchor.id,
            event_count = anchor.event_ids.len(),
            "CF created with anchor"
        );
        let cf = ConsensusFrame::new(anchor, self.local_validator_id.clone());
        self.pending_builds.insert(cf.id.clone(), pending_build);
        self.pending_cfs.insert(cf.id.clone(), cf.clone());
        Some(cf)
    }

    /// Heartbeat: try to create CF with relaxed delta (delta >= 1 + time guard).
    /// Returns None if conditions not met.
    pub fn try_create_cf_heartbeat(
        &mut self,
        dag: &Dag,
        vlc: &VLC,
        heartbeat_interval: std::time::Duration,
    ) -> Option<ConsensusFrame> {
        let in_flight = self.collect_in_flight_event_ids();
        match self.anchor_builder.prepare_build_heartbeat(dag, vlc, heartbeat_interval, &in_flight) {
            Ok(pending_build) => self.finalize_pending_build(pending_build),
            Err(_) => None,
        }
    }

    /// D1: event-ids already referenced by in-flight CFs, to be excluded
    /// from the next fold. Combines `pending_builds` (leader path, Anchor
    /// event_ids already committed to a not-yet-finalized CF) and
    /// `pending_cf_events` (follower path, deferred events for a received
    /// CF that hasn't finalized yet).
    fn collect_in_flight_event_ids(&self) -> std::collections::HashSet<setu_types::EventId> {
        let mut set: std::collections::HashSet<setu_types::EventId> =
            std::collections::HashSet::new();
        for build in self.pending_builds.values() {
            for id in &build.anchor.event_ids {
                set.insert(id.clone());
            }
        }
        for events in self.pending_cf_events.values() {
            for ev in events {
                set.insert(ev.id.clone());
            }
        }
        set
    }

    /// Check if a CF (pending or finalized) already exists
    pub fn has_cf(&self, cf_id: &str) -> bool {
        self.pending_cfs.contains_key(cf_id) ||
            self.finalized_cfs.iter().any(|cf| cf.id == cf_id)
    }

    pub fn is_finalized_cf(&self, cf_id: &str) -> bool {
        self.finalized_cfs.iter().any(|cf| cf.id == cf_id)
    }

    #[cfg(test)]
    pub fn pending_counts_for_testing(&self) -> (usize, usize) {
        (self.pending_cfs.len(), self.pending_cf_events.len())
    }

    /// Number of open pending_builds (test-only).
    /// Used by BUG-010 regression tests to verify the Step 2 guard contract.
    #[cfg(test)]
    pub fn pending_builds_len_for_testing(&self) -> usize {
        self.pending_builds.len()
    }

    pub fn receive_cf(&mut self, cf: ConsensusFrame) {
        let cf_id = cf.id.clone();
        if !self.pending_cfs.contains_key(&cf_id) {
            self.pending_cfs.insert(cf_id.clone(), cf);
            
            // Replay any votes that arrived before this CF proposal.
            if let Some(buffered) = self.buffered_votes.remove(&cf_id) {
                if let Some(cf) = self.pending_cfs.get_mut(&cf_id) {
                    for vote in buffered {
                        if !cf.votes.contains_key(&vote.validator_id) {
                            cf.add_vote(vote);
                        }
                    }
                }
            }
        }
    }

    pub fn receive_finalized_cf(&mut self, cf: ConsensusFrame) -> bool {
        let cf_id = cf.id.clone();
        if self.is_finalized_cf(&cf_id) {
            return false;
        }

        if let Some(existing) = self.pending_cfs.get_mut(&cf_id) {
            for vote in cf.votes.values() {
                if !existing.votes.contains_key(&vote.validator_id) {
                    existing.add_vote(vote.clone());
                }
            }
        } else {
            self.receive_cf(cf);
        }

        self.check_finalization(&cf_id)
    }

    /// Vote for a ConsensusFrame
    /// 
    /// Args:
    /// - cf_id: The CF ID to vote for
    /// - approve: Whether to approve (true) or reject (false)
    /// - private_key: Optional private key for signing the vote (32 bytes for ed25519)
    /// 
    /// Returns the vote if successful, None if:
    /// - CF not found
    /// - Already voted for this CF
    pub fn vote_for_cf(
        &mut self, 
        cf_id: &str, 
        approve: bool,
        private_key: Option<&[u8]>
    ) -> Option<Vote> {
        let cf = self.pending_cfs.get_mut(cf_id)?;
        
        if cf.votes.contains_key(&self.local_validator_id) {
            return None;
        }

        let mut vote = Vote::new(self.local_validator_id.clone(), cf_id.to_string(), approve);
        
        // Sign the vote if private key is provided
        if let Some(key) = private_key {
            if let Err(e) = vote.sign(key) {
                tracing::warn!(
                    cf_id = %cf_id,
                    error = %e,
                    "Failed to sign vote - continuing without signature for backward compatibility"
                );
            }
        }
        
        cf.add_vote(vote.clone());
        
        Some(vote)
    }

    /// Receive a vote from another validator
    /// 
    /// Returns true if this vote changes the CF lifecycle by finalizing,
    /// rejecting, or timing out the pending CF. Duplicate votes from the same
    /// validator are ignored (idempotent). Engine callers must verify the
    /// target CF is actually the last finalized CF before running finalization
    /// side effects such as broadcast, persistence, or round advance.
    pub fn receive_vote(&mut self, vote: Vote) -> bool {
        let cf_id = vote.cf_id.clone();
        let voter_id = vote.validator_id.clone();
        
        if let Some(cf) = self.pending_cfs.get_mut(&cf_id) {
            // Skip if this validator already voted (idempotency)
            if cf.votes.contains_key(&voter_id) {
                return false;
            }
            cf.add_vote(vote);
        } else {
            // CF not yet received — buffer the vote for later replay.
            // In P2P networks, votes can arrive before their CF proposal.
            self.buffered_votes.entry(cf_id.clone()).or_default().push(vote);
            return false;
        }
        self.check_finalization(&cf_id)
    }

    /// Check if a CF has reached quorum (finalize), rejection threshold (reject), or timeout
    /// 
    /// This is called after adding a vote to check if finalization/rejection should occur.
    /// Public because engine.receive_cf() needs to check after vote_for_cf().
    /// 
    /// Returns true if CF was finalized or rejected/timed out (removed from pending).
    /// Engine callers must check the last finalized CF id before treating this
    /// as a finalized outcome.
    pub fn check_finalization(&mut self, cf_id: &str) -> bool {
        let decision = {
            let cf = match self.pending_cfs.get(cf_id) {
                Some(cf) => cf,
                None => return false,
            };
            
            // Check if CF should be finalized (2/3+1 approve)
            if cf.check_quorum(self.config.validator_count) {
                Some(CFDecision::Finalize)
            }
            // Check if CF should be rejected (1/3+1 reject)
            else if cf.check_rejection(self.config.validator_count) {
                Some(CFDecision::Reject)
            }
            // Check if CF has timed out
            else if cf.is_timeout(self.config.cf_timeout_ms) {
                Some(CFDecision::Timeout)
            } else {
                None  // still pending
            }
        };

        match decision {
            Some(CFDecision::Finalize) => {
                if let Some(mut cf) = self.pending_cfs.remove(cf_id) {
                    cf.finalize();
                    let anchor_id = cf.anchor.id.clone();
                    let anchor_depth = cf.anchor.depth;

                    // Outcome of the apply attempt. Only Ok(()) pushes the CF into
                    // finalized_cfs; Err(_) discards the CF, records the failure, and
                    // causes check_finalization to return false so the engine's
                    // existing `manager_last_finalized_matches` guard skips persist/
                    // broadcast/round-advance. Events stay in dag.events for re-folding.
                    // See docs/feat/fix-bug010-finality-stall/design.md.
                    let apply_outcome: Result<(), ApplyFailure> =
                        if let Some(pending_build) = self.pending_builds.remove(cf_id) {
                            // Leader path: commit the pending build
                            // Clean up stored events (Leader uses pending_build's events)
                            self.pending_cf_events.remove(cf_id);
                            tracing::info!(cf_id = %cf_id, "Leader path: committing pending build");
                            match self.anchor_builder.commit_build(pending_build.clone()) {
                                Ok(state_summary) => {
                                    tracing::info!(
                                        cf_id = %cf_id,
                                        total_events = state_summary.total_events,
                                        total_changes = state_summary.total_changes,
                                        conflicted = state_summary.conflicted_events.len(),
                                        "Leader path: commit_build succeeded"
                                    );
                                    // Store result for diagnostics
                                    self.last_build_result = Some(AnchorBuildResult {
                                        anchor: cf.anchor.clone(),
                                        state_summary,
                                        routed_events: pending_build.routed_events,
                                    });
                                    Ok(())
                                }
                                Err(AnchorBuildError::SnapshotMismatch { .. }) => {
                                    // Another CF was committed first - use Follower path
                                    tracing::warn!(cf_id = %cf_id, "Snapshot mismatch during commit, falling back to follower path");
                                    let events = pending_build.all_events();
                                    match self.anchor_builder.apply_follower_finalized_cf(&events, &cf) {
                                        Ok(_) => Ok(()),
                                        Err(e) => {
                                            tracing::error!(
                                                cf_id = %cf_id, error = %e,
                                                "Follower fallback failed; discarding CF (BUG-010 fail-closed)"
                                            );
                                            Err(ApplyFailure {
                                                cf_id: cf_id.to_string(),
                                                anchor_id: anchor_id.clone(),
                                                anchor_depth,
                                                role: ApplyFailureRole::LeaderFollowerFallback,
                                                reason: e.to_string(),
                                            })
                                        }
                                    }
                                }
                                Err(e) => {
                                    // Other error - discard CF (BUG-010 fail-closed)
                                    tracing::error!(
                                        cf_id = %cf_id, error = %e,
                                        "commit_build failed; discarding CF (BUG-010 fail-closed)"
                                    );
                                    Err(ApplyFailure {
                                        cf_id: cf_id.to_string(),
                                        anchor_id: anchor_id.clone(),
                                        anchor_depth,
                                        role: ApplyFailureRole::LeaderCommitError,
                                        reason: e.to_string(),
                                            })
                                }
                            }
                        } else {
                            // Follower path: apply state at finalization time (deferred apply).
                            // Events were stored in pending_cf_events when the CF arrived.
                            // Applying here (not on arrival) guarantees correct ordering:
                            // CFs finalize in Leader commit order, so the write GSM base
                            // state always matches what the Leader computed against.
                            let events = self.pending_cf_events.remove(cf_id).unwrap_or_default();
                            tracing::info!(cf_id = %cf_id, event_count = events.len(), "Follower path: applying deferred state");
                            match self.anchor_builder.apply_follower_finalized_cf(&events, &cf) {
                                Ok(state_summary) => {
                                    tracing::info!(
                                        cf_id = %cf_id,
                                        total_events = state_summary.total_events,
                                        total_changes = state_summary.total_changes,
                                        "Follower path: state applied and committed"
                                    );
                                    Ok(())
                                }
                                Err(e) => {
                                    tracing::error!(
                                        cf_id = %cf_id, error = %e,
                                        "Follower deferred apply failed; discarding CF (BUG-010 fail-closed)"
                                    );
                                    Err(ApplyFailure {
                                        cf_id: cf_id.to_string(),
                                        anchor_id: anchor_id.clone(),
                                        anchor_depth,
                                        role: ApplyFailureRole::Follower,
                                        reason: e.to_string(),
                                    })
                                }
                            }
                        };

                    match apply_outcome {
                        Ok(()) => {
                            self.last_apply_failure = None;
                            self.finalized_cfs.push(cf);
                            self.gc_finalized_cfs();
                            return true;
                        }
                        Err(failure) => {
                            // CF discarded; do NOT push to finalized_cfs, do NOT call
                            // synchronize_finalized_anchor. last_finalized_cf() therefore
                            // does not advance, and the engine's
                            // manager_last_finalized_matches guard correctly skips
                            // persist/broadcast/round-advance for this cf_id.
                            self.last_apply_failure = Some(failure);
                            return false;
                        }
                    }
                }
            }
            Some(CFDecision::Reject) | Some(CFDecision::Timeout) => {
                // Remove rejected/timeout CF from pending
                if let Some(mut cf) = self.pending_cfs.remove(cf_id) {
                    // Simply discard the pending_build and stored events (no rollback needed!)
                    self.pending_builds.remove(cf_id);
                    self.pending_cf_events.remove(cf_id);
                    cf.reject();
                    return true;
                }
            }
            None => {}
        }
        false
    }
    
    /// Mark an anchor as persisted to storage
    /// 
    /// Call this after successfully storing the anchor to AnchorStore.
    /// This enables safe garbage collection of finalized CFs.
    pub fn mark_anchor_persisted(&mut self, anchor_id: &str) {
        self.persisted_anchor_ids.insert(anchor_id.to_string());
        // Note: persisted_anchor_ids is cleaned up when corresponding CFs are GC'd
        // in gc_finalized_cfs(), so it won't grow unbounded
    }
    
    /// Garbage collect finalized CFs, only removing those that have been persisted
    fn gc_finalized_cfs(&mut self) {
        const MAX_FINALIZED_CFS: usize = 1000;
        
        if self.finalized_cfs.len() <= MAX_FINALIZED_CFS {
            return;
        }
        
        let excess = self.finalized_cfs.len() - MAX_FINALIZED_CFS;
        
        // Collect anchor IDs that will be removed (for cleaning persisted_anchor_ids)
        let mut removed_anchor_ids = Vec::new();
        let mut removed_count = 0;
        
        // Only remove CFs that have been persisted
        self.finalized_cfs.retain(|cf| {
            if removed_count >= excess {
                return true;
            }
            if self.persisted_anchor_ids.contains(&cf.anchor.id) {
                removed_anchor_ids.push(cf.anchor.id.clone());
                removed_count += 1;
                false // remove this CF
            } else {
                true // keep unpersisted CF
            }
        });
        
        // Clean up persisted_anchor_ids for removed CFs
        for id in removed_anchor_ids {
            self.persisted_anchor_ids.remove(&id);
        }
        
        // Safety valve: if too many unpersisted CFs, log warning but don't drop
    }
    
    /// Clean up pending CFs that have timed out
    /// 
    /// This prevents memory leaks from CFs that never reach quorum due to:
    /// - Network partitions
    /// - Node failures
    /// - Insufficient votes
    /// 
    /// Should be called periodically (e.g., every few seconds) by the consensus engine.
    /// Returns the number of CFs that were removed.
    pub fn cleanup_timeout_cfs(&mut self) -> usize {
        let timeout_ms = self.config.cf_timeout_ms;
        let timeout_ids: Vec<String> = self.pending_cfs
            .iter()
            .filter(|(_, cf)| cf.is_timeout(timeout_ms))
            .map(|(id, _)| id.clone())
            .collect();
        
        let count = timeout_ids.len();
        for id in timeout_ids {
            if let Some(mut cf) = self.pending_cfs.remove(&id) {
                // Simply discard the pending_build (no rollback needed in deferred commit mode!)
                self.pending_builds.remove(&id);
                self.pending_cf_events.remove(&id);
                self.buffered_votes.remove(&id);
                cf.reject();
            }
        }
        count
    }
    
    /// Get the last finalized anchor (for storage)
    pub fn get_last_finalized_anchor(&self) -> Option<setu_types::Anchor> {
        self.finalized_cfs.last().map(|cf| cf.anchor.clone())
    }

    pub fn get_pending_cf(&self, cf_id: &str) -> Option<&ConsensusFrame> {
        self.pending_cfs.get(cf_id)
    }

    pub fn finalized_count(&self) -> usize {
        self.finalized_cfs.len()
    }

    #[cfg(test)]
    pub fn has_persisted_anchor_for_testing(&self, anchor_id: &str) -> bool {
        self.persisted_anchor_ids.contains(anchor_id)
    }

    pub fn last_finalized_cf(&self) -> Option<&ConsensusFrame> {
        self.finalized_cfs.last()
    }

    pub fn should_fold(&self, vlc: &VLC) -> bool {
        self.anchor_builder.should_fold(vlc)
    }

    /// Dynamically update validator_count (affects quorum calculation).
    ///
    /// Called when validators are added/removed from the consensus set.
    pub fn update_validator_count(&mut self, count: usize) {
        let old_count = self.config.validator_count;
        self.config.validator_count = count;
        tracing::info!(
            old_count = old_count,
            new_count = count,
            new_quorum = (count * 2) / 3 + 1,
            "Validator count updated"
        );
    }

    /// Get the current validator_count.
    pub fn validator_count(&self) -> usize {
        self.config.validator_count
    }

    // =========================================================================
    // New methods for Merkle tree access
    // =========================================================================
    
    /// Get the AnchorBuilder (read-only)
    pub fn anchor_builder(&self) -> &AnchorBuilder {
        &self.anchor_builder
    }
    
    /// Get the AnchorBuilder (mutable)
    pub fn anchor_builder_mut(&mut self) -> &mut AnchorBuilder {
        &mut self.anchor_builder
    }
    
    /// Get the shared GlobalStateManager
    pub fn shared_state_manager(&self) -> Arc<SharedStateManager> {
        self.anchor_builder.shared_state_manager()
    }
    
    /// Access the GlobalStateManager with a closure (read-only)
    pub fn with_state_manager<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&GlobalStateManager) -> R,
    {
        self.anchor_builder.with_state_manager(f)
    }
    
    /// Access the GlobalStateManager with a closure (mutable)
    pub fn with_state_manager_mut<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&mut GlobalStateManager) -> R,
    {
        self.anchor_builder.with_state_manager_mut(f)
    }
    
    /// Get the last build result (for diagnostics)
    pub fn last_build_result(&self) -> Option<&AnchorBuildResult> {
        self.last_build_result.as_ref()
    }

    /// Get the most recent apply-failure observed by `check_finalization`.
    /// Returns `None` if no apply failure has occurred since construction or the
    /// last successful finalization.
    pub fn last_apply_failure(&self) -> Option<&ApplyFailure> {
        self.last_apply_failure.as_ref()
    }
    
    /// Get a subnet's current state root
    pub fn get_subnet_root(&self, subnet_id: &setu_types::SubnetId) -> Option<[u8; 32]> {
        self.anchor_builder.get_subnet_root(subnet_id)
    }
    
    /// Get the current global state root
    pub fn get_global_root(&self) -> [u8; 32] {
        self.anchor_builder.get_global_root()
    }
    
    /// Get anchor count
    pub fn anchor_count(&self) -> usize {
        self.anchor_builder.anchor_count()
    }
    
    // =========================================================================
    // Follower State Synchronization
    // =========================================================================
    
    /// Collect and store events from a received ConsensusFrame for later
    /// application at finalization time (Follower path).
    ///
    /// Previously this method pre-applied events to the write GSM immediately
    /// on CF arrival. This caused cascading failures when CFs arrived out of
    /// order at Followers: the base state differed from the Leader's, root
    /// verification failed, and the CF was rejected entirely.
    ///
    /// New approach (deferred apply):
    /// 1. Collect events from the DAG
    /// 2. Store them in `pending_cf_events` for use at finalization
    /// 3. Do NOT mutate the write GSM
    /// 4. State is applied at finalization time via `apply_follower_finalized_cf`,
    ///    which guarantees correct ordering (CFs finalize in Leader order).
    ///
    /// Always returns true so the CF is received and voted on regardless.
    pub fn apply_cf_state_changes(&mut self, dag: &Dag, cf: &setu_types::ConsensusFrame) -> bool {
        // Get events from the anchor's event_ids
        let events: Vec<setu_types::Event> = cf.anchor.event_ids
            .iter()
            .filter_map(|id| dag.get_event(id).cloned())
            .collect();
        
        // Store events for deferred application at finalization time
        self.pending_cf_events.insert(cf.id.clone(), events);
        
        true
    }
    
    /// Verify a ConsensusFrame's merkle roots without applying state
    /// 
    /// This is a lighter verification that just checks the anchor's
    /// merkle roots are internally consistent.
    pub fn verify_cf_merkle_roots(&self, cf: &setu_types::ConsensusFrame) -> bool {
        let Some(ref merkle_roots) = cf.anchor.merkle_roots else {
            // No merkle roots to verify (legacy anchor)
            return true;
        };
        
        // Verify events_root is not all zeros (unless no events)
        if cf.anchor.event_ids.is_empty() && merkle_roots.events_root != [0u8; 32] {
            return false;
        }
        
        // Verify global_state_root is not all zeros (should have at least ROOT subnet)
        if merkle_roots.global_state_root == [0u8; 32] && !merkle_roots.subnet_roots.is_empty() {
            return false;
        }
        
        // Verify subnet_roots contains at least ROOT subnet
        if !merkle_roots.subnet_roots.is_empty() {
            if !merkle_roots.subnet_roots.contains_key(&setu_types::SubnetId::ROOT) {
                return false;
            }
        }
        
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use setu_types::{Event, EventType, VLCSnapshot, AnchorMerkleRoots};

    fn create_vlc(node_id: &str, time: u64) -> VLC {
        let mut vlc = VLC::new(node_id.to_string());
        for _ in 0..time {
            vlc.tick();
        }
        vlc
    }

    fn setup_dag_with_events(count: usize) -> (Dag, VLC) {
        let mut dag = Dag::new();
        let mut vlc = VLC::new("node1".to_string());

        let genesis = Event::genesis("node1".to_string(), vlc.snapshot());
        let mut last_id = dag.add_event(genesis).unwrap();

        for _ in 1..count {
            vlc.tick();
            let event = Event::new(
                EventType::Transfer,
                vec![last_id.clone()],
                vlc.snapshot(),
                "node1".to_string(),
            );
            last_id = dag.add_event(event).unwrap();
        }

        (dag, vlc)
    }

    #[test]
    fn test_folder_should_fold() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 10,
            ..Default::default()
        };
        let folder = DagFolder::new(config);
        
        let vlc = create_vlc("node1", 5);
        assert!(!folder.should_fold(&vlc));

        let vlc = create_vlc("node1", 10);
        assert!(folder.should_fold(&vlc));
    }

    #[test]
    fn test_consensus_manager_create_cf() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "validator1".to_string());
        let (dag, vlc) = setup_dag_with_events(10);

        // New API: try_create_cf without external state_root
        let cf = manager.try_create_cf(&dag, &vlc);
        assert!(cf.is_some());
        
        // Verify anchor has merkle_roots
        let cf = cf.unwrap();
        assert!(cf.anchor.merkle_roots.is_some());
    }
    
    #[test]
    fn test_consensus_manager_state_access() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            validator_count: 1,  // Single validator for immediate finalization
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "validator1".to_string());
        let (dag, vlc) = setup_dag_with_events(10);

        // Create CF (deferred commit mode - state not modified yet)
        let cf = manager.try_create_cf(&dag, &vlc);
        assert!(cf.is_some());
        let cf_id = cf.unwrap().id.clone();
        
        // State not committed yet (prepare_build only)
        assert_eq!(manager.anchor_count(), 0);
        
        // Vote to finalize (single validator, so immediate finalization)
        manager.vote_for_cf(&cf_id, true, None);
        let finalized = manager.check_finalization(&cf_id);
        assert!(finalized, "CF should be finalized with single validator");
        
        // Now state should be committed
        assert_eq!(manager.anchor_count(), 1);
        
        // Global root should be computed
        let global_root = manager.get_global_root();
        assert_ne!(global_root, [0u8; 32]);
    }

    #[test]
    fn test_receive_finalized_cf_merges_votes_into_pending_cf() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            validator_count: 3,
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "validator1".to_string());
        let anchor = Anchor::new(
            vec![],
            VLCSnapshot::default(),
            "state-root".to_string(),
            None,
            0,
        );
        let mut pending_cf = ConsensusFrame::new(anchor, "validator1".to_string());
        let cf_id = pending_cf.id.clone();
        pending_cf.add_vote(Vote::new("validator1".to_string(), cf_id.clone(), true));
        manager.receive_cf(pending_cf.clone());

        let mut finalized_cf = pending_cf;
        finalized_cf.add_vote(Vote::new("validator2".to_string(), cf_id.clone(), true));
        finalized_cf.add_vote(Vote::new("validator3".to_string(), cf_id.clone(), true));
        finalized_cf.finalize();
        let duplicate_finalized_cf = finalized_cf.clone();

        assert!(manager.receive_finalized_cf(finalized_cf));
        assert!(manager.is_finalized_cf(&cf_id));
        assert!(!manager.receive_finalized_cf(duplicate_finalized_cf));
    }

    // ------------------------------------------------------------------
    // BUG-010 regression tests.
    // See docs/feat/fix-bug010-finality-stall/design.md.
    // ------------------------------------------------------------------

    /// Step 2 guard: try_create_cf must skip when a pending_build is already
    /// open for the current round (one proposer => one in-flight CF).
    #[test]
    fn bug010_try_create_cf_skips_when_pending_build_open() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            validator_count: 3,
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "v1".to_string());
        let (dag, vlc) = setup_dag_with_events(10);

        let first = manager.try_create_cf(&dag, &vlc);
        assert!(first.is_some(), "first try_create_cf should produce a CF");

        // Second call must be skipped by the Step 2 guard because the first
        // CF's pending_build is still open (not yet finalized).
        let second = manager.try_create_cf(&dag, &vlc);
        assert!(
            second.is_none(),
            "second try_create_cf must return None while pending_build is open"
        );
    }

    /// Step 2 guard: once the pending_build is drained (CF finalizes
    /// successfully), the guard no longer blocks new CF creation.
    /// We assert the guard's direct precondition (pending_builds emptiness)
    /// rather than driving a second try_create_cf, which depends on unrelated
    /// vlc/delta thresholds and dag growth.
    #[test]
    fn bug010_pending_builds_drained_after_successful_finalize() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            validator_count: 1, // self-quorum for instant finalize
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "v1".to_string());
        let (dag, vlc) = setup_dag_with_events(10);

        let cf = manager.try_create_cf(&dag, &vlc).expect("first CF");
        let cf_id = cf.id.clone();
        assert_eq!(
            manager.pending_builds_len_for_testing(),
            1,
            "pending_build must be open after try_create_cf"
        );

        manager.vote_for_cf(&cf_id, true, None);
        assert!(manager.check_finalization(&cf_id), "CF should finalize");

        assert_eq!(
            manager.pending_builds_len_for_testing(),
            0,
            "pending_builds must be empty after successful finalize \
             (Step 2 guard would otherwise permanently block new CFs)"
        );
    }

    /// Step 1 fail-closed: a follower-path CF whose declared global_state_root
    /// does NOT match the locally-computed root must be DROPPED:
    ///   - check_finalization returns false
    ///   - the CF is NOT pushed into finalized_cfs
    ///   - last_apply_failure records the Follower role
    ///   - last_finalized_cf remains unchanged (no spurious advance)
    ///
    /// This is the core BUG-010 regression: previously the error branch called
    /// synchronize_finalized_anchor + finalized_cfs.push, lying to the engine
    /// that the CF had finalized despite no state apply.
    #[test]
    fn bug010_follower_apply_failure_drops_cf_and_does_not_advance() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            validator_count: 3,
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "v1".to_string());
        let (dag, vlc) = setup_dag_with_events(3);

        // Build a foreign-looking CF directly (NOT via try_create_cf), so
        // pending_builds stays empty and check_finalization takes the
        // follower deferred-apply path.
        let event_ids: Vec<_> = dag.all_events().map(|e| e.id.clone()).collect();
        assert_eq!(event_ids.len(), 3);

        let bad_roots = AnchorMerkleRoots {
            events_root: [0u8; 32],
            global_state_root: [0xFFu8; 32], // intentionally wrong
            anchor_chain_root: [0u8; 32],
            subnet_roots: Default::default(),
        };
        let anchor = Anchor::with_merkle_roots(
            event_ids,
            vlc.snapshot(),
            bad_roots,
            None,
            0,
        );
        let cf = ConsensusFrame::new(anchor, "v2".to_string());
        let cf_id = cf.id.clone();

        // Receive the CF and inject its events into pending_cf_events so the
        // follower deferred-apply path has work to do.
        manager.receive_cf(cf.clone());
        assert!(manager.apply_cf_state_changes(&dag, &cf));

        // Drive to quorum: self vote + two foreign votes via receive_finalized_cf.
        manager.vote_for_cf(&cf_id, true, None);
        let mut quorum_cf = cf.clone();
        quorum_cf.add_vote(Vote::new("v1".to_string(), cf_id.clone(), true));
        quorum_cf.add_vote(Vote::new("v2".to_string(), cf_id.clone(), true));
        quorum_cf.add_vote(Vote::new("v3".to_string(), cf_id.clone(), true));

        let finalized_ok = manager.receive_finalized_cf(quorum_cf);

        // The CF must be REJECTED (apply failed → fail-closed).
        assert!(
            !finalized_ok,
            "receive_finalized_cf must return false when follower apply fails"
        );
        assert!(
            !manager.is_finalized_cf(&cf_id),
            "failed-apply CF must NOT be marked finalized"
        );
        assert!(
            manager.last_finalized_cf().is_none(),
            "last_finalized_cf must stay None (no spurious advance)"
        );

        let failure = manager
            .last_apply_failure()
            .expect("last_apply_failure must be populated on follower apply error");
        assert_eq!(failure.cf_id, cf_id);
        assert_eq!(failure.role, ApplyFailureRole::Follower);
        assert!(
            !failure.reason.is_empty(),
            "failure.reason should carry the underlying error text"
        );
    }

    /// Regression: a CF that applies cleanly on the leader path still finalizes
    /// and clears any prior last_apply_failure record.
    #[test]
    fn bug010_successful_apply_finalizes_and_clears_failure() {
        let config = ConsensusConfig {
            vlc_delta_threshold: 5,
            min_events_per_cf: 1,
            validator_count: 1, // self-quorum
            ..Default::default()
        };
        let mut manager = ConsensusManager::new(config, "v1".to_string());
        let (dag, vlc) = setup_dag_with_events(10);

        let cf = manager.try_create_cf(&dag, &vlc).expect("CF");
        let cf_id = cf.id.clone();
        manager.vote_for_cf(&cf_id, true, None);
        assert!(manager.check_finalization(&cf_id));

        assert!(manager.is_finalized_cf(&cf_id));
        assert!(manager.last_apply_failure().is_none());
        assert!(manager.last_finalized_cf().is_some());
    }
}
