#!/usr/bin/env python3
"""tools/fetch_lofoten.py — step 2 of Map 2 (Lofoten): fetch OpenStreetMap roads in tiles.

Writes to data/world/osm_cache_lofoten/ (separate from Map 1's data). Uses the existing
osm_fetch helpers (Overpass first, OSM API v0.6 fallback). Resumable: skips tiles already saved.
Attribution: Road data (c) OpenStreetMap contributors, ODbL (https://www.openstreetmap.org/copyright)
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osm_fetch import compact_overpass_response, fetch_via_osm_v06, try_overpass_fetch  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "world" / "osm_cache_lofoten"
# Gemini's Lofoten box (south, west, north, east) — checked by hand against the E10 route
S, W, N, E = 67.87, 12.95, 68.34, 14.35
TILE_LAT, TILE_LON = 0.12, 0.20


def tiles():
    out = []
    lat = S
    while lat < N - 1e-9:
        lon = W
        while lon < E - 1e-9:
            out.append((round(lat, 4), round(lon, 4), round(min(lat + TILE_LAT, N), 4), round(min(lon + TILE_LON, E), 4)))
            lon += TILE_LON
        lat += TILE_LAT
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    ts = tiles()
    print(f"Lofoten fetch: {len(ts)} tiles", flush=True)
    total_ways = 0
    for i, bbox in enumerate(ts, 1):
        f = OUT / f"tile_{i:03d}.json"
        if f.exists():
            d = json.loads(f.read_text(encoding="utf-8"))
            total_ways += sum(1 for e in d["elements"] if e.get("type") == "way" and "highway" in e.get("tags", {}))
            print(f"[{i}/{len(ts)}] cached", flush=True)
            continue
        t0 = time.time()
        data = try_overpass_fetch(bbox, timeout_s=60)
        src = "overpass"
        if data is not None:
            data = compact_overpass_response(data)
        else:
            data = fetch_via_osm_v06(bbox)
            src = "osm-api"
        data["bbox"] = list(bbox)
        data["source"] = src
        f.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
        ways = sum(1 for e in data.get("elements", []) if e.get("type") == "way" and "highway" in e.get("tags", {}))
        total_ways += ways
        print(f"[{i}/{len(ts)}] {bbox} via {src}: {ways} highway ways in {time.time() - t0:.1f}s", flush=True)
        time.sleep(1.5)
    print(f"LOFOTEN FETCH DONE: {len(ts)} tiles, {total_ways} highway ways (may double-count ways that cross tiles)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
