#!/usr/bin/env python3
"""
tools/fetch_lofoten_landuse.py - landuse / forest / place polygons for the Lofoten world window.

Fetches (one request at a time, 2 s apart) the OSM objects that tools/bake_lofoten.py turns into the CITY and
FOREST biome planes:
    landuse = residential | commercial | retail | industrial | forest
    natural = wood
    place   = city | town | village | suburb
for the same window the Lofoten map uses (|x|, |z| <= 16384 m around lat 68.2085 / lon 13.90), split into
LAT_TILES x LON_TILES requests. Responses are cached in data/world/osm_cache_lofoten/landuse_NNN.json; an existing
valid cache file is never fetched again, so the script is resumable (re-run after a failure and it carries on).

Source order per tile (same as tools/osm_fetch.py): Overpass first, then the official OSM API v0.6 /map.json
(recursive bbox subdivision, filtered locally) when Overpass is busy / times out / answers with a runtime error.
A tile that fails on both is NOT written, so the next run retries it. Python 3 standard library only.

Attribution: Road data (c) OpenStreetMap contributors, ODbL (https://www.openstreetmap.org/copyright)
"""

import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import osm_fetch  # noqa: E402  (shared endpoints, user agent and the OSM API v0.6 tiling fallback)

ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = ROOT / "data" / "world" / "osm_cache_lofoten"

# --- world window (same projection as tools/bake_lofoten.py) --------------------------------------------------
CLAT, CLON = 68.2085, 13.90
HALF = 16384.0
KX = 111320.0 * math.cos(math.radians(CLAT))
KZ = 110574.0
MARGIN_DEG = 0.002  # ways just outside the window still matter for the blur at its edge
SOUTH = CLAT - HALF / KZ - MARGIN_DEG
NORTH = CLAT + HALF / KZ + MARGIN_DEG
WEST = CLON - HALF / KX - MARGIN_DEG
EAST = CLON + HALF / KX + MARGIN_DEG
LAT_TILES, LON_TILES = 3, 4

SLEEP_S = 2.0
OVERPASS_TIMEOUT_S = 120

LANDUSE = "residential|commercial|retail|industrial|forest"
PLACE = "city|town|village|suburb"
LANDUSE_SET = set(LANDUSE.split("|"))
PLACE_SET = set(PLACE.split("|"))


def tiles() -> list:
    out = []
    dlat = (NORTH - SOUTH) / LAT_TILES
    dlon = (EAST - WEST) / LON_TILES
    for r in range(LAT_TILES):
        for c in range(LON_TILES):
            out.append((SOUTH + r * dlat, WEST + c * dlon, SOUTH + (r + 1) * dlat, WEST + (c + 1) * dlon))
    return out


def query(bbox: tuple) -> str:
    s, w, n, e = bbox
    return (
        f"[out:json][timeout:90][bbox:{s:.6f},{w:.6f},{n:.6f},{e:.6f}];\n"
        f"(\n"
        f'  way["landuse"~"^({LANDUSE})$"];\n'
        f'  way["natural"="wood"];\n'
        f'  rel["landuse"~"^({LANDUSE})$"];\n'
        f'  rel["natural"="wood"];\n'
        f'  node["place"~"^({PLACE})$"];\n'
        f'  way["place"~"^({PLACE})$"];\n'
        f");\n"
        f"out body;\n>;\nout skel qt;\n"
    )


def relevant_tags(tags: dict) -> bool:
    if not tags:
        return False
    return tags.get("landuse") in LANDUSE_SET or tags.get("natural") == "wood" or tags.get("place") in PLACE_SET


def compact(elements: list) -> list:
    out = []
    for el in elements:
        t = el.get("type")
        if t == "node":
            entry = {"type": "node", "id": el["id"], "lat": round(float(el["lat"]), 7), "lon": round(float(el["lon"]), 7)}
            if el.get("tags") and relevant_tags(el["tags"]):
                entry["tags"] = {k: v for k, v in el["tags"].items() if k in ("place", "name", "landuse", "natural")}
            out.append(entry)
        elif t == "way":
            entry = {"type": "way", "id": el["id"], "nodes": el.get("nodes", [])}
            if el.get("tags"):
                entry["tags"] = {k: v for k, v in el["tags"].items() if k in ("landuse", "natural", "place", "name")}
            out.append(entry)
        elif t == "relation":
            out.append({
                "type": "relation", "id": el["id"],
                "members": [{"type": m["type"], "ref": m["ref"], "role": m.get("role", "")} for m in el.get("members", [])],
                "tags": {k: v for k, v in el.get("tags", {}).items() if k in ("type", "landuse", "natural", "name")},
            })
    return out


def overpass(bbox: tuple):
    """Elements list, or None when Overpass is unavailable / overloaded / reported a runtime error."""
    data = urllib.parse.urlencode({"data": query(bbox)}).encode("utf-8")
    req = urllib.request.Request(osm_fetch.OVERPASS_URL, data=data, headers={
        "User-Agent": osm_fetch.USER_AGENT,
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=OVERPASS_TIMEOUT_S) as resp:
            parsed = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # network error, HTTP 429/5xx, bad JSON
        print(f"    [overpass] unavailable ({exc})")
        return None
    remark = str(parsed.get("remark", ""))
    if "runtime error" in remark or "timed out" in remark:
        print(f"    [overpass] incomplete answer ({remark})")
        return None
    if "elements" not in parsed:
        return None
    return parsed["elements"]


def osm_api(bbox: tuple) -> list:
    """OSM API v0.6 fallback: tiles the bbox, then keeps only the objects Overpass would have returned."""
    s, w, n, e = bbox
    raw = osm_fetch._fetch_osm_v06_tile(s, w, n, e)
    seen, by_node, ways, rels = set(), {}, {}, {}
    for el in raw:
        key = (el.get("type"), el.get("id"))
        if key in seen:
            continue
        seen.add(key)
        t = el.get("type")
        if t == "node":
            by_node[el["id"]] = el
        elif t == "way":
            ways[el["id"]] = el
        elif t == "relation":
            rels[el["id"]] = el
    keep_rel = {i: r for i, r in rels.items() if relevant_tags(r.get("tags", {}))}
    member_ways = {m["ref"] for r in keep_rel.values() for m in r.get("members", []) if m.get("type") == "way"}
    keep_way = {i: wy for i, wy in ways.items() if relevant_tags(wy.get("tags", {})) or i in member_ways}
    need = {nid for wy in keep_way.values() for nid in wy.get("nodes", [])}
    keep_nodes = {i: nd for i, nd in by_node.items() if i in need or relevant_tags(nd.get("tags", {}))}
    return list(keep_rel.values()) + list(keep_way.values()) + [keep_nodes[i] for i in sorted(keep_nodes)]


def cache_ok(path: Path) -> bool:
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
        return isinstance(d.get("elements"), list) and d.get("complete") is True
    except Exception:
        return False


def main() -> int:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    todo = tiles()
    failed = []
    first_request = True
    for idx, bbox in enumerate(todo, 1):
        path = CACHE_DIR / f"landuse_{idx:03d}.json"
        if cache_ok(path):
            els = json.loads(path.read_text(encoding="utf-8"))["elements"]
            print(f"[{idx}/{len(todo)}] cached {path.name}: {len(els)} elements")
            continue
        print(f"[{idx}/{len(todo)}] fetching {path.name} bbox(s,w,n,e)=({bbox[0]:.4f},{bbox[1]:.4f},{bbox[2]:.4f},{bbox[3]:.4f})")
        if not first_request:
            time.sleep(SLEEP_S)
        first_request = False
        source = "overpass"
        elements = overpass(bbox)
        if elements is None:
            time.sleep(SLEEP_S)
            source = "osm-api"
            try:
                elements = osm_api(bbox)
            except Exception as exc:
                print(f"    [osm-api] failed ({exc}); tile left uncached, re-run to retry")
                failed.append(path.name)
                continue
        elements = compact(elements)
        out = {
            "version": 0.6,
            "copyright": "Road data (c) OpenStreetMap contributors, ODbL",
            "bbox": [round(v, 6) for v in bbox],
            "source": source,
            "complete": True,
            "elements": elements,
        }
        path.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
        n_way = sum(1 for e in elements if e["type"] == "way")
        n_rel = sum(1 for e in elements if e["type"] == "relation")
        n_place = sum(1 for e in elements if e["type"] == "node" and "place" in e.get("tags", {}))
        print(f"    saved {path.name} via {source}: {len(elements)} elements ({n_way} ways, {n_rel} relations, {n_place} place nodes)")
    if failed:
        print("INCOMPLETE, missing: " + ", ".join(failed))
        return 1
    print("landuse fetch complete: %d tiles in %s" % (len(todo), CACHE_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main())
