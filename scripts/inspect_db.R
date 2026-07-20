#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(dplyr)
  library(magrittr)
  library(tibble)
})

db_path <- Sys.getenv("SOFU_DB_PATH", unset = "data/sofu.sqlite")
if (!file.exists(db_path)) {
  stop("Database not found: ", db_path, call. = FALSE)
}

source("sofureport/R/db_qc.R", local = globalenv())

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
on.exit(DBI::dbDisconnect(con), add = TRUE)

cat("DB path:", normalizePath(db_path), "\n")
cat("Tables:\n")
print(DBI::dbListTables(con))

show_query <- function(label, sql) {
  cat("\n", label, "\n", sep = "")
  print(DBI::dbGetQuery(con, sql), row.names = FALSE)
}

show_query(
  "Latest raw timestamps",
  paste(
    "SELECT 'synoptic_fems_data' AS table_name, datetime(MAX(date), 'unixepoch') AS max_utc, COUNT(*) AS n_rows FROM synoptic_fems_data",
    "UNION ALL",
    "SELECT 'zentracloud_data' AS table_name, datetime(MAX(date), 'unixepoch') AS max_utc, COUNT(*) AS n_rows FROM zentracloud_data"
  )
)

show_query(
  "Latest daily stats dates",
  paste(
    "SELECT 'synoptic_fems_daily_stats' AS table_name, MAX(local_date) AS max_local_date_num, COUNT(*) AS n_rows FROM synoptic_fems_daily_stats",
    "UNION ALL",
    "SELECT 'zentracloud_daily_stats' AS table_name, MAX(local_date) AS max_local_date_num, COUNT(*) AS n_rows FROM zentracloud_daily_stats"
  )
)

show_query(
  "Sample FEMS site labels",
  "SELECT station_id, station_name, station_label, api, wims_id FROM sites_in_cg WHERE api = 'FEMS' ORDER BY station_id LIMIT 10"
)

result <- validate_sofu_database(db_path = db_path)

cat("\nValidation summary\n")
print(result)

if (nrow(result$stale_stations)) {
  out_dir <- Sys.getenv("SOFU_OUTPUT_DIR", unset = "output")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stale_path <- file.path(out_dir, "stale_stations.csv")
  utils::write.csv(result$stale_stations, stale_path, row.names = FALSE)
  cat("\nWrote stale station report to:", stale_path, "\n")
}
