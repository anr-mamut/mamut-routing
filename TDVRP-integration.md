# TDVRP extension via hourly urban-traffic simulation

## Context

The MAMUT-routing platform currently generates **CVRP** and **VRPTW** instances from real cartographic data (OSM via `OpenStreetMapX.jl` / `OSMToolset.jl`) and publishes them through a Leaflet webapp. Travel times are **static** — computed once from per-road-class free-flow speeds (`SPEED_ROADS_URBAN`) — which makes the platform unable to represent **rush-hour congestion**, the central phenomenon TDVRP research addresses.

This plan extends the existing pipeline to also produce **Time-Dependent VRP** instances. The approach: simulate a population of synthetic commuters whose home→work and work→home trips load the road network across the 24 hours of a typical working day; use the resulting per-edge flows to derive per-edge per-hour speeds via a BPR (Bureau of Public Roads) volume-delay function; aggregate those speeds into a `24 × N × N` time-dependent arc-cost tensor; enforce the **FIFO property** (Ichoua-Gendreau-Potvin) by isotonic monotonization of the arrival-time function; and serialize the result through the existing benchmark data contract (additive optional fields, schema bump to `1.1.0`).

The synthetic commuters are **decoupled** from the TDVRP delivery customers: commuters generate traffic; customers are the nodes the delivery fleet must visit. **v1 scope**: generation pipeline + schema additions + Leaflet hourly heatmap. **v1 does not include a TDVRP solver** (PyVRP does not natively support time-dependent travel times; a solver is left for v2).

## Scientific design

### 1. Synthetic commuter population

A commuter $i$ is a tuple $(\text{home}_i, \text{work}_i)$ of two road-graph vertices.

- **Home sampling** — new sampler `select_residential_nodes(map_data, n_homes, seed)` queries OSM polygons tagged `landuse=residential` (and `landuse=living_street` as fallback) via `OSMToolset.find_poi` (or a direct Overpass query if the helper does not support area tags), then snaps the polygon centroids — or, better, a Poisson sample inside each polygon weighted by polygon area — to the nearest graph vertex. Fallback when `landuse` data is sparse: reuse the existing `select_customers_parametric` with `customerMode="clustered"` and a *broader* spatial decay (e.g. `decay_m = 2000`), interpreted as "city-wide residential density".
- **Work sampling**: reuse `select_customers_poi()` with an *expanded* category set (`amenity`, `office`, `shop`, `industrial`, `university`) — the existing function already returns POIs snapped to graph vertices.
- The commuter population $|C|$ is a generator parameter (default $|C| \in [1000, 5000]$, scaled with city size). It is **independent** of the customer count $N$.

### 2. Daily activity schedule

Commuter $i$ generates four candidate trips per day, each fired with a probability drawn from a per-hour distribution:

| Trip type | Direction | Departure-time PDF | Population fraction |
|---|---|---|---|
| Morning commute | home → work | $\mathcal{N}(\mu=8.0, \sigma=0.75)$ | $A_1 = 1.0$ |
| Lunch return | work → home | $\mathcal{N}(\mu=12.0, \sigma=0.50)$ | $A_2 = 0.25$ |
| Lunch back-to-work | home → work | $\mathcal{N}(\mu=13.5, \sigma=0.50)$ | $A_2 = 0.25$ (same agents as above) |
| Evening commute | work → home | $\mathcal{N}(\mu=17.0, \sigma=1.00)$ | $A_1 = 1.0$ |

These mixture parameters match well-documented stylized facts (sharper morning peak; broader evening peak with 17h mode and tail to 20h; small bimodal lunch reverse; symmetry between morning and evening volumes). They are **exposed as generator config** so they can be re-fit per city if empirical OD data becomes available later.

Discretization: each trip is assigned to its departure hour bin $h \in \{0, \ldots, 23\}$ by integrating the PDF over the bin.

### 3. Flow assignment

For each hour bin $h$ and each trip in bin $h$, route the commuter on the **free-flow shortest path** (Dijkstra over `MapData.w` weighted by free-flow travel time). For an MVP this is *static user-equilibrium-free assignment* — each commuter assumed to know free-flow times only, ignoring the congestion they collectively create. This is the standard simplification used in published TDVRP benchmark generators (e.g. Figliozzi 2012).

Per-edge per-hour flow: $f_e(h) = $ number of commuter-trip traversals of edge $e$ during bin $h$.

### 4. Edge speed model (flow → speed)

Use the **BPR volume-delay function** to convert hourly flow to hourly travel time on edge $e$:

$$ t_e(h) = t_e^{\text{free}} \cdot \left(1 + \alpha \cdot \left(\frac{f_e(h)}{c_e}\right)^\beta \right) $$

with $\alpha = 0.15$, $\beta = 4$ (standard BPR coefficients). Edge capacity $c_e$ is derived from the OSM `highway` class via a small lookup (e.g. `motorway`: 2000 veh/h/lane, `primary`: 1500, `residential`: 600). Lane count from `lanes=*` tag (default 1) multiplies capacity.

Speed: $v_e(h) = \ell_e / t_e(h)$ where $\ell_e$ is edge length.

A **calibration knob** `traffic_intensity` $\in (0, 1]$ scales the commuter count so that the *average* peak-hour BPR multiplier matches a target (e.g. 1.8× — typical urban congested-vs-free-flow ratio).

### 5. From edge speeds to the 24×N×N arc-cost tensor

For each ordered customer pair $(i, j)$:

1. Compute the **free-flow shortest path** $P_{ij}$ once (reuse `dijkstra_shortest_paths` already in `osm_generation.jl`).
2. For each departure hour $h$, compute $\tau_{ij}(h)$ by **Ichoua-Gendreau-Potvin integration**: walk the edges of $P_{ij}$ in order, advancing the simulated clock; the speed used on each edge segment is the speed corresponding to the *current* hour bin at the moment the vehicle enters the edge. This is the standard IGP semantics — it natively handles boundary crossings.
3. Assemble $\mathbf{T}[h, i, j] = \tau_{ij}(h)$.

**Note** — the path $P_{ij}$ is fixed (free-flow optimal). A fully dynamic TDVRP would re-route per departure hour; we deliberately freeze the path to keep travel times comparable across hours and to keep the cost tensor a function of $h$ only. This is a deliberate, documented simplification (the same one used in IGP 2003).

### 6. FIFO enforcement by isotonic monotonization

After step 5, the discrete tensor may violate the FIFO property: for some $(i,j)$ and $h_1 < h_2$ we may have $h_1 \cdot \Delta + \mathbf{T}[h_1,i,j] > h_2 \cdot \Delta + \mathbf{T}[h_2,i,j]$ (departing later arrives earlier — non-physical). Enforce FIFO by **isotonic-up rounding of the arrival function**:

```
for (i, j):
  arrival[h] = h*Δ + T[h, i, j]              # for h in 0..23
  running_max = -inf
  for h in 0..23:
    running_max = max(running_max, arrival[h])
    arrival[h] = running_max
  T[h, i, j] = arrival[h] - h*Δ              # write back
```

This is **isotonic regression with the running-max operator** — it is the unique minimal upward correction that produces a FIFO-compliant tensor. It is preferable to rounding *down* because it preserves VRPTW time-window feasibility margins: a corrected travel time is never *smaller* than the simulated one. The total mass of corrections is logged in the manifest as a quality metric.

### 7. Data contract

**Additive optional schema extension; bump schema version `1.0.0 → 1.1.0`.**

Python — `MAMUT-routing-lib/src/mamut_routing_lib/models.py`:

```python
class ProblemType(str, Enum):
    CVRP = "CVRP"
    VRPTW = "VRPTW"
    TDVRP = "TDVRP"   # NEW

class BenchmarkInstanceTDVRP(_InstanceValidationMixin):
    """TDVRP instance. arc_costs[h][i][j] is travel time from i to j when
    departing during hour bin h. Time horizon is 24 bins × 3600 s = 86400 s."""
    instance_name: str
    num_customers: int
    vehicle_capacity: int
    coordinates: list[tuple[float, float]]
    demands: list[int]
    service_times: list[int]
    time_windows: list[tuple[int, int]]
    arc_costs_time_dependent: list[list[list[ArcCost]]]   # [H][N][N]
    num_time_bins: int = 24
    bin_seconds: int = 3600
```

Plus an optional `arc_costs` field (static fallback = `mean_h arc_costs_time_dependent[h]`) so naive consumers can still load the instance as a VRPTW.

Julia — `webapp/io-json-vrp.jl`: mirror `BenchmarkInstanceTDVRP` struct with `arc_costs_time_dependent::Vector{Vector{Vector{T}}}`.

Instance on disk:
```
benchmarks/TDVRP/Mamut2026/n={N}/{instance_id}/
  ├── {instance_id}.manifest.json   # generation params + FIFO correction stats
  ├── {instance_id}.meta.json       # coordinates, road_cache, edge_speed_profiles
  └── {instance_id}.tdvrp.json      # the tensor instance (NOT TSPLIB; JSON)
```

TSPLIB `.vrp` format is intentionally **not** used for TDVRP — its `EDGE_WEIGHT_SECTION` has no time dimension and there is no broadly adopted standard for time-dependent extension. JSON is honest about this.

The `meta.json` also stores the **per-OSM-edge hourly speed profile** `edge_speeds[edge_id] = [v_0, v_1, …, v_23]`, used by the webapp heatmap and as ground-truth/raw data should a solver later need it.

## Implementation plan (files & changes)

### A. New Julia module — `webapp/traffic_simulation.jl`
Pure-Julia, alongside `osm_generation.jl`. Public functions:
- `select_residential_nodes(map_data, n, seed; landuse_fallback=true)` — landuse=residential sampler with parametric fallback.
- `sample_commuter_population(map_data, n_commuters, schedule_params, seed)` → `Vector{Commuter}`.
- `simulate_hourly_flows(map_data, commuters, schedule_params)` → `Dict{EdgeId, Vector{Int}}` (length 24 per edge).
- `bpr_speeds(map_data, flows; α=0.15, β=4)` → `Dict{EdgeId, Vector{Float64}}` (m/s, length 24 per edge).
- `time_dependent_arc_costs(map_data, customer_nodes, edge_speeds)` — IGP integration along precomputed shortest paths; returns `Array{Float64,3}` of shape `(24, N, N)`.
- `enforce_fifo!(T; bin_seconds=3600)` — in-place isotonic-up monotonization; returns total correction mass.

### B. Generation entry point — extend `webapp/osm_generation.jl`
- New `generate_single_tdvrp_instance(...)` paralleling existing `generate_single_instance` (line 1620). Reuses `build_generation_selection` for customer sampling (POI / parametric / hybrid — unchanged); adds commuter population + traffic sim; writes `{instance_id}.tdvrp.json` and `_meta.json` (with `edge_speeds`).
- New `write_tdvrp_json(...)` replacing the role of `write_cvrplib` for TDVRP.

### C. Python schema — `MAMUT-routing-lib/src/mamut_routing_lib/models.py`
- Add `ProblemType.TDVRP`, `BenchmarkInstanceTDVRP`. Bump `SCHEMA_VERSION` (or the equivalent constant — currently `"1.0.0"`) to `"1.1.0"`. Add validator: tensor shape consistency, `bin_seconds × num_time_bins == 86400`, FIFO check (warning-level).

### D. Publisher — `src/mamut_routing_publish/site_payloads.py`
- Add `payload_kind = "instance_page_tdvrp"`.
- Discover `benchmarks/TDVRP/**` paralleling existing CVRP/VRPTW discovery.
- Include `edge_speeds` (downsampled if large — e.g. only edges traversed by at least one customer-to-customer route) in the instance payload so the webapp heatmap can render without a server roundtrip.

### E. Webapp heatmap — Leaflet
- `src/mamut_routing_publish/site_assets/workbench.js`: add hour slider control (0..23) for `instance_page_tdvrp` payloads. On slider change, color each cached road edge polyline by $v_e(h)/v_e^{\text{free}}$ on a green→red colormap (Viridis or RdYlGn_r). Reuse the existing `cached_road` polyline rendering path in `workbench_render_routes_payload` (site_api.jl:1098).
- `dist/workbench/index.html`: include the slider in the layout; no new JS dependency.

### F. CLI / config exposure
- Extend the existing generator config (see `osm_generation.jl` config knobs near line 1620) with:
  `commuter_count`, `traffic_intensity`, `schedule_morning_mu/sigma`, `schedule_evening_mu/sigma`, `lunch_share`, `bpr_alpha`, `bpr_beta`, `capacity_table`.
- All knobs surfaced via the existing CLI/JSON config; default to the literature values above.

## Critical files (read/modify)

- `webapp/osm_generation.jl` — extend, do not rewrite. Hotspots: `build_generation_selection` (~l. 1000), `compute_matrices` (~l. 880), `generate_single_instance` (~l. 1620), `write_cvrplib`, `write_instance_metadata`.
- `webapp/io-json-vrp.jl` — add `BenchmarkInstanceTDVRP` struct mirroring Python model.
- `webapp/site_api.jl` — `workbench_render_routes_payload` (~l. 1098); add TDVRP payload branch + edge-speed-coloring metadata in GeoJSON properties.
- `MAMUT-routing-lib/src/mamut_routing_lib/models.py` — add TDVRP model + version bump.
- `src/mamut_routing_publish/site_payloads.py` — TDVRP discovery + payload.
- `src/mamut_routing_publish/site_assets/workbench.js` — hour slider + colormap.
- New: `webapp/traffic_simulation.jl`.

## Verification

1. **Unit sanity**:
   - On a 2×2 toy graph with one commuter doing a round trip, assert the hourly flow vector is `[0,0,…,1 at 8h,…,1 at 17h,…,0]`.
   - On a chain graph, assert BPR formula matches a hand-computed value within 1e-9.
   - Pathological case: build a tensor that violates FIFO; assert `enforce_fifo!` makes it FIFO-compliant; assert it is a no-op on an already-FIFO tensor.
2. **End-to-end generation**: run the TDVRP generator on Brest (small map, already in the benchmark catalog). Verify:
   - The 24 per-edge speed profiles show a visible morning and evening peak at high-traffic arterials.
   - Travel time from depot to a far customer is ≥30% higher at 8h than at 3h.
   - The FIFO correction mass is logged in the manifest and is < 5% of total tensor mass (sanity threshold).
3. **Schema round-trip**: Pydantic deserializes the produced `.tdvrp.json`; Julia's `io-json-vrp.jl` re-reads it; the two reconstructions agree element-wise.
4. **Webapp**: launch the local webapp (`julia --project=webapp -t auto webapp/run_site_api.jl`); open an `instance_page_tdvrp`; verify the hour slider re-colors the network; verify edges with high simulated flow (e.g. ring roads) are visibly red around 8h and 17h and green at 3h.
5. **Regression**: existing CVRP/VRPTW catalogs continue to publish unchanged (schema 1.0.0 instances still validate under 1.1.0 models because new TDVRP fields are optional).

## Out of scope for v1 (v2 backlog)

- **TDVRP solver**. PyVRP does not natively support time-dependent travel times. Options for v2: (a) extend PyVRP at C++ level (heavy), (b) integrate an external TDVRP solver (e.g. `pyvroom` does not support TD either; `OptaPy`/`Timefold` do), (c) write a Julia HGS-TW variant that integrates over $\mathbf{T}$. Decision deferred until v1 instances exist and have been visually validated.
- **Time-dependent shortest-path re-routing** per departure hour. v1 freezes paths at free-flow optimum; v2 may add IGP-style dynamic routing.
- **Stochastic user-equilibrium assignment**. v1 uses deterministic shortest-path assignment ignoring self-congestion; v2 may iterate to a Wardrop equilibrium.
- **Empirical OD calibration** per city using INSEE EDT / Eurostat commute data. v1 uses literature default mixture parameters; v2 can fit per-city.

---

# v1.5 — Workbench UI integration

## Context (v1.5)

v1 produces TDVRP instances end-to-end via the Julia generator (`generate_single_tdvrp_instance`) and exposes a self-contained Leaflet heatmap + slider overlay in `workbench.js`, but the latter is **only reachable via `?tdvrp_demo=<url>`** — there is no first-class entry point in the UI. A user cannot select TDVRP in the Generate tab, cannot tweak the time-dependent parameters from the form, and cannot visualize a generated instance in one click. This iteration grafts TDVRP onto the existing 3-button generation flow (**Display on Map** / **Generate Data** / **Write Files**), reusing the `problemType`-dispatch pattern already used for VRPTW, and turns the static map view into a heatmap + animated hour slider whenever a TDVRP instance is in scope.

User-chosen design constraints:
- **Visualization stays on the Generate tab** (no auto-switch to Visualize), rendered inline in the always-visible map pane — encourages parameter iteration.
- **Two-tier parameter UI**: basic controls always visible; an `<details>` "Advanced parameters" panel for BPR coefficients, schedule μ/σ, work categories, etc. Matches the existing `<details>` pattern used for the POI category menu.
- **Hour controls**: slider 0–23 plus Play/Pause animation (~2 bins/sec) plus Reset.
- **Two preview tiers + full generate**, mapped onto the existing buttons:

  | Button         | Server endpoint                           | What it does                                                                                  | Latency on Brest |
  |----------------|--------------------------------------------|-----------------------------------------------------------------------------------------------|------------------|
  | Display on Map | `/api/workbench/generation/preview`        | Flow simulation + BPR speeds; renders heatmap at preview hours (default `[3,8,12,17,22]`). **Skips** the customer-pair tensor. | ~5 s |
  | Generate Data  | `/api/workbench/generation/generate`       | Full pipeline in memory: flows + BPR + 24×N×N IGP tensor + FIFO. **No disk write.** Slider spans 0..23. | ~30 s |
  | Write Files    | `/api/workbench/generation/single`         | Same as Generate Data, plus persists `.tdvrp.json`, `_meta.json`, `_manifest.json`.           | ~30 s + I/O |

## UX flow (v1.5)

1. User opens `/workbench/`, clicks Generate tab.
2. Selects city, method, customers (existing flow); changes **Problem type** to TDVRP.
3. The `.gen-field-tdvrp` fieldset becomes visible: a basic row (Commuter count, Traffic intensity range slider with live value, Preview hours text input) and a collapsed `<details>` "Advanced parameters".
4. Clicks **Display on Map**: server returns per-edge profiles for the preview hours. JS clears any existing route/marker layers and mounts the TDVRP overlay (heatmap + hour slider restricted to preview hours + Play/Pause + customer/depot markers). Map auto-fits.
5. User scrubs the slider, presses Play to watch the animation, tweaks Traffic intensity and re-previews. When satisfied, clicks **Generate Data** — slider expands to full 24-hour range and stats include FIFO correction ratio.
6. Clicks **Write Files** to persist; toast shows file paths.

## UI surface changes

### A. `src/mamut_routing_publish/site_webapp.py` — extend `_render_workbench_shell_html()`

1. Add `<option value="TDVRP">TDVRP — time-dependent travel times</option>` to `genProblemTypeSelect`.
2. After the existing `<fieldset id="genVrptwFieldset" class="field gen-field-vrptw">`, add a sibling:

```html
<fieldset class="field gen-field-tdvrp" id="genTdvrpFieldset" hidden>
  <legend>Time-dependent traffic</legend>
  <label class="field">
    <span>Commuter count</span>
    <input id="genTdvrpCommuterCountInput" type="number" min="50" max="50000" step="50" value="1500" />
  </label>
  <label class="field">
    <span>Traffic intensity <span id="genTdvrpTrafficIntensityValue">1.00</span></span>
    <input id="genTdvrpTrafficIntensityInput" type="range" min="0.05" max="3" step="0.05" value="1.0" />
  </label>
  <label class="field">
    <span>Preview hours (comma-separated)</span>
    <input id="genTdvrpPreviewHoursInput" type="text" value="3,8,12,17,22" />
  </label>
  <details class="gen-tdvrp-advanced">
    <summary>Advanced parameters</summary>
    <label class="field"><span>BPR α</span><input id="genTdvrpAlphaInput" type="number" step="0.01" value="0.15" /></label>
    <label class="field"><span>BPR β</span><input id="genTdvrpBetaInput" type="number" step="0.5" value="4" /></label>
    <label class="field"><span>Residential decay (m)</span><input id="genTdvrpResDecayInput" type="number" step="100" value="2000" /></label>
    <label class="field"><span>Residential cluster seeds</span><input id="genTdvrpResSeedsInput" type="number" step="1" value="4" /></label>
    <label class="field"><span>Morning peak μ (h)</span><input id="genTdvrpMorningMuInput" type="number" step="0.25" value="8.0" /></label>
    <label class="field"><span>Morning peak σ (h)</span><input id="genTdvrpMorningSigmaInput" type="number" step="0.05" value="0.75" /></label>
    <label class="field"><span>Evening peak μ (h)</span><input id="genTdvrpEveningMuInput" type="number" step="0.25" value="17.0" /></label>
    <label class="field"><span>Evening peak σ (h)</span><input id="genTdvrpEveningSigmaInput" type="number" step="0.05" value="1.0" /></label>
    <label class="field"><span>Lunch share</span><input id="genTdvrpLunchShareInput" type="number" step="0.05" min="0" max="1" value="0.25" /></label>
    <label class="field"><span>Default service time (s)</span><input id="genTdvrpServiceTimeInput" type="number" step="60" min="0" value="600" /></label>
    <label class="field"><span>Work categories (comma-separated)</span><input id="genTdvrpWorkCategoriesInput" type="text" placeholder="restaurant,office,school,…" /></label>
  </details>
</fieldset>
```

3. Heatmap controls (slider + Play/Pause + Reset) are created dynamically by JS as a floating panel (matches the existing `tdvrpControls` div from v1). No new HTML required.

### B. `src/mamut_routing_publish/site_assets/workbench.css`

- `.gen-field-tdvrp { display: none; }` + `.gen-field-tdvrp.active { display: block; }` — mirrors the VRPTW visibility convention.
- `#tdvrpControls .ctrl-row` — flex row for slider + transport icons.
- Small `@keyframes` pulse on the play icon while the animation is running.

### C. `src/mamut_routing_publish/site_assets/workbench.js`

**Refactor the existing `?tdvrp_demo` overlay into reusable helpers:**

- `mountTdvrpView({ profiles, coordinates, depot, numTimeBins, allowedHours, stats })` — central entry that clears the map, draws customer/depot markers, draws the edge heatmap, mounts the floating controls. Replaces both the `?tdvrp_demo` init path and the post-generation rendering path.
- `tdvrpAnimationController(slider, hourLabel, allowedHours)` — Play/Pause/Reset wired to a `requestAnimationFrame` loop advancing the hour at ~500 ms cadence, wrapping `23 → 0`. Pauses on manual slider drag.
- `clearTdvrpView()` — tears down the layer, controls, and `state.tdvrp` when problemType changes back to CVRP/VRPTW or when **Clear** is pressed.

**Form plumbing:**

- Element refs for every new `genTdvrp*` input.
- Extend `updateGenerationFieldVisibility()` (≈ `workbench.js:1498`) to toggle the `.gen-field-tdvrp` visibility class based on the selected problem type — exactly the way `gen-field-vrptw` is handled today.
- Add `currentTdvrpPayloadFields()` reading every TDVRP input and returning a flat object: `{ commuterCount, trafficIntensity, previewHours, bprAlpha, bprBeta, residentialDecayMeters, residentialClusterSeeds, morning_mu, morning_sigma, evening_mu, evening_sigma, lunch_share, defaultServiceTime, workCategories }`.
- Extend `currentGenerationPreviewPayload()` (≈ `workbench.js:1587`) to merge `currentTdvrpPayloadFields()` when `problemType === "TDVRP"`, parallel to the existing VRPTW block.

**Button-handler dispatch** (≈ `workbench.js:2319`, `2358`, `2409`):

- Each of the three handlers (`genDisplayBtn`, `genGenerateBtn`, `genFilesBtn`) gains a TDVRP branch. When the response has `problem_type === "TDVRP"`, the handler ignores the GeoJSON preview path and instead calls `mountTdvrpView(response.tdvrp_overlay)`. The existing `state.generation.generated` cache is still populated.

### D. `webapp/site_api.jl` — server-side dispatch

The three existing routes already dispatch on `problemType`. Add a TDVRP branch to each.

1. **`/preview`** with `problemType=TDVRP` → new `workbench_tdvrp_preview_payload(payload; repo_root)`:
   - Calls a refactored `_tdvrp_run_simulation_phase(payload, sel)` that runs `build_generation_selection` + commuter sampling + `simulate_hourly_flows` + `bpr_speeds`. **Skips** `time_dependent_arc_costs` and `enforce_fifo!`.
   - Returns the `tdvrp_overlay` payload (see contract below) restricted to the user-supplied `previewHours`.
   - Profiles include only edges where `max(speed) < free_flow` OR edges traversed by at least one customer-pair shortest path (to keep the response small) — concrete filter to tune during implementation.

2. **`/generate`** with `problemType=TDVRP` → new `workbench_tdvrp_full_payload(payload; repo_root)`:
   - Runs the full pipeline in memory: flows + BPR + 24×N×N tensor + FIFO. **No disk write.**
   - Returns the same overlay payload with `allowed_hours = 0:23` and `tdvrp_stats: { fifo_correction_ratio, total_demand, capacity, route_count }`. Does **not** include the tensor itself in the response (kept small; tensor is regenerated by `single` for write).

3. **`/single`** with `problemType=TDVRP` → call existing `generate_single_tdvrp_instance(payload)` and append `tdvrp_overlay` (same shape as `/generate`) plus the existing `{ folder, base_name, files, manifest, summary }`.

4. **Refactor** the common preprocessing — `build_generation_selection`, commuter sampling, `simulate_hourly_flows`, `bpr_speeds` — out of `generate_single_tdvrp_instance` into a `_tdvrp_run_simulation_phase(payload, sel)` helper that all three handlers call. The IGP tensor + write are layered on top per handler.

### E. JS ↔ Julia payload contract

```jsonc
// Response from /preview or /generate or /single when problemType=TDVRP
{
  "ok": true,
  "problem_type": "TDVRP",
  "tdvrp_overlay": {
    "num_time_bins": 24,
    "bin_seconds": 3600,
    "allowed_hours": [3, 8, 12, 17, 22],   // full 0..23 for generate/single
    "coordinates": [[lon, lat], ...],       // includes depot at index 0
    "depot": 0,
    "profiles": [
      { "edge_id": "1023_1024",
        "coordinates": [[lon, lat], [lon, lat], ...],
        "free_flow_speed": 13.89,
        "speeds": [v_0, v_1, ..., v_23] }   // only filled at allowed_hours, free-flow elsewhere
    ],
    "stats": { "fifo_correction_ratio": 0.012, "edge_count_with_flow": 8494,
               "commuter_count_effective": 1500 }
  },
  // present only for /single:
  "folder": "...", "base_name": "...", "files": { ... }, "manifest": "..."
}
```

## Implementation order

1. **Julia simulation refactor** — extract `_tdvrp_run_simulation_phase` from `generate_single_tdvrp_instance`. Add `workbench_tdvrp_preview_payload` (cheap) and `workbench_tdvrp_full_payload` (no-write). Plumb the three existing handlers' `problemType` dispatch.
2. **HTML form** — extend `_render_workbench_shell_html` with the TDVRP option and fieldset; rebuild via `uv run mamut-routing-publish site webapp`.
3. **CSS** — append the `.gen-field-tdvrp` visibility rule and the `#tdvrpControls` flex/animation rules.
4. **JS refactor** — pull the existing `?tdvrp_demo` overlay logic into `mountTdvrpView` / `clearTdvrpView` / `tdvrpAnimationController` helpers.
5. **JS form integration** — element refs, `currentTdvrpPayloadFields`, `updateGenerationFieldVisibility`, `currentGenerationPreviewPayload`.
6. **JS button dispatch** — TDVRP branches in the three handlers.
7. **JS animation** — wire Play/Pause/Reset to the slider via `requestAnimationFrame`; pause on manual scrub.
8. **End-to-end smoke** — see Verification below.

## Critical files (v1.5)

- `src/mamut_routing_publish/site_webapp.py` — `_render_workbench_shell_html()` (lines 156–609). Append the TDVRP option + fieldset; rebuild step required after edits.
- `src/mamut_routing_publish/site_assets/workbench.css` — append `.gen-field-tdvrp` visibility + `#tdvrpControls` styling.
- `src/mamut_routing_publish/site_assets/workbench.js` — refactor the v1 `?tdvrp_demo` overlay (block near `initTdvrpOverlay` at the tail of the file) into reusable helpers; extend `updateGenerationFieldVisibility` (≈l. 1498), `currentGenerationPreviewPayload` (≈l. 1587), and the three handlers (`genDisplayBtn` ≈l. 2319, `genGenerateBtn` ≈l. 2358, `genFilesBtn` ≈l. 2409).
- `webapp/site_api.jl` — extend `workbench_generation_preview_payload`, the `/generate` handler, and `workbench_generation_single_payload` (≈l. 2579) with TDVRP branches.
- `webapp/osm_generation.jl` — extract `_tdvrp_run_simulation_phase` from `generate_single_tdvrp_instance` (added in v1).
- Reuse: `generate_single_tdvrp_instance`, `simulate_hourly_flows`, `bpr_speeds`, `edge_speeds_to_dict`, `edge_geometry_to_dict` from `webapp/traffic_simulation.jl`; existing `mountTdvrpControls` and `tdvrpSpeedRatioColor` from `workbench.js`.

## Verification (v1.5)

1. **Form visibility**: open `/workbench/`, switch `Problem type` between CVRP / VRPTW / TDVRP. Assert that the correct fieldset shows and the others are hidden. Toggle Advanced; values default per the HTML above.
2. **Preview button** (cheap): set TDVRP, click Display on Map on Brest with commuters=400. Server returns < 2 MB JSON in ≤ 5 s. Map renders ~5–10k colored edges at preview hours `3, 8, 12, 17, 22`. Slider scrubbing changes colors visibly. No tensor data in response (assert `tdvrp_overlay.allowed_hours.length === 5`).
3. **Generate Data button** (full preview): click Generate Data. Server returns within ~30 s. Slider now spans 0–23 (assert `allowed_hours.length === 24`). Animation plays through morning peak → midday → evening peak. Stats show `fifo_correction_ratio` and `edge_count_with_flow`.
4. **Write Files button**: click Write Files. Returns `folder`, `base_name`, `files`. The Julia `.tdvrp.json` still round-trips through the Python Pydantic model (existing v1 test still passes). FIFO and tensor-shape assertions from the v1 e2e test still hold.
5. **Mode switch hygiene**: switch problemType back to CVRP after a TDVRP preview is mounted. Assert `clearTdvrpView()` removes the heatmap, the controls, and resets `state.tdvrp`; the next CVRP preview renders cleanly.
6. **Animation**: press Play with `allowed_hours = 0:23`. Slider advances every ~500 ms and wraps. Manual slider drag pauses animation. Reset returns to the first allowed hour. No `requestAnimationFrame` leaks after `clearTdvrpView`.
7. **Regression**: existing CVRP and VRPTW Display / Generate / Write Files flows continue to work end-to-end; no new console errors on the default city.
8. **Layout**: TDVRP controls panel doesn't overlap with the existing Route Legend or stats panel; verify on a 1280-px-wide window.

## Out of scope for v1.5

- Catalog browsing of pre-generated TDVRP instances in the Visualize tab (full publisher catalog discovery of `benchmarks/TDVRP/**` is still a v2 lift).
- TDVRP solver integration; the Solve button stays CVRP/VRPTW-only.
- Custom colormap controls (we ship the existing RdYlGn_r ramp; no UI to change it).
- Export of the heatmap to PNG or static GeoJSON (the user can already inspect the underlying `.tdvrp.json` and `_meta.json`).
- Bulk TDVRP generation (the bulk endpoints stay CVRP/VRPTW-only in this iteration).
