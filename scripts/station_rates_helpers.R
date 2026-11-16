# Descriptive rates from canonical SQLite observations, in source units/hour.
station_window_rates <- function(epoch, value, precipitation = FALSE, now = as.numeric(Sys.time())) {
  keys <- c("hours_24", "days_2", "days_7", "days_30")
  rates <- totals <- setNames(as.list(rep(NA_real_, 4)), keys)
  details <- setNames(vector("list", 4), keys)
  valid <- is.finite(epoch) & is.finite(value) & epoch <= now
  if (precipitation) valid <- valid & value >= 0
  epoch <- epoch[valid]; value <- value[valid]
  if (!length(epoch)) return(list(rates = rates, rate_details = details, totals = totals))
  ord <- order(epoch); epoch <- epoch[ord]; value <- value[ord]
  # Canonical hourly records get equal weight, even if a source repeats an hour.
  keep <- !duplicated(floor(epoch / 3600), fromLast = TRUE)
  epoch <- epoch[keep]; value <- value[keep]
  end <- tail(epoch, 1)
  for (i in seq_along(keys)) {
    hours <- c(24, 48, 168, 720)[i]
    idx <- which(epoch >= end - hours * 3600 & epoch <= end)
    if (precipitation) idx <- idx[epoch[idx] > end - hours * 3600]
    n <- length(idx)
    span <- if (n > 1) diff(range(epoch[idx])) / 3600 else 0
    coverage <- min(1, n / (hours + if (precipitation) 0 else 1))
    r2 <- NA_real_
    if (n >= 3 && span >= hours * .8 && coverage >= .8) {
      if (precipitation) {
        totals[[i]] <- sum(value[idx])
        rates[[i]] <- totals[[i]] / hours
      } else {
        x <- (epoch[idx] - end) / 3600; y <- value[idx]
        fit <- lm(y ~ x)
        rates[[i]] <- unname(coef(fit)[2])
        sst <- sum((y - mean(y))^2)
        r2 <- if (sst == 0) 1 else max(0, 1 - sum(residuals(fit)^2) / sst)
      }
    }
    if (!precipitation) {
      nearest <- which.min(abs(epoch - (end - hours * 3600)))
      if (abs(epoch[nearest] - (end - hours * 3600)) <= 3600) {
        totals[[i]] <- tail(value, 1) - value[nearest]
      }
    }
    details[[i]] <- list(samples = n, coverage = coverage, span_hours = span, r_squared = r2)
  }
  list(rates = rates, rate_details = details, totals = totals)
}

build_station_rate_exports <- function(con, sites, output_dir) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  maps <- list(
    Zentra = c(soil_moisture_1 = "port_2_teros_11_percent_water_content",
      soil_moisture_2 = "port_3_teros_11_percent_water_content",
      air_temp = "port_1_atmos_41_f_air_temperature",
      humidity = "port_1_atmos_41_percent_relative_humidity",
      wind_speed = "port_1_atmos_41_mph_wind_speed",
      precip_accum = "port_1_atmos_41_in_precipitation"),
    other = c(soil_moisture_1 = "soil_moisture_set_1.mean",
      soil_moisture_2 = "soil_moisture_set_2.mean", air_temp = "air_temp_set_1.mean",
      humidity = "relative_humidity_set_1.mean", wind_speed = "wind_speed_set_1.mean",
      precip_accum = "precip_accum_one_hour_set_1.mean", gsi = "gsi", kbdi = "kbdi")
  )
  exports <- list()
  now <- as.numeric(Sys.time())
  for (i in seq_len(nrow(sites))) {
    site <- sites[i, , drop = FALSE]
    id <- as.character(site$station_id[[1]])
    zentra <- identical(as.character(site$api[[1]]), "Zentra")
    table <- if (zentra) "zentracloud_data" else "synoptic_fems_data"
    if (!DBI::dbExistsTable(con, table)) next
    mapping <- maps[[if (zentra) "Zentra" else "other"]]
    mapping <- mapping[mapping %in% DBI::dbListFields(con, table)]
    select <- paste(sprintf("%s AS %s", DBI::dbQuoteIdentifier(con, unname(mapping)),
      DBI::dbQuoteIdentifier(con, names(mapping))), collapse = ", ")
    if (!length(mapping)) next
    rows <- DBI::dbGetQuery(con, sprintf(
      "SELECT date, %s FROM %s WHERE station_id = ? AND date >= ? AND date <= ? ORDER BY date",
      select, DBI::dbQuoteIdentifier(con, table)), params = list(id, now - 31 * 86400, now))
    metrics <- list()
    for (key in names(mapping)) {
      valid <- is.finite(rows$date) & is.finite(rows[[key]])
      if (key == "precip_accum") valid <- valid & rows[[key]] >= 0
      if (!any(valid)) next
      last <- tail(which(valid), 1)
      result <- station_window_rates(rows$date, rows[[key]], precipitation = key == "precip_accum", now = now)
      result$latest <- as.numeric(rows[[key]][last])
      result$latest_timestamp <- format_iso_mountain(rows$date[last])
      result$rate_method <- if (key == "precip_accum") "average_accumulation" else "linear_fit"
      metrics[[key]] <- result
    }
    # Format the bounded hourly block together instead of formatting each date
    # repeatedly during JSON construction.
    stamps <- as.POSIXct(rows$date, origin = "1970-01-01", tz = "America/Denver")
    timestamps <- sub("([+-][0-9]{2})([0-9]{2})$", "\\1:\\2",
      format(stamps, "%Y-%m-%dT%H:%M:%S%z", tz = "America/Denver"))
    recent <- lapply(seq_len(nrow(rows)), function(j) {
      point <- list(timestamp = timestamps[j])
      for (key in names(mapping)) point[[key]] <- as.numeric(rows[[key]][j])
      point
    })
    payload <- list(id = id, name = as.character(site$station_name[[1]]),
      api = as.character(site$api[[1]]), generated_at = format_iso_mountain(now),
      metrics = metrics, recent_series = recent)
    path <- file.path(output_dir, paste0(id, ".json"))
    temporary <- tempfile(tmpdir = output_dir, fileext = ".json")
    jsonlite::write_json(payload, temporary, auto_unbox = TRUE, na = "null", digits = 8)
    if (!file.rename(temporary, path)) stop("Could not publish station rates for ", id)
    exports[[id]] <- payload
  }
  exports
}
