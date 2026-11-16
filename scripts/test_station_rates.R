#!/usr/bin/env Rscript
source("scripts/station_rates_helpers.R")
end <- as.numeric(as.POSIXct("2026-11-10 12:00:00", tz = "UTC"))
epoch <- seq(end - 31 * 86400, end, by = 3600)
hours <- (epoch - epoch[1]) / 3600
linear <- station_window_rates(epoch, 10 + hours * .01, now = end)
stopifnot(all(abs(unlist(linear$rates) - .01) < 1e-10),
  abs(linear$totals$days_30 - 7.2) < 1e-8,
  linear$rate_details$days_30$r_squared > .999)
rain <- station_window_rates(epoch, rep(.01, length(epoch)), precipitation = TRUE, now = end)
stopifnot(abs(rain$totals$hours_24 - .24) < 1e-8,
  abs(rain$totals$days_30 - 7.2) < 1e-8,
  all(abs(unlist(rain$rates) - .01) < 1e-10))
flat <- station_window_rates(epoch, rep(0, length(epoch)), now = end)
stopifnot(all(unlist(flat$rates) == 0), flat$rate_details$hours_24$r_squared == 1)
sparse <- seq(1, length(epoch), by = 3)
gaps <- station_window_rates(epoch[sparse], hours[sparse], now = end)
stopifnot(all(is.na(unlist(gaps$rates))))
missing <- station_window_rates(epoch, rep(NA_real_, length(epoch)), now = end)
stopifnot(all(is.na(unlist(missing$rates))), all(is.na(unlist(missing$totals))))
short <- station_window_rates(tail(epoch, 10), tail(hours, 10), now = end)
stopifnot(all(is.na(unlist(short$rates))), is.na(short$totals$days_30))
# Repeated readings in an hour must not increase coverage or rainfall sums.
duplicates <- station_window_rates(rep(epoch, each = 2), rep(.01, length(epoch) * 2), TRUE, now = end)
stopifnot(abs(duplicates$totals$hours_24 - .24) < 1e-8)
future <- station_window_rates(c(epoch, end + 3600), c(rep(0, length(epoch)), 1000), TRUE, now = end)
stopifnot(future$totals$hours_24 == 0)
negative <- station_window_rates(epoch, rep(-1, length(epoch)), TRUE, now = end)
stopifnot(all(is.na(unlist(negative$rates))))
cat("PASS: fitted slopes, accumulation windows, zero rainfall, missing coverage, short series, duplicate hours, future data, negative precipitation\n")
