# P1 Drive — Progress

Tick a box in the same commit that finishes the task. Details and done-criteria: `docs/PLAN.md` §10.

## Milestone A — streaming world, solid P1, 50–150 km, city + hill pass
- [x] T01 Project skeleton + gate 1 — input map registered in code (autoload/settings.gd), *.uid git-ignored
- [x] T02 Test track + static sky — oval dev track; road.gdshader and day_night.gd (static 17:00) started early
- [x] T03 P1 physics core — 0-100 3.07 s, 0-200 6.80 s, top 345 (LOW aero, limiter), 100-0 28.8 m, 300-0 6.07 s; engine_force sign and friction fixed, see PLAN 6
- [x] T04 Camera + playable loop — chase/hood rig in _process on interpolated car xf (physics interpolation on); Mobile renderer, MSAA 2x; --shot=N dev arg; 60 FPS windowed
- [ ] T05 Active aero
- [ ] T06 Smoke test + gate 2
- [ ] T07 P1 procedural mesh
- [ ] T08 Lights, disc glow, trails
- [ ] T09 Engine audio
- [ ] T10 Handling polish
- [ ] T11 Origin + terrain function
- [ ] T12 One tile end to end
- [ ] T13 Streamer
- [ ] T14 Floating origin
- [ ] T15 Streaming test + gate
- [ ] T16 Road graph
- [ ] T17 Road surface
- [ ] T18 Road props
- [ ] T19 Streamed world becomes the game
- [ ] T20 Scatter
- [ ] T21 Day/night
- [ ] T22 Hero mechanism + hill pass
- [ ] T23 City roads + flyover
- [ ] T24 City overlay
- [ ] T25 Network generator
- [ ] T26 Milestone A hardening (real-HW 60 FPS check)

## Milestone B — towns, HUD, menus, radio, weather
- [ ] T27 Procedural towns
- [ ] T28 HUD
- [ ] T29 Settings + pause menu
- [ ] T30 Radio
- [ ] T31 Minimap (optional)
- [ ] T32 Weather core
- [ ] T33 Rain FX + mist

## Milestone C — coast, viewpoints, 500 km
- [ ] T34 Sea + coast biome
- [ ] T35 Coast hero tile
- [ ] T36 Viewpoints
- [ ] T37 Expand the network

## Extras
- [ ] T38 Companion stub
- [ ] T39 Car 2 (Gemera-inspired)
- [ ] T40 Car select
- [ ] T41 Final polish

## Measured numbers (fill in as tasks land)
| Metric | Target | Measured | Task |
|---|---|---|---|
| 0–100 km/h | 2.8–3.3 s | | T03 |
| Top speed normal / DRS | 325–335 / 345–352 km/h | | T05 |
| Worker time per FULL tile | ≤ 250 ms | | T13 |
| Network length | ≥ 100 km | | T25 |
| Min FPS, 5 min autodrive, target HW | ≥ 57 | | T26 |
