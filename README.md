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

- The daily workflow is designed to be incremental and safe to rerun.
- Historical source repairs are explicit Make targets, not normal cron work.
- The dashboard payload is static JSON generated from SQLite; frontend-only
  changes can use `make publish-frontend` without rerunning the data workflow.
- Read `docs/PROJECT_CONTEXT.md` before changing ingestion, timestamps,
  station reconciliation, aggregation, or API behavior.
