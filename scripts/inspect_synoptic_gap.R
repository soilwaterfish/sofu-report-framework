#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
})

args <- commandArgs(trailingOnly = TRUE)
station_ids <- strsplit(if (length(args)) args[[1]] else "MBRM8,SGOM8", ",", fixed = TRUE)[[1]]
start_time <- if (length(args) >= 2L) args[[2]] else "2026-06-01 00:00:00"
end_time <- if (length(args) >= 3L) args[[3]] else "2026-07-03 23:59:59"

renviron_path <- Sys.getenv("SOFU_RENVIRON_PATH", "/run/secrets/sofureport_renviron")
if (file.exists(renviron_path)) readRenviron(renviron_path)
token <- Sys.getenv("SYNOPTIC_TOKEN")
if (!nzchar(token)) stop("SYNOPTIC_TOKEN is required.", call. = FALSE)

as_synoptic_time <- function(value) {
  format(as.POSIXct(value, tz = "America/Denver"), "%Y%m%d%H%M", tz = "America/Denver")
}

response <- request("https://api.synopticdata.com/v2/stations/timeseries") %>%
  req_url_query(
    token = token,
    units = "english",
    stid = paste(station_ids, collapse = ","),
    start = as_synoptic_time(start_time),
    end = as_synoptic_time(end_time),
    obtimezone = "local"
  ) %>%
  req_perform()
payload <- resp_body_json(response, simplifyVector = FALSE)

if (!identical(payload$SUMMARY$RESPONSE_CODE, 1L)) {
  stop(payload$SUMMARY$RESPONSE_MESSAGE, call. = FALSE)
}

for (station in payload$STATION) {
  observations <- station$OBSERVATIONS
  timestamps <- unlist(observations$date_time, use.names = FALSE)
  sm1 <- unlist(observations$soil_moisture_set_1, use.names = FALSE)
  sm2 <- unlist(observations$soil_moisture_set_2, use.names = FALSE)
  cat(sprintf(
    "%s: %d rows; %s through %s; SM1=%d; SM2=%d\n",
    station$STID,
    length(timestamps),
    if (length(timestamps)) timestamps[[1]] else "NA",
    if (length(timestamps)) timestamps[[length(timestamps)]] else "NA",
    sum(!is.na(sm1)),
    sum(!is.na(sm2))
  ))
}
