# Implementation Log — cf-schema-guard

## Summary
No issues encountered during implementation. Single round of cargo check + cargo test
passed first try.

## Steps executed

1. Added `RocksDBCFStore::validate_schema(&self) -> SetuResult<()>` at
   `storage/src/rocks/cf_store.rs:455-503` immediately after
   `backfill_finalized_depth_index`. Method body matches the sketch in `design.md` §3a
   verbatim except for the formatted multi-line operator error string.

2. Added 3 unit tests at `storage/src/rocks/cf_store.rs:728-784`:
   - `validate_schema_passes_on_empty_db` — empty DB returns `Ok(())`.
   - `validate_schema_passes_on_current_schema` — 3 finalized CFs written via the
     normal write path validate cleanly.
   - `validate_schema_rejects_undecodable_blob` — overwrites a CF blob with a
     BCS-encoded `Vec<u8>` (structurally incompatible with `ConsensusFrame`) via
     `db.put_raw`; asserts the error message contains both `"CF schema mismatch"`
     and the offending `cf_id`.

   Note: the test uses `db.put_raw(..., &Vec<u8>)` rather than reaching into raw
   RocksDB through `db.inner()`. This is cleaner and tests the same error shape —
   any payload that BCS cannot decode as `ConsensusFrame` exercises the same
   `decode_value -> Err` path that a stale-schema blob would.

3. Wired the guard into `setu-validator/src/main.rs:323-335`. Switched from the
   single-line `Arc::new(RocksDBCFStore::from_shared(...))` to a two-step
   construction:
   ```
   let cf_store_concrete = RocksDBCFStore::from_shared(db.clone());
   cf_store_concrete.validate_schema().map_err(|e| anyhow::anyhow!(
       "CF schema guard failed at startup — on-disk data is incompatible with this release: {}", e
   ))?;
   let cf_store: Arc<dyn CFStoreBackend> = Arc::new(cf_store_concrete);
   ```
   Used `anyhow::anyhow!` rather than `Context::context` to avoid a new import and
   match the style of the adjacent `anyhow::anyhow!("Database open failed: ...")`
   on L277.

## Build / test results

- `cargo check -p setu-storage -p setu-validator` — clean (6 pre-existing
  `dead_code` warnings in setu-validator, unrelated).
- `cargo test -p setu-storage validate_schema` — 3 passed / 0 failed.
- `cargo clippy -p setu-storage --tests` — zero hits on `cf_store.rs`.
  Workspace-wide `-D warnings` fails on pre-existing lints in `setu-types` —
  out of scope; G14 forbids running `cargo fix` to clean those up.

## Design drift
None. The implemented method matches `design.md` §3a; the operator error message
matches §4 verbatim.

## R1-ISSUE-1 follow-up

The backfill silent-skip noted in `review-log.md` Round 1 is documented but not
addressed in this commit. Future work: order backfill after schema validation,
or have backfill propagate decode errors instead of `.ok()`. Not a blocker
because validate_schema exits the process before any reader observes the
half-built depth index.
