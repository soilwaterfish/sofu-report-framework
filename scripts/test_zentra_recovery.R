#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(DBI); library(RSQLite); library(dplyr); library(data.table)})
source("sofureport/R/utils.R")
source("sofureport/R/zentra.R")
source("sofureport/R/zentra_recovery.R")
make_db <- function() {
  con <- dbConnect(SQLite(), ":memory:")
  dbExecute(con, "CREATE TABLE zentracloud_data(station_id TEXT,date REAL,port_1_atmos_41_f_air_temperature REAL,port_2_teros_11_percent_water_content REAL, UNIQUE(station_id,date))")
  zentra_recovery_schema(con)
  con
}
con <- make_db()
tz <- "America/Denver"
start <- as.numeric(as.POSIXct("2026-11-01 00:00:00", tz = tz))
end <- as.numeric(as.POSIXct("2026-11-02 00:00:00", tz = tz))
now <- as.POSIXct("2026-11-03 12:00:00", tz = tz)
x <- data.frame(station_id = "A", date = seq(start, end - 3600, by = 3600),
  port_1_atmos_41_f_air_temperature = 10, port_2_teros_11_percent_water_content = 7)
stopifnot(nrow(x) == 25L)
dbWriteTable(con, "zentracloud_data", x, append = TRUE)
plan <- zentra_recovery_plan(con, "A", as.Date("2026-11-01"), now + 3*86400)
stopifnot(!"2026-11-01" %in% plan$local_date)
dbExecute(con, "UPDATE zentracloud_data SET port_2_teros_11_percent_water_content=NULL WHERE date=?", params = list(x$date[12]))
plan <- zentra_recovery_plan(con, "A", as.Date("2026-11-01"), now + 3*86400)
stopifnot(plan$missing_sensor_hours[plan$local_date == "2026-11-01"] == 1L)
# Coalescing upserts retain valid prior values and do not duplicate keys.
update <- x[1, ]; update$port_1_atmos_41_f_air_temperature <- 20; update$port_2_teros_11_percent_water_content <- NA_real_
zentra_recovery_commit(con, update, "A", "2026-11-01", as.numeric(now))
zentra_recovery_commit(con, update, "A", "2026-11-01", as.numeric(now))
stopifnot(dbGetQuery(con,"SELECT COUNT(*) AS n FROM zentracloud_data")$n == 25L,
 dbGetQuery(con,"SELECT port_2_teros_11_percent_water_content AS v FROM zentracloud_data ORDER BY date LIMIT 1")$v == 7)
# A checkpoint failure rolls the corresponding raw write back as well.
dbExecute(con,"CREATE TRIGGER reject_checkpoint BEFORE INSERT ON zentra_recovery_state BEGIN SELECT RAISE(ABORT,'simulated checkpoint failure'); END")
update$port_1_atmos_41_f_air_temperature <- 99
failed <- try(zentra_recovery_commit(con, update,"A","2026-11-01",as.numeric(now)),silent=TRUE)
stopifnot(inherits(failed,"try-error"),dbGetQuery(con,"SELECT port_1_atmos_41_f_air_temperature AS v FROM zentracloud_data ORDER BY date LIMIT 1")$v == 20)
dbExecute(con,"DROP TRIGGER reject_checkpoint")
dbDisconnect(con)

con <- make_db(); calls <- 0L; out <- tempfile(); dir.create(out)
bad_token <- function(...) { calls <<- calls + 1L; stop("HTTP 401 Invalid API token") }
failed <- try(run_zentra_recovery(con,c("A","B"),as.Date("2026-11-02"),out,max_chunks=5,now=now,fetch=bad_token),silent=TRUE)
stopifnot(inherits(failed,"try-error"), calls == 1L,
  dbGetQuery(con,"SELECT COUNT(*) AS n FROM zentra_recovery_state WHERE status='error'")$n > 0)
dbDisconnect(con)

con <- make_db(); calls <- 0L
empty <- function(...) { calls <<- calls + 1L; data.frame() }
run_zentra_recovery(con,"A",as.Date("2026-11-02"),out,max_chunks=2,now=now,fetch=empty)
stopifnot(calls == 1L,dbGetQuery(con,"SELECT COUNT(*) AS n FROM zentracloud_data")$n == 0L)
run_zentra_recovery(con,"A",as.Date("2026-11-02"),out,max_chunks=2,now=now+600,fetch=empty)
stopifnot(calls == 1L)
run_zentra_recovery(con,"A",as.Date("2026-11-02"),out,max_chunks=2,now=now+10800,fetch=empty)
stopifnot(calls == 2L)
dbDisconnect(con)

con <- make_db(); calls <- 0L
partial <- function(device_id, start_datetime, end_datetime) {
  calls <<- calls + 1L
  if (calls > 1L) stop("HTTP 503 temporary upstream failure")
  data.frame(station_id=device_id,date=as.numeric(start_datetime),
    port_1_atmos_41_f_air_temperature=12,
    port_2_teros_11_percent_water_content=8)
}
run_zentra_recovery(con,c("A","B"),as.Date("2026-11-02"),out,
  max_chunks=2,now=now,fetch=partial,normalize=function(raw,id) raw)
stopifnot(calls==2L,
  dbGetQuery(con,"SELECT COUNT(*) AS n FROM zentracloud_data")$n==1L,
  dbGetQuery(con,"SELECT COUNT(*) AS n FROM zentra_recovery_state WHERE status='committed' AND daily_dirty=1")$n>0L,
  dbGetQuery(con,"SELECT COUNT(*) AS n FROM zentra_recovery_state WHERE status='error'")$n>0L)
dbDisconnect(con)

raw <- data.frame(timestamp = c(start,start+900,start+3600),port_num=1,
  sensor_name="ATMOS 41 G2",unit="F",measurement="Air Temperature",value=c(10,12,14))
hourly <- zentra_recovery_hourly(raw,"A")
stopifnot(nrow(hourly)==2L,hourly$port_1_atmos_41_f_air_temperature[1]==11)
stamp <- as.POSIXct("2026-11-01 07:00:00",tz="UTC")
dst_endpoints <- as.POSIXct(c("2026-11-01 00:00:00","2026-11-02 23:59:59"),tz=tz)
stopifnot(all(grepl("[+]0000$",vapply(dst_endpoints,zentra_format_datetime,character(1)))))
priority_con <- make_db()
priority <- zentra_recovery_plan(priority_con,"A",as.Date("2026-10-25"),now)
old_days <- as.Date(priority$local_date[!priority$recent])
stopifnot(all(diff(as.numeric(old_days))<=0))
dbDisconnect(priority_con)
# A newest-first history queue must still combine adjacent days, honor bounds,
# and retain an empty window for a later delayed cellular upload.
con <- make_db(); windows <- list(); late <- FALSE
history_now <- as.POSIXct("2026-11-10 12:00:00",tz=tz)
delayed <- function(device_id,start_datetime,end_datetime) {
  windows[[length(windows)+1L]] <<- c(as.numeric(start_datetime),as.numeric(end_datetime))
  if(!late)return(data.frame())
  data.frame(station_id=device_id,
    date=seq(as.numeric(start_datetime),as.numeric(end_datetime),by=3600),
    port_1_atmos_41_f_air_temperature=12,
    port_2_teros_11_percent_water_content=8)
}
run_zentra_recovery(con,"A",as.Date("2026-10-09"),out,max_chunks=4,
  chunk_days=7,now=history_now,fetch=delayed,normalize=function(raw,id)raw,
  end_date=as.Date("2026-11-04"))
stopifnot(length(windows)==4L,
  all(vapply(windows,function(x)diff(x)>=5*86400,logical(1))))
late <- TRUE
run_zentra_recovery(con,"A",as.Date("2026-10-09"),out,max_chunks=4,
  chunk_days=7,now=history_now+2*86400,fetch=delayed,normalize=function(raw,id)raw,
  end_date=as.Date("2026-11-04"))
stored <- dbReadTable(con,"zentracloud_data")
stopifnot(nrow(stored)==27*24+1L,
  min(stored$date)==as.numeric(as.POSIXct("2026-10-09 00:00:00",tz=tz)),
  max(stored$date)==as.numeric(as.POSIXct("2026-11-04 23:00:00",tz=tz)))
dbDisconnect(con)
stopifnot(as.numeric(as.POSIXct(zentra_format_datetime(stamp),format="%Y-%m-%dT%H:%M:%S%z",tz="UTC"))==as.numeric(stamp),
 zentra_sleep_seconds(1,retry_after=900)==900,
 zentra_retry_after_seconds("Tue, 10 Nov 2026 18:00:00 GMT",as.POSIXct("2026-11-10 17:00:00",tz="UTC"))==3600)
cat("PASS: partial sensor gaps, 25-hour DST day, idempotent coalescing upserts, atomic checkpoints, auth fail-fast, empty-response cooldown/retry, hourly normalization, timestamp instants, Retry-After\n")
