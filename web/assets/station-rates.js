/* Shared rolling-window reports backed by canonical hourly observations. */
window.SofuRates = (() => {
  const cache = new Map();
  const windows = { hours_24: [24, "24 hour"], days_2: [48, "2 day"], days_7: [168, "7 day"], days_30: [720, "30 day"] };
  const config = {
    soil_moisture_1: ["Soil moisture 1", "percentage points", 24],
    soil_moisture_2: ["Soil moisture 2", "percentage points", 24],
    air_temp: ["Air temperature", "F", 1], humidity: ["Relative humidity", "percentage points", 1],
    wind_speed: ["Wind speed", "mph", 1], precip_accum: ["Precipitation", "in", 24],
    gsi: ["GSI", "GSI units", 24], kbdi: ["KBDI", "KBDI units", 24]
  };
  const esc = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
  const number = value => value !== null && value !== undefined && Number.isFinite(Number(value));
  const fmt = value => number(value) ? Number(value).toLocaleString(undefined, { maximumFractionDigits: 3 }) : "Unavailable";
  const time = value => new Date(value).toLocaleString([], { timeZone: "America/Denver", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" });
  const metricKey = key => key === "precip" || key === "precip_cumulative" ? "precip_accum" : key;
  const dayKey = timestamp => wallTime(timestamp).slice(0, 10);
  function snapshot(payload, selectedKey, today = dayKey(Date.now())) {
    const key = metricKey(selectedKey);
    const points = (payload?.recent_series || []).filter(point => number(point[key]) && Number.isFinite(Date.parse(point.timestamp)) && Date.parse(point.timestamp) <= Date.now())
      .sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
    const hourly = [...new Map(points.map(point => [Math.floor(Date.parse(point.timestamp) / 3600000), point])).values()];
    if (!hourly.length) return null;
    const latest = hourly.at(-1);
    const day = dayKey(latest.timestamp);
    const values = hourly.filter(point => dayKey(point.timestamp) === day).map(point => Number(point[key]));
    return { day, isToday: day === today, timestamp: latest.timestamp, latest: Number(latest[key]),
      min: Math.min(...values), max: Math.max(...values), mean: values.reduce((a, b) => a + b, 0) / values.length,
      total: values.reduce((a, b) => a + b, 0), samples: values.length };
  }
  async function load(id) {
    if (!cache.has(id)) {
      const request = fetch(`data/current/weather/${encodeURIComponent(id)}.json?v=${encodeURIComponent(document.body.dataset.build || "")}`)
        .then(response => { if (!response.ok) throw Error("Recent observations are unavailable"); return response.json(); })
        .then(payload => { if (payload.id !== id) throw Error("Station identity mismatch"); return payload; })
        .catch(error => { cache.delete(id); throw error; });
      cache.set(id, request);
    }
    return cache.get(id);
  }
  function rateMarkup(row, windowKey, key, expanded = false) {
    key = metricKey(key);
    const info = row?.rate_details?.[windowKey];
    const raw = row?.rates?.[windowKey];
    const coverage = info ? ` · ${Math.round((info.coverage || 0) * 100)}% hourly coverage` : "";
    if (!number(raw)) return `<small class="report-window-rate">Rate unavailable${expanded ? coverage : ""}</small>`;
    const [, unit, scale] = config[key] || [key, "units", 24];
    const value = Number(raw) * scale;
    const rain = key === "precip_accum";
    const variable = !rain && number(info?.r_squared) && info.r_squared < .6;
    const tone = variable || Math.abs(value) < 1e-8 ? "stable" : (value > 0) !== (key === "kbdi") ? "increase" : "decrease";
    const arrow = rain ? "" : variable ? "↔ " : value > 0 ? "↑ " : value < 0 ? "↓ " : "→ ";
    const title = rain ? "Avg accumulation" : variable ? "Variable · fit" : "Fitted rate";
    return `<small class="report-window-rate report-change-${tone}">${arrow}${title} ${!rain && value > 0 ? "+" : ""}${fmt(value)} ${esc(unit)}/${scale === 24 ? "day" : "hour"}${expanded ? coverage : ""}${expanded && number(info?.r_squared) ? ` · R² ${Number(info.r_squared).toFixed(2)}` : ""}</small>`;
  }
  function wallTime(timestamp) {
    const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Denver", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23"
    }).formatToParts(new Date(timestamp)).map(part => [part.type, part.value]));
    return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}`;
  }
  function chartPoints(payload, key, hours) {
    const accumulated = key === "precip_cumulative";
    key = metricKey(key);
    const points = (payload.recent_series || []).filter(point => number(point[key]) && Number.isFinite(Date.parse(point.timestamp)))
      .sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
    if (!points.length) return [];
    const end = Date.parse(points.at(-1).timestamp);
    const selected = points.filter(point => accumulated
      ? Date.parse(point.timestamp) > end - hours * 3600000
      : Date.parse(point.timestamp) >= end - hours * 3600000);
    if (!accumulated) return selected;
    let total = 0;
    // Sum each observed hour once; missing intervals are never zero-filled.
    return [...new Map(selected.map(point => [Math.floor(Date.parse(point.timestamp) / 3600000), point])).values()]
      .filter(point => Number(point[key]) >= 0)
      .map(point => ({ ...point, observed_accumulation: total += Number(point[key]) }));
  }
  function renderPlot(target, payload, key, hours = 720) {
    const accumulated = key === "precip_cumulative";
    const points = chartPoints(payload, key, hours);
    key = metricKey(key);
    if (!target || typeof Plotly === "undefined") return;
    if (!points.length) { target.textContent = "No recent observations for this variable."; return; }
    const rain = key === "precip_accum";
    const x = [], y = [], labels = [];
    points.forEach((point, i) => {
      if ((!rain || accumulated) && i && Date.parse(point.timestamp) - Date.parse(points[i - 1].timestamp) > 5400000) {
        x.push(wallTime(Date.parse(points[i - 1].timestamp) + 3600000)); y.push(null); labels.push("");
      }
      x.push(wallTime(point.timestamp)); y.push(accumulated ? point.observed_accumulation : Number(point[key])); labels.push(time(point.timestamp));
    });
    const unit = key.startsWith("soil_moisture") || key === "humidity" ? "%" : config[key]?.[1] || "units";
    const trace = { x, y, customdata: labels, type: rain && !accumulated ? "bar" : "scatter", mode: "lines", connectgaps: false,
      name: accumulated ? "Observed accumulation" : rain ? "Hourly precipitation" : config[key]?.[0], line: { color: "#007d78", width: 2, shape: accumulated ? "hv" : "linear" }, marker: { color: "#477b9b" },
      hovertemplate: `%{customdata}<br>%{y:.3f} ${esc(unit)}<extra></extra>` };
    Plotly.react(target, [trace], { height: 280, margin: { l: 65, r: 20, t: 15, b: 45 },
      paper_bgcolor: "transparent", plot_bgcolor: "#f8fbfc", font: { family: "Segoe UI, sans-serif", color: "#172a33" },
      xaxis: { title: "Mountain time", type: "date" }, yaxis: { title: accumulated ? "Accumulated precipitation (in, selected window)" : rain ? "Precipitation (in/hour interval)" : unit },
      hovermode: "x unified" }, { responsive: true, displaylogo: false });
  }
  async function render(target, station, selectedKey) {
    if (!target) return;
    const key = metricKey(selectedKey);
    const request = `${station.id}:${selectedKey}`;
    target.dataset.request = request;
    if (typeof Plotly !== "undefined") target.querySelectorAll(".js-plotly-plot").forEach(plot => Plotly.purge(plot));
    target.innerHTML = '<p class="panel-note" role="status">Loading rolling changes and rates...</p>';
    try {
      const payload = await load(station.id);
      if (target.dataset.request !== request) return;
      const row = payload.metrics?.[key];
      if (!row) { target.innerHTML = '<p class="panel-note">No recent hourly observations for this variable.</p>'; return payload; }
      const [baseLabel, unit] = config[key] || [key, "units"];
      const label = selectedKey === "precip_cumulative" ? "Accumulated precipitation" : baseLabel;
      const stale = Date.now() - Date.parse(row.latest_timestamp) > 3 * 86400000;
      target.innerHTML = `<p class="panel-label">Station report · rolling windows</p><h3>${esc(label)} · changes and rates</h3>
        <p class="panel-note">${esc(station.name)} · ${esc(time(row.latest_timestamp))}${stale ? ' <span class="rate-stale">Stale observations</span>' : ""} · Windows end at the latest available reading.</p>
        <div class="rates-window-grid">${Object.entries(windows).map(([windowKey, [, windowLabel]]) => `<article class="metric-card"><span>${windowLabel} ${key === "precip_accum" ? "total" : "change"}</span><strong>${number(row.totals?.[windowKey]) && row.totals[windowKey] > 0 && key !== "precip_accum" ? "+" : ""}${fmt(row.totals?.[windowKey])}</strong><span>${esc(unit)}</span>${rateMarkup(row, windowKey, key, true)}</article>`).join("")}</div>
        <div class="rates-chart-tools"><label>Observation window <select data-rate-window>${Object.values(windows).map(([hours, label]) => `<option value="${hours}"${hours === 168 ? " selected" : ""}>${label}</option>`).join("")}</select></label><span class="panel-note">${selectedKey === "precip_cumulative" ? "Observed accumulation within selected window · missing hours excluded" : "Hourly observations · gaps remain visible"}</span></div><div class="rates-observation-chart"></div>
        <p class="panel-note">Rates require 80% hourly coverage and period span. A low fit (R² &lt; 0.60) is labeled variable. Soil moisture changes are percentage points. Daily GSI/KBDI records may lack hourly coverage for a rate.</p>`;
      const plot = target.querySelector(".rates-observation-chart");
      renderPlot(plot, payload, selectedKey, 168);
      target.querySelector("[data-rate-window]").addEventListener("change", event => renderPlot(plot, payload, selectedKey, Number(event.target.value)));
      const snap = snapshot(payload, key);
      if (snap) {
        const summary = key === "precip_accum" ? `Observed day total ${fmt(snap.total)} in` : `Minimum ${fmt(snap.min)} · Mean ${fmt(snap.mean)} · Maximum ${fmt(snap.max)}`;
        target.insertAdjacentHTML("afterbegin", `<div class="today-observations"><span class="panel-label">${snap.isToday ? "Today so far · provisional" : "Latest observed day · " + esc(snap.day)}</span><strong>Latest ${fmt(snap.latest)} ${esc(key.startsWith("soil_moisture") || key === "humidity" ? "%" : unit)}</strong><span>${summary} · ${snap.samples} hourly readings</span><small>${esc(time(snap.timestamp))}. Sampled statistics are incomplete until the local day ends.</small></div>`);
      }
      return payload;
    } catch (error) {
      if (target.dataset.request === request) target.innerHTML = '<p class="panel-note">Rolling rates are unavailable for this station. Existing daily charts and percentiles remain available.</p>';
    }
  }
  return { load, rateMarkup, render, renderPlot, chartPoints, snapshot, dayKey, wallTime, time };
})();
