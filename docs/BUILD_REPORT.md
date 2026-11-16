# P1 Drive — Build Report

## Low/Medium build

Branch: `other/lowmed` (Mobile renderer, Medium default preset, Low lean preset, High preset hook exposed for `T17e`).

### Launching (`play.bat`)
- Normal play: `play.bat`
- FPS / frame-time logging: `play.bat --fps-log`
- Unattended graph-following drive: `play.bat --fps-log --autodrive`
- Dev screenshot capture: `play.bat --shot=120` (saves `logs/shot.png` and exits)

### Controls
| Action | Keyboard | Gamepad |
|---|---|---|
| Throttle / Brake & Reverse | `W` / `S` or `Up` / `Down` | `RT` / `LT` |
| Steer | `A` / `D` or `Left` / `Right` | Left Stick X |
| Handbrake | `Space` | `A` |
| Drift Mode toggle | `G` | `X` (button 2) |
| Active Aero DRS (hold) | `Shift` | `RB` |
| Camera toggle (Chase / Hood) | `C` | `Y` |
| Respawn on nearest road | `R` | `Back` |
| Time skip (+1 hour) | `T` | `D-pad Down` |
| Radio Next / Prev / Play-Pause | `N` / `B` / `M` | `D-pad Right` / `Left` / `Up` |
| FPS Counter toggle | `F3` | — |
| Pause / Settings Menu | `Esc` | `Start` (`LB`/`RB` switch tabs) |

### Verified results (after final edits)
- **`tools\run_gates.bat`**: `GATES PASS` (`PASS import`, `PASS check`, `PASS boot`, `PASS smoke`, `PASS stream`) with zero errors/warnings.
- **Smoke test (`logs/smoke.log`)**: `SMOKE PASS` — `0-100 3.07s`, `0-200 6.87s`, `top 334 km/h` (`drs 346 km/h`), `300-0 5.40s`, `100-0 28.2m`.
- **Streaming test (`logs/stream.log`)**: `STREAM PASS` — `50` tiles visited, `17` origin shifts, `0` stalls, `max full 13`, `max total 49`, `max nodes 50`, `nodes 601 -> 601`, `memory 74.9 -> 77.8 MB`, `rest shift moved 0.057 m` (`4` wheels), `streamer frame ms: avg 0.10, p99 0.28, max 17.42` (`max step 11.84 ms`, `max job 281 ms`).
- **Network generator (`tools/gen_network.gd`)**: `48` nodes, `81` edges, `144.1 km` total (`highway 55.2`, `country 60.9`, `mountain 20.9`, `city 7.1`), `min radius: highway 705 m, country 189 m, mountain 28 m`, connected graph, `RoadGraph.self_check()` passed.

### Known gaps / deferred to `main` (`[FABLE]`) or later Milestone B/C tasks
- **Graphics / Visuals (`[FABLE]`)**: Detailed McLaren P1 mesh (`T17a`), Forward+ High preset realism track (`T17e`), interior cockpit camera (`T17d`), High-quality sky/pass/city flyover & buildings (`T21–T24`), advanced weather/rain droplets/mist (`T32–T33`), sea/coast (`T34–T35`), and real-hardware 5-minute 60 FPS check (`T26`).
- **Remaining `[OTHER]` tasks**: Procedural towns (`T27`), optional minimap (`T31`), viewpoints (`T36`), 500 km expansion (`T37`), companion/car 2/polish (`T38–T41`).
- **Audio & live GPU check**: `Radio` plays local `.mp3`/`.ogg` files from `Settings.music_dir` (`%USERPROFILE%\Music\P1Drive`); tested headless with missing folder (`"No music"`, zero errors). Live windowed GPU frame-time verification on target hardware (Ryzen 3 7320U / Radeon 610M) should be run via `play.bat --fps-log --autodrive` after merging.
