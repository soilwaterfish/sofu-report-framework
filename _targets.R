library(targets)

tar_option_set(
  packages = c(
    "DBI",
    "RSQLite",
    "dplyr",
    "jsonlite",
    "purrr",
    "tibble",
    "sf",
    "terra",
    "sofureport"
  ),
  format = "rds"
)

source("scripts/targets_helpers.R")

list(
  tar_target(
    config,
    sofu_pipeline_config()
  ),
  tar_target(
    zone_site_roster,
    sofu_read_zone_site_roster(config$zone_csv_path)
  ),
  tar_target(
    zone_site_roster_enriched,
    sofu_enrich_zone_roster(zone_site_roster)
  ),
  tar_target(
    pipeline_manifest,
    sofu_pipeline_manifest(config, zone_site_roster, zone_site_roster_enriched)
  ),
  tar_target(
    pipeline_manifest_file,
    sofu_write_pipeline_manifest(pipeline_manifest, config),
    format = "file"
  ),
  tar_target(
    workflow_ingest_done,
    sofu_run_workflow_ingest(config),
    format = "file"
  ),
  tar_target(
    workflow_daily_done,
    sofu_run_workflow_daily(config),
    format = "file"
  ),
  tar_target(
    workflow_percentiles_done,
    sofu_run_workflow_percentiles(config),
    format = "file"
  ),
  tar_target(
    workflow_dev_done,
    sofu_run_workflow_dev(config),
    format = "file"
  ),
  tar_target(
    report_render_done,
    {
      workflow_dev_done
      sofu_run_render_report(config)
    },
    format = "file"
  ),
  tar_target(
    static_site_done,
    {
      workflow_daily_done
      sofu_run_build_static_site(config)
    },
    format = "file"
  ),
  tar_target(
    db_qc_done,
    {
      workflow_daily_done
      static_site_done
      sofu_run_db_qc(config)
    },
    format = "file"
  )
)
