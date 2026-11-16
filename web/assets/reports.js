function resolveReportsVersion() {
  const bodyVersion = document.body?.dataset?.build;
  if (bodyVersion) {
    return bodyVersion;
  }

  const script =
    document.currentScript ||
    Array.from(document.scripts).find((node) => /assets\/reports\.js(?:\?|$)/.test(node.src));

  if (!script?.src) {
    return "";
  }

  try {
    return new URL(script.src, window.location.href).searchParams.get("v") || "";
  } catch {
    return "";
  }
}

const REPORTS_VERSION = resolveReportsVersion();
const REPORTS_PATHS = [
  "data/reports.json",
  "../output/latest/data/reports.json",
  "output/latest/data/reports.json"
].map((path) => `${path}${REPORTS_VERSION ? `?v=${REPORTS_VERSION}` : ""}`);
const stationSeriesCache = new Map();

async function loadReportsData() {
  let lastError = null;

  for (const path of REPORTS_PATHS) {
    try {
      const response = await fetch(path, { cache: "no-store" });
      if (!response.ok) {
        throw new Error(`Failed to load ${path}`);
      }
      return await response.json();
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError ?? new Error("Unable to load reports data.");
}

function reportsPage() {
  return document.body?.dataset?.page || "";
}

function formatReportTimestamp(value) {
  if (!value) return "Unavailable";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return String(value);
  return parsed.toLocaleString([], {
    timeZone: "America/Denver",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit"
  });
}

function formatPrecipValue(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) {
    return "&ndash;";
  }
  return Number(value).toFixed(2);
}

function formatSignedValue(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) {
    return "&ndash;";
  }

  const numeric = Number(value);
  const prefix = numeric > 0 ? "+" : "";
  return `${prefix}${numeric.toFixed(2)}`;
}

function soilChangeClass(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || Math.abs(numeric) <= 0.5) return "stable";
  return numeric > 0 ? "increase" : "decrease";
}

function formatDatasetValue(datasetKey, value) {
  if (datasetKey === "precip") {
    return formatPrecipValue(value);
  }

  if (value === null || value === undefined || Number.isNaN(Number(value))) {
    return "&ndash;";
  }

  const rawDirection = datasetKey === "gsi" && Math.abs(Number(value)) > .005 ? Number(value) > 0 ? "increase" : "decrease" : soilChangeClass(value);
  let direction = rawDirection;
  if (datasetKey === "kbdi" && direction !== "stable") direction = direction === "increase" ? "decrease" : "increase";
  const icon = rawDirection === "increase" ? "&uarr;" : rawDirection === "decrease" ? "&darr;" : "&rarr;";
  return `<span class="report-change report-change-${direction}"><span aria-hidden="true">${icon}</span>${formatSignedValue(value)}</span>`;
}

function rowDetailMarkup(row, datasetKey, datasetLabel) {
  const totals = row?.totals || {};
  const label = datasetKey === "precip" ? "Precipitation total" : `Net ${datasetLabel.toLowerCase()} change`;
  const stationId = encodeURIComponent(row.station_id || "");

  return `
    <aside class="report-row-detail" aria-live="polite">
      <div>
        <p class="panel-label">Station detail</p>
        <h3>${escapeHtml(row.station_name || row.station_id || "Station")}</h3>
        <p>${escapeHtml(row.info || row.api || "Source")} &middot; ${escapeHtml(formatFreshnessStatus(row.freshness_status, row.days_stale))} &middot; ${escapeHtml(formatReportTimestamp(rowTimestampLabel(row)))}</p>
      </div>
      <div class="report-detail-values">
        ${["hours_24", "days_2", "days_7", "days_30"].map((key) => `
          <span><small>${key === "hours_24" ? "24 hr" : key.replace("days_", "") + " day"}</small><strong>${formatDatasetValue(datasetKey, totals[key])}</strong>${window.SofuRates?.rateMarkup(row, key, datasetKey, true) || ""}</span>
        `).join("")}
      </div>
      <div class="report-detail-actions">
        <span>${escapeHtml(label)}</span>
        <a class="button button-secondary report-dashboard-link" href="dashboard.html?station=${stationId}">Open in dashboard</a>
      </div>
    </aside>
  `;
}

async function loadStationSeries(stationId) {
  if (stationSeriesCache.has(stationId)) return stationSeriesCache.get(stationId);

  const path = `data/stations/${encodeURIComponent(stationId)}.json${REPORTS_VERSION ? `?v=${REPORTS_VERSION}` : ""}`;
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`Unable to load series for ${stationId}.`);
  const payload = await response.json();
  stationSeriesCache.set(stationId, payload);
  return payload;
}

function localDateFromTimestamp(timestamp) {
  return String(timestamp || "").slice(0, 10);
}

function buildReportChartData(series, datasetKey) {
  const metricKey = datasetKey === "precip" ? "precip_accum" : datasetKey;
  const records = (Array.isArray(series) ? series : [])
    .filter((point) => point?.timestamp && point[metricKey] != null && Number.isFinite(Number(point[metricKey])));
  if (!records.length) return [];

  const newestDate = localDateFromTimestamp(records[records.length - 1].timestamp);
  const start = new Date(`${newestDate}T00:00:00Z`);
  start.setUTCDate(start.getUTCDate() - 29);
  const startDate = start.toISOString().slice(0, 10);
  const byDay = new Map();

  records.forEach((point) => {
    const date = localDateFromTimestamp(point.timestamp);
    if (date < startDate || date > newestDate) return;
    if (!byDay.has(date)) byDay.set(date, []);
    byDay.get(date).push(point);
  });

  const dailyPoints = Array.from(byDay.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, points]) => {
      const recent = points.filter((point) => point.resolution === "recent");
      const daily = points.filter((point) => point.resolution === "daily");
      const selected = recent.length ? recent : daily;
      const values = selected.map((point) => Number(point[metricKey])).filter(Number.isFinite);
      const value = datasetKey === "precip"
        ? values.reduce((sum, entry) => sum + entry, 0)
        : values.reduce((sum, entry) => sum + entry, 0) / values.length;
      return { date, value };
    })
    .filter((point) => Number.isFinite(point.value));

  if (datasetKey !== "precip") return dailyPoints;

  let cumulative = 0;
  return dailyPoints.map((point) => {
    cumulative += point.value;
    return { ...point, cumulative };
  });
}

function formatChartDate(date) {
  return new Date(`${date}T12:00:00Z`).toLocaleDateString([], {
    timeZone: "America/Denver",
    month: "short",
    day: "numeric"
  });
}

function renderReportSvgChart(points, datasetKey) {
  const width = 760;
  const height = 210;
  const padding = { top: 18, right: datasetKey === "precip" ? 50 : 20, bottom: 34, left: 48 };
  const innerWidth = width - padding.left - padding.right;
  const innerHeight = height - padding.top - padding.bottom;
  const values = points.map((point) => point.value);
  const minValue = datasetKey === "precip" ? 0 : Math.min(...values);
  const maxValue = Math.max(...values);
  const spread = Math.max(maxValue - minValue, datasetKey === "precip" ? 0.1 : 1);
  const lower = datasetKey === "precip" ? 0 : minValue - spread * 0.12;
  const upper = maxValue + spread * 0.12;
  const x = (index) => padding.left + (points.length === 1 ? innerWidth / 2 : (index / (points.length - 1)) * innerWidth);
  const y = (value) => padding.top + ((upper - value) / (upper - lower)) * innerHeight;
  const color = datasetKey === "precip" ? "#3f7b9b" : datasetKey === "soil_moisture_1" ? "#3e756d" : "#b26742";
  const label = datasetKey === "precip" ? "Daily precip (in)" : datasetKey === "soil_moisture_1" ? "Soil moisture 1 (%)" : "Soil moisture 2 (%)";
  const cumulativeMax = datasetKey === "precip" ? Math.max(...points.map((point) => point.cumulative || 0), 0.1) : null;
  const cumulativeY = (value) => padding.top + ((cumulativeMax - value) / cumulativeMax) * innerHeight;
  const path = points.map((point, index) => `${index ? "L" : "M"}${x(index).toFixed(1)},${y(point.value).toFixed(1)}`).join(" ");
  const cumulativePath = datasetKey === "precip"
    ? points.map((point, index) => `${index ? "L" : "M"}${x(index).toFixed(1)},${cumulativeY(point.cumulative).toFixed(1)}`).join(" ")
    : "";
  const ticks = [0, 0.5, 1].map((position) => lower + (upper - lower) * position);
  const tickIndexes = [0, Math.floor((points.length - 1) / 2), points.length - 1];

  const marks = datasetKey === "precip"
    ? `${points.map((point, index) => {
      const barWidth = Math.max(3, innerWidth / Math.max(points.length, 1) - 4);
      const barHeight = Math.max(1, padding.top + innerHeight - y(point.value));
      return `<rect x="${(x(index) - barWidth / 2).toFixed(1)}" y="${y(point.value).toFixed(1)}" width="${barWidth.toFixed(1)}" height="${barHeight.toFixed(1)}" rx="2"><title>${formatChartDate(point.date)}: ${point.value.toFixed(2)} in</title></rect>`;
    }).join("")}<path class="report-cumulative-line" d="${cumulativePath}"/><g class="report-cumulative-points">${points.map((point, index) => `<circle cx="${x(index).toFixed(1)}" cy="${cumulativeY(point.cumulative).toFixed(1)}" r="2.1"><title>${formatChartDate(point.date)}: ${point.cumulative.toFixed(2)} in accumulated</title></circle>`).join("")}</g>`
    : `<path class="report-series-line" d="${path}"/><g class="report-series-points">${points.map((point, index) => `<circle cx="${x(index).toFixed(1)}" cy="${y(point.value).toFixed(1)}" r="2.8"><title>${formatChartDate(point.date)}: ${point.value.toFixed(2)}%</title></circle>`).join("")}</g>`;

  return `
    <svg class="report-detail-chart-svg report-chart-${datasetKey}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${label} over the last 30 days">
      ${ticks.map((tick) => `<g><line x1="${padding.left}" x2="${width - padding.right}" y1="${y(tick).toFixed(1)}" y2="${y(tick).toFixed(1)}"/><text x="${padding.left - 8}" y="${(y(tick) + 4).toFixed(1)}">${tick.toFixed(datasetKey === "precip" ? 1 : 0)}</text></g>`).join("")}
      <line class="report-chart-axis" x1="${padding.left}" x2="${width - padding.right}" y1="${padding.top + innerHeight}" y2="${padding.top + innerHeight}"/>
      ${datasetKey === "precip" ? [0, 0.5, 1].map((position) => { const value = cumulativeMax * position; return `<text class="report-chart-right-label" x="${width - padding.right + 8}" y="${(cumulativeY(value) + 4).toFixed(1)}">${value.toFixed(1)}</text>`; }).join("") : ""}
      <g class="report-chart-marks">${marks}</g>
      ${tickIndexes.map((index) => `<text class="report-chart-date" x="${x(index).toFixed(1)}" y="${height - 10}" text-anchor="middle">${formatChartDate(points[index].date)}</text>`).join("")}
    </svg>
  `;
}

async function renderSelectedStationChart(slot, row, datasetKey, datasetLabel) {
  const chartSlot = slot.querySelector(".report-detail-chart-slot");
  if (!chartSlot) return;

  try {
    if (datasetKey !== "precip" && window.SofuRates) {
      try {
        const current = await window.SofuRates.load(row.station_id);
        if (!chartSlot.isConnected) return;
        const snap = window.SofuRates.snapshot(current, datasetKey);
        const todayMarkup = snap ? `<div class="today-observations"><span class="panel-label">${snap.isToday ? "Today so far · provisional" : `Latest observed day · ${escapeHtml(snap.day)}`}</span><strong>Latest ${formatPrecipValue(snap.latest)}</strong><span>Minimum ${formatPrecipValue(snap.min)} · Mean ${formatPrecipValue(snap.mean)} · Maximum ${formatPrecipValue(snap.max)} · ${snap.samples} readings</span><small>${escapeHtml(formatReportTimestamp(snap.timestamp))}</small></div>` : "";
        chartSlot.innerHTML = `${todayMarkup}<div class="report-chart-heading"><span>Hourly observations · Mountain time</span><strong>${escapeHtml(datasetLabel)}</strong></div>
          <label>Observation window <select data-report-chart-window><option value="24">24 hour</option><option value="48">2 day</option><option value="168">7 day</option><option value="720" selected>30 day</option></select></label><div class="rates-observation-chart"></div>`;
        const plot = chartSlot.querySelector(".rates-observation-chart");
        window.SofuRates.renderPlot(plot, current, datasetKey);
        chartSlot.querySelector("[data-report-chart-window]").addEventListener("change", event => window.SofuRates.renderPlot(plot, current, datasetKey, Number(event.target.value)));
        return;
      } catch { /* Older exports retain their existing daily detail chart. */ }
    }
    const station = await loadStationSeries(row.station_id);
    if (!chartSlot.isConnected) return;
    const points = buildReportChartData(station.series, datasetKey);
    if (!points.length) {
      chartSlot.innerHTML = `<p class="report-chart-empty">No usable 30-day ${escapeHtml(datasetLabel.toLowerCase())} series is available for this station.</p>`;
      return;
    }

    chartSlot.innerHTML = `
      <div class="report-chart-heading">
        <span>${datasetKey === "precip" ? "Bars: daily precip | Line: 30-day accumulation" : "Last 30 days"}</span>
        <strong>${escapeHtml(datasetLabel)}</strong>
      </div>
      ${renderReportSvgChart(points, datasetKey)}
    `;
  } catch (error) {
    chartSlot.innerHTML = `<p class="report-chart-empty">The station detail is available, but its chart series could not be loaded.</p>`;
  }
}

function formatFreshnessStatus(status, daysStale) {
  if (status === "stale") {
    if (daysStale === null || daysStale === undefined || Number.isNaN(Number(daysStale))) {
      return "Stale";
    }
    return `Stale (${Number(daysStale)}d)`;
  }

  if (status === "current") {
    return "Current";
  }

  return "Unknown";
}

function rowTimestampLabel(row) {
  return row?.as_of_timestamp || row?.latest_timestamp || row?.station_latest_timestamp || null;
}

function formatCount(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) {
    return "0";
  }
  return String(Number(value));
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;");
}

function readZoneSlug() {
  const params = new URLSearchParams(window.location.search);
  return params.get("zone") || "";
}

function renderEmptyState(target, title, message) {
  target.innerHTML = `
    <section class="info-card">
      <p class="section-label">Reports</p>
      <h1>${escapeHtml(title)}</h1>
      <p>${escapeHtml(message)}</p>
    </section>
  `;
}

function renderReportsIndex(data) {
  const overview = document.getElementById("reports-overview");
  const grid = document.getElementById("reports-zone-grid");
  const zones = Array.isArray(data?.zones) ? data.zones : [];

  const sourceTotals = zones.reduce(
    (acc, zone) => {
      acc.zones += 1;
      acc.stations += Number(zone.station_count || 0);
      acc.fems += Number(zone.source_counts?.FEMS || 0);
      acc.synoptic += Number(zone.source_counts?.Synoptic || 0);
      acc.zentra += Number(zone.source_counts?.Zentra || 0);
      return acc;
    },
    { zones: 0, stations: 0, fems: 0, synoptic: 0, zentra: 0 }
  );

  overview.innerHTML = `
    <article class="metric-card"><span>Zones</span><strong>${formatCount(sourceTotals.zones)}</strong><span>Report groups available from the roster</span></article>
    <article class="metric-card"><span>Stations</span><strong>${formatCount(sourceTotals.stations)}</strong><span>Stations represented across all zone pages</span></article>
    <article class="metric-card"><span>RAWS</span><strong>${formatCount(sourceTotals.fems)}</strong><span>FEMS stations included in zone summaries</span></article>
    <article class="metric-card"><span>Synoptic Soil</span><strong>${formatCount(sourceTotals.synoptic)}</strong><span>Synoptic stations included in zone summaries</span></article>
    <article class="metric-card"><span>Zentra</span><strong>${formatCount(sourceTotals.zentra)}</strong><span>Zentra stations included in zone summaries</span></article>
  `;

  if (!zones.length) {
    grid.innerHTML = `
      <article class="info-card">
        <p class="section-label">No zones</p>
        <h2>Nothing to render yet</h2>
        <p>Build the site once to generate <code>reports.json</code>, then iterate on the frontend from there.</p>
      </article>
    `;
    return;
  }

  grid.innerHTML = zones
    .map(
      (zone) => {
        const peakPrecip = Number(zone.precip?.summary?.hours_24?.max || 0);
        const precipTone = peakPrecip >= 0.5 ? "report-zone-wet" : peakPrecip > 0 ? "report-zone-damp" : "report-zone-dry";
        return `
        <article class="info-card report-card report-zone-card ${precipTone}">
          <p class="section-label">Zone report</p>
          <h2>${escapeHtml(zone.label)}</h2>
          <p class="report-blurb">Latest precip summary built from ${escapeHtml(formatReportTimestamp(zone.latest_timestamp || data.generated_at))}.</p>
          <div class="report-activity">
            <span>Peak 24-hour precip</span>
            <strong>${formatPrecipValue(peakPrecip)} <small>in</small></strong>
          </div>
          <div class="report-chip-row">
            <span class="report-chip">${formatCount(zone.station_count)} stations</span>
            <span class="report-chip">${formatCount(zone.source_counts?.FEMS)} RAWS</span>
            <span class="report-chip">${formatCount(zone.source_counts?.Synoptic)} Synoptic Soil</span>
            <span class="report-chip">${formatCount(zone.source_counts?.Zentra)} Zentra</span>
          </div>
          <a class="button button-secondary report-link" href="report-zone.html?zone=${encodeURIComponent(zone.slug)}">Open report</a>
        </article>
      `;
      }
    )
    .join("");
}

function renderZoneReport(data) {
  const root = document.getElementById("zone-report-root");
  const zones = Array.isArray(data?.zones) ? data.zones : [];
  const zoneSlug = readZoneSlug();
  const zone = zones.find((entry) => entry.slug === zoneSlug || entry.id === zoneSlug || entry.label === zoneSlug);

  if (!zone) {
    renderEmptyState(root, "Zone not found", "This zone summary was not present in the latest reports payload.");
    return;
  }

  const datasets = {
    precip: {
      label: "Precip",
      panelLabel: "Precipitation",
      title: "Rolling totals by station",
      note: "Stations are hidden here when the precipitation windows are entirely blank in the current source payload.",
      data: zone.precip || {},
      formatter: formatPrecipValue
    },
    soil_moisture_1: {
      label: "Soil Moisture 1",
      panelLabel: "Soil Moisture",
      title: "Depth 1 gains and losses by station",
      note: "Values show net gain or loss over each lookback window using the latest available records in the source feed.",
      data: zone.soil_moisture_1 || {},
      formatter: formatSignedValue
    },
    soil_moisture_2: {
      label: "Soil Moisture 2",
      panelLabel: "Soil Moisture",
      title: "Depth 2 gains and losses by station",
      note: "Values show net gain or loss over each lookback window using the latest available records in the source feed.",
      data: zone.soil_moisture_2 || {},
      formatter: formatSignedValue
    }
  };

  for (const [key, label, unit] of [["air_temp", "Air temperature", "F"], ["humidity", "Humidity", "percentage points"], ["wind_speed", "Wind speed", "mph"], ["gsi", "GSI", "GSI units"], ["kbdi", "KBDI", "KBDI units"]]) {
    datasets[key] = { label, panelLabel: "Weather & fire indices", title: `${label} changes by station`,
      note: `Net changes in ${unit}. Fitted rates describe the direction across the window; they can differ from endpoint changes.`, data: zone[key] || {} };
  }

  let searchText = "";
  let currentOnly = false;
  let sortKey = "station_name";
  let ascending = true;
  let selectedStationId = null;

  function filteredReportRows(dataset) {
    return (dataset.data?.rows || []).filter(row =>
      (!currentOnly || row.freshness_status === "current") &&
      `${row.station_id} ${row.station_name} ${row.api}`.toLowerCase().includes(searchText)
    ).slice().sort((left, right) => {
      const a = sortKey.startsWith("days_") || sortKey === "hours_24" ? left.totals?.[sortKey] : left[sortKey];
      const b = sortKey.startsWith("days_") || sortKey === "hours_24" ? right.totals?.[sortKey] : right[sortKey];
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      const comparison = typeof a === "number" ? a - b : String(a).localeCompare(String(b));
      return (ascending ? comparison : -comparison) || String(left.station_id).localeCompare(String(right.station_id));
    });
  }

  function sortHeader(key, label) {
    return `<th aria-sort="${sortKey === key ? ascending ? "ascending" : "descending" : "none"}"><button class="report-sort-button" data-report-sort="${key}" type="button">${label} ${sortKey === key ? ascending ? "↑" : "↓" : "↕"}</button></th>`;
  }

  function renderDatasetTable(datasetKey) {
    const dataset = datasets[datasetKey] || datasets.precip;
    const rows = filteredReportRows(dataset);
    const summary = dataset.data?.summary || {};
    const valueFormatter = (value) => formatDatasetValue(datasetKey, value);

    const tableRows = rows.length
      ? rows
          .map(
            (row) => `
              <tr class="report-data-row ${row.freshness_status === "stale" ? "report-row-stale" : ""}" data-report-row="${escapeHtml(row.station_id)}" tabindex="0" aria-expanded="false" aria-label="Show details for ${escapeHtml(row.station_name || row.station_id)}">
                <td>${escapeHtml(row.station_id)}</td>
                <td>${escapeHtml(row.station_name)}</td>
                <td>${escapeHtml(row.info || row.api || "")}</td>
                <td>${escapeHtml(formatReportTimestamp(rowTimestampLabel(row)))}</td>
                <td>${escapeHtml(formatFreshnessStatus(row.freshness_status, row.days_stale))}</td>
                ${["hours_24", "days_2", "days_7", "days_30"].map(key => `<td>${valueFormatter(row.totals?.[key])}${window.SofuRates?.rateMarkup(row, key, datasetKey) || ""}</td>`).join("")}
              </tr>
            `
          )
          .join("")
      : `
          <tr>
            <td colspan="9">No stations in this zone currently expose enough data for this table.</td>
          </tr>
        `;

    const summaryRows = rows.length
      ? [
          ["Maximum", summary.hours_24?.max, summary.days_2?.max, summary.days_7?.max, summary.days_30?.max],
          ["Zone average", summary.hours_24?.average, summary.days_2?.average, summary.days_7?.average, summary.days_30?.average],
          ["Minimum", summary.hours_24?.min, summary.days_2?.min, summary.days_7?.min, summary.days_30?.min]
        ]
          .map(
            ([label, d1, d2, d7, d30]) => `
              <tr class="report-summary-row">
                <th>${escapeHtml(label)}</th>
                <td></td>
                <td></td>
                <td></td>
                <td></td>
                <td>${valueFormatter(d1)}</td>
                <td>${valueFormatter(d2)}</td>
                <td>${valueFormatter(d7)}</td>
                <td>${valueFormatter(d30)}</td>
              </tr>
            `
          )
          .join("")
      : "";

    return `
      <div class="panel-top">
        <div>
          <p class="panel-label">${escapeHtml(dataset.panelLabel)}</p>
          <h2>${escapeHtml(dataset.title)}</h2>
        </div>
        <p class="panel-note">${escapeHtml(dataset.note)}</p>
      </div>
      <p class="panel-note" role="status">${rows.length} of ${dataset.data?.rows?.length || 0} stations shown. Zone summary statistics below describe all stations. ${datasetKey === "precip" ? "Rates show average accumulation in inches/day." : "Fitted rates include their variable-specific units."} Rates require 80% hourly coverage and span; low-fit trends are labeled variable.</p>
      <div class="report-table-wrap">
        <table class="report-table report-precip-table">
          <thead>
            <tr>
              ${sortHeader("station_id", "Station ID")}
              ${sortHeader("station_name", "Station")}
              <th>Info</th>
              <th>As of</th>
              <th>Status</th>
              ${sortHeader("hours_24", "24 hour")}
              ${sortHeader("days_2", "2 day")}
              ${sortHeader("days_7", "7 day")}
              ${sortHeader("days_30", "30 day")}
            </tr>
          </thead>
          <tbody>
            ${tableRows}
            ${summaryRows}
          </tbody>
        </table>
      </div>
    `;
  }

  function renderTabButtons(datasetKey) {
    return Object.entries(datasets)
      .map(
        ([key, value]) => `
          <button class="report-tab-button${key === datasetKey ? " active" : ""}" type="button" data-report-tab="${escapeHtml(key)}">
            ${escapeHtml(value.label)}
          </button>
        `
      )
      .join("");
  }

  root.innerHTML = `
    <section class="page-header">
      <p class="eyebrow">Zone Report</p>
      <h1>${escapeHtml(zone.label)}</h1>
      <p class="lead">Compare precipitation, soil moisture, weather, and fire-index changes from the latest station observations. Select a station for hourly detail and today’s sampled conditions.</p>
      <div class="hero-actions">
        <a class="button button-secondary" href="reports.html">Back to reports</a>
        <a class="button button-secondary" href="dashboard.html">Open dashboard</a>
      </div>
    </section>

    <section class="panel">
      <div class="metric-grid">
        <article class="metric-card"><span>Stations</span><strong>${formatCount(zone.station_count)}</strong><span>Rostered stations in this zone</span></article>
        <article class="metric-card"><span>RAWS</span><strong>${formatCount(zone.source_counts?.FEMS)}</strong><span>FEMS stations represented here</span></article>
        <article class="metric-card"><span>Synoptic Soil</span><strong>${formatCount(zone.source_counts?.Synoptic)}</strong><span>Synoptic stations represented here</span></article>
        <article class="metric-card"><span>Zentra</span><strong>${formatCount(zone.source_counts?.Zentra)}</strong><span>Zentra stations represented here</span></article>
        <article class="metric-card"><span>Latest source pull</span><strong>${escapeHtml(formatReportTimestamp(zone.latest_timestamp || data.generated_at))}</strong><span>Newest precip timestamp used in this zone page</span></article>
      </div>
    </section>

    <section class="panel">
      <div class="report-tab-row" id="report-tab-row">
        ${renderTabButtons("precip")}
      </div>
      <div class="report-filter-bar"><label>Find a station<input id="report-search" type="search" placeholder="Station name, ID, or network"></label><label class="report-current-filter"><input id="report-current-only" type="checkbox">Current stations only</label></div>
      <div id="report-dataset-panel">
        ${renderDatasetTable("precip")}
      </div>
    </section>
  `;

  const tabRow = document.getElementById("report-tab-row");
  const datasetPanel = document.getElementById("report-dataset-panel");
  let currentDatasetKey = "precip";

  function refreshTable() {
    if (typeof Plotly !== "undefined") datasetPanel.querySelectorAll(".js-plotly-plot").forEach(plot => Plotly.purge(plot));
    datasetPanel.innerHTML = renderDatasetTable(currentDatasetKey);
    if (selectedStationId) {
      const row = filteredReportRows(datasets[currentDatasetKey]).find(entry => String(entry.station_id) === selectedStationId);
      if (row) showRowDetail(row, false);
      else selectedStationId = null;
    }
  }
  document.getElementById("report-search").addEventListener("input", event => {
    searchText = event.target.value.trim().toLowerCase();
    refreshTable();
  });
  document.getElementById("report-current-only").addEventListener("change", event => {
    currentOnly = event.target.checked;
    refreshTable();
  });

  function showRowDetail(row, toggle = true) {
    const dataset = datasets[currentDatasetKey] || datasets.precip;
    datasetPanel.querySelectorAll(".report-detail-table-row").forEach(detail => {
      if (typeof Plotly !== "undefined") detail.querySelectorAll(".js-plotly-plot").forEach(plot => Plotly.purge(plot));
      detail.remove();
    });
    const id = String(row.station_id);
    selectedStationId = toggle && selectedStationId === id ? null : id;
    let selectedRow = null;
    datasetPanel.querySelectorAll("[data-report-row]").forEach((tableRow) => {
      const selected = tableRow.dataset.reportRow === selectedStationId;
      tableRow.classList.toggle("is-selected", selected);
      tableRow.setAttribute("aria-expanded", String(selected));
      if (selected) selectedRow = tableRow;
    });
    if (!selectedRow) return;
    const detailRow = document.createElement("tr");
    detailRow.className = "report-detail-table-row";
    detailRow.innerHTML = `<td colspan="9"><div class="report-detail-inline" aria-live="polite">${rowDetailMarkup(row, currentDatasetKey, dataset.label)}<section class="report-detail-chart-slot"><span class="report-chart-loading">Loading 30-day chart&hellip;</span></section></div></td>`;
    selectedRow.after(detailRow);
    const slot = detailRow.querySelector(".report-detail-inline");
    renderSelectedStationChart(slot, row, currentDatasetKey, dataset.label);
  }

  datasetPanel.addEventListener("click", (event) => {
    const sort = event.target.closest("[data-report-sort]");
    if (sort) {
      ascending = sortKey === sort.dataset.reportSort ? !ascending : false;
      sortKey = sort.dataset.reportSort;
      refreshTable();
      return;
    }
    const tableRow = event.target.closest("[data-report-row]");
    if (!tableRow) return;
    const dataset = datasets[currentDatasetKey] || datasets.precip;
    const row = (dataset.data?.rows || []).find((entry) => String(entry.station_id) === tableRow.dataset.reportRow);
    if (row) showRowDetail(row);
  });

  datasetPanel.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    const tableRow = event.target.closest("[data-report-row]");
    if (!tableRow) return;
    event.preventDefault();
    tableRow.click();
  });

  function setActiveTab(datasetKey) {
    const buttons = tabRow?.querySelectorAll("[data-report-tab]") || [];
    buttons.forEach((button) => {
      button.classList.toggle("active", button.dataset.reportTab === datasetKey);
    });
  }

  tabRow?.addEventListener("click", (event) => {
    const button = event.target.closest("[data-report-tab]");
    if (!button) {
      return;
    }

    const datasetKey = button.dataset.reportTab;
    if (!datasetKey || !datasets[datasetKey]) {
      return;
    }

    currentDatasetKey = datasetKey;
    selectedStationId = null;
    setActiveTab(currentDatasetKey);
    refreshTable();
  });
}

async function initReports() {
  try {
    const data = await loadReportsData();
    if (reportsPage() === "reports-zone") {
      renderZoneReport(data);
    } else {
      renderReportsIndex(data);
    }
  } catch (error) {
    const target =
      document.getElementById("zone-report-root") ||
      document.querySelector("main.content-grid") ||
      document.body;
    renderEmptyState(target, "Reports unavailable", error.message || "Unable to load report data.");
  }
}

initReports();
