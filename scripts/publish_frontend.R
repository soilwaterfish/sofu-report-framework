#!/usr/bin/env Rscript

# Publish HTML, CSS, and JavaScript against the existing static JSON payload.
# This is intentionally DB-free for fast frontend iteration.
resolve_dir <- function(candidates) {
  existing <- candidates[dir.exists(candidates)]
  if (!length(existing)) {
    stop("Could not find required directory. Checked: ", paste(candidates, collapse = ", "), call. = FALSE)
  }
  existing[[1]]
}

source_dir <- resolve_dir(c("/app/web", "web"))
output_dir <- Sys.getenv("SOFU_OUTPUT_DIR", "/output")
if (!dir.exists(output_dir)) {
  output_dir <- "output"
}
site_dir <- file.path(output_dir, "latest")
dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)

source_files <- list.files(source_dir, full.names = TRUE, recursive = TRUE, all.files = TRUE, no.. = TRUE)
relative_files <- list.files(source_dir, recursive = TRUE, all.files = TRUE, no.. = TRUE)
target_files <- file.path(site_dir, relative_files)
invisible(lapply(unique(dirname(target_files)), dir.create, recursive = TRUE, showWarnings = FALSE))

if (!all(file.copy(source_files, target_files, overwrite = TRUE))) {
  stop("Could not publish one or more frontend files.", call. = FALSE)
}

cache_bust <- format(Sys.time(), "%Y%m%d%H%M%S")
html_files <- list.files(site_dir, pattern = "\\.html$", full.names = TRUE)
for (html_file in html_files) {
  html <- readLines(html_file, warn = FALSE)
  html <- gsub("assets/styles\\.css(\\?v=[0-9]+)?", paste0("assets/styles.css?v=", cache_bust), html)
  html <- gsub("assets/app\\.js(\\?v=[0-9]+)?", paste0("assets/app.js?v=", cache_bust), html)
  html <- gsub("assets/reports\\.js(\\?v=[0-9]+)?", paste0("assets/reports.js?v=", cache_bust), html)
  html <- gsub("assets/landing\\.js(\\?v=[0-9]+)?", paste0("assets/landing.js?v=", cache_bust), html)
  html <- gsub("assets/plotly\\.min\\.js(\\?v=[0-9]+)?", paste0("assets/plotly.min.js?v=", cache_bust), html)
  html <- gsub("BUILD_VERSION", cache_bust, html, fixed = TRUE)
  writeLines(html, html_file)
}

message("Published frontend only to: ", site_dir)
