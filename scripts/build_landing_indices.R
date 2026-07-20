#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(sf)
  library(terra)
})

resolve_existing <- function(candidates) {
  existing <- candidates[file.exists(candidates)]
  if (!length(existing)) {
    stop("Could not find required file. Checked: ", paste(candidates, collapse = ", "), call. = FALSE)
  }
  existing[[1]]
}

output_dir <- Sys.getenv("SOFU_OUTPUT_DIR", "/output")
if (!dir.exists(output_dir)) {
  output_dir <- "output"
}

bbox_path <- resolve_existing(c(
  Sys.getenv("SOFU_GPKG_PATH", unset = NA_character_),
  "/data/cg_bbox.gpkg",
  "data/cg_bbox.gpkg"
))
states_path <- resolve_existing(c(
  Sys.getenv("SOFU_STATES_SHP_PATH", unset = NA_character_),
  "/data/cb_2018_us_state_500k/cb_2018_us_state_500k.shp",
  "data/cb_2018_us_state_500k/cb_2018_us_state_500k.shp"
))

days_back <- suppressWarnings(as.integer(Sys.getenv("SOFU_LANDING_INDEX_DAYS", "21")))
if (is.na(days_back) || days_back < 1L) {
  days_back <- 21L
}

eddi_timescale <- Sys.getenv("SOFU_EDDI_TIMESCALE", "02wk")
fordri_lookback_days <- suppressWarnings(as.integer(Sys.getenv("SOFU_FORDRI_LOOKBACK_DAYS", "60")))
if (is.na(fordri_lookback_days) || fordri_lookback_days < 1L) {
  fordri_lookback_days <- 60L
}
asset_root <- file.path(output_dir, "latest", "assets", "indices")
dir.create(asset_root, recursive = TRUE, showWarnings = FALSE)
manifest_path <- file.path(asset_root, "manifest.json")
previous_manifest <- if (file.exists(manifest_path)) {
  tryCatch(jsonlite::read_json(manifest_path, simplifyVector = FALSE), error = function(error) NULL)
} else {
  NULL
}
previous_products <- if (!is.null(previous_manifest$products)) {
  stats::setNames(previous_manifest$products, vapply(previous_manifest$products, `[[`, character(1), "id"))
} else {
  list()
}

parse_end_date <- function(value, variable_name) {
  if (!nzchar(value)) {
    return(Sys.Date())
  }

  parsed <- as.Date(value)
  if (is.na(parsed)) {
    stop(variable_name, " must use YYYY-MM-DD.", call. = FALSE)
  }
  parsed
}

shared_end_date <- Sys.getenv("SOFU_LANDING_INDEX_END_DATE", unset = "")
fordri_end_date <- parse_end_date(
  Sys.getenv("SOFU_FORDRI_END_DATE", unset = shared_end_date),
  "SOFU_FORDRI_END_DATE"
)
eddi_end_date <- parse_end_date(
  Sys.getenv("SOFU_EDDI_END_DATE", unset = shared_end_date),
  "SOFU_EDDI_END_DATE"
)
fordri_start_override <- Sys.getenv("SOFU_FORDRI_START_DATE", unset = "")
fordri_start_date <- if (nzchar(fordri_start_override)) {
  parse_end_date(fordri_start_override, "SOFU_FORDRI_START_DATE")
} else {
  fordri_end_date - fordri_lookback_days + 1L
}
if (fordri_start_date > fordri_end_date) {
  stop("SOFU_FORDRI_START_DATE cannot be after SOFU_FORDRI_END_DATE.", call. = FALSE)
}

focus_boundary <- sf::st_read(bbox_path, quiet = TRUE)
if (!nrow(focus_boundary)) {
  stop("cg_bbox.gpkg contains no features.", call. = FALSE)
}
focus_boundary <- sf::st_make_valid(focus_boundary)
states <- sf::st_make_valid(sf::st_read(states_path, quiet = TRUE))
if (!identical(sf::st_crs(focus_boundary), sf::st_crs(states))) {
  focus_boundary <- sf::st_transform(focus_boundary, sf::st_crs(states))
}
state_boundary <- states[lengths(sf::st_intersects(states, sf::st_union(focus_boundary))) > 0, , drop = FALSE]
if (!nrow(state_boundary)) {
  stop("No state polygons intersect cg_bbox.gpkg.", call. = FALSE)
}

crop_to_states <- function(raster) {
  raster_states <- terra::vect(state_boundary)
  if (!terra::same.crs(raster, raster_states)) {
    raster_states <- terra::project(raster_states, terra::crs(raster))
  }

  terra::mask(terra::crop(raster, raster_states), raster_states)
}

safe_range <- function(raster) {
  values <- terra::values(raster, mat = FALSE)
  values <- values[is.finite(values)]
  if (!length(values)) {
    return(c(0, 1))
  }

  limits <- as.numeric(stats::quantile(values, probs = c(0.02, 0.98), na.rm = TRUE))
  if (!all(is.finite(limits)) || diff(limits) <= 0) {
    limits <- range(values, na.rm = TRUE)
  }
  if (diff(limits) <= 0) {
    limits <- limits + c(-0.5, 0.5)
  }
  limits
}

fordri_breaks <- c(-4, -2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 4)
fordri_labels <- c(
  "Exceptional drought", "Extreme drought", "Severe drought",
  "Moderate drought", "Abnormally dry", "Near normal", "Moist",
  "Very moist", "Extremely moist", "Exceptionally moist"
)
fordri_palette <- c(
  "#760000", "#e60000", "#f46d1f", "#ffd07b", "#fff200",
  "#42d500", "#00ae52", "#27958c", "#1d6d8a", "#123d7a"
)

mask_product_nodata <- function(raster, product) {
  if (!identical(product$id, "fordri")) {
    return(raster)
  }

  # ForDRI uses -9999 as its missing-data sentinel. Mask it before plotting
  # so it cannot influence the color scale or appear as extreme drought.
  terra::ifel(raster <= -9990, NA, raster)
}

write_product_frames <- function(product, stack) {
  product_dir <- file.path(asset_root, product$id)
  dir.create(product_dir, recursive = TRUE, showWarnings = FALSE)

  clipped <- mask_product_nodata(crop_to_states(stack), product)
  frame_dates <- names(clipped)
  range_limits <- if (is.null(product$breaks)) safe_range(clipped) else NULL
  state_vect <- terra::vect(state_boundary)
  focus_vect <- terra::vect(focus_boundary)
  if (!terra::same.crs(clipped, state_vect)) {
    state_vect <- terra::project(state_vect, terra::crs(clipped))
    focus_vect <- terra::project(focus_vect, terra::crs(clipped))
  }

  frames <- lapply(seq_len(terra::nlyr(clipped)), function(index) {
    frame_date <- frame_dates[[index]]
    filename <- sprintf("%s-%s.png", product$id, frame_date)
    filepath <- file.path(product_dir, filename)

    grDevices::png(filepath, width = 1280, height = 860, res = 144)
    tryCatch({
      graphics::par(mar = c(1, 1, 3, 5), bg = "#f8f4ed")
      plot_options <- list(
        x = clipped[[index]],
        col = product$palette,
        axes = FALSE,
        legend = is.null(product$breaks),
        main = sprintf("%s | %s", product$label, frame_date)
      )
      if (is.null(product$breaks)) {
        plot_options$range <- range_limits
        plot_options$plg <- list(title = product$legend)
      } else {
        plot_options$breaks <- product$breaks
      }
      do.call(terra::plot, plot_options)
      if (!is.null(product$breaks)) {
        graphics::legend(
          "right",
          legend = product$classes,
          fill = product$palette,
          title = product$legend,
          bty = "n",
          cex = 0.72,
          xpd = NA
        )
      }
      terra::lines(state_vect, col = "#49636a", lwd = 1.1)
      terra::lines(focus_vect, col = "#17272e", lwd = 2.2)
    }, finally = grDevices::dev.off())

    list(date = frame_date, file = file.path(product$id, filename))
  })

  list(
    id = product$id,
    label = product$label,
    description = product$description,
    legend = product$legend,
    source_window = list(start = as.character(product$start_date), end = as.character(product$end_date)),
    states = as.character(state_boundary$STUSPS),
    frame_count = length(frames),
    range = if (is.null(range_limits)) NULL else as.list(range_limits),
    classes = product$classes,
    frames = frames
  )
}

products <- list(
  list(
    id = "fordri",
    label = "ForDRI",
    description = "Flash Drought Risk Index across the SOFU reporting area.",
    legend = "ForDRI",
    start_date = fordri_start_date,
    end_date = fordri_end_date,
    fetch = function() sofureport::get_fordri_stack(fordri_start_date, fordri_end_date),
    palette = fordri_palette,
    breaks = fordri_breaks,
    classes = stats::setNames(as.list(fordri_labels), seq_along(fordri_labels)),
    legend_options = list()
  ),
  list(
    id = "eddi",
    label = sprintf("EDDI (%s)", eddi_timescale),
    description = "Evaporative Demand Drought Index across the SOFU reporting area.",
    legend = "EDDI",
    start_date = eddi_end_date - days_back + 1L,
    end_date = eddi_end_date,
    fetch = function() sofureport::get_eddi_stack(eddi_end_date - days_back + 1L, eddi_end_date, timescale = eddi_timescale),
    palette = grDevices::hcl.colors(17, "Blue-Red 3", rev = TRUE),
    breaks = NULL,
    classes = NULL,
    legend_options = list()
  )
)

manifest_products <- lapply(products, function(product) {
  message("Building ", product$label, " landing-page frames...")
  tryCatch(
    write_product_frames(product, product$fetch()),
    error = function(error) {
      message("Unable to build ", product$label, ": ", conditionMessage(error))
      list(
        id = product$id,
        label = product$label,
        description = product$description,
        legend = product$legend,
        frame_count = 0L,
        frames = list(),
        error = conditionMessage(error)
      )
    }
  )
})

# A source can lag or temporarily fail. Keep the last good published sequence
# rather than replacing a usable landing-page animation with an empty product.
manifest_products <- lapply(manifest_products, function(product) {
  previous_product <- previous_products[[product$id]]
  has_new_frames <- isTRUE(product$frame_count > 0L)
  has_previous_frames <- !is.null(previous_product) && length(previous_product$frames) > 0L
  if (!has_new_frames && has_previous_frames) {
    previous_product$refresh_error <- if (!is.null(product$error) && nzchar(product$error)) {
      product$error
    } else {
      "No new source frames were available."
    }
    return(previous_product)
  }
  product
})

manifest <- list(
  generated_at = format(Sys.time(), tz = "America/Denver", usetz = TRUE),
  source_windows = list(
    fordri = list(start = as.character(fordri_start_date), end = as.character(fordri_end_date)),
    eddi = list(start = as.character(eddi_end_date - days_back + 1L), end = as.character(eddi_end_date))
  ),
  products = manifest_products
)
jsonlite::write_json(manifest, manifest_path, auto_unbox = TRUE, pretty = TRUE, na = "null")
message("Wrote landing index manifest to: ", manifest_path)
