# SOFU Report — Project Context

> Repository root: `/home/joshualerickson/sofureport-deploy`
>
> This document defines the stable goal, data model, ingestion rules, and known failure modes for the SOFU Report project. Read it before changing ingestion, database, aggregation, reporting, or deployment code.
>
> This is not a chronological work log. Temporary debugging notes and the current task plan belong elsewhere.

## 1. Project goal

SOFU Report is an R-based data pipeline and user-facing reporting system that:

1. Retrieves environmental data from multiple external APIs.
2. Normalizes and stores sensor observations in SQLite.
3. Maintains hourly site-level sensor data.
4. Calculates site-level daily summaries, including minimum, mean, and maximum.
5. Calculates site-level percentiles using a deliberately defined reference period.
6. Generates custom derived variables.
7. Serves the processed data through a website with:
   - an interactive dashboard; and
   - a report/table generator.

The central engineering goal is:

> Build and maintain the database efficiently, correctly, incrementally, and dynamically despite API throttling, late-arriving observations, overlapping data sources, missing transmissions, and changing station inventories.

A pipeline run is not successful merely because it completes. It is successful only when the resulting database is complete for the available source data, internally consistent, reproducible, and safe to rerun.

## 2. High-level architecture

```text
R package / workflow code
        |
        v
External APIs
  - Zentra Cloud
  - FEMS
  - Synoptic
  - EDDI
  - ForDRI
        |
        v
Source-specific retrieval and validation
        |
        v
Normalized source tables in SQLite
        |
        v
Cross-source station reconciliation
        |
        v
Canonical hourly site-variable observations
        |
        v
Daily summaries, percentiles, and custom variables
        |
        v
Dashboard and report/table generator
```

### Future frontend delivery goal

The `sofureport-facelift` frontend adopts the Kootenai project's compact
blue/teal styling and map-led navigation using SOFU's existing station catalog
and zone reports. AI synopsis calls and hydrology sections are excluded.
The home page zone filter shows stations with precipitation or soil-moisture
rows in that zone's existing report payload; "All stations" includes the full
exported station catalog. It does not imply new boundary assignments.
`make preview-frontend` serves working `web/` files on localhost:8081 while
reading data and raster frames from `output/latest`, without publishing edits
or running ingestion, statistics, or API requests. Frontend changes remain
unpublished until the usual frontend or site publishing command is run.

Rolling-rate exports are additive: the reports builder reads at most 31 days
of canonical raw observations per active station and writes
`data/current/weather/<station_id>.json`. It also adds `rates`, `rate_details`,
and `rate_method` to existing report rows. SQLite is opened read-only. Hourly
bins have equal weight. Non-precipitation rates use a linear fit; precipitation
uses observed interval accumulation divided by window duration. Both require
80% hourly coverage and span. Windows end at the latest valid reading of that
variable, whose timestamp remains visible. Fitted rates with R-squared below
0.60 are labeled variable. Daily-only GSI/KBDI may lack hourly rate coverage.
Soil-moisture and humidity changes use percentage points, not relative percent.
The rolling observation chart preserves the selected precipitation mode:
daily precipitation shows interval bars; accumulated precipitation shows the
running sum of observed hourly increments within the selected window. It is
not a water-year total (the lower historical chart provides that). Duplicate
hourly instants count once, missing intervals remain gaps, and no daily or
cumulative counter is summed again. Rolling-total cards and rate definitions
remain unchanged.
`make preview-rates` writes these exports under `output/facelift/data`; the
frontend preview uses that overlay before `output/latest/data`. Refresh the
overlay with that command when new DB observations should enter the preview.
The standard static build generates rate files alongside its report payload.
An explicit `SOFU_REPORTS_JSON_PATH` is an output destination and must be
honored even when the target file does not exist yet.

The current dashboard exports a single `data/dashboard.json` payload that is
approximately 33 MB and renders the full map/chart experience on page load.
This is acceptable for the current static deployment. Do not change that
contract incidentally.

When dashboard responsiveness becomes a priority, replace it deliberately with
a small station/map manifest plus on-demand per-station JSON requests. The
reports page already demonstrates this pattern through `data/reports.json` and
`data/stations/<station_id>.json`. Preserve cache-busting and the ability to
render the map before individual station history is fetched.

Known implementation components include:

- SQLite database: `sofu.sqlite`
- Main development workflow: `workflow_dev.R`
- Container entry workflow: `run_workflow.R`
- Report rendering: `report_test.Rmd`
- Docker volumes: `/data`, `/output`, and `/logs`
- Relevant environment variables:
  - `SYNOPTIC_TOKEN`
  - `FEMS_API_KEY`
  - `ZENTRACLOUD_TOKEN`

Verify current paths and names in the repository before editing. Existing code may contain transitional or legacy behavior.

## 3. Governing design principles

### 3.1 Incremental, idempotent ingestion

All ingestion must be safe to rerun.

A second run over the same source records must not:

- create duplicates;
- alter unrelated records;
- erase previously retrieved history;
- recompute the entire database unnecessarily; or
- depend on in-memory deduplication of the full table.

Prefer:

1. retrieving a bounded source-specific time window;
2. validating and normalizing it;
3. writing it to a staging table;
4. inserting or upserting into the destination table using a database-enforced unique key; and
5. updating source/station ingestion state only after the transaction succeeds.

Do not use the pattern:

```r
read full table -> bind old and new rows -> distinct() -> overwrite full table
```

This pattern is memory-inefficient, vulnerable to partial failure, and likely to stomp valid data.

### 3.2 Preserve source data before integration

FEMS, Synoptic, Zentra Cloud, EDDI, and ForDRI are distinct authorities with different schemas, update behavior, and failure modes.

Keep source-normalized observations separate before creating integrated products. Do not make a cross-source join the only surviving copy of retrieved data.

The zone roster (`main_ExportTable_zones.csv`, exported to `sites_in_cg`) defines
the active website/report station set. Raw and derived SQLite tables may retain
historical observations for stations that are no longer in that active roster.
Those retained rows are intentional and must be reported by QA as informational
history, not deleted or treated as referential-integrity failures.

`data/station_source_mappings.csv` is the explicit, narrow cross-source
supplement map. It is used only where a rostered station needs an additional
source for named fields. For example, an `overlay_fields = soil_moisture`
mapping may supply Synoptic soil measurements to a FEMS canonical station;
FEMS remains the authority for that station's weather and NFDRS fields.

ForDRI landing-page frames use fixed semantic classes, not per-build quantile
color scaling. The bins are centered on the standardized index value of zero:
exceptional drought through exceptionally moist at half-index increments, with
the outer drought/moist classes beyond -2 and +2 respectively. The source
GeoTIFF's `-9999` sentinel is treated as NoData before rendering.

The normal containerized static-site build refreshes the landing-page ForDRI
and EDDI assets. A source outage or source lag must retain the most recently
published valid frame sequence and must not fail the database or site build.

Dashboard history defaults to the rolling 365-day window ending on the build
date in America/Denver. Read daily statistics from the October 1 preceding that
window (plus a counter baseline day) before trimming the exported series.
Accumulated precipitation resets for each water year, including when the
October 1 observation is missing, and the UI breaks accumulation traces and
historical ribbons at the boundary. Do not sum only the visible dates to obtain
a water-year total. Stored daily-stat history remains unchanged.

Today-so-far min/mean/max are sampled from canonical hourly observations in
the local Mountain calendar day and explicitly labeled provisional. They use
today's historical daily-stat reference, exported separately as
`today_reference`, and never replace completed-day SQLite statistics. Missing
today readings remain unavailable; stale readings must not be labeled today.
Users can switch to the latest completed-day percentile view.

SOFU scheduled jobs share `logs/scheduled-refresh.lock`. Light refreshes run at
minute 15 every two hours outside the 06:15 and 18:15 Mountain full-maintenance
slots. Light runs use a two-day FEMS/Synoptic overlap and one-day Zentra window,
skip NFDRS, daily statistics, computed indices, historical percentiles and raster
downloads, and rebuild the static exports. Full maintenance runs refresh a
31-day FEMS/Synoptic overlap, budgeted historical Zentra gaps, recent daily statistics and
computed indices, and raster/site assets. Historical percentile maintenance is
still explicit (`docker-run-percentiles` or `docker-run-full`). No AI synopsis
or water/hydrology refreshes are included. The cron installer backs up the
existing crontab and preserves other projects' entries.

For Synoptic/FEMS stations, `precip_accum_set_1.mean` is a source running
counter. User-facing daily precipitation and its percentile bands must use
differences between consecutive complete-day counter endpoints, never raw
counter values. The raw field remains preserved in SQLite for provenance.

Each normalized record should retain enough provenance to identify:

- source API;
- source station identifier;
- canonical site identifier;
- source variable name;
- canonical variable name;
- observation timestamp;
- retrieval timestamp;
- source quality flags, when available; and
- transformation or unit-conversion version, when applicable.

### FEMS timestamp contract

For SOFU's FEMS `weatherObs` deployment, normalize the known source-clock
offset at the ingestion boundary, before `wrangle_to_hourly()`, SQLite keys,
daily summaries, or a FEMS-to-Synoptic overlay join.
`SOFU_FEMS_CLOCK_OFFSET_HOURS` defaults to `-6`. Preserve the source API
timestamp fields on client output as
`source_observation_time`, `source_observation_time_lst`, and equivalent
`source_display_*` fields. User-facing serializers must use the canonical
SQLite instant directly and must never apply a second FEMS display offset.

The FEMS weather query window must be expressed in the station-local timezone
with an explicit UTC offset, including daylight-saving changes. The FEMS API
guide identifies `observation_time` / `display_hour` as UTC and their `*_lst`
counterparts as local station time. NFDRS requests must explicitly use
`dateTimeFormat = LocalStationTime`; that endpoint's returned time is already
its canonical local reporting hour and does not receive the `weatherObs` clock
offset. FEMS/Synoptic overlay joins use the resulting canonical hourly timestamp
plus the explicit station mapping; do not use a tolerance join as the normal
integration rule.

For a bounded historical weather/Synoptic repair, `SOFU_FEMS_SKIP_NFDRS=1`
may be set. It skips only the expensive FEMS NFDRS retrieval and retains the
existing NFDRS fields while FEMS `weatherObs` and Synoptic observations are
staged and merged transactionally. Use it for weather or mapped-soil recovery,
not when NFDRS itself needs historical recovery.

`SOFU_SKIP_ZENTRA_INGEST=1` provides the corresponding API-isolation switch
for a Synoptic/FEMS-only repair. It does not alter Zentra rows or state and
prevents a non-Zentra repair from consuming Zentra v5 rate-limit capacity.

FEMS `weatherObs` and NFDRS are partial companion payloads at the same
canonical hourly key. The stage merge must coalesce missing staged values from
the existing row before exact-key replacement; a weather-only refresh must
never erase existing NFDRS values such as source GSI and KBDI.

### 3.3 Database constraints are part of correctness

Deduplication must be enforced in SQLite, not only in R.

Every observation table needs a deliberate natural or surrogate unique key. The logical key will usually include some combination of:

```text
source + source_station_id + variable + observation_timestamp
```

The exact key must reflect the source grain. Do not assume that `station_id + date` is sufficient when a table contains hourly data, multiple variables, sensor depths, or multiple devices.

### 3.4 Missing data are not zero

A missing API record, missing transmission, failed request, absent variable, and true zero measurement are different states.

Never replace missing observations with zero unless the variable definition explicitly requires it.

### 3.5 Late-arriving observations must propagate forward

When historical observations arrive after an earlier pipeline run:

1. insert or update the affected hourly records;
2. identify the affected site-variable-date combinations;
3. recompute only the dependent daily summaries, percentiles, and custom variables that could have changed; and
4. refresh affected user-facing outputs.

Do not assume that previously processed dates are immutable.

## 4. Canonical data layers

The implementation may use different physical table names, but the following logical layers must remain distinct.

### 4.1 Station registry

A station registry maps source-specific station identifiers to canonical sites.

Minimum logical fields:

| Field | Purpose |
|---|---|
| `site_id` | Stable internal site key |
| `source` | `zentracloud`, `fems`, `synoptic`, etc. |
| `source_station_id` | Identifier used by the source API |
| `wims_id` | Cross-source key where available |
| `station_name` | Human-readable name |
| `active` | Whether the source currently exposes the station |
| `first_seen_at` | First discovery by this pipeline |
| `last_seen_at` | Most recent discovery |
| `metadata_updated_at` | Last metadata refresh |

Do not delete a station merely because it disappears from one API response. Mark it inactive or unavailable while preserving its history.

### 4.2 Source-normalized observations

Each source gets an independently ingestible normalized layer.

The layer should preserve source semantics while standardizing:

- timestamps;
- units;
- variable names;
- station identifiers;
- missing values; and
- quality flags.

### 4.3 Canonical hourly observations

The canonical hourly layer is the stable input to summaries and the frontend.

Expected logical grain:

```text
one row per site_id + canonical_variable + observation_hour
```

Additional dimensions such as sensor depth, device, or measurement method must be included when they materially distinguish observations.

Every canonical value must retain provenance. A merged value must not obscure which source supplied it.

### 4.4 Derived products

Derived layers include:

- daily minimum;
- daily mean;
- daily maximum;
- site-level percentiles;
- custom variables;
- dashboard-ready data; and
- report/table-ready data.

Derived products are rebuildable. Source-normalized observations are not disposable merely because a derived table exists.

## 5. Source-specific rules

## 5.1 Zentra Cloud

### Source behavior

Zentra Cloud sensors transmit through cellular connections. A station can appear to miss one or more days even though the sensor collected the data. When connectivity returns, the endpoint may expose observations for those earlier days.

Therefore:

- absence today does not prove permanent absence;
- a single global `MAX(timestamp)` is not a safe retrieval boundary;
- a station-level request may need a moving overlap window;
- targeted historical backfills are normal, not exceptional; and
- retries must respect strict API throttling.

### Required ingestion behavior

The Zentra recovery engine lives in `sofureport/R/zentra_recovery.R`. Normal
full runs audit the rolling 365-day display horizon plus its preceding October
1 baseline, rather than clamping gaps to the current water year or 30 days.
Frequent runs audit the last three completed Mountain days plus today. This
overlap rechecks even previously populated days for delayed cellular uploads.
Days with missing hourly keys or missing
values in previously supported fields are candidates; a single row does not
prove that a day is complete. Field expectations begin at the first stored
non-missing observation; expected hours account for 23/25-hour Mountain days.

`zentra_recovery_state` is additive, keyed by `(station_id, local_date)`.
Canonical raw/derived keys are unchanged. Full scheduled runs group up to seven
adjacent local days with explicit POSIX instants, reducing the requests needed
for long communication gaps. `SOFU_ZENTRA_CHUNK_DAYS` overrides this (1-31).
Frequent runs group the
four-day recent overlap into one window per device, so the five-window budget
still reaches all five active devices instead of spending it on old overlap
days while omitting today's readings. Historical chunks extend
backward from the newest candidate, matching newest-first queue order; otherwise
the queue degenerates into one-day requests. Each chunk upserts only its returned
hourly keys, coalesces valid old measurements over incoming NAs, and commits
the retry checkpoint in the same transaction. Duplicate unchanged values do
not cause raw writes or mark statistics dirty. An interrupted later request
cannot lose earlier committed chunks. Ingestion is bounded by
`SOFU_ZENTRA_MAX_CHUNKS` (5 frequent / 12 scheduled by default).

Empty/error/unchanged windows remain retryable: the four-day recent overlap cools down for
two hours, older ones for 24 hours. Successful changes become eligible again
after an hour if gaps remain. Recent windows run first, then least-recently
attempted historical candidates, so an offline device cannot monopolize every
run. HTTP 401 fails the workflow immediately with an actionable credential
error; it must never become an empty successful fetch. HTTP 403/404/422 stop
further requests for that device in the current run. Retry-After, including
HTTP-date headers, takes precedence over the exponential retry delay.
Repeated pagination tokens fail rather than looping forever.
Query endpoints are serialized in UTC with equal offsets, even when the
requested local-day window crosses DST; stored instants and Mountain-day
aggregation do not change. Among equally attempted candidates, newer gaps
run before older gaps so bounded repairs prioritize recent missing periods.

Dirty dates widen dependent daily-stat/percentile refreshes even when the
repaired date is outside the usual statistics lookback. Scheduled full runs
refresh affected Zentra percentile keys before clearing the dirty flags.
Numeric SQLite daily dates must be converted from epoch days to Unix seconds
before `strftime` selects affected month/day keys.

`make docker-run-zentra-audit` writes gap/latest reports without fetching.
`make docker-run-zentra-repair MAX_CHUNKS=24` performs bounded resumable API
recovery, derives statistics, and republishes under the scheduled-job lock.
`make docker-run-zentra-derived` does only the latter steps without API calls.
The standalone repair rebuilds derived products on a scratch database,
validates unique keys, and publishes the active stations' stats/percentiles
together in one transaction, retaining existing live indexes. It saves a
pre-repair derived-table backup under `output/zentra-repair/`.

Do not edit a bind-mounted R entry script while its `Rscript` process is running:
the interpreter can encounter changed source later in the run. If ingestion
committed but later derivation/publication failed, use the derived-only target;
do not discard committed observations or re-fetch their API windows.

Targeted repairs accept `STATIONS`, `START`, `END`, and `CHUNK_DAYS` on the Make
repair target. Dates bound ingestion inclusively, and station filtering also
scopes derived-table publication. Existing checkpoints and cooldowns remain in
force. Larger contiguous windows (up to 31 days) reduce requests but still page
at UTC month boundaries. An empty response never closes a gap permanently.

The renewed token was verified on November 10, 2026. The earlier HTTP 401 was
caused by updating the secret in a different project folder. This deployment
mounts only its own `secrets/.Renviron`; branches share that ignored file, but
separate clones do not.

Future ingestion option: v5 reading-ID paging (`since_reading_id`) is documented
to capture late uploads independently of measurement time. It is not enabled:
adoption needs a per-device durable cursor, a raw-reading store keyed by
device/reading/series, full-hour recomputation across pages, and cursor commits
atomic with source writes. Do not simply attach a cursor to hourly averages:
splitting an hour across pages would replace a complete average with a partial
one. See https://docs.zentracloud.io/l/en/article/pep98lcz1h-get-device-readings.

Maintain ingestion state per source station, not only per source.

The state should distinguish:

- latest observation stored;
- latest timestamp requested;
- latest successful request;
- oldest unresolved gap;
- next backfill window;
- retry count;
- last error;
- last station metadata check; and
- whether a full initial backfill is complete.

Use a bounded overlap window when fetching incrementally. The overlap exists to discover late-arriving records. Do not use an ever-growing request from the beginning of record.

Recommended conceptual flow:

```text
discover stations
    |
    +-- new station -> enqueue bounded historical backfill
    |
    +-- existing station -> request recent overlap window
    |
    +-- known unresolved gaps -> enqueue targeted gap windows
    |
    v
rate-limited request queue
    |
    v
stage -> validate -> transactional upsert
    |
    v
update ingestion state
```

### Throttling rules

Zentra requests must be centrally controlled.

The retrieval layer should support:

- explicit batching;
- a configurable delay between calls;
- retry with bounded exponential backoff and jitter;
- honoring source-provided rate-limit or retry headers;
- checkpointing after each successful batch;
- resuming after interruption;
- logging request windows and station IDs; and
- stopping cleanly rather than repeatedly hammering the endpoint.

Do not scatter `Sys.sleep()` calls across unrelated functions. Rate limiting should have one controlling implementation.

Do not perform a broad refactor of working Zentra retrieval merely to make it stylistically consistent with another source. Changes to throttling, pagination, station loops, or backfill logic require focused tests.

### Gap detection

A gap detector may flag candidate missing intervals, but it must account for:

- the station's expected reporting interval;
- known inactive periods;
- recent records that may not have transmitted yet;
- timezone and daylight-saving behavior;
- duplicate transmissions; and
- source quality flags.

A detected gap is a retrieval task, not proof that the sensor failed.

## 5.2 FEMS and Synoptic

### Source relationship

FEMS and Synoptic contain some overlapping stations. FEMS provides several relevant sensor variables, while Synoptic may provide soil-moisture observations needed for those same sites.

The intended workflow is:

1. retrieve station metadata from each source;
2. retain only relevant stations and variables;
3. normalize each source independently;
4. map stations using `WIMS_ID` where available and valid;
5. add Synoptic soil-moisture observations to the corresponding canonical FEMS site; and
6. retain source provenance in the integrated record.

### Join rules

`WIMS_ID` is the preferred cross-source join key for the relevant overlap. It is not permission for an unconstrained many-to-many join.

Before joining, assert:

- `WIMS_ID` has the expected type and formatting;
- blank and missing IDs are excluded from automatic matching;
- each source's relevant station mapping has the expected cardinality;
- duplicate `WIMS_ID` values are reviewed;
- the temporal grain is compatible; and
- variable names and units have been normalized.

Do not join only on station name, display label, rounded coordinates, or row order.

Do not use an unrestricted `full_join()` and then resolve duplicate columns by suffix or broad `coalesce()`.

### Variable precedence

For the current overlap:

- FEMS remains the source for its supported variables.
- Synoptic supplies soil moisture where that is the intended missing FEMS variable.
- An explicit soil mapping must retain every valid Synoptic soil timestamp under
  the canonical FEMS station, even when FEMS has no observation at that exact
  hour. Exact-time matching may enrich a FEMS row, but it must not be used as
  a condition for retaining the Synoptic soil row.
- If both sources later provide the same canonical variable for the same site and time, do not silently choose one. Apply an explicit, documented precedence or retain both as separate source observations until the policy is decided.

A canonical row should include a `source` or equivalent provenance field.

### Precipitation contract

For FEMS, `hourly_precip` / `precip_accum_one_hour_set_1.mean` is an hourly
increment and is the authoritative input for rolling and daily precipitation
totals. `precip_accum_set_1.mean` is a cumulative counter and may reset; it is
only a fallback when an hourly increment is not available. Never combine the
two for the same station-hour.

For accumulated-precipitation percentile context, use the longest valid daily
record for each station. Recent FEMS years can use hourly increments, while
the historical FEMS cumulative counter is differenced within each water year
to retain the full period of record. The running accumulation resets at the
water-year boundary; it must not be interpreted as one all-time counter.

FEMS weather timestamps follow the ingestion-boundary contract above:
`SOFU_FEMS_CLOCK_OFFSET_HOURS` normalizes the known weather source-clock defect
before canonical hourly storage. The old serializer-only
`SOFU_FEMS_DISPLAY_OFFSET_HOURS` workaround is obsolete; do not reintroduce it.
NFDRS reporting timestamps remain separate and do not receive that weather
correction. Dashboard station "Latest update" selects the latest hourly row
with actual weather/soil measurements, not a later index-only GSI/KBDI row or
a carried-forward precipitation total. Zero rainfall is a valid measurement.
If hourly observations are unavailable, use the latest measured daily summary;
stations containing only indices retain their index reporting timestamp.
Per-variable report timestamps continue to identify that variable's reading.

FEMS may also return the remainder of a local day before those observations
have occurred. Ingestion therefore retains reported FEMS rows only through
`current_time + SOFU_FEMS_FUTURE_GUARD_HOURS` (default `6`) and removes older
future-looking FEMS rows during the same transactional merge. This guard is
an ingestion safeguard, not permission to shift displayed timestamps. Do not
change this allowance or canonical source times as part of a card-label fix;
Synoptic and Zentra timestamps are unaffected.

The FEMS GraphQL response may return optional weather fields as `null`. Those
fields must be normalized to `NA` per record before row binding; a null
optional field is not a failed station response.

### Daily overlap and missing-data recovery

The normal daily workflow uses bounded, source-specific overlap windows. These
windows are the routine protection against delayed API publication, an
interrupted cron job, and late-arriving observations; a successful repeat run
must safely replace the same station/timestamp keys without duplicates.

The overlap is sufficient for routine, recent lateness. It is not a guarantee
that a gap older than the configured window will be discovered or repaired on
its own. Treat a gap as a source-data QA finding, not a zero or permanent
sensor failure:

1. Confirm the source viewer/API returns the expected station-variable-time
   observations.
2. Verify the station's source mapping and canonical ID.
3. Run a bounded, source-specific raw backfill covering the gap.
4. Refresh daily summaries for the same dates, then derived products and
   percentiles only when their inputs or reference rows changed.
5. Rebuild the static payload after SQLite validation confirms the recovered
   rows and daily products.

For a newly added station, use a one-time period-of-record establishment; do
not widen every station's normal daily lookback. For repeated interior gaps,
promote the QA finding into a persisted targeted-gap queue or a scheduled
gap-recheck rather than continuously increasing the global overlap window.

For a confirmed Synoptic-only repair, `SOFU_SYNOPTIC_STATION_IDS` may limit
the API request to comma-separated mapped Synoptic IDs. It is a retrieval
scope only: it must validate against the active mapping and never alter the
station roster or canonical IDs.

### Establishing newly added FEMS stations

The zone roster's numeric `fems_fetch_id` is the authority for FEMS API
requests. A station added after the database was initialized needs a one-time
period-of-record establishment, rather than a globally widened daily
lookback. Run:

```bash
make docker-run-fems-establish STATIONS=CANONICAL_ID START_DATE=YYYY-MM-DD
```

This fetches the requested canonical roster station, then rebuilds its own
daily summaries and percentile keys without deleting or recomputing historical
products for unrelated stations. Subsequent daily ingestion returns to the
normal short overlap window.

### Unmatched stations

An unmatched FEMS or Synoptic station is not automatically an error.

Classify unmatched records as one of:

- expected source-only station;
- missing `WIMS_ID`;
- invalid or changed identifier;
- duplicate/ambiguous mapping; or
- newly discovered station requiring review.

Log and report these categories separately.

## 6. Dynamic station updates and callback checks

The system must support:

- stations missing recent transmissions;
- late-arriving observations;
- failed or partial API runs;
- newly added sites;
- metadata changes; and
- manual or scheduled refresh checks.

A refresh/check operation should not blindly rerun the entire history.

It should:

1. refresh station inventories;
2. identify newly discovered or changed stations;
3. inspect ingestion state;
4. enqueue recent overlap windows;
5. enqueue known gap windows;
6. enqueue initial backfill windows for new sites;
7. respect source-specific rate limits;
8. commit each successful unit of work; and
9. expose a clear completion summary.

The queue should be persistent enough that an interrupted run can resume without restarting all requests.

A callback or frontend-triggered refresh must enqueue work or invoke a bounded update workflow. It must not allow multiple uncontrolled full ingestions to run concurrently.

Use a lock, job table, or equivalent concurrency guard so that two refreshes do not write the same database simultaneously.

## 7. Aggregation rules

### Daily summaries

Daily minimum, mean, and maximum must be computed at an explicitly defined grain, normally:

```text
site_id + canonical_variable + local_date
```

The project must define:

- canonical timezone;
- whether a day is local calendar day or UTC day;
- minimum observation completeness required;
- handling of duplicated timestamps;
- handling of quality-flagged observations; and
- whether hourly values are raw observations or hourly aggregates.

Do not change these semantics during a performance refactor.

Routine derived runs refresh only their configured recent lookback. A full
historical daily-stat rebuild is an explicit maintenance action
(`SOFU_FULL_STATS_BACKFILL=1`), not an automatic response to a newly added or
historically incomplete metric.

### Percentiles

The percentile reference period and population are part of the scientific meaning.

Before changing percentile code, identify:

- percentile variable;
- grouping dimensions;
- historical reference period;
- seasonal or day-of-year window, if any;
- minimum sample size;
- missing-data treatment; and
- whether percentiles are static or recomputed as history grows.

Do not infer these choices from a function name. Preserve the existing accepted definition unless the owner explicitly changes it.

### Custom variables

Custom variables must declare:

- required input variables;
- units;
- temporal grain;
- valid range;
- missing-input behavior;
- dependency order; and
- recomputation scope after late-arriving data.

Do not hide domain formulas inside report-rendering code.

## 8. SQLite rules

### Writes

Prefer transactions and staging tables.

A safe write sequence is:

```text
begin transaction
create or clear staging table
write validated batch to staging
upsert into destination using explicit key
recompute affected derived rows
update ingestion state
commit
```

On failure, roll back and leave the previous valid state intact.

### Indexes

Indexes should support:

- observation uniqueness;
- station/time retrieval;
- site/variable/date summaries;
- `WIMS_ID` station mapping; and
- pending ingestion jobs.

Do not add many speculative indexes without checking write cost and query plans.

### Connection lifecycle

Keep database connection ownership clear. A function that did not open a connection should not close it unless that contract is explicit.

Previous work encountered `"Invalid or closed connection"` behavior. Do not re-enable WAL or broadly rewrite connection handling as an incidental optimization. Any WAL change must be isolated, tested in the containerized workflow, and verified against the actual connection lifecycle.

## 9. Logging and observability

Each ingestion run should make it possible to answer:

- Which source was called?
- Which station and time window were requested?
- How many records were returned?
- How many rows were inserted, updated, skipped, or rejected?
- Which gaps remain unresolved?
- Were any requests throttled or retried?
- Which derived dates were recomputed?
- Were new stations discovered?
- Did the report/dashboard data refresh succeed?

Logs must not expose API tokens or secrets.

A run summary should distinguish:

- complete;
- complete with unresolved source gaps;
- partially complete;
- rate-limited and resumable; and
- failed before commit.

## 10. Required invariants

These conditions must remain true:

1. Re-running the same successful batch does not duplicate observations.
2. Source-normalized data retain provenance.
3. Missing transmissions are not converted to zero.
4. Late-arriving Zentra records can update historical dates.
5. FEMS/Synoptic integration uses validated `WIMS_ID` mappings.
6. Cross-source joins cannot silently become many-to-many.
7. New stations can be added without rebuilding unrelated station history.
8. Failed requests do not advance successful-ingestion watermarks.
9. A partially failed batch cannot erase previously valid records.
10. Daily summaries are recomputed when their hourly inputs change.
11. API throttling is controlled centrally and is resumable.
12. The frontend reads stable, documented data products rather than partially written staging data.
13. Secrets remain outside source control.
14. A workflow completing without an error is not sufficient evidence of data completeness.

## 11. Prohibited shortcuts

Do not:

- read, bind, deduplicate, and overwrite an entire large table to append new data;
- use one global latest timestamp for all Zentra stations;
- assume a missing Zentra day will remain missing;
- retry throttled requests in a tight loop;
- advance a checkpoint before its database transaction commits;
- join FEMS and Synoptic using names or row positions;
- allow an accidental many-to-many `WIMS_ID` join;
- coalesce overlapping source variables without a source-precedence policy;
- overwrite raw/source-normalized data with integrated data;
- delete inactive stations or old observations during routine refreshes;
- recalculate all history when only a bounded set of dates changed;
- bury ingestion or domain logic inside the report template;
- refactor multiple API clients at once without source-specific tests;
- change table grain, timestamps, units, or percentile definitions as a side effect of optimization; or
- run concurrent uncontrolled refreshes against the same SQLite database.

## 12. Minimum validation scenarios

Changes to ingestion or database code must cover the relevant scenarios below.

### Idempotency

- Ingest the same API response twice.
- Confirm row counts and values remain correct.

### Late Zentra transmission

- First response omits a historical interval.
- Later response includes it.
- Confirm the historical rows are inserted and affected summaries are refreshed.

### Throttling and resume

- Simulate a rate-limit response mid-run.
- Confirm completed batches remain committed.
- Confirm the next run resumes from the pending queue/checkpoint.

### New station

- Add a station to source metadata.
- Confirm it is registered and backfilled without restarting all stations.

### FEMS/Synoptic overlap

- Map a valid one-to-one `WIMS_ID`.
- Confirm FEMS variables and Synoptic soil moisture appear under the correct canonical site with provenance.

### Ambiguous join

- Create duplicate or missing `WIMS_ID` values.
- Confirm the pipeline stops or quarantines the ambiguous mapping rather than multiplying rows.

### Partial database failure

- Fail after staging but before commit.
- Confirm destination tables and checkpoints remain unchanged.

### Missingness

- Confirm missing observations remain missing and are not counted as zeros in daily summaries.

### Derived-data refresh

- Change one hourly observation.
- Confirm only dependent dates/products are recomputed and user-facing data become consistent.

## 13. Change protocol for Codex

Before changing this project:

1. Read this document.
2. Inspect the current schema, unique indexes, and table grain.
3. Identify the source API and station/time scope involved.
4. State any assumptions about timestamps, keys, units, or missingness.
5. Determine whether the change affects late-arriving data, joins, checkpoints, or derived products.
6. Make the smallest coherent change.
7. Add or update focused tests before broad refactoring.
8. Run the representative workflow.
9. Inspect the SQLite results, not only console success.
10. Report:
    - files changed;
    - schema or data-contract changes;
    - validation performed;
    - rows inserted/updated/rejected where relevant;
    - unresolved gaps or assumptions; and
    - whether this document needs updating.

Do not treat current implementation quirks as the intended design. Do not replace working source-specific behavior with a generic abstraction unless the abstraction preserves each source's semantics and failure modes.

## 14. Open definitions that must be resolved explicitly

The following details should be documented once confirmed in code or by the project owner:

- canonical timezone and daily boundary;
- canonical hourly aggregation rule;
- exact percentile reference population and period;
- minimum completeness thresholds for daily summaries;
- accepted source precedence when FEMS and Synoptic overlap on variables other than soil moisture;
- expected Zentra reporting interval by station or sensor;
- initial backfill depth for a newly added station;
- recent Zentra overlap-window length;
- gap-recheck schedule and maximum historical lookback;
- canonical table names and unique keys;
- callback/refresh concurrency mechanism; and
- frontend contract for partially complete data.

Until resolved, Codex must surface these as assumptions rather than silently inventing values.
