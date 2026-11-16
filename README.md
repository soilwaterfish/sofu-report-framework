# SOFU Report Framework

SOFU Report is a Dockerized R workflow and static website for environmental
station monitoring. It retrieves source data, stores normalized observations in
SQLite, derives daily products, and publishes a dashboard and zone reports.

This repository contains deployment and presentation code. The reusable R
package lives in the `sofureport` Git submodule and is pinned to a specific
commit for reproducibility.

## Repository Boundaries

Tracked here:

- Docker, Make, workflow, and static-site code
- Website HTML, CSS, and JavaScript
- Database QA and diagnostic scripts
- Documentation and configuration examples
- The pinned `sofureport` package submodule

Local only, never committed:

- `secrets/.Renviron` and `.env`
- `data/`, including the SQLite database and large raster inputs
- `output/`, `logs/`, temporary site files, and target cache files

## Initial Setup

Clone with submodules:

```bash
git clone --recurse-submodules git@github.com:soilwaterfish/sofu-report-framework.git
cd sofu-report-framework
```

For an existing clone:

```bash
git submodule update --init --recursive
```

Create local credentials from the safe template:

```bash
cp secrets/.Renviron.example secrets/.Renviron
chmod 600 secrets/.Renviron
```

Set `SYNOPTIC_TOKEN`, `FEMS_API_KEY`, and `ZENTRACLOUD_TOKEN` in
`secrets/.Renviron`. Do not add those values to GitHub, Docker images, logs, or
commits.

The deployment also needs its local runtime data in `data/`, including the
station roster, source mappings, spatial inputs, PRISM raster, and SQLite
database. Those inputs are intentionally not supplied by this repository.

## Common Commands

```bash
make docker-build              # Build the R workflow image
make docker-run                # Normal workflow and static-site publish
make docker-run-ingest         # API ingest only; no derived products/site
make docker-run-derived        # Rebuild daily products from SQLite only
make docker-run-percentiles    # Refresh percentile products only
make publish-frontend          # Publish HTML/CSS/JS without rebuilding data
make db-inspect                # Print database freshness and QA summary
make db-eda                    # Build local database inspection page
make docker-up-web             # Serve output/latest on localhost:8080
```

Run `make` targets from the repository root. The normal scheduled deployment
uses Docker volumes, so its database and generated website remain on the host
under `data/` and `output/`.

## Git Workflow

The package and deployment are versioned independently:

```bash
# Update the framework's pinned package revision intentionally.
git -C sofureport fetch origin
git -C sofureport checkout main
git -C sofureport pull --ff-only
git add sofureport
git commit -m "Update sofureport package dependency"
```

Before any commit, review staged paths:

```bash
git status --short
git diff --cached --stat
```

The root `.gitignore` is a safety boundary, not a substitute for review. In
particular, verify that no database, output artifact, or real credential is
staged.

## Operational Notes

### Zentra Recovery

```bash
make docker-run-zentra-audit                  # Inspect missing hours/sensor values; no API calls.
make docker-run-zentra-derived                # Rebuild stored Zentra statistics and publish; no API calls.
make docker-run-zentra-repair MAX_CHUNKS=24    # Fetch bounded gaps, rebuild statistics, and publish.
```

Recovery audits the rolling-year history and its October 1 accumulation baseline,
including partially populated days. Each successful chunk commits independently;
reruns resume from stored observations and retry checkpoints. Empty responses are
deferred, not treated as permanent missing data. Audit CSVs and derived-table
backups are written under `output/zentra-repair`.

If the API returns HTTP 401, renew `ZENTRACLOUD_TOKEN` in
`secrets/.Renviron` before running the repair command. Never put the token in
chat or Git. A statistics-only rebuild cannot recover missing API observations.
Zentra's one-call-per-minute limit means larger repairs can take a while;
`MAX_CHUNKS` bounds each run rather than promising all gaps will be filled.

For a confirmed gap, scope the repair rather than processing the whole queue:

```bash
make docker-run-zentra-repair STATIONS=z6-32392 START=2026-10-09 END=2026-11-04 CHUNK_DAYS=7 MAX_CHUNKS=4
```

`STATIONS` accepts comma-separated active Zentra IDs. Dates use Mountain
calendar days, inclusive. `CHUNK_DAYS` accepts 1-31 and defaults to 2; larger
contiguous windows reduce requests, but month boundaries may add API pages.
Routine refreshes revisit the last three completed days plus today to catch
late cellular uploads; full maintenance also audits older gaps.

Scheduled refreshes run every two hours at minute 15 in Mountain time.
The 06:15 and 18:15 slots run full maintenance (ingestion, recent daily stats,
computed indices, raster assets, and the site). Other slots use the light
current-observation refresh. Historical percentile recalculation remains a
separate maintenance command. All scheduled SOFU jobs share a lock and skip
when a previous run is still active.

```bash
make docker-run-frequent             # Current observations and website.
make docker-run-scheduled            # Full scheduled maintenance.
python3 scripts/install_sofu_cron.py  # Show proposed schedule.
```

The dashboard defaults to 365 days, with October 1 water-year resets for
accumulated precipitation. Today-so-far statistics and percentile comparisons
are provisional; the completed-day view remains available separately.

For frontend development on the facelift branch:

```bash
make preview-rates                  # Export rolling rates from existing SQLite.
make preview-frontend PORT=8091      # Serve working HTML/CSS/JS with cached data.
```

Open `http://127.0.0.1:8091`. The preview reads report/rate data from
`output/facelift/data` and falls back to `output/latest` for other data and
drought-map frames. Refresh the rate export after new database observations
arrive; ordinary HTML/CSS/JS edits only need a browser refresh. These commands
do not run API ingestion or publish the frontend. A normal static build also
exports the rolling rates for the published dashboard and reports.

Rates use 24-hour, 2-day, 7-day, and 30-day windows ending at each variable's
latest observation. Rainfall is average accumulation; other variables use a
linear fit with coverage and fit quality shown. Run the focused calculation
checks with `Rscript scripts/test_station_rates.R`.

- The daily workflow is designed to be incremental and safe to rerun.
- Historical source repairs are explicit Make targets, not normal cron work.
- The dashboard payload is static JSON generated from SQLite; frontend-only
  changes can use `make publish-frontend` without rerunning the data workflow.
- Read `docs/PROJECT_CONTEXT.md` before changing ingestion, timestamps,
  station reconciliation, aggregation, or API behavior.
