#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(DBI); library(RSQLite); library(dplyr); library(data.table)
  library(sf); library(terra)
})
Sys.setenv(TZ = "America/Denver")
args <- commandArgs(trailingOnly = TRUE)
ingest <- "--ingest" %in% args
derive <- "--derive" %in% args
root <- if (dir.exists("/app/sofureport")) "/app" else "."
for (file in sort(list.files(file.path(root,"sofureport/R"), pattern="[.]R$", full.names=TRUE))) source(file)
path <- Sys.getenv("SOFU_DB_PATH", file.path(root, "data/sofu.sqlite"))
out <- file.path(Sys.getenv("SOFU_OUTPUT_DIR", file.path(root,"output")), "zentra-repair")
dir.create(out, recursive=TRUE, showWarnings=FALSE)
if (ingest) {
  secret <- Sys.getenv("SOFU_RENVIRON_PATH", file.path(root,"secrets/.Renviron"))
  if (file.exists(secret)) readRenviron(secret)
}
con <- dbConnect(SQLite(), path, flags=if (ingest || derive) SQLITE_RW else SQLITE_RO)
sites <- dbReadTable(con,"sites_in_cg")
sites <- sites[sites$api=="Zentra",,drop=FALSE]
ids <- as.character(sites$station_id)
requested_ids <- Sys.getenv("SOFU_ZENTRA_REPAIR_STATIONS", "")
if (nzchar(requested_ids)) {
  requested_ids <- trimws(strsplit(requested_ids, ",", fixed=TRUE)[[1]])
  if (any(!requested_ids %in% ids)) stop("Unknown/non-active Zentra station IDs: ",paste(setdiff(requested_ids,ids),collapse=","))
  ids <- intersect(ids,requested_ids)
  sites <- sites[sites$station_id %in% ids,,drop=FALSE]
}
today <- as.Date(format(Sys.time(),tz="America/Denver",usetz=FALSE))
visible <- today - 365L
default_start <- as.Date(sprintf("%d-10-01",as.integer(format(visible,"%Y"))-as.integer(format(visible,"%m-%d")<"10-01")))
start_value <- Sys.getenv("SOFU_ZENTRA_REPAIR_START_DATE", "")
start <- as.Date(if(nzchar(start_value))start_value else as.character(default_start))
if (is.na(start) || start>today) stop("Invalid SOFU_ZENTRA_REPAIR_START_DATE")
end_value <- Sys.getenv("SOFU_ZENTRA_REPAIR_END_DATE", "")
end <- as.Date(if(nzchar(end_value))end_value else as.character(today))
if (is.na(end) || end<start || end>today) stop("Invalid SOFU_ZENTRA_REPAIR_END_DATE")
chunk_days <- as.integer(Sys.getenv("SOFU_ZENTRA_REPAIR_CHUNK_DAYS","2"))
if (is.na(chunk_days) || chunk_days<1L || chunk_days>31L) stop("Invalid SOFU_ZENTRA_REPAIR_CHUNK_DAYS (1-31)")
audit <- function(suffix) {
  plan <- zentra_recovery_plan(con,ids,start,include_deferred=TRUE)
  if(nrow(plan))plan <- plan[as.Date(plan$local_date)<=end,,drop=FALSE]
  write.csv(plan,file.path(out,paste0("missing_days_",suffix,".csv")),row.names=FALSE)
  latest <- dbGetQuery(con,"SELECT station_id,COUNT(*) AS hourly_rows,MAX(date) AS latest_epoch FROM zentracloud_data GROUP BY station_id")
  latest$latest_mountain <- format(as.POSIXct(latest$latest_epoch,origin="1970-01-01",tz="America/Denver"),"%Y-%m-%d %H:%M:%S %Z")
  write.csv(latest,file.path(out,paste0("latest_",suffix,".csv")),row.names=FALSE)
  print(latest[,c("station_id","hourly_rows","latest_mountain")],row.names=FALSE)
  cat("Candidate missing/partial days:",if(nrow(plan))sum(!plan$recent) else 0,"\n")
}
audit("before")
if (ingest) {
  limit <- as.integer(Sys.getenv("SOFU_ZENTRA_MAX_CHUNKS","60"))
  if(is.na(limit)||limit<1)stop("SOFU_ZENTRA_MAX_CHUNKS must be positive")
  run_zentra_recovery(con,ids,start,out,max_chunks=limit,chunk_days=chunk_days,end_date=end)
}
if (derive) {
  # Load existing aggregation definitions without evaluating workflow stages.
  for (expr in parse(file.path(root,"sofureport/dev/workflow_dev.R"))) {
    if(is.call(expr) && identical(expr[[1]],as.name("<-")) && is.call(expr[[3]]) && identical(expr[[3]][[1]],as.name("function"))) eval(expr)
  }
  stamp <- format(Sys.time(),"%Y%m%d-%H%M%S")
  backup_path <- file.path(out,paste0("derived-before-",stamp,".sqlite"))
  backup <- dbConnect(SQLite(),backup_path)
  for(table in c("zentracloud_daily_stats","zentracloud_daily_percentiles")) {
    if(dbExistsTable(con,table))dbWriteTable(backup,table,dbReadTable(con,table))
  }
  dbDisconnect(backup)
  cat("Derived-table recovery backup:",backup_path,"\n")
  # Compute against an isolated snapshot. Publish all affected station products
  # together only after the existing aggregation helpers and QA succeed.
  live_con <- con
  scratch_path <- tempfile(fileext=".sqlite")
  con <- dbConnect(SQLite(),scratch_path)
  for(table in c("zentracloud_data","zentracloud_daily_stats","zentracloud_daily_percentiles")) {
    if(dbExistsTable(live_con,table))dbWriteTable(con,table,dbReadTable(live_con,table))
  }
  first <- dbGetQuery(con,"SELECT MIN(date) AS first FROM zentracloud_data")$first
  days <- as.integer(today-as.Date(as.POSIXct(first,origin="1970-01-01",tz="America/Denver"),tz="America/Denver"))+2L
  refresh_daily_stats_table(con,"zentracloud_data","zentracloud_daily_stats","Zentra",
    metric_cols=zentra_recovery_fields,lookback_days=days,station_ids=ids,force_full_backfill=TRUE)
  geo <- sf::st_as_sf(sites,coords=c("longitude","latitude"),crs=4326,remove=FALSE)
  append_computed_gsi_stats(con,"zentracloud_data","zentracloud_daily_stats","Zentra",
    "port_1_atmos_41_f_air_temperature",geo,rh_col="port_1_atmos_41_percent_relative_humidity",vpd_col="port_1_atmos_41_k_pa_vpd")
  prism <- Sys.getenv("SOFU_PRISM_ANNUAL_PPT_PATH", file.path(dirname(path),"prism_ppt_us_30s_2020_avg_30y/prism_ppt_us_30s_2020_avg_30y.tif"))
  if(!file.exists(prism))stop("PRISM precipitation normals unavailable: ",prism)
  append_computed_kbdi_stats(con,"zentracloud_data","zentracloud_daily_stats","Zentra",
    "port_1_atmos_41_f_air_temperature",geo,prism,precip_mode="zentra")
  refresh_daily_percentiles_table(con,"zentracloud_daily_stats","zentracloud_daily_percentiles","Zentra",
    lookback_days=days,station_ids=ids,force_full_backfill=TRUE)
  duplicate <- dbGetQuery(con,"SELECT COUNT(*) AS n FROM (SELECT station_id,local_date,metric_name,COUNT(*) n FROM zentracloud_daily_stats GROUP BY 1,2,3 HAVING n>1)")$n
  stopifnot(duplicate==0L)
  tables <- c("zentracloud_daily_stats","zentracloud_daily_percentiles")
  for(table in tables) {
    rows <- dbReadTable(con,table)
    rows <- rows[rows$station_id %in% ids,,drop=FALSE]
    dbWriteTable(live_con,paste0(table,"_repair_stage"),rows,temporary=TRUE,overwrite=TRUE)
  }
  station_sql <- paste(dbQuoteString(live_con,ids),collapse=",")
  dbWithTransaction(live_con,{
    for(table in tables) {
      columns <- paste(dbQuoteIdentifier(live_con,dbListFields(live_con,table)),collapse=",")
      dbExecute(live_con,sprintf("DELETE FROM %s WHERE station_id IN (%s)",dbQuoteIdentifier(live_con,table),station_sql))
      dbExecute(live_con,sprintf("INSERT INTO %s (%s) SELECT %s FROM %s",dbQuoteIdentifier(live_con,table),columns,columns,dbQuoteIdentifier(live_con,paste0(table,"_repair_stage"))))
    }
    if(dbExistsTable(live_con,"zentra_recovery_state"))dbExecute(live_con,sprintf("UPDATE zentra_recovery_state SET daily_dirty=0,percentile_dirty=0 WHERE station_id IN (%s)",station_sql))
  })
  dbDisconnect(con)
  con <- live_con
  unlink(scratch_path)
  cat("Existing-observation daily statistics, GSI, KBDI, and percentiles rebuilt.\n")
}
audit("after")
dbDisconnect(con)
if ("--publish" %in% args) {
  status <- system2(file.path(R.home("bin"),"Rscript"),file.path(root,"build_static_site.R"),
    env="SOFU_BUILD_LANDING_INDICES=0")
  if(status != 0L)stop("Static publication failed; raw recovery checkpoints remain available.")
}
