function resolveLandingVersion() {
  return document.body?.dataset?.build || "";
}

const LANDING_VERSION = resolveLandingVersion();
const LANDING_MANIFEST = `assets/indices/manifest.json${LANDING_VERSION ? `?v=${LANDING_VERSION}` : ""}`;
const PLAYBACK_DELAY_MS = 800;

function displayDate(dateKey) {
  return new Date(`${dateKey}T12:00:00Z`).toLocaleDateString([], {
    timeZone: "America/Denver",
    month: "short",
    day: "numeric",
    year: "numeric"
  });
}

function buildPlayer(product, assetVersion) {
  const frames = product.frames || [];
  const card = document.createElement("article");
  card.className = "landing-index-card panel";

  if (!frames.length) {
    card.innerHTML = `
      <p class="panel-label">${product.label}</p>
      <h2>${product.label} is not available</h2>
      <p>${product.error || "No map frames were returned for this product yet."}</p>
    `;
    return card;
  }

  card.innerHTML = `
    <div class="landing-index-heading">
      <div>
        <p class="panel-label">Drought outlook</p>
        <h2>${product.label}</h2>
      </div>
      <div class="landing-heading-actions">
        <span class="landing-frame-date" data-frame-date></span>
        <button class="landing-expand-button" type="button" data-expand aria-label="Open ${product.label} in fullscreen">Expand</button>
      </div>
    </div>
    <p class="landing-index-description">${product.description}</p>
    <figure class="landing-map-figure">
      <img alt="${product.label} map for the SOFU reporting area" data-frame-image />
      <figcaption>${product.frame_count} available map frames. Use the date range to constrain playback.</figcaption>
    </figure>
    <div class="landing-controls">
      <div class="landing-playback-buttons">
        <button class="landing-play-button" type="button" data-play>Play</button>
        <button class="landing-stop-button" type="button" data-stop>Stop</button>
      </div>
      <label>
        Start date
        <input type="range" min="0" max="${frames.length - 1}" value="0" step="1" data-start />
        <output data-start-label></output>
      </label>
      <label>
        End date
        <input type="range" min="0" max="${frames.length - 1}" value="${frames.length - 1}" step="1" data-end />
        <output data-end-label></output>
      </label>
    </div>
  `;

  const image = card.querySelector("[data-frame-image]");
  const currentDate = card.querySelector("[data-frame-date]");
  const startInput = card.querySelector("[data-start]");
  const endInput = card.querySelector("[data-end]");
  const startLabel = card.querySelector("[data-start-label]");
  const endLabel = card.querySelector("[data-end-label]");
  const playButton = card.querySelector("[data-play]");
  const stopButton = card.querySelector("[data-stop]");
  const expandButton = card.querySelector("[data-expand]");
  let currentIndex = 0;
  let timer = null;

  const stop = () => {
    if (timer) window.clearInterval(timer);
    timer = null;
    playButton.textContent = "Play";
    card.classList.remove("is-playing");
  };

  const render = (index) => {
    currentIndex = Math.max(Number(startInput.value), Math.min(index, Number(endInput.value)));
    const frame = frames[currentIndex];
    image.src = `assets/indices/${frame.file}?v=${encodeURIComponent(assetVersion)}`;
    currentDate.textContent = displayDate(frame.date);
    image.alt = `${product.label} map for ${displayDate(frame.date)}`;
  };

  const updateRange = () => {
    if (Number(startInput.value) > Number(endInput.value)) {
      endInput.value = startInput.value;
    }
    startLabel.value = displayDate(frames[Number(startInput.value)].date);
    endLabel.value = displayDate(frames[Number(endInput.value)].date);
    render(currentIndex);
  };

  startInput.addEventListener("input", () => {
    stop();
    updateRange();
  });
  endInput.addEventListener("input", () => {
    stop();
    updateRange();
  });
  stopButton.addEventListener("click", stop);
  expandButton.addEventListener("click", async () => {
    try {
      if (document.fullscreenElement === card) {
        await document.exitFullscreen();
      } else {
        await card.requestFullscreen();
      }
    } catch {
      // Fullscreen is optional browser behavior; the map remains usable inline.
    }
  });
  document.addEventListener("fullscreenchange", () => {
    expandButton.textContent = document.fullscreenElement === card ? "Exit full screen" : "Expand";
  });
  playButton.addEventListener("click", () => {
    if (timer) {
      stop();
      return;
    }
    if (currentIndex >= Number(endInput.value)) render(Number(startInput.value));
    timer = window.setInterval(() => {
      const next = currentIndex >= Number(endInput.value)
        ? Number(startInput.value)
        : currentIndex + 1;
      render(next);
    }, PLAYBACK_DELAY_MS);
    playButton.textContent = "Pause";
    card.classList.add("is-playing");
  });

  updateRange();
  return card;
}

async function initLandingIndices() {
  const grid = document.querySelector("[data-landing-index-grid]");
  if (!grid) return;

  try {
    const response = await fetch(LANDING_MANIFEST);
    if (!response.ok) throw new Error(`No published map manifest (${response.status}).`);
    const manifest = await response.json();
    const products = manifest.products || [];
    const assetVersion = manifest.generated_at || LANDING_VERSION || "current";
    grid.replaceChildren(...products.map((product) => buildPlayer(product, assetVersion)));

    const generated = document.querySelector("[data-landing-generated]");
    if (generated) {
      generated.textContent = manifest.generated_at
        ? `Map assets published ${new Date(manifest.generated_at).toLocaleString([], { timeZone: "America/Denver" })}.`
        : "Static map assets are ready.";
    }
  } catch (error) {
    grid.innerHTML = `
      <article class="landing-index-empty panel">
        <p class="panel-label">Drought outlooks</p>
        <h2>Map sequences are not published yet</h2>
        <p>Run <code>make landing-assets</code> to download, crop, and publish the latest ForDRI and EDDI frames.</p>
      </article>
    `;
  }
}

document.addEventListener("DOMContentLoaded", initLandingIndices);
