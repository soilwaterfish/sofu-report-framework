#!/usr/bin/env Rscript

options(warn = 1)

log_path <- Sys.getenv("SOFU_LOG_PATH", "/logs/workflow.log")
out_html <- Sys.getenv("SOFU_OUTPUT_HTML", "/output/latest/sofureport.html")
tmp_dir  <- Sys.getenv("SOFU_TMP_DIR", "/tmp/sofureport-render")

dir.create(dirname(log_path), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(out_html), recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

log_con <- file(log_path, open = "a")
sink(log_con, append = TRUE, split = TRUE)
sink(log_con, append = TRUE, type = "message")

skip_report_render <- identical(Sys.getenv("SOFU_SKIP_REPORT_RENDER", "0"), "1")
skip_static_site <- identical(Sys.getenv("SOFU_SKIP_STATIC_SITE", "0"), "1")

cat("\n====================================================\n")
cat("SOFU run started:", as.character(Sys.time()), "\n")
cat("SOFU_DB_PATH:", Sys.getenv("SOFU_DB_PATH"), "\n")
cat("SOFU_GPKG_PATH:", Sys.getenv("SOFU_GPKG_PATH"), "\n")
cat("SOFU_OUTPUT_HTML:", out_html, "\n")
cat("SOFU_TMP_DIR:", tmp_dir, "\n")
cat(
  "Stages:",
  sprintf(
    "ingest=%s daily_stats=%s computed_indices=%s percentiles=%s skip_report_render=%s skip_static_site=%s",
    Sys.getenv("SOFU_STAGE_INGEST", "1"),
    Sys.getenv("SOFU_STAGE_DAILY_STATS", "1"),
    Sys.getenv("SOFU_STAGE_COMPUTED_INDICES", ifelse(identical(Sys.getenv("SOFU_SKIP_COMPUTED_INDICES", "0"), "1"), "0", "1")),
    Sys.getenv("SOFU_STAGE_PERCENTILES", ifelse(identical(Sys.getenv("SOFU_SKIP_PERCENTILES", "0"), "1"), "0", "1")),
    skip_report_render,
    skip_static_site
  ),
  "\n"
)

ok <- FALSE

tryCatch({

  cat("\n--- Running workflow_dev.R ---\n")
  source("/app/sofureport/dev/workflow_dev.R", local = new.env())

  if (skip_report_render) {
    cat("\n--- Skipping report_test.Rmd render (SOFU_SKIP_REPORT_RENDER=1) ---\n")
  } else {
    cat("\n--- Rendering report_test.Rmd ---\n")
    rmarkdown::render(
      input = "/app/report_test.Rmd",
      output_file = basename(out_html),
      output_dir = dirname(out_html),
      intermediates_dir = tmp_dir,
      knit_root_dir = tmp_dir,
      envir = new.env(parent = globalenv()),
      quiet = FALSE
    )
  }

  if (skip_static_site) {
    cat("\n--- Skipping static site build (SOFU_SKIP_STATIC_SITE=1) ---\n")
  } else {
    cat("\n--- Building static site ---\n")
    source("/app/build_static_site.R", local = new.env())
  }

  writeLines(
    paste("Success:", as.character(Sys.time())),
    file.path(dirname(out_html), "workflow_status.txt")
  )

  ok <- TRUE
  cat("\nSOFU run finished successfully:", as.character(Sys.time()), "\n")

}, error = function(e) {
  cat("\nSOFU run failed:", conditionMessage(e), "\n")
  cat("\nTraceback:\n")
  traceback(2)
  writeLines(
    paste("Failed:", as.character(Sys.time()), "-", conditionMessage(e)),
    file.path(dirname(out_html), "workflow_status.txt")
  )
  quit(status = 1)
}, finally = {
  sink(type = "message")
  sink()
  close(log_con)
})

if (!ok) quit(status = 1)
