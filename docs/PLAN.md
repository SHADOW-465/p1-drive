# P1 Drive — Implementation Plan

Private, personal-use Godot game. Calm free-roam driving, stylized low-poly, streamed 100–500 km road world.
**Never push this repo. Never publish** (car names/designs are trademarked; "inspired" shapes, personal use only).

- Godot: `C:\Users\acer\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe` (4.7.2 stable, GDScript only). Referred to as `%GODOT%`.
- Target HW: Ryzen 3 7320U (4c/8t), Radeon 610M iGPU (512 MB shared), 8 GB RAM, 1366x768 @ 60 Hz. **Stable 60 FPS is a hard requirement.**
- Milestone A (first target): tiled streaming working, solid P1, 50–150 km road, one city hero tile, one hill-pass hero tile = tasks T01–T26.

> **Showmik, Nov 16 5:30 PM:** car detail needs much more attention; add Low/Medium/High graphics presets; add drifting; camera cycle must include an interior view; aim for high quality, realistic, GTA 5-like look on the High preset (Medium stays default). Tasks T17a–T17d in PROGRESS.md come next, before T18.

> **Quality directive (Nov 16, from Showmik; overrides §1/§7 where they conflict):** balanced, clean, good-looking visuals: moderate, not overkill and not low quality. Detailed, well-shaped P1 (panels, vents, lights, moving active wing and flaps). Pleasant scenery density, lit cities, hills, rain with wet-road look, nice skies. Mobile renderer (Forward+ only if clearly needed), Low/Medium/High presets with Medium default. No SDFGI, no heavy volumetrics, moderate shadows and draw distance. CC0/CC-BY no-login assets allowed when better, credited in CREDITS.md. Zero errors required.
> **Realism track (Showmik, Nov 16 5:44 PM; task T17e; overrides the quality directive above for the High preset ONLY):** High aims for a Forza Horizon-inspired look. High uses the **Forward+** renderer; Low and Medium stay on **Mobile** (Medium default and balanced, Low lean). Renderer change needs a restart: the settings page prompts for it, and boot applies the stored choice (user://settings.cfg -> override.cfg `rendering/renderer/rendering_method` or a relaunch with `--rendering-method`). High enables SSR (wet road, paint), SSAO + SSIL, SDFGI or VoxelGI where sensible, volumetric fog, TAA or FSR2, HDRI sky lighting (Poly Haven CC0), PBR road/terrain/rock/building materials (Poly Haven / ambientCG CC0), car paint with clearcoat + metallic flake, colour grading (ACES/AgX + adjustments), wet-road reflections in rain, LOD/visibility ranges. Every asset credited in docs/CREDITS.md. The car must match real McLaren P1 reference photos as closely as possible (T17a).
> **Owners:** `[FABLE]` tasks (T17a, T17e, T17d, T21, T22, T23, T24, T26, T32, T33, T34, T35) run on main via the Fable chain; `[OTHER]` tasks run on branch `other/lowmed` via Grok Build / AG. See PROGRESS.md.

## 1. Decisions (final unless a task proves them wrong)

| Topic | Decision | Why |
|---|---|---|
| Renderer | `gl_compatibility`, vsync on, 1366x768 | Weak iGPU; cheapest pipeline |
| Physics | `physics/3d/physics_engine="Jolt Physics"` (4.7.2 default value is `DEFAULT`; set explicitly), 60 Hz tick | Stable, fast; VehicleBody3D is engine-agnostic (raycast wheels) |
| Assets | **100% procedural, zero downloads for milestone A.** Car, roads, terrain, trees, buildings, audio all generated in GDScript | Active aero needs wing/flaps as separate nodes with exact pivots; no login/licence risk; no textures = tiny VRAM. No online model search was done this run; Kenney/Quaternius CC0 packs stay an optional later upgrade (record in CREDITS.md if ever used) |
| Car mesh | Lofted cross-sections → `ArrayMesh`, built at `_ready` by `@tool` script; node hierarchy lives in `p1.tscn` | Tweakable in code, pivots editable in editor, no binary assets |
| Textures | None. Vertex colours + procedural fragment shaders (road markings, windows, sea) | VRAM, draw calls, look |
| Engine audio | Procedural loops **baked once at startup into `AudioStreamWAV`**, then pitch/volume driven per frame | No copyrighted audio; zero per-frame synth cost; `AudioStreamGenerator` filled from GDScript risks crackle on frame hitches |
| Tail trails | One `ImmediateMesh` ribbon (2 strips, ≤100 verts), unshaded additive | Cheapest; no particles |
| Streetlights / windows | Emissive geometry × global `night_factor` uniform + fake ground glow quad. **No real lights** except sun and 1 headlight spot | Compatibility renderer light cost |
| Tile size | 1024 m, 128 cells × 8 m (full LOD) | "~1 km"; power of two |
| Threading | Workers (`WorkerThreadPool`) produce **plain data only** (Packed arrays); main thread creates Mesh/Shape resources and nodes under a 2 ms/frame budget. Hero overlay scenes via `ResourceLoader.load_threaded_request` | Rendering/physics resource creation off-thread is not reliably safe in Compatibility |
| Road heights | Stored in the graph file (computed by the generator tool, grade-limited). Terrain conforms to roads, never the reverse | Deterministic across tiles and LODs |
| Tuning data | `@export` vars on `car.gd`, values set in `p1.tscn` | Car 2 just overrides exports; no spec-resource layer |

Facts verified by a probe on this machine (4.7.2): `AudioStreamMP3.load_from_file` and `AudioStreamOggVorbis.load_from_file` exist; `Environment.fog_mode` / `fog_depth_begin/end` exist; `VehicleWheel3D` has per-wheel `engine_force`/`brake`; `VehicleBody3D` default mass is 40 (must set); 8 logical threads; **warn-level GDScript warnings are NOT printed in headless runs** (see §8).

## 2. Architecture

### 2.1 Coordinates and floating origin
- **World coords** (64-bit GDScript floats, +X east, −Z north, Y up) are the truth for graph, terrain function and tile indices. Tile `(tx, tz) = floor(world.xz / 1024)`.
- **Local coords** = world − `Origin.offset`. Scene nodes live in local coords. All generated tile geometry is **tile-local** (relative to the tile's SW corner), so in-flight worker jobs are unaffected by a shift.
- `Origin` autoload: when the car's local XZ distance from (0,0) exceeds **2048 m**, shift by a multiple of 1024 m: `offset += d`, emit `shifted(d)`. Listeners: tile roots (`position -= d`), car (in `_physics_process` via `PhysicsServer3D.body_set_state(BODY_STATE_TRANSFORM)`; velocities untouched), camera rig (snap, no smoothing that frame), trail ribbon (shift points), rain emitter. Y is never shifted.
- Helpers: `Origin.to_world(local)`, `Origin.to_local(world)`.

### 2.2 Tile streaming (`world/tile_streamer.gd`)
- Rings by Chebyshev distance `d` from the car's centre tile: `d≤1` **FULL** (9 tiles), `d=2` **MID** (16), `d=3` **FAR** (24), else unloaded. Hard cap 49 tiles.
- Centre tile switches with **96 m hysteresis** (no thrash when driving along a border).
- Per tile state machine: `WANTED → BUILDING (worker) → READY (data) → APPLYING (main, stepwise) → LIVE → FREEING`.
- Worker job: `TileGen.build(tx, tz, lod, seed) -> Dictionary` — pure static function, reads only immutable data (`RoadGraph`, `TerrainFn`, shared read-only `FastNoiseLite`). Result pushed to a `Mutex`-guarded queue with an epoch id; stale results are dropped.
- Main-thread apply: each tile is split into steps (terrain mesh, terrain collider, road mesh, road collider, props mesh, each scatter chunk, hero overlay). Per frame: run steps nearest-first until **2.0 ms** is spent (always at least one). Any step measured >2 ms gets split (e.g. road collider per 256 m piece).
- LOD swaps build the new LOD first, then swap in one frame (never a hole). Frees: max 2 tiles/frame via `queue_free`.
- Boot / respawn / teleport: car frozen behind a fade until the 3×3 FULL set is LIVE (`streamer.is_ready()`).
- Shutdown: `_exit_tree` waits for outstanding tasks (clean `--quit`).
- Debug counters exposed: `full_count`, `lod_count`, `queue_len`, `last_apply_ms`, `origin_shifts`.

| LOD | Terrain grid | Collision | Roads | Props/scatter |
|---|---|---|---|---|
| FULL | 129×129 (8 m) + skirts | HeightMapShape3D (terrain) + trimesh (road, rails) | full mesh, markings | props mesh, MultiMesh chunks, hero overlay |
| MID | 33×33 (32 m) + skirts, road-conformed with widened corridor | none | flat ribbon, same material | none (forest areas tinted darker in vertex colour) |
| FAR | 17×17 (64 m) + skirts | none | none | none |

### 2.3 Terrain (`world/terrain_fn.gd`, pure static)
- `biome_weights(wx, wz) -> PackedFloat32Array` from region blobs in `data/world_def.json` (centre, radius, falloff, biome) → normalized, smooth blends. Biomes: `hills, mountain, coast, city, countryside` ("highway" is a road type, not a biome).
- `base_height(wx, wz)` = Σ weight × biome noise (per-biome amplitude/frequency/octaves, see §6.6). Seeded by `world_def.seed`.
- `final_height` = base height conformed to roads: within **bench half-width = road half-width + 12 m** terrain = road height − 0.5 m; then smoothstep back to base over 30 m (mountain 14 m, makes cuts/embankments). Bench margin ≥ cell diagonal (11.3 m) so no terrain triangle can poke through the road. Implemented by stamping road samples into the tile's height grid (road samples within tile + 64 m margin → identical values on shared tile edges).
- Elevated edges (`elevated: true`, flyover/bridges) do not conform terrain.
- Hero overrides per tile (`world_def.hero_tiles`): `flatten_to` height (city) or `amp_scale` (pass).
- Vertex colour from biome weights, height, slope (grass/rock/sand/snowline/asphalt-grey in city). Flat-shaded look via `dFdx/dFdy` normal in `terrain.gdshader` (no CPU normals, shared vertices).
- Skirts (4 m down) on all tile edges hide LOD cracks. Sea level = 0.

### 2.4 Road graph (`autoload/road_graph.gd`, `data/roads/network.json`)
```json
{ "version": 1, "seed": 1,
  "nodes": [ {"id": 0, "p": [x, y, z], "town": false} ],
  "edges": [ {"id": 0, "a": 0, "b": 1, "type": "highway|country|mountain|city",
              "elevated": false, "pts": [[x, y, z], ...]} ] }
```
- `pts` = control points ~40 m apart (hero edges denser), world coords, centripetal Catmull-Rom between them. ~150 km ≈ 4k points ≈ 150 KB; 500 km ≈ 500 KB. Loaded once at boot, immutable afterwards (thread-safe reads).
- Spatial index built at load (ms): `tile key → [edge id, pt range]`. No separate index file.
- API: `edges_in_tile(tx, tz, margin)`, `sample(edge, t) -> {pos, tangent}`, `nearest_point(world_pos, max_dist) -> {pos, tangent, edge}`, `total_km()`.
- Sources merged by `tools/gen_network.gd`: routes from `data/world_def.json` (km-scale waypoints, densified with seeded meander, heights sampled from `base_height` then grade-limited/smoothed) + hand-authored `data/hero/*.json` edges (copied verbatim). Output committed.
- Junctions: edges share nodes; mesher draws a flat pad (radius = widest road) and fades markings near nodes. `# ponytail:` overlap pads, real intersection geometry only if it looks bad.

### 2.5 Road meshing (`world/road_mesher.gd`, worker-side)
- Polyline sampling: 6 m on straights, down to 2 m by curvature. Auto banking ≤3° (highway/country only).
- One merged road mesh per tile (UV.x across in metres, UV.y along in metres, COLOR.r = type id) → `road.gdshader` draws asphalt, edge lines, dashed/solid centre lines, wet look (`wetness` global). One merged props mesh per tile (guardrails, poles, lamp heads, flyover pillars, kerbs) with vertex colours; `COLOR.a` marks emissive bits.
- Collider: road surface + thin vertical rail strips in one `ConcavePolygonShape3D`.
- Each side gets a 1 m-drop skirt/verge strip to hide the gap to terrain.

| Type | Paved width | Lanes / markings | Rails | Lights | Max grade | Min radius |
|---|---|---|---|---|---|---|
| highway | 22 m (dual, median barrier) | 2+2, dashed lane lines, solid edges | both sides + median | near city/junction only | 5 % | 400 m |
| country | 7 m | 1+1 dashed centre | where side drop >3 m | none | 8 % | 80 m |
| mountain | 6.5 m | 1+1 solid centre | downhill side | none | 11 % | 18 m (hairpins) |
| city | 10 m + 2×2.5 m sidewalk, 0.15 m kerb | 1+1 | none | every 40 m | 6 % | junction corners |

### 2.6 Scatter, towns, hero tiles
- **Scatter** (`world/scatter.gd`): per FULL tile, 4×4 chunks of 256 m; per chunk one `MultiMeshInstance3D` per type (tree A, tree B, rock), `multimesh.buffer` set directly from worker data. Deterministic hash of (seed, tile, cell); rejected inside road bench, on slopes >35°, below sea level, in city. `visibility_range_end` 450 m (Low 300 m). ≤150 instances/chunk/type, tree ≈ 60 tris.
- **Towns** (`world/town_gen.gd`): at graph nodes flagged `town`: 15–40 box houses with prism roofs in one MultiMesh (`building.gdshader`), box colliders, a few streetlights.
- **Hero tiles**: (a) hand-authored road edges in `data/hero/<name>.json`; (b) per-tile overrides in `world_def.hero_tiles` (`flatten_to`, `amp_scale`, `no_scatter`, `overlay`); (c) optional overlay scene `world/hero/<name>.tscn` loaded with `load_threaded_request`, added as a tile child. Overlay scenes are produced by tool scripts (e.g. `tools/build_city.gd`) and then freely hand-edited in the editor.
  - **City downtown**: 5×5 block street grid (city type), flyover = elevated highway edge with pillars, towers = one MultiMesh of boxes with procedural lit windows (hash per window × `night_factor`), box colliders, streetlights.
  - **Hill pass**: authored hairpin edges (mountain type), `amp_scale` 1.4, summit lay-by viewpoint.

### 2.7 Sky, day/night, weather
- `world/day_night.gd`: `WorldEnvironment` (ProceduralSkyMaterial, depth fog, filmic tonemap) + one `DirectionalLight3D`. Time 0–24 h, default cycle 24 real minutes, start 17:00. Sky/horizon/sun/fog colours sampled from `Gradient`s. Sun shadow off and light reused as dim blue moonlight at night. Sets global shader uniform `night_factor` (smoothstep on sun elevation +4°…−6°); headlight spot auto-on when >0.5.
- Fog (depth mode): clear 400→3600 m; camera far 4000 m. FAR ring fully fogged at its outer edge.
- `world/weather.gd` (milestone B): states `clear | overcast | rain | mist`, blends over 20 s: fog range, sky darkening, `wetness` global uniform, rain = one GPUParticles3D box following the camera (Low: CPUParticles 300), `droplets.gdshader` on a full-screen ColorRect, hill mist = lower fog begin in hills biome. Random timer or menu-picked.

### 2.8 Car (see §4 tree, §6 numbers)
- `car.gd` (VehicleBody3D): inputs (`in_throttle, in_brake, in_steer, in_handbrake, in_drs`; read from `Input` when `player_controlled`, otherwise set by tests/autodrive) → engine force (rear wheels), per-wheel brakes, speed-sensitive steering, traction control, drag + downforce forces from `active_aero.gd`, reverse, respawn.
- `drivetrain.gd` (RefCounted, pure logic): gear, rpm, boost, shift cut. No nodes → trivially testable.
- `active_aero.gd`: state machine + spring-animated wing/flaps; exposes smoothed `k_drag`, `k_down`, `wing_angle_deg`, `wing_height`, `state`.
- `car_lights.gd`: brake-light emission, disc heat glow, headlights, tail trail ribbon.
- `engine_audio.gd` + `audio_bake.gd`: baked loops, per-frame pitch/volume.
- `camera/camera_rig.gd`: chase (spring follow, speed FOV, noise shake) and hood cam; toggle.

## 3. Files and responsibilities

```
project.godot            renderer, physics, input map, autoloads, warnings, shader globals
play.bat                 launches game (passes extra args, e.g. --fps-log)
main.tscn / main.gd      composes world + car + camera + UI; boot/respawn flow; parses user args
autoload/settings.gd     user://settings.cfg (ConfigFile): quality, volumes, music_dir, fps_visible
autoload/origin.gd       floating origin offset + shifted signal
autoload/road_graph.gd   loads network.json, spatial index, sampling, nearest_point
autoload/radio.gd        scans music dir, threaded file load, next/prev/toggle, graceful when empty
autoload/fps_log.gd      --fps-log: prints FPS + frame-time max every second
cars/car.gd              vehicle controller (see 2.8)
cars/drivetrain.gd       gears/rpm/boost
cars/active_aero.gd      aero states, animation, coefficients
cars/car_lights.gd       brake lights, disc glow, headlights, trails
cars/engine_audio.gd     drives audio players from drivetrain
cars/audio_bake.gd       static funcs: synthesize AudioStreamWAV loops
cars/p1/p1.tscn          P1 node hierarchy + tuned exports
cars/p1/p1_mesh.gd       @tool static mesh builders (body, cockpit, wing, flaps, wheel, lights)
camera/camera_rig.gd     chase + hood cameras
world/tile_streamer.gd   ring logic, job queue, budgeted apply/free
world/tile_gen.gd        worker-side pure builders → tile data dictionary
world/tile_node.gd       main-thread apply steps (data → meshes/shapes/nodes)
world/terrain_fn.gd      biome weights, base height, colours (pure static)
world/road_mesher.gd     cross-sections, road/props/collider arrays, terrain stamping data
world/scatter.gd         deterministic MultiMesh buffers
world/town_gen.gd        small procedural towns
world/day_night.gd       sky, sun, fog, night_factor
world/weather.gd         weather states (milestone B)
world/hero/*.tscn        hero overlay scenes (generated then hand-editable)
shaders/terrain|road|props|building|sea|droplets.gdshader
ui/hud.tscn+hud.gd       speed, gear, rpm bar, aero state, radio track, FPS
ui/pause_menu.tscn+.gd   resume, quality preset, weather/time pick, volumes, quit
ui/minimap.gd            optional: nearby graph polylines via _draw at 5 Hz
data/world_def.json      seed, biome blobs, routes, towns, hero_tiles
data/roads/network.json  generated master graph (committed)
data/hero/*.json         hand-authored hero road edges (city, pass, later coast)
tools/run_gates.bat      all gates, pass/fail report
tools/check_scripts.gd   loads every .gd/.tscn/.gdshader under res:// (compile check)
tools/gen_network.gd     builds network.json from world_def + hero edges; prints km + validation
tools/build_city.gd      builds world/hero/city_downtown.tscn
tests/smoke_test.tscn+.gd, tests/streaming_test.tscn+.gd, tests/test_track.tscn
docs/PLAN.md, PROGRESS.md, CREDITS.md
```

## 4. Scene trees

```
Main (Node3D, main.gd)
├─ Sky (Node, day_night.gd) ── WorldEnvironment, Sun (DirectionalLight3D)
├─ World (Node3D, tile_streamer.gd) ── Tiles (Node3D) ── Tile_<tx>_<tz> (Node3D, tile_node.gd) ...
│     └─ Sea (MeshInstance3D, follows camera; milestone C)
├─ P1 (cars/p1/p1.tscn)
├─ CameraRig (Node3D, camera_rig.gd) ── Camera3D
├─ Weather (Node3D, weather.gd) ── Rain (particles)            [milestone B]
└─ UI (CanvasLayer) ── ScreenFX (ColorRect droplets), HUD, Minimap (opt), PauseMenu, Fade
Autoloads: Settings, Origin, RoadGraph, Radio, FpsLog

Tile_<tx>_<tz>: Terrain (MeshInstance3D), Body (StaticBody3D: TerrainShape, RoadShape[s]),
                Road (MeshInstance3D), Props (MeshInstance3D), Scatter (Node3D: MMI per chunk/type),
                Overlay (hero scene, optional)

P1 (VehicleBody3D, car.gd; faces −Z; continuous_cd on)
├─ CollisionShape3D (box 1.90 × 0.62 × 4.40, centre y 0.52)
├─ Body (MeshInstance3D, papaya paint)   ├─ Cockpit (MeshInstance3D, dark glass)
├─ Aero (Node3D, active_aero.gd)
│   ├─ WingPivot (Node3D) ── Wing (MeshInstance3D), StrutL, StrutR
│   └─ FlapL, FlapR (Node3D pivots ── MeshInstance3D)
├─ WheelFL / WheelFR / WheelRL / WheelRR (VehicleWheel3D) ── Rim (mesh), Disc (emissive mesh)
├─ Lights (Node3D, car_lights.gd) ── TailStrip, BrakeStrip, HeadL, HeadR (emissive meshes),
│     HeadSpot (SpotLight3D, no shadow), Trail (MeshInstance3D/ImmediateMesh, top_level)
├─ Audio (Node, engine_audio.gd) ── EngineLow, EngineHigh, Whistle, BlowOff, Wind (AudioStreamPlayer)
├─ ChaseTarget, HoodCam (Marker3D)
└─ Companion (Node3D, hidden stub)
```

## 5. Input map (InputMap actions; keyboard + gamepad, mouse for menus)

| Action | Keys | Gamepad |
|---|---|---|
| `throttle` | W, Up | RT (axis 5) |
| `brake` (reverse when stopped) | S, Down | LT (axis 4) |
| `steer_left` / `steer_right` | A, Left / D, Right | Left stick X (deadzone 0.15) |
| `handbrake` | Space | A (0) |
| `drs` (hold) | Shift | RB (10) |
| `camera_toggle` | C | Y (3) |
| `respawn` | R | Back (4) |
| `radio_next` / `radio_prev` / `radio_toggle` | N / B / M | D-pad right (14) / left (13) / up (11) |
| `time_skip` (+1 h) | T | D-pad down (12) |
| `fps_toggle` | F3 | — |
| `pause` | Esc | Start (6) |
| `companion_toggle` (stub) | P | — |

## 6. Tuning numbers (starting values; T03/T05 tune against the measurable targets)

Engine API semantics (from engine source; **T03 must confirm by measurement**): `engine_force` is Newtons **per traction wheel**; `brake` is a max impulse **per wheel per physics tick** → always compute `brake = force_N / Engine.physics_ticks_per_second`; a wheel with non-zero engine force ignores its brake; suspension force = `mass × (stiffness × compression − damping × velocity)`. **Measured in T03:** positive `engine_force` drives toward **+Z**, so the −Z-facing car applies it negated; positive `steering` turns left; side forces act at body-origin height (roll influence is ineffective with the origin at ground level), so lateral grip must stay well below the 2.67 g rollover threshold; the project default `linear_damp` 0.1 must be replaced with 0 on the car (it capped top speed at 200 km/h); Jolt's `WorldBoundaryShape3D` is finite (`world_boundary_shape_size` raised to 40 km).

### 6.1 Chassis and wheels
| Param | Value | Param | Value |
|---|---|---|---|
| mass | 1450 kg | body L×W×H | 4.59 × 1.95 × 1.19 m |
| centre of mass (custom) | y 0.30 m above ground, 45/55 F/R | wheelbase / track | 2.67 m / 1.66 F, 1.60 R |
| wheel radius F/R | 0.34 / 0.36 m | wheel_rest_length | 0.12 m |
| suspension_stiffness | 65 (static sag ≈ 3.8 cm, ≈ 7.5 cm at max downforce) | suspension_travel | 0.10 m |
| damping_compression / relaxation | 3.5 / 5.5 | suspension_max_force | 30000 N |
| wheel_friction_slip F/R | 1.35 / 1.6 (rear grippier = stable; 2.4/2.8 rolled the car) | wheel_roll_influence | 0.03 |
| angular_damp | 0.3 | traction | RWD (rear `use_as_traction`) |

### 6.2 Drivetrain
- Force model: `F_total = throttle × min(13 900 N, 560 000 W / v) × shift_cut`, split over 2 rear wheels (6 950 N each max). Soft limiter fades force 345→350 km/h. Reverse: 40 % force, 40 km/h cap.
- Traction control: if a rear wheel's `get_skidinfo() < 0.6`, scale force ×0.6 (smoothed).
- Gears (auto, 7): top speed per gear at 8250 rpm = `[78, 124, 170, 220, 270, 315, 360]` km/h; `rpm = max(900, 8250 × v / v_top[gear])`; upshift at 8000 rpm, downshift below 4200 rpm; shift = 0.12 s with force ×0.3. Idle 900, redline 8250.
- Boost (0..1): target `throttle × clamp((rpm − 2500)/3000, 0, 1)`; spool τ 0.35 s up, 0.15 s down. Blow-off when throttle drops with boost >0.6.
- Brakes: 18.5 kN total at full pedal, 60/40 → 5 550 N per front wheel, 3 700 N per rear (÷ tick rate). Handbrake: rear 6 000 N. Engine braking: 0.08 g off-throttle.
- Steering: max angle 32° at 0 km/h → 14° at 100 → 6° at 300 (curve); input smoothing 6 /s toward target, 9 /s return.
- **Targets**: 0–100 km/h 2.8–3.3 s; 0–200 ≤ 7.5 s; top speed 325–335 (normal), 345–352 (DRS); 100–0 ≤ 35 m; 300–0 ≤ 7 s with airbrake; no spin from full throttle + full lock at 100 km/h; no bottoming or bounce at 300 km/h.

### 6.3 Aero (forces: `drag = k_drag × v²` opposing velocity; `down = min(k_down × v², 14 000 N)`, 40 % applied at z −1.3 (front), 60 % at z +1.3 (rear); v in m/s)
| State | Enter when | Wing height | Wing angle | Flaps | k_drag | k_down |
|---|---|---|---|---|---|---|
| LOW | v < 80 km/h | 0.00 m | 2° | 0° | 0.60 | 0.60 |
| HIGH | v ≥ 100 km/h (drops to LOW < 80) | 0.22 m | 14° | 10° | 0.72 | 1.50 |
| DRS | HIGH + `drs` held + brake = 0 | 0.22 m | 0° | 0° | 0.48 | 0.70 |
| AIRBRAKE | brake > 0.6 and v > 110 km/h; held until brake released for 0.4 s or v < 50 km/h | 0.30 m | 58° | 24° | 1.90 | 1.90 |
- Animation: critically damped spring per channel; ω = 16 rad/s into AIRBRAKE (snappy rise), 9 for HIGH/DRS, 5 when settling out of AIRBRAKE (slow, smooth).
- `k_drag`/`k_down` follow the **animated pose** (same spring), so physics changes as the wing moves, not when the state flips.

### 6.4 Lights, heat, trails
- Brake strip emission energy 0.4 (tail, night only) → 4.0 on brake. Reverse: white strip.
- Disc heat `h` (0..1): `h += brake × (v/90) × 0.9 × dt`; `h −= h × 0.35 × dt`. Disc emission = orange-red × `h² × 5`.
- Trails: enabled when `night_factor > 0.4` and v > 60 km/h; 24 points per side, 0.035 s spacing, width 0.05 m, alpha fades along length.

### 6.5 Camera and audio
- Chase: 5.6 m behind, 1.7 m up, look-at +1.0 m; position spring ω 8, yaw follow ω 6. FOV 65° → 88° (smoothstep 60→330 km/h). Shake from 220 km/h, max 0.035 m / 0.25° at 350 (FastNoiseLite, ~22 Hz). Hood: (0, 0.95, −0.55), FOV 70° → 82°. Near 0.15 (hood 0.05), far 4000.
- Audio (22 050 Hz mono, 1 s loops, integer cycle counts): EngineLow baked at 2000 rpm (V8 firing 133 Hz + 0.5/1/1.5/2/3/4 orders), EngineHigh at 6000 rpm (brighter weights); `pitch_scale = rpm / baked_rpm`, crossfade 3000–5500 rpm, +4 dB on throttle. Whistle loop (3.2 kHz sine + band noise): pitch 0.7 + 0.6 × boost, volume ∝ boost². BlowOff: 0.35 s decaying noise one-shot. Wind: noise loop, volume ∝ v². Buses: Master → SFX, Music.

### 6.6 World
| Biome | Amplitude | Base wavelength | Octaves | Notes |
|---|---|---|---|---|
| countryside | 25 m | 900 m | 3 | grass, tree density 0.4 |
| hills | 110 m | 1400 m | 4 | tree density 0.8 |
| mountain | 380 m | 2600 m | 5 (ridged) | rock above slope 30°, snow tint > 320 m, sparse trees |
| coast | 30 m, sloping to −15 m | 1000 m | 3 | sand < 3 m, sea at 0 |
| city | flat (hero `flatten_to`) | — | — | no scatter |
- World A: 20 × 20 km (tiles −10…9). Mountains north, hills centre-north, countryside centre/east, city south-east, coast + sea along the south edge. Expand to 32 × 32 km for 500 km.
- Milestone-A route budget (≈148 km): highway ring 58, N–S country 22, E–W country 24, mountain road 16 (incl. 3 km hero pass), country loops 20, city streets 8. Coast road (+20) and more country (+330) later.
- Origin shift threshold 2048 m; centre-tile hysteresis 96 m; apply budget 2.0 ms/frame.

## 7. Performance budget (1366x768, Radeon 610M, 60 FPS = 16.6 ms)

| Item | Budget |
|---|---|
| Draw calls in view | ≤ 200 (typ. ~125: 9×3 tile meshes, ≤40 LOD tiles, ~30 scatter chunks, car ~25, sky/sea/UI) |
| Triangles in view | ≤ 350k Med / ≤ 220k Low |
| Lights | 1 directional (shadowed by day) + 1 spot (headlights, night, no shadow) |
| Main-thread CPU / frame | ≤ 6 ms: physics ≤ 1, scripts ≤ 1.5, streaming apply ≤ 2, rest ≤ 1.5 |
| Worker time per FULL tile | ≤ 250 ms (needed ≥ 10 s before arrival at 350 km/h) |
| Process RAM | ≤ 1.2 GB (expected ~400–600 MB); ≈ 1 MB per FULL tile |
| VRAM | ≤ 200 MB (no textures) |
| Forbidden | SDFGI, SSR, SSAO, SSIL, volumetric fog, real-time GI, omni lights for street lamps, transparent overdraw stacks |

| Preset | MSAA | Shadows | Glow | Scatter density / range | 3D scale | Rain particles |
|---|---|---|---|---|---|---|
| Low (default) | off | 1024 atlas, 40 m, orthogonal | off | 0.5 / 300 m | 0.85 bilinear (1.0 if unsupported in Compatibility) | 300 |
| Med | 2x | 2048 atlas, 70 m, PSSM 2 | on | 1.0 / 450 m | 1.0 | 600 |

Real-HW check (manual, after T24 and after every later milestone): `play.bat --fps-log --autodrive` for 5 min → min logged FPS ≥ 57, no frame > 25 ms after boot.

## 8. Quality gates (`tools/run_gates.bat`, logs in `logs/`, git-ignored)

1. **Import + compile + boot**: `%GODOT% --headless --path . --import`; `%GODOT% --headless --path . -s res://tools/check_scripts.gd` (loads every script/scene/shader so everything compiles, not just the main scene); `%GODOT% --headless --path . --quit`. Fail on non-zero exit or any of `ERROR`, `SCRIPT ERROR`, `Parse Error`, `WARNING` in the logs.
   - GDScript warning levels in `project.godot` (0 ignore / 1 warn / 2 error). Because warn-level output is invisible headless (probe-verified), anything we care about is level 2 so it fails compilation: `untyped_declaration=2`, `unused_variable=2`, `unused_local_constant=2`, `shadowed_variable=2`, `shadowed_variable_base_class=1`, `unused_parameter=0` (prefix with `_` by convention), `unused_signal=1`, `inferred_declaration=0` (`:=` allowed), `integer_division=0`. This deviates from "untyped as warnings" deliberately: as warnings the gate could never see them.
2. **Smoke test**: `%GODOT% --headless --path . --fixed-fps 60 res://tests/smoke_test.tscn`. Infinite ground plane + P1 (`player_controlled=false`). Phases, each with a frame limit (timeout = fail):
   1. settle 60 f → all wheels in contact, speed < 0.5 m/s, wing ≈ 2°;
   2. full throttle until 200 km/h (≤ 900 f) → state HIGH, wing 14° ± 2, height > 0.15;
   3. DRS 90 f → state DRS, wing < 3°, `k_drag` lower than in phase 2;
   4. release DRS, full brake → within 45 f state AIRBRAKE, wing > 45°; speed falling; brake emission > tail level; disc heat > 0;
   5. brake to < 5 km/h (≤ 600 f); release; after 180 f wing < 5°;
   6. always: no NaN, car upright (`basis.y·UP > 0.9`). Prints `SMOKE PASS`/`SMOKE FAIL: <reason>`, `quit(0|1)`.
3. **FPS logger**: `FpsLog` autoload, active with `--fps-log` (user arg after `--` or plain); prints `FPS <n> max_ms <x> tiles <full>/<lod>` every second.
4. **Streaming test**: `%GODOT% --headless --path . --fixed-fps 60 res://tests/streaming_test.tscn`. Moves the frozen car along a route (highway polyline once the network exists; straight line before) at 150 m/s equivalent, out across ≥ 24 distinct tiles and back. Asserts:
   - every visited tile reached FULL before the car was > 300 m inside it (otherwise the test pauses movement and counts a "stall"; stalls after warm-up = fail);
   - `full_count ≤ 9` and `full + lod ≤ 49` on every frame; tiles behind are freed (count of live tile nodes bounded);
   - ≥ 2 origin shifts happened; across each shift `Origin.to_world(car)` changes by < 0.01 m beyond the expected step; car local |xz| never > 3100 m;
   - memory bounded: `Performance.MEMORY_STATIC` and `OBJECT_NODE_COUNT` at the end of the return trip ≤ 1.15 × their value at the same place on the way out; `OBJECT_ORPHAN_NODE_COUNT == 0`;
   - main-thread frame work time (measured with `Time.get_ticks_usec`, not rendered FPS): logs avg / p99 / max; fail if p99 > 8 ms or max > 25 ms after warm-up. (Headless has no GPU, so this guards CPU hitches only; GPU side is the manual `--fps-log` run.)
   - prints `STREAM PASS`/`STREAM FAIL: <reason>`, `quit(0|1)`.
5. `tools/run_gates.bat` runs 1, 2, 4 in order, prints one PASS/FAIL line per gate, exits non-zero on any failure. `play.bat` in repo root: `"%GODOT%" --path "%~dp0." -- %*` (the trailing `.` stops `\"` from escaping the quote).

## 9. Acceptance criteria per feature

| Feature | Accepted when |
|---|---|
| P1 handling | §6.2 targets met (bench printout); drives a full lap of the test track at 250+ km/h without spin or bounce |
| Active aero | Smoke test passes; visible smooth wing/flap motion; coasting from 300 km/h slows clearly faster in AIRBRAKE than LOW; DRS raises top speed |
| Lights | Brake strip brightens on brake; discs glow after a 300→0 stop and fade in ~10 s; trails only at night above 60 km/h |
| Audio | Pitch tracks rpm through all gears, audible shift dip, whistle rises with boost, blow-off on lift; no crackle; silent-safe headless |
| Camera | FOV widens with speed, shake only above 220 km/h, `C` toggles chase/hood without a pop |
| Streaming | Streaming test passes; driving 10 min at top speed shows no hole, no visible pop inside 400 m, no hitch > 25 ms |
| Floating origin | Shift invisible to the player (no camera jump, no audio click, velocity kept); wheels stay planted |
| Road graph | `gen_network.gd` reports ≥ 100 km (target 148), all edges within grade/radius limits, graph connected |
| Roads | Car never falls through or snags at tile borders or junction pads; markings continuous across tiles; rails stop the car |
| Terrain | No terrain poking through road; no cracks visible between tiles/LODs; same seed → identical world |
| Scatter | No tree/rock on a road bench; identical on reload; density preset works |
| Hero tiles | City: grid drivable, flyover drivable above streets, windows lit at night, tower collisions. Pass: ≥ 6 hairpins drivable both ways, viewpoint lay-by |
| Day/night | Full cycle without popping; night readable with headlights; `T` skips an hour |
| Weather (B) | Rain: wet road sheen, droplets, darker sky, denser fog, particles near camera; still 60 FPS on Low |
| HUD | Speed, gear, rpm bar, aero state, radio track, FPS (F3) all live |
| Radio | Plays .mp3/.ogg from the music dir; next/prev/toggle; empty or missing folder → "No music" and no errors; no hitch when a track loads |
| Pause/settings | Esc pauses; preset switch applies live and persists in `user://settings.cfg`; gamepad navigable |
| Respawn | `R` puts the car on the nearest road, aligned, at rest, from anywhere (including under the map) |
| Gates | `tools/run_gates.bat` exits 0 |

## 10. Tasks (ordered; one task ≈ one commit)

Rules for every task: commit as `Txx: <summary>`; `tools\run_gates.bat` must exit 0 before the commit (from T01 on, with whatever gates exist by then); tick the box in `docs/PROGRESS.md` in the same commit; never push; all GDScript fully typed; never print the words `ERROR`/`WARNING` from our own code (gates grep for them); any third-party file needs a `docs/CREDITS.md` entry first.

### Phase 1 — setup and car (playable at T04)

**T01 Project skeleton + gate 1.** `project.godot` (gl_compatibility, 1366x768, vsync, Jolt, 60 Hz, warning levels from §8, input map from §5, buses SFX/Music, shader globals `night_factor`, `wetness`), folders from §3, `.gitignore` (`.godot/`, `logs/`), `autoload/fps_log.gd`, empty `main.tscn`, `tools/check_scripts.gd`, `tools/run_gates.bat` (gate 1), `play.bat`.
Done: gates exit 0; a deliberately planted `var x = 1` makes gate 1 fail (then removed); `play.bat --fps-log` opens a window and prints FPS lines.

**T02 Test track + static sky.** `tests/test_track.tscn`: 3 km straight + wide oval as flat meshes on a `WorldBoundaryShape3D` ground, simple markings; `WorldEnvironment` with ProceduralSkyMaterial, warm sun (one shadowed directional, 70 m), depth fog.
Done: scene opens from `main.tscn`; looks like a late-afternoon sky; gates pass.

**T03 P1 physics core.** `cars/p1/p1.tscn` with placeholder boxes, 4 wheels, `car.gd` + `drivetrain.gd` using §6.1–6.2 (constant LOW aero for now). Confirm the API semantics noted in §6 by measurement and fix the notes in this file if wrong.
Done: with a temporary bench script: 0–100, 0–200, top speed, 100–0 within §6.2 targets; no bounce at rest; numbers pasted into the commit message.

**T04 Camera + playable loop.** `camera/camera_rig.gd` (chase with speed FOV + shake, hood cam, toggle), `main.gd` wiring player input, respawn to start (`R`), debug label (speed/gear/rpm).
Done: `play.bat` → drive the test track with keyboard and gamepad; camera toggle works; 60 FPS on target HW with `--fps-log`.

**T05 Active aero.** `active_aero.gd` per §6.3 with placeholder wing/flap boxes on pivots; forces applied from animated coefficients; state shown in debug label.
Done: wing rises at 100 km/h, flattens on DRS, airbrakes on hard braking and settles slowly; top speed higher with DRS than without.

**T06 Smoke test + gate 2.** `tests/smoke_test.tscn/.gd` per §8.2; also prints (not asserts) the §6.2 bench numbers; added to `run_gates.bat`.
Done: gate 2 passes; breaking the airbrake rule on purpose makes it fail (then restored).

**T07 P1 procedural mesh.** `p1_mesh.gd` (`@tool`): body loft (~9 cross-sections, low nose, teardrop cabin, side intakes, open rear deck), cockpit glass, wing with endplates + struts, front flaps, wheels (16-seg tyre, rim, disc, caliper), light strips. Papaya orange paint (`#FF8000`, metallic 0.6, roughness 0.3), black lower body/diffuser. Target ≤ 6k tris, ≤ 25 draw calls.
Done: recognisably P1-inspired from chase cam; wing/flaps animate on correct pivots without clipping; collider matches body; smoke test still passes.

**T08 Lights, disc glow, trails.** `car_lights.gd` per §6.4; headlight spot stub (manual toggle until T21).
Done: acceptance row "Lights"; smoke test asserts brake emission and disc heat.

**T09 Engine audio.** `audio_bake.gd` + `engine_audio.gd` per §6.5.
Done: acceptance row "Audio"; bake < 150 ms at startup; headless runs clean.

**T10 Handling polish.** Tune §6 numbers on the test track (steering curve, grip balance, damping, traction control, camera feel). Update §6 with final values.
Done: acceptance row "P1 handling"; smoke test passes.

### Phase 2 — streaming world

**T11 Origin + terrain function.** `autoload/origin.gd` (no listeners yet), `data/world_def.json` (seed, biome blobs for the 20 km world), `world/terrain_fn.gd` with a `self_check()` run by `check_scripts.gd`: deterministic, continuous across tile borders, mountain/sea ranges sane.
Done: self-check passes in gate 1.

**T12 One tile end to end (synchronous).** `tile_gen.gd` FULL terrain data (heights, colours, indices, skirts), `tile_node.gd` apply steps, `terrain.gdshader`, HeightMapShape3D collider (scaled 8×; verify under Jolt, else fallback R1). Static 3×3 block in a dev scene.
Done: car drives over generated hills; resting height matches the visual surface within 5 cm; no cracks between the 9 tiles; build time per tile logged.

**T13 Streamer.** `tile_streamer.gd`: rings, hysteresis, WorkerThreadPool jobs, epoch/stale drop, budgeted apply, MID/FAR LODs, LOD swap, frees, counters, clean shutdown.
Done: driving in a straight line for 10 km keeps `full ≤ 9`, `total ≤ 49`; `FpsLog` shows no frame > 25 ms; worker time per FULL tile ≤ 250 ms.

**T14 Floating origin.** Wire `Origin.shifted` to tiles, car, camera, trail; shift at 2048 m.
Done: acceptance row "Floating origin"; world position continuous across shifts (logged).

**T15 Streaming test + gate.** `tests/streaming_test.tscn/.gd` per §8.4 (straight-line route for now); added to `run_gates.bat`.
Done: gate passes; disabling tile frees on purpose makes it fail (then restored).

**T16 Road graph.** `autoload/road_graph.gd` (format §2.4, index, sampling, `nearest_point`), hand-written dev network `data/roads/network.json` (~8 km loop over ≥ 6 tiles, all four road types, one junction) with `self_check()`.
Done: self-check passes (sample continuity, index completeness, `total_km`).

**T17 Road surface.** `road_mesher.gd`: sampling, four cross-sections, banking, verge skirts, `road.gdshader` markings, road collider, terrain conform stamping (FULL + widened MID), junction pads.
Done: acceptance rows "Roads" and "Terrain" on the dev loop at 300 km/h, including tile borders.

**T18 Road props.** Guardrails (with collision strips), streetlight poles + emissive heads + glow quads, kerbs/sidewalks, MID ribbons; `props.gdshader` using `night_factor`.
Done: rails stop the car; one props mesh per tile; draw calls within §7.

**T19 Streamed world becomes the game.** `main.tscn` uses World instead of the test track; spawn on graph; `respawn` via `nearest_point`; boot fade until `is_ready()`; `--autodrive` (follow the road graph, speed limited by curvature); streaming test now follows the dev loop.
Done: acceptance row "Respawn"; `play.bat --fps-log --autodrive` laps the dev loop unattended.

**T20 Scatter.** `scatter.gd` per §2.6 with tree A/B and rock meshes (procedural, vertex-coloured).
Done: acceptance row "Scatter"; triangles and draw calls within §7 in the densest hills.

**T21 Day/night.** `day_night.gd` per §2.7; `time_skip`; auto headlights; streetlight/trail night behaviour.
Done: acceptance row "Day/night"; 60 FPS at night with headlight spot.

### Phase 3 — hero tiles

**T22 Hero mechanism + hill pass.** `hero_tiles` overrides in tile gen, threaded overlay loading; `data/hero/pass.json` (≥ 6 hairpins, ~3 km, 250 m climb), summit lay-by overlay.
Done: acceptance row "Hero tiles" (pass part); streaming test still passes through the pass tile.

**T23 City roads + flyover.** `data/hero/city.json`: 5×5 block grid, elevated highway edge crossing the tile; elevated cross-section (deck, barriers, pillars, no terrain conform); city tile `flatten_to`.
Done: every street and the flyover drivable; ramps join the dev highway.

**T24 City overlay.** `tools/build_city.gd` → `world/hero/city_downtown.tscn` (tower MultiMesh, `building.gdshader` lit windows, box colliders, a few low blocks/parks for variety).
Done: acceptance row "Hero tiles" (city part); city tile ≤ 40 draw calls, 60 FPS on target HW.

### Phase 4 — the network (milestone A lands here)

**T25 Network generator.** `tools/gen_network.gd` + routes/towns in `world_def.json` per §6.6; validation (grade, radius, connectivity, self-intersections become junction nodes); writes `network.json`; prints km per type.
Done: acceptance row "Road graph" (≥ 100 km, target ~148 km); hero edges intact.

**T26 Milestone A hardening.** Streaming test follows the highway ring (≥ 24 tiles, ≥ 2 origin shifts); `--autodrive` 5-minute run on target HW; fix every budget overrun (§7); update §6/§7 with measured numbers.
Done: all gates pass; real-HW check from §7 met; **Milestone A complete**.

**T27 Procedural towns.** `town_gen.gd` at `town` nodes.
Done: 3+ towns visible on the network; no building on a road bench; budgets hold.

### Phase 5 — HUD, menus, radio

**T28 HUD.** `ui/hud.tscn` (speed, gear, rpm bar with redline, aero state, radio track, FPS via `fps_toggle`); remove debug label.
Done: acceptance row "HUD"; HUD costs ≤ 5 draw calls.

**T29 Settings + pause menu.** `autoload/settings.gd`, `ui/pause_menu.tscn` (resume, Low/Med preset applied live, volumes, time-of-day pick, quit); keyboard, mouse and gamepad navigation.
Done: acceptance row "Pause/settings"; verify 3D scale works in Compatibility, else pin to 1.0.

**T30 Radio.** `autoload/radio.gd`: music dir from settings (default `%USERPROFILE%\Music\P1Drive`), scan `.mp3/.ogg`, load bytes on a worker then `load_from_file`/`data`, auto-advance, keys, HUD text.
Done: acceptance row "Radio"; gates pass with a missing folder.

**T31 Minimap (optional).** `ui/minimap.gd`.
Done: shows nearby roads + car heading; ≤ 0.3 ms per redraw. Skip if time is short.

### Phase 6 — weather (milestone B)

**T32 Weather core.** `weather.gd` states + blends: fog, sky darkening, `wetness` in `road.gdshader`; pause-menu pick + random mode.
Done: switching states is smooth; wet sheen visible; budgets hold.

**T33 Rain FX + mist.** Camera-following rain particles, `droplets.gdshader` screen effect, hill mist.
Done: acceptance row "Weather"; 60 FPS on Low in rain at night in the city.

### Phase 7 — coast, viewpoints, more km (milestone C)

**T34 Sea + coast biome.** `sea.gdshader` on a camera-following plane; beach/cliff colouring; coast noise.
Done: shoreline looks clean from the road; sea costs 1 draw call.

**T35 Coast hero tile.** `data/hero/coast.json` cliff road + overlay (rock stacks, lighthouse silhouette).
Done: drivable both ways; rails on the sea side; streaming test passes through it.

**T36 Viewpoints.** Lay-by generator for marked graph points (parking pad, sign, bench); 4+ viewpoints incl. pass and coast.
Done: each reachable and drivable; shown on minimap if T31 exists.

**T37 Expand the network.** World 32×32 km; routes to ~300 km, then ~500 km; re-run T26 checks.
Done: `gen_network.gd` reports ≥ 450 km; all gates and the real-HW check pass; boot time ≤ 5 s.

### Phase 8–9 — low priority

**T38 Companion stub.** `companion_toggle` shows/hides a simple seated figure node; setting persisted.
Done: toggles without affecting physics.

**T39 Car 2 (Gemera-inspired).** New scene reusing `car.gd` with its own exports (4 seats, AWD, heavier, softer), own mesh builder, simpler aero (no airbrake).
Done: passes a variant of the smoke test minus aero asserts.

**T40 Car select.** Pause-menu car switch (respawn in place).
Done: switch works mid-session; setting persisted.

**T41 Final polish.** Tuning pass, README-level notes in this file, CREDITS.md final.
Done: all gates pass; real-HW check passes in every weather on Low.

## 11. Risks and fallbacks

| # | Risk | Checked in | Fallback |
|---|---|---|---|
| R1 | HeightMapShape3D with 8× XZ node scale misbehaves under Jolt | T12 | Terrain trimesh in 16 strips, one strip per frame; or GodotPhysics3D |
| R2 | GDScript tile generation too slow (> 250 ms/tile) | T13 | Fewer octaves; 97×97 grid; stamp roads at half resolution |
| R3 | `engine_force`/`brake` semantics differ from §6 notes | T03 | Re-derive from measurements; targets in §6.2 are the contract, not the raw numbers |
| R4 | 610M fill rate / shader cost misses 60 FPS | T04, T26 | Low preset: 0.85 scale, no MSAA/glow, shorter shadows, then shadows off |
| R5 | `visibility_range` or 3D scaling unsupported in Compatibility | T20, T29 | Manual per-chunk distance toggle at 4 Hz; fixed scale 1.0 |
| R6 | Main-thread Mesh/Shape creation spikes > 2 ms | T13, T17 | Split steps smaller (road collider per 256 m, scatter per chunk) |
| R7 | Junction pads look bad | T17, T23 | Proper intersection meshes for city grid only |
| R8 | Headless tests cannot see GPU cost | T26 | Manual `--fps-log --autodrive` run is part of each milestone's done-criteria |
| R9 | Procedural car looks too crude | T07 | More cross-sections first; a verified CC0 model only as a last resort (must allow separate wing) |

Milestones: **A** = T01–T26, **B** = T27–T33, **C** = T34–T37, extras = T38–T41.
