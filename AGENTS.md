# AGENTS.md

## Required project context

Before modifying ingestion, SQLite, API, aggregation, dashboard, report, or deployment code, read:

- `docs/PROJECT_CONTEXT.md`

Treat that document as the governing description of project intent and invariants.

## Operating rules

- Inspect the relevant schema, indexes, and current implementation before editing.
- State material assumptions about source grain, timestamps, units, missingness, station keys, and API behavior.
- Prefer small, source-specific changes over broad ingestion refactors.
- Preserve source provenance.
- Make database writes incremental, transactional, idempotent, and resumable.
- Do not use full-table read-bind-deduplicate-overwrite patterns.
- Do not advance ingestion state before the corresponding database transaction commits.
- Do not treat missing Zentra transmissions as permanent missing data.
- Validate FEMS/Synoptic joins using `WIMS_ID`; prevent accidental many-to-many joins.
- Do not change aggregation, percentile, timezone, or unit semantics as a side effect of performance work.
- Run focused tests and inspect database results after changes.
- Update `docs/PROJECT_CONTEXT.md` when a stable invariant, data contract, source rule, or known footgun changes.

## Before broad work

Write a plan before changes that:

- alter table grain or unique keys;
- change station identity or source reconciliation;
- modify Zentra throttling, checkpointing, or backfill behavior;
- change derived-variable or percentile definitions;
- cross multiple API clients;
- alter frontend data contracts; or
- change SQLite concurrency or journal behavior.

The plan must include the affected tables, migration strategy, failure recovery, and validation scenarios.
