# Horizon Triland — Country & Region Layout Data Schema (`M6-data v2`)

> **Attribution**: Road data (c) OpenStreetMap contributors, ODbL (`https://www.openstreetmap.org/copyright`). Real elevation sampled from SRTM 30m / ASTER GDEM 30m via OpenTopoData (`https://www.opentopodata.org/`).

This document defines the v2 real-OSM data schema specified in Section 7 of [MAP_PLAN.md](file:///C:/Users/acer/Documents/GitHub/p1-drive-regions/docs/MAP_PLAN.md) for the **32.768 × 32.768 km** (`32 × 32` tiles of `1024 m`) **Horizon Triland** world (`data/world/country.json` and `data/world/regions/<region_id>.json`).

---

## 1. World Coordinate, Projection & Scaling Conventions

| Property | Convention |
|---|---|
| **Units** | Metres (`m`) for all coordinates, lengths, widths, radii, and elevations; `km/h` for speed limits; degrees (`deg`) for yaw angles; dimensionless ratio (`dy / ds`) for grades. |
| **Axes** | Right-handed Godot 4 world space: **`+X` = East**, **`-X` = West**, **`+Y` = Up (Elevation above sea level `0.0 m`)**, **`-Z` = North**, **`+Z` = South**. |
| **World Bounds** | `X ∈ [-16384.0, +16384.0] m`, `Z ∈ [-16384.0, +16384.0] m` (`32 × 32` tiles of `1024.0 m`, tile indices `tx, tz ∈ [-16, +15]`). |
| **Region Disjointness** | Regional `bounds_m` boxes are axis-aligned `[x_min, z_min] .. [x_max, z_max]` rectangles that partition the 3 regional footprints without 2D overlap. |
| **Local Projection** | Each real-world OSM sub-area (`area_id`) is projected from `(lat, lon)` to local metres `(dx_m, dz_m)` around its local origin `(lat0, lon0)` using equirectangular tangent-plane scaling: `dx_m = (lon - lon0) * 111320.0 * cos(lat0)`, `dz_m = -(lat - lat0) * 110574.0`. |
| **Uniform Area Scale (`scale_factor`)** | Each real-world sub-area is uniformly scaled by `scale_factor ∈ [0.6, 1.0]` (recorded in both `country.json` and `<region_id>.json`) to fit inside the 32 × 32 km country without distorting real horizontal curve shapes. |

---

## 2. Source Bounding Boxes (`source_bboxes`)

Each region records its real-world OpenStreetMap source areas in `source_bboxes`:

| Region | Area ID | Real Location | Bounding Box `[south, west, north, east]` | Uniform `scale_factor` |
|---|---|---|---|---|
| `tokyo_hakone` | `tokyo_ginza_c1` | Ginza, Shiodome, Tokyo Tower, Shibaura Loop, Rainbow Bridge & Shuto C1 | `[35.630, 139.735, 35.676, 139.776]` | `0.78` |
| `tokyo_hakone` | `tokyo_shibuya` | Shibuya Scramble, Roppongi, Route 246 & Shuto Route 3 | `[35.654, 139.698, 35.670, 139.735]` | `0.78` |
| `tokyo_hakone` | `hakone` | Hakone Turnpike, Ashinoko Skyline, Lake Ashi & Route 732 Nanamagari | `[35.172, 138.980, 35.242, 139.110]` | `0.68` |
| `tokyo_hakone` | `shonan_coast` | Shonan Coast Road (Route 134, Enoshima to Kamakura) | `[35.298, 139.475, 35.320, 139.555]` | `0.75` |
| `monaco_alps` | `monaco` | Principality of Monaco (Port Hercule, GP Circuit, Tunnel Louis II, Casino, Corniches) | `[43.723, 7.408, 43.755, 7.443]` | `0.88` |
| `monaco_alps` | `col_de_turini` | Col de Turini (`D2566`), Peïra-Cava & Moulinet switchbacks | `[43.875, 7.365, 43.988, 7.452]` | `0.65` |
| `monaco_alps` | `turini_coast_link` | `D2566` / `D2204` Gorge & Foothill link road to Côte d'Azur coast | `[43.755, 7.410, 43.875, 7.458]` | `0.65` |
| `dubai_jais` | `dubai_downtown` | Downtown Dubai, Business Bay, Burj Khalifa & Sheikh Zayed Road (`E11`) | `[25.180, 55.252, 25.215, 55.290]` | `0.82` |
| `dubai_jais` | `dubai_marina` | Dubai Marina, JBR & Sheikh Zayed Road (`E11`) Marina Interchanges | `[25.068, 55.130, 25.096, 55.162]` | `0.82` |
| `dubai_jais` | `dubai_desert` | Al Qudra Road (`D63`), `E77` Desert Highway & Al Qudra Oasis Lakes | `[24.835, 55.300, 24.925, 55.410]` | `0.72` |
| `dubai_jais` | `jebel_jais` | Jebel Jais Mountain Road (Ras Al Khaimah, Wadi Shehah to Summit) | `[25.885, 56.065, 25.958, 56.162]` | `0.75` |

---

## 3. Road Class Geometric & Curvature Rules

Every road spline in `country.json` (`motorways`) and `regions/<region_id>.json` (`roads`) carries `road_class` (`"motorway"`, `"arterial"`, `"street"`, `"mountain"`), `type` (`"highway"`, `"arterial"`, `"city"`, `"country"`, `"mountain"`, `"jebel_jais"`, `"ramp"`), `osm_way_ids`, and `osm_highway`.

- **Horizontal Geometry**: Extracted directly from OpenStreetMap ways, simplified with Douglas-Peucker (`1.0–2.0 m` tolerance), merged across degree-2 continuation nodes, and connected at shared OSM junction nodes **without altering real horizontal curves**.
- **Vertical Profile & Curvature Smoothing**:
  - Real elevation is sampled from SRTM30m / ASTER30m along each road and smoothed along arc length $s$ so that discrete vertical curvature $\kappa_{v,i} = |g_i - g_{i-1}| / \Delta s_{\text{avg}}$ satisfies:
    - $R_{v,i} = \kappa_{v,i}^{-1} \ge 600.0\text{ m}$ on `"motorway"` (`"highway"`),
    - $R_{v,i} \ge 250.0\text{ m}$ on `"arterial"` and `"street"`,
    - $R_{v,i} \ge 120.0\text{ m}$ on `"mountain"` roads.
  - Where real steep terrain (e.g. Monaco hillside streets, Hakone Nanamagari, Col de Turini ramps) exceeds nominal grade targets, `real_grade_exception: true` and `max_observed_grade` are recorded on the road and listed by `tools/validate_world.py`.

---

## 4. Country Manifest (`data/world/country.json`)

```json
{
  "schema_version": 2,
  "attribution": "Road data (c) OpenStreetMap contributors, ODbL",
  "country_id": "horizon_triland",
  "display_name": "Horizon Triland (Kanto • Azur • Mirage)",
  "world_seed": 202611,
  "tile_size_m": 1024.0,
  "size_km": [32.0, 32.0],
  "bounds_m": { "min": [-16384.0, -16384.0], "max": [16384.0, 16384.0] },
  "bounds_tiles": { "min": [-16, -16], "max": [15, 15] },
  "default_spawn": { "region": "tokyo_hakone", "spawn_id": "shuto_c1_bayshore" },
  "regions": [ ... ],
  "motorways": [ ... ],
  "interchanges": [ ... ]
}
```

---

## 5. Regional Layout Data (`data/world/regions/<region_id>.json`)

Each region file contains:
- `schema_version` (`2`), `attribution` (`"Road data (c) OpenStreetMap contributors, ODbL"`), `scale_factor` (`float` in `[0.6, 1.0]`), and `source_bboxes` (`Array[Object]`).
- `roads`: Connected 3D OSM road splines (`id`, `name`, `osm_way_ids`, `osm_highway`, `road_class`, `type`, `kind`, `elevated`, `tunnel`, `lanes`, `lane_config`, `width_m`, `speed_limit_kmh`, `min_radius_m`, `max_grade`, `min_vertical_curve_radius_m`, `start_junction`, `end_junction`, `control_points`).
- `junctions`: Network topology nodes derived from shared OSM nodes (`id`, `name`, `osm_node_id`, `type`, `kind`, `position`, `radius_m`, `grade_plane`, `connected_road_ids`, `interchange_id`).
- `city_blocks`: Urban blocks containing compact real OSM building footprints for `M3`/`M8` merged block mesh generation:
  - `id`, `district`, `polygon` (`[[x, z], ...]`), `base_elevation_m`, `height_range_m`, `style_tags`, `has_occluder`,
  - `footprints`: Array of `{ "osm_id": int, "poly": [[x, z], ...], "height_m": float, "levels": int }` extracted from real Overpass `building=*` ways with `height` or `building:levels`.
- `terrain`:
  - `base_noise`, `biomes`, `terraces`, `water_bodies`, `key_features`,
  - `elevation_grid`: Coarse real SRTM30m elevation grid (`rows`, `cols`, `bounds_m`, `values_m`) for terrain conforming and atlas hillshading,
  - `coastlines`: Real OSM `natural=coastline` polylines (`[[x, z], ...]`),
  - `water_polygons`: Real OSM `natural=water` / lake / harbour / canal polygons and polylines,
  - `landuse_zones`: Real OSM `landuse=forest|park|grass|sand` and `leisure=park|garden` polygons (`kind`, `name`, `polygon`) for terrain material zones.
- `petrol_stations`: Real OSM `amenity=fuel` stations inside each region (`id`, `osm_id`, `name`, `brand`, `road_id`, `s_m`, `side`, `offset_m`, `position`, `yaw_deg`, `services`).
- `landmarks`: Real OSM landmarks (`tourism=attraction|viewpoint`, `man_made=tower|bridge`, `historic=*`) inside each region.
- `spawns`, `events`, `traffic`, `weather_weights`.

## v3 budget totals (for later agents to check against)

Source: `country.json` `budget_totals`. 2039 road splines, 1766 region junction nodes, 12918 region control vertices, 540.0 road-km (58.7 km motorway M1/M2/M3 + 481.3 km regional), 10909 building footprints, 15 OSM fuel stations, 18 landmarks, 495 city blocks.

| region | splines (motorway/arterial/mountain/street) | km | buildings |
|---|---|---|---|
| tokyo_hakone | 927 (439/310/92/86) | 187.2 | 7088 |
| monaco_alps | 413 (0/209/80/124) | 105.1 | 1772 |
| dubai_jais | 696 (194/450/13/39) | 189.1 | 2049 |

Terrain: one 128x128 country heightfield (`terrain.heightfield`), sampled bicubically (Catmull-Rom) by the build and the atlas renderer; regional grids are slices of it, so there are no region seams. Motorways are Dijkstra least-cost routes between interchanges (sea heavily penalised), M1 = M2N-M1W-M1N-M1C-M1E-M3N, M2 = M1W-M2E-M2S, M3 = M2E-M3S-M3N. Interchange heights are locked by the first motorway through them.
Known grade exceptions (real OSM hairpins, 13-14%): tk_osm_hakone_39, mc_osm_turini_coast_link_0, db_osm_jebel_jais_0/1.
