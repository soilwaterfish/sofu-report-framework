#!/usr/bin/env Rscript

options(warn = 1)

out_html <- Sys.getenv("SOFU_OUTPUT_HTML", "/output/sofureport.html")
input_rmd <- "/app/report_test.Rmd"
tmp_dir <- Sys.getenv("SOFU_TMP_DIR", "/tmp/sofureport-render")

dir.create(dirname(out_html), recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

cat("Rendering report to:", out_html, "\n")
cat("Using temp/intermediate dir:", tmp_dir, "\n")

rmarkdown::render(
  input = input_rmd,
  output_file = basename(out_html),
  output_dir = dirname(out_html),
  intermediates_dir = tmp_dir,
  knit_root_dir = tmp_dir,
  envir = new.env(parent = globalenv()),
  quiet = FALSE
)

source("/app/build_static_site.R", local = new.env())

cat("Render complete.\n")
