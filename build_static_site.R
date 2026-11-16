#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(jsonlite)
  library(sf)
})

resolve_first_existing <- function(candidates, dir_ok = FALSE, create_parent = FALSE) {
  for (candidate in candidates) {
    if (dir_ok) {
      if (dir.exists(candidate)) {
        return(candidate)
      }
    } else if (file.exists(candidate)) {
      return(candidate)
    }
  }

  fallback <- candidates[[length(candidates)]]
  if (create_parent) {
    dir.create(dirname(fallback), recursive = TRUE, showWarnings = FALSE)
  }
  fallback
}

station_names <- c(
  "z6-28071" = "Langhor",
  "z6-28073" = "Hebgen",
  "z6-32392" = "W. Bridger Cr",
  "z6-32393" = "Whitetail",
  "z6-32483" = "Bear Palmer"
)

out_html <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_OUTPUT_HTML", unset = NA_character_),
    "/output/latest/sofureport.html",
    "output/latest/sofureport.html"
  )[!is.na(c(
    Sys.getenv("SOFU_OUTPUT_HTML", unset = NA_character_),
    "/output/latest/sofureport.html",
    "output/latest/sofureport.html"
  ))],
  create_parent = TRUE
)
db_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DB_PATH", unset = NA_character_),
    "/data/sofu.sqlite",
    "data/sofu.sqlite"
  )[!is.na(c(
    Sys.getenv("SOFU_DB_PATH", unset = NA_character_),
    "/data/sofu.sqlite",
    "data/sofu.sqlite"
  ))]
)
requested_output <- Sys.getenv("SOFU_OUTPUT_HTML", "")
if (nzchar(requested_output)) out_html <- requested_output
site_dir <- dirname(out_html)
source_dir <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_SITE_SOURCE_DIR", unset = NA_character_),
    "/app/web",
    "web"
  )[!is.na(c(
    Sys.getenv("SOFU_SITE_SOURCE_DIR", unset = NA_character_),
    "/app/web",
    "web"
  ))],
  dir_ok = TRUE
)
data_dir <- file.path(site_dir, "data")
reports_dir <- file.path(site_dir, "reports")
domain_gpkg_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DOMAIN_GPKG_PATH", unset = NA_character_),
    file.path(dirname(db_path), "domain_report_sf.gpkg"),
    "data/domain_report_sf.gpkg"
  )[!is.na(c(
    Sys.getenv("SOFU_DOMAIN_GPKG_PATH", unset = NA_character_),
    file.path(dirname(db_path), "domain_report_sf.gpkg"),
    "data/domain_report_sf.gpkg"
  ))]
)
domain_source_url <- Sys.getenv("SOFU_DOMAIN_SOURCE_URL", "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_Ecomap2025_01/MapServer/1")
bbox_gpkg_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_GPKG_PATH", unset = NA_character_),
    file.path(dirname(db_path), "cg_bbox.gpkg"),
    "data/cg_bbox.gpkg"
  )[!is.na(c(
    Sys.getenv("SOFU_GPKG_PATH", unset = NA_character_),
    file.path(dirname(db_path), "cg_bbox.gpkg"),
    "data/cg_bbox.gpkg"
  ))]
)
domain_fetch_enabled <- identical(Sys.getenv("SOFU_DOMAIN_FETCH", "0"), "1")

dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(reports_dir, recursive = TRUE, showWarnings = FALSE)
stations_data_dir <- file.path(data_dir, "stations")
dir.create(stations_data_dir, recursive = TRUE, showWarnings = FALSE)

if (!dir.exists(source_dir)) {
  stop("Static site source directory not found: ", source_dir)
}

source_files <- list.files(
  source_dir,
  full.names = TRUE,
  recursive = TRUE,
  all.files = TRUE,
  no.. = TRUE
)
relative_files <- list.files(
  source_dir,
  recursive = TRUE,
  all.files = TRUE,
  no.. = TRUE
)
dest_files <- file.path(site_dir, relative_files)

unique_dirs <- unique(dirname(dest_files))
invisible(lapply(unique_dirs, dir.create, recursive = TRUE, showWarnings = FALSE))

copy_ok <- file.copy(
  from = source_files,
  to = dest_files,
  overwrite = TRUE
)

if (!all(copy_ok)) {
  stop("Failed to copy one or more static site assets into: ", site_dir)
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

if (identical(Sys.getenv("SOFU_BUILD_LANDING_INDICES", "0"), "1")) {
  landing_builder <- c("/app/scripts/build_landing_indices.R", "scripts/build_landing_indices.R")
  landing_builder <- landing_builder[file.exists(landing_builder)]
  if (!length(landing_builder)) {
    stop("Could not locate scripts/build_landing_indices.R.")
  }

  message("Building ForDRI and EDDI landing-page assets...")
  status <- system2("Rscript", landing_builder[[1]])
  if (!identical(status, 0L)) {
    warning("Landing index asset build failed; retaining any previously published assets.")
  }
}

if (!file.exists(db_path)) {
  stop("Database path does not exist: ", db_path)
}

dashboard_timezone <- "America/Denver"

format_iso_mountain <- function(value) {
  if (length(value) == 0 || is.na(value)) {
    return(NA_character_)
  }

  stamp <- as.POSIXct(value, origin = "1970-01-01", tz = "UTC")
  local_stamp <- as.POSIXct(format(stamp, tz = dashboard_timezone, usetz = TRUE), tz = dashboard_timezone)
  offset <- format(local_stamp, "%z")
  offset <- sub("([+-][0-9]{2})([0-9]{2})$", "\\1:\\2", offset)

  paste0(format(local_stamp, "%Y-%m-%dT%H:%M:%S"), offset)
}

format_timestamp <- function(value) {
  format_iso_mountain(value)
}

null_if_na <- function(value) {
  if (length(value) == 0 || is.na(value)) {
    return(NA)
  }

  if (is.character(value) && !nzchar(trimws(value))) {
    return(NA)
  }

  unname(value)
}

safe_numeric <- function(value) {
  if (is.null(value) || length(value) == 0 || is.na(value)) {
    return(NA_real_)
  }

  as.numeric(value)
}

html_escape <- function(x) {
  x <- ifelse(is.na(x), "", as.character(x))
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  x
}

slugify <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "-", x)
  x <- gsub("(^-|-$)", "", x)
  ifelse(nzchar(x), x, "report")
}

zone_label_from_column <- function(column_name) {
  label <- gsub("_", " ", as.character(column_name))
  label <- gsub("\\s+", " ", trimws(label))
  label <- tools::toTitleCase(label)
  label <- gsub("\\bAb\\b", "AB", label)
  label <- gsub("\\bUsfs\\b", "USFS", label)
  label
}

zone_slug_from_column <- function(column_name) {
  slugify(zone_label_from_column(column_name))
}

is_truthy_zone_flag <- function(x) {
  if (is.logical(x)) {
    return(!is.na(x) & x)
  }

  if (is.numeric(x)) {
    return(!is.na(x) & x != 0)
  }

  values <- toupper(trimws(as.character(x)))
  !is.na(values) & values %in% c("TRUE", "T", "1", "YES", "Y")
}

format_report_number <- function(value, digits = 2) {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(NA_character_)
  }

  formatC(as.numeric(value), format = "f", digits = digits)
}

compute_cumulative_precip_increments <- function(values) {
  if (!length(values)) {
    return(numeric())
  }

  values <- suppressWarnings(as.numeric(values))
  increments <- rep(NA_real_, length(values))

  for (idx in seq_along(values)) {
    current_value <- values[[idx]]
    if (!is.finite(current_value)) {
      next
    }

    if (idx == 1L) {
      increments[[idx]] <- max(current_value, 0)
      next
    }

    previous_value <- values[[idx - 1L]]
    if (!is.finite(previous_value)) {
      increments[[idx]] <- max(current_value, 0)
    } else if (current_value >= previous_value) {
      increments[[idx]] <- current_value - previous_value
    } else {
      increments[[idx]] <- max(current_value, 0)
    }
  }

  increments[!is.finite(increments) | increments < 0] <- NA_real_
  increments
}

compute_station_precip_windows <- function(raw_rows, api_label, windows_days = c(1, 2, 7, 30)) {
  if (!nrow(raw_rows) || !"date" %in% names(raw_rows)) {
    return(list(latest_timestamp = NA_character_, totals = setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days))))
  }

  raw_rows$date <- suppressWarnings(as.numeric(raw_rows$date))
  raw_rows <- raw_rows[is.finite(raw_rows$date), , drop = FALSE]
  if (!nrow(raw_rows)) {
    return(list(latest_timestamp = NA_character_, totals = setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days))))
  }

  raw_rows <- raw_rows[order(raw_rows$date), , drop = FALSE]
  raw_rows <- raw_rows[!duplicated(raw_rows$date, fromLast = TRUE), , drop = FALSE]

  latest_epoch <- max(raw_rows$date, na.rm = TRUE)
  latest_timestamp <- format_iso_mountain(latest_epoch)
  totals <- setNames(as.list(rep(NA_real_, length(windows_days))), paste0("d", windows_days))

  if (identical(api_label, "Zentra") && "precip_value" %in% names(raw_rows)) {
    precip_values <- suppressWarnings(as.numeric(raw_rows$precip_value))
    for (window_days in windows_days) {
      cutoff <- latest_epoch - window_days * 24 * 60 * 60
      idx <- raw_rows$date > cutoff & raw_rows$date <= latest_epoch
      if (any(idx, na.rm = TRUE)) {
        totals[[paste0("d", window_days)]] <- sum(precip_values[idx], na.rm = TRUE)
      }
    }
  } else if ("precip_cumulative" %in% names(raw_rows)) {
    precip_values <- suppressWarnings(as.numeric(raw_rows$precip_cumulative))
    increments <- compute_cumulative_precip_increments(precip_values)
    for (window_days in windows_days) {
      cutoff <- latest_epoch - window_days * 24 * 60 * 60
      idx <- raw_rows$date > cutoff & raw_rows$date <= latest_epoch
      if (any(idx, na.rm = TRUE)) {
        totals[[paste0("d", window_days)]] <- sum(increments[idx], na.rm = TRUE)
      }
    }
  }

  list(
    latest_timestamp = latest_timestamp,
    totals = totals
  )
}

first_non_missing <- function(row, candidates, default = NA_character_) {
  for (candidate in candidates) {
    if (candidate %in% names(row)) {
      value <- row[[candidate]][[1]]
      if (!is.null(value) && !is.na(value) && nzchar(trimws(as.character(value)))) {
        return(as.character(value))
      }
    }
  }

  default
}

metric_label_map <- c(
  soil_moisture_1 = "Soil Moisture 1",
  soil_moisture_2 = "Soil Moisture 2",
  air_temp = "Air Temperature",
  humidity = "Humidity",
  wind_speed = "Wind Speed",
  precip_accum = "Precip Accum",
  precip_cumulative = "Accumulated Precip",
  gsi = "GSI",
  kbdi = "KBDI"
)

available_metrics_for_station <- function(station) {
  keys <- c("soil_moisture_1", "soil_moisture_2", "air_temp", "humidity", "wind_speed", "precip_accum", "precip_cumulative", "gsi", "kbdi")

  Filter(function(key) {
    latest_value <- station$latest[[key]]
    if (!is.null(latest_value) && !is.na(latest_value)) {
      return(TRUE)
    }

    any(vapply(station$series, function(point) {
      value <- point[[key]]
      !is.null(value) && !is.na(value)
    }, logical(1)))
  }, keys)
}

downsample_series <- function(series) {
  if (!length(series)) {
    return(series)
  }

  timestamps <- as.POSIXct(vapply(series, function(point) point$timestamp, character(1)), tz = "UTC")
  latest_timestamp <- max(timestamps, na.rm = TRUE)
  recent_cutoff <- latest_timestamp - (days_back * 24 * 60 * 60)

  recent_mask <- timestamps >= recent_cutoff
  recent_series <- series[recent_mask]
  older_series <- series[!recent_mask]

  if (!length(older_series)) {
    return(lapply(recent_series, function(point) {
      point$resolution <- "recent"
      point
    }))
  }

  older_days <- as.Date(timestamps[!recent_mask], tz = "UTC")
  older_split <- split(older_series, older_days)
  metric_keys <- c("soil_moisture_1", "soil_moisture_2", "air_temp", "humidity", "wind_speed", "precip_24h", "precip_cumulative")

  older_daily <- lapply(older_split, function(day_points) {
    last_point <- day_points[[length(day_points)]]
    summary_point <- list(
      timestamp = last_point$timestamp,
      resolution = "daily"
    )

    for (metric_key in metric_keys) {
      values <- vapply(day_points, function(point) {
        value <- point[[metric_key]]
        if (is.null(value) || is.na(value)) {
          return(NA_real_)
        }

        as.numeric(value)
      }, numeric(1))

      values <- values[!is.na(values)]

      if (!length(values)) {
        summary_point[[metric_key]] <- NA
        summary_point[[paste0(metric_key, "_min")]] <- NA
        summary_point[[paste0(metric_key, "_max")]] <- NA
        next
      }

      summary_point[[metric_key]] <- mean(values)
      summary_point[[paste0(metric_key, "_min")]] <- min(values)
      summary_point[[paste0(metric_key, "_max")]] <- max(values)
    }

    summary_point
  })

  recent_series <- lapply(recent_series, function(point) {
    point$resolution <- "recent"
    point
  })

  c(unname(older_daily), recent_series)
}

read_domain_layer <- function() {
  domains <- NULL

  if (file.exists(domain_gpkg_path)) {
    domains <- tryCatch(
      sf::st_read(domain_gpkg_path, quiet = TRUE),
      error = function(e) NULL
    )
  }

  if (is.null(domains) && domain_fetch_enabled) {
    domains <- tryCatch(
      sf::read_sf(sprintf("%s/query?where=1%%3D1&outFields=*&f=geojson", domain_source_url), quiet = TRUE),
      error = function(e) NULL
    )
  }

  if (is.null(domains) || !nrow(domains)) {
    return(NULL)
  }

  if (!is.null(sf::st_crs(domains)) && !is.na(sf::st_crs(domains))) {
    domains <- sf::st_make_valid(domains)
  }

  if (file.exists(bbox_gpkg_path)) {
    bbox_layer <- tryCatch(sf::st_read(bbox_gpkg_path, quiet = TRUE), error = function(e) NULL)

    if (!is.null(bbox_layer) && nrow(bbox_layer)) {
      bbox_layer <- sf::st_make_valid(bbox_layer)

      if (!identical(sf::st_crs(domains), sf::st_crs(bbox_layer))) {
        bbox_layer <- sf::st_transform(bbox_layer, sf::st_crs(domains))
      }

      intersects_bbox <- lengths(sf::st_intersects(domains, bbox_layer)) > 0
      domains <- domains[intersects_bbox, , drop = FALSE]
    }
  }

  if (!nrow(domains)) {
    return(NULL)
  }

  domains
}

build_station_points_sf <- function(stations_for_dashboard) {
  station_rows <- lapply(stations_for_dashboard, function(station) {
    lat <- safe_numeric(station$latitude)
    lon <- safe_numeric(station$longitude)

    if (is.na(lat) || is.na(lon)) {
      return(NULL)
    }

    variable_labels <- unname(metric_label_map[station$available_metrics])
    layer_name <- if (identical(station$api, "Zentra")) {
      "Zentra"
    } else if (identical(station$api, "FEMS")) {
      "RAWS"
    } else {
      "Synoptic Soil"
    }

    list(
      station_id = station$id,
      station_name = station$name,
      api = station$api,
      leaflet_layer = layer_name,
      latitude = lat,
      longitude = lon,
      years_of_data = station$years_of_data,
      latest_timestamp = station$latest$timestamp,
      variables = paste(variable_labels[!is.na(variable_labels)], collapse = ", ")
    )
  })

  station_rows <- Filter(Negate(is.null), station_rows)
  if (!length(station_rows)) {
    return(NULL)
  }

  station_df <- do.call(rbind.data.frame, c(station_rows, stringsAsFactors = FALSE))
  sf::st_as_sf(station_df, coords = c("longitude", "latitude"), crs = 4326, remove = FALSE)
}

render_site_shell <- function(title, nav_active, body_class = NULL, body_content, lead_title = "SOFU Report", asset_prefix = "", link_prefix = "") {
  body_attr <- if (!is.null(body_class) && nzchar(body_class)) sprintf(" data-page=\"%s\"", body_class) else ""

  paste0(
    "<!DOCTYPE html><html lang=\"en\"><head>",
    "<meta charset=\"UTF-8\" />",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />",
    "<title>", html_escape(title), "</title>",
    "<link rel=\"stylesheet\" href=\"", asset_prefix, "assets/styles.css?v=", cache_bust, "\" />",
    "</head><body", body_attr, " data-build=\"", cache_bust, "\">",
    "<div class=\"site-shell\">",
    "<nav class=\"topbar compact\">",
    "<a class=\"brand\" href=\"", link_prefix, "index.html\">", html_escape(lead_title), "</a>",
    "<div class=\"topbar-links\">",
    "<a href=\"", link_prefix, "dashboard.html\">Dashboard</a>",
    "<a", if (identical(nav_active, "reports")) " class=\"active\"" else "", " href=\"", link_prefix, "reports.html\">Reports</a>",
    "<a", if (identical(nav_active, "docs")) " class=\"active\"" else "", " href=\"", link_prefix, "docs.html\">Docs</a>",
    "<a", if (identical(nav_active, "about")) " class=\"active\"" else "", " href=\"", link_prefix, "about.html\">About</a>",
    "</div></nav>",
    body_content,
    "</div></body></html>"
  )
}

render_domain_index_html <- function(domain_reports, source_label) {
  if (!length(domain_reports)) {
    body <- paste0(
      "<main class=\"content-grid single-column\">",
      "<section class=\"page-header\">",
      "<p class=\"eyebrow\">Reports</p>",
      "<h1>Ecological domain reports</h1>",
      "<p class=\"lead\">No domain polygons were available for the current build. Add <code>data/domain_report_sf.gpkg</code> or let the build reach the source layer to populate this section.</p>",
      "</section>",
      "<section class=\"info-card\">",
      "<p class=\"section-label\">Expected source</p>",
      "<p>This reports section is wired for a local geopackage first and can later switch to another boundary source without changing the frontend.</p>",
      "</section>",
      "</main>"
    )

    return(render_site_shell("SOFU Reports", "reports", "reports", body))
  }

  source_counts <- Reduce(`+`, lapply(domain_reports, function(report) report$source_counts))
  all_sources <- c("Zentra", "FEMS", "Synoptic")
  source_counts <- setNames(as.integer(source_counts[all_sources]), all_sources)
  source_counts[is.na(source_counts)] <- 0L

  cards_html <- paste(vapply(domain_reports, function(report) {
    paste0(
      "<article class=\"info-card report-card\">",
      "<p class=\"section-label\">", html_escape(report$domain_name), "</p>",
      "<h2>", html_escape(report$division_name), "</h2>",
      "<p class=\"report-meta-line\">", html_escape(report$division_code), " · ", html_escape(report$domain_code), "</p>",
      "<p class=\"report-blurb\">", html_escape(report$summary_sentence), "</p>",
      "<div class=\"report-chip-row\">",
      "<span class=\"report-chip\">", report$station_count, " stations</span>",
      "<span class=\"report-chip\">", report$source_counts[["FEMS"]], " RAWS</span>",
      "<span class=\"report-chip\">", report$source_counts[["Synoptic"]], " Synoptic Soil</span>",
      "<span class=\"report-chip\">", report$source_counts[["Zentra"]], " Zentra</span>",
      "</div>",
      "<a class=\"button button-secondary report-link\" href=\"", html_escape(report$page_path), "\">Open report</a>",
      "</article>"
    )
  }, character(1)), collapse = "")

  body <- paste0(
    "<main class=\"content-grid single-column\">",
    "<section class=\"page-header\">",
    "<p class=\"eyebrow\">Reports</p>",
    "<h1>Ecological domain reports</h1>",
    "<p class=\"lead\">Static domain summaries generated from active station intersections. Current source: ", html_escape(source_label), ".</p>",
    "</section>",
    "<section class=\"panel\">",
    "<div class=\"metric-grid\">",
    "<article class=\"metric-card\"><span>Report areas</span><strong>", length(domain_reports), "</strong><span>Ecological divisions intersecting the project area</span></article>",
    "<article class=\"metric-card\"><span>Matched stations</span><strong>", sum(vapply(domain_reports, function(report) report$station_count, integer(1))), "</strong><span>Active dashboard stations linked to a report area</span></article>",
    "<article class=\"metric-card\"><span>RAWS</span><strong>", source_counts[["FEMS"]], "</strong><span>WIMS-backed FEMS stations in current reports</span></article>",
    "<article class=\"metric-card\"><span>Synoptic Soil</span><strong>", source_counts[["Synoptic"]], "</strong><span>Synoptic stations with soil data in current reports</span></article>",
    "<article class=\"metric-card\"><span>Zentra</span><strong>", source_counts[["Zentra"]], "</strong><span>Zentra stations intersecting report areas</span></article>",
    "</div>",
    "</section>",
    "<section class=\"report-grid\">", cards_html, "</section>",
    "</main>"
  )

  render_site_shell("SOFU Reports", "reports", "reports", body)
}

render_domain_page_html <- function(report) {
  station_rows <- if (nrow(report$stations)) {
    paste(vapply(seq_len(nrow(report$stations)), function(i) {
      station <- report$stations[i, , drop = FALSE]
      latest_label <- if (!is.na(station$latest_timestamp[[1]]) && nzchar(station$latest_timestamp[[1]])) {
        formatTimestamp <- station$latest_timestamp[[1]]
        html_escape(formatTimestamp)
      } else {
        "Unavailable"
      }

      paste0(
        "<tr>",
        "<td>", html_escape(station$station_name[[1]]), "</td>",
        "<td>", html_escape(station$station_id[[1]]), "</td>",
        "<td>", html_escape(station$api[[1]]), "</td>",
        "<td>", ifelse(is.na(station$years_of_data[[1]]), "N/A", as.character(station$years_of_data[[1]])), "</td>",
        "<td>", latest_label, "</td>",
        "<td>", html_escape(station$variables[[1]]), "</td>",
        "</tr>"
      )
    }, character(1)), collapse = "")
  } else {
    "<tr><td colspan=\"6\">No active dashboard stations intersected this report area in the current build.</td></tr>"
  }

  body <- paste0(
    "<main class=\"content-grid single-column\">",
    "<section class=\"page-header\">",
    "<p class=\"eyebrow\">", html_escape(report$domain_name), "</p>",
    "<h1>", html_escape(report$division_name), "</h1>",
    "<p class=\"lead\">", html_escape(report$summary_sentence), "</p>",
    "<div class=\"hero-actions\">",
    "<a class=\"button button-secondary\" href=\"../reports.html\">Back to reports</a>",
    "<a class=\"button button-secondary\" href=\"../dashboard.html\">Open dashboard</a>",
    "</div>",
    "</section>",
    "<section class=\"panel\">",
    "<div class=\"metric-grid\">",
    "<article class=\"metric-card\"><span>Division code</span><strong>", html_escape(report$division_code), "</strong><span>Ecological division identifier</span></article>",
    "<article class=\"metric-card\"><span>Domain code</span><strong>", html_escape(report$domain_code), "</strong><span>Broader ecological domain context</span></article>",
    "<article class=\"metric-card\"><span>Active stations</span><strong>", report$station_count, "</strong><span>Stations with data intersecting this area</span></article>",
    "<article class=\"metric-card\"><span>RAWS</span><strong>", report$source_counts[["FEMS"]], "</strong><span>WIMS-backed stations in this area</span></article>",
    "<article class=\"metric-card\"><span>Synoptic Soil</span><strong>", report$source_counts[["Synoptic"]], "</strong><span>Synoptic soil stations in this area</span></article>",
    "<article class=\"metric-card\"><span>Zentra</span><strong>", report$source_counts[["Zentra"]], "</strong><span>Zentra stations in this area</span></article>",
    "</div>",
    "</section>",
    "<section class=\"panel\">",
    "<div class=\"panel-top\">",
    "<div><p class=\"panel-label\">Station roster</p><h2>Active stations in this report area</h2></div>",
    "<p class=\"panel-note\">This first version stays intentionally compact: intersected stations, source mix, and variable coverage.</p>",
    "</div>",
    "<div class=\"report-table-wrap\"><table class=\"report-table\"><thead><tr><th>Station</th><th>ID</th><th>Source</th><th>Years</th><th>Latest update</th><th>Variables</th></tr></thead><tbody>",
    station_rows,
    "</tbody></table></div>",
    "</section>",
    "</main>"
  )

  render_site_shell(
    title = paste0("SOFU Report - ", report$division_name),
    nav_active = "reports",
    body_class = "reports",
    body_content = body,
    asset_prefix = "../",
    link_prefix = "../"
  )
}

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)

sites_lookup <- data.frame()

if (DBI::dbExistsTable(con, "sites_in_cg")) {
  sites_lookup <- DBI::dbReadTable(con, "sites_in_cg")
}

station_record_years <- list(
  Zentra = c(),
  `Synoptic/FEMS` = c()
)

days_back <- 30
local_timezone <- "America/Denver"
local_timezone <- dashboard_timezone
local_today <- as.Date(format(Sys.time(), tz = local_timezone, usetz = FALSE), tz = local_timezone)
# The dashboard series and accumulated precipitation both start on the current
# water-year boundary. After October 1, that boundary belongs to this calendar
# year; before October it belongs to the prior calendar year.
water_year_start <- as.Date(sprintf(
  "%d-10-01",
  ifelse(
    as.integer(format(local_today, "%m")) >= 10L,
    as.integer(format(local_today, "%Y")),
    as.integer(format(local_today, "%Y")) - 1L
  )
))
today_start_epoch <- as.numeric(as.POSIXct(
  paste(local_today, "00:00:00"),
  tz = local_timezone
))
water_year_start_numeric <- as.numeric(water_year_start)
chart_series_start <- local_today - 365L
accumulation_start <- as.Date(sprintf("%d-10-01",
  as.integer(format(chart_series_start, "%Y")) - as.integer(format(chart_series_start, "%m-%d") < "10-01")))
stats_query_start_numeric <- as.numeric(accumulation_start) - 1L

stats_metric_maps <- list(
  `Zentra` = c(
    `port_2_teros_11_percent_water_content` = "soil_moisture_1",
    `port_3_teros_11_percent_water_content` = "soil_moisture_2",
    `port_1_atmos_41_f_air_temperature` = "air_temp",
    `port_1_atmos_41_percent_relative_humidity` = "humidity",
    `port_1_atmos_41_mph_wind_speed` = "wind_speed",
    `port_1_atmos_41_in_precipitation` = "precip_increment",
    `gsi` = "gsi",
    `kbdi` = "kbdi"
  ),
  `Synoptic/FEMS` = c(
    `air_temp_set_1.mean` = "air_temp",
    `relative_humidity_set_1.mean` = "humidity",
    `wind_speed_set_1.mean` = "wind_speed",
    `precip_accum_one_hour_set_1.mean` = "precip_accum",
    `precip_accum_set_1.mean` = "precip_accum",
    `precip_accum_24_hour_set_1.mean` = "precip_accum",
    `soil_moisture_set_1.mean` = "soil_moisture_1",
    `soil_moisture_set_2.mean` = "soil_moisture_2",
    `gsi` = "gsi",
    `kbdi` = "kbdi"
  )
)

percentile_table_map <- c(
  `Zentra` = "zentracloud_daily_percentiles",
  `Synoptic/FEMS` = "synoptic_fems_daily_percentiles"
)

read_station_record_years <- function(stats_table) {
  if (!DBI::dbExistsTable(con, stats_table)) {
    return(c())
  }

  years_df <- DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT station_id,",
        "COUNT(DISTINCT strftime('%%Y', CAST(local_date AS INTEGER) * 86400, 'unixepoch')) AS years_of_data",
        "FROM %s",
        "GROUP BY station_id"
      ),
      stats_table
    )
  )

  if (!nrow(years_df)) {
    return(c())
  }

  setNames(as.numeric(years_df$years_of_data), as.character(years_df$station_id))
}

read_stats_export <- function(stats_table, metric_map, api_label) {
  if (!DBI::dbExistsTable(con, stats_table)) {
    return(data.frame())
  }

  metric_names <- names(metric_map)
  metric_sql <- paste(DBI::dbQuoteString(con, metric_names), collapse = ", ")
  stats_query <- sprintf(
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "local_date,",
      "metric_name,",
      "value_min,",
      "value_max,",
      "value_mean,",
      "n_obs,",
      "is_complete_day",
      "FROM %s",
      "WHERE local_date >= %s",
      "AND local_date < %s",
      "AND metric_name IN (%s)",
      "ORDER BY station_id, local_date, metric_name"
    ),
    stats_table,
    stats_query_start_numeric,
    as.numeric(local_today),
    metric_sql
  )

  stats_df <- DBI::dbGetQuery(con, stats_query)

  if (!nrow(stats_df)) {
    return(data.frame())
  }

  stats_df$station_id <- as.character(stats_df$station_id)
  stats_df$local_date <- as.Date(as.numeric(stats_df$local_date), origin = "1970-01-01")
  stats_df$metric_key <- unname(metric_map[stats_df$metric_name])
  stats_df <- stats_df[!is.na(stats_df$metric_key) & nzchar(stats_df$metric_key), , drop = FALSE]

  if (identical(api_label, "Synoptic/FEMS")) {
    # FEMS hourly_precip is an increment. Prefer it where available; retain
    # cumulative/24-hour fields only as fallbacks for stations without it.
    stats_df$metric_priority <- ifelse(
      stats_df$metric_name == "precip_accum_one_hour_set_1.mean", 1L,
      ifelse(stats_df$metric_name == "precip_accum_set_1.mean", 2L, 3L)
    )
    stats_df <- stats_df[order(stats_df$station_id, stats_df$local_date, stats_df$metric_key, stats_df$metric_priority), , drop = FALSE]
    stats_df <- stats_df[!duplicated(stats_df[c("station_id", "local_date", "metric_key")]), , drop = FALSE]
    stats_df$metric_priority <- NULL
  }

  stats_df$api <- api_label
  stats_df
}

read_hourly_overlay <- function(raw_table, metric_sql, api_label, extra_where = NULL) {
  if (!DBI::dbExistsTable(con, raw_table)) {
    return(data.frame())
  }

  where_clause <- sprintf("WHERE date >= %s", today_start_epoch)
  if (!is.null(extra_where) && nzchar(extra_where)) {
    where_clause <- paste(where_clause, extra_where)
  }

  overlay_query <- sprintf(
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id, date, %s",
      "FROM %s",
      "%s",
      "ORDER BY station_id, date"
    ),
    metric_sql,
    raw_table,
    where_clause
  )

  hourly_df <- DBI::dbGetQuery(con, overlay_query)

  if (!nrow(hourly_df)) {
    return(data.frame())
  }

  hourly_df$station_id <- as.character(hourly_df$station_id)
  hourly_df$api <- api_label
  hourly_df
}

zentra_stats <- read_stats_export(
  stats_table = "zentracloud_daily_stats",
  metric_map = stats_metric_maps[["Zentra"]],
  api_label = "Zentra"
)

synoptic_stats <- read_stats_export(
  stats_table = "synoptic_fems_daily_stats",
  metric_map = stats_metric_maps[["Synoptic/FEMS"]],
  api_label = "Synoptic/FEMS"
)

station_record_years$Zentra <- read_station_record_years("zentracloud_daily_stats")
station_record_years[["Synoptic/FEMS"]] <- read_station_record_years("synoptic_fems_daily_stats")

zentra_hourly <- read_hourly_overlay(
  raw_table = "zentracloud_data",
  metric_sql = paste(
    "port_2_teros_11_percent_water_content AS soil_moisture_1,",
    "port_3_teros_11_percent_water_content AS soil_moisture_2,",
    "port_1_atmos_41_f_air_temperature AS air_temp,",
    "port_1_atmos_41_percent_relative_humidity AS humidity,",
    "port_1_atmos_41_mph_wind_speed AS wind_speed,",
    "port_1_atmos_41_in_precipitation AS precip_increment"
  ),
  api_label = "Zentra"
)

synoptic_hourly <- read_hourly_overlay(
  raw_table = "synoptic_fems_data",
  metric_sql = paste(
    "\"air_temp_set_1.mean\" AS air_temp,",
    "\"relative_humidity_set_1.mean\" AS humidity,",
    "\"wind_speed_set_1.mean\" AS wind_speed,",
    "\"precip_accum_set_1.mean\" AS precip_accum_wims,",
    "\"precip_accum_24_hour_set_1.mean\" AS precip_24h,",
    "\"precip_accum_one_hour_set_1.mean\" AS precip_hourly,",
    "\"soil_moisture_set_1.mean\" AS soil_moisture_1,",
    "\"soil_moisture_set_2.mean\" AS soil_moisture_2,",
    "gsi,",
    "kbdi,",
    "WIMS_ID AS wims_id"
  ),
  api_label = "Synoptic/FEMS",
  extra_where = paste(
    "AND station_id IS NOT NULL AND TRIM(CAST(station_id AS TEXT)) != ''",
    "AND (",
    "(WIMS_ID IS NOT NULL AND TRIM(CAST(WIMS_ID AS TEXT)) != '')",
    "OR \"soil_moisture_set_1.mean\" IS NOT NULL",
    "OR \"soil_moisture_set_2.mean\" IS NOT NULL",
    ")"
  )
)

synoptic_station_lookup <- if (DBI::dbExistsTable(con, "synoptic_fems_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "CAST(WIMS_ID AS TEXT) AS wims_id",
      "FROM synoptic_fems_data",
      "WHERE station_id IS NOT NULL",
      "AND TRIM(CAST(station_id AS TEXT)) != ''",
      "AND (",
      "(WIMS_ID IS NOT NULL AND TRIM(CAST(WIMS_ID AS TEXT)) != '')",
      "OR \"soil_moisture_set_1.mean\" IS NOT NULL",
      "OR \"soil_moisture_set_2.mean\" IS NOT NULL",
      ")",
      "GROUP BY station_id, WIMS_ID"
    )
  )
} else {
  data.frame()
}

if (!nrow(zentra_stats) && !nrow(synoptic_stats)) {
  stop("No dashboard stats were found since ", as.character(water_year_start), ".")
}

site_row_for_station <- function(station_id, wims_id = NULL) {
  if (!nrow(sites_lookup)) {
    return(NULL)
  }

  first_match <- function(column_name, value) {
    if (!column_name %in% names(sites_lookup) || is.null(value) || length(value) == 0 || is.na(value) || !nzchar(trimws(as.character(value)))) {
      return(NULL)
    }

    column_values <- as.character(sites_lookup[[column_name]])
    match_idx <- which(!is.na(column_values) & column_values == as.character(value))

    if (!length(match_idx)) {
      return(NULL)
    }

    sites_lookup[match_idx[[1]], , drop = FALSE]
  }

  has_wims_id <- !is.null(wims_id) && length(wims_id) > 0 && !is.na(wims_id) && nzchar(trimws(as.character(wims_id)))

  if (has_wims_id) {
    match_row <- first_match("station_key", wims_id)
    if (!is.null(match_row)) {
      return(match_row)
    }
  }

  if (has_wims_id) {
    match_row <- first_match("wims_id", wims_id)
    if (!is.null(match_row)) {
      return(match_row)
    }
  }

  match_row <- first_match("station_key", station_id)
  if (!is.null(match_row)) {
    return(match_row)
  }

  match_row <- first_match("stid", station_id)
  if (!is.null(match_row)) {
    return(match_row)
  }

  match_row <- first_match("station_id", station_id)
  if (!is.null(match_row)) {
    return(match_row)
  }

  NULL
}

build_station_meta <- function(station_id, fallback_name = NULL, fallback_api = NULL, wims_id = NULL) {
  site_row <- site_row_for_station(station_id, wims_id = wims_id)

  site_station_name <- if (!is.null(site_row) && "station_name" %in% names(site_row) && !is.na(site_row$station_name[[1]]) && nzchar(as.character(site_row$station_name[[1]]))) {
    site_row$station_name[[1]]
  } else {
    NULL
  }

  name <- if (!is.null(site_station_name)) {
    site_station_name
  } else if (!is.null(site_row) && "station_label" %in% names(site_row) && !is.na(site_row$station_label[[1]]) && nzchar(as.character(site_row$station_label[[1]]))) {
    site_row$station_label[[1]]
  } else if (!is.null(fallback_name) && !is.na(fallback_name) && nzchar(fallback_name)) {
    fallback_name
  } else if (station_id %in% names(station_names)) {
    station_names[[station_id]]
  } else {
    station_id
  }

  list(
    id = station_id,
    name = name,
    api = if (!is.null(site_row) && "api" %in% names(site_row) && !is.na(site_row$api[[1]]) && nzchar(as.character(site_row$api[[1]]))) null_if_na(site_row$api[[1]]) else fallback_api,
    latitude = if (!is.null(site_row) && "latitude" %in% names(site_row)) null_if_na(site_row$latitude[[1]]) else NULL,
    longitude = if (!is.null(site_row) && "longitude" %in% names(site_row)) null_if_na(site_row$longitude[[1]]) else NULL,
    geometry_wkt = if (!is.null(site_row) && "geometry_wkt" %in% names(site_row)) null_if_na(site_row$geometry_wkt[[1]]) else NULL
  )
}

timestamp_for_day <- function(day_value) {
  local_noon <- as.POSIXct(
    paste(as.character(day_value), "12:00:00"),
    tz = dashboard_timezone
  )
  offset <- format(local_noon, "%z")
  offset <- sub("([+-][0-9]{2})([0-9]{2})$", "\\1:\\2", offset)
  paste0(format(local_noon, "%Y-%m-%dT%H:%M:%S"), offset)
}

build_daily_series <- function(station_stats, api_label) {
  if (!nrow(station_stats)) {
    return(list())
  }

  station_stats <- station_stats[order(station_stats$local_date, station_stats$metric_key), , drop = FALSE]
  day_keys <- sort(unique(station_stats$local_date))
  daily_points <- vector("list", length(day_keys))
  names(daily_points) <- as.character(day_keys)
  running_precip <- 0
  previous_synoptic_cumulative <- NA_real_
  previous_water_year <- NA_integer_

  for (i in seq_along(day_keys)) {
    day_value <- day_keys[[i]]
    current_water_year <- water_year_for_date(day_value)
    if (is.na(previous_water_year) || current_water_year != previous_water_year) running_precip <- 0
    previous_water_year <- current_water_year
    day_rows <- station_stats[station_stats$local_date == day_value, , drop = FALSE]
    if (day_value < accumulation_start) {
      baseline <- day_rows[day_rows$metric_name == "precip_accum_set_1.mean", , drop = FALSE]
      if (nrow(baseline)) previous_synoptic_cumulative <- safe_numeric(baseline$value_max[[1]])
      next
    }

    point <- list(
      timestamp = timestamp_for_day(day_value),
      resolution = "daily"
    )

    for (j in seq_len(nrow(day_rows))) {
      metric_key <- day_rows$metric_key[[j]]
      if (api_label == "Synoptic/FEMS" && identical(metric_key, "precip_accum")) {
        next
      }

      point[[metric_key]] <- null_if_na(day_rows$value_mean[[j]])
      point[[paste0(metric_key, "_min")]] <- null_if_na(day_rows$value_min[[j]])
      point[[paste0(metric_key, "_max")]] <- null_if_na(day_rows$value_max[[j]])
    }

    if (api_label == "Synoptic/FEMS" && any(day_rows$metric_key %in% "precip_accum", na.rm = TRUE)) {
      precip_row <- day_rows[day_rows$metric_key == "precip_accum", , drop = FALSE][1, , drop = FALSE]
      source_metric <- precip_row$metric_name[[1]]
      raw_min <- safe_numeric(precip_row$value_min[[1]])
      raw_max <- safe_numeric(precip_row$value_max[[1]])
      daily_total <- NA_real_

      if (identical(source_metric, "precip_accum_set_1.mean")) {
        if (!is.na(raw_max)) {
          if (is.na(previous_synoptic_cumulative)) {
            if (!is.na(raw_min)) {
              daily_total <- max(raw_max - raw_min, 0)
            } else {
              daily_total <- 0
            }
          } else if (raw_max >= previous_synoptic_cumulative) {
            daily_total <- raw_max - previous_synoptic_cumulative
          } else {
            daily_total <- raw_max
          }

          previous_synoptic_cumulative <- raw_max
        }
      } else if (identical(source_metric, "precip_accum_one_hour_set_1.mean")) {
        daily_total <- safe_numeric(precip_row$value_mean[[1]])
      } else {
        daily_total <- raw_max
      }

      point$precip_accum <- null_if_na(daily_total)
      point$precip_accum_min <- null_if_na(daily_total)
      point$precip_accum_max <- null_if_na(daily_total)

      running_precip <- running_precip + ifelse(is.na(daily_total), 0, daily_total)
      point$precip_cumulative <- if (is.na(daily_total) && running_precip == 0) NA else running_precip
    }

    if (api_label == "Zentra" && any(day_rows$metric_key %in% "precip_increment", na.rm = TRUE)) {
      precip_row <- day_rows[day_rows$metric_key == "precip_increment", , drop = FALSE][1, , drop = FALSE]
      daily_total <- safe_numeric(precip_row$value_mean[[1]]) * safe_numeric(precip_row$n_obs[[1]])
      running_precip <- running_precip + ifelse(is.na(daily_total), 0, daily_total)
      point$precip_cumulative <- if (is.na(daily_total) && running_precip == 0) NA else running_precip
    }

    daily_points[[i]] <- point
  }

  unname(Filter(function(point) !is.null(point) && as.Date(substr(point$timestamp, 1, 10)) >= chart_series_start, daily_points))
}

get_station_percentiles <- function(station_id, latest_local_date, api_label, metric_map, latest_daily_point = NULL) {
  if (is.null(latest_local_date) || length(latest_local_date) == 0 || is.na(latest_local_date)) {
    return(list())
  }

  percentiles_table <- percentile_table_map[[api_label]]
  if (is.null(percentiles_table) || !DBI::dbExistsTable(con, percentiles_table)) {
    return(list())
  }

  metric_names <- names(metric_map)
  metric_sql <- paste(DBI::dbQuoteString(con, metric_names), collapse = ", ")
  doy_key <- format(latest_local_date, "%m-%d")

  percentile_query <- sprintf(
    paste(
      "SELECT metric_name, stat_type, n_years,",
      "p05, p10, p25, p50, p75, p90, p95",
      "FROM %s",
      "WHERE station_id = %s",
      "AND day_of_year_key = %s",
      "AND metric_name IN (%s)"
    ),
    percentiles_table,
    DBI::dbQuoteString(con, station_id),
    DBI::dbQuoteString(con, doy_key),
    metric_sql
  )

  percentile_rows <- DBI::dbGetQuery(con, percentile_query)

  if (!nrow(percentile_rows)) {
    return(list())
  }

  percentiles <- list()

  for (i in seq_len(nrow(percentile_rows))) {
    row <- percentile_rows[i, , drop = FALSE]
    metric_key <- unname(metric_map[[row$metric_name[[1]]]])
    stat_type <- row$stat_type[[1]]
    current_value <- NA_real_

    if (!is.null(latest_daily_point)) {
      if (stat_type == "value_mean") {
        current_value <- safe_numeric(latest_daily_point[[metric_key]])
      } else if (stat_type == "value_min") {
        current_value <- safe_numeric(latest_daily_point[[paste0(metric_key, "_min")]])
      } else if (stat_type == "value_max") {
        current_value <- safe_numeric(latest_daily_point[[paste0(metric_key, "_max")]])
      }
    }

    if (is.null(percentiles[[metric_key]])) {
      percentiles[[metric_key]] <- list(
        local_date = as.character(latest_local_date),
        day_of_year_key = doy_key,
        n_years = null_if_na(row$n_years[[1]])
      )
    }

    percentiles[[metric_key]][[stat_type]] <- list(
      current = null_if_na(current_value),
      p05 = null_if_na(row$p05[[1]]),
      p10 = null_if_na(row$p10[[1]]),
      p25 = null_if_na(row$p25[[1]]),
      p50 = null_if_na(row$p50[[1]]),
      p75 = null_if_na(row$p75[[1]]),
      p90 = null_if_na(row$p90[[1]]),
      p95 = null_if_na(row$p95[[1]])
    )
  }

  percentiles
}

get_station_percentile_series <- function(station_id, daily_series, api_label, metric_map) {
  if (!length(daily_series)) {
    return(list())
  }

  percentiles_table <- percentile_table_map[[api_label]]
  if (is.null(percentiles_table) || !DBI::dbExistsTable(con, percentiles_table)) {
    return(list())
  }

  daily_dates <- as.Date(vapply(daily_series, function(point) substr(point$timestamp, 1, 10), character(1)))
  doy_keys <- unique(format(daily_dates, "%m-%d"))
  metric_names <- names(metric_map)

  if (!length(doy_keys) || !length(metric_names)) {
    return(list())
  }

  doy_sql <- paste(DBI::dbQuoteString(con, doy_keys), collapse = ", ")
  metric_sql <- paste(DBI::dbQuoteString(con, metric_names), collapse = ", ")

  percentile_query <- sprintf(
    paste(
      "SELECT metric_name, day_of_year_key, stat_type, n_years,",
      "p05, p10, p25, p50, p75, p90, p95",
      "FROM %s",
      "WHERE station_id = %s",
      "AND metric_name IN (%s)",
      "AND day_of_year_key IN (%s)",
      "AND stat_type = 'value_mean'"
    ),
    percentiles_table,
    DBI::dbQuoteString(con, station_id),
    metric_sql,
    doy_sql
  )

  percentile_rows <- DBI::dbGetQuery(con, percentile_query)
  if (!nrow(percentile_rows)) {
    return(list())
  }

  rows_by_metric_doy <- split(
    percentile_rows,
    paste(percentile_rows$metric_name, percentile_rows$day_of_year_key, sep = "||")
  )

  percentile_series <- list()

  for (metric_name in metric_names) {
    metric_key <- unname(metric_map[[metric_name]])
    metric_points <- list()

    for (idx in seq_along(daily_series)) {
      point <- daily_series[[idx]]
      doy_key <- format(as.Date(substr(point$timestamp, 1, 10)), "%m-%d")
      lookup_key <- paste(metric_name, doy_key, sep = "||")
      row <- rows_by_metric_doy[[lookup_key]]

      if (is.null(row) || !nrow(row)) {
        next
      }

      metric_points[[length(metric_points) + 1L]] <- list(
        timestamp = point$timestamp,
        n_years = null_if_na(row$n_years[[1]]),
        p05 = null_if_na(row$p05[[1]]),
        p10 = null_if_na(row$p10[[1]]),
        p25 = null_if_na(row$p25[[1]]),
        p50 = null_if_na(row$p50[[1]]),
        p75 = null_if_na(row$p75[[1]]),
        p90 = null_if_na(row$p90[[1]]),
        p95 = null_if_na(row$p95[[1]])
      )
    }

    if (length(metric_points)) {
      percentile_series[[metric_key]] <- metric_points
    }
  }

  percentile_series
}

water_year_for_date <- function(date_value) {
  ifelse(as.integer(format(date_value, "%m")) >= 10,
    as.integer(format(date_value, "%Y")) + 1L,
    as.integer(format(date_value, "%Y"))
  )
}

synoptic_precip_metric_for_station <- function(station_id) {
  if (!DBI::dbExistsTable(con, "synoptic_fems_daily_stats")) {
    return(NULL)
  }

  metric_candidates <- c(
    "precip_accum_one_hour_set_1.mean",
    "precip_accum_set_1.mean",
    "precip_accum_24_hour_set_1.mean"
  )
  metric_sql <- paste(DBI::dbQuoteString(con, metric_candidates), collapse = ", ")
  available <- DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT metric_name, COUNT(*) AS n_rows, MIN(local_date) AS first_local_date",
        "FROM synoptic_fems_daily_stats",
        "WHERE station_id = %s AND metric_name IN (%s)",
        "GROUP BY metric_name"
      ),
      DBI::dbQuoteString(con, station_id),
      metric_sql
    )
  )

  if (!nrow(available)) {
    return(NULL)
  }

  # The FEMS hourly increment is the best current-day source, but it was only
  # added recently. Accumulated-precipitation percentiles need the longest
  # available period of record, so use the historical cumulative counter when
  # it spans more days than the recent hourly field.
  available$n_rows <- as.numeric(available$n_rows)
  available <- available[order(-available$n_rows, match(available$metric_name, metric_candidates)), , drop = FALSE]

  if (nrow(available) && is.finite(available$n_rows[[1]]) && available$n_rows[[1]] > 0) {
    return(as.character(available$metric_name[[1]]))
  }

  NULL
}

# `precip_accum_set_1.mean` is a running source counter, not a daily rain
# amount. The dashboard chart already converts it to a daily increment; use
# the same endpoint-difference rule for its historical percentile reference.
synoptic_fems_precip_daily_totals <- function(station_id) {
  metric_name <- synoptic_precip_metric_for_station(station_id)
  if (is.null(metric_name) || !DBI::dbExistsTable(con, "synoptic_fems_daily_stats")) {
    return(data.frame())
  }

  rows <- DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT local_date, value_min, value_mean, value_max, is_complete_day",
        "FROM synoptic_fems_daily_stats",
        "WHERE station_id = %s AND metric_name = %s"
      ),
      DBI::dbQuoteString(con, station_id),
      DBI::dbQuoteString(con, metric_name)
    )
  )

  if (!nrow(rows)) {
    return(data.frame())
  }

  rows$local_date <- as.Date(as.numeric(rows$local_date), origin = "1970-01-01")
  rows <- rows[rows$is_complete_day == 1 | rows$is_complete_day == TRUE, , drop = FALSE]
  rows <- rows[order(rows$local_date), , drop = FALSE]
  if (!nrow(rows)) {
    return(data.frame())
  }

  if (identical(metric_name, "precip_accum_set_1.mean")) {
    raw_min <- as.numeric(rows$value_min)
    raw_max <- as.numeric(rows$value_max)
    daily_total <- rep(NA_real_, nrow(rows))

    for (idx in seq_len(nrow(rows))) {
      current_max <- raw_max[[idx]]
      previous_max <- if (idx > 1L) raw_max[[idx - 1L]] else NA_real_

      if (is.na(current_max)) {
        next
      }
      if (idx == 1L) {
        daily_total[[idx]] <- if (!is.na(raw_min[[idx]])) max(current_max - raw_min[[idx]], 0) else 0
      } else if (!is.na(previous_max) && current_max >= previous_max) {
        daily_total[[idx]] <- current_max - previous_max
      } else {
        # A source counter reset starts a new accumulation interval.
        daily_total[[idx]] <- current_max
      }
    }
  } else if (identical(metric_name, "precip_accum_one_hour_set_1.mean")) {
    daily_total <- as.numeric(rows$value_mean)
  } else {
    daily_total <- as.numeric(rows$value_max)
  }

  data.frame(
    local_date = rows$local_date,
    daily_total = daily_total,
    stringsAsFactors = FALSE
  )
}

precip_percentile_summary <- function(values, current_value, local_date) {
  values <- as.numeric(values)
  values <- values[is.finite(values)]
  if (!length(values)) {
    return(NULL)
  }

  quantiles <- stats::quantile(
    values,
    probs = c(0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95),
    na.rm = TRUE,
    names = FALSE,
    type = 7
  )
  summary <- list(
    current = null_if_na(current_value),
    p05 = null_if_na(quantiles[[1]]),
    p10 = null_if_na(quantiles[[2]]),
    p25 = null_if_na(quantiles[[3]]),
    p50 = null_if_na(quantiles[[4]]),
    p75 = null_if_na(quantiles[[5]]),
    p90 = null_if_na(quantiles[[6]]),
    p95 = null_if_na(quantiles[[7]])
  )

  list(
    local_date = as.character(local_date),
    day_of_year_key = format(local_date, "%m-%d"),
    n_years = length(values),
    value_min = summary,
    value_mean = summary,
    value_max = summary
  )
}

get_synoptic_precip_accum_percentiles <- function(station_id, latest_local_date, current_value = NA_real_) {
  if (is.na(latest_local_date)) {
    return(NULL)
  }

  precip_rows <- synoptic_fems_precip_daily_totals(station_id)
  if (!nrow(precip_rows)) {
    return(NULL)
  }

  target_key <- format(latest_local_date, "%m-%d")
  precip_percentile_summary(
    values = precip_rows$daily_total[format(precip_rows$local_date, "%m-%d") == target_key],
    current_value = current_value,
    local_date = latest_local_date
  )
}

get_synoptic_precip_accum_percentile_series <- function(station_id, daily_series) {
  precip_rows <- synoptic_fems_precip_daily_totals(station_id)
  if (!nrow(precip_rows) || !length(daily_series)) {
    return(NULL)
  }

  values_by_day <- split(precip_rows$daily_total, format(precip_rows$local_date, "%m-%d"))
  metric_points <- list()

  for (point in daily_series) {
    point_date <- as.Date(substr(point$timestamp, 1, 10))
    values <- values_by_day[[format(point_date, "%m-%d")]]
    if (is.null(values)) {
      next
    }

    summary <- precip_percentile_summary(values, current_value = NA_real_, local_date = point_date)
    if (is.null(summary)) {
      next
    }

    metric_points[[length(metric_points) + 1L]] <- list(
      timestamp = point$timestamp,
      n_years = summary$n_years,
      p05 = summary$value_mean$p05,
      p10 = summary$value_mean$p10,
      p25 = summary$value_mean$p25,
      p50 = summary$value_mean$p50,
      p75 = summary$value_mean$p75,
      p90 = summary$value_mean$p90,
      p95 = summary$value_mean$p95
    )
  }

  if (!length(metric_points)) NULL else metric_points
}

get_accumulated_precip_percentiles <- function(station_id, latest_local_date, api_label, current_value = NA_real_, has_wims = FALSE) {
  if (is.null(latest_local_date) || length(latest_local_date) == 0 || is.na(latest_local_date)) {
    return(NULL)
  }

  stats_table <- if (api_label == "Zentra") "zentracloud_daily_stats" else "synoptic_fems_daily_stats"
  precip_metric_name <- if (api_label == "Zentra") {
    "port_1_atmos_41_in_precipitation"
  } else {
    synoptic_precip_metric_for_station(station_id)
  }

  if (is.null(precip_metric_name) || !DBI::dbExistsTable(con, stats_table)) {
    return(NULL)
  }

  precip_query <- sprintf(
    paste(
      "SELECT local_date, value_min, value_mean, value_max, n_obs, is_complete_day",
      "FROM %s",
      "WHERE station_id = %s",
      "AND metric_name = %s"
    ),
    stats_table,
    DBI::dbQuoteString(con, station_id),
    DBI::dbQuoteString(con, precip_metric_name)
  )

  precip_rows <- DBI::dbGetQuery(con, precip_query)
  if (!nrow(precip_rows)) {
    return(NULL)
  }

  precip_rows$local_date <- as.Date(as.numeric(precip_rows$local_date), origin = "1970-01-01")
  precip_rows <- precip_rows[precip_rows$is_complete_day == 1 | precip_rows$is_complete_day == TRUE, , drop = FALSE]

  if (!nrow(precip_rows)) {
    return(NULL)
  }

  precip_rows$water_year <- water_year_for_date(precip_rows$local_date)
  precip_rows$month_day <- format(precip_rows$local_date, "%m-%d")
  precip_rows <- precip_rows[order(precip_rows$local_date), , drop = FALSE]

  split_by_wy <- split(precip_rows, precip_rows$water_year)
  cumulative_values <- unlist(lapply(split_by_wy, function(df) {
    df <- df[order(df$local_date), , drop = FALSE]
    if (api_label == "Zentra") {
      df$daily_total <- as.numeric(df$value_mean) * as.numeric(df$n_obs)
    } else if (identical(precip_metric_name, "precip_accum_set_1.mean")) {
      raw_min <- as.numeric(df$value_min)
      raw_max <- as.numeric(df$value_max)
      daily_total <- rep(NA_real_, nrow(df))

      for (idx in seq_len(nrow(df))) {
        current_max <- raw_max[idx]
        current_min <- raw_min[idx]
        previous_max <- if (idx > 1) raw_max[idx - 1] else NA_real_

        if (is.na(current_max)) {
          next
        }

        if (idx == 1) {
          if (!is.na(current_min)) {
            daily_total[idx] <- max(current_max - current_min, 0)
          } else {
            daily_total[idx] <- 0
          }
        } else if (!is.na(previous_max) && current_max >= previous_max) {
          daily_total[idx] <- current_max - previous_max
        } else {
          daily_total[idx] <- current_max
        }
      }

      df$daily_total <- daily_total
    } else {
      df$daily_total <- as.numeric(df$value_max)
    }

    df$daily_total[is.na(df$daily_total)] <- 0
    df$cumulative <- cumsum(df$daily_total)
    target <- df[df$month_day == format(latest_local_date, "%m-%d"), , drop = FALSE]
    if (!nrow(target)) {
      return(numeric())
    }
    target$cumulative[[nrow(target)]]
  }))

  cumulative_values <- cumulative_values[is.finite(cumulative_values)]

  if (!length(cumulative_values)) {
    return(NULL)
  }

  quantiles <- stats::quantile(
    cumulative_values,
    probs = c(0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95),
    na.rm = TRUE,
    names = FALSE,
    type = 7
  )

  list(
    local_date = as.character(latest_local_date),
    day_of_year_key = format(latest_local_date, "%m-%d"),
    n_years = length(cumulative_values),
    value_mean = list(
      current = null_if_na(current_value),
      p05 = null_if_na(quantiles[[1]]),
      p10 = null_if_na(quantiles[[2]]),
      p25 = null_if_na(quantiles[[3]]),
      p50 = null_if_na(quantiles[[4]]),
      p75 = null_if_na(quantiles[[5]]),
      p90 = null_if_na(quantiles[[6]]),
      p95 = null_if_na(quantiles[[7]])
    )
  )
}

get_accumulated_precip_percentile_series <- function(station_id, daily_series, api_label, has_wims = FALSE) {
  if (!length(daily_series)) {
    return(NULL)
  }

  stats_table <- if (api_label == "Zentra") "zentracloud_daily_stats" else "synoptic_fems_daily_stats"
  precip_metric_name <- if (api_label == "Zentra") {
    "port_1_atmos_41_in_precipitation"
  } else {
    synoptic_precip_metric_for_station(station_id)
  }

  if (is.null(precip_metric_name) || !DBI::dbExistsTable(con, stats_table)) {
    return(NULL)
  }

  precip_query <- sprintf(
    paste(
      "SELECT local_date, value_min, value_mean, value_max, n_obs, is_complete_day",
      "FROM %s",
      "WHERE station_id = %s",
      "AND metric_name = %s"
    ),
    stats_table,
    DBI::dbQuoteString(con, station_id),
    DBI::dbQuoteString(con, precip_metric_name)
  )

  precip_rows <- DBI::dbGetQuery(con, precip_query)
  if (!nrow(precip_rows)) {
    return(NULL)
  }

  precip_rows$local_date <- as.Date(as.numeric(precip_rows$local_date), origin = "1970-01-01")
  precip_rows <- precip_rows[precip_rows$is_complete_day == 1 | precip_rows$is_complete_day == TRUE, , drop = FALSE]
  if (!nrow(precip_rows)) {
    return(NULL)
  }

  precip_rows$water_year <- water_year_for_date(precip_rows$local_date)
  precip_rows$month_day <- format(precip_rows$local_date, "%m-%d")
  precip_rows <- precip_rows[order(precip_rows$local_date), , drop = FALSE]

  split_by_wy <- split(precip_rows, precip_rows$water_year)
  cumulative_lookup <- list()

  for (wy_name in names(split_by_wy)) {
    df <- split_by_wy[[wy_name]]
    df <- df[order(df$local_date), , drop = FALSE]

    if (api_label == "Zentra") {
      df$daily_total <- as.numeric(df$value_mean) * as.numeric(df$n_obs)
    } else if (identical(precip_metric_name, "precip_accum_set_1.mean")) {
      raw_min <- as.numeric(df$value_min)
      raw_max <- as.numeric(df$value_max)
      daily_total <- rep(NA_real_, nrow(df))

      for (idx in seq_len(nrow(df))) {
        current_max <- raw_max[idx]
        current_min <- raw_min[idx]
        previous_max <- if (idx > 1) raw_max[idx - 1] else NA_real_

        if (is.na(current_max)) {
          next
        }

        if (idx == 1) {
          if (!is.na(current_min)) {
            daily_total[idx] <- max(current_max - current_min, 0)
          } else {
            daily_total[idx] <- 0
          }
        } else if (!is.na(previous_max) && current_max >= previous_max) {
          daily_total[idx] <- current_max - previous_max
        } else {
          daily_total[idx] <- current_max
        }
      }

      df$daily_total <- daily_total
    } else {
      df$daily_total <- as.numeric(df$value_max)
    }

    df$daily_total[is.na(df$daily_total)] <- 0
    df$cumulative <- cumsum(df$daily_total)

    for (row_idx in seq_len(nrow(df))) {
      doy_key <- df$month_day[[row_idx]]
      cumulative_lookup[[doy_key]] <- c(cumulative_lookup[[doy_key]], df$cumulative[[row_idx]])
    }
  }

  if (!length(cumulative_lookup)) {
    return(NULL)
  }

  metric_points <- list()

  for (idx in seq_along(daily_series)) {
    point <- daily_series[[idx]]
    doy_key <- format(as.Date(substr(point$timestamp, 1, 10)), "%m-%d")
    values <- cumulative_lookup[[doy_key]]

    if (is.null(values) || !length(values)) {
      next
    }

    values <- values[is.finite(values)]
    if (!length(values)) {
      next
    }

    quantiles <- stats::quantile(
      values,
      probs = c(0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95),
      na.rm = TRUE,
      names = FALSE,
      type = 7
    )

    metric_points[[length(metric_points) + 1L]] <- list(
      timestamp = point$timestamp,
      n_years = length(values),
      p05 = null_if_na(quantiles[[1]]),
      p10 = null_if_na(quantiles[[2]]),
      p25 = null_if_na(quantiles[[3]]),
      p50 = null_if_na(quantiles[[4]]),
      p75 = null_if_na(quantiles[[5]]),
      p90 = null_if_na(quantiles[[6]]),
      p95 = null_if_na(quantiles[[7]])
    )
  }

  if (!length(metric_points)) {
    return(NULL)
  }

  metric_points
}

build_hourly_overlay <- function(station_hourly, api_label, display_api = api_label, prior_cumulative = NA_real_) {
  if (!nrow(station_hourly)) {
    return(list())
  }

  station_hourly <- station_hourly[order(station_hourly$date), , drop = FALSE]
  running_cumulative <- ifelse(is.na(prior_cumulative), 0, prior_cumulative)
  synoptic_day_baseline <- NA_real_

  points <- vector("list", nrow(station_hourly))
  for (i in seq_len(nrow(station_hourly))) {
    row <- station_hourly[i, , drop = FALSE]
    display_epoch <- as.numeric(row$date[[1]])
    point <- list(
      timestamp = format_timestamp(display_epoch),
      resolution = "recent",
      soil_moisture_1 = null_if_na(row$soil_moisture_1[[1]]),
      soil_moisture_2 = null_if_na(row$soil_moisture_2[[1]]),
      air_temp = null_if_na(row$air_temp[[1]]),
      humidity = null_if_na(row$humidity[[1]]),
      wind_speed = null_if_na(row$wind_speed[[1]])
    )

    if ("precip_24h" %in% names(row) || "precip_accum_wims" %in% names(row) || "precip_hourly" %in% names(row)) {
      point$precip_accum <- if ("precip_hourly" %in% names(row) && !is.na(row$precip_hourly[[1]])) {
        safe_numeric(row$precip_hourly[[1]])
      } else if ("precip_accum_wims" %in% names(row) && !is.na(row$precip_accum_wims[[1]])) {
        raw_value <- safe_numeric(row$precip_accum_wims[[1]])
        if (is.na(raw_value)) {
          NA
        } else {
          if (is.na(synoptic_day_baseline)) {
            synoptic_day_baseline <- raw_value
          }

          if (raw_value >= synoptic_day_baseline) {
            raw_value - synoptic_day_baseline
          } else {
            raw_value
          }
        }
      } else if ("precip_24h" %in% names(row)) {
        precip_24h_value <- null_if_na(row$precip_24h[[1]])
        if (!is.null(precip_24h_value) && !is.na(precip_24h_value)) {
          precip_24h_value
        } else if ("precip_hourly" %in% names(row)) {
          null_if_na(row$precip_hourly[[1]])
        } else {
          NA
        }
      } else if ("precip_hourly" %in% names(row)) {
        null_if_na(row$precip_hourly[[1]])
      } else {
        NA
      }
    }

    if ("gsi" %in% names(row)) {
      point$gsi <- null_if_na(row$gsi[[1]])
    }

    if ("kbdi" %in% names(row)) {
      point$kbdi <- null_if_na(row$kbdi[[1]])
    }

    if (api_label == "Zentra" && "precip_increment" %in% names(row)) {
      increment <- safe_numeric(row$precip_increment[[1]])
      point$precip_accum <- null_if_na(increment)
      if (!is.na(increment)) {
        running_cumulative <- running_cumulative + increment
      }
      point$precip_cumulative <- if (running_cumulative == 0 && is.na(increment)) NA else running_cumulative
    } else if (api_label == "Synoptic/FEMS") {
      precip_amount <- safe_numeric(point$precip_accum)
      if (!is.na(precip_amount)) {
        if ("precip_hourly" %in% names(row) && !is.na(row$precip_hourly[[1]])) {
          running_cumulative <- running_cumulative + precip_amount
          point$precip_cumulative <- running_cumulative
        } else {
          point$precip_cumulative <- running_cumulative + precip_amount
        }
      } else if (!is.na(running_cumulative) && running_cumulative != 0) {
        point$precip_cumulative <- running_cumulative
      }
    }

    points[[i]] <- point
  }
  points
}

value_on_or_before <- function(series, metric_key, cutoff_date) {
  if (!length(series)) {
    return(NA_real_)
  }

  matches <- Filter(function(point) {
    point_date <- as.Date(substr(point$timestamp, 1, 10))
    value <- point[[metric_key]]
    point$resolution == "daily" &&
      point_date <= cutoff_date &&
      !is.null(value) &&
      !is.na(value)
  }, series)

  if (!length(matches)) {
    return(NA_real_)
  }

  safe_numeric(matches[[length(matches)]][[metric_key]])
}

latest_value_for_metric <- function(daily_series, hourly_series, metric_key) {
  if (length(hourly_series)) {
    for (idx in rev(seq_along(hourly_series))) {
      value <- hourly_series[[idx]][[metric_key]]
      if (!is.null(value) && !is.na(value)) {
        return(value)
      }
    }
  }

  if (length(daily_series)) {
    for (idx in rev(seq_along(daily_series))) {
      value <- daily_series[[idx]][[metric_key]]
      if (!is.null(value) && !is.na(value)) {
        return(value)
      }
    }
  }

  NA
}

latest_timestamp_for_metric <- function(daily_series, hourly_series, metric_key) {
  if (length(hourly_series)) {
    for (idx in rev(seq_along(hourly_series))) {
      value <- hourly_series[[idx]][[metric_key]]
      if (!is.null(value) && !is.na(value)) {
        return(hourly_series[[idx]]$timestamp)
      }
    }
  }

  if (length(daily_series)) {
    for (idx in rev(seq_along(daily_series))) {
      value <- daily_series[[idx]][[metric_key]]
      if (!is.null(value) && !is.na(value)) {
        return(daily_series[[idx]]$timestamp)
      }
    }
  }

  NA_character_
}

latest_daily_value_for_metric <- function(daily_series, metric_key, target_date = NULL) {
  if (!length(daily_series)) {
    return(NA)
  }

  target_point <- NULL

  if (!is.null(target_date) && length(target_date) && !is.na(target_date)) {
    for (idx in rev(seq_along(daily_series))) {
      point <- daily_series[[idx]]
      point_date <- as.Date(substr(point$timestamp, 1, 10))
      if (!is.na(point_date) && identical(point_date, target_date)) {
        target_point <- point
        break
      }
    }
  }

  if (is.null(target_point)) {
    target_point <- daily_series[[length(daily_series)]]
  }

  value <- target_point[[metric_key]]
  if (is.null(value) || is.na(value)) {
    return(NA)
  }

  value
}

latest_observation_timestamp <- function(daily_series, hourly_series) {
  sensor_keys <- c("soil_moisture_1", "soil_moisture_2", "air_temp", "humidity",
    "wind_speed", "precip_accum", "precip_increment")
  for (points in list(hourly_series, daily_series)) {
    for (idx in rev(seq_along(points))) {
      point <- points[[idx]]
      present <- vapply(sensor_keys, function(key) {
        value <- point[[key]]
        length(value) == 1L && is.numeric(value) && is.finite(value)
      }, logical(1))
      if (any(present)) return(point$timestamp)
    }
  }
  # Index-only stations retain their reporting timestamp, not a fabricated shift.
  points <- if (length(hourly_series)) hourly_series else daily_series
  if (length(points)) tail(points, 1)[[1]]$timestamp else NA_character_
}

build_station_payload <- function(station_id, station_stats, station_hourly, fallback_api, display_api = fallback_api, fallback_name = NULL, wims_id = NULL) {
  meta <- build_station_meta(
    station_id = station_id,
    fallback_name = fallback_name,
    fallback_api = display_api,
    wims_id = wims_id
  )
  has_wims <- !is.null(wims_id) && !is.na(wims_id) && nzchar(as.character(wims_id))

  daily_series <- build_daily_series(station_stats, api_label = fallback_api)
  prior_cumulative <- if (length(daily_series) && water_year_for_date(as.Date(substr(tail(daily_series, 1)[[1]]$timestamp, 1, 10))) == water_year_for_date(local_today)) safe_numeric(tail(daily_series, 1)[[1]]$precip_cumulative) else 0
  hourly_series <- build_hourly_overlay(
    station_hourly,
    api_label = fallback_api,
    display_api = meta$api,
    prior_cumulative = prior_cumulative
  )
  full_series <- c(daily_series, hourly_series)

  latest_timestamp <- latest_observation_timestamp(daily_series, hourly_series)

  complete_station_stats <- station_stats[station_stats$is_complete_day %in% c(TRUE, 1), , drop = FALSE]
  latest_local_date <- if (nrow(complete_station_stats)) {
    max(complete_station_stats$local_date, na.rm = TRUE)
  } else if (nrow(station_stats)) {
    max(station_stats$local_date, na.rm = TRUE)
  } else {
    as.Date(NA)
  }
  prior_date <- latest_local_date - 14
  latest_daily_point <- if (length(daily_series)) {
    latest_daily_matches <- Filter(function(point) {
      point$resolution == "daily" &&
        !is.na(latest_local_date) &&
        identical(as.Date(substr(point$timestamp, 1, 10)), latest_local_date)
    }, daily_series)

    if (length(latest_daily_matches)) {
      latest_daily_matches[[length(latest_daily_matches)]]
    } else {
      daily_series[[length(daily_series)]]
    }
  } else {
    NULL
  }
  station_percentiles <- get_station_percentiles(
    station_id = station_id,
    latest_local_date = latest_local_date,
    api_label = fallback_api,
    metric_map = stats_metric_maps[[fallback_api]],
    latest_daily_point = latest_daily_point
  )

  if (identical(fallback_api, "Synoptic/FEMS")) {
    daily_precip_percentiles <- get_synoptic_precip_accum_percentiles(
      station_id = station_id,
      latest_local_date = latest_local_date,
      current_value = if (is.null(latest_daily_point)) NA_real_ else safe_numeric(latest_daily_point$precip_accum)
    )
    if (!is.null(daily_precip_percentiles)) {
      station_percentiles$precip_accum <- daily_precip_percentiles
    }
  }

  accumulated_precip_percentiles <- get_accumulated_precip_percentiles(
    station_id = station_id,
    latest_local_date = latest_local_date,
    api_label = fallback_api,
    current_value = latest_value_for_metric(daily_series, hourly_series, "precip_cumulative"),
    has_wims = has_wims
  )

  if (!is.null(accumulated_precip_percentiles)) {
    station_percentiles$precip_cumulative <- accumulated_precip_percentiles
  }

  percentile_series <- get_station_percentile_series(
    station_id = station_id,
    daily_series = daily_series,
    api_label = fallback_api,
    metric_map = stats_metric_maps[[fallback_api]]
  )

  if (identical(fallback_api, "Synoptic/FEMS")) {
    daily_precip_percentile_series <- get_synoptic_precip_accum_percentile_series(
      station_id = station_id,
      daily_series = daily_series
    )
    if (!is.null(daily_precip_percentile_series)) {
      percentile_series$precip_accum <- daily_precip_percentile_series
    }
  }

  accumulated_precip_percentile_series <- get_accumulated_precip_percentile_series(
    station_id = station_id,
    daily_series = daily_series,
    api_label = fallback_api,
    has_wims = has_wims
  )

  if (!is.null(accumulated_precip_percentile_series)) {
    percentile_series$precip_cumulative <- accumulated_precip_percentile_series
  }

  latest <- list(
    timestamp = latest_timestamp,
    soil_moisture_1 = latest_value_for_metric(daily_series, hourly_series, "soil_moisture_1"),
    soil_moisture_2 = latest_value_for_metric(daily_series, hourly_series, "soil_moisture_2"),
    air_temp = latest_value_for_metric(daily_series, hourly_series, "air_temp"),
    humidity = latest_value_for_metric(daily_series, hourly_series, "humidity"),
    wind_speed = latest_value_for_metric(daily_series, hourly_series, "wind_speed"),
    precip_accum = latest_value_for_metric(daily_series, hourly_series, "precip_accum"),
    precip_total = latest_value_for_metric(daily_series, hourly_series, "precip_cumulative"),
    precip_cumulative = latest_value_for_metric(daily_series, hourly_series, "precip_cumulative"),
    gsi = latest_daily_value_for_metric(daily_series, "gsi", latest_local_date),
    kbdi = latest_daily_value_for_metric(daily_series, "kbdi", latest_local_date),
    soil_moisture_1_change_14d = latest_value_for_metric(daily_series, hourly_series, "soil_moisture_1") - value_on_or_before(daily_series, "soil_moisture_1", prior_date),
    soil_moisture_2_change_14d = latest_value_for_metric(daily_series, hourly_series, "soil_moisture_2") - value_on_or_before(daily_series, "soil_moisture_2", prior_date),
    precip_cumulative_change_14d = latest_value_for_metric(daily_series, hourly_series, "precip_cumulative") - value_on_or_before(daily_series, "precip_cumulative", prior_date),
    gsi_change_14d = latest_daily_value_for_metric(daily_series, "gsi", latest_local_date) - value_on_or_before(daily_series, "gsi", prior_date),
    kbdi_change_14d = latest_daily_value_for_metric(daily_series, "kbdi", latest_local_date) - value_on_or_before(daily_series, "kbdi", prior_date)
  )

  latest_dates <- list(
    soil_moisture_1 = latest_timestamp_for_metric(daily_series, hourly_series, "soil_moisture_1"),
    soil_moisture_2 = latest_timestamp_for_metric(daily_series, hourly_series, "soil_moisture_2"),
    air_temp = latest_timestamp_for_metric(daily_series, hourly_series, "air_temp"),
    humidity = latest_timestamp_for_metric(daily_series, hourly_series, "humidity"),
    wind_speed = latest_timestamp_for_metric(daily_series, hourly_series, "wind_speed"),
    precip_accum = latest_timestamp_for_metric(daily_series, hourly_series, "precip_accum"),
    precip_cumulative = latest_timestamp_for_metric(daily_series, hourly_series, "precip_cumulative"),
    gsi = latest_timestamp_for_metric(daily_series, hourly_series, "gsi"),
    kbdi = latest_timestamp_for_metric(daily_series, hourly_series, "kbdi")
  )

  if (is.na(latest$soil_moisture_1_change_14d)) {
    latest$soil_moisture_1_change_14d <- NA
  }

  if (is.na(latest$soil_moisture_2_change_14d)) {
    latest$soil_moisture_2_change_14d <- NA
  }

  if (is.na(latest$precip_cumulative_change_14d)) {
    latest$precip_cumulative_change_14d <- NA
  }

  if (is.na(latest$gsi_change_14d)) {
    latest$gsi_change_14d <- NA
  }

  if (is.na(latest$kbdi_change_14d)) {
    latest$kbdi_change_14d <- NA
  }

  years_lookup <- station_record_years[[fallback_api]]
  years_of_data <- if (!is.null(years_lookup) && station_id %in% names(years_lookup)) {
    as.integer(years_lookup[[station_id]])
  } else if (nrow(station_stats)) {
    length(unique(format(station_stats$local_date, "%Y")))
  } else {
    NA_integer_
  }

  if (!is.na(years_of_data) && length(station_percentiles)) {
    for (metric_name in names(station_percentiles)) {
      metric_years <- station_percentiles[[metric_name]]$n_years
      if (!is.null(metric_years) && !is.na(metric_years)) {
        station_percentiles[[metric_name]]$n_years <- min(as.integer(metric_years), years_of_data)
      }
    }
  }

  today_reference <- get_station_percentiles(station_id, local_today, fallback_api,
    stats_metric_maps[[fallback_api]], latest_daily_point = NULL)
  if (identical(fallback_api, "Synoptic/FEMS")) {
    today_reference$precip_accum <- get_synoptic_precip_accum_percentiles(station_id, local_today)
  }
  today_reference$precip_cumulative <- get_accumulated_precip_percentiles(station_id,
    local_today, fallback_api, current_value = NA_real_, has_wims = has_wims)

  list(
    id = meta$id,
    name = meta$name,
    api = meta$api,
    latitude = meta$latitude,
    longitude = meta$longitude,
    geometry_wkt = meta$geometry_wkt,
    years_of_data = years_of_data,
    latest = latest,
    latest_dates = latest_dates,
    percentiles = station_percentiles,
    today_reference = today_reference,
    percentile_series = percentile_series,
    series = full_series
  )
}

zentra_ids <- sort(unique(c(
  if (nrow(zentra_stats)) zentra_stats$station_id else character(),
  if (nrow(zentra_hourly)) zentra_hourly$station_id else character()
)))

synoptic_ids <- sort(unique(synoptic_station_lookup$station_id))

stations <- c(
  lapply(zentra_ids, function(station_id) {
    build_station_payload(
      station_id = station_id,
      station_stats = zentra_stats[zentra_stats$station_id == station_id, , drop = FALSE],
      station_hourly = zentra_hourly[zentra_hourly$station_id == station_id, , drop = FALSE],
      fallback_api = "Zentra"
    )
  }),
  lapply(synoptic_ids, function(station_id) {
    station_hourly <- synoptic_hourly[synoptic_hourly$station_id == station_id, , drop = FALSE]
    fallback_wims <- NULL
    fallback_name <- NULL

    if (nrow(station_hourly) && "wims_id" %in% names(station_hourly)) {
      fallback_wims <- null_if_na(station_hourly$wims_id[[1]])
    }

    if ((is.null(fallback_wims) || is.na(fallback_wims)) && nrow(synoptic_station_lookup)) {
      lookup_row <- synoptic_station_lookup[synoptic_station_lookup$station_id == station_id, , drop = FALSE]
      if (nrow(lookup_row)) {
        fallback_wims <- null_if_na(lookup_row$wims_id[[1]])
      }
    }

    if (nrow(sites_lookup)) {
      direct_lookup_row <- site_row_for_station(station_id, wims_id = fallback_wims)
      if (!is.null(direct_lookup_row)) {
        if ("station_name" %in% names(direct_lookup_row)) {
          fallback_name <- null_if_na(direct_lookup_row$station_name[[1]])
        }
        if ((is.null(fallback_wims) || is.na(fallback_wims)) && "wims_id" %in% names(direct_lookup_row)) {
          fallback_wims <- null_if_na(direct_lookup_row$wims_id[[1]])
        }
      }
    }

    build_station_payload(
      station_id = station_id,
      station_stats = synoptic_stats[synoptic_stats$station_id == station_id, , drop = FALSE],
      station_hourly = station_hourly,
      fallback_api = "Synoptic/FEMS",
      display_api = if (!is.null(fallback_wims) && !is.na(fallback_wims) && nzchar(as.character(fallback_wims))) "FEMS" else "Synoptic",
      fallback_name = if (!is.null(fallback_name) && !is.na(fallback_name) && nzchar(as.character(fallback_name))) fallback_name else station_id,
      wims_id = fallback_wims
    )
  })
)

for (i in seq_along(stations)) {
  stations[[i]]$available_metrics <- available_metrics_for_station(stations[[i]])
}

latest_timestamps <- vapply(stations, function(x) x$latest$timestamp, character(1))

avg_latest <- function(field) {
  vals <- vapply(stations, function(x) safe_numeric(x$latest[[field]]), numeric(1))
  mean(vals, na.rm = TRUE)
}

sum_latest <- function(field) {
  vals <- vapply(stations, function(x) safe_numeric(x$latest[[field]]), numeric(1))
  sum(vals, na.rm = TRUE)
}

stations_for_dashboard <- stations

if (nrow(sites_lookup)) {
  station_name_lookup <- sites_lookup

  if ("station_name" %in% names(station_name_lookup)) {
    station_name_lookup$station_name <- as.character(station_name_lookup$station_name)
  }
  if ("wims_id" %in% names(station_name_lookup)) {
    station_name_lookup$wims_id <- as.character(station_name_lookup$wims_id)
  }
  if ("station_id" %in% names(station_name_lookup)) {
    station_name_lookup$station_id <- as.character(station_name_lookup$station_id)
  }

  resolve_export_station_name <- function(station) {
    if (is.null(station) || is.null(station$id)) {
      return(station)
    }

    first_lookup_match <- function(column_name, value) {
      if (!column_name %in% names(station_name_lookup) || is.null(value) || length(value) == 0 || is.na(value) || !nzchar(trimws(as.character(value)))) {
        return(NULL)
      }

      column_values <- as.character(station_name_lookup[[column_name]])
      match_idx <- which(!is.na(column_values) & column_values == as.character(value))

      if (!length(match_idx)) {
        return(NULL)
      }

      station_name_lookup[match_idx[[1]], , drop = FALSE]
    }

    match_row <- NULL

    match_row <- first_lookup_match("wims_id", station$id)
    if (is.null(match_row)) {
      match_row <- first_lookup_match("station_key", station$id)
    }
    if (is.null(match_row)) {
      match_row <- first_lookup_match("station_id", station$id)
    }

    if (!is.null(match_row) && "station_name" %in% names(match_row)) {
      resolved_name <- null_if_na(match_row$station_name[[1]])
      if (!is.null(resolved_name) && !is.na(resolved_name) && nzchar(as.character(resolved_name))) {
        station$name <- resolved_name
      }
    }

    station
  }

  stations_for_dashboard <- lapply(stations_for_dashboard, resolve_export_station_name)
}

station_catalog <- lapply(stations_for_dashboard, function(station) {
  list(
    id = station$id,
    name = station$name,
    api = station$api,
    latitude = station$latitude,
    longitude = station$longitude,
    geometry_wkt = station$geometry_wkt,
    years_of_data = station$years_of_data,
    available_metrics = lapply(station$available_metrics, function(metric_key) {
      list(
        key = metric_key,
        label = unname(metric_label_map[[metric_key]])
      )
    }),
    latest_timestamp = station$latest$timestamp,
    latest = station$latest,
    latest_dates = station$latest_dates,
    percentiles = station$percentiles
  )
})

existing_station_json <- list.files(
  stations_data_dir,
  pattern = "\\.json$",
  full.names = TRUE
)
if (length(existing_station_json)) {
  unlink(existing_station_json, recursive = FALSE, force = TRUE)
}

for (station in stations_for_dashboard) {
  station_path <- file.path(stations_data_dir, paste0(as.character(station$id), ".json"))
  jsonlite::write_json(
    x = station,
    path = station_path,
    pretty = FALSE,
    auto_unbox = TRUE,
    na = "null"
  )
}

station_points_export <- build_station_points_sf(stations_for_dashboard)

if (!is.null(station_points_export) && nrow(station_points_export)) {
  suppressWarnings(
    sf::st_write(
      station_points_export,
      dsn = file.path(data_dir, "leaflet_station_layer.geojson"),
      delete_dsn = TRUE,
      quiet = TRUE
    )
  )

  suppressWarnings(
    sf::st_write(
      station_points_export,
      dsn = file.path(data_dir, "leaflet_station_layer.gpkg"),
      layer = "leaflet_station_layer",
      delete_dsn = TRUE,
      quiet = TRUE
    )
  )
}

zone_reports <- list()

station_report_lookup <- data.frame(
  station_id = vapply(stations_for_dashboard, function(station) as.character(station$id), character(1)),
  station_name = vapply(stations_for_dashboard, function(station) as.character(station$name), character(1)),
  api = vapply(stations_for_dashboard, function(station) as.character(station$api), character(1)),
  latest_timestamp = vapply(stations_for_dashboard, function(station) as.character(station$latest$timestamp), character(1)),
  years_of_data = vapply(stations_for_dashboard, function(station) safe_numeric(station$years_of_data), numeric(1)),
  variables = vapply(stations_for_dashboard, function(station) paste(unname(metric_label_map[station$available_metrics]), collapse = ", "), character(1)),
  stringsAsFactors = FALSE
)

zone_columns <- if (nrow(sites_lookup)) {
  grep("_zone$", names(sites_lookup), value = TRUE)
} else {
  character()
}

raw_zentra_precip <- if (DBI::dbExistsTable(con, "zentracloud_data")) {
  DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT CAST(station_id AS TEXT) AS station_id,",
        "date,",
        "port_1_atmos_41_in_precipitation AS precip_value",
        "FROM zentracloud_data",
        "WHERE date >= %s",
        "AND port_1_atmos_41_in_precipitation IS NOT NULL"
      ),
      as.numeric(Sys.time()) - 31 * 24 * 60 * 60
    )
  )
} else {
  data.frame()
}

raw_synoptic_precip <- if (DBI::dbExistsTable(con, "synoptic_fems_data")) {
  DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT CAST(station_id AS TEXT) AS station_id,",
        "date,",
        "\"precip_accum_set_1.mean\" AS precip_cumulative,",
        "\"precip_accum_one_hour_set_1.mean\" AS precip_value",
        "FROM synoptic_fems_data",
        "WHERE date >= %s",
        "AND \"precip_accum_one_hour_set_1.mean\" IS NOT NULL"
      ),
      as.numeric(Sys.time()) - 31 * 24 * 60 * 60
    )
  )
} else {
  data.frame()
}

if (length(zone_columns)) {
  for (zone_column in zone_columns) {
    zone_mask <- is_truthy_zone_flag(sites_lookup[[zone_column]])
    zone_site_rows <- sites_lookup[zone_mask, , drop = FALSE]

    if (!nrow(zone_site_rows)) {
      next
    }

    zone_station_ids <- unique(as.character(zone_site_rows$station_id))
    zone_station_ids <- zone_station_ids[!is.na(zone_station_ids) & nzchar(zone_station_ids)]
    zone_stations <- station_report_lookup[station_report_lookup$station_id %in% zone_station_ids, , drop = FALSE]
    zone_stations <- zone_stations[order(zone_stations$api, zone_stations$station_name), , drop = FALSE]

    zone_rows <- lapply(seq_len(nrow(zone_stations)), function(i) {
      station_row <- zone_stations[i, , drop = FALSE]
      station_id <- as.character(station_row$station_id[[1]])
      station_api <- as.character(station_row$api[[1]])

      precip_windows <- if (identical(station_api, "Zentra")) {
        compute_station_precip_windows(
          raw_rows = raw_zentra_precip[raw_zentra_precip$station_id == station_id, , drop = FALSE],
          api_label = "Zentra"
        )
      } else {
        compute_station_precip_windows(
          raw_rows = raw_synoptic_precip[raw_synoptic_precip$station_id == station_id, , drop = FALSE],
          api_label = "Synoptic/FEMS"
        )
      }

      list(
        station_id = station_id,
        station_name = as.character(station_row$station_name[[1]]),
        api = station_api,
        info = station_api,
        latest_timestamp = if (!is.null(precip_windows$latest_timestamp) &&
          !is.na(precip_windows$latest_timestamp) &&
          nzchar(as.character(precip_windows$latest_timestamp))) {
          as.character(precip_windows$latest_timestamp)
        } else {
          as.character(station_row$latest_timestamp[[1]])
        },
        totals = list(
          hours_24 = null_if_na(precip_windows$totals[["d1"]]),
          days_2 = null_if_na(precip_windows$totals[["d2"]]),
          days_7 = null_if_na(precip_windows$totals[["d7"]]),
          days_30 = null_if_na(precip_windows$totals[["d30"]])
        )
      )
    })

    summary_metrics <- list(
      hours_24 = vapply(zone_rows, function(row) safe_numeric(row$totals$hours_24), numeric(1)),
      days_2 = vapply(zone_rows, function(row) safe_numeric(row$totals$days_2), numeric(1)),
      days_7 = vapply(zone_rows, function(row) safe_numeric(row$totals$days_7), numeric(1)),
      days_30 = vapply(zone_rows, function(row) safe_numeric(row$totals$days_30), numeric(1))
    )

    summarize_zone_metric <- function(values) {
      values <- values[is.finite(values)]
      if (!length(values)) {
        return(list(max = NA, average = NA, min = NA))
      }

      list(
        max = max(values, na.rm = TRUE),
        average = mean(values, na.rm = TRUE),
        min = min(values, na.rm = TRUE)
      )
    }

    source_counts <- setNames(
      c(
        sum(zone_stations$api == "Zentra", na.rm = TRUE),
        sum(zone_stations$api == "FEMS", na.rm = TRUE),
        sum(zone_stations$api == "Synoptic", na.rm = TRUE)
      ),
      c("Zentra", "FEMS", "Synoptic")
    )

    zone_reports[[length(zone_reports) + 1L]] <- list(
      id = zone_column,
      label = zone_label_from_column(zone_column),
      slug = zone_slug_from_column(zone_column),
      station_count = nrow(zone_stations),
      source_counts = source_counts,
      latest_timestamp = {
        zone_latest_values <- vapply(zone_rows, function(row) {
          value <- row$latest_timestamp
          if (is.null(value) || is.na(value) || !nzchar(as.character(value))) {
            return(NA_character_)
          }
          as.character(value)
        }, character(1))
        zone_latest_values <- zone_latest_values[!is.na(zone_latest_values) & nzchar(zone_latest_values)]
        if (length(zone_latest_values)) max(zone_latest_values) else NA_character_
      },
      precip = list(
        windows = list(
          hours_24 = "24 hour",
          days_2 = "2 day",
          days_7 = "7 day",
          days_30 = "30 day"
        ),
        rows = zone_rows,
        summary = list(
          hours_24 = summarize_zone_metric(summary_metrics$hours_24),
          days_2 = summarize_zone_metric(summary_metrics$days_2),
          days_7 = summarize_zone_metric(summary_metrics$days_7),
          days_30 = summarize_zone_metric(summary_metrics$days_30)
        )
      )
    )
  }
}

zone_reports <- zone_reports[order(vapply(zone_reports, function(report) report$station_count, integer(1)), decreasing = TRUE)]

payload <- list(
  generated_at = format_iso_mountain(as.numeric(Sys.time())),
  date_window_days = 365L,
  date_window_start = as.character(chart_series_start),
  overview = list(
    station_count = length(stations_for_dashboard),
    last_timestamp = max(latest_timestamps),
    avg_soil_moisture_1 = avg_latest("soil_moisture_1"),
    avg_soil_moisture_2 = avg_latest("soil_moisture_2"),
    avg_air_temp = avg_latest("air_temp")
  ),
  station_catalog = station_catalog,
  stations = stations_for_dashboard
)

jsonlite::write_json(
  x = payload,
  path = file.path(data_dir, "dashboard.json"),
  pretty = FALSE,
  auto_unbox = TRUE,
  na = "null"
)

dashboard_js <- paste0(
  "window.__SOFU_DASHBOARD__ = ",
  jsonlite::toJSON(
    payload,
    auto_unbox = TRUE,
    null = "null",
    na = "null"
  ),
  ";\n"
)

writeLines(dashboard_js, file.path(data_dir, "dashboard-data.js"))

DBI::dbDisconnect(con)

reports_payload_script <- c(
  Sys.getenv("SOFU_REPORTS_PAYLOAD_SCRIPT", unset = ""),
  "/app/scripts/build_reports_payload.R",
  "scripts/build_reports_payload.R"
)
reports_payload_script <- reports_payload_script[nzchar(reports_payload_script)]
reports_payload_script <- reports_payload_script[file.exists(reports_payload_script)]

if (!length(reports_payload_script)) {
  stop("Could not locate scripts/build_reports_payload.R for static site build.")
}

reports_build_output <- system2(
  command = file.path(R.home("bin"), "Rscript"),
  args = c(reports_payload_script[[1]]),
  env = paste0("SOFU_REPORTS_JSON_PATH=", shQuote(file.path(data_dir, "reports.json"))),
  stdout = TRUE,
  stderr = TRUE
)

reports_build_status <- attr(reports_build_output, "status")
if (!is.null(reports_build_status) && !identical(reports_build_status, 0L)) {
  stop(
    paste(
      c("Failed to build reports payload.", reports_build_output),
      collapse = "\n"
    )
  )
}

if (length(reports_build_output)) {
  cat(paste(reports_build_output, collapse = "\n"), "\n")
}

cat("Static site written to:", site_dir, "\n")
