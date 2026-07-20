#!/usr/bin/env Rscript

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
assets_dir <- file.path(site_dir, "assets")
dir.create(assets_dir, recursive = TRUE, showWarnings = FALSE)

files <- c(
  "index.html",
  file.path("assets", "styles.css"),
  file.path("assets", "landing.js")
)

for (relative_path in files) {
  source_path <- file.path(source_dir, relative_path)
  target_path <- file.path(site_dir, relative_path)
  if (!file.exists(source_path)) {
    stop("Landing source file is missing: ", source_path, call. = FALSE)
  }
  dir.create(dirname(target_path), recursive = TRUE, showWarnings = FALSE)
  if (!file.copy(source_path, target_path, overwrite = TRUE)) {
    stop("Could not publish landing file: ", relative_path, call. = FALSE)
  }
}

cache_bust <- format(Sys.time(), "%Y%m%d%H%M%S")
index_path <- file.path(site_dir, "index.html")
index_html <- readLines(index_path, warn = FALSE)
index_html <- gsub("assets/styles\\.css(\\?v=[0-9]+)?", paste0("assets/styles.css?v=", cache_bust), index_html)
index_html <- gsub("assets/landing\\.js(\\?v=[0-9]+)?", paste0("assets/landing.js?v=", cache_bust), index_html)
index_html <- gsub("assets/app\\.js(\\?v=[0-9]+)?", paste0("assets/app.js?v=", cache_bust), index_html)
index_html <- gsub("BUILD_VERSION", cache_bust, index_html, fixed = TRUE)
writeLines(index_html, index_path)

message("Published landing page to: ", index_path)
