#!/usr/bin/env python3
"""
tools/osm_fetch.py — OpenStreetMap Road, Building, Water, Landuse & POI Fetcher
Uses Python 3 standard library only (urllib, json, time, ssl, pathlib).

Attribution:
  Road data (c) OpenStreetMap contributors, ODbL (https://www.openstreetmap.org/copyright)

Queries https://overpass-api.de/api/interpreter politely (one query at a time,
sleeping between requests) and caches raw JSON responses in data/world/osm_cache/.
If the public Overpass API server is at capacity (HTTP 429/502/503/504 or timeout),
falls back automatically to the official OpenStreetMap API v0.6 JSON endpoint
(https://api.openstreetmap.org/api/0.6/map.json) with recursive bbox subdivision
and filters to the exact Overpass element set.
"""

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = ROOT / "data" / "world" / "osm_cache"

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OSM_MAP_JSON_URL = "https://api.openstreetmap.org/api/0.6/map.json"
USER_AGENT = "P1DriveOSMBuilder/2.0 (https://github.com/SHADOW-465; ODbL attribution in CREDITS.md)"

HIGHWAY_CLASSES = {
    "motorway", "trunk", "primary", "secondary", "tertiary", "residential",
    "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    "unclassified", "living_street", "service",
}

# Targeted v3 supplements: city-core service/living_street networks & Castillon D2566 link
V3_SUPPLEMENTS = {
    "turini_coast_link": (43.782, 7.442, 43.842, 7.468),
    "tokyo_ginza_c1": (35.656, 139.756, 35.672, 139.772),
    "tokyo_shibuya": (35.657, 139.698, 35.666, 139.714),
    "monaco": (43.731, 7.416, 43.743, 7.433),
    "dubai_downtown": (25.191, 55.268, 25.204, 55.284),
    "dubai_marina": (25.072, 55.134, 25.086, 55.150),
}

# Real-world bounding boxes: (south_lat, west_lon, north_lat, east_lon)
AREAS = {
    # Region 1: Tokyo, Hakone & Shonan
    "tokyo_ginza_c1": {
        "region": "tokyo_hakone",
        "description": "Central Tokyo slice: Ginza, Shiodome, Tokyo Tower, Shibaura Loop, Rainbow Bridge & Shuto C1 Loop",
        "bbox": (35.630, 139.735, 35.676, 139.776),
    },
    "tokyo_shibuya": {
        "region": "tokyo_hakone",
        "description": "Shibuya, Roppongi, Route 246 & Shuto Expressway Route 3 (Shibuya Line to C1 Tanimachi JCT)",
        "bbox": (35.654, 139.698, 35.670, 139.735),
    },
    "hakone": {
        "region": "tokyo_hakone",
        "description": "Hakone Turnpike, Ashinoko Skyline, Lake Ashi, Route 1 & Old Tokaido (Route 732 Nanamagari)",
        "bbox": (35.172, 138.980, 35.242, 139.110),
    },
    "shonan_coast": {
        "region": "tokyo_hakone",
        "description": "Shonan Coast Road (Route 134) from Enoshima to Kamakura along Sagami Bay",
        "bbox": (35.298, 139.475, 35.320, 139.555),
    },

    # Region 2: Monaco & Maritime Alps
    "monaco": {
        "region": "monaco_alps",
        "description": "Principality of Monaco: Port Hercule, Grand Prix street circuit, Tunnel Louis II, Casino, Corniches",
        "bbox": (43.723, 7.408, 43.755, 7.443),
    },
    "col_de_turini": {
        "region": "monaco_alps",
        "description": "Col de Turini (D2566) mountain pass, Peira-Cava, Moulinet & Bevera Gorge switchbacks to Sospel",
        "bbox": (43.875, 7.365, 43.988, 7.452),
    },
    "turini_coast_link": {
        "region": "monaco_alps",
        "description": "D2566 / D2204 link road from Sospel down to the Cote d'Azur coast at Monaco/Roquebrune",
        "bbox": (43.755, 7.410, 43.875, 7.458),
    },

    # Region 3: Dubai, Desert & Jebel Jais
    "dubai_downtown": {
        "region": "dubai_jais",
        "description": "Downtown Dubai & Business Bay slice with Sheikh Zayed Road (E11), Burj Khalifa & Financial Centre IC",
        "bbox": (25.180, 55.252, 25.215, 55.290),
    },
    "dubai_marina": {
        "region": "dubai_jais",
        "description": "Dubai Marina & JBR slice with Sheikh Zayed Road (E11), Marina lagoon & interchange loops",
        "bbox": (25.068, 55.130, 25.096, 55.162),
    },
    "dubai_desert": {
        "region": "dubai_jais",
        "description": "Dubai desert road stretch: Al Qudra Road (D63), E77 highway & Al Qudra oasis lakes",
        "bbox": (24.835, 55.300, 24.925, 55.410),
    },
    "jebel_jais": {
        "region": "dubai_jais",
        "description": "Jebel Jais mountain road in Ras Al Khaimah from Wadi Shehah base to Viewing Deck & summit ridge",
        "bbox": (25.885, 56.065, 25.958, 56.162),
    },
}


def build_overpass_query(bbox: tuple) -> str:
    s, w, n, e = bbox
    b_str = f"{s},{w},{n},{e}"
    hw_regex = "^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|(motorway|trunk|primary|secondary|tertiary)_link)$"
    return (
        f"[out:json][timeout:45][bbox:{b_str}];\n"
        f"(\n"
        f'  way["highway"~"{hw_regex}"];\n'
        f'  way["building"];\n'
        f'  way["natural"~"^(coastline|water|sand|beach|wood|scrub)$"];\n'
        f'  way["landuse"~"^(forest|park|grass|sand|basin|reservoir|recreation_ground)$"];\n'
        f'  way["leisure"~"^(park|garden|marina|nature_reserve)$"];\n'
        f'  way["waterway"~"^(river|canal|dock)$"];\n'
        f'  node["amenity"="fuel"];\n'
        f'  way["amenity"="fuel"];\n'
        f'  node["highway"="motorway_junction"];\n'
        f'  node["tourism"~"^(attraction|viewpoint|museum)$"];\n'
        f'  way["tourism"~"^(attraction|viewpoint|museum)$"];\n'
        f'  node["man_made"~"^(tower|bridge|lighthouse|pier)$"];\n'
        f'  way["man_made"~"^(tower|bridge|lighthouse|pier)$"];\n'
        f'  node["historic"];\n'
        f'  way["historic"];\n'
        f");\n"
        f"out body;\n"
        f">;\n"
        f"out skel qt;\n"
    )


_OVERPASS_FAIL_COUNT = 0


def try_overpass_fetch(bbox: tuple, timeout_s: int = 12) -> dict | None:
    global _OVERPASS_FAIL_COUNT
    if _OVERPASS_FAIL_COUNT >= 2:
        return None
    query = build_overpass_query(bbox)
    data = urllib.parse.urlencode({"data": query}).encode("utf-8")
    req = urllib.request.Request(
        OVERPASS_URL,
        data=data,
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw)
            if "elements" in parsed and len(parsed["elements"]) > 0:
                _OVERPASS_FAIL_COUNT = 0
                return parsed
    except Exception as exc:
        _OVERPASS_FAIL_COUNT += 1
        print(f"    [overpass-api.de] unavailable ({exc}); using OSM API v0.6 JSON fallback...")
    return None


def _is_relevant_way(tags: dict) -> bool:
    if not tags:
        return False
    hw = tags.get("highway")
    if hw in HIGHWAY_CLASSES:
        if hw == "service" and tags.get("service") in {"parking_aisle", "driveway", "emergency_access"}:
            return False
        return True
    if "building" in tags:
        return True
    if tags.get("natural") in {"coastline", "water", "sand", "beach", "wood", "scrub", "bay", "cape", "peak"}:
        return True
    if tags.get("landuse") in {"forest", "park", "grass", "sand", "basin", "reservoir", "recreation_ground"}:
        return True
    if tags.get("leisure") in {"park", "garden", "marina", "nature_reserve"}:
        return True
    if tags.get("waterway") in {"river", "canal", "dock"}:
        return True
    if tags.get("amenity") == "fuel":
        return True
    if tags.get("tourism") in {"attraction", "viewpoint", "museum"}:
        return True
    if tags.get("man_made") in {"tower", "bridge", "lighthouse", "pier"}:
        return True
    if "historic" in tags:
        return True
    return False


def _is_relevant_node(tags: dict) -> bool:
    if not tags:
        return False
    if tags.get("amenity") == "fuel":
        return True
    if tags.get("highway") in {"motorway_junction", "Mini_roundabout", "mini_roundabout", "turning_circle"}:
        return True
    if tags.get("tourism") in {"attraction", "viewpoint", "museum"}:
        return True
    if tags.get("man_made") in {"tower", "bridge", "lighthouse", "pier"}:
        return True
    if tags.get("natural") in {"peak", "saddle"}:
        return True
    if "historic" in tags:
        return True
    return False


def _fetch_osm_v06_tile(s: float, w: float, n: float, e: float, depth: int = 0) -> list:
    """
    Fetches OSM elements for (s, w, n, e) from https://api.openstreetmap.org/api/0.6/map.json.
    Automatically subdivides the bounding box into a 2x2 grid if the bbox exceeds the 50,000-node limit
    or if the span is larger than 0.045 deg in dense areas.
    """
    max_span = 0.055
    if (n - s > max_span or e - w > max_span) and depth < 3:
        mid_lat = 0.5 * (s + n)
        mid_lon = 0.5 * (w + e)
        out = []
        for sub_s, sub_w, sub_n, sub_e in [
            (s, w, mid_lat, mid_lon),
            (s, mid_lon, mid_lat, e),
            (mid_lat, w, n, mid_lon),
            (mid_lat, mid_lon, n, e),
        ]:
            out.extend(_fetch_osm_v06_tile(sub_s, sub_w, sub_n, sub_e, depth + 1))
        return out

    url = f"{OSM_MAP_JSON_URL}?bbox={w:.6f},{s:.6f},{e:.6f},{n:.6f}"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
    )
    try:
        time.sleep(1.0)
        with urllib.request.urlopen(req, timeout=35) as resp:
            raw = resp.read().decode("utf-8")
            data = json.loads(raw)
            return data.get("elements", [])
    except urllib.error.HTTPError as err:
        if err.code == 400 and depth < 4:
            # Exceeded 50,000 node limit in dense urban tile -> split 2x2
            mid_lat = 0.5 * (s + n)
            mid_lon = 0.5 * (w + e)
            print(f"    [osm-v0.6] Tile ({s:.3f},{w:.3f})->({n:.3f},{e:.3f}) >50k nodes; splitting 2x2...")
            out = []
            for sub_s, sub_w, sub_n, sub_e in [
                (s, w, mid_lat, mid_lon),
                (s, mid_lon, mid_lat, e),
                (mid_lat, w, n, mid_lon),
                (mid_lat, mid_lon, n, e),
            ]:
                out.extend(_fetch_osm_v06_tile(sub_s, sub_w, sub_n, sub_e, depth + 1))
            return out
        raise


def fetch_via_osm_v06(bbox: tuple) -> dict:
    s, w, n, e = bbox
    raw_elements = _fetch_osm_v06_tile(s, w, n, e)

    nodes_by_id = {}
    kept_ways = {}
    kept_poi_nodes = {}
    needed_node_ids = set()

    for el in raw_elements:
        etype = el.get("type")
        eid = el.get("id")
        if etype == "node":
            nodes_by_id[eid] = el
            tags = el.get("tags")
            if tags and _is_relevant_node(tags):
                kept_poi_nodes[eid] = el
        elif etype == "way":
            tags = el.get("tags")
            if tags and _is_relevant_way(tags):
                kept_ways[eid] = el
                for nid in el.get("nodes", ()):
                    needed_node_ids.add(nid)

    filtered_elements = []
    for wid, way in kept_ways.items():
        filtered_elements.append({
            "type": "way",
            "id": wid,
            "nodes": way.get("nodes", []),
            "tags": way.get("tags", {}),
        })

    all_node_ids = needed_node_ids | set(kept_poi_nodes.keys())
    for nid in sorted(all_node_ids):
        nd = nodes_by_id.get(nid)
        if not nd:
            continue
        entry = {
            "type": "node",
            "id": nid,
            "lat": round(float(nd["lat"]), 7),
            "lon": round(float(nd["lon"]), 7),
        }
        if "tags" in nd and _is_relevant_node(nd["tags"]):
            entry["tags"] = nd["tags"]
        filtered_elements.append(entry)

    return {
        "version": 0.6,
        "generator": "P1Drive tools/osm_fetch.py (OpenStreetMap ODbL)",
        "copyright": "Road data (c) OpenStreetMap contributors, ODbL",
        "elements": filtered_elements,
    }


def compact_overpass_response(data: dict) -> dict:
    """Keeps only necessary fields on ways/nodes so cached JSON stays compact."""
    elements = []
    for el in data.get("elements", []):
        etype = el.get("type")
        if etype == "way":
            elements.append({
                "type": "way",
                "id": el["id"],
                "nodes": el.get("nodes", []),
                "tags": el.get("tags", {}),
            })
        elif etype == "node":
            entry = {
                "type": "node",
                "id": el["id"],
                "lat": round(float(el["lat"]), 7),
                "lon": round(float(el["lon"]), 7),
            }
            if "tags" in el and _is_relevant_node(el["tags"]):
                entry["tags"] = el["tags"]
            elements.append(entry)
    return {
        "version": 0.6,
        "generator": data.get("generator", "Overpass API"),
        "copyright": "Road data (c) OpenStreetMap contributors, ODbL",
        "elements": elements,
    }


def fetch_all_areas(force: bool = False):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    summary = {}

    for idx, (area_id, meta) in enumerate(AREAS.items(), 1):
        cache_file = CACHE_DIR / f"{area_id}.json"
        bbox = meta["bbox"]
        if cache_file.exists() and not force:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            if area_id in V3_SUPPLEMENTS and not cached.get("v3_supplemented"):
                sup_bbox = V3_SUPPLEMENTS[area_id]
                print(f"    [v3-supplement] Fetching denser core/link OSM ways for {area_id} {sup_bbox}...")
                sup_data = fetch_via_osm_v06(sup_bbox)
                existing_ways = {e["id"] for e in cached.get("elements", []) if e.get("type") == "way"}
                existing_nodes = {e["id"] for e in cached.get("elements", []) if e.get("type") == "node"}
                added_w = 0
                for el in sup_data.get("elements", []):
                    if el.get("type") == "way" and el["id"] not in existing_ways:
                        cached["elements"].append(el)
                        existing_ways.add(el["id"])
                        added_w += 1
                    elif el.get("type") == "node" and el["id"] not in existing_nodes:
                        cached["elements"].append(el)
                        existing_nodes.add(el["id"])
                cached["v3_supplemented"] = True
                cache_file.write_text(json.dumps(cached, separators=(",", ":")), encoding="utf-8")
                print(f"    [v3-supplement] Added {added_w} ways to {area_id}.json")
            els = cached.get("elements", [])
            n_ways = sum(1 for e in els if e.get("type") == "way" and "highway" in e.get("tags", {}))
            n_blds = sum(1 for e in els if e.get("type") == "way" and "building" in e.get("tags", {}))
            print(f"[{idx}/{len(AREAS)}] Cached {area_id}: {len(els)} elements ({n_ways} highway ways, {n_blds} buildings)")
            summary[area_id] = {"elements": len(els), "highway_ways": n_ways, "buildings": n_blds}
            continue

        print(f"[{idx}/{len(AREAS)}] Fetching {area_id} {bbox} — {meta['description']}...")
        if idx > 1:
            time.sleep(2.0)

        data = try_overpass_fetch(bbox)
        if data is not None:
            data = compact_overpass_response(data)
        else:
            data = fetch_via_osm_v06(bbox)

        data["area_id"] = area_id
        data["region"] = meta["region"]
        data["bbox"] = list(bbox)
        data["description"] = meta["description"]

        cache_file.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
        els = data.get("elements", [])
        n_ways = sum(1 for e in els if e.get("type") == "way" and "highway" in e.get("tags", {}))
        n_blds = sum(1 for e in els if e.get("type") == "way" and "building" in e.get("tags", {}))
        size_kb = cache_file.stat().st_size / 1024.0
        print(f"    Saved {cache_file.name} ({size_kb:.1f} KB): {len(els)} elements ({n_ways} highway ways, {n_blds} buildings)")
        summary[area_id] = {"elements": len(els), "highway_ways": n_ways, "buildings": n_blds}

    total_bytes = sum(p.stat().st_size for p in CACHE_DIR.glob("*.json"))
    total_mb = total_bytes / (1024.0 * 1024.0)
    print(f"OSM fetch complete: {len(AREAS)} areas cached in {CACHE_DIR} ({total_mb:.2f} MB total).")
    return summary


if __name__ == "__main__":
    force_flag = "--force" in sys.argv
    fetch_all_areas(force=force_flag)
