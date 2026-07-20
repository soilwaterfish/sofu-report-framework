#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(dplyr)
  library(jsonlite)
  library(tibble)
})

options(width = 120)

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

safe_iso_local <- function(value, tz = "America/Denver") {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(NA_character_)
  }

  stamp <- as.POSIXct(as.numeric(value), origin = "1970-01-01", tz = "UTC")
  format(stamp, tz = tz, usetz = TRUE)
}

safe_local_date <- function(value, tz = "America/Denver") {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(as.Date(NA))
  }

  as.Date(format(as.POSIXct(as.numeric(value), origin = "1970-01-01", tz = "UTC"), tz = tz, usetz = FALSE))
}

read_dashboard_export <- function(path) {
  if (!file.exists(path)) {
    return(tibble())
  }

  payload <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  stations <- payload$stations

  if (!length(stations)) {
    return(tibble())
  }

  tibble::tibble(
    station_id = vapply(stations, function(x) as.character(x$id %||% NA_character_), character(1)),
    exported_name = vapply(stations, function(x) as.character(x$name %||% NA_character_), character(1)),
    exported_api = vapply(stations, function(x) as.character(x$api %||% NA_character_), character(1)),
    exported_latest_timestamp = vapply(stations, function(x) as.character(x$latest$timestamp %||% NA_character_), character(1)),
    series_length = vapply(stations, function(x) length(x$series %||% list()), integer(1)),
    exported_latitude = vapply(stations, function(x) as.character(x$latitude %||% NA_character_), character(1)),
    exported_longitude = vapply(stations, function(x) as.character(x$longitude %||% NA_character_), character(1)),
    exported_available_metrics = vapply(stations, function(x) paste(x$available_metrics %||% character(), collapse = ", "), character(1))
  )
}

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

run_live_fetch_checks <- function(stale_sites, roster, local_today, output_dir) {
  if (!requireNamespace("sofureport", quietly = TRUE)) {
    warning("Package `sofureport` not available, skipping live fetch checks.", call. = FALSE)
    return(tibble())
  }

  recent_days <- suppressWarnings(as.integer(Sys.getenv("SOFU_DIAG_RECENT_DAYS", "3")))
  if (is.na(recent_days) || recent_days < 1) {
    recent_days <- 3L
  }

  if (file.exists(Sys.getenv("SOFU_RENVIRON_PATH", unset = "/run/secrets/sofureport_renviron"))) {
    readRenviron(Sys.getenv("SOFU_RENVIRON_PATH", unset = "/run/secrets/sofureport_renviron"))
  } else if (file.exists("secrets/.Renviron")) {
    readRenviron("secrets/.Renviron")
  }

  roster_subset <- roster %>%
    filter(.data$station_id %in% stale_sites$station_id)

  start_dt <- as.POSIXct(paste(local_today - recent_days, "00:00:00"), tz = "America/Denver")
  end_dt <- as.POSIXct(paste(local_today, "23:59:59"), tz = "America/Denver")

  checks <- purrr::map_dfr(seq_len(nrow(roster_subset)), function(i) {
    row <- roster_subset[i, , drop = FALSE]
    station_id <- as.character(row$station_id[[1]])
    api <- as.character(row$api[[1]])

    if (identical(api, "Zentra")) {
      result <- tryCatch(
        sofureport::get_zentracloud_v5_data(
          device_id = station_id,
          start_datetime = format(as.POSIXct(start_dt, tz = "UTC"), "%Y-%m-%d %H:%M:%S", tz = "UTC"),
          end_datetime = format(as.POSIXct(end_dt, tz = "UTC"), "%Y-%m-%d %H:%M:%S", tz = "UTC")
        ),
        error = function(e) e
      )

      if (inherits(result, "error")) {
        return(tibble(
          station_id = station_id,
          api = api,
          live_rows = 0L,
          live_min_utc = NA_character_,
          live_max_utc = NA_character_,
          status = "error",
          note = conditionMessage(result)
        ))
      }

      return(tibble(
        station_id = station_id,
        api = api,
        live_rows = nrow(result),
        live_min_utc = if (nrow(result)) safe_iso_local(min(result$timestamp), tz = "UTC") else NA_character_,
        live_max_utc = if (nrow(result)) safe_iso_local(max(result$timestamp), tz = "UTC") else NA_character_,
        status = if (nrow(result)) "rows_returned" else "no_rows",
        note = NA_character_
      ))
    }

    if (identical(api, "FEMS")) {
      fetch_row <- row
      fetch_id <- if ("fems_fetch_id" %in% names(fetch_row)) as.character(fetch_row$fems_fetch_id[[1]]) else NA_character_

      if (is.na(fetch_id) || !nzchar(fetch_id)) {
        return(tibble(
          station_id = station_id,
          api = api,
          live_rows = 0L,
          live_min_utc = NA_character_,
          live_max_utc = NA_character_,
          status = "missing_fetch_id",
          note = "Could not resolve numeric FEMS fetch ID"
        ))
      }

      result <- tryCatch(
        sofureport::get_nfdrs_long(
          station_ids = fetch_id,
          start_date = as.Date(local_today - recent_days),
          end_date = as.Date(local_today),
          fuel_model = "Y",
          chunk_by = "7 days",
          parallel = FALSE
        ),
        error = function(e) e
      )

      if (inherits(result, "error")) {
        return(tibble(
          station_id = station_id,
          api = api,
          live_rows = 0L,
          live_min_utc = NA_character_,
          live_max_utc = NA_character_,
          status = "error",
          note = conditionMessage(result)
        ))
      }

      timestamps <- if ("display_hour_lst" %in% names(result) && nrow(result)) {
        as.POSIXct(result$display_hour_lst, tz = "America/Denver")
      } else {
        as.POSIXct(character())
      }

      return(tibble(
        station_id = station_id,
        api = api,
        live_rows = nrow(result),
        live_min_utc = if (length(timestamps)) as.character(min(timestamps, na.rm = TRUE)) else NA_character_,
        live_max_utc = if (length(timestamps)) as.character(max(timestamps, na.rm = TRUE)) else NA_character_,
        status = if (nrow(result)) "rows_returned" else "no_rows",
        note = paste("fetch_id =", fetch_id)
      ))
    }

    tibble(
      station_id = station_id,
      api = api,
      live_rows = NA_integer_,
      live_min_utc = NA_character_,
      live_max_utc = NA_character_,
      status = "skipped",
      note = "Live fetch only implemented for Zentra and FEMS"
    )
  })

  out_path <- file.path(output_dir, "live_fetch_checks.csv")
  utils::write.csv(checks, out_path, row.names = FALSE)
  checks
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
site_json_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DASHBOARD_JSON_PATH", unset = NA_character_),
    "output/latest/data/dashboard.json"
  ),
  create_parent = TRUE
)
output_dir <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DIAG_OUTPUT_DIR", unset = NA_character_),
    "output/diagnostics"
  ),
  dir_ok = TRUE,
  create_parent = TRUE
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

cat("\nSOFU diagnostics starting\n")
cat("db_path:", db_path, "\n")
cat("zone_csv_path:", zone_csv_path, "\n")
cat("dashboard_json:", site_json_path, "\n")
cat("output_dir:", output_dir, "\n")

if (!file.exists(db_path)) {
  stop("Database not found: ", db_path)
}

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
on.exit(DBI::dbDisconnect(con), add = TRUE)

local_today <- as.Date(format(Sys.time(), tz = "America/Denver", usetz = FALSE))
water_year_start <- as.Date(sprintf(
  "%d-10-01",
  ifelse(
    as.integer(format(local_today, "%m")) >= 10L,
    as.integer(format(local_today, "%Y")),
    as.integer(format(local_today, "%Y")) - 1L
  )
))
expected_current_date <- local_today - 1L

cat("\n[1/5] Reading site roster and DB station inventory\n")

roster <- tibble::as_tibble(utils::read.csv(zone_csv_path, check.names = FALSE, stringsAsFactors = FALSE, fileEncoding = "UTF-8-BOM")) %>%
  mutate(across(where(is.character), trimws)) %>%
  mutate(
    station_id = as.character(.data$station_id),
    station_name = as.character(.data$station_name),
    api = as.character(.data$api),
    fems_fetch_id = if ("fems_fetch_id" %in% names(.)) dplyr::na_if(as.character(.data$fems_fetch_id), "") else NA_character_
  ) %>%
  distinct(.data$station_id, .data$api, .keep_all = TRUE)

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

utils::write.csv(roster, file.path(output_dir, "zone_site_roster.csv"), row.names = FALSE)
utils::write.csv(sites_in_cg, file.path(output_dir, "sites_in_cg_snapshot.csv"), row.names = FALSE)

cat("\n[2/5] Summarizing latest DB dates by site\n")

raw_synoptic <- if (DBI::dbExistsTable(con, "synoptic_fems_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(date) AS raw_max_epoch",
      "FROM synoptic_fems_data",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      raw_max_utc = vapply(.data$raw_max_epoch, safe_iso_local, character(1), tz = "UTC"),
      raw_max_local = vapply(.data$raw_max_epoch, safe_iso_local, character(1), tz = "America/Denver"),
      raw_max_local_date = as.Date(vapply(.data$raw_max_epoch, function(x) as.character(safe_local_date(x)), character(1)))
    )
} else {
  tibble(station_id = character(), raw_max_epoch = numeric(), raw_max_utc = character(), raw_max_local = character(), raw_max_local_date = as.Date(character()))
}

stats_synoptic <- if (DBI::dbExistsTable(con, "synoptic_fems_daily_stats")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(local_date) AS stats_max_day",
      "FROM synoptic_fems_daily_stats",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      stats_max_local_date = as.Date(as.numeric(.data$stats_max_day), origin = "1970-01-01")
    )
} else {
  tibble(station_id = character(), stats_max_day = numeric(), stats_max_local_date = as.Date(character()))
}

raw_zentra <- if (DBI::dbExistsTable(con, "zentracloud_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(date) AS raw_max_epoch",
      "FROM zentracloud_data",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      raw_max_utc = vapply(.data$raw_max_epoch, safe_iso_local, character(1), tz = "UTC"),
      raw_max_local = vapply(.data$raw_max_epoch, safe_iso_local, character(1), tz = "America/Denver"),
      raw_max_local_date = as.Date(vapply(.data$raw_max_epoch, function(x) as.character(safe_local_date(x)), character(1)))
    )
} else {
  tibble(station_id = character(), raw_max_epoch = numeric(), raw_max_utc = character(), raw_max_local = character(), raw_max_local_date = as.Date(character()))
}

stats_zentra <- if (DBI::dbExistsTable(con, "zentracloud_daily_stats")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(local_date) AS stats_max_day",
      "FROM zentracloud_daily_stats",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      stats_max_local_date = as.Date(as.numeric(.data$stats_max_day), origin = "1970-01-01")
    )
} else {
  tibble(station_id = character(), stats_max_day = numeric(), stats_max_local_date = as.Date(character()))
}

synoptic_latest <- roster %>%
  filter(.data$api %in% c("Synoptic", "FEMS")) %>%
  left_join(raw_synoptic %>% select(.data$station_id, .data$raw_max_utc, .data$raw_max_local, .data$raw_max_local_date), by = "station_id") %>%
  left_join(stats_synoptic %>% select(.data$station_id, .data$stats_max_local_date), by = "station_id")

zentra_latest <- roster %>%
  filter(.data$api == "Zentra") %>%
  left_join(raw_zentra %>% select(.data$station_id, .data$raw_max_utc, .data$raw_max_local, .data$raw_max_local_date), by = "station_id") %>%
  left_join(stats_zentra %>% select(.data$station_id, .data$stats_max_local_date), by = "station_id")

latest_by_site <- bind_rows(synoptic_latest, zentra_latest) %>%
  mutate(
    expected_current_date = expected_current_date,
    freshness_status = case_when(
      is.na(.data$raw_max_local_date) ~ "missing",
      .data$raw_max_local_date >= .data$expected_current_date ~ "current_enough",
      TRUE ~ "stale"
    ),
    recommended_backfill_start = case_when(
      .data$api == "Zentra" ~ as.character(water_year_start),
      .data$api == "FEMS" ~ as.character(water_year_start),
      .data$api == "Synoptic" & !is.na(.data$raw_max_local_date) ~ as.character(.data$raw_max_local_date - 1L),
      TRUE ~ as.character(water_year_start)
    )
  ) %>%
  arrange(.data$api, .data$station_id)

utils::write.csv(latest_by_site, file.path(output_dir, "db_latest_by_site.csv"), row.names = FALSE)

cat("\n[3/5] Comparing DB contents to dashboard export\n")

dashboard_export <- read_dashboard_export(site_json_path)
site_export_compare <- latest_by_site %>%
  left_join(
    sites_in_cg %>%
      select(.data$station_id, db_station_name = .data$station_name, db_api = .data$api, db_latitude = .data$latitude, db_longitude = .data$longitude),
    by = "station_id"
  ) %>%
  left_join(dashboard_export, by = "station_id") %>%
  mutate(
    exported_latest_local_date = suppressWarnings(as.Date(substr(.data$exported_latest_timestamp, 1, 10))),
    name_matches_db = dplyr::coalesce(.data$exported_name == .data$db_station_name, FALSE),
    latest_matches_db = dplyr::coalesce(.data$exported_latest_local_date == .data$raw_max_local_date, FALSE),
    exported_has_coordinates = !is.na(.data$exported_latitude) & nzchar(.data$exported_latitude) & !is.na(.data$exported_longitude) & nzchar(.data$exported_longitude)
  ) %>%
  arrange(.data$api, .data$station_id)

utils::write.csv(site_export_compare, file.path(output_dir, "dashboard_export_compare.csv"), row.names = FALSE)

cat("\n[4/5] Writing backfill plan\n")

backfill_plan <- latest_by_site %>%
  transmute(
    station_id,
    station_name,
    api,
    raw_max_local_date,
    stats_max_local_date,
    freshness_status,
    recommended_backfill_start,
    backfill_reason = case_when(
      .data$freshness_status == "missing" ~ "No raw rows in DB",
      .data$freshness_status == "stale" ~ "Raw DB latest date is behind expected current date",
      TRUE ~ "No backfill needed"
    )
  )

utils::write.csv(backfill_plan, file.path(output_dir, "backfill_plan.csv"), row.names = FALSE)

cat("\n[5/5] Optional live fetch checks\n")

do_live_fetch <- identical(Sys.getenv("SOFU_DIAGNOSE_FETCH", "0"), "1")
if (do_live_fetch) {
  stale_sites <- latest_by_site %>% filter(.data$freshness_status != "current_enough")
  live_checks <- run_live_fetch_checks(stale_sites, roster, local_today, output_dir)
  utils::write.csv(live_checks, file.path(output_dir, "live_fetch_checks.csv"), row.names = FALSE)
} else {
  cat("Skipping live fetch checks. Set SOFU_DIAGNOSE_FETCH=1 to enable.\n")
}

summary_tbl <- latest_by_site %>%
  count(.data$api, .data$freshness_status, name = "n_sites")
utils::write.csv(summary_tbl, file.path(output_dir, "freshness_summary.csv"), row.names = FALSE)

cat("\nSummary\n")
print(summary_tbl)

cat("\nKey outputs written to", output_dir, "\n")
cat("- zone_site_roster.csv\n")
cat("- sites_in_cg_snapshot.csv\n")
cat("- db_latest_by_site.csv\n")
cat("- backfill_plan.csv\n")
cat("- dashboard_export_compare.csv\n")
cat("- freshness_summary.csv\n")
if (do_live_fetch) {
  cat("- live_fetch_checks.csv\n")
}
