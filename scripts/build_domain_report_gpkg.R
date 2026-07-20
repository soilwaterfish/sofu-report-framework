#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(sf)
})

domain_service_url <- Sys.getenv(
  "SOFU_DOMAIN_SOURCE_URL",
  "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_Ecomap2025_01/MapServer/1"
)
bbox_path <- Sys.getenv("SOFU_GPKG_PATH", "data/cg_bbox.gpkg")
output_path <- Sys.getenv("SOFU_DOMAIN_GPKG_PATH", "data/domain_report_sf.gpkg")
output_layer <- Sys.getenv("SOFU_DOMAIN_GPKG_LAYER", "domain_report_sf")

query_url <- sprintf(
  "%s/query?where=1%%3D1&outFields=*&f=geojson",
  domain_service_url
)

if (!file.exists(bbox_path)) {
  stop("Bounding box geopackage not found: ", bbox_path)
}

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)

message("Reading project area from: ", bbox_path)
cg_bbox <- sf::st_read(bbox_path, quiet = TRUE)

if (!nrow(cg_bbox)) {
  stop("Bounding box layer is empty: ", bbox_path)
}

cg_bbox <- sf::st_make_valid(cg_bbox)

message("Downloading domain polygons from: ", domain_service_url)
domains <- sf::read_sf(query_url, quiet = TRUE)

if (!nrow(domains)) {
  stop("No domain polygons were returned from the source service.")
}

domains <- sf::st_make_valid(domains)

if (!identical(sf::st_crs(domains), sf::st_crs(cg_bbox))) {
  cg_bbox <- sf::st_transform(cg_bbox, sf::st_crs(domains))
}

message("Intersecting domains with cg_bbox ...")
domains_in_bbox <- domains[lengths(sf::st_intersects(domains, cg_bbox)) > 0, , drop = FALSE]

if (!nrow(domains_in_bbox)) {
  stop("No domain polygons intersected the project bounding geometry.")
}

domains_in_bbox <- sf::st_intersection(domains_in_bbox, sf::st_union(cg_bbox))

if (file.exists(output_path)) {
  file.remove(output_path)
}

message("Writing intersected domains to: ", output_path)
sf::st_write(
  domains_in_bbox,
  output_path,
  layer = output_layer,
  delete_dsn = TRUE,
  quiet = TRUE
)

message("Done. Wrote ", nrow(domains_in_bbox), " intersected domain polygons.")
