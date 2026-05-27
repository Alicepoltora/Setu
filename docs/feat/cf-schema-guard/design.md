# CF Schema Guard (v3 → testnet hardening)

> Status: IMPLEMENTING
> Origin: code review of `post-restart-finality-stall-v3` PR-1..PR-5.
> Predecessor: design.md §3 PR-4 (d) — full `PersistedCf` envelope, **explicitly
> deferred** in v3 retro. This is the minimal stop-gap that lands before v1
> testnet so an upgrade-induced silent data loss cannot happen, without
> requiring the full envelope rewrite.

## 1. Problem Definition

After PR-4 added `round: u64` to `ConsensusFrame`, the on-disk BCS encoding
of every stored CF blob changed shape (one extra leading field). Read paths
in [`storage/src/rocks/cf_store.rs`](../../../storage/src/rocks/cf_store.rs)
silently swallow BCS decode failures via the
`self.db.get_raw::<ConsensusFrame>(...).ok().flatten()` pattern (lines 64,
69, 227, 344).

Concrete failure scenario on upgrade from pre-PR-4 binary to PR-4+ binary
without `clean.sh`:

1. RocksDB still holds the legacy `cf:{id}` blobs (no `round` field).
2. New binary opens the store, recovery iterates the `finalized:` index,
   finds CF ids.
3. For each id, `get(cf_id)` calls `get_raw::<ConsensusFrame>` →
   `decode_value` returns `Err` (BCS strict schema mismatch) → `.ok()`
   converts to `None` → caller treats CF as "not found".
4. Recovery completes with **zero finalized CFs visible**, `current_round`
   resets to 0, local state-root tree appears empty.
5. The node joins the live quorum thinking it is at genesis, induces a fork
   on the first proposal it tries to make / participate in.

No log, no error, no operator-visible warning until the cluster is already
diverged. This is the worst class of upgrade bug (silent corruption that
manifests as a downstream consensus issue).

## 2. Goals and Non-Goals

### Goals
- **Refuse to start** any `setu-validator` whose CF column family contains
  blobs that cannot be decoded into the current `ConsensusFrame` schema.
- Zero impact on fresh installs (empty DB) and on installs already on the
  current schema.
- No change to write paths, no change to in-memory store, no change to
  any consensus logic.
- Provide a clear, actionable error message that names the offending blob
  and tells the operator what to do.

### Non-Goals
- Implementing the full `PersistedCf` tagged envelope (deferred to v1.1,
  per design.md PR-4b).
- Implementing the `setu-cli migrate-cf-schema` subcommand (the SOP for v1
  is `rm -rf data/`; we will print a hint to that effect in the error).
- Detecting all forms of DB corruption — only the specific case "BCS blob
  cannot deserialize into current `ConsensusFrame`".
- Adding a versioned `META_SCHEMA_VERSION` key (would help future migrations
  but is out of scope; lands with PR-4b).

## 3. Solution Overview

### a. New method on `RocksDBCFStore`

```rust
/// Refuse to open the store if any finalized CF blob fails to decode into
/// the current `ConsensusFrame` schema. Called once, from `main.rs`, right
/// after constructing the store and before recovery walks the indexes.
///
/// Detection strategy: pick the first key under `finalized:` (insertion
/// order — cheap), parse the cf_id out of it, attempt
/// `db.get_raw::<ConsensusFrame>(cf:{id})`. If decode fails we are looking
/// at a pre-v3 blob; return `Err` with the BCS error and the operator
/// remediation hint.
///
/// Empty DB → `Ok(())` (no finalized index, nothing to check).
pub fn validate_schema(&self) -> SetuResult<()>;
```

Rationale for "first key only" rather than scanning all blobs:

- A schema break is *uniform*: if one pre-v3 blob exists, every blob is
  pre-v3. There's no scenario where some blobs are v3 and others aren't,
  because writes only happen through the current binary.
- Scanning all blobs at startup is O(N) where N can be tens of thousands.
  Probing one is O(1) on the iterator side + one point read.

### b. Call site

`setu-validator/src/main.rs` near line 324, after the existing
`RocksDBCFStore::from_shared` and before `recover_from_storage`:

```rust
let cf_store_concrete = RocksDBCFStore::from_shared(db.clone());
cf_store_concrete.validate_schema()
    .context("CF schema guard failed at startup")?;
let cf_store: Arc<dyn CFStoreBackend> = Arc::new(cf_store_concrete);
```

(Exact placement TBD during implementation — must be before any code that
walks the finalized index, otherwise the silent-`None` path defeats the
guard.)

### c. Error message contract

```
CF schema mismatch detected: cf_id={hex} cannot be decoded into the
current ConsensusFrame schema. This release (v3) added a `round` field
to ConsensusFrame and is not backward-compatible with pre-v3 on-disk
blobs.

Remediation:
  1. Stop the validator process.
  2. Back up data/ if you need forensics: `mv data data.bak-$(date +%s)`.
  3. Wipe CF storage: `rm -rf data/`.
  4. Restart; the validator will catch up from peers via the v3
     finalized-CF pull RPC.

Underlying decode error: {bcs_error}
```

The text goes into the `SetuError::StorageError` variant (existing) and is
printed by main's `?` propagation through `anyhow::Context`.

## 4. Affected Files

| File | Change |
|------|--------|
| `storage/src/rocks/cf_store.rs` | add `validate_schema(&self) -> SetuResult<()>` + one unit test |
| `setu-validator/src/main.rs` | call `validate_schema()` after store construction, before recovery |
| `docs/testnet/runbook.md` (new or appended) | SOP step: "if validator exits with `CF schema mismatch`, run `rm -rf data/` and restart" |
| `docs/feat/cf-schema-guard/implementation-log.md` | per FDP — mandatory |
| `docs/feat/cf-schema-guard/retro.md` | per FDP — mandatory |
| `docs/feat/cf-schema-guard/commit.md` | per FDP — Phase 6 |

## 5. Test Plan

### Unit (in `storage/src/rocks/cf_store.rs#tests`)

| # | Test name | Setup | Assert |
|---|-----------|-------|--------|
| 1 | `validate_schema_passes_on_empty_db` | fresh `RocksDBCFStore` | `validate_schema()` returns `Ok(())` |
| 2 | `validate_schema_passes_on_current_schema` | store a finalized v3 CF, call validate_schema | `Ok(())` |
| 3 | `validate_schema_rejects_legacy_blob` | manually write a deliberately-malformed BCS blob under `cf:{id}` and a corresponding `finalized:{seq}:{id}` index entry, call validate_schema | `Err(StorageError(..))` with message containing `"schema mismatch"` and the cf_id hex |

Test 3 is the central case. The "malformed blob" is constructed by encoding
a struct with one fewer field than the current `ConsensusFrame` —
synthesized via `bcs::to_bytes` of a stand-in struct in the test module.

### Integration: not needed for this guard

The `setu-validator/main.rs` call site is exercised by every existing
startup test. No new integration test required.

## 6. Acceptance Criteria

- `cargo test -p setu-storage --lib validate_schema` → 3 tests pass.
- `cargo check -p setu-validator` → no new warnings.
- `bash ai/scripts/validate.sh --quick` → green.
- Manual smoke: writing a deliberately-broken blob into a dev DB and
  starting `setu-validator` against it → process exits with non-zero code
  and prints the remediation message.

## 7. Mental Model Answers (storage crate)

> Per `ai/crate-instructions/storage.md` (if present). No `## Mental Model`
> section currently exists for storage; the consensus-crate questions do
> not apply since we touch no consensus state machine.

This change is read-only / startup-only. No new `DashMap` (G10 not
triggered), no new state key format (G11 not triggered), no EventType
change (G13 not triggered). G14 (no `cargo fmt`) honored.

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Guard refuses to start a *healthy* current-schema DB due to a bug in the probe | Tests 1 & 2 directly assert happy-path acceptance; unreachable code paths are explicit |
| Guard misses a pre-v3 blob because the picked key doesn't have a corresponding `cf:{id}` blob (index leak) | Treat "index points at missing blob" also as a refuse-to-start condition — the probe's `Ok(None)` branch returns `Err` |
| Operator wipes data and loses local state | Acceptable for v1 testnet (the catch-up RPC will rehydrate from peers); explicit remediation message tells them to back up first |
| Future PR-4b PersistedCf rollout invalidates this guard | The guard checks the current `ConsensusFrame` shape; when PR-4b lands and switches to `PersistedCf`, the guard's body is updated in the same PR (1-line change) |

## 9. Revisions

(empty until implementation drift requires updates)
