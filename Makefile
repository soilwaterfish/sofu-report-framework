.PHONY: docker-build docker-run docker-run-build docker-run-no-site docker-run-ingest docker-run-daily docker-run-derived docker-run-percentiles docker-run-full docker-run-backfill docker-run-db-refresh docker-run-db-refresh-build docker-run-source-repair docker-run-may-june-repair docker-run-fems-nfdrs-repair docker-run-fems-establish docker-run-fems-establish-percentiles docker-up-web docker-down-web build-site-local publish-frontend landing-assets landing-publish build-site-with-indices db-qc db-inspect db-eda diagnose-pipeline trace-pipeline targets-manifest targets-ingest targets-daily targets-percentiles targets-workflow targets-site targets-qc

docker-build:
	docker compose build sofureport-job

docker-run:
	docker compose run --rm -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

docker-run-build:
	docker compose run --build --rm -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

docker-run-no-site:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

docker-run-ingest:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_STAGE_DAILY_STATS=0 -e SOFU_STAGE_COMPUTED_INDICES=0 -e SOFU_STAGE_PERCENTILES=0 -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

docker-run-daily:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

# Rebuild daily summaries and computed indices from the current SQLite data
# without calling any external API or rebuilding the static site.
docker-run-derived:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_STAGE_INGEST=0 -e SOFU_STAGE_PERCENTILES=0 -e SOFU_DAILY_STATS_LOOKBACK_DAYS=30 sofureport-job

docker-run-percentiles:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_STAGE_INGEST=0 -e SOFU_STAGE_DAILY_STATS=0 -e SOFU_STAGE_COMPUTED_INDICES=0 -e SOFU_STAGE_PERCENTILES=1 -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

docker-run-full:
	docker compose run --rm -e SOFU_STAGE_PERCENTILES=1 -e SOFU_ZENTRA_BACKFILL_DAYS=30 sofureport-job

docker-run-backfill:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_FORCE_WATER_YEAR_BACKFILL=1 sofureport-job

docker-run-db-refresh:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_FORCE_WATER_YEAR_BACKFILL=1 -e SOFU_FULL_STATS_BACKFILL=1 -e SOFU_STAGE_PERCENTILES=1 sofureport-job

docker-run-db-refresh-build:
	docker compose run --rm -e SOFU_FORCE_WATER_YEAR_BACKFILL=1 -e SOFU_FULL_STATS_BACKFILL=1 -e SOFU_STAGE_PERCENTILES=1 sofureport-job

# One-time bounded repair for source rows affected by an interrupted or older
# schema-mismatched ingest. It refreshes recent raw data and daily summaries,
# but leaves percentile recomputation off.
docker-run-source-repair:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_SYNOPTIC_BACKFILL_DAYS=30 -e SOFU_FEMS_BACKFILL_DAYS=30 -e SOFU_DAILY_STATS_LOOKBACK_DAYS=30 -e SOFU_ZENTRA_BACKFILL_DAYS=1 sofureport-job

# One-time repair for late-May through mid-June weather and Synoptic gaps.
# NFDRS is retained because its historical fallback is intentionally separate.
docker-run-may-june-repair:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_SYNOPTIC_BACKFILL_DAYS=60 -e SOFU_FEMS_BACKFILL_DAYS=60 -e SOFU_DAILY_STATS_LOOKBACK_DAYS=60 -e SOFU_FEMS_SKIP_NFDRS=1 -e SOFU_SKIP_ZENTRA_INGEST=1 -e SOFU_STAGE_PERCENTILES=0 sofureport-job

# One-time recovery of FEMS NFDRS GSI/KBDI after a weather-only repair.
# The staged merge preserves weather fields while NFDRS rows are restored.
docker-run-fems-nfdrs-repair:
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_SYNOPTIC_BACKFILL_DAYS=1 -e SOFU_FEMS_BACKFILL_DAYS=60 -e SOFU_DAILY_STATS_LOOKBACK_DAYS=60 -e SOFU_SKIP_ZENTRA_INGEST=1 -e SOFU_STAGE_PERCENTILES=0 sofureport-job

# One-time period-of-record establishment for comma-separated canonical FEMS
# IDs. Example: make docker-run-fems-establish STATIONS=QADW4,SBYM8 START_DATE=2005-01-01
docker-run-fems-establish:
	@test -n "$(STATIONS)" || (echo "Set STATIONS=ID1,ID2" && exit 1)
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_ZENTRA_BACKFILL_DAYS=1 -e SOFU_STAGE_PERCENTILES=1 -e SOFU_ONLY_ESTABLISH_DERIVED=1 -e SOFU_FEMS_ESTABLISH_STATIONS=$(STATIONS) -e SOFU_FEMS_ESTABLISH_START_DATE=$(or $(START_DATE),2000-01-01) sofureport-job

# Finish historical percentile keys after an establishment raw/data-stat pass,
# without recomputing the percentile products for every existing station.
docker-run-fems-establish-percentiles:
	@test -n "$(STATIONS)" || (echo "Set STATIONS=ID1,ID2" && exit 1)
	docker compose run --rm -e SOFU_SKIP_STATIC_SITE=1 -e SOFU_STAGE_INGEST=0 -e SOFU_STAGE_DAILY_STATS=0 -e SOFU_STAGE_COMPUTED_INDICES=0 -e SOFU_STAGE_PERCENTILES=1 -e SOFU_ONLY_ESTABLISH_DERIVED=1 -e SOFU_FEMS_ESTABLISH_STATIONS=$(STATIONS) sofureport-job

docker-up-web:
	docker compose up -d sofureport-web

docker-down-web:
	docker compose stop sofureport-web

build-site-local:
	Rscript build_static_site.R

# Copy the web frontend to output/latest while preserving the existing JSON.
# Use this for dashboard/report HTML, CSS, or JS iteration without a DB build.
publish-frontend:
	docker compose run --rm --entrypoint Rscript sofureport-job /app/scripts/publish_frontend.R

# Download and crop landing-page ForDRI/EDDI frames without touching SQLite.
# Set SOFU_FORDRI_START_DATE/SOFU_FORDRI_END_DATE or SOFU_EDDI_END_DATE
# (YYYY-MM-DD) when a source archive has a different window than the local clock.
landing-assets:
	docker compose run --rm --entrypoint Rscript sofureport-job /app/scripts/build_landing_indices.R

# Publish only the landing page, its CSS, and its controller; no DB or report build.
landing-publish:
	docker compose run --rm --entrypoint Rscript sofureport-job /app/scripts/publish_landing_page.R

# Build the static site and refresh the landing-page raster frames in one run.
build-site-with-indices:
	docker compose run --rm -e SOFU_STAGE_INGEST=0 -e SOFU_STAGE_DAILY_STATS=0 -e SOFU_STAGE_COMPUTED_INDICES=0 -e SOFU_STAGE_PERCENTILES=0 -e SOFU_BUILD_LANDING_INDICES=1 sofureport-job

db-qc:
	Rscript scripts/run_db_qc.R

db-inspect:
	Rscript scripts/inspect_db.R

db-eda:
	Rscript scripts/build_db_eda.R

diagnose-pipeline:
	Rscript scripts/diagnose_pipeline.R

trace-pipeline:
	Rscript scripts/trace_pipeline.R

targets-manifest:
	Rscript -e "targets::tar_make(names = 'pipeline_manifest_file')"

targets-ingest:
	Rscript -e "targets::tar_make(names = 'workflow_ingest_done')"

targets-daily:
	Rscript -e "targets::tar_make(names = 'workflow_daily_done')"

targets-percentiles:
	Rscript -e "targets::tar_make(names = 'workflow_percentiles_done')"

targets-workflow:
	Rscript -e "targets::tar_make(names = 'workflow_dev_done')"

targets-site:
	Rscript -e "targets::tar_make(names = 'static_site_done')"

targets-qc:
	Rscript -e "targets::tar_make(names = 'db_qc_done')"
