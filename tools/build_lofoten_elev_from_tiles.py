#!/usr/bin/env python3
"""tools/build_lofoten_elev_from_tiles.py — Map 2 elevation grid from SRTM 1-arc-second tiles (local, fast).

Reads N68E013.hgt and N68E014.hgt (SRTM, big-endian int16, 3601x3601), bilinear-samples the same
513 x 513 game grid as fetch_lofoten_elev.py (64 m, centre 68.2085 N 13.90 E), and writes
data/world/lofoten_raw/elev_grid_513.json in the same format. SRTM voids (-32768) and sea -> 0 m.
Source tiles: SRTM 1 arc-second, NASA/USGS. Tiles mirrored at elevation-tiles-prod (skadi).
Inputs are read from TILE_DIR (default: $TMPDIR).
"""
import json
import math
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "world" / "lofoten_raw" / "elev_grid_513.json"
TILE_DIR = Path(os.environ.get("TMPDIR", "."))

CLAT, CLON = 68.2085, 13.90
N = 513
STEP = 64.0
ORIGIN = -16384.0
KX = 111320.0 * math.cos(math.radians(CLAT))
KZ = 110574.0
SAMP = 3601


class Tile:
    def __init__(self, path: Path, lat_top: float, lon_left: float):
        raw = path.read_bytes()
        assert len(raw) == SAMP * SAMP * 2, f"{path.name}: unexpected size {len(raw)}"
        self.v = struct.unpack(f">{SAMP * SAMP}h", raw)
        self.lat_top = lat_top
        self.lon_left = lon_left

    def at(self, r: int, c: int) -> float:
        val = self.v[r * SAMP + c]
        return 0.0 if val == -32768 else float(val)


def tile_for(lat: float, lon: float, tiles: dict) -> Tile:
    return tiles[(math.floor(lat), math.floor(lon))]


def sample(lat: float, lon: float, tiles: dict) -> float:
    t = tile_for(lat, lon, tiles)
    fy = (t.lat_top - lat) * (SAMP - 1)
    fx = (lon - t.lon_left) * (SAMP - 1)
    r0, c0 = int(math.floor(fy)), int(math.floor(fx))
    r0 = min(max(r0, 0), SAMP - 2)
    c0 = min(max(c0, 0), SAMP - 2)
    ty, tx = fy - r0, fx - c0
    a = t.at(r0, c0)
    b = t.at(r0, c0 + 1)
    c = t.at(r0 + 1, c0)
    d = t.at(r0 + 1, c0 + 1)
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def main() -> int:
    tiles = {
        (68, 13): Tile(TILE_DIR / "N68E013.hgt", 69.0, 13.0),
        (68, 14): Tile(TILE_DIR / "N68E014.hgt", 69.0, 14.0),
    }
    grid = []
    for iz in range(N):
        z = ORIGIN + STEP * iz
        lat = CLAT - z / KZ
        for ix in range(N):
            x = ORIGIN + STEP * ix
            lon = CLON + x / KX
            grid.append(round(max(0.0, sample(lat, lon, tiles)), 2))  # below-sea values -> 0 m (water level)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"n": N, "step": STEP, "origin": ORIGIN, "centre": [CLAT, CLON],
                               "source": "SRTM 1 arc-second tiles N68E013/N68E014 (local bilinear)",
                               "elev_m_row_major_z_then_x": grid}), encoding="utf-8")
    land = sum(1 for g in grid if g > 0.5)
    print(f"TILE GRID DONE: {len(grid)} values, land {land} ({100 * land / len(grid):.1f}%), "
          f"min {min(grid):.1f} max {max(grid):.1f} m -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
