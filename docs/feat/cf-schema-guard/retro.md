# Retrospective — cf-schema-guard

## 1. Outcome Classification

- [x] **fully-resolved** — root cause fixed, tests pass, no residual debt

Residuals: none for the in-scope problem (silent CF read on schema mismatch).
One adjacent gap (`backfill_finalized_depth_index` also uses `.ok()`-style silent
skip) is documented in `review-log.md` R1-ISSUE-1 as accepted future-followup; it
cannot cause a fork on its own because the schema guard exits the process before
any reader observes the half-built index.

## 2. What the original mental model got wrong

- **I originally assumed**: that the post-restart finality-stall v3 PRs (PR-1..PR-5)
  closed the testnet readiness gap end-to-end, because each PR shipped with tests
  and the headline regression (CFs missing after restart) had a regression test.
- **Actual behavior**: PR-4 added `pub round: u64` to `ConsensusFrame`, which is a
  BCS-incompatible schema change. Combined with the silent
  `db.get_raw(...).ok().flatten()` pattern in `RocksDBCFStore::get()` and
  `backfill_finalized_depth_index`, an upgrade against an existing data dir will
  return `Ok(None)` for every pre-v3 CF — the node believes it has no finalized
  history and silently forks.
- **Evidence that broke the assumption**: re-reading
  `storage/src/rocks/cf_store.rs:223-228` (`.ok().flatten()` on the primary read
  path) against the codec contract comment at
  `storage/src/rocks/core/db.rs:72-81` ("BCS has no `#[serde(default)]` escape
  hatch — existing bytes will fail to decode"). The contract documents the hazard;
  the read path silently absorbs it.

## 3. Cognitive gain — candidate L3 mental-model item

- **Question**: "Before adding or removing a field on any struct that is persisted
  via `db.encode_value` / `db.decode_value` (BCS), ask: what does every read path
  for this struct do on a `Result::Err` from decode — fail loud, or
  `.ok().flatten()` it into `None`? If any caller treats decode failure as 'no
  data', the schema change will cause a silent data-loss on upgrade."
- **Why this question matters**: 4 layered defenses (PR-1..PR-5) were in place
  for the post-restart finality bug, yet a single `.ok().flatten()` in the storage
  reader would have neutered all of them on upgrade. The hazard is invisible at
  the call site because the return type `Option<ConsensusFrame>` does not
  distinguish "absent" from "undecodable".
- **Which crate/module**: `storage` — specifically any `RocksDB*Store` calling
  `db.get_raw` / `db.prefix_scan`.

## 4. Upgrade decision

- [x] **Crate Mental Model** — module-local L3 question → append under
  `## Mental Model` in `ai/crate-instructions/storage.md`.

Draft of the upgrade text:
```
## Mental Model

Before adding or removing a field on a struct persisted via BCS (`encode_value`
/ `decode_value`), ask: what does every read path for this struct do on a
`Result::Err` from decode? If any caller maps Err -> None (e.g. `.ok().flatten()`,
`let Ok(Some(...)) = ... else { continue; }`), the schema change will cause a
silent data-loss on upgrade rather than a loud failure. Either (a) make every
reader propagate the decode error, or (b) gate startup on a schema probe that
calls `decode_value` and refuses to start on mismatch (see `RocksDBCFStore::
validate_schema`, the canonical pattern). BCS has no `#[serde(default)]`
escape hatch — once bytes exist on disk, adding a field is a breaking change.
```

Also worth considering (NOT ticked, but flagged for the user):
- **Golden Rule candidate**: "Storage reader paths must not silently drop decode
  errors (`.ok().flatten()` on a `Result<Option<V>>` typed return)." Statically
  greppable. Deferring upgrade decision to user since enforcing this across all
  existing readers is a larger cleanup than this PR.

## 5. Failure-specific
N/A — fully-resolved.

---

**Commit coupling reminder**: commit message MUST include
`Outcome: fully-resolved` and link to this file.
