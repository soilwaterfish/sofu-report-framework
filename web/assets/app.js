function resolveDataVersion() {
  const bodyVersion = document.body?.dataset?.build;
  if (bodyVersion) {
    return bodyVersion;
  }

  const script =
    document.currentScript ||
    Array.from(document.scripts).find((node) => /assets\/app\.js(?:\?|$)/.test(node.src));

  if (!script?.src) {
    return "";
  }

  try {
    return new URL(script.src, window.location.href).searchParams.get("v") || "";
  } catch {
    return "";
  }
}

const DATA_VERSION = resolveDataVersion();
const DATA_PATH = `data/dashboard.json${DATA_VERSION ? `?v=${DATA_VERSION}` : ""}`;
const state = {
  data: null,
  stationId: null,
  metric: "soil_moisture_1",
  chartWindow: "365",
  percentileDay: "today",
  multiAxisMetrics: [],
  map: null,
  markers: new Map(),
  layerControl: null,
  overlays: {},
  modalMap: null,
  modalMarkers: new Map(),
  modalLayerControl: null,
  modalOverlays: {}
};

const MAX_MULTI_AXIS_METRICS = 6;

const metricConfig = {
  soil_moisture_1: { label: "Soil Moisture 1", unit: "%", color: "#204f4a" },
  soil_moisture_2: { label: "Soil Moisture 2", unit: "%", color: "#c56b3b" },
  air_temp: { label: "Air Temperature", unit: "F", color: "#9b3d2f" },
  humidity: { label: "Humidity", unit: "%", color: "#506e8a" },
  wind_speed: { label: "Wind Speed", unit: "mph", color: "#7a8f47" },
  precip_accum: { label: "Precip Accum", unit: "in", color: "#40667a" },
  precip_cumulative: { label: "Accumulated Precip", unit: "in", color: "#274c77" },
  gsi: { label: "GSI", unit: "", color: "#6a7f2b" },
  kbdi: { label: "KBDI", unit: "", color: "#8b5a2b" }
};

function withAlpha(hex, alpha) {
  const clean = hex.replace("#", "");
  const normalized = clean.length === 3
    ? clean.split("").map((char) => char + char).join("")
    : clean;

  const int = Number.parseInt(normalized, 16);
  const r = (int >> 16) & 255;
  const g = (int >> 8) & 255;
  const b = int & 255;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

async function loadData() {
  const response = await fetch(DATA_PATH);
  if (!response.ok) throw new Error(`Failed to load ${DATA_PATH}`);
  state.data = await response.json();
}

function setDashboardLoading(isLoading, message = "Preparing the map, current readings, and charts.") {
  const loader = document.getElementById("dashboard-loading");
  const layout = document.querySelector(".dashboard-layout");
  if (!loader || !layout) return;

  loader.classList.toggle("is-hidden", !isLoading);
  layout.setAttribute("aria-busy", String(isLoading));
  const messageTarget = loader.querySelector("span:last-child");
  if (messageTarget) messageTarget.textContent = message;
}

function requestedStationId() {
  return new URLSearchParams(window.location.search).get("station") || "";
}

function formatValue(value, digits = 1) {
  if (value === null || value === undefined || Number.isNaN(value)) return "N/A";
  return Number(value).toFixed(digits);
}

function formatTimestamp(value) {
  return new Date(value).toLocaleString([], {
    timeZone: "America/Denver",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  });
}

function metricAsOf(station, metricKey, fallbackText = "Latest reading") {
  const timestamp = station?.latest_dates?.[metricKey];
  if (timestamp) {
    return `As of ${formatTimestamp(timestamp)}`;
  }
  return fallbackText;
}

function latestObservationTimestamp(station) {
  const keys = ["soil_moisture_1", "soil_moisture_2", "air_temp", "humidity",
    "wind_speed", "precip_accum"];
  const timestamps = keys.map((key) => station.latest_dates?.[key])
    .filter((value) => value && Number.isFinite(Date.parse(value)));
  return timestamps.sort((a, b) => Date.parse(b) - Date.parse(a))[0]
    || station.latest.timestamp;
}

function localDateKey(timestamp) {
  return String(timestamp ?? "").slice(0, 10);
}

function dateKeyLabel(dateKey) {
  if (!dateKey) return "N/A";
  return new Date(`${dateKey}T12:00:00Z`).toLocaleDateString([], {
    timeZone: "America/Denver",
    month: "short",
    day: "numeric",
    year: "numeric"
  });
}

function incrementDateKey(dateKey) {
  const cursor = new Date(`${dateKey}T00:00:00Z`);
  cursor.setUTCDate(cursor.getUTCDate() + 1);
  return cursor.toISOString().slice(0, 10);
}

function createMetricCard(label, value, note, options = {}) {
  const card = document.createElement("article");
  card.className = `metric-card${options.className ? ` ${options.className}` : ""}`;
  card.innerHTML = `<span>${label}</span><strong>${value}</strong><span>${note}</span>`;
  return card;
}

function getStations() {
  return state.data?.stations ?? [];
}

function getStationCatalog() {
  return state.data?.station_catalog ?? [];
}

function getCurrentStation() {
  return getStations().find((station) => station.id === state.stationId) ?? null;
}

function defaultMultiAxisMetrics(station) {
  const available = getAvailableMetrics(station);
  if (!available.length) {
    return [];
  }

  if (available.includes(state.metric)) {
    return [state.metric];
  }

  const preferred = [
    "soil_moisture_1",
    "soil_moisture_2",
    "air_temp",
    "humidity",
    "wind_speed",
    "precip_accum",
    "precip_cumulative",
    "gsi",
    "kbdi"
  ];

  const selected = preferred.filter((metricKey) => available.includes(metricKey));
  return [selected[0] ?? available[0]];
}

function stationLayerName(station) {
  if (station?.api === "Zentra") {
    return "Zentra";
  }

  if (station?.api === "FEMS") {
    return "RAWS";
  }

  return "Synoptic Soil";
}

function availableMetricLabels(station) {
  return (station?.available_metrics ?? [])
    .map((metricKey) => metricConfig[metricKey]?.label)
    .filter(Boolean);
}

function trendClass(changeValue, metricKey = null) {
  if (changeValue === null || changeValue === undefined || Number.isNaN(Number(changeValue))) {
    return "";
  }

  const value = Number(changeValue);
  const increaseClass = metricKey === "kbdi" ? "metric-trend-decrease" : "metric-trend-increase";
  const decreaseClass = metricKey === "kbdi" ? "metric-trend-increase" : "metric-trend-decrease";

  if (value > 0.5) return increaseClass;
  if (value < -0.5) return decreaseClass;
  return "metric-trend-stable";
}

function formatChangeNote(changeValue, unitLabel = "pts", digits = 1) {
  if (changeValue === null || changeValue === undefined || Number.isNaN(Number(changeValue))) {
    return "Latest reading";
  }

  const value = Number(changeValue);
  const prefix = value > 0 ? "+" : "";
  return `14-day change ${prefix}${value.toFixed(digits)} ${unitLabel}`;
}

function percentileBands(stat) {
  if (!stat) return null;

  const current = Number(stat.current);
  if (!Number.isFinite(current)) return null;

  const p05 = Number(stat.p05);
  const p10 = Number(stat.p10);
  const p25 = Number(stat.p25);
  const p75 = Number(stat.p75);
  const p90 = Number(stat.p90);
  const p95 = Number(stat.p95);

  const bands = [
    { key: "extremely-below", label: "0-5", note: "Extremely below", className: "band-extremely-below" },
    { key: "much-below", label: "5-10", note: "Much below", className: "band-much-below" },
    { key: "below-normal", label: "10-25", note: "Below normal", className: "band-below-normal" },
    { key: "normal", label: "25-75", note: "Normal", className: "band-normal" },
    { key: "above-normal", label: "75-90", note: "Above normal", className: "band-above-normal" },
    { key: "much-above", label: "90-95", note: "Much above", className: "band-much-above" },
    { key: "extremely-above", label: "95-100", note: "Extremely above", className: "band-extremely-above" }
  ];

  let activeKey = "normal";
  if (Number.isFinite(p05) && current <= p05) activeKey = "extremely-below";
  else if (Number.isFinite(p10) && current <= p10) activeKey = "much-below";
  else if (Number.isFinite(p25) && current <= p25) activeKey = "below-normal";
  else if (Number.isFinite(p75) && current <= p75) activeKey = "normal";
  else if (Number.isFinite(p90) && current <= p90) activeKey = "above-normal";
  else if (Number.isFinite(p95) && current <= p95) activeKey = "much-above";
  else activeKey = "extremely-above";

  return bands.map((band) => ({
    ...band,
    active: band.key === activeKey
  }));
}

function activePercentileBand(stat) {
  const bands = percentileBands(stat);
  return bands ? bands.find((band) => band.active) ?? null : null;
}

function metricShortLabel(metricKey) {
  const shortLabels = {
    soil_moisture_1: "SM1",
    soil_moisture_2: "SM2",
    air_temp: "AT",
    humidity: "RH",
    wind_speed: "WS",
    precip_accum: "PA",
    precip_cumulative: "AP",
    gsi: "GSI",
    kbdi: "KBDI"
  };

  return shortLabels[metricKey] ?? metricKey;
}

function hasMapCoords(station) {
  const lat = station?.latitude;
  const lon = station?.longitude;

  if (lat === null || lat === undefined || lat === "") return false;
  if (lon === null || lon === undefined || lon === "") return false;

  return Number.isFinite(Number(lat)) && Number.isFinite(Number(lon));
}

function tooltipBlocks(station) {
  const metricKeys = getAvailableMetrics(station)
    .filter((metricKey) => station.percentiles?.[metricKey]?.value_mean)
    .slice(0, 6);

  if (!metricKeys.length) {
    return '<div class="tooltip-meta">No percentile context available for current station variables.</div>';
  }

  const blocks = metricKeys.map((metricKey) => {
    const stat = station.percentiles[metricKey].value_mean;
    const band = activePercentileBand(stat);
    const bandClass = band?.className ?? "band-normal";
    const bandLabel = band?.label ?? "";
    return `<div class="tooltip-chip ${bandClass}"><strong>${metricShortLabel(metricKey)}</strong><span>${bandLabel}</span></div>`;
  }).join("");

  return `<div class="tooltip-grid">${blocks}</div>`;
}

function buildTooltipHtml(station, layerName) {
  const coords = hasMapCoords(station)
    ? `${formatValue(station.latitude, 3)}, ${formatValue(station.longitude, 3)}`
    : "Coords unavailable";
  const yearsText = station.years_of_data
    ? `${station.years_of_data} year${station.years_of_data === 1 ? "" : "s"}`
    : "Years unavailable";

  return `
    <span class="tooltip-title">${station.name}</span>
    <span class="tooltip-subtitle">${station.id} · ${layerName}</span>
    <span class="tooltip-meta">${yearsText} · ${coords}</span>
    ${tooltipBlocks(station)}
  `;
}

function getAvailableMetrics(station) {
  if (!station) return [];

  if (Array.isArray(station.available_metrics) && station.available_metrics.length) {
    return station.available_metrics
      .map((metric) => (typeof metric === "string" ? metric : metric?.key))
      .filter((key) => key in metricConfig);
  }

  return Object.keys(metricConfig).filter((key) => {
    if (station.latest?.[key] !== null && station.latest?.[key] !== undefined) {
      return true;
    }

    return station.series.some((point) => point[key] !== null && point[key] !== undefined);
  });
}

function syncStationPicker() {
  const picker = document.getElementById("station-picker");
  if (picker && picker.value !== state.stationId) {
    picker.value = state.stationId ?? "";
  }
}

function updateMapSelection() {
  state.markers.forEach((marker, stationId) => {
    const isActive = stationId === state.stationId;
    marker.setStyle({
      radius: isActive ? 9 : 6,
      fillColor: isActive ? "#c56b3b" : marker.options.baseFillColor,
      color: isActive ? "#fff7ef" : "#f3e8da",
      weight: isActive ? 3 : 2,
      fillOpacity: isActive ? 1 : 0.9
    });

    if (isActive) {
      marker.bringToFront();
    }
  });

  state.modalMarkers.forEach((marker, stationId) => {
    const isActive = stationId === state.stationId;
    marker.setStyle({
      radius: isActive ? 9 : 6,
      fillColor: isActive ? "#c56b3b" : marker.options.baseFillColor,
      color: isActive ? "#fff7ef" : "#f3e8da",
      weight: isActive ? 3 : 2,
      fillOpacity: isActive ? 1 : 0.9
    });

    if (isActive) {
      marker.bringToFront();
    }
  });
}

function selectStationById(stationId) {
  if (!getStations().some((station) => station.id === stationId)) {
    return;
  }

  state.stationId = stationId;
  const station = getCurrentStation();
  const availableMetrics = getAvailableMetrics(station);
  if (!availableMetrics.includes(state.metric)) {
    state.metric = availableMetrics[0] ?? "soil_moisture_1";
  }
  state.multiAxisMetrics = defaultMultiAxisMetrics(station);
  syncStationPicker();
  updateMapSelection();
  updateDashboard();
}

function renderHome() {
  const target = document.getElementById("home-overview");
  if (!target || !state.data) return;

  const { overview } = state.data;
  target.innerHTML = "";
  target.append(
    createMetricCard("Stations", overview.station_count, "Active stations in current export")
  );

  const stamp = document.getElementById("generated-at");
  if (stamp) {
    stamp.textContent = `Generated ${formatTimestamp(state.data.generated_at)}`;
  }
}

function renderOverviewCards() {
  const target = document.getElementById("dashboard-overview");
  if (!target || !state.data) return;

  const { overview } = state.data;
  target.innerHTML = "";
  target.append(
    createMetricCard("Stations", overview.station_count, `Updated ${formatTimestamp(overview.last_timestamp)}`)
  );
}

function renderStationPicker() {
  const picker = document.getElementById("station-picker");
  if (!picker) return;

  picker.innerHTML = "";

  const groupedStations = getStations().reduce((groups, station) => {
    const key = stationLayerName(station);
    groups[key] = groups[key] ?? [];
    groups[key].push(station);
    return groups;
  }, {});

  Object.entries(groupedStations).forEach(([groupName, stations]) => {
    const optgroup = document.createElement("optgroup");
    optgroup.label = groupName;

    stations.forEach((station) => {
      const option = document.createElement("option");
      option.value = station.id;
      option.textContent = station.name;
      optgroup.appendChild(option);
    });

    picker.appendChild(optgroup);
  });

  syncStationPicker();
  picker.onchange = (event) => selectStationById(event.target.value);
}

function renderVariablePicker(station) {
  const picker = document.getElementById("variable-picker");
  if (!picker || !station) return;

  const availableMetrics = getAvailableMetrics(station);
  picker.innerHTML = "";

  availableMetrics.forEach((metricKey) => {
    const option = document.createElement("option");
    option.value = metricKey;
    option.textContent = metricConfig[metricKey].label;
    picker.appendChild(option);
  });

  if (!availableMetrics.includes(state.metric)) {
    state.metric = availableMetrics[0] ?? "soil_moisture_1";
  }

  picker.value = state.metric;
  picker.onchange = (event) => {
    state.metric = event.target.value;
    updateDashboard();
  };
}

function renderMultiAxisControls(station) {
  const panel = document.getElementById("multi-axis-beta-panel");
  const controls = document.getElementById("multi-axis-beta-controls");
  const note = document.getElementById("multi-axis-beta-note");

  if (!panel || !controls || !note || !station) return;

  const availableMetrics = getAvailableMetrics(station);
  if (!availableMetrics.length) {
    panel.classList.add("is-hidden");
    return;
  }

  const normalized = state.multiAxisMetrics.filter((metricKey) => availableMetrics.includes(metricKey));
  state.multiAxisMetrics = normalized.length ? normalized : defaultMultiAxisMetrics(station);

  controls.innerHTML = "";
  availableMetrics.forEach((metricKey) => {
    const metric = metricConfig[metricKey];
    const isChecked = state.multiAxisMetrics.includes(metricKey);
    const item = document.createElement("label");
    item.className = `multi-axis-option${isChecked ? " is-selected" : ""}`;
    item.innerHTML = `
      <input type="checkbox" value="${metricKey}" ${isChecked ? "checked" : ""} />
      <span class="multi-axis-swatch" style="background:${metric.color}"></span>
      <span>${metric.label}</span>
    `;

    const input = item.querySelector("input");
    input.addEventListener("change", (event) => {
      const nextKey = event.target.value;

      if (event.target.checked) {
        if (state.multiAxisMetrics.length >= MAX_MULTI_AXIS_METRICS) {
          event.target.checked = false;
          note.textContent = `Choose up to ${MAX_MULTI_AXIS_METRICS} variables at a time for the multi-axis beta.`;
          return;
        }

        state.multiAxisMetrics = [...state.multiAxisMetrics, nextKey];
      } else {
        state.multiAxisMetrics = state.multiAxisMetrics.filter((metricKeyInner) => metricKeyInner !== nextKey);
      }

      renderMultiAxisControls(station);
      renderMultiAxisBeta(station);
    });

    controls.appendChild(item);
  });

  note.textContent = `Choose up to ${MAX_MULTI_AXIS_METRICS} variables, then use the Plotly legend to toggle traces on and off.`;
}

function filteredSeries(station) {
  if (!station || !station.series.length) return [];
  const [start, end] = chartDateRange();
  return station.series.filter(point => localDateKey(point.timestamp) >= start.slice(0, 10) && localDateKey(point.timestamp) <= end.slice(0, 10));
}

function chartDateRange() {
  const today = window.SofuRates.dayKey(state.data?.generated_at || Date.now());
  const end = `${today}T23:59:59`;
  let start;
  if (state.chartWindow === "wy") {
    start = `${Number(today.slice(0, 4)) - (today.slice(5) < "10-01" ? 1 : 0)}-10-01`;
  } else {
    const date = new Date(`${today}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() - Number(state.chartWindow));
    start = date.toISOString().slice(0, 10);
  }
  return [`${start}T00:00:00`, end];
}

function waterYearKey(timestamp) {
  const date = localDateKey(timestamp);
  return Number(date.slice(0, 4)) + (date.slice(5) >= "10-01" ? 1 : 0);
}

function addWaterYearBreaks(series, key) {
  if (key !== "precip_cumulative") return series;
  const points = [];
  series.forEach((point, index) => {
    if (index && waterYearKey(point.timestamp) !== waterYearKey(series[index - 1].timestamp)) {
      points.push({ timestamp: point.timestamp, resolution: point.resolution,
        [key]: null, [`${key}_min`]: null, [`${key}_max`]: null });
    }
    points.push(point);
  });
  return points;
}

function provisionalPercentiles(station) {
  const key = state.metric;
  const today = window.SofuRates.dayKey(Date.now());
  const ref = station.today_reference?.[key];
  if (!ref || ref.local_date !== today) return null;
  const snap = window.SofuRates.snapshot(station.current_report, key);
  const context = { ...ref, provisional: true, observed_at: snap?.isToday ? snap.timestamp : null };
  const precipitation = key === "precip_accum" || key === "precip_cumulative";
  for (const [field, stat] of [["value_min", "min"], ["value_mean", "mean"], ["value_max", "max"]]) {
    if (!ref[field]) continue;
    let value = snap?.isToday ? snap[stat] : null;
    if (precipitation) {
      if (field !== "value_mean") { delete context[field]; continue; }
      value = snap?.isToday ? snap.total : null;
      if (key === "precip_cumulative" && value !== null && today.slice(5) !== "10-01") {
        const prior = station.series.filter(point => point.resolution === "daily" && localDateKey(point.timestamp) < today && waterYearKey(point.timestamp) === waterYearKey(today) && point.precip_cumulative != null).at(-1);
        value = prior ? Number(prior.precip_cumulative) + value : null;
      }
    }
    context[field] = { ...ref[field], current: value };
  }
  return context;
}

function fillDailyDateGaps(dailySeries, metricKey) {
  if (!dailySeries.length) return [];

  const minKey = `${metricKey}_min`;
  const maxKey = `${metricKey}_max`;
  const byDate = new Map(
    dailySeries.map((point) => [localDateKey(point.timestamp), point])
  );

  const filled = [];
  const startKey = localDateKey(dailySeries[0].timestamp);
  const endKey = localDateKey(dailySeries[dailySeries.length - 1].timestamp);

  for (let dateKey = startKey; dateKey <= endKey; dateKey = incrementDateKey(dateKey)) {
    const existing = byDate.get(dateKey);

    if (existing) {
      filled.push(existing);
      continue;
    }

    filled.push({
      timestamp: `${dateKey}T12:00:00`,
      resolution: "daily",
      [metricKey]: null,
      [minKey]: null,
      [maxKey]: null
    });
  }

  return filled;
}

function renderSelectedStationMeta(station) {
  const target = document.getElementById("selected-station-meta");
  const title = document.getElementById("selected-station-title");
  const status = document.getElementById("map-status");

  if (!target || !station) return;

  if (title) {
    title.textContent = station.name;
  }

  if (status) {
    status.textContent = hasMapCoords(station)
      ? `Mapped station at ${formatValue(station.latitude, 3)}, ${formatValue(station.longitude, 3)}`
      : "This station is available in the dashboard but has no map coordinates yet.";
  }

  target.innerHTML = "";
  const variableLabels = availableMetricLabels(station);
  target.append(
    createMetricCard("Station ID", station.id, station.api ?? "API source unavailable"),
    createMetricCard("Latest update", formatTimestamp(latestObservationTimestamp(station)), "Most recent observation"),
    createMetricCard(
      "Coordinates",
      hasMapCoords(station)
        ? `${formatValue(station.latitude, 3)}, ${formatValue(station.longitude, 3)}`
        : "N/A",
      hasMapCoords(station) ? "Latitude, longitude" : "Coordinate unavailable"
    ),
    createMetricCard(
      "Years",
      station.years_of_data ?? "N/A",
      "Calendar years represented in this station record"
    ),
    createMetricCard(
      "Variables",
      variableLabels.length,
      variableLabels.length ? variableLabels.join(", ") : "No graphable variables exported"
    )
  );
}

function renderStationSummary(station) {
  const target = document.getElementById("station-summary");
  const title = document.getElementById("station-summary-title");
  if (!target || !station) return;

  if (title) {
    title.textContent = `${station.name} latest station summary`;
  }

  const latest = station.latest;
  const cards = [];

  if (latest.soil_moisture_1 !== null && latest.soil_moisture_1 !== undefined) {
    cards.push(
      createMetricCard(
        "Soil Moisture 1",
        `${formatValue(latest.soil_moisture_1)}%`,
        formatChangeNote(latest.soil_moisture_1_change_14d),
        { className: trendClass(latest.soil_moisture_1_change_14d, "soil_moisture_1") }
      )
    );
  }

  if (latest.soil_moisture_2 !== null && latest.soil_moisture_2 !== undefined) {
    cards.push(
      createMetricCard(
        "Soil Moisture 2",
        `${formatValue(latest.soil_moisture_2)}%`,
        formatChangeNote(latest.soil_moisture_2_change_14d),
        { className: trendClass(latest.soil_moisture_2_change_14d, "soil_moisture_2") }
      )
    );
  }

  if (latest.air_temp !== null && latest.air_temp !== undefined) {
    cards.push(createMetricCard("Air temperature", `${formatValue(latest.air_temp)}F`, metricAsOf(station, "air_temp")));
  }

  if (latest.humidity !== null && latest.humidity !== undefined) {
    cards.push(createMetricCard("Humidity", `${formatValue(latest.humidity)}%`, metricAsOf(station, "humidity", "Latest relative humidity")));
  }

  if (latest.wind_speed !== null && latest.wind_speed !== undefined) {
    cards.push(createMetricCard("Wind speed", `${formatValue(latest.wind_speed)} mph`, metricAsOf(station, "wind_speed", "Latest recorded wind speed")));
  }

  if (latest.precip_accum !== null && latest.precip_accum !== undefined) {
    cards.push(createMetricCard("Precip accum", `${formatValue(latest.precip_accum, 2)} in`, metricAsOf(station, "precip_accum", "Latest station precip value")));
  }

  if (latest.precip_cumulative !== null && latest.precip_cumulative !== undefined) {
    cards.push(createMetricCard(
      "Accumulated precip",
      `${formatValue(latest.precip_cumulative, 2)} in`,
      metricAsOf(station, "precip_cumulative", formatChangeNote(latest.precip_cumulative_change_14d, "in", 2)),
      { className: trendClass(latest.precip_cumulative_change_14d, "precip_cumulative") }
    ));
  } else if (latest.precip_total !== null && latest.precip_total !== undefined) {
    cards.push(createMetricCard("Accumulated precip", `${formatValue(latest.precip_total, 2)} in`, "Accumulated in exported window"));
  }

  if (latest.gsi !== null && latest.gsi !== undefined) {
    cards.push(createMetricCard(
      "GSI",
      formatValue(latest.gsi, 2),
      metricAsOf(station, "gsi", formatChangeNote(latest.gsi_change_14d, "pts", 2)),
      { className: trendClass(latest.gsi_change_14d, "gsi") }
    ));
  }

  if (latest.kbdi !== null && latest.kbdi !== undefined) {
    cards.push(createMetricCard(
      "KBDI",
      formatValue(latest.kbdi, 0),
      metricAsOf(station, "kbdi", formatChangeNote(latest.kbdi_change_14d, "pts", 0)),
      { className: trendClass(latest.kbdi_change_14d, "kbdi") }
    ));
  }

  target.innerHTML = "";
  target.append(...cards);
}

function createPercentileCard(label, stat) {
  const currentText = stat?.current !== null && stat?.current !== undefined
    ? formatValue(stat.current, 2)
    : "N/A";
  const p10 = stat?.p10 !== null && stat?.p10 !== undefined ? formatValue(stat.p10, 2) : "N/A";
  const p50 = stat?.p50 !== null && stat?.p50 !== undefined ? formatValue(stat.p50, 2) : "N/A";
  const p90 = stat?.p90 !== null && stat?.p90 !== undefined ? formatValue(stat.p90, 2) : "N/A";
  const activeBand = activePercentileBand(stat);
  const toneClass = activeBand ? `percentile-card-${activeBand.key}` : "";
  return createMetricCard(label, currentText, `P10 ${p10} | P50 ${p50} | P90 ${p90}`, {
    className: toneClass
  });
}

function percentileSummaryLabel(metricKey, statKey) {
  if (metricKey === "precip_cumulative") return "Current accumulated precip";
  if (statKey === "value_min") return "Current daily minimum";
  if (statKey === "value_max") return "Current daily maximum";
  return "Current daily mean";
}

function chartPercentileStat(station) {
  const metricPercentiles = station?.percentiles?.[state.metric];
  if (!metricPercentiles) return null;

  if (state.metric === "precip_cumulative") {
    return metricPercentiles.value_mean ?? null;
  }

  return metricPercentiles.value_mean ?? null;
}

function buildPercentileRibbonTrace(points, lowerKey, upperKey, color, name, alpha) {
  if (!Array.isArray(points) || !points.length) return null;

  const validPoints = points.filter((point) => {
    const lower = point?.[lowerKey];
    const upper = point?.[upperKey];
    return lower !== null && lower !== undefined && upper !== null && upper !== undefined;
  });

  if (!validPoints.length) return null;

  const groups = [];
  for (const point of validPoints) {
    const previous = groups.at(-1);
    if (!previous || (state.metric === "precip_cumulative" && waterYearKey(previous[0].timestamp) !== waterYearKey(point.timestamp))) groups.push([point]);
    else previous.push(point);
  }
  const ribbonX = [], ribbonY = [];
  for (const group of groups) {
    ribbonX.push(...group.map(point => localDateKey(point.timestamp)), ...group.map(point => localDateKey(point.timestamp)).reverse(), null);
    ribbonY.push(...group.map(point => Number(point[upperKey])), ...group.map(point => Number(point[lowerKey])).reverse(), null);
  }
  return {
    x: [
      ...ribbonX
    ],
    y: [
      ...ribbonY
    ],
    type: "scatter",
    mode: "lines",
    name,
    fill: "toself",
    fillcolor: withAlpha(color, alpha),
    line: {
      color: withAlpha(color, alpha + 0.08),
      width: 1
    },
    hoverinfo: "skip",
    xhoverformat: "%b %-d, %Y",
    visible: "legendonly"
  };
}

function renderPercentiles(station) {
  const target = document.getElementById("station-percentiles");
  const title = document.getElementById("percentile-title");
  const scale = document.getElementById("percentile-scale");
  const scaleSummary = document.getElementById("percentile-scale-summary");
  if (!target || !station) return;

  const metric = metricConfig[state.metric];
  const metricPercentiles = state.percentileDay === "today" ? provisionalPercentiles(station) : station.percentiles?.[state.metric];

  if (title) {
    title.textContent = metricPercentiles
      ? `${metric.label} percentile context for ${metricPercentiles.local_date}${metricPercentiles.provisional ? " · today so far, provisional" : " · completed day"}`
      : `${metric.label} percentile context`;
  }

  target.innerHTML = "";
  if (scale) {
    scale.innerHTML = "";
  }
  if (scaleSummary) {
    scaleSummary.innerHTML = "";
  }

  if (!metricPercentiles) {
    target.append(createMetricCard("Percentiles unavailable", "N/A", "No percentile record yet for this station and variable."));
    return;
  }

  const scaleStatKey = metricPercentiles.value_mean
    ? "value_mean"
    : metricPercentiles.value_max
      ? "value_max"
      : metricPercentiles.value_min
        ? "value_min"
        : null;
  const scaleStat = scaleStatKey ? metricPercentiles[scaleStatKey] : null;

  const bands = percentileBands(scaleStat);
  if (scale && bands) {
    const scaleInner = document.createElement("div");
    scaleInner.className = "percentile-scale";

    bands.forEach((band) => {
      const item = document.createElement("div");
      item.className = `percentile-band ${band.className}${band.active ? " active" : ""}`;
      item.innerHTML = `<strong>${band.label}</strong><span>${band.note}</span>${band.active ? '<em>Current</em>' : ""}`;
      scaleInner.appendChild(item);
    });

    scale.appendChild(scaleInner);
  }

  const activeBand = activePercentileBand(scaleStat);
  if (scaleSummary && activeBand && scaleStat?.current !== null && scaleStat?.current !== undefined) {
    scaleSummary.innerHTML = `
      <div class="percentile-summary-card ${activeBand.className}">
        <span class="percentile-summary-label">${metricPercentiles.provisional ? "Provisional · " : ""}${percentileSummaryLabel(state.metric, scaleStatKey)}</span>
        <strong>${formatValue(scaleStat.current, 2)} ${metric.unit}</strong>
        <span class="percentile-summary-text">${activeBand.note} · ${activeBand.label} percentile band</span>
      </div>
    `;
  }

  const cards = [];

  if (metricPercentiles.value_min) {
    cards.push(createPercentileCard(metricPercentiles.provisional ? "Today sampled min" : "Daily min", metricPercentiles.value_min));
  }

  if (metricPercentiles.value_mean) {
    cards.push(createPercentileCard(
      state.metric === "precip_cumulative" ? "Water-year precipitation" : state.metric === "precip_accum" ? "Daily precipitation" : metricPercentiles.provisional ? "Today sampled mean" : "Daily mean",
      metricPercentiles.value_mean
    ));
  }

  if (metricPercentiles.value_max) {
    cards.push(createPercentileCard(metricPercentiles.provisional ? "Today sampled max" : "Daily max", metricPercentiles.value_max));
  }

  cards.push(
    createMetricCard("Years in record", metricPercentiles.n_years ?? "N/A", `Day of year ${metricPercentiles.day_of_year_key}`)
  );

  target.append(...cards);
}

function renderMap() {
  renderLeafletMap("main");
}

function mapState(prefix) {
  if (prefix === "modal") {
    return {
      elementId: "station-map-modal",
      mapKey: "modalMap",
      markersKey: "modalMarkers",
      layerControlKey: "modalLayerControl",
      overlaysKey: "modalOverlays",
      scrollWheelZoom: true
    };
  }

  return {
    elementId: "station-map",
    mapKey: "map",
    markersKey: "markers",
    layerControlKey: "layerControl",
    overlaysKey: "overlays",
    scrollWheelZoom: false
  };
}

function renderLeafletMap(prefix = "main") {
  const cfg = mapState(prefix);
  const mapElement = document.getElementById(cfg.elementId);
  if (!mapElement || typeof L === "undefined") return;

  const mapStations = getStationCatalog().filter(hasMapCoords);
  const status = prefix === "main" ? document.getElementById("map-status") : null;

  if (!mapStations.length) {
    mapElement.innerHTML = '<div class="metric-card">No mapped station coordinates available yet.</div>';
    if (status) {
      status.textContent = "Run the refreshed workflow to export station coordinates.";
    }
    return;
  }

  if (!state[cfg.mapKey]) {
    state[cfg.mapKey] = L.map(mapElement, {
      scrollWheelZoom: cfg.scrollWheelZoom
    });

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors"
    }).addTo(state[cfg.mapKey]);
  }

  state[cfg.markersKey].forEach((marker) => marker.remove());
  state[cfg.markersKey].clear();

  if (state[cfg.layerControlKey]) {
    state[cfg.layerControlKey].remove();
    state[cfg.layerControlKey] = null;
  }

  Object.values(state[cfg.overlaysKey]).forEach((layer) => {
    if (layer && state[cfg.mapKey].hasLayer(layer)) {
      state[cfg.mapKey].removeLayer(layer);
    }
  });

  state[cfg.overlaysKey] = {
    Zentra: L.layerGroup(),
    "Synoptic Soil": L.layerGroup(),
    RAWS: L.layerGroup()
  };

  const bounds = [];

  mapStations.forEach((station) => {
    const layerName = stationLayerName(station);
    const baseFillColor = layerName === "Zentra"
      ? "#204f4a"
      : layerName === "RAWS"
        ? "#8b5a2b"
        : "#506e8a";
    const marker = L.circleMarker([station.latitude, station.longitude], {
      radius: 6,
      fillColor: baseFillColor,
      baseFillColor,
      color: "#f3e8da",
      weight: 2,
      fillOpacity: 0.9
    });

    marker.bindPopup(`<strong>${station.name}</strong><br />${station.id}`);
    marker.bindTooltip(buildTooltipHtml(station, layerName), {
      className: "station-tooltip",
      direction: "top",
      offset: [0, -8],
      opacity: 0.95
    });
    marker.on("click", () => selectStationById(station.id));
    marker.addTo(state[cfg.overlaysKey][layerName]);
    state[cfg.markersKey].set(station.id, marker);
    bounds.push([station.latitude, station.longitude]);
  });

  const overlayMaps = {
    Zentra: state[cfg.overlaysKey].Zentra,
    "Synoptic Soil": state[cfg.overlaysKey]["Synoptic Soil"],
    RAWS: state[cfg.overlaysKey].RAWS
  };

  Object.values(overlayMaps).forEach((layer) => layer.addTo(state[cfg.mapKey]));
  state[cfg.layerControlKey] = L.control.layers(null, overlayMaps, {
    collapsed: false
  }).addTo(state[cfg.mapKey]);

  if (bounds.length) {
    state[cfg.mapKey].fitBounds(bounds, { padding: [24, 24] });
  }

  if (prefix === "modal" && state.map) {
    state[cfg.mapKey].setView(state.map.getCenter(), state.map.getZoom());
  }

  updateMapSelection();
}

function openMapModal() {
  const modal = document.getElementById("map-modal");
  if (!modal) return;

  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
  renderLeafletMap("modal");
  setTimeout(() => {
    if (state.modalMap) {
      state.modalMap.invalidateSize();
      if (state.map) {
        state.modalMap.setView(state.map.getCenter(), state.map.getZoom());
      }
    }
  }, 30);
}

function closeMapModal() {
  const modal = document.getElementById("map-modal");
  if (!modal) return;

  modal.classList.remove("open");
  modal.setAttribute("aria-hidden", "true");
}

function setupMapModal() {
  const openButton = document.getElementById("maximize-map");
  const closeButton = document.getElementById("close-map-modal");
  const modal = document.getElementById("map-modal");

  openButton?.addEventListener("click", openMapModal);
  closeButton?.addEventListener("click", closeMapModal);
  modal?.addEventListener("click", (event) => {
    if (event.target?.dataset?.closeMapModal === "true") {
      closeMapModal();
    }
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      closeMapModal();
    }
  });
}

function renderChart(station) {
  const chart = document.getElementById("trend-chart");
  const title = document.getElementById("chart-title");
  if (!chart || !station || typeof Plotly === "undefined") return;

  const fullSeries = filteredSeries(station);
  const series = fullSeries.filter((point) => point[state.metric] !== null && point[state.metric] !== undefined);
  const metric = metricConfig[state.metric];
  title.textContent = `${station.name}: ${metric.label}`;

  if (!series.length) {
    Plotly.purge(chart);
    return;
  }

  const recentSeries = series.filter((point) => point.resolution !== "daily" && Date.parse(point.timestamp) <= Date.now());
  const dailySeries = addWaterYearBreaks(fillDailyDateGaps(series.filter((point) => point.resolution === "daily"), state.metric), state.metric);
  const coverage = document.getElementById("chart-coverage-note");
  if (coverage) coverage.textContent = `${series.filter(point => point.resolution === "daily").length} observed daily records · missing dates remain gaps`;
  const traces = [];
  const percentileSeries = station.percentile_series?.[state.metric] ?? [];

  if (dailySeries.length) {
    const outerRibbon = buildPercentileRibbonTrace(
      percentileSeries,
      "p10",
      "p90",
      metric.color,
      "Percentile band 10-90",
      0.14
    );

    const innerRibbon = buildPercentileRibbonTrace(
      percentileSeries,
      "p25",
      "p75",
      metric.color,
      "Percentile band 25-75",
      0.24
    );

    if (outerRibbon) {
      traces.push(outerRibbon);
    }

    if (innerRibbon) {
      traces.push(innerRibbon);
    }

    const meanTrace = {
      x: dailySeries.map((point) => localDateKey(point.timestamp)),
      y: dailySeries.map((point) => {
        const value = point[state.metric];
        return value === null || value === undefined ? null : Number(value);
      }),
      customdata: dailySeries.map((point) => dateKeyLabel(localDateKey(point.timestamp))),
      type: "scatter",
      mode: "lines",
      name: "Daily mean",
      line: {
        color: withAlpha(metric.color, 0.55),
        width: 2
      },
      hovertemplate: `<b>${station.name}</b><br>Daily mean ${metric.label}: %{y:.2f} ${metric.unit}<br>%{customdata}<extra></extra>`
    };

    const minKey = `${state.metric}_min`;
    const maxKey = `${state.metric}_max`;
    const hasMinMax = dailySeries.some((point) => point[minKey] !== null && point[minKey] !== undefined);

    if (hasMinMax) {
      traces.push({
        x: dailySeries.map((point) => localDateKey(point.timestamp)),
        y: dailySeries.map((point) => {
          const value = point[minKey];
          return value === null || value === undefined ? null : Number(value);
        }),
        customdata: dailySeries.map((point) => dateKeyLabel(localDateKey(point.timestamp))),
        type: "scatter",
        mode: "lines",
        name: "Daily min",
        line: {
          color: withAlpha(metric.color, 0.38),
          width: 1.5,
          dash: "dot"
        },
        connectgaps: false,
        hovertemplate: `<b>${station.name}</b><br>Daily min ${metric.label}: %{y:.2f} ${metric.unit}<br>%{customdata}<extra></extra>`
      });

      traces.push({
        x: dailySeries.map((point) => localDateKey(point.timestamp)),
        y: dailySeries.map((point) => {
          const value = point[maxKey];
          return value === null || value === undefined ? null : Number(value);
        }),
        customdata: dailySeries.map((point) => dateKeyLabel(localDateKey(point.timestamp))),
        type: "scatter",
        mode: "lines",
        name: "Daily max",
        line: {
          color: withAlpha(metric.color, 0.38),
          width: 1.5,
          dash: "dot"
        },
        connectgaps: false,
        hovertemplate: `<b>${station.name}</b><br>Daily max ${metric.label}: %{y:.2f} ${metric.unit}<br>%{customdata}<extra></extra>`
      });
    }

    meanTrace.connectgaps = false;
    traces.push(meanTrace);
  }

  const recentTrace = {
    x: recentSeries.map((point) => window.SofuRates.wallTime(point.timestamp)),
    y: recentSeries.map((point) => Number(point[state.metric])),
    customdata: recentSeries.map((point) => formatTimestamp(point.timestamp)),
    type: "scatter",
    mode: "lines+markers",
    name: "Recent",
    line: {
      color: metric.color,
      width: 3
    },
    marker: {
      color: metric.color,
      size: 5
    },
    hovertemplate: `<b>${station.name}</b><br>${metric.label}: %{y:.2f} ${metric.unit}<br>%{customdata}<extra></extra>`
  };

  if (recentSeries.length) {
    traces.push(recentTrace);
  }

  const layout = {
    margin: { t: 12, r: 24, b: 56, l: 56 },
    paper_bgcolor: "rgba(0,0,0,0)",
    plot_bgcolor: "rgba(255,255,255,0.15)",
    font: {
      family: '"Segoe UI", sans-serif',
      color: "#1e2a2f"
    },
    xaxis: {
      title: "Time",
      range: chartDateRange(),
      tickformat: "%b %-d\n%Y",
      gridcolor: "rgba(30,42,47,0.08)",
      zeroline: false
    },
    yaxis: {
      title: `${metric.label} (${metric.unit})`,
      gridcolor: "rgba(30,42,47,0.12)",
      zeroline: false
    },
    dragmode: "zoom"
  };

  const config = {
    responsive: true,
    displaylogo: false,
    modeBarButtonsToRemove: ["lasso2d", "select2d", "autoScale2d"],
    scrollZoom: true
  };

  Plotly.react(chart, traces, layout, config);
}

function buildMultiAxisTrace(series, metricKey, station, axisKey) {
  const metric = metricConfig[metricKey];
  if (!metric) return null;

  const y = series.map((point) => {
    const value = point[metricKey];
    return value === null || value === undefined ? null : Number(value);
  });

  if (!y.some((value) => value !== null && Number.isFinite(value))) {
    return null;
  }

  return {
    x: series.map((point) => window.SofuRates.wallTime(point.timestamp)),
    y,
    customdata: series.map((point) => formatTimestamp(point.timestamp)),
    type: "scatter",
    mode: "lines+markers",
    name: metric.label,
    yaxis: axisKey,
    line: {
      color: metric.color,
      width: metricKey === "soil_moisture_1" || metricKey === "soil_moisture_2" ? 3 : 2
    },
    marker: {
      color: metric.color,
      size: 5,
      opacity: 0.35
    },
    hovertemplate: `<b>${station.name}</b><br>${metric.label}: %{y:.2f} ${metric.unit}<br>%{customdata}<extra></extra>`
  };
}

function buildMetricTimeline(station, metricKey) {
  const series = filteredSeries(station).filter((point) => point[metricKey] !== null && point[metricKey] !== undefined);
  if (!series.length) return [];

  const recentSeries = series.filter((point) => point.resolution !== "daily");
  if (!recentSeries.length) {
    return addWaterYearBreaks(series, metricKey);
  }

  const recentStart = recentSeries[0].timestamp;
  const dailyBeforeRecent = series.filter(
    (point) => point.resolution === "daily" && point.timestamp < recentStart
  );

  return addWaterYearBreaks([...dailyBeforeRecent, ...recentSeries].sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp)), metricKey);
}

function buildMultiAxisLayout(selectedMetrics) {
  const leftExtraAxes = [];
  const rightExtraAxes = [];
  const axisStep = 0.08;

  selectedMetrics.forEach((metricKey, index) => {
    if (index === 0) return;
    if (index % 2 === 1) {
      rightExtraAxes.push(metricKey);
    } else {
      leftExtraAxes.push(metricKey);
    }
  });

  const layout = {
    margin: {
      t: 12,
      r: 90 + rightExtraAxes.length * 56,
      b: 56,
      l: 90 + leftExtraAxes.length * 56
    },
    paper_bgcolor: "rgba(0,0,0,0)",
    plot_bgcolor: "rgba(255,255,255,0.15)",
    font: {
      family: '"Segoe UI", sans-serif',
      color: "#1e2a2f"
    },
    legend: {
      orientation: "h",
      x: 0,
      y: 1.18
    },
    hovermode: "x unified",
    xaxis: {
      domain: [
        0.08 + leftExtraAxes.length * axisStep,
        0.92 - rightExtraAxes.length * axisStep
      ],
      title: "Time",
      range: chartDateRange(),
      tickformat: "%b %-d\n%Y",
      gridcolor: "rgba(30,42,47,0.08)",
      zeroline: false
    },
    dragmode: "zoom"
  };

  selectedMetrics.forEach((metricKey, index) => {
    const metric = metricConfig[metricKey];
    const axisName = index === 0 ? "yaxis" : `yaxis${index + 1}`;
    const axisDef = {
      title: {
        text: metric.unit ? `${metric.label} (${metric.unit})` : metric.label,
        standoff: 8
      },
      titlefont: { color: metric.color },
      tickfont: { color: metric.color },
      zeroline: false,
      automargin: true,
      showgrid: index === 0,
      gridcolor: index === 0 ? "rgba(30,42,47,0.08)" : undefined
    };

    if (index !== 0) {
      const rightIndex = rightExtraAxes.indexOf(metricKey);
      const side = rightIndex !== -1 ? "right" : "left";
      const offsetIndex = rightIndex !== -1 ? rightIndex : leftExtraAxes.indexOf(metricKey);
      const [domainStart, domainEnd] = layout.xaxis.domain;
      axisDef.overlaying = "y";
      axisDef.side = side;
      axisDef.anchor = "free";
      axisDef.position = side === "right"
        ? Math.min(0.99, domainEnd + axisStep * (offsetIndex + 1))
        : Math.max(0.01, domainStart - axisStep * (offsetIndex + 1));
    }

    layout[axisName] = axisDef;
  });

  return layout;
}

function renderMultiAxisBeta(station) {
  const panel = document.getElementById("multi-axis-beta-panel");
  const chart = document.getElementById("multi-axis-beta-chart");
  const title = document.getElementById("multi-axis-beta-title");

  if (!panel || !chart || typeof Plotly === "undefined") return;

  if (!station) {
    panel.classList.add("is-hidden");
    Plotly.purge(chart);
    return;
  }

  renderMultiAxisControls(station);

  const selectedMetrics = state.multiAxisMetrics.filter((metricKey) => getAvailableMetrics(station).includes(metricKey));
  if (!selectedMetrics.length) {
    panel.classList.add("is-hidden");
    Plotly.purge(chart);
    return;
  }

  const traces = selectedMetrics
    .map((metricKey, index) => buildMultiAxisTrace(
      buildMetricTimeline(station, metricKey),
      metricKey,
      station,
      index === 0 ? "y" : `y${index + 1}`
    ))
    .filter(Boolean);

  if (!traces.length) {
    panel.classList.add("is-hidden");
    Plotly.purge(chart);
    return;
  }

  panel.classList.remove("is-hidden");
  title.textContent = `${station.name}: Multi-variable beta`;

  const layout = buildMultiAxisLayout(selectedMetrics);

  const config = {
    responsive: true,
    displaylogo: false,
    modeBarButtonsToRemove: ["lasso2d", "select2d", "autoScale2d"],
    scrollZoom: true
  };

  Plotly.react(chart, traces, layout, config);
}

function renderDashboard() {
  if (!state.data) return;
  renderOverviewCards();
  renderStationPicker();
  renderMap();
  updateDashboard();
}

function updateDashboard() {
  const station = getCurrentStation();
  if (!station) return;
  renderVariablePicker(station);
  renderSelectedStationMeta(station);
  renderStationSummary(station);
  renderChart(station);
  renderMultiAxisBeta(station);
  renderPercentiles(station);
  const requestedMetric = state.metric;
  window.SofuRates?.render(document.getElementById("station-rolling-report"), station, requestedMetric).then(payload => {
    if (payload && state.stationId === station.id && state.metric === requestedMetric) {
      station.current_report = payload;
      renderPercentiles(station);
    }
  });
}

async function init() {
  const page = document.body.dataset.page;
  if (!["home", "dashboard"].includes(page)) return;
  document.querySelectorAll("[data-chart-window]").forEach(button => button.addEventListener("click", () => {
    state.chartWindow = button.dataset.chartWindow;
    document.querySelectorAll("[data-chart-window]").forEach(item => item.setAttribute("aria-pressed", String(item === button)));
    const station = getCurrentStation();
    if (station) { renderChart(station); renderMultiAxisBeta(station); }
  }));
  document.querySelectorAll("[data-percentile-day]").forEach(button => button.addEventListener("click", () => {
    state.percentileDay = button.dataset.percentileDay;
    document.querySelectorAll("[data-percentile-day]").forEach(item => item.setAttribute("aria-pressed", String(item === button)));
    const station = getCurrentStation();
    if (station) renderPercentiles(station);
  }));

  try {
    await loadData();
    const firstStation = getStations()[0];
    const requestedStation = getStations().find((station) => station.id === requestedStationId());
    state.stationId = requestedStation?.id ?? firstStation?.id ?? null;
    state.multiAxisMetrics = defaultMultiAxisMetrics(firstStation);
    setupMapModal();
    if (page === "home") renderHome();
    if (page === "dashboard") renderDashboard();
    if (page === "dashboard") setDashboardLoading(false);
  } catch (error) {
    console.error(error);
    if (page === "dashboard") {
      setDashboardLoading(true, "Station data could not be loaded. Please refresh the page.");
    }
  }
}

init();
