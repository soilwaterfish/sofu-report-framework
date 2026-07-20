# SOFU Targets Pipeline

This project now has a `targets` pipeline at [`_targets.R`](/home/joshualerickson/sofureport-deploy/_targets.R) so we can inspect the workflow step by step instead of treating `workflow_dev.R` and `build_static_site.R` as one opaque run.

## Why This Exists

The current workflow does a lot in one pass:

1. Read environment and resolve paths.
2. Read the zone roster CSV.
3. Resolve RAWS station IDs to numeric FEMS fetch IDs.
4. Fetch Synoptic, FEMS, and Zentra raw data.
5. Merge raw data into `data/sofu.sqlite`.
6. Refresh daily stats and percentiles.
7. Build the static site payloads in `output/latest`.

`targets` gives us a visible dependency graph and persistent intermediates so we can debug one stage at a time.

## Current Target Graph

The first-pass pipeline is intentionally explicit:

- `config`
  Resolves paths, dates, output folders, and script locations.

- `zone_site_roster`
  Reads `data/main_ExportTable_zones.csv`.

- `fems_station_lookup`
  Uses `sofureport::get_stations()` to translate RAWS/WIMS IDs like `HBRM8` into numeric FEMS fetch IDs like `244603`.

- `zone_site_roster_enriched`
  Joins the roster and FEMS lookup so downstream steps can see both the user-facing station IDs and the fetch IDs.

- `pipeline_manifest`
  A human-readable table describing the stages.

- `pipeline_manifest_file`
  Writes `output/targets/pipeline_manifest.csv`.

- `workflow_dev_done`
  Runs [`sofureport/dev/workflow_dev.R`](/home/joshualerickson/sofureport-deploy/sofureport/dev/workflow_dev.R).

- `report_render_done`
  Runs [`render_report.R`](/home/joshualerickson/sofureport-deploy/render_report.R) after the DB refresh.

- `static_site_done`
  Runs [`build_static_site.R`](/home/joshualerickson/sofureport-deploy/build_static_site.R) after the DB refresh.

- `db_qc_done`
  Runs DB QA/QC after the workflow and static site build.

## Important Design Choice

This is a transparent scaffold, not yet a full functional decomposition of `workflow_dev.R`.

That means:

- The pipeline already gives us visibility into inputs, sequencing, and artifacts.
- The heavy side-effecting work still happens inside the existing scripts.
- We can incrementally peel pure functions out of `workflow_dev.R` into reusable helpers later.

This is deliberate. It gives us observability now without forcing a risky full rewrite first.

## Files Added

- [`_targets.R`](/home/joshualerickson/sofureport-deploy/_targets.R)
  Main targets graph.

- [`scripts/targets_helpers.R`](/home/joshualerickson/sofureport-deploy/scripts/targets_helpers.R)
  Path resolution, roster loading, FEMS ID resolution, target manifest writing, and script-running wrappers.

- [`docs/targets-pipeline.md`](/home/joshualerickson/sofureport-deploy/docs/targets-pipeline.md)
  This reference.

## Recommended Commands

You will need the `targets` package installed locally because it is not currently installed in this environment.

Useful commands:

```r
targets::tar_manifest()
targets::tar_make(names = "pipeline_manifest_file")
targets::tar_make(names = "workflow_dev_done")
targets::tar_make(names = "static_site_done")
targets::tar_make()
```

## Suggested Dev Flow

For understanding the workflow:

1. Run only `pipeline_manifest_file`.
2. Inspect `output/targets/pipeline_manifest.csv`.
3. Run `workflow_dev_done`.
4. Inspect the SQLite DB and QC outputs.
5. Run `static_site_done`.
6. Inspect `output/latest`.

For future refactors:

1. Extract one pure section from `workflow_dev.R`.
2. Replace the script wrapper with a true `tar_target()` for that section.
3. Keep side effects isolated to the smallest possible late-stage targets.

## Next Good Refactor Targets

These are the best pieces to break out next:

- site roster and metadata persistence
- Synoptic fetch windows
- FEMS fetch windows
- Zentra station windows
- raw-to-hourly transformations
- daily stats refresh
- percentile refresh
- dashboard JSON assembly

That path gets us from “targets wrapping scripts” to a genuinely granular DAG without losing momentum.
