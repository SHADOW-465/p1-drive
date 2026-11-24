# P1 Drive — World Map & Multi-Region Architecture Plan (`M0`–`M16`)

## 1. Root-Cause Diagnosis (With Code & Log Evidence)

### 1.1 Why Entering the City Drops FPS to 6–19 FPS Today

Target hardware is a **GeForce 610M / Radeon 610M class laptop GPU** (48–96 shader cores, 64-bit memory bus, ~8–14 GB/s shared system RAM bandwidth, 512 MB–1 GB VRAM) at `1366×768` on **Low / Medium** presets (`mobile` renderer). To hold **40–55 FPS** (`18–25 ms/frame`) and **never drop below 25 FPS** (`40 ms/frame`), total frame draw calls must stay under **120 (Low) / 175 (Medium)**, triangles in view under **140k (Low) / 240k (Medium)**, and full-screen heavy fragment overdraw must be near zero.

Auditing `world/hero/city_downtown.gd`, `shaders/building.gdshader`, `data/hero/city.json`, `world/road_mesher.gd`, `world/tile_node.gd`, `world/scatter.gd`, `world/tile_streamer.gd`, `autoload/settings.gd`, `camera/camera_rig.gd`, `cars/glb/glb_body.gd`, and `logs/stream*.log` reveals **six compounding bottlenecks** that happen simultaneously when entering tile `(5, 5)`:

| # | Bottleneck | Code Evidence | Measured / Computed Cost |
|---|---|---|---|
| **1** | **Single un-culled city MultiMesh + 4–8× full-screen fragment overdraw of a 12-texture anisotropic shader** | `world/hero/city_downtown.gd:25-36, 128-189` packs all **~115 building boxes** (16 blocks × 4 lots × 1–3 stacked boxes for podium, shaft, and penthouse setback) into **one `MultiMeshInstance3D` (`Towers`)** with `visibility_range_end = 0.0` (infinite), **zero LODs**, **zero impostors**, and **zero `OccluderInstance3D` nodes**. Godot frustum-culls a `MultiMeshInstance3D` as a **single combined AABB (`560×130×560 m`)**, so 100% of the ~115 boxes render every frame. `shaders/building.gdshader:11-26, 57-174` binds **12 × 1K `filter_linear_mipmap_anisotropic` PBR textures**, unconditionally samples `tex_conc_diff` and `tex_conc_nor` on every fragment (`lines 148, 171`) on top of the facade diffuse/normal/ARM triple, and runs per-pixel `hash21` window/blind/storefront procedural math. | Looking down a city street draws **4–8 layers of full-screen building facades** back-to-back (plus internal hidden faces of 3 stacked boxes per tower) with MSAA 2× (`Medium`). On a 64-bit bus iGPU, ~6M shaded fragments × 5–6 anisotropic 1K texture fetches saturates memory bandwidth (**35–75 ms GPU**). |
| **2** | **Directional shadow cascade rendering of all towers, 72 high-poly city oaks, and all city props** | `autoload/settings.gd:286-305` enables real-time directional shadows on both `Low` (`1024` ortho, `85 m`) and `Medium` (`2048` 2-split PSSM, `175 m`, `blend_splits = true`). In `city_downtown.gd:35, 49`, both `Towers` (~115 boxes in 1 giant AABB) and `CityTrees` (~72 instances of `tree_oak_lod0.res` = `65 KB` / ~1,500 tris each = **~108,000 triangles** with `render_mode cull_disabled` in `shaders/foliage.gdshader:2`) have `cast_shadow = SHADOW_CASTING_SETTING_ON`. `world/tile_node.gd:181` also enables `cast_shadow = ON` on `Props` (~160 3D box streetlamps + ~80 signs across 40 city edges). | Every frame renders the entire un-culled `Towers` MultiMesh, all **~108k double-sided oak triangles**, and all **40 streets of props** into **2 directional shadow cascades** (`Medium`), adding **~250k+ shadow triangles** and heavy alpha-discard shadow rasterization. |
| **3** | **Scatter MultiMesh node & triangle explosion on the 8 surrounding FULL tiles** | `world/tile_streamer.gd:148` keeps a **3×3 ring of 9 FULL tiles** live. Only tile `(5, 5)` sets `"no_scatter": true` (`data/world_def.json:314`). The 8 adjacent FULL tiles (`(4,4)..(6,6)`) each build `4×4 = 16` chunks (`world/scatter.gd:6`). For each chunk, `world/tile_node.gd:217-240` creates up to **11 `MultiMeshInstance3D` nodes** (7 types × LOD0/LOD1; trees have **2 surfaces** = 2 draw calls per MMI). Baked meshes (`assets/models/nature/baked/*.res`) are huge: `tree_pine_lod0.res` is **364.5 KB (~8,500 tris/tree)**, `tree_conifer_lod0.res` is **128.5 KB (~3,000 tris/tree)**, `tree_oak_lod0.res` is **65.2 KB (~1,500 tris/tree)**. Worse, `VIS_LOD0_END = 210 m` and `VIS_LOD1_START = 165 m` (`scatter.gd:14-15`), so in the **165–210 m ring (45 m overlap)** both `LOD0` and `LOD1` draw simultaneously with `discard` dithering (`shaders/foliage.gdshader:62-64`). | Up to **176 MMIs (~272 surface draw calls) per neighboring FULL tile** = **~1,000+ active MMIs** in the 8 border tiles around the city, plus `cast_shadow = ON` on all LOD0 trees/rocks (`scatter.gd:439`). |
| **4** | **Unmerged GLB car hierarchies + ReflectionProbe / Cockpit Mirror re-renders** | `logs/p1_tree.txt`, `logs/glb600.txt`, `logs/gem_tree.txt` show `cars/glb/glb_body.gd` instantiates **195 separate `MeshInstance3D` nodes** for `mclaren_p1_vecarz`, **~850** for `mclaren_600lt`, and **756** for `koenigsegg_gemera` (mostly unmerged wheel `polySurface*` and trim sub-meshes), all with `cast_shadow = ON` except `no_shadow_mats`. Meanwhile, `cars/car_mirror.gd:51-80` runs **3 SubViewport cameras** (`far = 700 m`, `cull_mask = 1`) in cockpit view, and `camera/camera_rig.gd:64-82, 196-213` updates a 6-face `ReflectionProbe` (`cull_mask = 1`) that re-renders the city world meshes. | Car alone costs **195–850 draw calls** (+ shadow pass) instead of **≤12 merged draw calls**. Mirror SubViewports / ReflectionProbe multiply city world draw calls by **2×–4×**. |
| **5** | **40 City Edges × 9 Profile Strips + 25 Filleted Junctions cooked into 45+ `ConcavePolygonShape3D` chunks** | `data/hero/city.json` puts **25 nodes** and **40 `CITY` edges** (plus 4 connecting `COUNTRY` edges) inside tile `(5, 5)`. `world/road_mesher.gd:26-33` extrudes **9 quad strips** per `CITY` edge and runs `_pad_fillet()` (`lines 826-963`) at all **25 nodes**. Then `lines 333-344` emit a 2-layer `_drive_slab_faces()` **plus** copy all triangles of 7 of the 9 visual strips (`cols[i].b < 0.75`) and all 25 junction pads/kerbs/sidewalks into `d["road_faces"]` (~40,000 face vertices). `world/tile_node.gd:33-42` slices this into **~45 `CollisionShape3D` (`ConcavePolygonShape3D`)** nodes with `backface_collision = true`. Plus `city_downtown.gd:70-83` drips **12 `BoxShape3D` colliders/frame** in `_process()` directly onto an active in-tree `StaticBody3D` (`CityColliders`), forcing Jolt broadphase rebuilds across 5 frames. | **~45 `ConcavePolygonShape3D` + ~60 `BoxShape3D` + `HeightMapShape3D`** in one tile; main-thread Jolt BVH cooking + per-frame broadphase rebuild spikes when entering `(5, 5)`. |
| **6** | **Worker & Main-Thread Streaming Stalls (`1,039 ms` worker job, `36.3 ms` frame hitch)** | `logs/stream.log` and `logs/stream2.log` record `max job 1039 ms` (4× over the `250 ms` budget) and `streamer frame ms: max 36.34 ms` (`_terrain_mesh: 4.96 ms`, `_road_mesh: 4.49 ms`, `_props_mesh: 3.96 ms`, `_terrain_collider: 2.81 ms`). In `RoadMesher.stamp()` (`world/road_mesher.gd:233-281`), tile `(5, 5)` stamps ~800 road segments across a `49.5 m` reach into the `131×131` height grid even though the city is flat (`CITY_Y = 20.0 m`). | Crossing a tile border near the city stalls worker threads for **>1.0 s** and blows the `2.0 ms` main-thread apply budget by **2.5×–18×**. |

---

### 1.2 Why Cars Get Thrown Into the Air at Road Tile Joins & Junctions Today

Auditing `world/road_mesher.gd`, `world/road_graph.gd`, `tools/gen_network.gd`, `world/tile_node.gd`, `cars/car.gd`, and `logs/fall.log` reveals **five exact geometric/physics defects** that launch cars:

1. **Extrapolated `±0.4 m` Tile-Border Collision Slab Lips Cross in Y (`world/road_mesher.gd:381-419`)**:
   - `_emit_slab()` builds the road collision ribbon using `stride = 2` (`8 m` chords) for `FULL` and `stride = 3` (`12 m` chords) for `MID`.
   - At the first cross-section in a tile (`n == 0`, line 403), it extrapolates the vertices backward by `-0.4 m` along `pts[ids[0]] -> pts[ids[1]]`. At the last cross-section (`n == ids.size() - 1`, line 407), it extrapolates forward by `+0.4 m` along `pts[ids[n-1]] -> pts[ids[n]]`.
   - Whenever a road crosses a tile boundary on any vertical grade change, crest, sag, or banking transition, tile A's `+0.4 m` chord extension and tile B's `-0.4 m` chord extension have different slopes and **intersect in an X-shape**, creating a **protruding vertical step/lip (`1–6 cm`)** across the entire road width right on the tile seam!
2. **Double-Stacked Conflicting Road Colliders (`world/road_mesher.gd:333-344, 393-395`)**:
   - `RoadMesher.mesh()` puts **three overlapping triangle layers** into `d["road_faces"]`:
     1. `_drive_slab_faces()` top layer at `y - 0.08 m` (`FULL`, `stride = 2` / 8 m chords) or `y - 0.02 m` (`MID`, `stride = 3` / 12 m chords),
     2. `_drive_slab_faces()` bottom layer at `y - 0.78 m`,
     3. The visual road mesh triangles (`idx`, lines 335-342) at `y = 0.00 m` (`stride = 1` / 4 m chords), **including vertical 15 cm city kerbs (`KERB = 0.15 m`) and 16 cm roundabout kerbs** because `cols[i].b == 0.30 < 0.75`!
   - Where visual strips are cut back at junctions (`edge_range(e)`) or split across tiles, wheel raycasts and chassis shapes drop `8 cm` from the `0.00 m` visual triangles onto the `-0.08 m` `stride = 2` slab (or hit exposed vertical kerb edges) and violently rebound.
3. **Downsampled `65×65` (`16 m`) `HeightMapShape3D` Poking Through Curved & Mountain Roads (`world/tile_node.gd:268-297`, `world/road_mesher.gd:217-289`)**:
   - `RoadMesher.stamp()` stamps the `129×129` (`8 m`) visual height grid to `ry - 0.35 m` (`OFF = 0.35 m`), with `blend = 14.0 m` on mountain roads and `2.4 m` bench near tunnels (`lines 241-242`).
   - Then `TileNode._terrain_collider()` (`line 275`) downsamples `hm` by **`stride = 2` (`65×65`, `16 m` cells, `22.6 m` diagonals)**!
   - On any curved mountain road, hillside cut, or embankment where terrain rises `5–20 m` over `14 m` beside the road, the `16 m` `HeightMapShape3D` triangle diagonals chord across the curve and **poke `0.2–1.5 m` UP through the `0.35 m` road clearance**, creating invisible **saw-tooth terrain ridges** across the lane! (Evidenced in `logs/fall.log:13`: `t=8.0s 315 km/h ... wheels 0 clear 0.04`, where the car is launched completely airborne with `0` wheels in contact).
4. **C0 Vertical Grade Kinks at Nodes, Flat Roundabouts & Junction Fans (`tools/gen_network.gd:815-884`, `world/road_graph.gd:149-171`, `world/road_mesher.gd:567-904`)**:
   - `gen_network.gd:_solve_edge_vertical()` clamps point-to-point slopes (`lines 879-883`) independently per edge without enforcing vertical tangent (`dy/ds`) continuity at shared graph nodes, and `RoadGraph.spline()` uses reflected phantom endpoints (`p0 = 2*p1 - p2`, `line 157`).
   - `_roundabout_mesh()` (`lines 671-775`) builds the entire circular ring at a **flat constant `y = node.y`**, while approaching sloped edges stop at `i_cut` (`r_outer + 8 m` away) at `pts[i_cut].y`, bridging the height difference over an `8 m` linear apron that acts as a **ski jump** at speed.
   - `_pad_fillet()` (`lines 851-915`) connects a single center vertex at `node.y` to cut road mouths `15–45 m` away, creating a sharp pitch kink whenever an approaching road has non-zero grade or banking.
5. **Arbitrary 300-Triangle Slicing of `ConcavePolygonShape3D` (`world/tile_node.gd:34-36, 256-265`)**:
   - `d["road_faces"]` is sliced every `900` vertices (`300` triangles) into separate `ConcavePolygonShape3D` resources (`RoadShape_0`, `RoadShape_900`, ...). Splitting a continuous road strip across multiple `ConcavePolygonShape3D` shapes inside Jolt disables internal-edge welding along the split seam, allowing fast-moving wheel raycasts/contacts to snag on boundary triangle edges.

---

## 2. World & Region Layout ("Horizon Triland" — 32 × 32 km)

> **Attribution**: Road data (c) OpenStreetMap contributors, ODbL. Real elevation data from SRTM 30m / ASTER 30m via OpenTopoData.

### 2.1 Geographical Overview & Approximate Sizes

The world is a **32.768 × 32.768 km** (`32 × 32` tiles of `1024 m`, tile indices `tx, tz ∈ [-16, +15]`, world coordinates `X, Z ∈ [-16384, +16384] m`) fictional country inspired by *Forza Horizon*, divided into **three distinct, self-contained regions** connected by a high-speed grade-separated **Motorway Triangle (`M1`, `M2`, `M3`)**:

1. **Region 1 (`tokyo_hakone`) — Kanto Neon City, Hakone Touge & Shonan Coast (East / North-East)**:
   - **Total Footprint**: `~12 km (E–W) × 14 km (N–S)` (`~168 km²`), `X ∈ [+2048, +14336]`, `Z ∈ [-12288, +2048]`.
   - **Neo-Tokyo Neon District (`4.0 × 3.5 km`, `X ∈ [+7168, +11264], Z ∈ [-3072, +512]`, flat basin at `y = 18 m`)**:
     - Dense grid & arterial avenues (Shibuya/Shinjuku-inspired neon canyon blocks, elevated `C1` inner-loop urban expressway on concrete piers at `y = 30 m`, glowing vertical kanji/katakana-inspired procedural neon signboards, pedestrian scrambles, underpass tunnel, petrol station & parking garage landmark).
   - **Hakone Mountain Pass & Crater Lake (`6.5 × 6.0 km`, `X ∈ [+3072, +9600], Z ∈ [-11264, -5120]`, `y = 120..620 m`)**:
     - 18-hairpin rhythmically banked touge climb (`min R = 22 m`, `max grade = 9.5%`), cedar/pine forest, Lake Ashi-inspired highland caldera lake (`y = 410 m`) with a red Torii gate landmark and summit Daikanyama-style touge parking/viewpoint area.
   - **Shonan / Odawara Bay Coast (`8.0 × 2.5 km`, `X ∈ [+4096, +12288], Z ∈ [+512, +3072]`, `y = 0..16 m`)**:
     - Sweeping coastal seawall road, bay suspension bridge (`Rainbow Bridge` style connecting to the C1 expressway), beach promenade.
2. **Region 2 (`monaco_alps`) — Côte d'Azur Harbour Town & Maritime Alpine Hairpins (North-West / West)**:
   - **Total Footprint**: `~13 km (E–W) × 14 km (N–S)` (`~182 km²`), `X ∈ [-14336, -1024]`, `Z ∈ [-14336, -512]`.
   - **Port d'Azur / Monaco Harbour Town (`3.5 × 2.8 km`, `X ∈ [-11264, -7680], Z ∈ [-4096, -1280]`, terraced `y = 4..68 m`)**:
     - Terraced Belle Époque / Mediterranean pastel hillside blocks overlooking a sheltered yacht harbour (`y = 0 m`), waterfront swimming-pool chicane, Casino-style uphill hairpin & plaza landmark, seafront curved cliff tunnel (`Fairmont/Louis II` style), and coastal Corniche road (`Moyenne & Grande Corniche`).
   - **Col de Turini / Maritime Alps (`9.0 × 8.5 km`, `X ∈ [-13312, -4096], Z ∈ [-13312, -4800]`, `y = 140..780 m`)**:
     - Fast lower-gorge road climbing through stone arch viaducts into 14 tight Alpine switchbacks (`min R = 20 m`, `max grade = 10.0%`), limestone cliff balconies, snow-dusted summit pass (`> 520 m`), and an Alpine chalet village hub with a petrol station.
3. **Region 3 (`dubai_jais`) — Mirage Skyline, Red Dune Highways & Jebel Jais Mountain Road (South / South-West)**:
   - **Total Footprint**: `~22 km (E–W) × 11 km (N–S)` (`~242 km²`), `X ∈ [-13312, +9216]`, `Z ∈ [+3072, +14336]`.
   - **Mirage Marina & Sheikh Zayed Skyline Corridor (`4.5 × 3.0 km`, `X ∈ [-3072, +1536], Z ∈ [+8192, +11264]`, `y = 6..12 m`)**:
     - 6-lane divided superhighway flanked by supertall glass/steel towers (`80–240 m` merged per block), central Spire landmark (`320 m`), desert marina lagoon & palm-island causeway loop, futuristic service station.
   - **Rub' al Khali Red Dunes & Oasis Highway (`14.0 × 6.0 km`, `X ∈ [-12288, +2048], Z ∈ [+4096, +10240]`, `y = 15..95 m`)**:
     - Sweeping red-gold sand dunes, desert salt-flat straight (`6.2 km` laser-straight section on `M3` for `350–400 km/h` top-speed testing), camel-rock arches, oasis roundabout town.
   - **Jebel Jais Desert Mountain Road (`7.5 × 6.5 km`, `X ∈ [+2048, +9216], Z ∈ [+6144, +12800]`, `y = 60..680 m`)**:
     - Wide (`10.5 m`, 3-lane `2 uphill + 1 downhill`), ultra-smooth, high-speed desert canyon & ridge road carved into stratified terracotta cliffs (`min R = 38 m`, `max grade = 7.5%`), sweeping banked hairpins, concrete rock-shed gallery, and Jebel Jais summit sky-deck landmark.

### 2.2 Inter-Regional Motorways (`~82 km` total motorway backbone)

- **`M1` Trans-Northern Alpine-Hakone Motorway (`~26 km`)**: Connects **Region 2 (Port d'Azur / Alpine Foothills)** east across a high central suspension viaduct (`Valley Gorge Viaduct`) to **Region 1 (Hakone Foothills & Neo-Tokyo North IC)**.
- **`M2` Western Coastal-Desert Motorway (`~27 km`)**: Connects **Region 2 (Port d'Azur West IC)** south along the coastal cliffs, transitioning into the **Region 3** desert salt-flat `6.2 km` top-speed straight into **Mirage Marina West IC**.
- **`M3` Eastern Bay-to-Jais Superhighway (`~29 km`)**: Connects **Region 3 (Mirage Marina East IC & Jebel Jais Base IC)** north-east along the bay causeway into **Region 1 (Shonan Coast & Neo-Tokyo C1 Bayshore IC)**.

### 2.3 ASCII World Map (`32 × 32 km`, North = `-Z` up, East = `+X` right)

```text
      X=-16km                X=-8km                 X=0km                  X=+8km                 X=+16km
Z=-16km +----------------------+----------------------+----------------------+----------------------+
        |                      |                      |                      |                      |
        |     REGION 2: MONACO & MARITIME ALPS        |        REGION 1: KANTO NEON & HAKONE        |
        |   [Col de Turini Summit 780m]               |          [Hakone Crater Lake 410m]          |
        |       /\/\/\  (Alpine Hairpins)             |           (Torii) ~~~ /\/\/\ (Touge Pass)   |
        |      /      \                               |                      /      \               |
Z=-8km  +-----/--------\------------------------------+---------------------/--------\--------------+
        |    /  [Alpine \      M1 TRANS-NORTHERN MOTORWAY (Viaduct)        /          \             |
        |   |   Village] ========(IC-M1W)===================(IC-M1C)=====(IC-M1E)      \            |
        |   |          /                                                 /    \         \           |
        |  (IC-M2N)===[PORT D'AZUR / MONACO]                            /   [NEO-TOKYO NEON CITY]   |
        |   ||         (Harbour, Chicane,                              /    | 4x3.5km Grid + C1  |  |
        |   ||          Cliff Tunnel) ~~~SEA~~~                       /     | Elevated Loop      |  |
Z=0km   +---||----------------------------------------+--------------/------+--(IC-M3N)----------+--+
        |   ||  WEST COAST                            |             /       [Shonan Coast & Bay]    |
        |   ||  CORNICHE                              |            /         ~~~ Bay Bridge ~~~     |
        |   ||                                        |           /                 ||              |
        |   ||  M2 WESTERN                            |          /                  ||  M3 EASTERN  |
        |  (IC-M2S) DESERT                            |         /                   ||  BAY-JAIS    |
        |   ||  MOTORWAY                              |        /                    ||  MOTORWAY    |
        |   ||                                        |       /                     ||              |
Z=+8km  +---||----------------------------------------+------/----------------------||--------------+
        |   \\=====[6.2 km SALT-FLAT TOP SPEED STRAIGHT]====(IC-M2E)                ||              |
        |                                                       \                   ||              |
        |          [Oasis Hub]                                  [MIRAGE MARINA &    ||              |
        |         (Roundabout)                                   DUBAI SKYLINE]====(IC-M3S)         |
        |                                                       (Supertall Corridor, \              |
        |       REGION 3: DUBAI DESERT & JEBEL JAIS              Spire, Lagoon)       \             |
        |                                                                              \  /\/\/\    |
        |                                                                   [JEBEL JAIS \/ 680m ]   |
        |                                                                   (Fast 3-Lane Canyon Rd) |
Z=+16km +----------------------+----------------------+----------------------+----------------------+
```

| Region / Corridor | Approx. Size (km) | Road Length by Class (km) | Key Landmarks & Features |
|---|---|---|---|
| **1. `tokyo_hakone`** | `12 × 14 km` | `118 km` (`24` hwy/C1, `34` city, `28` mtn touge, `22` coast/country, `10` ramp) | Neo-Tokyo Neon Core, C1 Elevated Loop, Rainbow Bay Bridge, Hakone 18-Hairpin Touge, Crater Lake & Red Torii, Daikanyama Parking Area, 2 Petrol Stations |
| **2. `monaco_alps`** | `13 × 14 km` | `104 km` (`18` hwy, `16` harbour town, `36` alpine pass, `26` corniche/country, `8` ramp) | Port d'Azur Yacht Marina, Waterfront Chicane, Casino Hairpin Plaza, Seafront Cliff Tunnel, Stone Gorge Viaduct, Col de Turini 14 Switchbacks, 2 Petrol Stations |
| **3. `dubai_jais`** | `22 × 11 km` | `128 km` (`40` desert superhighway, `18` skyline avenue, `32` Jebel Jais mtn, `26` dune/oasis, `12` ramp) | Sheikh Zayed Skyline Corridor, 320 m Mirage Spire, 6.2 km Salt-Flat Top-Speed Straight, Desert Oasis Roundabout, Jebel Jais 3-Lane Ridge Climb & Sky Deck, 2 Petrol Stations |
| **Total Country** | **`32 × 32 km`** | **`~350 km`** | **3 Cities/Towns, 3 Signature Mountain Passes, 3 Coasts/Lagoons, 9 Motorway Interchanges, 8 Roundabouts, 6 Petrol Stations** |

---

## 3. Road System Architecture (Zero Tile Seams, C2 Smoothness)

To make it **physically impossible** for any car to be thrown into the air at tile joins, grade transitions, or curves, the road system replaces independent per-tile chord approximations and double-stacked colliders with a **globally indexed, C2-continuous, Rotation-Minimizing Frame (RMF) spline architecture**.

### 3.1 Global Spline Representation & Pre-Sampled Master Frames

1. **Master Curve Evaluation (`world/road_graph.gd` + `tools/gen_network.gd`)**:
   - Every road edge `e` between nodes `a` and `b` is defined in region data by control points `ctrl` with **pinned endpoint tangents `T_a`, `T_b` and endpoint heights/grades `(y_a, g_a)`, `(y_b, g_b)`** derived from the junction solver (§4).
   - **Horizontal Plan (`XZ`)**: Evaluated using a **centripetal Catmull-Rom / cubic Bezier spline** with exact endpoint tangent clamping (`T_a`, `T_b`) so two edges meeting at a continuation node or junction mouth are strictly **$C^1$ tangent-continuous and curvature-bounded** (no reflected phantom-point kinks).
   - **Vertical Profile (`y(s)`)**: Solved as a **cubic Hermite vertical curve** `y(s)` parameterized by arc length `s`, subject to:
     - Exact node elevation `y(0) = y_a`, `y(L) = y_b`,
     - Exact node vertical slope `dy/ds(0) = g_a`, `dy/ds(L) = g_b` (`g = 0.0` at flat junctions/roundabouts; matched `g` across continuation nodes and motorway merges),
     - Maximum grade `|dy/ds| <= MAX_GRADE[type]`,
     - **Minimum vertical crest/sag radius of curvature** $R_v = \left|\frac{d^2y}{ds^2}\right|^{-1} \ge R_{v,\min}$:
       - `HIGHWAY`: $R_{v,\min} = 600\text{ m}$ (at $100\text{ m/s} = 360\text{ km/h}$, vertical centripetal acceleration $a_y = v^2 / R_v \le 16.6\text{ m/s}^2$ on sags and $\le 0.5g$ on crests — **impossible to launch airborne at 350 km/h**),
       - `COUNTRY / CITY / RAMP / JEBEL_JAIS`: $R_{v,\min} = 250\text{ m}$,
       - `MOUNTAIN`: $R_{v,\min} = 120\text{ m}$.
2. **Global Master Cross-Section Table (`RoadGraph` arrays)**:
   - At load time, each edge `e` is resampled at uniform arc-length spacing `STEP = 4.0 m` (`2.0 m` on hairpins with $R < 45\text{ m}$).
   - For every dense index `i ∈ [0, N_e - 1]`, `RoadGraph` precomputes and stores the **exact orthonormal frame** once globally:
     - `e_pts[e][i]` (`Vector3` world center position),
     - `e_fwd[e][i]` (`Vector3` unit tangent),
     - `e_right[e][i]` (`Vector3` banked right vector, rotated around `e_fwd` by smooth superelevation `e_bank[e][i]`),
     - `e_up[e][i]` (`Vector3 = e_right.cross(e_fwd).normalized()`),
     - `e_uv_y[e][i]` (`float` cumulative arc length $s_i$ in meters).
   - **Superelevation (`e_bank[e][i]`)**:
     - Computed from smoothed horizontal curvature $\kappa(s)$ (`16` Gaussian smoothing passes), clamped to $\pm 4.5^\circ$ (`HIGHWAY`, `RAMP`, `JEBEL_JAIS`), $\pm 5.5^\circ$ (`MOUNTAIN` hairpins — banking helps cornering), $\pm 3.0^\circ$ (`COUNTRY`), and $0^\circ$ (`CITY`).
     - Smoothly fades to `0.0` (`quintic smoothstep`) over `45 m` approaching any non-banked junction (`NODE_NORMAL`, `NODE_SIGNAL`, `NODE_ROUNDABOUT`), or matches the mainline bank angle at `NODE_MERGE`.

### 3.2 Segment Ownership & Zero-Seam Tile Partitioning

The root cause of tile-join launches today is that tiles extrapolate their own collision slabs by `±0.4 m` and downsample colliders differently. The new rule is **Strict Segment Ownership with Shared Global Frames**:

1. **Segment Definition**:
   - An edge `e` with dense points `0 .. N_e - 1` consists of `N_e - 1` elementary quad segments `seg_i = [i, i + 1]` for `i ∈ edge_range(e).x .. edge_range(e).y - 1`.
2. **Unique Tile Ownership**:
   - Segment `seg_i = [i, i + 1]` is owned **exclusively** by the tile `(tx, tz)` containing its start point `e_pts[e][i]`:
     $$\text{owner}(\text{seg}_i) = \left(\lfloor \text{pts}[i].x / 1024 \rfloor,\; \lfloor \text{pts}[i].z / 1024 \rfloor\right)$$
3. **Exact Shared Boundary Vertices**:
   - When `seg_{k-1} = [k-1, k]` is in Tile A and `seg_k = [k, k+1]` is in Tile B:
     - Tile A's last cross-section `k` and Tile B's first cross-section `k` both evaluate the **exact same global function**:
       $$\mathbf{V}_{\text{world}}(e, k, m) = \text{e\_pts}[e][k] + \text{e\_right}[e][k] \cdot x_m + \text{e\_up}[e][k] \cdot y_m$$
     - In local coordinates after floating-origin offset, `Tile_A.position + (V_world - Origin_A)` and `Tile_B.position + (V_world - Origin_B)` are **bit-identical (`0.0000 m` vertical/lateral delta, identical normal, identical UV)**!
   - **Zero `±0.4 m` extrapolation**: `_emit_slab`'s `±0.4 m` chord extrapolation is **deleted**.
   - **Single-Layer Exact Road Collider (`RoadShape` = 1 `ConcavePolygonShape3D` per tile)**:
     - Delete the duplicate 2-layer `stride = 2` `_drive_slab_faces()` + visual triangle copy.
     - Instead, the road collider for a `FULL` tile is a **single, clean, 1-layer drivable surface** generated at `stride = 1` (`y = 0.00 m`, exact match to visual road vertices) across the drivable width (`[-hw - sw, +hw + sw]`), with city kerbs beveled at a smooth **30° ramp (`0.25 m` wide × `0.10 m` high)** instead of a vertical `90°` `0.15 m` wall so wheels roll smoothly onto sidewalks without snagging.
     - Put **all road collider triangles of a tile into ONE `ConcavePolygonShape3D`** (built off-thread or uploaded in a single step — with verge skirts excluded and `CITY` blocks reduced to arterial grids, a tile has only `~600–1,400` road collision triangles, cooking in `< 0.8 ms` in Jolt and preserving internal-edge welding across the entire tile!).

### 3.3 Road Types & Cross-Section Profiles

| Type ID | Name | Paved Width | Lanes | Shoulder / Sidewalk | Max Grade | Min Radius | Max Bank | AI Lane Offsets (m) |
|---|---|---|---|---|---|---|---|---|
| `0` | `HIGHWAY` | `22.0 m` (divided) | 2+2 (`3.75 m` lanes, `1.8 m` median) | `1.2 m` paved shoulder + guardrail | `4.5%` | `500 m` | `4.5°` | `±2.75`, `±6.50` |
| `1` | `ARTERIAL` | `14.0 m` (city/skyline) | 2+2 (`3.5 m` lanes) | `3.0 m` sidewalk, `30°` `0.10 m` bevel kerb | `5.0%` | `60 m` | `0.0°` | `±1.75`, `±5.25` |
| `2` | `CITY` | `10.0 m` | 1+1 (`3.8 m` lanes + gutter) | `2.5 m` sidewalk, `30°` `0.10 m` bevel kerb | `6.0%` | `25 m` | `0.0°` | `±2.20` |
| `3` | `COUNTRY` | `8.5 m` | 1+1 (`3.65 m` lanes) | `0.6 m` asphalt-gravel shoulder | `7.5%` | `90 m` | `3.5°` | `±2.00` |
| `4` | `JEBEL_JAIS` | `10.5 m` (desert mtn) | 2+1 (`3.5 m` lanes) | `0.8 m` rock shoulder + parapet | `7.5%` | `38 m` | `5.0°` | `±1.75`, `+5.25` |
| `5` | `MOUNTAIN` | `7.2 m` (touge/alps) | 1+1 (`3.3 m` lanes) | `0.5 m` shoulder + guardrail on drop | `10.0%` | `20 m` | `5.5°` | `±1.75` |
| `6` | `RAMP` | `7.5 m` (1-way slip) | 1 wide + pass shoulder | `0.6 m` shoulder + guardrail | `6.5%` | `75 m` | `4.5°` | `0.0` (center) |

---

## 4. The Junction System (T-Junctions, 4-Way Crossings, Roundabouts & Interchanges)

Every node where $\ge 2$ edges meet is classified into a strict junction archetype (`NODE_CONTINUATION`, `NODE_T_JUNCTION`, `NODE_CROSSROAD`, `NODE_ROUNDABOUT`, `NODE_MERGE`) and meshed so that **edge mouths and junction surfaces share the exact same boundary vertices, heights, normals, and slopes (`0.000 m` seam)**.

```text
  (A) T-JUNCTION / 4-WAY CROSSROAD          (B) ROUNDABOUT (TILTED PLANE)          (C) MOTORWAY GORE MERGE
        Arm 2 (Minor)                              Arm N                              Mainline Highway (Unbroken)
         |   |                                     |   |                         ====================================
      ---+   +---  <-- Exact stitched           _.-'   '-._                      ---------------------\  (Chevron
     /  Fillet   \     mouth vertices         .'   .-"-.   '.   Ring lies on                          \  Gore Apron)
====+     Pad     +==== Arm 0/1             /    /Islnd\    \  tilted plane               Ramp        \  Exact shared
    | (Coplanar)  |     (Through)       ===+    | (Kerb)|    +=== P(x,z)               -----------     +=== edge verts
    +-------------+                         \    \     /    /                             \           /
                                             '._  '-.-'  _.'                               '---------'
```

### 4.1 Universal Mouth-Stitching Invariant

1. For any non-continuation junction node $u$ with incident edges $e_1, \dots, e_k$:
   - Each edge $e_m$ is cut back at dense index $i_{\text{cut}}(e_m, u)$ at distance $d_{\text{cut}}(e_m, u)$ from node $u$.
   - At $i_{\text{cut}}$, the road strip ends with exact cross-section vertices $\mathbf{V}_{\text{mouth}}(e_m) = [\mathbf{v}_{\text{verge,L}}, \mathbf{v}_{\text{sh,L}}, \mathbf{v}_{\text{road,L}}, \mathbf{v}_{\text{road,R}}, \mathbf{v}_{\text{sh,R}}, \mathbf{v}_{\text{verge,R}}]$.
   - **Invariant**: Every junction builder (`_build_t_or_cross`, `_build_roundabout`, `_build_merge`) uses the **exact same $\mathbf{V}_{\text{mouth}}(e_m)$ vertices** as its outer boundary on arm $m$, and in `gen_network.gd` the last `3` dense steps (`12 m`) of edge $e_m$ before $i_{\text{cut}}$ have their vertical height $y(s)$ and roll `bank(s)` Hermite-locked to the junction plane!
   - Therefore, at $i_{\text{cut}}$:
     $$\Delta y = 0.000\text{ m}, \quad \Delta(\text{dy/ds}) = 0.000, \quad \Delta\text{bank} = 0.000^\circ$$

### 4.2 Junction Archetypes

1. **T-Junctions (`NODE_T_JUNCTION`, 3 arms) & 4-Way Crossroads (`NODE_CROSSROAD`, 4 arms)**:
   - **Junction Plane Fitting**: Instead of forcing a flat `y = node.y` fan (which creates grade kinks on hills), node $u$ defines a **tilted tangent plane**:
     $$P_u(x, z) = y_u + s_x (x - x_u) + s_z (z - z_u)$$
     where $(s_x, s_z)$ is the least-squares slope of the through-road (clamped to $\le 4\%$).
   - In `gen_network.gd`, each incident edge $e_m$'s cut point $p_{\text{cut}}$ and tangent at $i_{\text{cut}}$ lie **exactly on $P_u(x, z)$**.
   - **Mesh Construction**:
     - Corner fillets between adjacent arms $m$ and $m+1$ are cubic Bezier arcs matching the exact outward tangents of $\mathbf{v}_{\text{road,R}}(e_m)$ and $\mathbf{v}_{\text{road,L}}(e_{m+1})$ with turning radius $R_{\text{corner}} = 8.0\text{ m}$ (`CITY`) or $14.0\text{ m}$ (`COUNTRY`).
     - Interior is triangulated as a smooth grid/fan evaluated on $P_u(x, z)$ with stop lines, give-way triangles (on minor T-junction arm), and zebra crosswalks (`CITY`/`ARTERIAL`) encoded in `UV` / `COLOR`.
     - Perimeter shoulder, `30°` bevelled kerb, sidewalk, and verge strips extrude continuously along the corner Bezier fillets from arm $m$'s profile to arm $m+1$'s profile.

2. **Roundabouts (`NODE_ROUNDABOUT`, radius $R_{\text{outer}} \in [18, 32]\text{ m}$)**:
   - **Tilted Plane Support**: The roundabout ring lies on a gentle tilted plane $P_u(x, z)$ ($\le 2.5\%$ grade) so hill/valley roundabouts never have step ramps.
   - **Entry/Exit S-Curve Splitter Islands**:
     - Each arm $e_m$ stops at $r = R_{\text{outer}} + 14.0\text{ m}$ where its height and slope are Hermite-locked to $P_u(x, z)$.
     - A `14.0 m` flared entry/exit apron with a **curbed splitter island** divides entry (right lane) and exit (left lane) and blends tangentially into the `9.0 m`-wide circulatory carriageway ring.
     - Central island has a `30°` bevelled granite kerb (`0.12 m` high) and landscaped mound (`+0.65 m`).

3. **Motorway Merges (`NODE_MERGE`) & Grade-Separated Interchanges (`9` total across the map)**:
   - **Zero Flat Crossings on Motorways**: `HIGHWAY` edges (`M1`, `M2`, `M3`, and Tokyo `C1`) never have flat intersections or roundabouts.
   - **Continuous Mainline + Stitched Parallel Gore Taper**:
     - At a `NODE_MERGE`, the mainline `HIGHWAY` edge runs **100% unbroken** (`endpoint_cut = 0`).
     - In `gen_network.gd`, the slip `RAMP` edge $e_{\text{ramp}}$ is generated so that its last `80 m` runs parallel and adjacent to the mainline outer edge (`offset = hw_main + hw_ramp = 11.0 + 3.75 = 14.75 m` tapering to `11.0 m`), with its elevation $y_{\text{ramp}}(s)$ and banking $b_{\text{ramp}}(s)$ **locked strictly equal to the mainline's outer edge elevation** $y_{\text{main}}(s) + \text{lat} \cdot \sin(b_{\text{main}}(s))$!
     - `_merge_aprons()` stitches directly onto the mainline outer vertices `mp + mrt * (m_side * hw_main)` on the inside and the ramp's cut cross-section `p_in .. p_out` at $i_{\text{cut}}$ on the outside, with painted chevron gore markings (`COLOR.a = 0.75`) and a `90 m` acceleration/deceleration taper.
   - **3 Interchange Templates in `gen_network.gd`**:
     - **Trumpet Interchange (`kind: "trumpet"`)**: Used for 3-way motorway-to-motorway or motorway-to-arterial T-splits (`IC-M1W`, `IC-M1E`, `IC-M2E`, `IC-M3N`). One mainline underpass/overpass (`7.5 m` vertical clearance) + directional semi-direct flyover ramp (`R >= 110 m`) + loop ramp (`R >= 75 m`).
     - **Diamond / Dumbbell Interchange (`kind: "diamond_rbt"`)**: Used where motorways cross regional A-roads (`IC-M1C`, `IC-M2N`, `IC-M2S`, `IC-M3S`). Motorway crosses on a concrete box-girder overpass (`+7.5 m` clearance); 4 slip ramps meet the surface road at a pair of tear-drop/roundabout terminals.
     - **Urban Elevated Ramp (`kind: "urban_c1"`)**: Used on Tokyo's elevated `C1` loop (`y = 30 m`), where pair of concrete viaduct slip ramps descend at `5.0%` grade over `240 m` to join surface `ARTERIAL` avenues (`y = 18 m`).

---

## 5. Terrain Conforming (Zero Saw-Tooth Ridges, Full-Resolution Corridor)

### 5.1 Why Terrain Pokes Through Today & How We Fix It

Today, `RoadMesher.stamp()` lowers terrain on the `129×129` (`8 m`) grid by only `OFF = 0.35 m`, and then `TileNode._terrain_collider()` downsamples `HeightMapShape3D` by `stride = 2` to `65×65` (`16 m` cells, `22.6 m` diagonals). On curves and mountain slopes, `16 m` heightmap diagonals chord across the curve and rise above the road surface!

### 5.2 Three-Layer Solution for Guaranteed Terrain Clearance

```text
  Cross-section of Road Corridor on a Mountain Slope:
                     ..--""`  Natural Mountain Slope
                   .'
                  /   Cut Slope (Smooth Quintic Blend: 18m Mtn / 35m Country)
  Road Surface   /
  ==============+======+  <-- Visual Road & 1-Layer RoadShape Collider (y = ry)
   \  Shoulder   \Verge \
  --+-------------+------+---  <-- Stamped Terrain Bench (y = ry - 0.85m, width = hw + 16m)
                                   PLUS Terrain Mesh/HeightMap Hole Cutout directly under
                                   the paved carriageway so terrain can NEVER poke through!
```

1. **Continuous Analytical Corridor Stamping (`RoadMesher.stamp()`)**:
   - Increase `OFF` under the road bench from `0.35 m` to **`0.85 m`** (hidden cleanly behind the road's `0.85 m` shoulder + verge skirt drop).
   - Increase `bench` half-width to **`half_width(type) + 16.0 m`** (always $> 2 \times 8\text{ m}$ grid cells outside the road edge) and use **`stride = 1` (`4 m` dense segments)** for all road types in `FULL` tiles.
   - Replace linear segment-projection distance jump with **smooth polyline projection**: at junctions, roundabouts, and merge aprons, stamp the junction's exact tilted plane $P_u(x, z) - 0.85\text{ m}$ out to radius $R_{\text{junc}} + 16.0\text{ m}$.
   - Use a **quintic $C^2$ blend curve** $w(d) = 1 - (6u^5 - 15u^4 + 10u^3)$ where $u = \text{clamp}((d - \text{bench}) / \text{blend}, 0, 1)$, with `blend = 22.0 m` (`MOUNTAIN` / `JEBEL_JAIS`) and `38.0 m` (`COUNTRY` / `HIGHWAY`).
   - **City / Town Footprint Flattening**: Every city or harbour-town zone defines analytical flat or terraced plateau polygons in the region JSON (`terraces: [{poly, y, blend_m}]`). Inside a city block grid, `TerrainFn.base_height()` returns the exact terrace height `y` before `RoadMesher.stamp()` even runs—so `RoadMesher.stamp()` skips flat city interior edges (`O(1)` fast path, saving `~600 ms` of worker time on city tiles!).

2. **Full-Resolution `129×129` (`8 m`) `HeightMapShape3D` + Paved-Corridor Hole Mask**:
   - Why did `TileNode._terrain_collider()` downsample `129×129` to `65×65`? Because creating the `HeightMapShape3D` and assigning `map_data` was done alongside heavy `ConcavePolygonShape3D` chunks. In Jolt Physics, a `129×129` `HeightMapShape3D` (`16,641` floats = `65 KB`) cooks in **`~1.4 ms`** when isolated in its own apply step!
   - Even better: for any terrain vertex `(i, j)` in a `FULL` tile that lies strictly **under the paved carriageway** ($d_{\text{lat}} < \text{hw} - 1.0\text{ m}$ on ground-level roads, or inside tunnel portals), we clamp `h[q] = minf(h[q], ry[q] - 0.85)` AND check all 4 corners of each `8 m` terrain cell against the road plane. Because `RoadShape` (`ConcavePolygonShape3D`) covers `[-hw - sw - 1.5 m, +hw + sw + 1.5 m]` at `y = ry` while `HeightMapShape3D` is guaranteed $\le \text{ry} - 0.85\text{ m}$ across the entire `hw + 16 m` bench on an `8 m` grid, **no terrain triangle or diagonal can ever approach within `0.70 m` of the road surface**, even on a `20 m`-radius alpine hairpin!
   - **MID/FAR Tiles Have Zero Collision Shapes**: `TileGen._terrain()` currently outputs `d["hm"]` for `MID` tiles (`lod != FAR`, `world/tile_gen.gd:209`), and `RoadMesher.mesh()` outputs `_drive_slab_faces()` for `MID` and `FAR` tiles (`world/road_mesher.gd:333`)! The car is **always inside the center 3×3 `FULL` ring** (`1,536 m` radius around the car). Cooking physics shapes for the `16 MID + 24 FAR = 40 outer LOD tiles` wastes massive CPU/RAM and causes Jolt job-pool saturation (`WARNING: Jolt Physics job system exceeded the maximum number of jobs` in `logs/smoke.log:3`). **Only `FULL` tiles (`lod == FULL`) will create physics colliders!**

---

## 6. City & Region Architecture, Streaming, and Performance Budgets

### 6.1 Fixing the City: Merged Block Meshes, HLOD/Impostors, Occlusion Culling & Shader Tiers

Instead of putting `~115` individual overlapping `BoxMesh` instances into one giant un-culled `MultiMeshInstance3D` with a 12-texture shader and 60 per-building `BoxShape3D` colliders, cities (`Neo-Tokyo`, `Port d'Azur`, `Mirage Marina`) use a **Per-Block Merged Architecture (`world/city_block_builder.gd`)**:

```text
  City Tile (e.g. Neo-Tokyo Core: 4x4 Blocks per 1024m Tile)
  ├─ Block_0_0 (Node3D, 180m x 180m block)
  │   ├─ OccluderInstance3D (1 BoxOccluder3D: 150m x 45m x 150m -> culls all blocks behind it!)
  │   ├─ Buildings_LOD0 (MeshInstance3D: 1 merged ArrayMesh for the whole block, 0..280m, ~400-800 tris)
  │   ├─ Buildings_LOD1 (MeshInstance3D: 1 simplified hull ArrayMesh, 280..900m, ~120 tris, simple shader)
  │   ├─ Buildings_LOD2 (MeshInstance3D: 1 low-poly block prism impostor, 900..3200m, ~24 tris, vertex-lit)
  │   ├─ NeonSigns_LOD0 (MeshInstance3D: 1 merged emissive signage mesh, 0..220m, disabled/reduced on Low)
  │   └─ BlockCollider (1 single BoxShape3D covering the entire block perimeter curb-to-curb!)
```

1. **One Merged Mesh Per City Block (`Buildings_LOD0`) — Zero Stacked-Box Overdraw**:
   - Each city block (`~140–180 m` pitch) merges all of its buildings (podiums, towers, setbacks, storefronts, roof parapets) into **a single `ArrayMesh` (`1 draw call per block`)** during worker-thread tile generation (or pre-baked `.res` for hero landmark blocks).
   - **Hidden Face Elimination**: Bottom faces (underground) and interior horizontal faces where a tower shaft sits on a podium are **never emitted**—cutting building triangle count and self-overdraw by **45%**.
   - **Per-Block Frustum & Occlusion Culling**: Because each block is its own `MeshInstance3D` (`16 blocks` per city tile = maximum `6–9 blocks` inside the camera's 65°–90° frustum at once), blocks behind the camera are frustum-culled immediately.
2. **Hardware/Software Occlusion Culling (`OccluderInstance3D` per Block)**:
   - Godot 4's built-in CPU raster occlusion culling (`Viewport.use_occlusion_culling = true` in `project.godot`) is enabled.
   - Each city block gets **one `OccluderInstance3D` with a single `BoxOccluder3D`** inset `0.5 m` inside the block's lowest continuous podium/facade perimeter (`e.g. 110 m × 28 m × 110 m`).
   - When the car is driving on a street between blocks, the front row of `BoxOccluder3D` boxes **completely occludes 70–85% of the blocks, props, and scatter tiles behind them** before they ever reach the GPU vertex/fragment stage!
3. **3-Tier Building LOD & Distant Block Impostors**:
   - **`LOD0` (`0–280 m` Med/High, `0–180 m` Low)**: Merged block mesh (`~400–800 tris/block`) + `NeonSigns_LOD0` (`0–220 m`, emissive signboards/billboards merged into 1 surface per block).
   - **`LOD1` (`280–900 m` Med/High, `180–700 m` Low)**: Single simplified block massing mesh (no setbacks/mullions/signs, `~120 tris/block`), using a cheap `building_lod.gdshader` (**zero normal maps, 1 atlas texture + procedural window grid + night glow**).
   - **`LOD2` Skyline Impostor (`900–3,200 m`, placed on `MID`/`FAR` city tiles)**: One ultra-cheap merged silhouette prism mesh **per entire 1024 m city tile** (`1 draw call per tile`, `~150–300 tris`), vertex-colored with procedural night-window horizon glow so the Tokyo/Dubai skyline is visible from `3 km` away on the motorway at **1 draw call**.
4. **Tiered `building.gdshader` (Fixing the 12-Texture Bandwidth Bottleneck)**:
   - Replace the 12 separate 1K textures (`4 styles × 3 maps`) with a **single `2048×2048` (or `4-slice Texture2DArray`) Building Atlas** (`1 diffuse + 1 normal/roughness` = **2 texture bindings total** instead of 12!).
   - On `Low` preset (and beyond `45 m` on `Medium`), skip normal-map sampling entirely (`nor_fade`) and use pure analytical window/facade shading.
5. **One `BoxShape3D` Per Block (Not 60 Per-Building Boxes Dripped in `_process`)**:
   - Cars drive on streets and sidewalks, never inside solid building blocks. Each rectangular city block needs **only 1 `BoxShape3D`** (spanning the block's building footprint) added inside `TileNode`'s normal `_props_collider_chunk` step (`16 BoxShape3D` total for an entire city tile, cooked in `< 0.15 ms`!). Delete `city_downtown.gd:_process()` collider dripping.
6. **Fixing GLB Car Draw Calls (`cars/glb/glb_body.gd`)**:
   - In `GlbBody._enter_tree()`, merge all static chassis `MeshInstance3D` surfaces that share the same material into a single multi-surface `ArrayMesh` (`ChassisMerged`), and merge each wheel corner's (`WheelFL..RR`) sub-meshes by material. This collapses `mclaren_p1_vecarz` (`195` nodes), `mclaren_600lt` (`850` nodes), and `koenigsegg_gemera` (`756` nodes) down to **≤ 12 `MeshInstance3D` nodes (`≤ 22` draw calls)** per car, with `cast_shadow = OFF` on all sub-meshes except the outer body shell and 4 wheels!

### 6.2 Region & Tile Streaming Architecture

1. **Two-Level Streaming (`RegionManager` + `TileStreamer`)**:
   - **Level 1 — Country & Active Region Window (`world/region_streamer.gd`)**:
     - Reads `country.json` (`32 × 32 km` world). Tracks which of the 3 regions (`tokyo_hakone`, `monaco_alps`, `dubai_jais`) the car is inside or approaching (within `3.0 km` along a motorway).
     - Keeps only the **current region's asset palette** (building block atlas, neon sign atlas, regional landmark `.res` meshes, regional foliage/rock `.res` meshes) resident in VRAM; unloads distant regions' unique textures/meshes when `> 4.5 km` away.
   - **Level 2 — 7×7 Tile Grid (`world/tile_streamer.gd`)**:
     - Ring radii scaled by preset:
       - **Low**: `FULL` = `3×3` (`9` tiles, `d <= 1`), `MID` = `5×5` (`16` tiles, `d == 2`), `FAR` = `7×7` (`24` tiles, `d == 3`, `draw_distance = 2400 m`).
       - **Medium / High**: `FULL` = `3×3` (`9` tiles), `MID` = `5×5` (`16` tiles), `FAR` = `7×7` (`24` tiles, `draw_distance = 3600–4500 m`).
     - **Scatter Coalescing (`4` Chunks per Tile instead of `16`, Decimated Baked Meshes)**:
       - Reduce scatter chunks per `FULL` tile from `4×4 = 16` (`256 m`) to **`2×2 = 4` chunks (`512 m`)**, cutting `MultiMeshInstance3D` node count by **4×** (`≤ 28 MMIs/tile` instead of `176`).
       - Eliminate the `45 m` `LOD0`/`LOD1` double-draw overlap (`VIS_LOD0_END = 160 m`, `VIS_LOD1_START = 160 m` with a `12 m` screen-door crossfade only on `Medium`/`High`, hard swap at `130 m` on `Low`).
       - Re-bake `tree_pine_lod0.res` (`365 KB` -> `< 35 KB`, `≤ 450 tris`), `tree_conifer_lod0.res` (`≤ 350 tris`), `tree_oak_lod0.res` (`≤ 350 tris`), and `LOD1` trees (`≤ 60 tris`).
     - **Sub-2ms Apply Steps**:
       - Split `_terrain_mesh`, `_road_mesh`, and `_props_mesh` array assembly (`ArrayMesh.add_surface_from_arrays`) into the **worker thread** (in Godot 4.7, `ArrayMesh.new()` and `ConcavePolygonShape3D.new()` + `set_faces()` are `Resource` creations that are thread-safe when not yet attached to the scene tree; the main thread only creates `MeshInstance3D` / `CollisionShape3D` and calls `add_child`, taking **`< 0.25 ms` per step** instead of `4.96 ms`!).

### 6.3 Strict Performance Budgets Per Preset (`1366×768`, GeForce 610M / Radeon 610M)

| Metric / Budget Item | **Low Preset** (610M Safe) | **Medium Preset** (Default) | **High Preset** (Forward+ Desktop) |
|---|---|---|---|
| **Target FPS / Min Floor** | **48–60 FPS** (never **< 30 FPS**) | **40–55 FPS** (never **< 25 FPS**) | **60 FPS** (never **< 45 FPS**) |
| **Max Frame Time (Avg / P99 / Max)** | `≤ 19 ms / ≤ 26 ms / ≤ 33 ms` | `≤ 22 ms / ≤ 30 ms / ≤ 40 ms` | `≤ 16.6 ms / ≤ 20 ms / ≤ 25 ms` |
| **Renderer & 3D Resolution Scale** | `mobile`, `0.80` (`1092×614`), MSAA Off | `mobile`, `1.00` (`1366×768`), FXAA (no MSAA 2× fill-rate penalty in city) | `forward_plus`, `1.00`, MSAA 2× / TAA |
| **Directional Shadows** | **Off (`0`)** or Blob/Car-only (`512` ortho `35 m`, world `cast_shadow = OFF`) | **`1024` atlas, 1-split (`75 m`), `blend_splits = false`**; only `Buildings_LOD0` + `Car` cast shadows (trees/props `cast_shadow = OFF`) | `2048–4096` atlas, 3-split PSSM (`240 m`), trees + buildings + props cast shadows |
| **Max Draw Calls in View (Any Region)** | **≤ 110** (City ≤ 110, Pass ≤ 95) | **≤ 165** (City ≤ 165, Pass ≤ 140) | **≤ 320** |
| **Max Triangles in View (Main + Shadow)** | **≤ 110k** (City ≤ 95k, Pass ≤ 110k) | **≤ 200k** (City ≤ 170k, Pass ≤ 200k) | **≤ 450k** |
| **City Tile (`1024×1024 m`) Budget** | `≤ 22` draw calls, `≤ 25k` tris, `0` shadow casters, `16` `BoxOccluder3D` | `≤ 34` draw calls, `≤ 45k` tris, `16` block shadow casters, `16` `BoxOccluder3D` | `≤ 55` draw calls, `≤ 90k` tris, full neon + street trees |
| **Car Draw Calls (Any Car)** | **≤ 12** (`Mirrors` Off, `Probe` Off) | **≤ 18** (`Mirrors` 1 rear @ every 4f, `Probe` Off) | **≤ 24** (`Mirrors` 3 @ every 2f, `Probe` On) |
| **Worker Build Time per FULL Tile** | `≤ 120 ms` | `≤ 150 ms` | `≤ 180 ms` |
| **Main-Thread Streamer Cost / Frame** | `avg ≤ 0.2 ms, p99 ≤ 0.8 ms, max ≤ 2.5 ms` | `avg ≤ 0.2 ms, p99 ≤ 1.0 ms, max ≤ 3.0 ms` | `avg ≤ 0.3 ms, p99 ≤ 1.2 ms, max ≤ 3.5 ms` |
| **VRAM / System RAM** | `≤ 180 MB VRAM / ≤ 550 MB RAM` | `≤ 260 MB VRAM / ≤ 680 MB RAM` | `≤ 600 MB VRAM / ≤ 1.1 GB RAM` |

---

## 7. Data-Driven Region & Country Format

Adding a new region or a new country requires **zero code changes**: one country manifest (`res://data/maps/<country_id>/country.json`) plus one data file per region (`res://data/maps/<country_id>/regions/<region_id>.json`) and its referenced `.res` asset bundle.

### 7.1 Country Manifest (`res://data/maps/horizon_triland/country.json`)

```json
{
  "schema_version": 1,
  "country_id": "horizon_triland",
  "display_name": "Horizon Triland (Kanto • Azur • Mirage)",
  "world_seed": 202611,
  "tile_size_m": 1024.0,
  "bounds_tiles": { "min": [-16, -16], "max": [15, 15] },
  "default_spawn": { "region": "tokyo_hakone", "spawn_id": "shuto_c1_bayshore" },
  "regions": [
    {
      "id": "tokyo_hakone",
      "file": "res://data/maps/horizon_triland/regions/tokyo_hakone.json",
      "bounds_m": { "min": [2048, -12288], "max": [14336, 3072] },
      "preload_radius_m": 3000.0
    },
    {
      "id": "monaco_alps",
      "file": "res://data/maps/horizon_triland/regions/monaco_alps.json",
      "bounds_m": { "min": [-14336, -14336], "max": [-1024, 0] },
      "preload_radius_m": 3000.0
    },
    {
      "id": "dubai_jais",
      "file": "res://data/maps/horizon_triland/regions/dubai_jais.json",
      "bounds_m": { "min": [-13312, 3072], "max": [9216, 14336] },
      "preload_radius_m": 3000.0
    }
  ],
  "inter_region_motorways": "res://data/maps/horizon_triland/motorways.json"
}
```

### 7.2 Per-Region Data File (`res://data/maps/horizon_triland/regions/<region_id>.json`)

```json
{
  "schema_version": 1,
  "region_id": "tokyo_hakone",
  "display_name": "Kanto Neon & Hakone Pass",
  "theme": "neon_metropolis_touge",
  "assets": {
    "building_atlas": "res://assets/regions/tokyo_hakone/tokyo_facades_2k.png",
    "neon_atlas": "res://assets/regions/tokyo_hakone/tokyo_neon_1k.png",
    "foliage_set": ["tree_cedar", "tree_pine", "tree_cherry_oak", "shrub_bamboo", "rock_volcanic"],
    "landmark_meshes": {
      "red_torii": "res://assets/regions/tokyo_hakone/landmarks/red_torii.res",
      "tokyo_tower_spire": "res://assets/regions/tokyo_hakone/landmarks/tokyo_spire.res",
      "rainbow_bridge_pylon": "res://assets/regions/tokyo_hakone/landmarks/bay_pylon.res"
    }
  },
  "terrain": {
    "biomes": [
      { "biome": "city", "shape": "rect", "min": [7168, -3072], "max": [11264, 512], "falloff": 450.0 },
      { "biome": "mountain", "shape": "circle", "center": [6200, -8200], "radius": 3200.0, "falloff": 2000.0, "amp_scale": 1.35 },
      { "biome": "forest", "shape": "circle", "center": [5800, -6400], "radius": 2800.0, "falloff": 1500.0 },
      { "biome": "coast", "shape": "rect", "min": [4096, 512], "max": [14336, 4096], "falloff": 900.0 }
    ],
    "terraces": [
      { "name": "neo_tokyo_basin", "min": [7168, -3072], "max": [11264, 512], "y": 18.0, "blend_m": 180.0 },
      { "name": "daikanyama_parking", "min": [6050, -8450], "max": [6250, -8280], "y": 545.0, "blend_m": 45.0 }
    ],
    "water_bodies": [
      { "kind": "caldera_lake", "name": "Lake Ashi", "center": [5200, -8400], "radius": 720.0, "water_y": 410.0 },
      { "kind": "sea_bay", "name": "Kanto Bay", "coast_z": 1600.0, "water_y": 0.0 }
    ]
  },
  "city_zones": [
    {
      "name": "Neo-Tokyo Core",
      "origin_xz": [7424.0, -2816.0],
      "grid_blocks": [8, 6],
      "block_pitch_m": [180.0, 180.0],
      "street_type": "city",
      "avenue_every": 2,
      "elevation_y": 18.0,
      "style_weights": { "neon_commercial": 0.50, "glass_highrise": 0.35, "midrise_concrete": 0.15 },
      "height_range_m": { "core": [55.0, 165.0], "fringe": [22.0, 58.0] },
      "neon_density": { "low": 0.25, "medium": 0.65, "high": 1.0 },
      "pedestrian_density": { "low": 0.0, "medium": 0.4, "high": 1.0 }
    }
  ],
  "nodes": [
    { "id": "tk_n0", "p": [7424.0, 18.0, -1016.0], "kind": "signal", "grade_plane": [0.0, 0.0] },
    { "id": "tk_ic_c1_bay", "p": [9216.0, 30.0, 200.0], "kind": "merge", "interchange": "urban_c1" },
    { "id": "hk_rbt_base", "p": [6400.0, 128.0, -4800.0], "kind": "roundabout", "radius": 24.0 }
  ],
  "routes": [
    {
      "id": "shuto_c1_loop",
      "type": "highway",
      "kind": "overpass",
      "closed": true,
      "fillet_r": 280.0,
      "wp": [[7600, 30, -2600], [10800, 30, -2600], [10800, 30, 200], [7600, 30, 200]]
    },
    {
      "id": "hakone_touge_climb",
      "type": "mountain",
      "kind": "road",
      "hairpins": 18,
      "wp": [[6400, 128, -4800], [6150, 545, -8350]]
    }
  ],
  "pois": [
    { "id": "petrol_shibuya", "kind": "petrol_station", "pos": [8144.0, 18.0, -1376.0], "yaw_deg": 90.0, "brand": "ENEOS_NEON" },
    { "id": "petrol_hakone_pa", "kind": "petrol_station", "pos": [6140.0, 545.0, -8360.0], "yaw_deg": 180.0, "brand": "TOUGE_PA" },
    { "id": "lm_red_torii", "kind": "landmark", "mesh": "red_torii", "pos": [5580.0, 412.0, -7920.0], "yaw_deg": 35.0 }
  ],
  "spawns": [
    { "id": "shuto_c1_bayshore", "route": "shuto_c1_loop", "s_m": 1200.0, "dir": 1 },
    { "id": "hakone_summit", "route": "hakone_touge_climb", "s_m": 6800.0, "dir": -1 }
  ],
  "traffic": {
    "max_vehicles": { "low": 6, "medium": 16, "high": 32 },
    "spawn_radius_m": [120.0, 550.0]
  },
  "weather_weights": { "clear": 0.50, "overcast": 0.20, "rain": 0.30 }
}
```

---

## 8. Room for Later Phases (Preset-Scaled Hooks Built Into the Plan)

1. **AI Traffic Following Road Splines (`world/traffic_manager.gd`)**:
   - Every edge `e` in `RoadGraph` exposes `lane_count(edge, dir)` and `sample_lane(edge, s_m, lane_idx, dir) -> Transform3D` using the precomputed `e_pts`, `e_fwd`, `e_right`, `e_up` arrays, plus junction turn connectors `node_turn_arcs[node][in_edge][out_edge]`.
   - Traffic cars are rendered via **1 `MultiMeshInstance3D` per vehicle archetype** (sedan, kei van, supercar, truck; `< 300 tris` each) updated in a single C-array buffer write per frame (`0` RigidBody3D physics cost for distant cars; only the nearest `4` cars within `80 m` activate a kinematic `AnimatableBody3D` `BoxShape3D` for collision).
   - **Preset Scaling**: `Low = 6` active traffic cars, `Medium = 16`, `High = 32`.
2. **Pedestrians in Cities (`world/pedestrian_crowd.gd`)**:
   - Sidewalk splines (`±(hw + KERB_W + SIDEWALK * 0.5)`) are implicitly defined along every `CITY` and `ARTERIAL` edge.
   - Rendered via **1 `MultiMeshInstance3D` per city tile** using vertex-shader walk-cycle animation (`custom_data` stores walk phase, speed, and clothing tint; `~90 tris` per pedestrian, zero `Skeleton3D` skinning overhead!).
   - **Preset Scaling**: `Low = Off (0)` (zero cost on GeForce 610M Low), `Medium = 40` instances within `140 m`, `High = 120` instances within `220 m`.
3. **Petrol Stations & Landmarks (`world/poi_builder.gd`)**:
   - Defined in each region's `pois` array (`petrol_station`, `landmark`, `viewpoint`).
   - Petrol stations (`6` total: 2 per region) are built as a single merged `ArrayMesh` (canopy, illuminated price totem, pumps, drive-through apron stitched smoothly to the road shoulder at `y = road_y`) + `Area3D` trigger (repairs/refuels/resets disc heat when driven through).
   - Landmarks (Tokyo Spire, Hakone Lake Red Torii, Monaco Casino Plaza & Yachts, Mirage 320 m Spire, Jebel Jais Sky Deck) include a long-range `LOD2` mesh visible up to `3,500 m`.
4. **Wet-Road Rain & Regional Atmosphere (`world/weather.gd`, `shaders/road.gdshader`, `shaders/building.gdshader`)**:
   - Driven by global shader uniform `wetness` (`0..1`) and regional weather weights (e.g. neon reflections on wet Tokyo asphalt, Mediterranean golden hour in Monaco, dry heat haze in Dubai).
   - **Preset Scaling**:
     - `Low`: `300` rain particles, road albedo darkening + roughness drop (`wetness`), **skip** procedural raindrop ripple math (`dist < 30.0` ripples disabled on `Low`).
     - `Medium`: `600` rain particles, wet road puddles + neon reflection tint in `road.gdshader`, raindrop ripples within `20 m`.
     - `High`: `1,200` rain particles, screen-space reflections (`SSR`), volumetric mist in Hakone/Alps, windshield droplets in cockpit view.

---

## 9. Automated Test Plan: Smoothness Gate & Per-Region FPS Gate

### 9.1 Gate A — All-Car, All-Road Smoothness Gate (`tests/smoothness_gate.gd`)

Replaces the limited 5-tile `kick_test.gd` with an exhaustive, deterministic **100% network coverage smoothness gate**:

- **Scope**: Iterates over **every available car** (`p1`, `mclaren_p1_vecarz`, `mclaren_600lt`, `koenigsegg_gemera`, `bentley_exp10_speed6`) and **every edge `e` + every junction transition + every tile boundary crossing** across all 3 regions (`tokyo_hakone`, `monaco_alps`, `dubai_jais`) and the inter-regional motorways (`M1`, `M2`, `M3`).
- **Execution Mode**:
  - Stage 1 (**Static Geometric & Collider Continuity Audit**, runs in `< 3 s` across all `~350 km`):
    - Walks every dense step `i` of every edge `e` and every junction mouth `i_cut`:
      - Asserts adjacent vertex height step $\left|\Delta y / \Delta s - g_i\right| \le 0.008$ (no saw-tooth kinks),
      - Asserts discrete vertical curvature $\left|\Delta g / \Delta s\right| \le 1 / R_{v,\min}$ (no launch crests/sags),
      - Asserts exact `0.000 m` vertex match across every tile boundary `(tx_A, tz_A) -> (tx_B, tz_B)` and every junction mouth `i_cut`,
      - Raycasts against live tile physics colliders along left/right wheel tracks across every tile seam and junction mouth: asserts raycast hit height matches `RoadGraph` spline height within **`≤ 0.015 m` (`1.5 cm`)** and surface normal angle change between consecutive `1 m` rays is **`≤ 1.8°`**.
  - Stage 2 (**High-Speed Physics Drive Gate**, drives each car at `280–350 km/h` on motorways/desert, `160–220 km/h` on country/Jebel Jais, `110–150 km/h` on city/touge/alpine across all tile seams, roundabouts, T-junctions, and interchanges):
    - **Hard Fail Conditions (Zero Grace Windows)**:
      1. **Airtime Fail**: `car.wheels_in_contact() == 0` for **`> 2` physics ticks (`33 ms`)** anywhere on the road network, OR `car.wheels_in_contact() < 3` for **`> 8` ticks (`133 ms`)** on any tile boundary or junction.
      2. **Vertical Jolt Fail (`dv_y`)**: Per-tick vertical velocity jump `absf(v_local.y - prev_v_local.y) > 0.45 m/s` (`~2.7g` vertical impulse in `1/60 s`).
      3. **Lateral / Roll / Pitch Kick Fail (`dv_lat`, `dw`)**: `absf(v_local.x - prev_v_local.x) > 0.50 m/s` or `maxf(absf(w.x - prev_w.x), maxf(absf(w.y - prev_w.y), absf(w.z - prev_w.z))) > 0.50 rad/s` (with **zero `LAND_GRACE` masking**).
      4. **Chassis Contact Fail**: `not car.get_colliding_bodies().is_empty()` (chassis `BoxShape3D` must **never** touch any road, kerb, or terrain collider).
      5. **Fall-Through Fail**: `wpos.y - road_y < -0.15 m` or `main.fall_count > 0`.
- **Output**: Prints `SMOOTHNESS PASS (<n> cars, <km> km, <seams> tile seams, max_dv_y=<x>, max_air_ticks=0)` or `SMOOTHNESS FAIL: <car> at <region> edge <e> world <pos>: <reason>`.

### 9.2 Gate B — Per-Region FPS & Render Budget Gate (`tests/fps_gate.gd`)

Tests performance across **6 benchmark cameras/drives** (`Neo-Tokyo Core`, `Hakone Touge`, `Port d'Azur Harbour`, `Col de Turini Alps`, `Mirage Skyline`, `Jebel Jais Pass`) under both **`low`** and **`medium`** presets:

1. **Headless Deterministic Budget Gate (runs in `tools/run_gates.bat`)**:
   - Streams each of the 6 regional benchmark zones to `FULL` (`world.is_ready()`), sweeps the camera `360°` while driving `500 m` through the densest block/junction, and inspects scene & `Performance` monitors + `TileStreamer` timings:
     - **Draw Calls / Visible Mesh & MultiMesh Surfaces in Frustum**:
       - `Low`: **FAIL if `> 110`** in any region (Neo-Tokyo City must be `≤ 110`).
       - `Medium`: **FAIL if `> 165`** in any region (Neo-Tokyo City must be `≤ 165`).
     - **Triangles in Frustum (Main + Shadow Cascades)**:
       - `Low`: **FAIL if `> 110,000`**.
       - `Medium`: **FAIL if `> 200,000`**.
     - **Occluder Verification**: Asserts every city tile has `≥ 12` active `OccluderInstance3D` nodes and `Viewport.is_using_occlusion_culling() == true`.
     - **CPU & Streaming Frame Budget**:
       - **FAIL** if `streamer.frame_ms` `p99 > 2.0 ms` or `max > 6.0 ms` after warm-up, or if any worker job `max_job_ms > 200 ms`, or if total main-thread process + physics tick exceeds `10.0 ms` (`p99`).
2. **Windowed GPU Frame-Rate Gate (`tools/run_fps_gate.bat`, runs with live Mobile renderer)**:
   - Drives a `20 s` (`1,200` frames) automated benchmark route through each of the 3 regions (`tokyo_hakone` city + pass, `monaco_alps` harbour + hairpins, `dubai_jais` skyline + canyon) at `1366×768` with `--vsync=off` on `low` and `medium`:
     - **FAIL** if **any region's average FPS `< 40.0 FPS`** (`target 40–55+ FPS`),
     - **FAIL** if **1%-low FPS `< 28.0 FPS`**,
     - **FAIL** if **minimum 0.25-second rolling FPS `< 25.0 FPS`** (hard floor).
   - Prints `FPS GATE PASS: tokyo_hakone avg=51.2 min=34.1 | monaco_alps avg=54.6 min=38.0 | dubai_jais avg=56.4 min=39.2`.

---

## 10. Ordered Implementation Tasks (`M1`..`M15`)

Every task is small, self-contained, and must pass `tools\run_gates.bat` (including the new smoothness and FPS budget gates as soon as they are introduced) before committing as `M<n>: <summary>`. **Never commit anything from `assets_nc`. Never push.**

- **`M1` — Smoothness Gate & Per-Region FPS/Budget Gate Harness (`tests/smoothness_gate.gd`, `tests/fps_gate.gd`, `tools/run_gates.bat`)**:
  - Build `tests/smoothness_gate.tscn/.gd` (Stage 1 static seam/raycast audit + Stage 2 all-car physics drive with zero-airtime / zero-jolt assertions) and `tests/fps_gate.tscn/.gd` (per-region draw-call, triangle, shadow-caster, occluder, and CPU frame-time assertions + windowed GPU FPS mode).
  - Wire both into `tools/run_gates.bat`.
- **`M2` — Fix Car Draw-Call Explosion & Low/Medium Shadow/Scatter Budgets (`cars/glb/glb_body.gd`, `world/scatter.gd`, `world/tile_node.gd`, `tools/bake_nature_meshes.gd`, `autoload/settings.gd`)**:
  - Merge static GLB chassis and wheel sub-meshes by material in `GlbBody` (`756` nodes -> `≤ 12` nodes/car, `cast_shadow = OFF` on interior/trim).
  - Re-bake nature `.res` meshes to strict poly budgets (`tree_pine_lod0` `365 KB` -> `≤ 35 KB` / `450 tris`), coalesce scatter chunks from `4×4` (`16`) to `2×2` (`4`) per tile, remove the `165–210 m` LOD0/LOD1 double-draw overlap, and disable tree/prop shadow casting on `Low`/`Medium`.
  - Upload `ArrayMesh` and `ConcavePolygonShape3D` resources on worker threads so main-thread `TileNode.step()` never exceeds `1.0 ms`.
- **`M3` — City Block Architecture: Merged Block Meshes, 2-Texture Atlas, LOD0/1/2 Impostors, `BoxOccluder3D` & Single-Box Block Colliders (`world/city_block_builder.gd`, `shaders/building.gdshader`, `shaders/building_lod.gdshader`, `project.godot`)**:
  - Enable `rendering/occlusion_culling/use_occlusion_culling=true` in `project.godot`.
  - Build `CityBlockBuilder` (worker-safe): generates 1 merged `Buildings_LOD0` mesh, 1 `Buildings_LOD1` mesh, 1 tile-wide `Buildings_LOD2` skyline impostor, 1 `NeonSigns_LOD0` mesh, 1 `OccluderInstance3D` (`BoxOccluder3D`), and 1 `BoxShape3D` per city block.
  - Replace the 12-texture `building.gdshader` with a 2-texture atlas shader + cheap `building_lod.gdshader`. Verify `fps_gate` passes `> 45 FPS` in the existing city before expanding the world.
- **`M4` — Zero-Seam Road Collider, Full-Res `129×129` Terrain Conforming & C2 Vertical Splines (`world/road_graph.gd`, `world/road_mesher.gd`, `world/tile_gen.gd`, `world/tile_node.gd`, `tools/gen_network.gd`)**:
  - Upgrade `RoadGraph` & `gen_network.gd` with endpoint-tangent-pinned splines, Hermite vertical profiles with minimum vertical curvature radius $R_{v,\min}$ (`600 m` hwy / `120 m` mtn), and precomputed global `[e_pts, e_fwd, e_right, e_up]` frames.
  - Replace `_drive_slab_faces()` (`±0.4 m` extrapolated lips + double-stacked colliders) with a **single-layer exact `stride = 1` road collider** in one `ConcavePolygonShape3D` per `FULL` tile, with `30°` bevelled kerbs.
  - Remove physics colliders from `MID`/`FAR` tiles; restore full `129×129` (`8 m`) `HeightMapShape3D` on `FULL` tiles with `OFF = 0.85 m`, `bench = hw + 16 m`, and paved-corridor height clamping.
- **`M5` — Stitched Junction System: Tilted-Plane T-Junctions, Crossroads, Roundabouts & Motorway Gore Merges (`world/road_mesher.gd`, `tools/gen_network.gd`)**:
  - Implement tilted-plane $P_u(x, z)$ junction fitting, Hermite mouth locking over the last `12 m` of every approaching edge, exact shared mouth vertices $\mathbf{V}_{\text{mouth}}$, S-curve splitter-island roundabouts, and parallel-locked motorway gore merges (`trumpet`, `diamond_rbt`, `urban_c1` interchanges).
  - Verify `smoothness_gate` passes with **0 airtime ticks and 0 jolts** across all cars.
- **`M6` — Data-Driven Multi-Region Loader & `32 × 32 km` Country Manifest (`world/region_streamer.gd`, `world/terrain_fn.gd`, `data/maps/horizon_triland/country.json`)**:
  - Refactor `TerrainFn` and `RoadGraph` to load from `country.json` + modular `regions/<region_id>.json` files (`32 × 32 km` bounds, analytical city terraces, multi-lake/bay water levels, per-region asset palettes).
  - Add `RegionStreamer` to manage active region asset lifetimes.
- **`M7` — Inter-Regional Motorway Backbone (`M1`, `M2`, `M3`) & 9 Grade-Separated Interchanges (`data/maps/horizon_triland/motorways.json`, `tools/gen_network.gd`)**:
  - Author the `~82 km` motorway triangle (`M1` Trans-Northern Viaduct, `M2` Western Coastal-Desert with the `6.2 km` salt-flat top-speed straight, `M3` Eastern Bay-to-Jais Superhighway) and all 9 grade-separated interchanges.
  - Run `smoothness_gate` at `350 km/h` across the full motorway loop.
- **`M8` — Region 1 (`tokyo_hakone`): Neo-Tokyo Neon City, Elevated `C1` Loop, Shonan Coast & Hakone Touge (`data/maps/horizon_triland/regions/tokyo_hakone.json`)**:
  - Author the `4.0 × 3.5 km` Neo-Tokyo block grid, elevated `C1` expressway + urban ramps, Rainbow Bay Bridge, Shonan coast road, and 18-hairpin Hakone touge pass with Lake Ashi (`y = 410 m`).
  - Verify `smoothness_gate` and `fps_gate` in `tokyo_hakone`.
- **`M9` — Region 2 (`monaco_alps`): Port d'Azur Harbour Town, Seafront Tunnel, Corniche & Col de Turini Alpine Hairpins (`data/maps/horizon_triland/regions/monaco_alps.json`)**:
  - Author the terraced Port d'Azur harbour town, yacht marina waterfront chicane, Casino hairpin plaza, curved cliff tunnel, stone gorge viaducts, and 14-switchback Col de Turini pass (`y = 780 m`).
  - Verify `smoothness_gate` and `fps_gate` in `monaco_alps`.
- **`M10` — Region 3 (`dubai_jais`): Mirage Skyline Corridor, Red Dunes Oasis & Jebel Jais 3-Lane Mountain Road (`data/maps/horizon_triland/regions/dubai_jais.json`)**:
  - Author the Sheikh Zayed supertall corridor, desert marina causeway, red sand dune highway, oasis roundabout hub, and wide 3-lane Jebel Jais canyon climb (`y = 680 m`).
  - Verify `smoothness_gate` and `fps_gate` in `dubai_jais`.
- **`M11` — Landmarks & Drive-Through Petrol Stations Across All 3 Regions (`world/poi_builder.gd`, region JSONs)**:
  - Add the 6 preset-scaled drive-through petrol stations (2 per region, stitched to road shoulders with `Area3D` repair/refuel trigger) and regional hero landmarks (Red Torii, Tokyo Spire, Casino Plaza, Yacht Marina, Mirage 320 m Spire, Jebel Jais Sky Deck) with `LOD0/1/2` meshes.
- **`M12` — Preset-Scaled Spline AI Traffic & City Sidewalk Pedestrians (`world/traffic_manager.gd`, `world/pedestrian_crowd.gd`)**:
  - Implement MultiMesh spline-following AI traffic (`Low: 6`, `Med: 16`, `High: 32`) with junction turn arcs and player proximity collision boxes, plus vertex-animated MultiMesh sidewalk pedestrians (`Low: 0`, `Med: 40`, `High: 120`).
- **`M13` — Regional Weather, Wet-Road Neon Reflections & Horizon-Style World Map UI (`world/weather.gd`, `ui/map_data.gd`, `ui/full_map.gd`, `ui/minimap.gd`)**:
  - Upgrade `MapData`, `FullMap`, and `Minimap` for the `32 × 32 km` 3-region country (regional badges, motorway shield icons, petrol station & landmark icons, fast-travel to region spawns, A* GPS routing across all `~350 km`).
  - Add preset-scaled wet-road neon reflection tint in `road.gdshader` and regional weather transitions.
- **`M14` — Full-World Smoothness & Per-Region FPS Hardening (`tests/smoothness_gate.gd`, `tests/fps_gate.gd`, `docs/BUILD_REPORT.md`)**:
  - Run the complete `smoothness_gate` (all 5 cars across all 3 regions and motorways) and `fps_gate` (all 6 regional zones on Low and Medium), tune any remaining draw-call or frame-time hotspots until every region holds **40–55+ FPS (`min >= 25 FPS`)**, and document final measured numbers in `docs/BUILD_REPORT.md`.
