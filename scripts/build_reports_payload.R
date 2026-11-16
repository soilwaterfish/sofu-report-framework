#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(jsonlite)
})

resolve_first_existing <- function(candidates, create_parent = FALSE) {
  for (candidate in candidates) {
    if (!is.na(candidate) && nzchar(candidate) && file.exists(candidate)) {
      return(candidate)
    }
  }

  fallback <- candidates[[length(candidates)]]
  if (create_parent) {
    dir.create(dirname(fallback), recursive = TRUE, showWarnings = FALSE)
  }
  fallback
}

db_path <- resolve_first_existing(c(
  Sys.getenv("SOFU_DB_PATH", unset = NA_character_),
  "data/sofu.sqlite"
))

output_dir <- Sys.getenv("SOFU_OUTPUT_DIR", unset = NA_character_)
output_path <- Sys.getenv("SOFU_REPORTS_JSON_PATH", unset = "")
if (!nzchar(output_path)) {
  output_path <- if (!is.na(output_dir) && nzchar(output_dir)) {
    file.path(output_dir, "latest", "data", "reports.json")
  } else {
    "output/latest/data/reports.json"
  }
}

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)

dashboard_timezone <- "America/Denver"
local_today <- as.Date(format(Sys.time(), tz = dashboard_timezone, usetz = FALSE))
stale_threshold_days <- suppressWarnings(as.integer(Sys.getenv("SOFU_REPORT_STALE_DAYS", "3")))
if (is.na(stale_threshold_days) || stale_threshold_days < 0) {
  stale_threshold_days <- 3L
}

format_iso_mountain <- function(value, api_label = NULL) {
  if (length(value) == 0 || is.na(value)) {
    return(NA_character_)
  }

  stamp <- as.POSIXct(value, origin = "1970-01-01", tz = "UTC")
  local_stamp <- as.POSIXct(format(stamp, tz = dashboard_timezone, usetz = TRUE), tz = dashboard_timezone)
  offset <- format(local_stamp, "%z")
  offset <- sub("([+-][0-9]{2})([0-9]{2})$", "\\1:\\2", offset)
  paste0(format(local_stamp, "%Y-%m-%dT%H:%M:%S"), offset)
}

slugify <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "-", x)
  x <- gsub("(^-|-$)", "", x)
  ifelse(nzchar(x), x, "report")
}

zone_label_from_column <- function(column_name) {
  label <- gsub("_", " ", as.character(column_name))
  label <- gsub("\\s+", " ", trimws(label))
  label <- tools::toTitleCase(label)
  label <- gsub("\\bAb\\b", "AB", label)
  label
}

is_truthy_zone_flag <- function(x) {
  if (is.logical(x)) {
    return(!is.na(x) & x)
  }
  if (is.numeric(x)) {
    return(!is.na(x) & x != 0)
  }

  values <- toupper(trimws(as.character(x)))
  !is.na(values) & values %in% c("TRUE", "T", "1", "YES", "Y")
}

null_if_na <- function(value) {
  if (length(value) == 0 || is.na(value)) {
    return(NA)
  }
  unname(value)
}

safe_numeric <- function(value) {
  if (is.null(value) || length(value) == 0 || is.na(value)) {
    return(NA_real_)
  }
  as.numeric(value)
}

parse_iso_timestamp <- function(value) {
  if (length(value) == 0 || is.na(value) || !nzchar(trimws(as.character(value)))) {
    return(as.POSIXct(NA))
  }

  parsed <- suppressWarnings(as.POSIXct(as.character(value), format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"))
  if (is.na(parsed)) {
    parsed <- suppressWarnings(as.POSIXct(as.character(value), tz = "UTC"))
  }

  parsed
}

latest_local_date_from_timestamp <- function(value) {
  parsed <- parse_iso_timestamp(value)
  if (is.na(parsed)) {
    return(as.Date(NA))
  }

  as.Date(format(parsed, tz = dashboard_timezone, usetz = FALSE))
}

row_freshness_from_timestamp <- function(value) {
  local_date <- latest_local_date_from_timestamp(value)
  if (is.na(local_date)) {
    return(list(status = "unknown", days_stale = NA_integer_))
  }

  days_stale <- as.integer(local_today - local_date)
  status <- if (!is.na(days_stale) && days_stale > stale_threshold_days) "stale" else "current"
  list(status = status, days_stale = days_stale)
}

normalize_report_row <- function(station_row, value_timestamp, totals, metric_key = "precip_accum") {
  freshness <- row_freshness_from_timestamp(value_timestamp)
  latest_value <- if (!is.na(value_timestamp) && nzchar(as.character(value_timestamp))) {
    as.character(value_timestamp)
  } else {
    NA_character_
  }

  row <- list(
    station_id = as.character(station_row$station_id[[1]]),
    station_name = as.character(station_row$station_name[[1]]),
    api = as.character(station_row$api[[1]]),
    info = as.character(station_row$api[[1]]),
    as_of_timestamp = latest_value,
    latest_timestamp = latest_value,
    station_latest_timestamp = as.character(station_row$latest_timestamp[[1]]),
    freshness_status = as.character(freshness$status),
    days_stale = if (!is.na(freshness$days_stale)) as.integer(freshness$days_stale) else NA_integer_,
    totals = list(
      hours_24 = null_if_na(totals[["d1"]]),
      days_2 = null_if_na(totals[["d2"]]),
      days_7 = null_if_na(totals[["d7"]]),
      days_30 = null_if_na(totals[["d30"]])
    )
  )
  reference <- station_rate_exports[[row$station_id]]$metrics[[metric_key]]
  if (!is.null(reference)) {
    row$rates <- reference$rates
    row$rate_details <- reference$rate_details
    row$rate_method <- reference$rate_method
  }
  row
}

compute_cumulative_precip_increments <- function(values) {
  values <- suppressWarnings(as.numeric(values))
  increments <- rep(NA_real_, length(values))

  for (idx in seq_along(values)) {
    current_value <- values[[idx]]
    if (!is.finite(current_value)) {
      next
    }

    if (idx == 1L) {
      increments[[idx]] <- max(current_value, 0)
      next
    }

    previous_value <- values[[idx - 1L]]
    if (!is.finite(previous_value)) {
      increments[[idx]] <- max(current_value, 0)
    } else if (current_value >= previous_value) {
      increments[[idx]] <- current_value - previous_value
    } else {
      increments[[idx]] <- max(current_value, 0)
    }
  }

  increments[!is.finite(increments) | increments < 0] <- NA_real_
  increments
}

compute_station_precip_windows <- function(raw_rows, api_label, windows_days = c(1, 2, 7, 30)) {
  empty <- list(latest_timestamp = NA_character_, totals = setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days)))
  if (!nrow(raw_rows) || !"date" %in% names(raw_rows)) {
    return(empty)
  }

  raw_rows$date <- suppressWarnings(as.numeric(raw_rows$date))
  raw_rows <- raw_rows[is.finite(raw_rows$date), , drop = FALSE]
  if (!nrow(raw_rows)) {
    return(empty)
  }

  raw_rows <- raw_rows[order(raw_rows$date), , drop = FALSE]
  raw_rows <- raw_rows[!duplicated(raw_rows$date, fromLast = TRUE), , drop = FALSE]
  latest_epoch <- max(raw_rows$date, na.rm = TRUE)

  totals <- setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days))

  if (identical(api_label, "Zentra") && "precip_value" %in% names(raw_rows)) {
    precip_values <- suppressWarnings(as.numeric(raw_rows$precip_value))
    for (window_days in windows_days) {
      cutoff <- latest_epoch - window_days * 24 * 60 * 60
      idx <- raw_rows$date > cutoff & raw_rows$date <= latest_epoch
      if (any(idx, na.rm = TRUE)) {
        totals[[paste0("d", window_days)]] <- sum(precip_values[idx], na.rm = TRUE)
      }
    }
  } else if ("precip_value" %in% names(raw_rows)) {
    precip_values <- suppressWarnings(as.numeric(raw_rows$precip_value))
    for (window_days in windows_days) {
      cutoff <- latest_epoch - window_days * 24 * 60 * 60
      idx <- raw_rows$date > cutoff & raw_rows$date <= latest_epoch
      if (any(idx, na.rm = TRUE)) {
        totals[[paste0("d", window_days)]] <- sum(precip_values[idx], na.rm = TRUE)
      }
    }
  } else if ("precip_cumulative" %in% names(raw_rows)) {
    increments <- compute_cumulative_precip_increments(raw_rows$precip_cumulative)
    for (window_days in windows_days) {
      cutoff <- latest_epoch - window_days * 24 * 60 * 60
      idx <- raw_rows$date > cutoff & raw_rows$date <= latest_epoch
      if (any(idx, na.rm = TRUE)) {
        totals[[paste0("d", window_days)]] <- sum(increments[idx], na.rm = TRUE)
      }
    }
  }

  list(
    latest_timestamp = format_iso_mountain(latest_epoch, api_label),
    totals = totals
  )
}

compute_station_change_windows <- function(raw_rows, value_column, api_label, windows_days = c(1, 2, 7, 30)) {
  empty <- list(latest_timestamp = NA_character_, totals = setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days)))
  if (!nrow(raw_rows) || !"date" %in% names(raw_rows) || !value_column %in% names(raw_rows)) {
    return(empty)
  }

  raw_rows$date <- suppressWarnings(as.numeric(raw_rows$date))
  raw_rows$value <- suppressWarnings(as.numeric(raw_rows[[value_column]]))
  raw_rows <- raw_rows[is.finite(raw_rows$date) & is.finite(raw_rows$value), c("date", "value"), drop = FALSE]
  if (!nrow(raw_rows)) {
    return(empty)
  }

  raw_rows <- raw_rows[order(raw_rows$date), , drop = FALSE]
  raw_rows <- raw_rows[!duplicated(raw_rows$date, fromLast = TRUE), , drop = FALSE]
  latest_epoch <- max(raw_rows$date, na.rm = TRUE)
  totals <- setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days))

  for (window_days in windows_days) {
    cutoff <- latest_epoch - window_days * 24 * 60 * 60
    window_rows <- raw_rows[raw_rows$date > cutoff & raw_rows$date <= latest_epoch, , drop = FALSE]
    if (nrow(window_rows) >= 2) {
      totals[[paste0("d", window_days)]] <- window_rows$value[[nrow(window_rows)]] - window_rows$value[[1]]
    }
  }

  list(
    latest_timestamp = format_iso_mountain(latest_epoch, api_label),
    totals = totals
  )
}

has_any_numeric_totals <- function(row) {
  totals <- suppressWarnings(as.numeric(unlist(row$totals, use.names = FALSE)))
  any(is.finite(totals))
}

con <- DBI::dbConnect(RSQLite::SQLite(), db_path, flags = RSQLite::SQLITE_RO)
on.exit(DBI::dbDisconnect(con), add = TRUE)

sites_lookup <- DBI::dbReadTable(con, "sites_in_cg")
helper_candidates <- c("/app/scripts/station_rates_helpers.R", "scripts/station_rates_helpers.R")
helper_path <- helper_candidates[file.exists(helper_candidates)][1]
if (is.na(helper_path)) stop("Could not locate station_rates_helpers.R")
source(helper_path)
station_rate_exports <- build_station_rate_exports(con, sites_lookup,
  file.path(dirname(output_path), "current", "weather"))
zone_columns <- grep("_zone$", names(sites_lookup), value = TRUE)

raw_zentra_precip <- DBI::dbGetQuery(
  con,
  sprintf(
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "date,",
      "port_1_atmos_41_in_precipitation AS precip_value",
      "FROM zentracloud_data",
      "WHERE date >= %s",
      "AND port_1_atmos_41_in_precipitation IS NOT NULL"
    ),
    as.numeric(Sys.time()) - 31 * 24 * 60 * 60
  )
)

raw_synoptic_precip <- DBI::dbGetQuery(
  con,
  sprintf(
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "date,",
      "\"precip_accum_set_1.mean\" AS precip_cumulative,",
      "\"precip_accum_one_hour_set_1.mean\" AS precip_value",
      "FROM synoptic_fems_data",
      "WHERE date >= %s",
      "AND \"precip_accum_one_hour_set_1.mean\" IS NOT NULL"
    ),
    as.numeric(Sys.time()) - 31 * 24 * 60 * 60
  )
)

raw_zentra_soil <- DBI::dbGetQuery(
  con,
  sprintf(
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "date,",
      "port_2_teros_11_percent_water_content AS soil_moisture_1,",
      "port_3_teros_11_percent_water_content AS soil_moisture_2",
      "FROM zentracloud_data",
      "WHERE date >= %s"
    ),
    as.numeric(Sys.time()) - 31 * 24 * 60 * 60
  )
)

raw_synoptic_soil <- DBI::dbGetQuery(
  con,
  sprintf(
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "date,",
      "\"soil_moisture_set_1.mean\" AS soil_moisture_1,",
      "\"soil_moisture_set_2.mean\" AS soil_moisture_2",
      "FROM synoptic_fems_data",
      "WHERE date >= %s"
    ),
    as.numeric(Sys.time()) - 31 * 24 * 60 * 60
  )
)

summarize_metric <- function(values) {
  values <- values[is.finite(values)]
  if (!length(values)) {
    return(list(max = NA, average = NA, min = NA))
  }

  list(
    max = max(values, na.rm = TRUE),
    average = mean(values, na.rm = TRUE),
    min = min(values, na.rm = TRUE)
  )
}

zones <- list()

for (zone_column in zone_columns) {
  zone_rows <- sites_lookup[is_truthy_zone_flag(sites_lookup[[zone_column]]), , drop = FALSE]
  if (!nrow(zone_rows)) {
    next
  }

  zone_rows <- zone_rows[order(zone_rows$api, zone_rows$station_name), , drop = FALSE]

  station_rows <- lapply(seq_len(nrow(zone_rows)), function(i) {
    station_row <- zone_rows[i, , drop = FALSE]
    station_id <- as.character(station_row$station_id[[1]])
    station_api <- as.character(station_row$api[[1]])
    precip_windows <- if (identical(station_api, "Zentra")) {
      compute_station_precip_windows(raw_zentra_precip[raw_zentra_precip$station_id == station_id, , drop = FALSE], "Zentra")
    } else {
      compute_station_precip_windows(raw_synoptic_precip[raw_synoptic_precip$station_id == station_id, , drop = FALSE], station_api)
    }

    as_of_timestamp <- if (!is.na(precip_windows$latest_timestamp)) precip_windows$latest_timestamp else NA_character_
    normalize_report_row(station_row, as_of_timestamp, precip_windows$totals)
  })

  soil_rows_sm1 <- lapply(seq_len(nrow(zone_rows)), function(i) {
    station_row <- zone_rows[i, , drop = FALSE]
    station_id <- as.character(station_row$station_id[[1]])
    station_api <- as.character(station_row$api[[1]])
    soil_windows <- if (identical(station_api, "Zentra")) {
      compute_station_change_windows(
        raw_zentra_soil[raw_zentra_soil$station_id == station_id, , drop = FALSE],
        "soil_moisture_1",
        "Zentra"
      )
    } else {
      compute_station_change_windows(
        raw_synoptic_soil[raw_synoptic_soil$station_id == station_id, , drop = FALSE],
        "soil_moisture_1",
        station_api
      )
    }

    as_of_timestamp <- if (!is.na(soil_windows$latest_timestamp)) soil_windows$latest_timestamp else NA_character_
    normalize_report_row(station_row, as_of_timestamp, soil_windows$totals, "soil_moisture_1")
  })

  soil_rows_sm2 <- lapply(seq_len(nrow(zone_rows)), function(i) {
    station_row <- zone_rows[i, , drop = FALSE]
    station_id <- as.character(station_row$station_id[[1]])
    station_api <- as.character(station_row$api[[1]])
    soil_windows <- if (identical(station_api, "Zentra")) {
      compute_station_change_windows(
        raw_zentra_soil[raw_zentra_soil$station_id == station_id, , drop = FALSE],
        "soil_moisture_2",
        "Zentra"
      )
    } else {
      compute_station_change_windows(
        raw_synoptic_soil[raw_synoptic_soil$station_id == station_id, , drop = FALSE],
        "soil_moisture_2",
        station_api
      )
    }

    as_of_timestamp <- if (!is.na(soil_windows$latest_timestamp)) soil_windows$latest_timestamp else NA_character_
    normalize_report_row(station_row, as_of_timestamp, soil_windows$totals, "soil_moisture_2")
  })

  station_rows <- Filter(has_any_numeric_totals, station_rows)
  soil_rows_sm1 <- Filter(has_any_numeric_totals, soil_rows_sm1)
  soil_rows_sm2 <- Filter(has_any_numeric_totals, soil_rows_sm2)

  zones[[length(zones) + 1L]] <- list(
    id = zone_column,
    label = zone_label_from_column(zone_column),
    slug = slugify(zone_label_from_column(zone_column)),
    station_count = nrow(zone_rows),
    source_counts = list(
      FEMS = sum(zone_rows$api == "FEMS", na.rm = TRUE),
      Synoptic = sum(zone_rows$api == "Synoptic", na.rm = TRUE),
      Zentra = sum(zone_rows$api == "Zentra", na.rm = TRUE)
    ),
    latest_timestamp = {
      latest_vals <- vapply(station_rows, function(row) {
        value <- row$as_of_timestamp
        if (is.null(value) || !length(value) || is.na(value) || !nzchar(as.character(value))) {
          value <- row$station_latest_timestamp
        }
        if (is.null(value) || !length(value) || is.na(value) || !nzchar(as.character(value))) {
          return(NA_character_)
        }
        as.character(value)
      }, character(1))
      latest_vals <- latest_vals[!is.na(latest_vals) & nzchar(latest_vals)]
      if (length(latest_vals)) max(latest_vals) else NA_character_
    },
    precip = list(
      rows = station_rows,
      summary = list(
        hours_24 = summarize_metric(vapply(station_rows, function(row) safe_numeric(row$totals$hours_24), numeric(1))),
        days_2 = summarize_metric(vapply(station_rows, function(row) safe_numeric(row$totals$days_2), numeric(1))),
        days_7 = summarize_metric(vapply(station_rows, function(row) safe_numeric(row$totals$days_7), numeric(1))),
        days_30 = summarize_metric(vapply(station_rows, function(row) safe_numeric(row$totals$days_30), numeric(1)))
      )
    ),
    soil_moisture_1 = list(
      rows = soil_rows_sm1,
      summary = list(
        hours_24 = summarize_metric(vapply(soil_rows_sm1, function(row) safe_numeric(row$totals$hours_24), numeric(1))),
        days_2 = summarize_metric(vapply(soil_rows_sm1, function(row) safe_numeric(row$totals$days_2), numeric(1))),
        days_7 = summarize_metric(vapply(soil_rows_sm1, function(row) safe_numeric(row$totals$days_7), numeric(1))),
        days_30 = summarize_metric(vapply(soil_rows_sm1, function(row) safe_numeric(row$totals$days_30), numeric(1)))
      )
    ),
    soil_moisture_2 = list(
      rows = soil_rows_sm2,
      summary = list(
        hours_24 = summarize_metric(vapply(soil_rows_sm2, function(row) safe_numeric(row$totals$hours_24), numeric(1))),
        days_2 = summarize_metric(vapply(soil_rows_sm2, function(row) safe_numeric(row$totals$days_2), numeric(1))),
        days_7 = summarize_metric(vapply(soil_rows_sm2, function(row) safe_numeric(row$totals$days_7), numeric(1))),
        days_30 = summarize_metric(vapply(soil_rows_sm2, function(row) safe_numeric(row$totals$days_30), numeric(1)))
      )
    )
  )
}

for (i in seq_along(zones)) {
  station_rows <- sites_lookup[is_truthy_zone_flag(sites_lookup[[zones[[i]]$id]]), , drop = FALSE]
  for (metric in c("air_temp", "humidity", "wind_speed", "gsi", "kbdi")) {
    rows <- lapply(seq_len(nrow(station_rows)), function(j) {
      site <- station_rows[j, , drop = FALSE]
      current <- station_rate_exports[[as.character(site$station_id[[1]])]]$metrics[[metric]]
      if (is.null(current)) return(NULL)
      totals <- setNames(current$totals, c("d1", "d2", "d7", "d30"))
      normalize_report_row(site, current$latest_timestamp, totals, metric)
    })
    rows <- Filter(Negate(is.null), rows)
    summary <- setNames(lapply(c("hours_24", "days_2", "days_7", "days_30"), function(key) {
      summarize_metric(vapply(rows, function(row) safe_numeric(row$totals[[key]]), numeric(1)))
    }), c("hours_24", "days_2", "days_7", "days_30"))
    zones[[i]][[metric]] <- list(rows = rows, summary = summary)
  }
}

zones <- zones[order(vapply(zones, function(zone) zone$station_count, integer(1)), decreasing = TRUE)]

payload <- list(
  generated_at = format_iso_mountain(as.numeric(Sys.time())),
  zones = zones
)

temporary_path <- tempfile(tmpdir = dirname(output_path), fileext = ".json")
jsonlite::write_json(payload, temporary_path, auto_unbox = TRUE, pretty = FALSE, na = "null")
if (!file.rename(temporary_path, output_path)) stop("Could not publish reports payload: ", output_path)
cat("Wrote reports payload to:", output_path, "\n")
