/* Browse the existing station catalog; observations keep their exported units. */
(() => {
  const root = document.getElementById("area-map");
  if (!root) return;
  const status = document.getElementById("area-status");
  const zoneSelect = document.getElementById("area-select");
  const sourceSelect = document.getElementById("area-source");
  const detail = document.getElementById("area-station-detail");
  const reportLink = document.getElementById("area-report-link");
  const version = document.body.dataset.build || "";
  const colors = { FEMS: "#bd602f", Synoptic: "#477b9b", Zentra: "#007d78" };
  const metrics = {
    soil_moisture_1: ["Soil moisture 1", "%"],
    soil_moisture_2: ["Soil moisture 2", "%"],
    air_temp: ["Air temperature", "F"],
    humidity: ["Relative humidity", "%"],
    precip_cumulative: ["Water-year precipitation", "in"],
    gsi: ["GSI", ""], kbdi: ["KBDI", ""]
  };
  const dateLabel = (value) => {
    if (!value || Number.isNaN(Date.parse(value))) return "Unavailable";
    return new Date(value).toLocaleString([], {
      timeZone: "America/Denver", month: "short", day: "numeric",
      hour: "numeric", minute: "2-digit", timeZoneName: "short"
    });
  };
  const element = (tag, text, className) => {
    const node = document.createElement(tag);
    node.textContent = text;
    if (className) node.className = className;
    return node;
  };
  function showStation(station) {
    detail.replaceChildren(element("p", station.api === "FEMS" ? "RAWS / FEMS" : station.api, "panel-label"),
      element("h3", station.name), element("p", `${station.id} · Updated ${dateLabel(station.latest_timestamp)}`, "panel-note"));
    const readings = element("dl", "", "area-readings");
    for (const [key, [label, unit]] of Object.entries(metrics)) {
      const value = station.latest?.[key];
      if (value === null || value === undefined || !Number.isFinite(Number(value))) continue;
      const group = document.createElement("div");
      group.append(element("dt", label), element("dd", `${Number(value).toFixed(key === "gsi" ? 2 : 1)} ${unit}`));
      if (station.latest_dates?.[key]) group.append(element("small", dateLabel(station.latest_dates[key])));
      readings.append(group);
    }
    const link = element("a", "Explore station →", "button button-secondary");
    link.href = `dashboard.html?station=${encodeURIComponent(station.id)}`;
    detail.append(readings, link);
  }
  async function load(path) {
    const response = await fetch(`${path}?v=${encodeURIComponent(version)}`);
    if (!response.ok) throw new Error(`Unable to load ${path}`);
    return response.json();
  }
  async function init() {
    if (typeof L === "undefined") throw new Error("Map library unavailable");
    const map = L.map(root, { scrollWheelZoom: false }).setView([45.7, -109.8], 7);
    const streets = L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors", maxZoom: 19
    }).addTo(map);
    const imagery = L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", {
      attribution: "Tiles &copy; Esri and contributors", maxZoom: 19
    });
    L.control.layers({ Streets: streets, "Esri World Imagery": imagery }).addTo(map);
    L.control.scale().addTo(map);
    const layers = L.layerGroup().addTo(map);
    const [dashboard, reportResult] = await Promise.all([
      load("data/dashboard.json"),
      load("data/reports.json").then(data => ({ data }), error => ({ error }))
    ]);
    const stations = (dashboard.station_catalog || dashboard.stations || []).filter(station =>
      station.latitude !== null && station.longitude !== null &&
      Number.isFinite(Number(station.latitude)) && Number.isFinite(Number(station.longitude)));
    const zones = reportResult.data?.zones || [];
    for (const zone of zones) {
      const option = element("option", zone.label);
      option.value = zone.slug;
      zoneSelect.append(option);
    }
    if (reportResult.error) zoneSelect.disabled = true;
    function render() {
      layers.clearLayers();
      detail.replaceChildren(element("p", "Select a station on the map to explore its observations.", "panel-note"));
      const zone = zones.find(item => item.slug === zoneSelect.value);
      const ids = zone ? new Set([zone.precip, zone.soil_moisture_1, zone.soil_moisture_2]
        .flatMap(group => (group?.rows || []).map(row => row.station_id))) : null;
      const selected = stations.filter(station => (!ids || ids.has(station.id)) &&
        (!sourceSelect.value || sourceSelect.value === station.api));
      for (const station of selected) {
        const marker = L.circleMarker([station.latitude, station.longitude], {
          radius: 7, color: "#fff", weight: 2, fillColor: colors[station.api] || "#526773", fillOpacity: 0.95
        }).addTo(layers);
        marker.bindTooltip(element("span", `${station.name} · ${station.api}`));
        marker.on("click", () => {
          showStation(station);
          const popup = document.createElement("div");
          const link = element("a", "Open station dashboard →");
          link.href = `dashboard.html?station=${encodeURIComponent(station.id)}`;
          popup.append(element("strong", station.name), document.createElement("br"), link);
          marker.bindPopup(popup).openPopup();
        });
      }
      if (selected.length) map.fitBounds(selected.map(station => [station.latitude, station.longitude]), { padding: [24, 24], maxZoom: 10 });
      status.textContent = `${selected.length} mapped stations${zone ? ` with report data in ${zone.label}` : ""}. Exported ${dateLabel(dashboard.generated_at)}.${reportResult.error ? " Zone reports unavailable; all stations remain available." : ""}`;
      reportLink.textContent = zone ? `Open ${zone.label} report` : "Browse zone reports";
      reportLink.href = zone ? `report-zone.html?zone=${encodeURIComponent(zone.slug)}` : "reports.html";
    }
    zoneSelect.addEventListener("change", render);
    sourceSelect.addEventListener("change", render);
    render();
  }
  init().catch(error => {
    console.error(error);
    status.textContent = "Station map could not load. You can still open the dashboard or zone reports above.";
  });
})();
