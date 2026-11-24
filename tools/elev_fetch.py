#!/usr/bin/env python3
"""
tools/elev_fetch.py — Real Elevation Sampler (OpenTopoData SRTM30m / ASTER30m + Open-Elevation Fallback)
Uses Python 3 standard library only (urllib, json, math, time, pathlib).

Samples real elevation:
  1. On a coarse terrain grid covering each area's bounding box
  2. Along the OSM highway network nodes in each area
from https://api.opentopodata.org/v1/srtm30m (or aster30m, max 100 points per request,
1 request per second) with https://api.open-elevation.com/api/v1/lookup as fallback.
Caches results in data/world/osm_cache/elev_<area_id>.json.
"""

import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from osm_fetch import AREAS, CACHE_DIR, USER_AGENT

OPENTOPO_SRTM_URL = "https://api.opentopodata.org/v1/srtm30m"
OPENTOPO_ASTER_URL = "https://api.opentopodata.org/v1/aster30m"
OPEN_ELEVATION_URL = "https://api.open-elevation.com/api/v1/lookup"
MAX_PTS_PER_REQ = 100
REQ_SLEEP_SEC = 1.1


def query_elevation_batch(points_latlon: list[tuple[float, float]]) -> list[float]:
    """
    Queries up to 100 (lat, lon) points from OpenTopoData srtm30m,
    falling back to aster30m and Open-Elevation if needed.
    """
    assert len(points_latlon) <= MAX_PTS_PER_REQ
    loc_str = "|".join(f"{lat:.6f},{lon:.6f}" for lat, lon in points_latlon)

    for base_url in (OPENTOPO_SRTM_URL, OPENTOPO_ASTER_URL):
        url = f"{base_url}?locations={urllib.parse.quote(loc_str, safe='|,.-')}"
        req = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )
        for attempt in range(3):
            try:
                time.sleep(REQ_SLEEP_SEC * (attempt + 1))
                with urllib.request.urlopen(req, timeout=25) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    results = data.get("results", [])
                    if len(results) == len(points_latlon):
                        elevs = []
                        all_valid = True
                        for r in results:
                            ev = r.get("elevation")
                            if ev is None:
                                all_valid = False
                                elevs.append(0.0)
                            else:
                                elevs.append(float(ev))
                        if all_valid or base_url == OPENTOPO_ASTER_URL:
                            return elevs
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    time.sleep(2.5)
                    continue
                break
            except Exception:
                break

    # Fallback: Open-Elevation POST API
    payload = json.dumps(
        {"locations": [{"latitude": lat, "longitude": lon} for lat, lon in points_latlon]}
    ).encode("utf-8")
    req = urllib.request.Request(
        OPEN_ELEVATION_URL,
        data=payload,
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        time.sleep(REQ_SLEEP_SEC)
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = data.get("results", [])
            if len(results) == len(points_latlon):
                return [float(r.get("elevation", 0.0) or 0.0) for r in results]
    except Exception as exc:
        print(f"    [elev_fetch] Warning: fallback failed ({exc}); returning 0.0")

    return [0.0 for _ in points_latlon]


def select_road_sample_nodes(osm_data: dict, max_samples: int = 100) -> list[tuple[int, float, float]]:
    """
    Picks up to `max_samples` representative road nodes (endpoints and spaced interior nodes)
    from highway ways in `osm_data` so road profiles have direct elevation samples in addition
    to the terrain grid.
    """
    elements = osm_data.get("elements", [])
    nodes = {
        el["id"]: (float(el["lat"]), float(el["lon"]))
        for el in elements
        if el.get("type") == "node" and "lat" in el and "lon" in el
    }
    priority_hw = {"motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "primary_link"}
    ways = [
        el for el in elements
        if el.get("type") == "way" and el.get("tags", {}).get("highway") in priority_hw
    ]
    if not ways:
        ways = [
            el for el in elements
            if el.get("type") == "way" and "highway" in el.get("tags", {})
        ]

    candidate_ids = []
    seen = set()
    # First pass: endpoints and midpoints of major ways
    for w in ways:
        nd_list = w.get("nodes", [])
        if not nd_list:
            continue
        indices = [0, len(nd_list) // 2, len(nd_list) - 1]
        if len(nd_list) >= 12:
            step = max(1, len(nd_list) // 6)
            indices = list(range(0, len(nd_list), step)) + [len(nd_list) - 1]
        for idx in indices:
            nid = nd_list[idx]
            if nid not in seen and nid in nodes:
                seen.add(nid)
                candidate_ids.append(nid)

    if len(candidate_ids) > max_samples:
        stride = len(candidate_ids) / float(max_samples)
        picked = [candidate_ids[int(i * stride)] for i in range(max_samples)]
    else:
        picked = candidate_ids

    return [(nid, nodes[nid][0], nodes[nid][1]) for nid in picked]


def fetch_area_elevation(area_id: str, meta: dict, grid_rows: int = 10, grid_cols: int = 10, force: bool = False) -> dict:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    elev_file = CACHE_DIR / f"elev_{area_id}.json"
    if elev_file.exists() and not force:
        cached = json.loads(elev_file.read_text(encoding="utf-8"))
        print(
            f"  [elev] Cached {area_id}: {grid_rows}x{grid_cols} terrain grid "
            f"({cached['min_elev_m']:.1f}..{cached['max_elev_m']:.1f} m) + {len(cached.get('road_samples', []))} road nodes"
        )
        return cached

    s, w, n, e = meta["bbox"]
    # 1. Build regular terrain grid (grid_rows x grid_cols = 100 points)
    grid_pts = []
    for r in range(grid_rows):
        lat = s + (n - s) * (r / max(1, grid_rows - 1))
        for c in range(grid_cols):
            lon = w + (e - w) * (c / max(1, grid_cols - 1))
            grid_pts.append((lat, lon))

    print(f"  [elev] Querying {len(grid_pts)} terrain grid points for {area_id} {meta['bbox']}...")
    grid_elevs = []
    for i in range(0, len(grid_pts), MAX_PTS_PER_REQ):
        batch = grid_pts[i : i + MAX_PTS_PER_REQ]
        grid_elevs.extend(query_elevation_batch(batch))

    # 2. Sample road nodes from cached OSM data if available
    osm_file = CACHE_DIR / f"{area_id}.json"
    road_samples = []
    if osm_file.exists():
        osm_data = json.loads(osm_file.read_text(encoding="utf-8"))
        sampled_nodes = select_road_sample_nodes(osm_data, max_samples=100)
        if sampled_nodes:
            print(f"  [elev] Querying {len(sampled_nodes)} road node elevations for {area_id}...")
            pts = [(lat, lon) for _, lat, lon in sampled_nodes]
            r_elevs = []
            for i in range(0, len(pts), MAX_PTS_PER_REQ):
                r_elevs.extend(query_elevation_batch(pts[i : i + MAX_PTS_PER_REQ]))
            for (nid, lat, lon), ev in zip(sampled_nodes, r_elevs):
                road_samples.append({
                    "node_id": nid,
                    "lat": round(lat, 7),
                    "lon": round(lon, 7),
                    "elev_m": round(ev, 2),
                })

    grid_2d = []
    for r in range(grid_rows):
        row_vals = [round(grid_elevs[r * grid_cols + c], 2) for c in range(grid_cols)]
        grid_2d.append(row_vals)

    all_vals = grid_elevs + [rs["elev_m"] for rs in road_samples]
    result = {
        "area_id": area_id,
        "region": meta["region"],
        "bbox": list(meta["bbox"]),
        "dataset": "srtm30m",
        "grid_rows": grid_rows,
        "grid_cols": grid_cols,
        "min_elev_m": round(min(all_vals) if all_vals else 0.0, 2),
        "max_elev_m": round(max(all_vals) if all_vals else 0.0, 2),
        "grid_elev_m": grid_2d,
        "road_samples": road_samples,
    }
    elev_file.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(
        f"  [elev] Saved {elev_file.name}: range {result['min_elev_m']:.1f}..{result['max_elev_m']:.1f} m "
        f"({grid_rows}x{grid_cols} grid + {len(road_samples)} road samples)"
    )
    return result


class AreaElevationSampler:
    """
    Interpolates real elevation (in metres above sea level) at any (lat, lon) inside an area
    using a Gaussian-smoothed SRTM30m grid (eliminating single-cell cliff-face spikes and
    conical tent artifacts along mountain switchbacks).
    """

    def __init__(self, elev_data: dict):
        self.bbox = elev_data["bbox"]  # [s, w, n, e]
        self.rows = elev_data["grid_rows"]
        self.cols = elev_data["grid_cols"]
        raw_grid = [list(map(float, row)) for row in elev_data["grid_elev_m"]]
        self.min_elev = float(elev_data["min_elev_m"])
        self.max_elev = float(elev_data["max_elev_m"])
        self.node_elev = {
            int(s["node_id"]): float(s["elev_m"])
            for s in elev_data.get("road_samples", [])
        }
        self.road_pts = [
            (float(s["lat"]), float(s["lon"]), float(s["elev_m"]))
            for s in elev_data.get("road_samples", [])
        ]

        # Blend road_samples gently into the grid and apply 3 Gaussian smoothing passes
        # so switchback roads on steep cliffs (Jebel Jais, Turini, Hakone) have smooth C1 relief
        s, w, n, e = self.bbox
        grid = [list(row) for row in raw_grid]
        for rlat, rlon, rev in self.road_pts:
            u = max(0.0, min(1.0, (rlat - s) / max(1e-9, n - s))) * (self.rows - 1)
            v = max(0.0, min(1.0, (rlon - w) / max(1e-9, e - w))) * (self.cols - 1)
            ri = min(self.rows - 1, max(0, int(round(u))))
            ci = min(self.cols - 1, max(0, int(round(v))))
            grid[ri][ci] = 0.75 * grid[ri][ci] + 0.25 * max(0.0, rev)

        for _ in range(3):
            nxt = [[0.0] * self.cols for _ in range(self.rows)]
            for r in range(self.rows):
                for c in range(self.cols):
                    acc = 0.0
                    wt = 0.0
                    for dr in (-1, 0, 1):
                        for dc in (-1, 0, 1):
                            rr = max(0, min(self.rows - 1, r + dr))
                            cc = max(0, min(self.cols - 1, c + dc))
                            wk = 4.0 if (dr == 0 and dc == 0) else (2.0 if (dr == 0 or dc == 0) else 1.0)
                            acc += wk * grid[rr][cc]
                            wt += wk
                    nxt[r][c] = acc / wt
            grid = nxt
        self.grid = grid

    def sample_grid(self, lat: float, lon: float) -> float:
        s, w, n, e = self.bbox
        u = max(0.0, min(1.0, (lat - s) / max(1e-9, n - s))) * (self.rows - 1)
        v = max(0.0, min(1.0, (lon - w) / max(1e-9, e - w))) * (self.cols - 1)
        r0 = min(self.rows - 2, int(math.floor(u)))
        c0 = min(self.cols - 2, int(math.floor(v)))
        du = u - r0
        dv = v - c0
        # Smoothstep C1 weights to eliminate bilinear grid crease lines
        su = du * du * (3.0 - 2.0 * du)
        sv = dv * dv * (3.0 - 2.0 * dv)
        h00 = self.grid[r0][c0]
        h01 = self.grid[r0][c0 + 1]
        h10 = self.grid[r0 + 1][c0]
        h11 = self.grid[r0 + 1][c0 + 1]
        h0 = h00 * (1.0 - sv) + h01 * sv
        h1 = h10 * (1.0 - sv) + h11 * sv
        return max(0.0, h0 * (1.0 - su) + h1 * su)

    def sample(self, lat: float, lon: float, node_id: int | None = None) -> float:
        return self.sample_grid(lat, lon)


def fetch_all_elevations(force: bool = False):
    results = {}
    for idx, (area_id, meta) in enumerate(AREAS.items(), 1):
        print(f"[{idx}/{len(AREAS)}] Elevation fetch for {area_id}...")
        results[area_id] = fetch_area_elevation(area_id, meta, force=force)
    print(f"Elevation fetch complete for all {len(AREAS)} areas.")
    return results


if __name__ == "__main__":
    force_flag = "--force" in sys.argv
    fetch_all_elevations(force=force_flag)
