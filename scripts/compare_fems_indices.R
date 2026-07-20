#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(dplyr)
  library(terra)
  library(jsonlite)
  library(tibble)
})

db_path <- Sys.getenv("SOFU_DB_PATH", unset = "data/sofu.sqlite")
prism_annual_ppt_path <- Sys.getenv(
  "SOFU_PRISM_ANNUAL_PPT_PATH",
  unset = "data/prism_ppt_us_30s_2020_avg_30y/prism_ppt_us_30s_2020_avg_30y.tif"
)
output_dir <- Sys.getenv("SOFU_VALIDATION_DIR", unset = "output/validation")
lookback_days <- suppressWarnings(as.integer(Sys.getenv("SOFU_VALIDATION_LOOKBACK_DAYS", unset = "")))
station_filter_env <- trimws(Sys.getenv("SOFU_VALIDATION_STATIONS", unset = ""))

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

clamp01 <- function(x) pmin(pmax(x, 0), 1)
fahrenheit_to_celsius <- function(x) (as.numeric(x) - 32) * 5 / 9

vpd_kpa_from_temp_rh <- function(temp_f, rh_pct) {
  temp_c <- fahrenheit_to_celsius(temp_f)
  rh_frac <- as.numeric(rh_pct) / 100
  es <- 0.6108 * exp((17.27 * temp_c) / (temp_c + 237.3))
  es * (1 - rh_frac)
}

daylength_hours <- function(date_value, latitude) {
  doy <- as.POSIXlt(as.Date(date_value), tz = "UTC")$yday + 1
  lat_rad <- as.numeric(latitude) * pi / 180
  decl <- 0.409 * sin((2 * pi / 365) * doy - 1.39)
  ws_arg <- -tan(lat_rad) * tan(decl)
  ws_arg <- pmin(pmax(ws_arg, -1), 1)
  ws <- acos(ws_arg)
  24 / pi * ws
}

compute_gsi_value <- function(tmin_f, vpd_kpa, latitude, local_date, prcp_mm = NA_real_, use_precip_limiter = FALSE) {
  tmin_c <- fahrenheit_to_celsius(tmin_f)
  vpd_pa <- as.numeric(vpd_kpa) * 1000
  photo <- daylength_hours(local_date, latitude)
  prcp_mm <- as.numeric(prcp_mm)

  i_tmin <- clamp01((tmin_c - (-2)) / (5 - (-2)))
  i_vpd <- clamp01(1 - ((vpd_pa - 900) / (4100 - 900)))
  i_photo <- clamp01((photo - 10) / (11 - 10))
  i_prcp <- rep(1, length(prcp_mm))
  if (isTRUE(use_precip_limiter)) {
    has_prcp <- !is.na(prcp_mm)
    i_prcp[has_prcp] <- clamp01((prcp_mm[has_prcp] - 0) / (10 - 0))
  }

  gsi <- i_tmin * i_vpd * i_photo * i_prcp
  gsi[is.na(tmin_f) | is.na(vpd_kpa) | is.na(latitude) | is.na(local_date)] <- NA_real_
  gsi
}

rolling_mean_right <- function(x, n = 28L) {
  x <- as.numeric(x)
  if (!length(x)) return(x)
  vapply(seq_along(x), function(idx) {
    start_idx <- max(1L, idx - n + 1L)
    window_vals <- x[start_idx:idx]
    if (all(is.na(window_vals))) return(NA_real_)
    mean(window_vals, na.rm = TRUE)
  }, numeric(1))
}

build_synoptic_daily_precip <- function(con, station_ids = NULL) {
  cutoff_clause <- ""
  if (!is.na(lookback_days) && is.finite(lookback_days) && lookback_days > 0) {
    cutoff_date <- Sys.Date() - lookback_days
    cutoff_epoch <- as.numeric(as.POSIXct(paste(cutoff_date, "00:00:00"), tz = "America/Denver"))
    cutoff_clause <- sprintf(
      "AND date >= %.0f",
      cutoff_epoch
    )
  }

  station_filter_sql <- if (!is.null(station_ids) && length(station_ids)) {
    sprintf(
      "AND station_id IN (%s)",
      paste(DBI::dbQuoteString(con, station_ids), collapse = ", ")
    )
  } else {
    ""
  }

  precip_rows <- DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT CAST(station_id AS TEXT) AS station_id,",
        "CAST(date(date, 'unixepoch', 'localtime') AS TEXT) AS local_date,",
        "MAX(\"precip_accum_since_local_midnight_set_1.mean\") AS precip_accum_since_midnight,",
        "MAX(\"precip_accum_24_hour_set_1.mean\") AS precip_24h,",
        "MAX(\"precip_accum_set_1.mean\") AS precip_accum",
        "FROM synoptic_fems_data",
        "WHERE 1 = 1 %s %s",
        "GROUP BY 1, 2"
      ),
      station_filter_sql,
      cutoff_clause
    )
  )

  if (!nrow(precip_rows)) {
    return(tibble::tibble(
      station_id = character(),
      local_date = as.Date(character()),
      precip_in = numeric(),
      has_precip_support = logical()
    ))
  }

  precip_rows %>%
    mutate(
      station_id = as.character(.data$station_id),
      local_date = as.Date(.data$local_date),
      precip_accum_since_midnight = as.numeric(.data$precip_accum_since_midnight),
      precip_24h = as.numeric(.data$precip_24h),
      precip_accum = as.numeric(.data$precip_accum)
    ) %>%
    arrange(.data$station_id, .data$local_date) %>%
    group_by(.data$station_id) %>%
    mutate(
      precip_accum_delta = dplyr::if_else(
        !is.na(.data$precip_accum) & !is.na(dplyr::lag(.data$precip_accum)),
        pmax(.data$precip_accum - dplyr::lag(.data$precip_accum), 0),
        NA_real_
      ),
      precip_in = dplyr::coalesce(.data$precip_accum_since_midnight, .data$precip_24h, .data$precip_accum_delta),
      has_precip_support = !is.na(.data$precip_accum_since_midnight) | !is.na(.data$precip_24h) | !is.na(.data$precip_accum)
    ) %>%
    ungroup() %>%
    select(.data$station_id, .data$local_date, .data$precip_in, .data$has_precip_support)
}

compute_kbdi_series <- function(local_date, tmax_f, precip_in, annual_ppt_in) {
  if (!length(local_date) || all(is.na(annual_ppt_in))) {
    return(rep(NA_real_, length(local_date)))
  }

  local_date <- as.Date(local_date)
  tmax_f <- as.numeric(tmax_f)
  precip_in <- as.numeric(precip_in)
  annual_ppt_in <- as.numeric(annual_ppt_in)

  order_idx <- order(local_date)
  kbdi_sorted <- rep(NA_real_, length(local_date))
  prev_kbdi <- 0
  map_in <- annual_ppt_in[order_idx][[1]]

  for (idx in seq_along(order_idx)) {
    row_idx <- order_idx[[idx]]
    rainfall_in <- precip_in[[row_idx]]
    rainfall_in <- ifelse(is.na(rainfall_in), 0, rainfall_in)

    current_kbdi <- prev_kbdi
    if (rainfall_in > 0.2) {
      current_kbdi <- max(prev_kbdi - 100 * (rainfall_in - 0.2), 0)
    }

    tmax_val <- tmax_f[[row_idx]]
    drought_factor <- 0

    if (!is.na(tmax_val) && !is.na(map_in)) {
      drought_factor <- (
        (800 - current_kbdi) *
          (0.968 * exp(0.0486 * tmax_val) - 8.30) *
          0.001
      ) / (1 + 10.88 * exp(-0.0441 * map_in))
      drought_factor <- max(drought_factor, 0)
    }

    current_kbdi <- min(max(current_kbdi + drought_factor, 0), 800)
    kbdi_sorted[[idx]] <- current_kbdi
    prev_kbdi <- current_kbdi
  }

  kbdi <- rep(NA_real_, length(local_date))
  kbdi[order_idx] <- kbdi_sorted
  kbdi
}

extract_station_annual_ppt <- function(station_lookup, raster_path) {
  if (!file.exists(raster_path)) {
    stop("PRISM annual precip raster not found: ", raster_path)
  }

  lookup_df <- station_lookup %>%
    mutate(
      stid = if ("STID" %in% names(.)) as.character(.data$STID) else as.character(.data$stid),
      wims_id = if ("WIMS_ID" %in% names(.)) as.character(.data$WIMS_ID) else as.character(.data$wims_id)
    ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      station_key = as.character(.data$station_key),
      stid = as.character(.data$stid),
      wims_id = as.character(.data$wims_id),
      latitude = as.numeric(.data$latitude),
      longitude = as.numeric(.data$longitude)
    ) %>%
    filter(!is.na(.data$latitude), !is.na(.data$longitude))

  if (!nrow(lookup_df)) {
    return(tibble(
      station_id = character(),
      station_key = character(),
      stid = character(),
      wims_id = character(),
      latitude = numeric(),
      longitude = numeric(),
      annual_ppt_in = numeric()
    ))
  }

  prism_rast <- terra::rast(raster_path)
  points_vect <- terra::vect(
    as.matrix(lookup_df[, c("longitude", "latitude")]),
    type = "points",
    crs = "EPSG:4326"
  )

  extracted <- terra::extract(prism_rast, points_vect)
  names(extracted)[ncol(extracted)] <- "annual_ppt_mm"

  lookup_df %>%
    bind_cols(extracted["annual_ppt_mm"]) %>%
    mutate(annual_ppt_in = as.numeric(.data$annual_ppt_mm) / 25.4)
}

metric_stats <- function(obs, sim) {
  keep <- is.finite(obs) & is.finite(sim)
  obs <- obs[keep]
  sim <- sim[keep]
  if (!length(obs)) {
    return(data.frame(
      n = 0L, correlation = NA_real_, mae = NA_real_, rmse = NA_real_, bias = NA_real_,
      obs_mean = NA_real_, sim_mean = NA_real_
    ))
  }
  data.frame(
    n = length(obs),
    correlation = if (length(obs) > 1) cor(obs, sim) else NA_real_,
    mae = mean(abs(sim - obs)),
    rmse = sqrt(mean((sim - obs)^2)),
    bias = mean(sim - obs),
    obs_mean = mean(obs),
    sim_mean = mean(sim)
  )
}

con <- dbConnect(SQLite(), db_path)
on.exit(dbDisconnect(con), add = TRUE)

station_lookup <- dbGetQuery(con, "SELECT * FROM sites_in_cg")

wims_stations <- dbGetQuery(
  con,
  "SELECT DISTINCT station_id FROM synoptic_fems_daily_stats WHERE source='Synoptic/FEMS' AND metric_name IN ('gsi','kbdi')"
)$station_id

if (nzchar(station_filter_env)) {
  requested_stations <- unique(trimws(strsplit(station_filter_env, ",", fixed = TRUE)[[1]]))
  requested_stations <- requested_stations[nzchar(requested_stations)]
  wims_stations <- intersect(wims_stations, requested_stations)
}

if (!length(wims_stations)) {
  stop("No WIMS/FEMS stations available after applying validation filters.")
}

cutoff_sql <- ""
if (!is.na(lookback_days) && is.finite(lookback_days) && lookback_days > 0) {
  cutoff_date <- Sys.Date() - lookback_days
  cutoff_sql <- sprintf(
    "AND local_date >= %.0f",
    as.numeric(cutoff_date)
  )
}

temp_stats <- dbGetQuery(
  con,
  sprintf(
    paste(
      "SELECT station_id, local_date, metric_name, value_min, value_max, value_mean",
      "FROM synoptic_fems_daily_stats",
      "WHERE source='Synoptic/FEMS'",
      "AND station_id IN (%s)",
      "AND metric_name IN ('air_temp_set_1.mean','relative_humidity_set_1.mean','gsi','kbdi')",
      "%s"
    ),
    paste(DBI::dbQuoteString(con, wims_stations), collapse = ", "),
    cutoff_sql
  )
) %>%
  mutate(
    station_id = as.character(.data$station_id),
    local_date = as.Date(as.numeric(.data$local_date), origin = "1970-01-01")
  )

observed_gsi <- temp_stats %>%
  filter(.data$metric_name == "gsi") %>%
  transmute(station_id, local_date, observed_gsi = as.numeric(.data$value_mean))

observed_kbdi <- temp_stats %>%
  filter(.data$metric_name == "kbdi") %>%
  transmute(station_id, local_date, observed_kbdi = as.numeric(.data$value_mean))

gsi_inputs <- temp_stats %>%
  filter(.data$metric_name %in% c("air_temp_set_1.mean", "relative_humidity_set_1.mean")) %>%
  select(.data$station_id, .data$local_date, .data$metric_name, .data$value_min, .data$value_max) %>%
  tidyr::pivot_wider(
    names_from = .data$metric_name,
    values_from = c(.data$value_min, .data$value_max)
  )

names(gsi_inputs) <- gsub("\\.", "_", names(gsi_inputs))

precip_daily <- build_synoptic_daily_precip(con, station_ids = wims_stations)

lookup_clean <- station_lookup %>%
  mutate(
    station_id = as.character(.data$station_id),
    station_key = as.character(.data$station_key),
    stid = as.character(.data$stid)
  ) %>%
  transmute(
    station_id = dplyr::coalesce(.data$stid, .data$station_id, .data$station_key),
    latitude = as.numeric(.data$latitude)
  ) %>%
  filter(.data$station_id %in% wims_stations) %>%
  distinct(.data$station_id, .keep_all = TRUE)

station_lookup <- station_lookup %>%
  mutate(
    station_id = as.character(.data$station_id),
    station_key = as.character(.data$station_key),
    stid = as.character(.data$stid)
  ) %>%
  filter(dplyr::coalesce(.data$stid, .data$station_id, .data$station_key) %in% wims_stations)

gsi_compare <- gsi_inputs %>%
  left_join(precip_daily, by = c("station_id", "local_date")) %>%
  left_join(lookup_clean, by = "station_id") %>%
  mutate(
    tmin_f = as.numeric(.data$value_min_air_temp_set_1_mean),
    tmax_f = as.numeric(.data$value_max_air_temp_set_1_mean),
    rh_min = as.numeric(.data$value_min_relative_humidity_set_1_mean),
    vpd_kpa = vpd_kpa_from_temp_rh(.data$tmax_f, .data$rh_min),
    precip_mm = as.numeric(.data$precip_in) * 25.4
  ) %>%
  arrange(.data$station_id, .data$local_date) %>%
  group_by(.data$station_id) %>%
  mutate(
    igsi = compute_gsi_value(.data$tmin_f, .data$vpd_kpa, .data$latitude, .data$local_date, .data$precip_mm, use_precip_limiter = FALSE),
    simulated_gsi = rolling_mean_right(.data$igsi, n = 28L)
  ) %>%
  ungroup() %>%
  left_join(observed_gsi, by = c("station_id", "local_date"))

station_meta <- extract_station_annual_ppt(station_lookup, prism_annual_ppt_path) %>%
  transmute(
    station_id = dplyr::coalesce(.data$stid, .data$station_id, .data$station_key),
    annual_ppt_in = .data$annual_ppt_in
  ) %>%
  filter(.data$station_id %in% wims_stations) %>%
  distinct(.data$station_id, .keep_all = TRUE)

kbdi_inputs <- temp_stats %>%
  filter(.data$metric_name == "air_temp_set_1.mean") %>%
  transmute(
    station_id,
    local_date,
    tmax_f = as.numeric(.data$value_max)
  ) %>%
  left_join(station_meta, by = "station_id") %>%
  left_join(precip_daily, by = c("station_id", "local_date")) %>%
  mutate(precip_in = dplyr::coalesce(.data$precip_in, 0)) %>%
  arrange(.data$station_id, .data$local_date)

kbdi_compare <- kbdi_inputs %>%
  group_by(.data$station_id) %>%
  group_modify(~{
    .x %>%
      mutate(simulated_kbdi = compute_kbdi_series(.data$local_date, .data$tmax_f, .data$precip_in, .data$annual_ppt_in))
  }) %>%
  ungroup() %>%
  left_join(observed_kbdi, by = c("station_id", "local_date"))

overall_summary <- bind_rows(
  cbind(metric = "gsi", metric_stats(gsi_compare$observed_gsi, gsi_compare$simulated_gsi)),
  cbind(metric = "kbdi", metric_stats(kbdi_compare$observed_kbdi, kbdi_compare$simulated_kbdi))
)

station_summary <- bind_rows(
  gsi_compare %>%
    group_by(.data$station_id) %>%
    group_modify(~cbind(metric = "gsi", metric_stats(.x$observed_gsi, .x$simulated_gsi))) %>%
    ungroup(),
  kbdi_compare %>%
    group_by(.data$station_id) %>%
    group_modify(~cbind(metric = "kbdi", metric_stats(.x$observed_kbdi, .x$simulated_kbdi))) %>%
    ungroup()
)

write.csv(overall_summary, file.path(output_dir, "fems_index_validation_overall.csv"), row.names = FALSE)
write.csv(station_summary, file.path(output_dir, "fems_index_validation_by_station.csv"), row.names = FALSE)
write.csv(gsi_compare, file.path(output_dir, "fems_gsi_validation_timeseries.csv"), row.names = FALSE)
write.csv(kbdi_compare, file.path(output_dir, "fems_kbdi_validation_timeseries.csv"), row.names = FALSE)

writeLines(
  jsonlite::toJSON(
    list(
      generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      overall = overall_summary,
      by_station = station_summary
    ),
    pretty = TRUE,
    auto_unbox = TRUE,
    na = "null"
  ),
  file.path(output_dir, "fems_index_validation_summary.json")
)

cat("Overall summary\n")
print(overall_summary, row.names = FALSE)
cat("\nWorst-station snapshot by RMSE\n")
print(
  station_summary %>%
    filter(!is.na(.data$rmse)) %>%
    group_by(.data$metric) %>%
    arrange(desc(.data$rmse), .by_group = TRUE) %>%
    slice_head(n = 8) %>%
    ungroup(),
  row.names = FALSE
)
