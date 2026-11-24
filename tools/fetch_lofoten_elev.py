#!/usr/bin/env python3
"""tools/fetch_lofoten_elev.py — elevation grid for Map 2 (Lofoten window).

Samples SRTM30m via OpenTopoData (100 points per request, 1 request/s) on the game's own grid:
513 x 513 points, 64 m apart, world x/z = -16384 + 64*i, centred on the window centre below.
Resumable: finished batches are kept in data/world/lofoten_raw/elev_batches/ and skipped on re-run.
Attribution: elevation SRTM 30 m via OpenTopoData (https://www.opentopodata.org/), data NASA/USGS.
"""
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from elev_fetch import query_elevation_batch  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "world" / "lofoten_raw"
BATCH_DIR = RAW / "elev_batches"

CLAT, CLON = 68.2085, 13.90          # window centre (world 0,0)
N = 513
STEP = 64.0
ORIGIN = -16384.0
KX = 111320.0 * math.cos(math.radians(CLAT))
KZ = 110574.0


def world_to_latlon(x: float, z: float) -> tuple[float, float]:
    return (CLAT - z / KZ, CLON + x / KX)


def main() -> int:
    BATCH_DIR.mkdir(parents=True, exist_ok=True)
    pts = []
    for iz in range(N):
        z = ORIGIN + STEP * iz
        for ix in range(N):
            x = ORIGIN + STEP * ix
            pts.append(world_to_latlon(x, z))
    per = 100
    nb = math.ceil(len(pts) / per)
    print(f"Lofoten elevation: {len(pts)} points in {nb} batches", flush=True)
    t0 = time.time()
    for b in range(nb):
        f = BATCH_DIR / f"b_{b:05d}.json"
        if f.exists():
            continue
        chunk = pts[b * per:(b + 1) * per]
        vals = None
        for attempt in range(4):
            try:
                vals = query_elevation_batch(chunk)
                break
            except Exception as exc:  # network hiccup: back off and retry
                print(f"  batch {b} attempt {attempt + 1} failed: {exc}", flush=True)
                time.sleep(5 * (attempt + 1))
        if vals is None or len(vals) != len(chunk):
            print(f"BATCH {b} FAILED; re-run to retry", flush=True)
            return 1
        f.write_text(json.dumps(vals), encoding="utf-8")
        if b % 50 == 0:
            print(f"batch {b}/{nb} ({time.time() - t0:.0f}s)", flush=True)
        time.sleep(1.1)
    # assemble
    grid = []
    for b in range(nb):
        grid.extend(json.loads((BATCH_DIR / f"b_{b:05d}.json").read_text(encoding="utf-8")))
    out = RAW / "elev_grid_513.json"
    out.write_text(json.dumps({"n": N, "step": STEP, "origin": ORIGIN, "centre": [CLAT, CLON],
                               "elev_m_row_major_z_then_x": grid}), encoding="utf-8")
    print(f"ELEV GRID DONE: {len(grid)} values -> {out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
