#!/usr/bin/env Rscript

db_path <- Sys.getenv("SOFU_DB_PATH", unset = "data/sofu.sqlite")
require_derived_tables <- !identical(Sys.getenv("SOFU_QC_SKIP_DERIVED", "0"), "1")

source("sofureport/R/db_qc.R", local = globalenv())

result <- validate_sofu_database(
  db_path = db_path,
  require_derived_tables = require_derived_tables
)

print(result)

if (!isTRUE(result$ok)) {
  quit(status = 1)
}
