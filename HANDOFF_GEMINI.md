# HANDOFF: P1 Drive (Godot) → Gemini 4 Neon in Antigravity

Snapshot written 2026-11-21 from the repo and prior job logs. Anything not verified from a file is labelled **UNVERIFIED**.

## How to use this handoff

- Audience: Gemini 4 Neon in Antigravity (new orchestrator), continuing paused work from Claude (Opus/Sonnet) sessions that hit usage limits.
- Repo: `C:\Users\acer\Documents\GitHub\p1-drive-other` (git worktree). Branch `other/lowmed`. Tip `6d89693` (M4); `c946042` is M6. Both local only.
- There is **uncommitted M4b WIP** in the working tree. Preserve it. No stash / reset / clean / checkout of those files.
- Owner: Showmik (git user SHADOW-465). Origin `https://github.com/SHADOW-465/p1-drive` is **PUBLIC**. Never push.
- Do M4b first (section "Ordered pending work"). No new scope until M4b is committed locally.
- Source of truth for the plan: `docs/MAP_PLAN.md` (M0–M14), `docs/PLAN.md` (original spec + gate definitions), `.agent_prompt.md` (long owner task list, partly stale), `docs/PROGRESS.md`, `docs/BUILD_REPORT.md`, `docs/REGION_SCHEMA.md`, `docs/ROADS_PLAN.md`. No README / AGENTS.md exists.

## Project overview

- Calm, scenery-first open-world driving game (GTA5 / Forza Horizon look goal). Godot **4.7.2 stable**, GDScript only, Mobile renderer, 1366x768, target hardware Radeon/GeForce 610M-class iGPU laptop.
- World: "Horizon Triland" country stitched from real OSM roads + SRTM elevation: regions `tokyo_hakone`, `monaco_alps`, `dubai_jais`. Baked offline by `tools\bake_world.py` into `data\world\baked\`. Default world; `--world=old` selects the old procedural map.
- Cars (registry `cars\car_registry.gd`, data `data\cars.json`): McLaren P1 (vecarz model), McLaren 600LT, Koenigsegg Gemera, Bentley EXP 10 Speed 6. Models live in git-ignored `assets_nc\`; P1 falls back to code-built mesh if missing.

### Godot binaries (all verified present in `C:\Users\acer\Tools\Godot\`)

| Binary | Used by |
|---|---|
| `Godot_v4.7.2-stable_win64_console.exe` | `play.bat`, `tools\run_gates.bat`, `tools\t.sh`, `tools\view.sh`, docs |
| `Godot_v4.7.2-stable_win64.exe` (windowed, no console) | `tools\run_fps_gate.bat` only (needs a real window/GPU) |

### Run the game

```bat
cd /d C:\Users\acer\Documents\GitHub\p1-drive-other
play.bat
play.bat --preset=low
```

`play.bat` = `Godot_..._console.exe --path "<repo>" -- %*`. Always run with the repo root as `--path`; gate scripts `cd` to the repo root themselves.

### Quality presets
- Low / Medium / High defined in `autoload\settings.gd` (`PRESETS`, `apply_preset()`); default `medium`. Persisted in `user://settings.cfg` (`[graphics] preset`), changed in the pause menu (`ui\pause_menu.gd`).
- Command-line: `Settings.has_arg` / `arg_value` read user args after `--` (or plain args). The FPS gate takes `--preset=low|medium`. Whether `play.bat --preset=` is honoured by `main.gd` is **UNVERIFIED**; only `tests\fps_gate.gd` reads `--preset` (verified).
- Flags read by `main.gd`: `--spawn=x,z[,dir[,y]]` (dir -1 = against edge order; y picks the deck of stacked roads), `--autodrive`, `--world=old`.
- Flags read by `tests\fps_gate.gd`: `--spawn --autodrive --region=<name> --preset= --warmup=s --seconds=s --cockpit --png=path --png_at=s --breakdown --map`.
- `autoload\settings.gd` has Showmik's **uncommitted own changes**. Do not touch.

## Architecture map

Autoloads (`project.godot`): `Settings` (`autoload\settings.gd`), `FpsLog` (`--fps-log`), `Origin` (floating origin), `Radio` (local music, N/B/M keys). `RoadGraph`, `OsmWorld`, `CarRegistry` are `class_name` scripts, not autoloads.

- **Streaming world**: `world\tile_streamer.gd` (tile queue, worker jobs, apply steps per frame), `world\tile_node.gd` (builds one tile: terrain mesh/collider, water, scatter, road mesh/collider chunks, city chunks, props), `world\tile_gen.gd` (worker-side generation), `world\terrain_fn.gd` (pure static terrain function). Budget: main-thread apply steps should stay ~1 ms.
- **Map data**: `world\osm_world.gd` (baked OSM world: terrain raster, biome planes, water, footprints, petrol stations, labels, spawns; `meta["regions"]`). `world\road_graph.gd` (roads as splines, node heights pinned and smoothed, junction planes, nearest_point, tangent). Data in `data\world\{country.json,regions\*.json,baked\}`.
- **road_mesher** (`world\road_mesher.gd`): continuous road ribbons + one slab collider per segment run, shared border cross-sections, terrain stamped under roads. WIP adds the clearance API: `clear_hw`, `corridor_edge`, `corridor_top`, `_clear`, `quad_hit`, `quad_blocked`, `spawn_pose`.
- **scatter** (`world\scatter.gd`): MultiMesh trees/shrubs/rocks/grass with LODs, per tile. WIP skips instances that fall in a road corridor.
- **city_chunks** (`world\city_chunks.gd`): OSM footprints as merged extruded blocks per 256 m chunk (LOD0, LOD1 hulls, LOD2 skyline impostors, box occluders, one wall collider per tile). Shaders `shaders\building.gdshader`, `building_lod.gdshader`.
- **poi_builder** (`world\poi_builder.gd`): petrol station canopies/totems merged into the props mesh. Also `world\hero\` (old hand-made hero tiles), `world\weather.gd`, `world\day_night.gd`.
- **Map UI**: `ui\map_data.gd` (road data for maps), `ui\minimap.gd` (rotating round minimap, roads batched per colour/width), `ui\full_map.gd` (M key), `ui\gps_route.gd` (A* GPS on road graph).
- **HUD**: `ui\hud.gd` + `ui\hud.tscn`, `ui\speedo.gd` (Forza-style speed/gear/RPM, H1 commit). `ui\pause_menu.*`.
- **Cars**: `cars\car.gd` (VehicleBody3D physics), `cars\drivetrain.gd`, `cars\active_aero.gd` (DRS / airbrake wing), `cars\autodrive.gd` (pure-pursuit route follower used by gates), `cars\cockpit.gd`, `cars\car_mirror.gd`, `cars\car_lights.gd`, `cars\engine_audio.gd`, `cars\glb\` (GLB/FBX body loader, merged meshes), `cars\p1\` (code-built P1 + interior). Camera `camera\camera_rig.gd` (orbit + cockpit).
- **Main**: `main.gd` / `main.tscn` (spawn, respawn onto nearest road, wiring).
- **Tools**: `tools\bake_world.py`, `osm_fetch.py`, `elev_fetch.py`, `render_world_map.py`, `validate_world.py`, `gen_network.gd`, `check_scripts.gd`. Files `tools\_*.gd/.tscn` are untracked debug probes.

## Test gates

All headless gates: `tools\run_gates.bat` (cwd auto = repo root; Godot console exe; writes `logs\<name>.log`; one PASS/FAIL line each). A gate fails if its log has `FAIL:`, `ERROR`, `Parse Error` or `WARNING` (the Jolt job-system line is filtered). Run all (cmd or PowerShell):

```bat
cd /d C:\Users\acer\Documents\GitHub\p1-drive-other
tools\run_gates.bat
```

Individual gates (what `run_gates.bat` runs; `$G` = `C:\Users\acer\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe`, run from repo root):

| Gate | Command | Pass means |
|---|---|---|
| import | `$G --headless --path . --import` | no ERROR/WARNING |
| check | `$G --headless --path . -s res://tools/check_scripts.gd` | every script/scene/shader under `res://` loads with no parse errors (it scans **all** of `res://`, including `logs\`) |
| boot | `$G --headless --path . --quit` | clean boot |
| smoke | `$G --headless --path . --fixed-fps 60 res://tests/smoke_test.tscn` | prints `SMOKE PASS` |
| stream | `... --fixed-fps 60 res://tests/streaming_test.tscn` | `STREAM PASS` (no stalls, tile/memory bounds, p99 < 8 ms, max < 25 ms per PLAN §8) |
| drive | `... --fixed-fps 60 res://tests/drive_test.tscn` | car boots onto spawn and drives; `DRIVE PASS` |
| fall | `... --fixed-fps 60 res://tests/fall_test.tscn` | car never drops below road/terrain across bridges, seams, interchanges |
| cars | `... --fixed-fps 60 res://tests/car_test.tscn` | all cars load, wheels, controls |
| kick | `... --fixed-fps 60 res://tests/kick_test.tscn` | `KICK PASS`: P1 + 600LT autodrive 100–300 km/h, no sideways kick (DV_LAT 0.6, DW 0.6) or unexplained lift-off (45 air ticks) |
| smooth | `... --fixed-fps 60 res://tests/smoothness_gate.tscn` | all four cars on Tokyo / Monaco / Dubai motorway routes: no airtime, max dv_y/dw within thresholds, top speed ≥ 250 (240 Monaco) |

Gates NOT in `run_gates.bat` (**clearance is not wired yet; M4b requires wiring it**):

```powershell
$G = "C:\Users\acer\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe"
# clearance: all road tiles, all regions (~144 s). Optional: --region=tokyo_hakone|monaco_alps|dubai_jais  --max_tiles=N
& $G --headless --path . res://tests/clearance_gate.tscn
# FPS gate: windowed exe, needs a real GPU window, default preset medium
tools\run_fps_gate.bat low medium        # per-region Tokyo/Monaco/Dubai; results in logs\fps_gate.log
```

- Clearance pass = prints `CLEARANCE PASS`; failure prints `FAIL: N corridor violations {...}` with examples. Checks terrain above road, scatter trunk+crown, building roofs, prop vertices, and that every spawn is on a carriageway lane facing along the road.
- FPS gate: `run_fps_gate.bat` calls `Godot_v4.7.2-stable_win64.exe --path . res://tests/fps_gate.tscn -- --autodrive --preset=<p> --region=<r> "--spawn=x,z,dir,y"`. Spawns: tokyo `9777,-1692,-1,18.6`, monaco `-8057.4,241.2,1,36.4`, dubai `-553,5500,-1,6.1`. It only **reports and warns** (greps `FPS ` lines); it does not fail. Compare against the targets in "Performance targets".
- `tools\t.sh` is a quick headless runner (`T=timeout N=tail-lines sh tools/t.sh <args>`).

### Last known results (Opus3 run, baseline per Showmik; Nov 18 evening)

- Passed: import, boot, smoke, drive, fall, cars, smoothness, full clearance (253 tiles: 96 tokyo, 64 monaco, 93 dubai; `logs\_clr0.log`).
- Failed:
  - **check**: parse errors `Could not find type "Acc"` from `res://logs/_cc_new.gd` (`logs\check.log`).
  - **stream**: `STREAM FAIL: settle timeout` plus `ERROR: unimplemented base type encountered in renderer scene cull` at `world/tile_node.gd:339` `_city_chunk`; `_city_chunk` apply step 13.9 ms, max job 7885 ms (`logs\stream.log`). The renderer error is raised by an `instance_set_base` call on a headless dummy mesh, likely from the new city chunk mesh path.
  - **kick**: `KICK FAIL: mclaren_600lt left the ground at t=0.8s 1 km/h (air ticks 46, up 1.00, falls 0)`. P1 portion passed (max 294 km/h) (`logs\kick.log`).
- Log files dated Nov 18 18:38–18:48 match this (`logs\_gates1.txt`). `%TEMP%\p1_roads_opus3.log` contains only a session-limit message, so it has no results of its own. No later logs were found.
- No after-M4b FPS gate was run. Older `logs\fps_gate_before_m4b.log` (Nov 18 16:49, pre-M4b-WIP baseline):

| Region | Low avg / 1% / min | Medium avg / 1% / min |
|---|---|---|
| Tokyo | 71.8 / 49.1 / 23.7 | 39.6 / 17.2 / **9.2** |
| Monaco | 62.8 / 31.8 / 23.1 | 41.5 / 29.3 / 19.0 |
| Dubai | 80.4 / 57.1 / 35.0 | 47.1 / 31.2 / 22.0 |

  Draw calls ~100–130 and ~530–850k tris reported as over budget. Opus3 prompt wanted the Monaco Medium hitch (~8 FPS) fixed; unverified whether it was.
- Earlier M6 commit-time numbers are in `logs\fps_m6.log` / `fps_m6med.log` (UNVERIFIED relevance).

## Ordered pending work

### 1. Finish M4b (do this first): road corridor clearance

Goal (from Opus3 prompt `%TEMP%\p1_roads_opus3_prompt.txt`): flatten/blend terrain under roads plus shoulders, cut hills at passes, nothing (trees, props, buildings, mountains) inside the roadway or shoulders. Also fix: Monaco spawn on the sidewalk, Monaco hillside hole, buildings badly placed on slopes, Monaco Medium FPS hitch, garbled "Col de Turini" map label.

What the uncommitted WIP already does (read diffs with `git diff <file>`; do not rewrite blindly):
- `world\road_mesher.gd` (+~450): corridor API (`clear_hw`, `corridor_edge`, `corridor_top`, `quad_hit`, `quad_blocked`, `_clear`, `_struct_ok`, `_box_ok`, `_seg_ok`, `_drop_blocking_quads/_faces`). Clear corridor = carriageway + shoulder (city: + kerb/sidewalk); vertical band from 1 m under the surface to `CLEAR_H` 4.2 m above, so bridges/overpasses are not counted. Bridge pieces that intrude another road are dropped (visual + collider). `spawn_pose(pos, dir)` returns a lane pose on a real stretch (never junction pad or sidewalk). Constants: `MEDIAN_HW 0.8`, `KERB_TOL 0.15`, `RAIL_OUT 0.35`.
- `world\scatter.gd`: per-type `CROWN` / `HEIGHT` / `CLEAR_ZONE` tables; scatter and roadside grass skipped when `corridor_edge(...) >= 0` (OSM world only).
- `world\city_chunks.gd` (+298/-): `_prepare` clips footprints out of road corridors (`Geometry2D.clip_polygons`), drops slivers under 25 m², drops sites with ground fall > `MAX_SLOPE_DROP` 8 m, sets floor at highest ground with a stone **plinth** down to lowest ground (UV.v < 0), `ROAD_GAP 0.3`. Sky prisms use the placed list.
- `shaders\building.gdshader`, `building_lod.gdshader`: draw the plinth (UV.v < -0.05) as plain stone, no windows.
- `world\poi_builder.gd`: petrol stations skipped when apron/totem overlap a road corridor (`_site_clear`).
- `main.gd`: spawn and respawn now go through `RoadMesher.spawn_pose` (lane of a real road; respawn keeps the car's heading).
- `tests\clearance_gate.gd/.tscn` (new, untracked): the clearance gate above. Not wired into `run_gates.bat`.
- `tests\junction_shots.gd/.tscn` (new, untracked): M5 screenshot helper. `tools\_*.gd/.tscn` (untracked): debug probes (`_probe`, `_pv`, `_route`, `_spawn`, `_ter`, `_dbg_fall`, `_dbg_smooth`, ...).
- Terrain flatten/cut was part of M6/M4 (`terrain stamped under every road`); whether M4b WIP adds more terrain carving is **UNVERIFIED** (no terrain files appear in `git diff --stat`).

Tasks:
1. Inspect WIP: `git status`, `git diff --stat`, per-file diffs. Do not revert.
2. `logs\_cc_new.gd` (git-ignored, untracked-by-ignore): likely scratch (a stale copy of `_extrude` code using an `Acc` type from `city_chunks.gd`). It breaks the `check` gate because `tools\check_scripts.gd` scans every file under `res://`. Gemini decides: delete (needs Showmik's OK per hard rules) or repair, or exclude `logs\` in `check_scripts.gd` (explain it in the commit message). I did not touch it.
3. Fix `stream`: investigate `world\tile_node.gd:339` `_city_chunk` (`instance_set_base` "unimplemented base type", leaked `DummyMesh` RID) and the `_city_chunk` apply step (13.9 ms vs ~1 ms budget; likely split the apply across frames or build the arrays/ArrayMesh on the worker). Check if the settle timeout is from slow/blocked jobs (max job 7885 ms) or from stalls. Rerun once if there is a single spike; report honestly.
4. Fix `kick`: 600LT is airborne at t = 0.8 s at 1 km/h. This is at the start, so check spawn height/pose from `RoadMesher.spawn_pose` vs the new spawn y and car drop height, and tile-ready wait in `tests\kick_test.gd`. The same spawn works for P1 and the smoothness gate. Do not relax `AIR_TICKS` / `DV_LAT` / `DW`.
5. Wire clearance into `tools\run_gates.bat` (e.g. `call :run clearance --headless... res://tests/clearance_gate.tscn`; mind the ~144 s runtime; `:run` expects `--fixed-fps` style args but passes `%2 %3 %4`).
6. Re-run all gates until all pass, then `tools\run_fps_gate.bat low medium`, then save screenshots.
7. Commit locally: `M4b: road corridor clearance`.

Acceptance criteria M4b:
- `tools\run_gates.bat` → all PASS (import, check, boot, smoke, stream, drive, fall, cars, kick, smooth) and the clearance gate prints `CLEARANCE PASS` over all 253 tiles.
- All four cars (P1, 600LT, Gemera, Bentley) pass smooth; P1 + 600LT pass kick; no test thresholds weakened (any test change explained in commit message).
- FPS (avg / 1% low / min per region) reported before (table above) and after; meets "Performance targets"; Monaco Medium hitch and Tokyo Medium min 9.2 explained or fixed.
- Screenshots in `logs\m4b_*.png`: Tokyo, Monaco, Dubai, hill pass (`logs\` is git-ignored, so they are not committed; also optionally copy to `docs\shots\` if Showmik wants them tracked).
- Monaco spawn lands on the carriageway facing along it; Monaco hillside hole closed; `Col de Turini` map label legible. Status of these three is **UNVERIFIED**.
- Print `M4b DONE`.
- Commit contents: `main.gd`, `scatter.gd`, `poi_builder.gd`, `city_chunks.gd`, `road_mesher.gd`, both building shaders, `tests\clearance_gate.*`, `tools\run_gates.bat` edits, any test/map-label fixes. **Do NOT commit**: `autoload\settings.gd`, `screenshots\*.import`, `docs\*.import`, `assets_nc\`, `refs\`, `graphify-out\`. Untracked debug probes `tools\_*.gd/.tscn` and `tests\junction_shots.*`: decide per file; prefer leaving probes uncommitted, junction_shots belongs to M5. Do not delete.

### 2. M5: junctions

- Source: `docs/MAP_PLAN.md` §4 and task `M5`; `%TEMP%\p1_m5_prompt.txt`. Intended: proper T, cross, roundabout and motorway ramp/gore junctions generated from the road graph: tilted-plane junction fitting, mouth locking over the last ~12 m of each approaching edge, shared exact mouth vertices, S-curve splitter-island roundabouts, parallel-locked motorway gore merges; smooth merged surfaces, lane markings, curbs, no gaps/overlaps; driven without bumps; 0 airtime and 0 jolts in `smoothness_gate`.
- Status: not started as a commit. The M6 commit already added junction planes, gore locks and parallel-carriageway caps in `RoadGraph`/`RoadMesher` (see commit message `c946042`). Earlier RD3 (`c49b939`) did procedural-world roundabouts/filleted junctions. What exactly is still missing on the OSM map is **unknown**; `tests\junction_shots.gd` (untracked WIP) is meant to screenshot junctions to find out.
- Files: `world\road_mesher.gd`, `world\road_graph.gd`, `tools\bake_world.py` (bake step), `tests\junction_shots.*`, `tests\smoothness_gate.gd`.
- Acceptance: all gates (incl. clearance) pass; smooth gate 0 airtime; `logs\m5_junction.png` showing T, cross, roundabout and ramp; FPS targets hold; one local commit `M5: junctions`; print `M5 DONE`.
- Caveat: `MAP_PLAN.md` uses an older numbering (its M6 = loader, M7 = motorway backbone, M8–M10 = regions). The Opus3 prompt renumbered: M7 = road furniture. Use the Opus3 numbering.

### 3. M7: realistic road furniture

- Source: Opus3 prompt. Landed already: **M6 (`c946042`)** delivered the OSM map as the default world, baked data, road meshing, city chunks, petrol stations, minimap/full map using real roads. Do not redo it. (Old `MAP_PLAN.md` M7 "motorway backbone" is superseded by the stitched map v3 already merged in `d87f313`/`658bcef`.)
- Goal: W-beam steel guardrails with posts; sloped Jersey concrete median barrier; street lights (pole, arm, lamp head, night glow); lane separators and cat's-eyes; realistic PBR metal/concrete with wear; all following curves and bending cleanly through junctions, no gaps/clipping, respecting the clearance zone (`RoadMesher.corridor_*`, `RAIL_OUT`, `MEDIAN_HW`). Instanced / MultiMesh per chunk.
- Existing partial furniture: RD-era guardrails/parapets in `world\road_mesher.gd` (bridges, `RAIL_OUT`) and props in `world\tile_node.gd`/`tile_gen.gd`; exact current state is **UNVERIFIED**.
- Acceptance: gates + clearance pass (barriers/lamps must not violate the corridor gate except for intentional rails: adjust the gate with an explained exception, not by relaxing thresholds); FPS targets hold; `logs\m7_furniture.png`; commit `M7: road furniture`; print `M7 DONE`.

## Broader goals (after the ordered milestones)

- Roads as smooth curves, gentle elevation OK; no saw-tooth tiles that launch cars; terrain follows roads evenly. (M4 `6d89693` smoothed vertical profiles: ~600 m vertical radius on motorways, ~350 m other, ~170 m mountain; remove any remaining kinks found by `smooth`/`kick`.)
- Roads clear of trees, buildings, mountains: M4b approach above (corridor index in `RoadMesher`, enforced in scatter, city chunks, POIs, bridge pieces, spawn).
- Realistic map from real OSM roads + elevation; regions Tokyo/Hakone, Monaco/Turini, Dubai/Jebel Jais stitched into one country (`data\world\country.json`). Map previews (`docs\world_map*.png`, in-game minimap/full map) must look like a realistic atlas, never neon diagrams. Renderer: `tools\render_world_map.py`, `ui\map_data.gd`.
- A properly playable, connected map: roads connected across regions with no dead ends (`validate_world.py`; autodrive routes in the gates avoid dead ends).
- Car realism: P1 vs reference photos (44 photos in `C:\Users\acer\Documents\GitHub\p1-drive\refs`; `refs\` is git-ignored, keep it out of git). Keep airbrake and DRS working (`cars\active_aero.gd`, smoke gate). 600LT. Gemera AWD 1700 PS and Bentley EXP 10 in the picker at real scale with spinning and steering wheels (done in S4a; keep working, `cars` gate).
- Non-boxy realistic cockpit (S2/S5 done for 600LT and P1; polish as needed).
- Forza Horizon 5 style HUD: thin circular RPM ring, big digital speed and gear at bottom right, round minimap with route at bottom left (H1 `3b39a99` did a version; verify vs spec).
- Day/night, rain, radio: present (`world\day_night.gd`, `world\weather.gd`, `autoload\radio.gd`); keep working.

## Performance targets

- Low: 48–60 FPS, never below 30. Medium: 40–55 FPS, never below 25. Showmik's laptop overall: ≥ 30 FPS, never below 25.
- Report avg / 1% low / min per region (Tokyo, Monaco, Dubai) on Low and Medium before and after each step.
- Run the after-M4b FPS gate before committing M4b:

```bat
cd /d C:\Users\acer\Documents\GitHub\p1-drive-other
tools\run_fps_gate.bat low medium
```
  Results: `logs\fps_gate.log` (`FPS <region> [<preset>] ... avg, 1% low, min | draws | tris | worst ms`). Add `--breakdown` to a manual `fps_gate` run for GPU/CPU render time. Copy the log to `logs\m4b_fps_after.txt` for the record.
- Do not downscale quality to hit FPS without Showmik's OK (owner: "he runs GTA 5 fine on this laptop").

## Hard rules for Gemini

- Never push to origin (`https://github.com/SHADOW-465/p1-drive`, public) without Showmik's explicit OK. No force-push, no deploys, no remote changes.
- Never commit `assets_nc\` (vecarz P1, Gemera, Bentley, 600LT models; git-ignored). P1 reference photos and `refs\` stay out of git. Never commit `graphify-out\`.
- Do not touch his uncommitted `autoload\settings.gd` or any `screenshots\*.import`.
- Do not delete files without his OK (includes `logs\_cc_new.gd`).
- No stash / reset / clean / revert of existing WIP. (Shared stash stack across worktrees.)
- One local commit per milestone, only with the required gates passing; do not weaken test thresholds; explain any test change in the commit message.
- Git commit trailer used so far: `Co-Authored-By: ...`. Follow whatever Showmik's tooling requires.
- Wrap Godot runs in a timeout (prior prompts used 590 s) so nothing hangs.
- No secrets in files or commits.

## Current working tree (snapshot)

Branch `other/lowmed`, HEAD `6d89693 M4: smooth roads and car fixes`. Remote `origin` = public GitHub. 49 status entries at snapshot.

```
 M autoload/settings.gd            (Showmik's own: leave alone)
 M main.gd                         (spawn/respawn via RoadMesher.spawn_pose)       39 lines
 M shaders/building.gdshader                                                        9
 M shaders/building_lod.gdshader                                                    5
 M world/city_chunks.gd            (clip to roads, slope sites, plinth)            298
 M world/poi_builder.gd            (_site_clear)                                    13
 M world/road_mesher.gd            (corridor API, spawn_pose, quad culling)        448
 M world/scatter.gd                (corridor skip)                                   9
?? tests/clearance_gate.{gd,tscn}  (M4b gate)
?? tests/junction_shots.{gd,tscn}  (M5 helper)
?? tools/_aabb _cam _ce _dbg _dbg_fall _dbg_smooth _edge _near _node _pq _probe _pv _route _spawn _ter  (.gd/.tscn debug probes)
?? docs/world_map*.png.import, docs/world_map.svg.import, screenshots/s1_caliper_*.png.import
?? HANDOFF_GEMINI.md               (this file: do not commit unless Showmik asks)
```

`git diff --stat` (tracked): 7 files + settings.gd; 665 insertions, 156 deletions (excl. settings.gd). Git ignores `logs/`, `*.uid`, `assets_nc/`, `refs/`, `.godot/`, `data/world/osm_cache/`, so `logs\_cc_new.gd` does not appear in status.

## Suggested first actions for Gemini

1. `git status` + `git diff --stat`; read the road_mesher / city_chunks / scatter diffs. Change nothing yet.
2. Decide `logs\_cc_new.gd` (delete with Showmik's OK, repair, or exclude `logs\` from `tools\check_scripts.gd`). Re-run `check`.
3. Fix `stream` (`tile_node.gd:339` `_city_chunk` error + apply-step cost + settle timeout).
4. Fix `kick` (600LT airborne at t = 0.8 s) without relaxing thresholds.
5. Wire clearance into `tools\run_gates.bat`; run all gates until green.
6. `tools\run_fps_gate.bat low medium`; compare to the baseline table; fix Monaco/Tokyo Medium dips if over target.
7. Take `logs\m4b_*.png` screenshots (Tokyo, Monaco, Dubai, hill pass); verify Monaco spawn, hillside hole, Col de Turini label.
8. Commit M4b locally with only the files listed above. No push.
9. Then M5 (use `tests\junction_shots`), then M7, then broader goals. No new scope before M4b is committed.
