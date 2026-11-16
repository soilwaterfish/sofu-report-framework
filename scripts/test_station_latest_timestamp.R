#!/usr/bin/env Rscript
env <- new.env(parent=globalenv())
for (expr in parse("build_static_site.R")) {
  if (is.call(expr) && identical(expr[[1]],as.name("<-")) &&
      identical(expr[[2]],as.name("latest_observation_timestamp"))) eval(expr,env)
}
weather <- list(timestamp="2026-11-16T06:00:00-07:00",air_temp=52,precip_accum=0)
indices <- list(timestamp="2026-11-16T12:00:00-07:00",gsi=0,kbdi=139,precip_cumulative=1.09)
stopifnot(identical(env$latest_observation_timestamp(list(),list(weather,indices)),weather$timestamp))
zero <- list(timestamp="2026-11-16T07:00:00-07:00",precip_accum=0)
stopifnot(identical(env$latest_observation_timestamp(list(),list(weather,zero,indices)),zero$timestamp))
stopifnot(identical(env$latest_observation_timestamp(list(weather),list(indices)),weather$timestamp))
stopifnot(identical(env$latest_observation_timestamp(list(),list(indices)),indices$timestamp))
stopifnot(is.na(env$latest_observation_timestamp(list(),list())))
path <- "output/latest/data/stations/TCTM8.json"
if (file.exists(path)) {
  station <- jsonlite::fromJSON(path,simplifyVector=FALSE)
  recent <- Filter(function(x)identical(x$resolution,"recent"),station$series)
  daily <- Filter(function(x)identical(x$resolution,"daily"),station$series)
  stamp <- env$latest_observation_timestamp(daily,recent)
  cat("Timbercrest observation:",stamp,"; air temperature:",station$latest_dates$air_temp,"\n")
}
cat("PASS: index-only rows excluded, zero rainfall retained, daily/index-only fallbacks, no time shifts\n")
