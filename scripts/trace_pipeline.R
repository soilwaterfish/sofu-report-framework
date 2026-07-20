#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(dplyr)
  library(jsonlite)
  library(tibble)
})

options(width = 120)

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

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

safe_local_date_from_epoch <- function(value, tz = "America/Denver") {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(as.Date(NA))
  }

  as.Date(format(as.POSIXct(as.numeric(value), origin = "1970-01-01", tz = "UTC"), tz = tz, usetz = FALSE))
}

safe_iso_from_epoch <- function(value, tz = "America/Denver") {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(NA_character_)
  }

  format(as.POSIXct(as.numeric(value), origin = "1970-01-01", tz = "UTC"), tz = tz, usetz = TRUE)
}

parse_export_date <- function(value) {
  if (length(value) == 0 || is.na(value) || !nzchar(as.character(value))) {
    return(as.Date(NA))
  }

  as.Date(substr(as.character(value), 1, 10))
}

read_roster <- function(path) {
  tibble::as_tibble(
    utils::read.csv(
      path,
      check.names = FALSE,
      stringsAsFactors = FALSE,
      fileEncoding = "UTF-8-BOM"
    )
  ) %>%
    mutate(across(where(is.character), trimws)) %>%
    mutate(
      station_id = as.character(.data$station_id),
      station_name = as.character(.data$station_name),
      api = as.character(.data$api)
    ) %>%
    distinct(.data$station_id, .data$api, .keep_all = TRUE)
}

read_dashboard_export <- function(path) {
  if (!file.exists(path)) {
    return(tibble())
  }

  payload <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  stations <- payload$stations %||% list()

  if (!length(stations)) {
    return(tibble())
  }

  tibble(
    station_id = vapply(stations, function(x) as.character(x$id %||% NA_character_), character(1)),
    exported_name = vapply(stations, function(x) as.character(x$name %||% NA_character_), character(1)),
    exported_api = vapply(stations, function(x) as.character(x$api %||% NA_character_), character(1)),
    exported_latest_timestamp = vapply(stations, function(x) as.character(x$latest$timestamp %||% NA_character_), character(1)),
    exported_latest_date = as.Date(vapply(stations, function(x) as.character(parse_export_date(x$latest$timestamp %||% NA_character_)), character(1))),
    series_length = vapply(stations, function(x) length(x$series %||% list()), integer(1))
  )
}

read_reports_export <- function(path) {
  if (!file.exists(path)) {
    return(tibble())
  }

  payload <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  zones <- payload$zones %||% list()

  if (!length(zones)) {
    return(tibble())
  }

  rows <- lapply(zones, function(zone) {
    zone_label <- as.character(zone$label %||% NA_character_)

    dataset_rows <- function(dataset_name, rows) {
      if (!length(rows)) {
        return(tibble())
      }

      tibble(
        zone = zone_label,
        dataset = dataset_name,
        station_id = vapply(rows, function(x) as.character(x$station_id %||% NA_character_), character(1)),
        as_of_timestamp = vapply(rows, function(x) as.character((x$as_of_timestamp %||% x$latest_timestamp) %||% NA_character_), character(1)),
        freshness_status = vapply(rows, function(x) as.character(x$freshness_status %||% NA_character_), character(1))
      )
    }

    bind_rows(
      dataset_rows("precip", zone$precip$rows %||% list()),
      dataset_rows("soil_moisture_1", zone$soil_moisture_1$rows %||% list()),
      dataset_rows("soil_moisture_2", zone$soil_moisture_2$rows %||% list())
    )
  })

  bind_rows(rows)
}

stage_header <- function(label) {
  cat("\n", label, "\n", strrep("-", nchar(label)), "\n", sep = "")
}

db_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DB_PATH", unset = NA_character_),
    "/data/sofu.sqlite",
    "data/sofu.sqlite"
  )
)
zone_csv_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_ZONE_CSV_PATH", unset = NA_character_),
    file.path(dirname(db_path), "main_ExportTable_zones.csv"),
    "data/main_ExportTable_zones.csv"
  )
)
dashboard_json_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DASHBOARD_JSON_PATH", unset = NA_character_),
    "output/latest/data/dashboard.json"
  ),
  create_parent = TRUE
)
reports_json_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_REPORTS_JSON_PATH", unset = NA_character_),
    "output/latest/data/reports.json"
  ),
  create_parent = TRUE
)
output_dir <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_TRACE_OUTPUT_DIR", unset = NA_character_),
    "output/pipeline-trace"
  ),
  dir_ok = TRUE,
  create_parent = TRUE
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

cat("SOFU pipeline trace\n")
cat("db_path:", db_path, "\n")
cat("zone_csv_path:", zone_csv_path, "\n")
cat("dashboard_json_path:", dashboard_json_path, "\n")
cat("reports_json_path:", reports_json_path, "\n")
cat("output_dir:", output_dir, "\n")

if (!file.exists(db_path)) {
  stop("Database not found: ", db_path)
}

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
on.exit(DBI::dbDisconnect(con), add = TRUE)

local_today <- as.Date(format(Sys.time(), tz = "America/Denver", usetz = FALSE))
expected_current_date <- local_today - 1L

stage_header("1. Roster -> sites_in_cg")

roster <- read_roster(zone_csv_path)
sites_in_cg <- if (DBI::dbExistsTable(con, "sites_in_cg")) {
  DBI::dbReadTable(con, "sites_in_cg") %>%
    tibble::as_tibble() %>%
    mutate(
      station_id = as.character(.data$station_id),
      station_name = as.character(.data$station_name),
      api = as.character(.data$api)
    )
} else {
  tibble()
}

roster_compare <- roster %>%
  select(.data$station_id, roster_station_name = .data$station_name, roster_api = .data$api) %>%
  full_join(
    sites_in_cg %>%
      select(.data$station_id, db_station_name = .data$station_name, db_api = .data$api),
    by = "station_id"
  ) %>%
  mutate(
    in_roster = !is.na(.data$roster_api),
    in_sites = !is.na(.data$db_api),
    name_matches = dplyr::coalesce(.data$roster_station_name == .data$db_station_name, FALSE),
    api_matches = dplyr::coalesce(.data$roster_api == .data$db_api, FALSE)
  ) %>%
  arrange(.data$station_id)

utils::write.csv(roster_compare, file.path(output_dir, "01_roster_vs_sites_in_cg.csv"), row.names = FALSE)
cat("rows in roster:", nrow(roster), "\n")
cat("rows in sites_in_cg:", nrow(sites_in_cg), "\n")
cat("name mismatches:", sum(roster_compare$in_roster & roster_compare$in_sites & !roster_compare$name_matches, na.rm = TRUE), "\n")

stage_header("2. Raw tables -> latest by station")

raw_synoptic <- if (DBI::dbExistsTable(con, "synoptic_fems_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(date) AS raw_max_epoch,",
      "MAX(CASE WHEN \"air_temp_set_1.mean\" IS NOT NULL THEN date END) AS air_temp_epoch,",
      "MAX(CASE WHEN \"relative_humidity_set_1.mean\" IS NOT NULL THEN date END) AS humidity_epoch,",
      "MAX(CASE WHEN \"soil_moisture_set_1.mean\" IS NOT NULL THEN date END) AS sm1_epoch,",
      "MAX(CASE WHEN \"soil_moisture_set_2.mean\" IS NOT NULL THEN date END) AS sm2_epoch,",
      "MAX(CASE WHEN \"precip_accum_set_1.mean\" IS NOT NULL THEN date END) AS precip_epoch",
      "FROM synoptic_fems_data",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      raw_max_local_date = as.Date(vapply(.data$raw_max_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      air_temp_local_date = as.Date(vapply(.data$air_temp_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      humidity_local_date = as.Date(vapply(.data$humidity_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      sm1_local_date = as.Date(vapply(.data$sm1_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      sm2_local_date = as.Date(vapply(.data$sm2_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      precip_local_date = as.Date(vapply(.data$precip_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1)))
    )
} else {
  tibble()
}

raw_zentra <- if (DBI::dbExistsTable(con, "zentracloud_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(date) AS raw_max_epoch,",
      "MAX(CASE WHEN port_1_atmos_41_f_air_temperature IS NOT NULL THEN date END) AS air_temp_epoch,",
      "MAX(CASE WHEN port_1_atmos_41_percent_relative_humidity IS NOT NULL THEN date END) AS humidity_epoch,",
      "MAX(CASE WHEN port_2_teros_11_percent_water_content IS NOT NULL THEN date END) AS sm1_epoch,",
      "MAX(CASE WHEN port_3_teros_11_percent_water_content IS NOT NULL THEN date END) AS sm2_epoch,",
      "MAX(CASE WHEN port_1_atmos_41_in_precipitation IS NOT NULL THEN date END) AS precip_epoch",
      "FROM zentracloud_data",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      raw_max_local_date = as.Date(vapply(.data$raw_max_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      air_temp_local_date = as.Date(vapply(.data$air_temp_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      humidity_local_date = as.Date(vapply(.data$humidity_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      sm1_local_date = as.Date(vapply(.data$sm1_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      sm2_local_date = as.Date(vapply(.data$sm2_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1))),
      precip_local_date = as.Date(vapply(.data$precip_epoch, function(x) as.character(safe_local_date_from_epoch(x)), character(1)))
    )
} else {
  tibble()
}

raw_latest <- bind_rows(
  roster %>% filter(.data$api %in% c("Synoptic", "FEMS")) %>% left_join(raw_synoptic, by = "station_id"),
  roster %>% filter(.data$api == "Zentra") %>% left_join(raw_zentra, by = "station_id")
) %>%
  mutate(
    freshness_status = case_when(
      is.na(.data$raw_max_local_date) ~ "missing",
      .data$raw_max_local_date >= expected_current_date ~ "current_enough",
      TRUE ~ "stale"
    )
  ) %>%
  arrange(.data$api, .data$station_id)

utils::write.csv(raw_latest, file.path(output_dir, "02_raw_latest_by_station.csv"), row.names = FALSE)
print(raw_latest %>% count(.data$api, .data$freshness_status, name = "n_sites"))

stage_header("3. Daily stats -> latest by station and metric")

stats_synoptic <- if (DBI::dbExistsTable(con, "synoptic_fems_daily_stats")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id, source, metric_name, MAX(local_date) AS max_local_date,",
      "MAX(updated_at_utc) AS updated_at_utc",
      "FROM synoptic_fems_daily_stats",
      "GROUP BY station_id, source, metric_name"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      local_date = as.Date(as.numeric(.data$max_local_date), origin = "1970-01-01"),
      updated_at_local = vapply(.data$updated_at_utc, safe_iso_from_epoch, character(1))
    )
} else {
  tibble()
}

stats_zentra <- if (DBI::dbExistsTable(con, "zentracloud_daily_stats")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id, source, metric_name, MAX(local_date) AS max_local_date,",
      "MAX(updated_at_utc) AS updated_at_utc",
      "FROM zentracloud_daily_stats",
      "GROUP BY station_id, source, metric_name"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      local_date = as.Date(as.numeric(.data$max_local_date), origin = "1970-01-01"),
      updated_at_local = vapply(.data$updated_at_utc, safe_iso_from_epoch, character(1))
    )
} else {
  tibble()
}

stats_latest <- bind_rows(stats_synoptic, stats_zentra) %>%
  arrange(.data$station_id, .data$source, .data$metric_name)

utils::write.csv(stats_latest, file.path(output_dir, "03_stats_latest_by_station_metric.csv"), row.names = FALSE)

stats_focus <- stats_latest %>%
  filter(.data$metric_name %in% c("air_temp_set_1.mean", "relative_humidity_set_1.mean", "soil_moisture_set_1.mean", "soil_moisture_set_2.mean", "gsi", "kbdi", "port_1_atmos_41_f_air_temperature", "port_1_atmos_41_percent_relative_humidity", "port_2_teros_11_percent_water_content", "port_3_teros_11_percent_water_content")) %>%
  arrange(.data$station_id, .data$metric_name, .data$source)
utils::write.csv(stats_focus, file.path(output_dir, "03b_stats_focus_metrics.csv"), row.names = FALSE)

stage_header("4. DB -> dashboard export")

dashboard_export <- read_dashboard_export(dashboard_json_path)

dashboard_compare <- roster %>%
  select(.data$station_id, roster_station_name = .data$station_name, roster_api = .data$api) %>%
  left_join(raw_latest %>% select(.data$station_id, db_raw_latest_date = .data$raw_max_local_date), by = "station_id") %>%
  left_join(dashboard_export, by = "station_id") %>%
  mutate(
    name_matches_roster = dplyr::coalesce(.data$exported_name == .data$roster_station_name, FALSE),
    api_matches_roster = dplyr::coalesce(.data$exported_api == .data$roster_api, FALSE),
    latest_matches_db = dplyr::coalesce(.data$exported_latest_date == .data$db_raw_latest_date, FALSE),
    export_missing = is.na(.data$exported_latest_timestamp)
  ) %>%
  arrange(.data$roster_api, .data$station_id)

utils::write.csv(dashboard_compare, file.path(output_dir, "04_dashboard_compare.csv"), row.names = FALSE)
cat("dashboard export missing rows:", sum(dashboard_compare$export_missing, na.rm = TRUE), "\n")
cat("dashboard name mismatches:", sum(!dashboard_compare$name_matches_roster, na.rm = TRUE), "\n")
cat("dashboard latest-date mismatches:", sum(!dashboard_compare$latest_matches_db & !dashboard_compare$export_missing, na.rm = TRUE), "\n")

stage_header("5. DB -> reports export")

reports_export <- read_reports_export(reports_json_path)

reports_compare <- reports_export %>%
  mutate(as_of_date = as.Date(substr(.data$as_of_timestamp, 1, 10))) %>%
  left_join(
    raw_latest %>% select(.data$station_id, db_raw_latest_date = .data$raw_max_local_date, api),
    by = "station_id"
  ) %>%
  mutate(
    export_age = as.integer(expected_current_date - .data$as_of_date),
    db_age = as.integer(expected_current_date - .data$db_raw_latest_date)
  ) %>%
  arrange(.data$dataset, .data$zone, .data$station_id)

utils::write.csv(reports_compare, file.path(output_dir, "05_reports_compare.csv"), row.names = FALSE)
cat("report rows:", nrow(reports_compare), "\n")
cat("report freshness_status unknown rows:", sum(reports_compare$freshness_status %in% "unknown", na.rm = TRUE), "\n")

stage_header("6. Likely breakpoints")

breakpoints <- bind_rows(
  dashboard_compare %>%
    filter(.data$export_missing | !.data$name_matches_roster | !.data$latest_matches_db) %>%
    transmute(
      stage = "dashboard_export",
      station_id,
      api = .data$roster_api,
      issue = case_when(
        .data$export_missing ~ "station missing from dashboard export",
        !.data$name_matches_roster ~ "exported station name differs from roster",
        !.data$latest_matches_db ~ "dashboard latest date differs from DB raw latest date",
        TRUE ~ "unknown"
      )
    ),
  raw_latest %>%
    filter(.data$freshness_status != "current_enough") %>%
    transmute(
      stage = "raw_ingest",
      station_id,
      api,
      issue = paste("raw table freshness =", .data$freshness_status)
    ),
  reports_compare %>%
    filter(is.na(.data$as_of_date) | .data$freshness_status %in% c("unknown", "", NA_character_)) %>%
    transmute(
      stage = "reports_export",
      station_id,
      api,
      issue = "reports row missing usable as_of/freshness"
    )
) %>%
  arrange(.data$stage, .data$api, .data$station_id)

utils::write.csv(breakpoints, file.path(output_dir, "06_likely_breakpoints.csv"), row.names = FALSE)
print(breakpoints %>% count(.data$stage, name = "n_flags"))

cat("\nWrote pipeline trace files to:", output_dir, "\n")
cat("- 01_roster_vs_sites_in_cg.csv\n")
cat("- 02_raw_latest_by_station.csv\n")
cat("- 03_stats_latest_by_station_metric.csv\n")
cat("- 03b_stats_focus_metrics.csv\n")
cat("- 04_dashboard_compare.csv\n")
cat("- 05_reports_compare.csv\n")
cat("- 06_likely_breakpoints.csv\n")
