# Review Log — cf-schema-guard

## Round 1 — Design vs Constraints

Inputs read:
- `storage/src/rocks/core/db.rs:60-100` — `encode_value` / `decode_value` (BCS, errors propagate as `Result<V>::Err`).
- `storage/src/rocks/core/db.rs:166-194` — `put_raw` / `get_raw` (BCS-encoded, `Result<Option<V>>`).
- `storage/src/rocks/core/db.rs:272-292` — `prefix_scan_keys` returns owned key bytes.
- `storage/src/rocks/cf_store.rs:60-90` — `from_shared` infallible signature.
- `storage/src/rocks/cf_store.rs:117-172` — `cf_key`, `finalized_key`, `extract_cf_id_from_index_key`.
- `storage/src/rocks/cf_store.rs:223-228` — `get()` uses `.ok().flatten()` (the silent path being closed).
- `storage/src/rocks/cf_store.rs:415-453` — `backfill_finalized_depth_index` (also uses silent `.ok()` — see R1-ISSUE-1).
- `setu-validator/src/main.rs:320-340` — sole production call site.

### Findings

**R1-PASS — BCS decode error propagation.**
`decode_value` returns `StorageError::deserialization(e.to_string())`. The error surfaces through
`get_raw -> Result<Option<V>>` as `Err(StorageError)` rather than `Ok(None)`. Design's probe
strategy of distinguishing `Ok(Some)` / `Ok(None)` / `Err` is correct.

**R1-PASS — Key format compatibility.**
`extract_cf_id_from_index_key` consumes `finalized:{seq:016x}:{cf_id}` and returns
`Option<CFId>` (String). The bytes after the 16-hex+colon prefix are UTF-8 hex of the CF id,
which matches the layout `cf_key()` consumes — round-trips cleanly into `get_raw`.

**R1-PASS — Single production call site.**
`grep RocksDBCFStore::from_shared` finds exactly one non-test occurrence:
`setu-validator/src/main.rs:324`. No other reader can sidestep the guard.

**R1-PASS — Codec contract already documents this.**
`db.rs` L72-L81 explicitly warns: "BCS has no `#[serde(default)]` escape hatch — existing
bytes will fail to decode. Plan schema changes carefully." The guard operationalises this
contract.

**R1-ISSUE-1 (KNOWN, ACCEPTED) — `backfill_finalized_depth_index` silently skips
schema-mismatched blobs.**
At `cf_store.rs:442` the backfill loop uses
`let Ok(Some(cf)) = self.db.get_raw::<ConsensusFrame>(...) else { continue; };` — same silent-
failure shape this guard fixes for reads. Backfill runs inside `from_shared` *before*
`validate_schema` can be called.

*Disposition*: accepted. Because validate_schema runs immediately after `from_shared`
returns and exits the process on mismatch, the no-op backfill write batch is harmless
(no further code path observes the half-built depth index). Closing this gap by ordering
backfill after validate would require an API change to `from_shared` and is out of scope
for v1 testnet. Documented here so future Agents do not assume backfill is schema-safe.

**R1-ISSUE-2 (resolved in design) — operator-facing error message.**
Initial design had a one-line error. Reviewed against expected operator workflow:
expanded to multi-line block with explicit `mv data data.bak-…` / `rm -rf data/` /
restart instructions, naming the offending cf_id. Confirmed in implementation.

### Round 1 Verdict: PROCEED to implementation.
No design changes required. R1-ISSUE-1 is a future-followup, not a blocker.

## Round 2 — Implementation vs Design (post-code)

Inputs read:
- `storage/src/rocks/cf_store.rs:455-503` — new `validate_schema` method.
- `storage/src/rocks/cf_store.rs:728-784` — 3 new unit tests.
- `setu-validator/src/main.rs:320-345` — wired-in call.

### Findings

**R2-PASS — Determinism (G1).** Read-only probe; touches only RocksDB reads + one
conditional error return. No system time, no nondeterministic iteration affecting consensus.

**R2-PASS — Deferred commit (G3).** Not applicable; runs before any consensus state is
touched.

**R2-PASS — State key format (G11).** Probe consumes existing `finalized:` and `cf:` keys
unchanged. No new keys minted.

**R2-PASS — Dependency direction.** Change confined to `storage` (leaf-adjacent) and
`setu-validator` (integration hub). No new cross-crate dependencies.

**R2-PASS — Error type.** Method returns `SetuResult<()>`; main.rs wraps with
`anyhow::anyhow!` matching the existing style on adjacent lines (L277). No new imports
needed.

**R2-PASS — Test coverage.** Three cases cover empty / current-schema / corrupt-blob.
Tests verify both the error message names "CF schema mismatch" and the offending cf_id.

**R2-PASS — Clippy clean.** `cargo clippy -p setu-storage --tests` reports zero hits on
`cf_store.rs`.

### Round 2 Verdict: PASS. No issues found, no further rounds required.
