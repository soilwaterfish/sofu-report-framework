#!/usr/bin/env Rscript
# Load only pure renderer helpers; do not run the site builder or touch SQLite.
env <- new.env(parent = globalenv())
helpers <- c("safe_numeric", "null_if_na", "timestamp_for_day", "water_year_for_date",
  "build_daily_series", "build_hourly_overlay", "format_timestamp", "format_iso_mountain")
for (expr in parse("build_static_site.R")) {
  if (is.call(expr) && identical(expr[[1]], as.name("<-")) &&
      as.character(expr[[2]])[1] %in% helpers) eval(expr, env)
}
env$dashboard_timezone <- "America/Denver"
env$chart_series_start <- as.Date("2026-09-29")
env$accumulation_start <- as.Date("2025-10-01")
days <- as.Date(c("2025-10-01", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"))
data <- data.frame(local_date = days, metric_name = "precip_accum_one_hour_set_1.mean",
  metric_key = "precip_accum", value_mean = c(5, 1, 2, .1, .2), value_min = 0, value_max = 0, n_obs = 24)
points <- env$build_daily_series(data, "Synoptic/FEMS")
stopifnot(length(points) == 4L,
  abs(points[[1]]$precip_cumulative - 6) < 1e-8,
  abs(points[[2]]$precip_cumulative - 8) < 1e-8,
  abs(points[[3]]$precip_cumulative - .1) < 1e-8,
  abs(points[[4]]$precip_cumulative - .3) < 1e-8)
# Reset even when a station has no October 1 observation.
missing_boundary <- data[data$local_date != as.Date("2026-10-01"), ]
stopifnot(abs(tail(env$build_daily_series(missing_boundary, "Synoptic/FEMS"), 1)[[1]]$precip_cumulative - .2) < 1e-8)
# The same boundary applies to Zentra interval precipitation.
data$metric_name <- "port_1_atmos_41_in_precipitation"
data$metric_key <- "precip_increment"
data$value_mean <- data$value_mean / 24
stopifnot(abs(tail(env$build_daily_series(data, "Zentra"), 1)[[1]]$precip_cumulative - .3) < 1e-8)
hourly <- data.frame(date = as.numeric(as.POSIXct("2026-10-02 00:00:00", tz = "America/Denver")) + (0:2) * 3600,
  soil_moisture_1 = NA_real_, soil_moisture_2 = NA_real_, air_temp = 40,
  humidity = 30, wind_speed = 2, precip_hourly = c(.1, .2, .3),
  precip_accum_wims = c(20, 20.2, 20.5), precip_24h = NA_real_)
overlay <- env$build_hourly_overlay(hourly, "Synoptic/FEMS", prior_cumulative = 1)
stopifnot(abs(tail(overlay, 1)[[1]]$precip_cumulative - 1.6) < 1e-8)
cat("PASS: 365-day hidden water-year baseline, October reset, missing boundary day, Zentra totals, hourly increment accumulation\n")
