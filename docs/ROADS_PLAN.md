# Road Network Redesign Plan (`RD0`–`RD5`)

## 1. Audit of Current Road Code & Root Causes

Reading `world/road_graph.gd`, `world/road_mesher.gd`, `tools/gen_network.gd`, `data/world_def.json`, `world/terrain_fn.gd`, `world/tile_gen.gd`, `world/tile_node.gd`, `main.gd`, and `ui/map_data.gd` revealed the exact causes of the issues reported:

1. **Artificial "cat-face" symmetry (`data/world_def.json`)**: `hwy_ring_1` + `hwy_ring_2` form a rounded oval head, `mtn_nw_loop` + `mtn_ne_loop` form two symmetric ears, `cntry_ew_center` forms a horizontal crossbar, and `hwy_west_cut` splits down the middle.
2. **Spawn glitch & broken intersection geometry (`main.gd`, `world/road_mesher.gd`, `tools/gen_network.gd`)**:
   - `main.gd` spawns on `RoadGraph.e_pts[0]` index `10` (`40 m` from node 0 at `(1000, 3000)`), which is a 4-way flat crossing where `hwy_west_cut` and `cntry_ns_center` converge at an ~18° acute angle, causing overlapping road strips and z-fighting (`r2_ground_materials.png`, `r6_minimap_hud.png`).
   - `RoadGraph.lane_offset(HIGHWAY)` returns `WIDTH * 0.25 = 5.5 m`, placing the car close to the dashed lane line at `4.60 m` instead of centered in the outer right lane (`6.45 m`) or inner lane (`2.80 m`).
   - `RoadMesher._pad()` cuts all incident edges back by a fixed `1.6 * hw + 3.0` (`20.6 m` on highways), breaking highway median barriers and lane markings into flat unlined grey triangle fans whose edges omit shoulders/verges (`hw` vs `hw + sw`).
   - `tools/gen_network.gd` runs raw `[1, 2, 1]/4` height averaging + hard point-wise grade clamps, producing vertical crest/sag kinks; cross-sections are completely flat (no banking on fast curves).
3. **Lack of long stretches & bridges**: Motorway segments are broken by flat crossings every 2–3 km, with no grade-separated interchanges, no river/ravine terrain features, and no bridges.
4. **Baseline `stream` gate budget overrun (`logs/stream.log`)**:
   - Running `tools\run_gates.bat` on the baseline failed `stream` because `_road_collider_chunk` spiked to `51.38 ms` (3000-vertex `ConcavePolygonShape3D` chunks containing all 5 strips including verge drop skirts) and `_scatter_batch` took `8.41 ms` (2 chunks/step).

---

## 2. Redesigned World Geography & Road Layout (20 × 20 km)

### Asymmetric Climates & Natural Terrain Features
- **Southern Coast & Bays (`coast`, Z ≈ 7400–8600+)**: Irregular undulating coastline (bays, headlands, sandy beaches, rocky coastal cliffs) with sea at `y = 0.0 m`.
- **Downtown City (`city`, tile `(5, 5)` centered at `(5632, 5120)`, flat at `CITY_Y = 20.0 m`)**: Existing hero city overlay (`city_downtown.tscn` + `city.json`) preserved and reconnected via clean arterial avenues and a motorway bypass interchange.
- **Sunbaked Desert / Arid Plain (`desert`, SW quadrant `X ∈ [-8500, -3000], Z ∈ [1500, 7400]`)**: Warm ochre/terracotta sand-gravel plain with sparse rocks/scrub and a 4+ km high-speed motorway straightaway.
- **Clearwater River Valley & Farmland (`countryside`, central-east diagonal)**: Analytical continuous river channel carved from the NE mountains `(4000, -5200)` through `(2200, -800)` -> `(1600, 3400)` -> coastal estuary `(1400, 8100)` with a sloped/stepped water surface and rolling green farmland.
- **Redwood/Pine Forest & Mirror Lake (`forest`, west-central `X ∈ [-8200, -2800], Z ∈ [-4500, 1500]`)**: Dense forest surrounding a carved highland **Lake** around `(-4600, -1400)` (`y_water ≈ 36 m`), crossed at a narrow inlet by a lakeside bridge.
- **Central Foothills & Ravine Gorge (`hills`, `X ∈ [-800, 3800], Z ∈ [-4200, -800]`)**: Wooded hills bisected by a deep E-W **Valley Ravine** (`Z ≈ -2400`) spanned by a tall multi-pier viaduct bridge.
- **Hill Pass & Snowy Alpine Peaks (`mountain`, NW & North `Z ∈ [-8800, -4500]`)**: Existing hero Hill Pass (`pass.json` + `hill_pass.tscn` in tile `(-2, -6)`) preserved and extended above the `320 m` snowline along an asymmetric alpine ridge loop, plus an eastern ridge spur with a **Ridge Tunnel** near `(3400, -6400)`.

### Asymmetric Road Hierarchy (~185–210 km total, no dead ends)
1. **Motorway Backbone (`HIGHWAY`, 22 m divided 2+2, min R ≥ 500 m, max grade 4.5%)**:
   - **M1 Grand Coastal-Valley Expressway**: City West Bypass -> long sweeping 5 km NW valley straight (contains default spawn at >400 m from any junction) -> **Highway River Bridge** -> SW Desert 4 km high-speed straight -> S-SE Coastal Terrace -> **Estuary Bridge** -> City West.
   - **M2 Northern Foothill Spur**: Diverges from M1 at a grade-separated Y-interchange, crosses the **Valley Ravine Viaduct**, sweeps asymmetrically below the northern foothills and forest edge, and merges back into M1 on the west side. Zero flat crossings on any `HIGHWAY` edge.
2. **Interchanges & Slip Ramps (`RAMP`, 7.5 m 1-lane slip, min R ≥ 80 m)**:
   - 5 grade-separated interchanges (`IC-1` City West, `IC-2` Central Valley, `IC-3` Desert/M2 West, `IC-4` Coast Estuary, `IC-5` Foothill M1/M2 Split) with `≥ 6.8 m` vertical overpass clearance and tangential acceleration/deceleration merges.
3. **Regional Two-Lane A-Roads (`COUNTRY`, 8.0 m 1+1, min R ≥ 120 m)**:
   - `A1` Coastal Scenic Route, `A2` Central Valley & Hill Pass Approach, `A3` East Valley to NE Crags, `A4` Forest & Mirror Lake Blvd; 3 **Roundabouts** at key regional hubs.
4. **Mountain Pass & Alpine Roads (`MOUNTAIN`, 6.5 m 1+1, min R ≥ 22 m)**:
   - Hero Hill Pass + Snowy Alpine Ridge Loop (`> 320 m`) + Eastern Saddle & **Ridge Tunnel**.
5. **Rural Backroads (`RURAL`, 5.5 m 1+1 narrow paved, min R ≥ 40 m)**:
   - `R1` Riverbank Farmland Lane (+ rural river bridge), `R2` Mirror Lake Shore Loop (+ inlet bridge), `R3` Desert Canyon Backroad, `R4` Coastal Headland Spur.
6. **Downtown City (`CITY`, 10.0 m + sidewalks/kerbs)**:
   - Existing `city.json` grid connected cleanly to West, North, and South A-roads/interchange.

---

## 3. Data Model & Architecture Changes

- **`RoadGraph` (`world/road_graph.gd`)**:
  - `enum { HIGHWAY, COUNTRY, MOUNTAIN, CITY, RAMP, RURAL }`
  - `WIDTH = [22.0, 8.0, 6.5, 10.0, 7.5, 5.5]`
  - `MAX_GRADE = [0.045, 0.075, 0.11, 0.06, 0.065, 0.09]`
  - `lane_offset(HIGHWAY) = 6.45` (centers car cleanly inside the outer right lane `4.60..8.30 m`).
  - Edge metadata: `e_kind` (`"road" | "bridge" | "overpass" | "tunnel"`), `e_elev` (`1` for bridges/overpasses), `e_bank` (smooth curvature-driven superelevation in radians, computed deterministically at load, clamped to `≤ 4°` and faded near bridges/junctions).
  - Node metadata: `node_kind` (`"normal" | "merge" | "roundabout" | "signal"`), `node_radius` (`0.0` or roundabout radius).
  - Explicit `"spawn"` record in `network.json` (`edge`, `i`, `pos`, `fwd`), checked in `RoadGraph.self_check()` (`>= 200 m` clear of any junction node).
- **Smooth Curves, Banking & Junction Meshes (`world/road_mesher.gd`)**:
  - `RoadMesher.stamp()` conforms terrain to banked road surfaces (`y + s * tan(bank) - OFF`), uses `stride = 1` on tight curves, and blends smoothly into bridge abutment approaches.
  - Replace uniform `_pad()` with node-kind builders:
    - `merge`: through-highway runs unbroken (median + lane lines continuous); ramp tapers smoothly with a painted chevron gore apron.
    - `roundabout`: circular paved ring + curbed grass central island + flared entry aprons.
    - `normal` / `signal`: filleted shoulder/kerb corners matching adjacent road widths continuously + zebra crosswalks in city/towns + stop/give-way markings.
- **Bridges, Overpasses & Ridge Tunnel**:
  - `bridge` / `overpass` edges generate concrete box-girder underside, crash parapets + steel guardrails + collision walls, and concrete piers reaching `TerrainFn.base_height(x, z) - 2.0`.
  - `tunnel` stamps terrain cleanly down beneath the road (so `HeightMapShape3D` never blocks the car) and places a vaulted concrete tunnel tube + rock ridge shell + portals + interior warm lamps overhead.
- **Streaming Performance**:
  - Exclude non-drivable verge skirts from `road_faces`, split `_road_collider_chunk` to `900` verts, and run `_scatter_batch` 1 chunk per step so `TileStreamer` stays well under the `25 ms` frame budget.

---

## 4. Implementation Steps (`RD1`–`RD5`)

Each step ends with `tools\run_gates.bat` passing (zero ERROR/WARNING), screenshots in `docs/shots/`, and a local commit `RD<n>: <summary>`:

- **RD1: Terrain biomes, river/ravine/lake carving, water surfaces & stream budget fix**
  - Add `DESERT` and `FOREST` biomes, irregular coastline, Clearwater River channel, Valley Ravine, and Mirror Lake basin to `data/world_def.json` and `world/terrain_fn.gd`.
  - Update `world/tile_gen.gd`, `shaders/terrain.gdshader`, and `world/scatter.gd` for desert/forest coloring, alpine snow, and water rejection.
  - Add per-tile water surface mesh + `shaders/water.gdshader` for sea (`y=0`), river, and lake.
  - Reduce `_road_collider_chunk` / `_scatter_batch` step sizes in `world/tile_node.gd` so `stream` gate passes `< 25 ms`.
- **RD2: Road graph schema & asymmetric network generator (`RoadGraph`, `gen_network.gd`)**
  - Extend `RoadGraph` (`RAMP`, `RURAL`, node/edge kinds, `e_bank`, `lane_offset`, `spawn` validation).
  - Upgrade `tools/gen_network.gd` and `data/world_def.json` to generate the asymmetric ~190 km network with grade-separated interchanges, smooth clothoid-like curves, parabolic vertical smoothing, bridge/tunnel tagging, and clean straight spawn (`> 250 m` from junctions).
  - Update `main.gd` spawn and `cars/autodrive.gd` junction/roundabout navigation.
- **RD3: Road geometry, banking, gore merges, roundabouts & clean intersections (`RoadMesher`, `road.gdshader`)**
  - Implement banked cross-sections + banked `RoadMesher.stamp()`.
  - Replace `_pad()` with continuous motorway gore merges, roundabouts, and filleted/crosswalked intersections.
  - Style `RAMP` and `RURAL` in `shaders/road.gdshader`, soften overly bright shoulders, and omit verge skirts from `road_faces`.
- **RD4: Bridges, overpasses, guardrails, interchange signage & ridge tunnel (`RoadMesher`, `props.gdshader`)**
  - Build bridge/overpass decks, parapets, piers to ground, interchange directional gantry signs, and the deep-cut vaulted ridge tunnel.
- **RD5: Topographic world map, minimap, streaming test route & verification (`MapData`, `Minimap`, `FullMap`, `streaming_test.gd`)**
  - Style the 6 road classes & bridges in `MapData` / `Minimap` / `FullMap`, bake river/lake/desert/forest/coast into the topographic map background, and update `REGIONS` / `towns`.
  - Update `tests/streaming_test.gd` route across the new network, verify all gates pass, and update `docs/BUILD_REPORT.md`.
