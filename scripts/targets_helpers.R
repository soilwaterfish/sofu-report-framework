resolve_first_existing <- function(candidates, dir_ok = FALSE, create_parent = FALSE) {
  candidates <- candidates[!is.na(candidates) & nzchar(candidates)]

  for (candidate in candidates) {
    if (dir_ok) {
      if (dir.exists(candidate)) {
        return(candidate)
      }
    } else if (file.exists(candidate)) {
      return(candidate)
    }
  }

  fallback <- candidates[[length(candidates)]]
  if (create_parent) {
    dir.create(dirname(fallback), recursive = TRUE, showWarnings = FALSE)
  }
  fallback
}

sofu_pipeline_config <- function() {
  local_today <- as.Date(format(Sys.time(), tz = "America/Denver", usetz = FALSE))
  water_year_start <- as.Date(sprintf(
    "%d-10-01",
    ifelse(
      as.integer(format(local_today, "%m")) >= 10L,
      as.integer(format(local_today, "%Y")),
      as.integer(format(local_today, "%Y")) - 1L
    )
  ))

  db_path <- resolve_first_existing(
    c(
      Sys.getenv("SOFU_DB_PATH", unset = NA_character_),
      "/data/sofu.sqlite",
      "data/sofu.sqlite"
    )
  )

  output_dir <- resolve_first_existing(
    c(
      Sys.getenv("SOFU_OUTPUT_DIR", unset = NA_character_),
      "/output",
      "output"
    ),
    dir_ok = TRUE,
    create_parent = TRUE
  )

  list(
    project_root = normalizePath(".", winslash = "/", mustWork = TRUE),
    db_path = db_path,
    gpkg_path = resolve_first_existing(
      c(
        Sys.getenv("SOFU_GPKG_PATH", unset = NA_character_),
        file.path(dirname(db_path), "cg_bbox.gpkg"),
        "data/cg_bbox.gpkg"
      )
    ),
    zone_csv_path = resolve_first_existing(
      c(
        Sys.getenv("SOFU_ZONE_CSV_PATH", unset = NA_character_),
        file.path(dirname(db_path), "main_ExportTable_zones.csv"),
        "data/main_ExportTable_zones.csv"
      )
    ),
    output_dir = output_dir,
    output_html = file.path(output_dir, "latest", "sofureport.html"),
    report_output_html = file.path(output_dir, "latest", "sofureport.html"),
    tmp_dir = Sys.getenv("SOFU_TMP_DIR", unset = "/tmp/sofureport-render"),
    log_path = Sys.getenv("SOFU_LOG_PATH", unset = file.path(output_dir, "workflow.log")),
    source_dir = resolve_first_existing(
      c(
        Sys.getenv("SOFU_SITE_SOURCE_DIR", unset = NA_character_),
        "/app/web",
        "web"
      ),
      dir_ok = TRUE
    ),
    renviron_path = Sys.getenv("SOFU_RENVIRON_PATH", unset = "/run/secrets/sofureport_renviron"),
    prism_annual_ppt_path = Sys.getenv(
      "SOFU_PRISM_ANNUAL_PPT_PATH",
      unset = "/data/prism_ppt_us_30s_2020_avg_30y/prism_ppt_us_30s_2020_avg_30y.tif"
    ),
    workflow_script = normalizePath("sofureport/dev/workflow_dev.R", winslash = "/", mustWork = TRUE),
    build_site_script = normalizePath("build_static_site.R", winslash = "/", mustWork = TRUE),
    render_report_script = normalizePath("render_report.R", winslash = "/", mustWork = TRUE),
    report_rmd = normalizePath("report_test.Rmd", winslash = "/", mustWork = TRUE),
    local_today = local_today,
    water_year_start = water_year_start,
    default_fems_backfill_days = as.integer(local_today - water_year_start) + 1L,
    default_zentra_backfill_days = as.integer(local_today - water_year_start) + 1L,
    targets_output_dir = file.path(output_dir, "targets")
  )
}

sofu_with_env <- function(env, expr) {
  env <- env[!is.na(env)]
  old <- Sys.getenv(names(env), unset = NA_character_)

  on.exit({
    for (nm in names(old)) {
      if (is.na(old[[nm]])) {
        do.call(Sys.unsetenv, list(nm))
      } else {
        do.call(Sys.setenv, stats::setNames(list(old[[nm]]), nm))
      }
    }
  }, add = TRUE)

  for (nm in names(env)) {
    do.call(Sys.setenv, stats::setNames(list(env[[nm]]), nm))
  }

  force(expr)
}

sofu_read_zone_site_roster <- function(path) {
  roster <- utils::read.csv(
    path,
    check.names = FALSE,
    stringsAsFactors = FALSE,
    fileEncoding = "UTF-8-BOM"
  )

  names(roster) <- sub("^\ufeff", "", names(roster))

  if (!"fems_fetch_id" %in% names(roster)) {
    roster$fems_fetch_id <- NA_character_
  }

  tibble::as_tibble(roster) |>
    dplyr::mutate(dplyr::across(where(is.character), trimws)) |>
    dplyr::mutate(
      station_id = as.character(.data$station_id),
      station_name = as.character(.data$station_name),
      api = as.character(.data$api),
      fems_fetch_id = dplyr::na_if(as.character(.data$fems_fetch_id), "")
    ) |>
    dplyr::distinct(.data$station_id, .data$api, .keep_all = TRUE)
}

sofu_enrich_zone_roster <- function(roster) {
  leaflet_layer_values <- if ("leaflet_layer" %in% names(roster)) {
    as.character(roster$leaflet_layer)
  } else {
    rep(NA_character_, nrow(roster))
  }

  roster |>
    dplyr::mutate(
      leaflet_layer = dplyr::coalesce(
        leaflet_layer_values,
        dplyr::case_when(
          .data$api == "FEMS" ~ "RAWS",
          .data$api == "Synoptic" ~ "Synoptic Soil",
          .data$api == "Zentra" ~ "Zentra",
          TRUE ~ .data$api
        )
      ),
      WIMS_ID = dplyr::if_else(.data$api == "FEMS", as.character(.data$station_id), NA_character_),
      STID = dplyr::if_else(.data$api == "Synoptic", as.character(.data$station_id), NA_character_),
      station_key = as.character(.data$station_id)
    )
}

sofu_pipeline_manifest <- function(config, roster, roster_enriched) {
  tibble::tribble(
    ~target_name, ~stage, ~script_or_source, ~description, ~primary_inputs, ~primary_outputs,
    "config", "bootstrap", "_targets.R", "Resolve paths, water-year settings, and environment-aware defaults.", "Sys.getenv(), project files", "config list",
    "zone_site_roster", "site roster", "data/main_ExportTable_zones.csv", "Read the canonical site roster used for mapping, zones, and station metadata.", config$zone_csv_path, "roster tibble",
    "zone_site_roster_enriched", "site enrichment", "scripts/targets_helpers.R", "Attach fetch IDs, layers, and station keys used downstream by workflow_dev.R.", "roster", "enriched roster tibble",
    "pipeline_manifest_file", "documentation", "scripts/targets_helpers.R", "Write a CSV manifest explaining each target and its role in the pipeline.", "config + roster metadata", "output/targets/pipeline_manifest.csv",
    "workflow_ingest_done", "database refresh", "sofureport/dev/workflow_dev.R", "Fetch raw API data and merge it into SQLite without recomputing stats or percentiles.", "DB, APIs, enriched roster", "output/targets/workflow_ingest.done",
    "workflow_daily_done", "database refresh", "sofureport/dev/workflow_dev.R", "Run the fast daily DB path: ingest raw data, refresh daily stats, and refresh computed indices.", "DB, APIs, enriched roster, PRISM raster", "output/targets/workflow_daily.done",
    "workflow_percentiles_done", "database refresh", "sofureport/dev/workflow_dev.R", "Run the heavy percentile refresh against the existing daily stats tables.", "DB daily stats tables", "output/targets/workflow_percentiles.done",
    "workflow_dev_done", "database refresh", "sofureport/dev/workflow_dev.R", "Run the full workflow including ingest, daily stats, computed indices, and percentiles.", "DB, APIs, enriched roster, PRISM raster", "output/targets/workflow_dev.done",
    "report_render_done", "report render", "render_report.R / report_test.Rmd", "Optional R Markdown render step for legacy report output.", "DB + report_test.Rmd", "output/targets/render_report.done",
    "static_site_done", "site build", "build_static_site.R", "Build the static dashboard/docs/reports payloads from SQLite into output/latest.", "DB + web assets + domain gpkg", "output/targets/build_static_site.done",
    "db_qc_done", "validation", "scripts/run_db_qc.R", "Run QA/QC checks against the SQLite outputs after the workflow and site build.", "SQLite database", "output/targets/db_qc.done"
  ) |>
    dplyr::mutate(
      roster_rows = nrow(roster),
      enriched_roster_rows = nrow(roster_enriched),
      generated_at = as.character(Sys.time())
    )
}

sofu_write_pipeline_manifest <- function(manifest, config) {
  dir.create(config$targets_output_dir, recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path(config$targets_output_dir, "pipeline_manifest.csv")
  utils::write.csv(manifest, out_path, row.names = FALSE)
  out_path
}

sofu_write_stamp <- function(path, lines) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, path)
  path
}

sofu_run_workflow_stage <- function(config, stamp_name, env = c()) {
  stamp <- file.path(config$targets_output_dir, stamp_name)

  sofu_with_env(
    c(
      SOFU_DB_PATH = config$db_path,
      SOFU_GPKG_PATH = config$gpkg_path,
      SOFU_OUTPUT_DIR = config$output_dir,
      SOFU_ZONE_CSV_PATH = config$zone_csv_path,
      SOFU_RENVIRON_PATH = config$renviron_path,
      SOFU_PRISM_ANNUAL_PPT_PATH = config$prism_annual_ppt_path,
      env
    ),
    source(config$workflow_script, local = new.env(parent = globalenv()))
  )

  sofu_write_stamp(
    stamp,
    c(
      paste("workflow stage complete:", Sys.time()),
      paste("stamp:", stamp_name),
      paste("db_path:", config$db_path)
    )
  )
}

sofu_run_workflow_ingest <- function(config) {
  sofu_run_workflow_stage(
    config = config,
    stamp_name = "workflow_ingest.done",
    env = c(
      SOFU_STAGE_DAILY_STATS = "0",
      SOFU_STAGE_COMPUTED_INDICES = "0",
      SOFU_STAGE_PERCENTILES = "0"
    )
  )
}

sofu_run_workflow_daily <- function(config) {
  sofu_run_workflow_stage(
    config = config,
    stamp_name = "workflow_daily.done",
    env = c(
      SOFU_STAGE_PERCENTILES = "0"
    )
  )
}

sofu_run_workflow_percentiles <- function(config) {
  sofu_run_workflow_stage(
    config = config,
    stamp_name = "workflow_percentiles.done",
    env = c(
      SOFU_STAGE_INGEST = "0",
      SOFU_STAGE_DAILY_STATS = "0",
      SOFU_STAGE_COMPUTED_INDICES = "0",
      SOFU_STAGE_PERCENTILES = "1"
    )
  )
}

sofu_run_workflow_dev <- function(config) {
  sofu_run_workflow_stage(
    config = config,
    stamp_name = "workflow_dev.done"
  )
}

sofu_run_render_report <- function(config) {
  stamp <- file.path(config$targets_output_dir, "render_report.done")

  sofu_with_env(
    c(
      SOFU_OUTPUT_HTML = config$report_output_html,
      SOFU_TMP_DIR = config$tmp_dir
    ),
    source(config$render_report_script, local = new.env(parent = globalenv()))
  )

  sofu_write_stamp(
    stamp,
    c(
      paste("render_report complete:", Sys.time()),
      paste("output_html:", config$report_output_html)
    )
  )
}

sofu_run_build_static_site <- function(config) {
  stamp <- file.path(config$targets_output_dir, "build_static_site.done")

  sofu_with_env(
    c(
      SOFU_DB_PATH = config$db_path,
      SOFU_OUTPUT_HTML = config$output_html,
      SOFU_SITE_SOURCE_DIR = config$source_dir,
      SOFU_GPKG_PATH = config$gpkg_path
    ),
    source(config$build_site_script, local = new.env(parent = globalenv()))
  )

  sofu_write_stamp(
    stamp,
    c(
      paste("build_static_site complete:", Sys.time()),
      paste("output_html:", config$output_html)
    )
  )
}

sofu_run_db_qc <- function(config) {
  stamp <- file.path(config$targets_output_dir, "db_qc.done")

  sofu_with_env(
    c(
      SOFU_DB_PATH = config$db_path,
      SOFU_OUTPUT_DIR = config$output_dir
    ),
    source(normalizePath("scripts/run_db_qc.R", winslash = "/", mustWork = TRUE), local = new.env(parent = globalenv()))
  )

  sofu_write_stamp(
    stamp,
    c(
      paste("db_qc complete:", Sys.time()),
      paste("db_path:", config$db_path)
    )
  )
}
