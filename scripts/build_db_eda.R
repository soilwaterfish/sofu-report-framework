#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(dplyr)
  library(jsonlite)
  library(tibble)
})

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

resolve_first_existing <- function(candidates, dir_ok = FALSE, create_parent = FALSE) {
  candidates <- candidates[!is.na(candidates) & nzchar(candidates)]

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

safe_epoch_to_local_datetime <- function(value, tz = "America/Denver") {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(NA_character_)
  }

  format(
    as.POSIXct(as.numeric(value), origin = "1970-01-01", tz = "UTC"),
    tz = tz,
    usetz = TRUE
  )
}

safe_epoch_to_local_date <- function(value, tz = "America/Denver") {
  if (length(value) == 0 || is.na(value) || !is.finite(value)) {
    return(NA_character_)
  }

  as.character(
    as.Date(
      format(
        as.POSIXct(as.numeric(value), origin = "1970-01-01", tz = "UTC"),
        tz = tz,
        usetz = FALSE
      )
    )
  )
}

read_roster <- function(path) {
  tibble::as_tibble(
    utils::read.csv(
      path,
      check.names = FALSE,
      stringsAsFactors = FALSE,
      fileEncoding = "UTF-8-BOM"
    )
  ) %>%
    mutate(across(where(is.character), trimws)) %>%
    mutate(
      station_id = as.character(.data$station_id),
      station_name = as.character(.data$station_name),
      api = as.character(.data$api)
    ) %>%
    distinct(.data$station_id, .data$api, .keep_all = TRUE)
}

read_dashboard_export <- function(path) {
  if (!file.exists(path)) {
    return(tibble())
  }

  payload <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  stations <- payload$stations %||% list()

  if (!length(stations)) {
    return(tibble())
  }

  tibble(
    station_id = vapply(stations, function(x) as.character(x$id %||% NA_character_), character(1)),
    exported_name = vapply(stations, function(x) as.character(x$name %||% NA_character_), character(1)),
    exported_api = vapply(stations, function(x) as.character(x$api %||% NA_character_), character(1)),
    exported_latest_timestamp = vapply(stations, function(x) as.character(x$latest$timestamp %||% NA_character_), character(1)),
    series_length = vapply(stations, function(x) length(x$series %||% list()), integer(1))
  )
}

raw_metric_map <- list(
  FEMS = c(
    air_temp = "air_temp_set_1.mean",
    humidity = "relative_humidity_set_1.mean",
    sm1 = "soil_moisture_set_1.mean",
    sm2 = "soil_moisture_set_2.mean",
    precip = "precip_accum_set_1.mean"
  ),
  Synoptic = c(
    air_temp = "air_temp_set_1.mean",
    humidity = "relative_humidity_set_1.mean",
    sm1 = "soil_moisture_set_1.mean",
    sm2 = "soil_moisture_set_2.mean",
    precip = "precip_accum_set_1.mean"
  ),
  Zentra = c(
    air_temp = "port_1_atmos_41_f_air_temperature",
    humidity = "port_1_atmos_41_percent_relative_humidity",
    sm1 = "port_2_teros_11_percent_water_content",
    sm2 = "port_3_teros_11_percent_water_content",
    precip = "port_1_atmos_41_in_precipitation"
  )
)

stats_metric_map <- list(
  FEMS = c(
    air_temp = "air_temp_set_1.mean",
    humidity = "relative_humidity_set_1.mean",
    sm1 = "soil_moisture_set_1.mean",
    sm2 = "soil_moisture_set_2.mean",
    precip = "precip_accum_set_1.mean",
    gsi = "gsi",
    kbdi = "kbdi"
  ),
  Synoptic = c(
    air_temp = "air_temp_set_1.mean",
    humidity = "relative_humidity_set_1.mean",
    sm1 = "soil_moisture_set_1.mean",
    sm2 = "soil_moisture_set_2.mean",
    precip = "precip_accum_set_1.mean",
    gsi = "gsi",
    kbdi = "kbdi"
  ),
  Zentra = c(
    air_temp = "port_1_atmos_41_f_air_temperature",
    humidity = "port_1_atmos_41_percent_relative_humidity",
    sm1 = "port_2_teros_11_percent_water_content",
    sm2 = "port_3_teros_11_percent_water_content",
    precip = "precip_increment",
    gsi = "gsi",
    kbdi = "kbdi"
  )
)

render_eda_html <- function(payload_json) {
  paste0(
'<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate" />
  <meta http-equiv="Pragma" content="no-cache" />
  <meta http-equiv="Expires" content="0" />
  <title>SOFU DB EDA</title>
  <style>
    :root {
      --bg: #f5f0e7;
      --panel: #fbf8f2;
      --panel-strong: #fffdf9;
      --text: #24313a;
      --muted: #677883;
      --accent: #295b59;
      --warm: #b95b28;
      --border: rgba(36, 49, 58, 0.12);
      --stale: #f4d7d7;
      --warn: #f2e4bd;
      --good: #dcefdc;
      --shadow: 0 18px 60px rgba(36, 49, 58, 0.08);
      --mono: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      --serif: Georgia, "Times New Roman", serif;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background:
        radial-gradient(circle at top left, rgba(41, 91, 89, 0.08), transparent 28%),
        radial-gradient(circle at top right, rgba(185, 91, 40, 0.08), transparent 24%),
        var(--bg);
      color: var(--text);
      font-family: var(--serif);
    }
    .shell {
      max-width: 1600px;
      margin: 0 auto;
      padding: 28px;
    }
    .hero, .panel {
      background: rgba(255,255,255,0.68);
      backdrop-filter: blur(10px);
      border: 1px solid rgba(255,255,255,0.6);
      border-radius: 28px;
      box-shadow: var(--shadow);
      padding: 24px 26px;
      margin-bottom: 18px;
    }
    .eyebrow {
      margin: 0 0 10px;
      color: var(--warm);
      font-size: 0.82rem;
      text-transform: uppercase;
      letter-spacing: 0.2em;
      font-weight: 700;
    }
    h1, h2, h3, p { margin-top: 0; }
    h1 {
      font-size: clamp(2rem, 4vw, 3.4rem);
      line-height: 0.95;
      margin-bottom: 10px;
    }
    .lead {
      color: var(--muted);
      max-width: 70ch;
      font-size: 1rem;
      line-height: 1.6;
    }
    .summary-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 14px;
      margin-top: 18px;
    }
    .card {
      background: var(--panel-strong);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 16px;
    }
    .card .label {
      font-size: 0.9rem;
      color: var(--muted);
      margin-bottom: 8px;
    }
    .card .value {
      font-size: 2rem;
      font-weight: 700;
      color: var(--accent);
    }
    .controls {
      display: grid;
      grid-template-columns: 1.6fr 1fr 1fr 1fr;
      gap: 12px;
      margin-top: 14px;
    }
    .control {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .control label {
      color: var(--muted);
      font-size: 0.9rem;
    }
    input, select {
      width: 100%;
      border-radius: 14px;
      border: 1px solid var(--border);
      padding: 12px 14px;
      background: #fff;
      color: var(--text);
      font: inherit;
    }
    .panel-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr);
      gap: 18px;
    }
    .table-wrap {
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 18px;
      background: rgba(255,255,255,0.82);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      min-width: 980px;
    }
    th, td {
      padding: 11px 12px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
      font-size: 0.94rem;
    }
    th {
      position: sticky;
      top: 0;
      background: #fff9f0;
      color: var(--warm);
      letter-spacing: 0.08em;
      text-transform: uppercase;
      font-size: 0.72rem;
      z-index: 1;
    }
    tr:hover td {
      background: rgba(41, 91, 89, 0.04);
    }
    tr.selected td {
      background: rgba(41, 91, 89, 0.09);
    }
    tr.stale td {
      background: rgba(185, 91, 40, 0.08);
    }
    .pill {
      display: inline-block;
      border-radius: 999px;
      padding: 4px 10px;
      font-size: 0.76rem;
      font-weight: 700;
      border: 1px solid var(--border);
      background: #fff;
    }
    .pill.good { background: var(--good); }
    .pill.warn { background: var(--warn); }
    .pill.stale { background: var(--stale); }
    .detail-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
    }
    .detail-block {
      background: var(--panel-strong);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 16px;
    }
    .detail-block h3 {
      margin-bottom: 12px;
      font-size: 1rem;
    }
    .kv {
      display: grid;
      grid-template-columns: 140px 1fr;
      gap: 8px 12px;
      font-size: 0.93rem;
      margin-bottom: 6px;
    }
    .kv .k { color: var(--muted); }
    .mini-table {
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 16px;
      background: #fff;
    }
    .mini-table table {
      min-width: 100%;
    }
    .mini-table th, .mini-table td {
      font-size: 0.85rem;
      padding: 8px 9px;
    }
    .muted { color: var(--muted); }
    code {
      font-family: var(--mono);
      font-size: 0.9em;
      background: rgba(36, 49, 58, 0.06);
      padding: 0.15em 0.35em;
      border-radius: 6px;
    }
    @media (max-width: 1180px) {
      .panel-grid, .controls, .detail-grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <p class="eyebrow">Local DB EDA</p>
      <h1>SQLite edge inspector</h1>
      <p class="lead">
        This page is built directly from the current SQLite database and local exports. It is intentionally separate from the website
        so we can inspect what the DB knows versus what the frontend is serving.
      </p>
      <div id="summary-grid" class="summary-grid"></div>
    </section>

    <section class="panel">
      <p class="eyebrow">Filters</p>
      <div class="controls">
        <div class="control">
          <label for="station-search">Search station</label>
          <input id="station-search" type="search" placeholder="Station id or name" />
        </div>
        <div class="control">
          <label for="api-filter">API</label>
          <select id="api-filter">
            <option value="">All</option>
          </select>
        </div>
        <div class="control">
          <label for="freshness-filter">Raw freshness</label>
          <select id="freshness-filter">
            <option value="">All</option>
            <option value="current_enough">Current enough</option>
            <option value="stale">Stale</option>
            <option value="missing">Missing</option>
          </select>
        </div>
        <div class="control">
          <label for="mismatch-filter">Bridge issue</label>
          <select id="mismatch-filter">
            <option value="">All</option>
            <option value="only">Only dashboard mismatches</option>
          </select>
        </div>
      </div>
    </section>

    <section class="panel panel-grid">
      <div>
        <p class="eyebrow">Stations</p>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Station</th>
                <th>API</th>
                <th>Raw Latest</th>
                <th>Dashboard Latest</th>
                <th>Freshness</th>
                <th>Bridge</th>
                <th>Air</th>
                <th>Humidity</th>
                <th>SM1</th>
                <th>SM2</th>
                <th>Precip</th>
                <th>GSI</th>
                <th>KBDI</th>
              </tr>
            </thead>
            <tbody id="station-table-body"></tbody>
          </table>
        </div>
      </div>
      <div>
        <p class="eyebrow">Selection</p>
        <div id="station-detail"></div>
      </div>
    </section>
  </div>

  <script id="db-eda-data" type="application/json">', payload_json, '</script>
  <script>
    const payload = JSON.parse(document.getElementById("db-eda-data").textContent);
    const stations = payload.stations || [];
    let selectedStationId = stations[0]?.station_id || null;

    const els = {
      summary: document.getElementById("summary-grid"),
      tbody: document.getElementById("station-table-body"),
      detail: document.getElementById("station-detail"),
      search: document.getElementById("station-search"),
      api: document.getElementById("api-filter"),
      freshness: document.getElementById("freshness-filter"),
      mismatch: document.getElementById("mismatch-filter")
    };

    function esc(value) {
      return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll(\'"\', "&quot;");
    }

    function pillClass(value) {
      if (value === "current_enough" || value === "yes") return "good";
      if (value === "stale" || value === "mismatch") return "stale";
      return "warn";
    }

    function rawDateField(station, key) {
      return station?.raw?.fields?.[key]?.local_date || "—";
    }

    function statsDateField(station, key) {
      return station?.stats_latest?.[key]?.local_date || "—";
    }

    function fillApiOptions() {
      const apis = [...new Set(stations.map((x) => x.api).filter(Boolean))].sort();
      els.api.innerHTML = \'<option value="">All</option>\' + apis.map((api) => `<option value="${esc(api)}">${esc(api)}</option>`).join("");
    }

    function renderSummary(filtered) {
      const mismatchCount = filtered.filter((x) => x.dashboard?.latest_matches_raw === false).length;
      const staleCount = filtered.filter((x) => x.raw?.freshness_status !== "current_enough").length;
      const missingExport = filtered.filter((x) => !x.dashboard?.exported_latest_timestamp).length;
      const html = [
        ["Stations", filtered.length, "Rows after current filters"],
        ["Raw stale or missing", staleCount, "SQLite DB-side freshness check"],
        ["Dashboard mismatches", mismatchCount, "SQLite latest date differs from dashboard export"],
        ["Missing export", missingExport, "Stations absent from output/latest/data/dashboard.json"],
        ["Generated", esc(payload.generated_at || "—"), "DB EDA page build time"],
        ["DB file updated", esc(payload.db_file_mtime || "—"), "Last modified time for data/sofu.sqlite"],
        ["Dashboard JSON updated", esc(payload.dashboard_json_mtime || "—"), "Last modified time for output/latest/data/dashboard.json"],
        ["Expected current date", esc(payload.expected_current_date || "—"), "Trace target date for freshness"]
      ];
      els.summary.innerHTML = html.map(([label, value, note]) => `
        <article class="card">
          <div class="label">${label}</div>
          <div class="value">${value}</div>
          <div class="muted">${note}</div>
        </article>
      `).join("");
    }

    function currentFilters() {
      return {
        search: els.search.value.trim().toLowerCase(),
        api: els.api.value,
        freshness: els.freshness.value,
        mismatch: els.mismatch.value
      };
    }

    function filterStations() {
      const filters = currentFilters();
      return stations.filter((station) => {
        const hay = `${station.station_id} ${station.station_name}`.toLowerCase();
        if (filters.search && !hay.includes(filters.search)) return false;
        if (filters.api && station.api !== filters.api) return false;
        if (filters.freshness && station.raw?.freshness_status !== filters.freshness) return false;
        if (filters.mismatch === "only" && station.dashboard?.latest_matches_raw !== false) return false;
        return true;
      });
    }

    function renderTable() {
      const filtered = filterStations();
      if (!filtered.find((x) => x.station_id === selectedStationId)) {
        selectedStationId = filtered[0]?.station_id || null;
      }

      renderSummary(filtered);

      els.tbody.innerHTML = filtered.map((station) => {
        const selected = station.station_id === selectedStationId;
        const stale = station.raw?.freshness_status !== "current_enough";
        const mismatch = station.dashboard?.latest_matches_raw === false;
        return `
          <tr data-station-id="${esc(station.station_id)}" class="${selected ? "selected" : ""} ${stale ? "stale" : ""}">
            <td><strong>${esc(station.station_name)}</strong><br><span class="muted"><code>${esc(station.station_id)}</code></span></td>
            <td>${esc(station.api)}</td>
            <td>${esc(station.raw?.latest_local_date || "—")}</td>
            <td>${esc(station.dashboard?.exported_latest_date || "—")}</td>
            <td><span class="pill ${pillClass(station.raw?.freshness_status)}">${esc(station.raw?.freshness_status || "unknown")}</span></td>
            <td><span class="pill ${mismatch ? "stale" : "good"}">${mismatch ? "mismatch" : "yes"}</span></td>
            <td>${esc(rawDateField(station, "air_temp"))}</td>
            <td>${esc(rawDateField(station, "humidity"))}</td>
            <td>${esc(rawDateField(station, "sm1"))}</td>
            <td>${esc(rawDateField(station, "sm2"))}</td>
            <td>${esc(rawDateField(station, "precip"))}</td>
            <td>${esc(statsDateField(station, "gsi"))}</td>
            <td>${esc(statsDateField(station, "kbdi"))}</td>
          </tr>
        `;
      }).join("");

      renderDetail();
    }

    function renderMetricRows(metrics) {
      const rows = Object.entries(metrics || {});
      if (!rows.length) {
        return "<p class=\\"muted\\">No metric rows available.</p>";
      }

      return `
        <div class="mini-table">
          <table>
            <thead>
              <tr>
                <th>Metric</th>
                <th>Date</th>
                <th>Mean</th>
                <th>Source</th>
                <th>Updated</th>
              </tr>
            </thead>
            <tbody>
              ${rows.map(([key, row]) => `
                <tr>
                  <td>${esc(key)}</td>
                  <td>${esc(row.local_date || "—")}</td>
                  <td>${row.value_mean === null || row.value_mean === undefined ? "—" : esc(row.value_mean)}</td>
                  <td>${esc(row.source || "—")}</td>
                  <td>${esc(row.updated_at_local || "—")}</td>
                </tr>
              `).join("")}
            </tbody>
          </table>
        </div>
      `;
    }

    function renderDetail() {
      const station = stations.find((x) => x.station_id === selectedStationId);
      if (!station) {
        els.detail.innerHTML = "<div class=\\"detail-block\\"><p class=\\"muted\\">No station selected.</p></div>";
        return;
      }

      els.detail.innerHTML = `
        <div class="detail-grid">
          <section class="detail-block">
            <h3>${esc(station.station_name)}</h3>
            <div class="kv"><div class="k">Station ID</div><div><code>${esc(station.station_id)}</code></div></div>
            <div class="kv"><div class="k">API</div><div>${esc(station.api)}</div></div>
            <div class="kv"><div class="k">SQLite raw latest</div><div>${esc(station.raw?.latest_local_datetime || "—")}</div></div>
            <div class="kv"><div class="k">Dashboard export latest</div><div>${esc(station.dashboard?.exported_latest_timestamp || "—")}</div></div>
            <div class="kv"><div class="k">Freshness</div><div><span class="pill ${pillClass(station.raw?.freshness_status)}">${esc(station.raw?.freshness_status || "unknown")}</span></div></div>
            <div class="kv"><div class="k">Export matches raw</div><div><span class="pill ${station.dashboard?.latest_matches_raw === false ? "stale" : "good"}">${station.dashboard?.latest_matches_raw === false ? "no" : "yes"}</span></div></div>
            <div class="kv"><div class="k">Series length</div><div>${esc(station.dashboard?.series_length ?? "—")}</div></div>
          </section>
          <section class="detail-block">
            <h3>Raw field latest dates</h3>
            <div class="kv"><div class="k">Air temperature</div><div>${esc(rawDateField(station, "air_temp"))}</div></div>
            <div class="kv"><div class="k">Humidity</div><div>${esc(rawDateField(station, "humidity"))}</div></div>
            <div class="kv"><div class="k">Soil moisture 1</div><div>${esc(rawDateField(station, "sm1"))}</div></div>
            <div class="kv"><div class="k">Soil moisture 2</div><div>${esc(rawDateField(station, "sm2"))}</div></div>
            <div class="kv"><div class="k">Precip</div><div>${esc(rawDateField(station, "precip"))}</div></div>
            <div class="kv"><div class="k">Years</div><div>${esc(station.years_of_data ?? "—")}</div></div>
            <div class="kv"><div class="k">Coordinates</div><div>${esc(station.latitude ?? "—")}, ${esc(station.longitude ?? "—")}</div></div>
          </section>
        </div>
        <section class="detail-block" style="margin-top:14px;">
          <h3>Latest daily stats rows</h3>
          ${renderMetricRows(station.stats_latest)}
        </section>
      `;
    }

    els.tbody.addEventListener("click", (event) => {
      const row = event.target.closest("tr[data-station-id]");
      if (!row) return;
      selectedStationId = row.dataset.stationId;
      renderTable();
    });

    [els.search, els.api, els.freshness, els.mismatch].forEach((node) => {
      node.addEventListener("input", renderTable);
      node.addEventListener("change", renderTable);
    });

    fillApiOptions();
    renderTable();
  </script>
</body>
</html>'
  )
}

db_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DB_PATH", unset = NA_character_),
    "/data/sofu.sqlite",
    "data/sofu.sqlite"
  )
)
zone_csv_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_ZONE_CSV_PATH", unset = NA_character_),
    file.path(dirname(db_path), "main_ExportTable_zones.csv"),
    "data/main_ExportTable_zones.csv"
  )
)
dashboard_json_path <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DASHBOARD_JSON_PATH", unset = NA_character_),
    "output/latest/data/dashboard.json"
  ),
  create_parent = TRUE
)
output_dir <- resolve_first_existing(
  c(
    Sys.getenv("SOFU_DB_EDA_OUTPUT_DIR", unset = NA_character_),
    "output/db-eda"
  ),
  dir_ok = TRUE,
  create_parent = TRUE
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(db_path)) {
  stop("Database not found: ", db_path, call. = FALSE)
}

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
on.exit(DBI::dbDisconnect(con), add = TRUE)

local_today <- as.Date(format(Sys.time(), tz = "America/Denver", usetz = FALSE))
expected_current_date <- local_today - 1L

roster <- read_roster(zone_csv_path)
sites_in_cg <- if (DBI::dbExistsTable(con, "sites_in_cg")) {
  DBI::dbReadTable(con, "sites_in_cg") %>%
    tibble::as_tibble() %>%
    mutate(
      station_id = as.character(.data$station_id),
      station_name = as.character(.data$station_name),
      api = as.character(.data$api),
      latitude = suppressWarnings(as.numeric(.data$latitude)),
      longitude = suppressWarnings(as.numeric(.data$longitude)),
      years_of_data = suppressWarnings(as.numeric(.data$years_of_data))
    )
} else {
  tibble()
}

dashboard_export <- read_dashboard_export(dashboard_json_path)

raw_synoptic <- if (DBI::dbExistsTable(con, "synoptic_fems_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(date) AS raw_max_epoch,",
      "MAX(CASE WHEN \"air_temp_set_1.mean\" IS NOT NULL THEN date END) AS air_temp_epoch,",
      "MAX(CASE WHEN \"relative_humidity_set_1.mean\" IS NOT NULL THEN date END) AS humidity_epoch,",
      "MAX(CASE WHEN \"soil_moisture_set_1.mean\" IS NOT NULL THEN date END) AS sm1_epoch,",
      "MAX(CASE WHEN \"soil_moisture_set_2.mean\" IS NOT NULL THEN date END) AS sm2_epoch,",
      "MAX(CASE WHEN \"precip_accum_set_1.mean\" IS NOT NULL THEN date END) AS precip_epoch",
      "FROM synoptic_fems_data",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(station_id = as.character(.data$station_id))
} else {
  tibble()
}

raw_zentra <- if (DBI::dbExistsTable(con, "zentracloud_data")) {
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT CAST(station_id AS TEXT) AS station_id,",
      "MAX(date) AS raw_max_epoch,",
      "MAX(CASE WHEN port_1_atmos_41_f_air_temperature IS NOT NULL THEN date END) AS air_temp_epoch,",
      "MAX(CASE WHEN port_1_atmos_41_percent_relative_humidity IS NOT NULL THEN date END) AS humidity_epoch,",
      "MAX(CASE WHEN port_2_teros_11_percent_water_content IS NOT NULL THEN date END) AS sm1_epoch,",
      "MAX(CASE WHEN port_3_teros_11_percent_water_content IS NOT NULL THEN date END) AS sm2_epoch,",
      "MAX(CASE WHEN port_1_atmos_41_in_precipitation IS NOT NULL THEN date END) AS precip_epoch",
      "FROM zentracloud_data",
      "GROUP BY station_id"
    )
  ) %>%
    mutate(station_id = as.character(.data$station_id))
} else {
  tibble()
}

read_latest_metric_rows <- function(con, table_name, station_ids = character(), metric_names = character()) {
  if (!DBI::dbExistsTable(con, table_name)) {
    return(tibble())
  }

  where_clauses <- character()

  station_ids <- unique(as.character(station_ids))
  station_ids <- station_ids[!is.na(station_ids) & nzchar(station_ids)]
  if (length(station_ids)) {
    where_clauses <- c(
      where_clauses,
      sprintf(
        "CAST(station_id AS TEXT) IN (%s)",
        paste(DBI::dbQuoteString(con, station_ids), collapse = ", ")
      )
    )
  }

  metric_names <- unique(as.character(metric_names))
  metric_names <- metric_names[!is.na(metric_names) & nzchar(metric_names)]
  if (length(metric_names)) {
    where_clauses <- c(
      where_clauses,
      sprintf(
        "metric_name IN (%s)",
        paste(DBI::dbQuoteString(con, metric_names), collapse = ", ")
      )
    )
  }

  where_sql <- if (length(where_clauses)) {
    paste("WHERE", paste(where_clauses, collapse = " AND "))
  } else {
    ""
  }

  DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "WITH ranked AS (",
        "  SELECT",
        "    CAST(station_id AS TEXT) AS station_id,",
        "    source,",
        "    metric_name,",
        "    local_date,",
        "    value_min,",
        "    value_max,",
        "    value_mean,",
        "    n_obs,",
        "    updated_at_utc,",
        "    ROW_NUMBER() OVER (",
        "      PARTITION BY CAST(station_id AS TEXT), metric_name",
        "      ORDER BY local_date DESC, updated_at_utc DESC",
        "    ) AS rn",
        "  FROM %s",
        "  %s",
        ")",
        "SELECT station_id, source, metric_name, local_date, value_min, value_max, value_mean, n_obs, updated_at_utc",
        "FROM ranked",
        "WHERE rn = 1"
      ),
      table_name,
      where_sql
    )
  ) %>%
    mutate(
      station_id = as.character(.data$station_id),
      local_date = as.Date(as.numeric(.data$local_date), origin = "1970-01-01"),
      updated_at_local = vapply(.data$updated_at_utc, safe_epoch_to_local_datetime, character(1))
    )
}

all_station_ids <- unique(as.character(roster$station_id))
all_metric_names <- unique(unname(unlist(stats_metric_map, use.names = FALSE)))

latest_metric_rows <- bind_rows(
  read_latest_metric_rows(
    con,
    "synoptic_fems_daily_stats",
    station_ids = all_station_ids,
    metric_names = all_metric_names
  ),
  read_latest_metric_rows(
    con,
    "zentracloud_daily_stats",
    station_ids = all_station_ids,
    metric_names = all_metric_names
  )
)

station_records <- lapply(seq_len(nrow(roster)), function(i) {
  row <- roster[i, , drop = FALSE]
  station_id <- as.character(row$station_id[[1]])
  api <- as.character(row$api[[1]])

  site_row <- sites_in_cg %>% filter(.data$station_id == .env$station_id) %>% slice(1L)
  export_row <- dashboard_export %>% filter(.data$station_id == .env$station_id) %>% slice(1L)
  raw_row <- if (api %in% c("FEMS", "Synoptic")) {
    raw_synoptic %>% filter(.data$station_id == .env$station_id) %>% slice(1L)
  } else {
    raw_zentra %>% filter(.data$station_id == .env$station_id) %>% slice(1L)
  }

  raw_fields <- raw_metric_map[[api]]
  stats_fields <- stats_metric_map[[api]]

  raw_info <- list(
    latest_local_datetime = if (nrow(raw_row)) safe_epoch_to_local_datetime(raw_row$raw_max_epoch[[1]]) else NA_character_,
    latest_local_date = if (nrow(raw_row)) safe_epoch_to_local_date(raw_row$raw_max_epoch[[1]]) else NA_character_,
    freshness_status = if (!nrow(raw_row) || is.na(raw_row$raw_max_epoch[[1]])) {
      "missing"
    } else if (safe_epoch_to_local_date(raw_row$raw_max_epoch[[1]]) >= as.character(expected_current_date)) {
      "current_enough"
    } else {
      "stale"
    },
    fields = lapply(names(raw_fields), function(key) {
      epoch_col <- paste0(key, "_epoch")
      list(
        local_datetime = if (nrow(raw_row) && epoch_col %in% names(raw_row)) safe_epoch_to_local_datetime(raw_row[[epoch_col]][[1]]) else NA_character_,
        local_date = if (nrow(raw_row) && epoch_col %in% names(raw_row)) safe_epoch_to_local_date(raw_row[[epoch_col]][[1]]) else NA_character_
      )
    })
  )
  names(raw_info$fields) <- names(raw_fields)

  stat_rows <- latest_metric_rows %>%
    filter(.data$station_id == .env$station_id, .data$metric_name %in% unname(stats_fields))

  stats_latest <- lapply(names(stats_fields), function(key) {
    metric_name <- unname(stats_fields[[key]])
    metric_row <- stat_rows %>% filter(.data$metric_name == metric_name) %>% slice(1L)
    if (!nrow(metric_row)) {
      return(NULL)
    }
    list(
      metric_name = metric_name,
      local_date = as.character(metric_row$local_date[[1]]),
      value_min = metric_row$value_min[[1]],
      value_max = metric_row$value_max[[1]],
      value_mean = metric_row$value_mean[[1]],
      n_obs = metric_row$n_obs[[1]],
      source = as.character(metric_row$source[[1]]),
      updated_at_local = as.character(metric_row$updated_at_local[[1]])
    )
  })
  names(stats_latest) <- names(stats_fields)
  stats_latest <- stats_latest[!vapply(stats_latest, is.null, logical(1))]

  exported_latest_date <- if (nrow(export_row)) as.character(as.Date(substr(export_row$exported_latest_timestamp[[1]], 1, 10))) else NA_character_
  raw_latest_date <- raw_info$latest_local_date

  list(
    station_id = station_id,
    station_name = as.character(row$station_name[[1]]),
    api = api,
    latitude = if (nrow(site_row)) site_row$latitude[[1]] else NA_real_,
    longitude = if (nrow(site_row)) site_row$longitude[[1]] else NA_real_,
    years_of_data = if (nrow(site_row) && "years_of_data" %in% names(site_row)) site_row$years_of_data[[1]] else NA_real_,
    raw = raw_info,
    dashboard = list(
      exported_name = if (nrow(export_row)) as.character(export_row$exported_name[[1]]) else NA_character_,
      exported_api = if (nrow(export_row)) as.character(export_row$exported_api[[1]]) else NA_character_,
      exported_latest_timestamp = if (nrow(export_row)) as.character(export_row$exported_latest_timestamp[[1]]) else NA_character_,
      exported_latest_date = exported_latest_date,
      series_length = if (nrow(export_row)) as.integer(export_row$series_length[[1]]) else NA_integer_,
      latest_matches_raw = if (!is.na(exported_latest_date) && !is.na(raw_latest_date)) identical(exported_latest_date, raw_latest_date) else NA
    ),
    stats_latest = stats_latest
  )
})

summary <- list(
  station_count = length(station_records),
  current_enough_raw = sum(vapply(station_records, function(x) identical(x$raw$freshness_status, "current_enough"), logical(1))),
  stale_or_missing_raw = sum(vapply(station_records, function(x) !identical(x$raw$freshness_status, "current_enough"), logical(1))),
  dashboard_mismatch_count = sum(vapply(station_records, function(x) identical(x$dashboard$latest_matches_raw, FALSE), logical(1))),
  missing_dashboard_timestamp = sum(vapply(station_records, function(x) is.na(x$dashboard$exported_latest_timestamp) || !nzchar(x$dashboard$exported_latest_timestamp), logical(1)))
)

payload <- list(
  generated_at = format(Sys.time(), tz = "America/Denver", usetz = TRUE),
  expected_current_date = as.character(expected_current_date),
  db_path = normalizePath(db_path, winslash = "/", mustWork = FALSE),
  db_file_mtime = if (file.exists(db_path)) format(file.info(db_path)$mtime, tz = "America/Denver", usetz = TRUE) else NA_character_,
  dashboard_json_mtime = if (file.exists(dashboard_json_path)) format(file.info(dashboard_json_path)$mtime, tz = "America/Denver", usetz = TRUE) else NA_character_,
  summary = summary,
  stations = station_records
)

payload_json <- jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null", na = "null", digits = 8)
out_html <- file.path(output_dir, "index.html")
writeLines(render_eda_html(payload_json), out_html)

cat("Wrote DB EDA page to:", out_html, "\n")
