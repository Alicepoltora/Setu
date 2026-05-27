# Commit — cf-schema-guard

Per project rule: this commit stages **only Rust source + Cargo manifests**.
Docs under `docs/feat/cf-schema-guard/` are committed separately by the user.

## Commands

```bash
git add storage/src/rocks/cf_store.rs setu-validator/src/main.rs

git commit -m 'feat(storage): add startup CF schema guard against silent BCS decode failures

- Add RocksDBCFStore::validate_schema() — O(1) probe that picks the first
  finalized index entry, resolves its cf:{id} blob, and attempts BCS decode
  into the current ConsensusFrame. Returns a SetuError naming the offending
  cf_id and listing operator remediation (backup + wipe + restart) on
  decode mismatch.
- Wire the guard into setu-validator/main.rs immediately after
  RocksDBCFStore::from_shared, so a stale-schema data dir aborts startup
  instead of silently surfacing as Ok(None) through the existing
  .ok().flatten() read path and forking the validator.
- Add 3 unit tests: empty DB passes, current-schema CFs pass, BCS-undecodable
  blob is rejected with a message naming cf_id and "CF schema mismatch".

PR-4 (post-restart-finality-stall-v3) added a round field to ConsensusFrame,
which is a BCS-incompatible schema break. Without this guard, upgrading a
node against an existing data dir returns Ok(None) for every pre-v3 CF and
the validator silently forks.

Outcome: fully-resolved
Retro: docs/feat/cf-schema-guard/retro.md'
```

## Notes for the docs commit (separate)

```bash
git add docs/feat/cf-schema-guard/

git commit -m 'docs(feat): cf-schema-guard FDP artifacts

Design, review log, implementation log, retrospective for the startup
CF schema guard. See storage commit referenced in retro.md §1.'
```
