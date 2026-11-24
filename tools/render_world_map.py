#!/usr/bin/env python3
"""
tools/render_world_map.py — Horizon Triland v3 High-Resolution Realistic Atlas Map Renderer (PNG + SVG)
Uses Python 3 standard library only (zlib, struct, math, json, html, pathlib).

Attribution:
  Road data (c) OpenStreetMap contributors, ODbL

Renders a high-resolution cartographic atlas map (Google Maps / OSM Carto style):
  - Seamless country-wide hillshading with bilinear per-pixel interpolation (zero blocky pixels,
    zero rectangular region seams)
  - Subtle topographic elevation contour lines on mountain slopes
  - Full-resolution natural coastlines, ocean bathymetry shelves, bays, lakes, and canals
  - Parks, woodland, alpine forest polygons, and desert sand zones
  - Dense real OSM building footprints rendered as architectural rooftop polygons with outlines
  - Multi-pass Google Maps / OSM Carto road hierarchy with casings, bridges, and dashed tunnels
  - Readable haloed bitmap labels with strict bounding-box collision avoidance (skips overlaps)

Outputs:
  - docs/world_map.png        (3000 x 3000 px full country atlas map)
  - docs/world_map_tokyo.png  (1800 x 1800 px zoomed Tokyo, Hakone & Shonan map)
  - docs/world_map_monaco.png (1800 x 1800 px zoomed Monaco & Col de Turini map)
  - docs/world_map_dubai.png  (1800 x 1800 px zoomed Dubai, Desert & Jebel Jais map)
  - docs/world_map.svg        (Atlas-styled vector map)
"""

import html
import json
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COUNTRY_PATH = ROOT / "data" / "world" / "country.json"
REGIONS_DIR = ROOT / "data" / "world" / "regions"
DOCS_DIR = ROOT / "docs"

# ---------------------------------------------------------------------------
# 5x7 Clean Bitmap Font (ASCII 32..90 + symbols)
# ---------------------------------------------------------------------------
FONT_5X7 = {
    " ": (0, 0, 0, 0, 0, 0, 0),
    "!": (4, 4, 4, 4, 4, 0, 4),
    '"': (10, 10, 0, 0, 0, 0, 0),
    "#": (10, 31, 10, 10, 31, 10, 0),
    "&": (12, 18, 20, 8, 21, 18, 13),
    "'": (4, 4, 0, 0, 0, 0, 0),
    "(": (2, 4, 8, 8, 8, 4, 2),
    ")": (8, 4, 2, 2, 2, 4, 8),
    "*": (0, 4, 21, 14, 21, 4, 0),
    "+": (0, 4, 4, 31, 4, 4, 0),
    ",": (0, 0, 0, 0, 4, 4, 8),
    "-": (0, 0, 0, 31, 0, 0, 0),
    ".": (0, 0, 0, 0, 0, 0, 4),
    "/": (1, 2, 2, 4, 8, 8, 16),
    "0": (14, 17, 19, 21, 25, 17, 14),
    "1": (4, 12, 4, 4, 4, 4, 14),
    "2": (14, 17, 1, 6, 8, 16, 31),
    "3": (31, 2, 4, 6, 1, 17, 14),
    "4": (2, 6, 10, 18, 31, 2, 2),
    "5": (31, 16, 30, 1, 1, 17, 14),
    "6": (6, 8, 16, 30, 17, 17, 14),
    "7": (31, 1, 2, 4, 8, 8, 8),
    "8": (14, 17, 17, 14, 17, 17, 14),
    "9": (14, 17, 17, 15, 1, 2, 12),
    ":": (0, 4, 0, 0, 0, 4, 0),
    "A": (14, 17, 17, 31, 17, 17, 17),
    "B": (30, 17, 17, 30, 17, 17, 30),
    "C": (14, 17, 16, 16, 16, 17, 14),
    "D": (28, 18, 17, 17, 17, 18, 28),
    "E": (31, 16, 16, 30, 16, 16, 31),
    "F": (31, 16, 16, 30, 16, 16, 16),
    "G": (14, 17, 16, 23, 17, 17, 15),
    "H": (17, 17, 17, 31, 17, 17, 17),
    "I": (14, 4, 4, 4, 4, 4, 14),
    "J": (7, 2, 2, 2, 2, 18, 12),
    "K": (17, 18, 20, 24, 20, 18, 17),
    "L": (16, 16, 16, 16, 16, 16, 31),
    "M": (17, 27, 21, 21, 17, 17, 17),
    "N": (17, 25, 21, 19, 17, 17, 17),
    "O": (14, 17, 17, 17, 17, 17, 14),
    "P": (30, 17, 17, 30, 16, 16, 16),
    "Q": (14, 17, 17, 17, 21, 18, 13),
    "R": (30, 17, 17, 30, 20, 18, 17),
    "S": (15, 16, 16, 14, 1, 1, 30),
    "T": (31, 4, 4, 4, 4, 4, 4),
    "U": (17, 17, 17, 17, 17, 17, 14),
    "V": (17, 17, 17, 17, 17, 10, 4),
    "W": (17, 17, 17, 21, 21, 21, 10),
    "X": (17, 17, 10, 4, 10, 17, 17),
    "Y": (17, 17, 10, 4, 4, 4, 4),
    "Z": (31, 1, 2, 4, 8, 16, 31),
    "_": (0, 0, 0, 0, 0, 0, 31),
}


def write_png_rgb(path: Path, width: int, height: int, rgb_buf: bytearray):
    """Writes an 8-bit RGB bytearray (width * height * 3) to a PNG file using stdlib zlib."""
    def make_chunk(chunk_type: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(chunk_type)
        crc = zlib.crc32(data, crc) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    row_bytes = width * 3
    mv = memoryview(rgb_buf)
    raw_rows = b"".join(b"\x00" + bytes(mv[y * row_bytes : (y + 1) * row_bytes]) for y in range(height))
    compressed = zlib.compress(raw_rows, level=6)

    png_bytes = (
        b"\x89PNG\r\n\x1a\n"
        + make_chunk(b"IHDR", ihdr)
        + make_chunk(b"IDAT", compressed)
        + make_chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png_bytes)


class AtlasCanvas:
    def __init__(self, width: int, height: int, wx_min: float, wz_min: float, wx_max: float, wz_max: float):
        self.w = width
        self.h = height
        self.wx_min = wx_min
        self.wz_min = wz_min
        self.wx_max = wx_max
        self.wz_max = wz_max
        self.wx_span = max(1.0, wx_max - wx_min)
        self.wz_span = max(1.0, wz_max - wz_min)
        self.buf = bytearray(width * height * 3)
        self.placed_labels = []  # list of (x0, y0, x1, y1)

    def w_to_px(self, wx: float, wz: float) -> tuple[float, float]:
        px = ((wx - self.wx_min) / self.wx_span) * self.w
        py = ((wz - self.wz_min) / self.wz_span) * self.h
        return px, py

    def px_to_w(self, px: float, py: float) -> tuple[float, float]:
        wx = self.wx_min + (px / self.w) * self.wx_span
        wz = self.wz_min + (py / self.h) * self.wz_span
        return wx, wz

    def fill_rect(self, x0: int, y0: int, x1: int, y1: int, rgb: tuple[int, int, int]):
        w, h = self.w, self.h
        xa = max(0, min(w, int(x0)))
        xb = max(0, min(w, int(x1)))
        ya = max(0, min(h, int(y0)))
        yb = max(0, min(h, int(y1)))
        if xb <= xa or yb <= ya:
            return
        span = bytes(rgb) * (xb - xa)
        row_b = w * 3
        a3 = xa * 3
        b3 = xb * 3
        buf = self.buf
        for y in range(ya, yb):
            off = y * row_b
            buf[off + a3 : off + b3] = span

    def fill_polygon(self, poly_px: list[tuple[float, float]], rgb: tuple[int, int, int]):
        n = len(poly_px)
        if n < 3:
            return
        w, h = self.w, self.h
        ys = [p[1] for p in poly_px]
        ya = max(0, int(math.floor(min(ys))))
        yb = min(h - 1, int(math.ceil(max(ys))))
        if yb < ya:
            return
        color_bytes = bytes(rgb)
        row_b = w * 3
        buf = self.buf
        for y in range(ya, yb + 1):
            yf = y + 0.5
            x_ints = []
            j = n - 1
            for i in range(n):
                xi, yi = poly_px[i]
                xj, yj = poly_px[j]
                if (yi <= yf < yj) or (yj <= yf < yi):
                    x_int = xi + (yf - yi) * (xj - xi) / (yj - yi)
                    x_ints.append(x_int)
                j = i
            if len(x_ints) < 2:
                continue
            x_ints.sort()
            for k in range(0, len(x_ints) - 1, 2):
                xa = max(0, min(w, int(round(x_ints[k]))))
                xb = max(0, min(w, int(round(x_ints[k + 1]))))
                if xb > xa:
                    off = y * row_b
                    buf[off + xa * 3 : off + xb * 3] = color_bytes * (xb - xa)

    def fill_circle(self, cx: float, cy: float, r: float, rgb: tuple[int, int, int]):
        w, h = self.w, self.h
        ya = max(0, int(math.floor(cy - r)))
        yb = min(h - 1, int(math.ceil(cy + r)))
        r2 = r * r
        color_bytes = bytes(rgb)
        row_b = w * 3
        buf = self.buf
        for y in range(ya, yb + 1):
            dy = y - cy
            rem = r2 - dy * dy
            if rem < 0.0:
                continue
            dx = math.sqrt(rem)
            xa = max(0, min(w, int(round(cx - dx))))
            xb = max(0, min(w, int(round(cx + dx))))
            if xb > xa:
                off = y * row_b
                buf[off + xa * 3 : off + xb * 3] = color_bytes * (xb - xa)

    def draw_segment(self, x0: float, y0: float, x1: float, y1: float, radius: float, rgb: tuple[int, int, int]):
        w, h = self.w, self.h
        if max(x0, x1) + radius < 0 or min(x0, x1) - radius >= w:
            return
        if max(y0, y1) + radius < 0 or min(y0, y1) - radius >= h:
            return
        dx = x1 - x0
        dy = y1 - y0
        seg_len = math.hypot(dx, dy)
        step = max(0.65, radius * 0.42)
        steps = max(1, int(math.ceil(seg_len / step)))
        ir = max(1, int(round(radius)))
        r2 = radius * radius
        spans = []
        for sy_off in range(-ir, ir + 1):
            rem = r2 - sy_off * sy_off
            if rem >= 0:
                sx_half = int(round(math.sqrt(rem)))
                spans.append((sy_off, -sx_half, sx_half + 1, bytes(rgb) * (2 * sx_half + 1)))

        row_b = w * 3
        buf = self.buf
        cbytes = bytes(rgb)
        for k in range(steps + 1):
            u = k / steps
            cx = int(round(x0 + dx * u))
            cy = int(round(y0 + dy * u))
            for sy_off, dx0, dx1, span_b in spans:
                py = cy + sy_off
                if 0 <= py < h:
                    xa = cx + dx0
                    xb = cx + dx1
                    if 0 <= xa and xb <= w:
                        off = py * row_b
                        buf[off + xa * 3 : off + xb * 3] = span_b
                    else:
                        xa_c = max(0, min(w, xa))
                        xb_c = max(0, min(w, xb))
                        if xb_c > xa_c:
                            off = py * row_b
                            buf[off + xa_c * 3 : off + xb_c * 3] = cbytes * (xb_c - xa_c)

    def draw_polyline(self, pts_px: list[tuple[float, float]], width_px: float, rgb: tuple[int, int, int], dashed: bool = False):
        if len(pts_px) < 2:
            return
        radius = max(0.55, width_px * 0.5)
        for i in range(len(pts_px) - 1):
            if dashed and (i % 2 == 1):
                continue
            p0 = pts_px[i]
            p1 = pts_px[i + 1]
            self.draw_segment(p0[0], p0[1], p1[0], p1[1], radius, rgb)

    def _draw_raw_text(self, x: int, y: int, text: str, scale: int, rgb: tuple[int, int, int]):
        w, h = self.w, self.h
        row_b = w * 3
        buf = self.buf
        cbytes = bytes(rgb) * scale
        cur_x = x
        for ch in text.upper():
            glyph = FONT_5X7.get(ch, FONT_5X7.get(" "))
            for r_idx, row_bits in enumerate(glyph):
                if row_bits == 0:
                    continue
                for c_idx in range(5):
                    if (row_bits >> (4 - c_idx)) & 1:
                        px0 = cur_x + c_idx * scale
                        px1 = px0 + scale
                        if px0 < 0 or px1 > w:
                            continue
                        for sy in range(scale):
                            py = y + r_idx * scale + sy
                            if 0 <= py < h:
                                off = py * row_b
                                buf[off + px0 * 3 : off + px1 * 3] = cbytes
            cur_x += 6 * scale

    def try_place_label(
        self,
        anchor_x: float,
        anchor_y: float,
        text: str,
        scale: int = 2,
        fg_rgb: tuple[int, int, int] = (30, 41, 59),
        halo_rgb: tuple[int, int, int] = (252, 250, 245),
        offsets: list[tuple[int, int]] | None = None,
        force: bool = False,
    ) -> bool:
        translit = str.maketrans({
            "Ô": "O", "Ó": "O", "Ò": "O", "Ö": "O", "Ō": "O",
            "É": "E", "È": "E", "Ê": "E", "Ë": "E",
            "À": "A", "Â": "A", "Ä": "A", "Á": "A", "Ā": "A",
            "Î": "I", "Ï": "I", "Í": "I",
            "Û": "U", "Ü": "U", "Ù": "U", "Ū": "U",
            "Ç": "C", "Ñ": "N",
            "•": "-", "—": "-", "–": "-",
        })
        norm = text.upper().translate(translit)
        # Keep only ASCII characters present in FONT_5X7
        clean = "".join(ch if ch in FONT_5X7 else " " for ch in norm).strip()
        while "  " in clean:
            clean = clean.replace("  ", " ")
        # Skip labels that stripped to empty or pure punctuation
        if not clean or not any(c.isalnum() for c in clean):
            return False
        tw = len(clean) * 6 * scale
        th = 7 * scale
        if offsets is None:
            offsets = [
                (9, -th // 2),
                (-tw // 2, -th - 8),
                (-tw // 2, 10),
                (-tw - 9, -th // 2),
                (12, -th - 7),
                (12, 9),
                (-tw - 10, -th - 7),
                (-tw - 10, 9),
            ]
        pad = 5 * scale
        for ox, oy in offsets:
            lx = int(round(anchor_x + ox))
            ly = int(round(anchor_y + oy))
            bx0, by0, bx1, by1 = lx - pad, ly - pad, lx + tw + pad, ly + th + pad
            if not force:
                if bx0 < 14 or by0 < 68 or bx1 >= self.w - 14 or by1 >= self.h - 68:
                    continue
                collision = False
                for ex0, ey0, ex1, ey1 in self.placed_labels:
                    if not (bx1 < ex0 or ex1 < bx0 or by1 < ey0 or ey1 < by0):
                        collision = True
                        break
                if collision:
                    continue
            self.placed_labels.append((bx0, by0, bx1, by1))
            h_step = max(1, scale // 2)
            for hx in (-h_step, 0, h_step):
                for hy in (-h_step, 0, h_step):
                    if hx != 0 or hy != 0:
                        self._draw_raw_text(lx + hx, ly + hy, clean, scale, halo_rgb)
            self._draw_raw_text(lx, ly, clean, scale, fg_rgb)
            return True
        return False


def _cubic(p0, p1, p2, p3, t):
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)))


def _sample_continuous_elevation(wx: float, wz: float, country: dict, regions: dict) -> float:
    """Bicubic (Catmull-Rom) sample of the single country heightfield: C1-smooth, no region boxes, no grid lattice."""
    hf = country.get("terrain", {}).get("heightfield")
    if not hf:
        return 24.0
    rows, cols, vals = hf["rows"], hf["cols"], hf["values_m"]
    bmin, bmax = hf["bounds_m"]["min"], hf["bounds_m"]["max"]
    u = max(0.0, min(1.0, (wz - bmin[1]) / (bmax[1] - bmin[1]))) * (rows - 1)
    v = max(0.0, min(1.0, (wx - bmin[0]) / (bmax[0] - bmin[0]))) * (cols - 1)
    r0 = min(rows - 2, int(u))
    c0 = min(cols - 2, int(v))
    du, dv = u - r0, v - c0
    cs = [max(0, min(cols - 1, c0 + k)) for k in (-1, 0, 1, 2)]
    col_vals = []
    for dr in (-1, 0, 1, 2):
        row = vals[max(0, min(rows - 1, r0 + dr))]
        col_vals.append(_cubic(row[cs[0]], row[cs[1]], row[cs[2]], row[cs[3]], dv))
    return _cubic(*col_vals, du)


def render_smooth_hillshaded_land(canvas: AtlasCanvas, country: dict, regions: dict, grid_steps: int = 600):
    """
    Computes continuous elevation, hypsometric biome tint, analytical NW-sun hillshading,
    and subtle topographic contour lines on a `grid_steps x grid_steps` grid, and then
    bilinearly interpolates RGB across every pixel of the canvas so there are ZERO blocky pixels!
    """
    w, h = canvas.w, canvas.h
    # Choose grid_steps that divides canvas dimensions cleanly (e.g. 600 for 3000px -> step=5, 450 for 1800px -> step=4)
    step_px = 5 if w == 3000 else 4
    gw = w // step_px + 1
    gh = h // step_px + 1

    elev_g = [[0.0] * gw for _ in range(gh)]
    for r in range(gh):
        py = r * step_px
        for c in range(gw):
            px = c * step_px
            wx, wz = canvas.px_to_w(px, py)
            elev_g[r][c] = max(0.0, _sample_continuous_elevation(wx, wz, country, regions))

    # 2 gentle smoothing passes on elev_g for silky-smooth surface normals
    for _ in range(2):
        nxt = [[0.0] * gw for _ in range(gh)]
        for r in range(gh):
            rm1 = max(0, r - 1)
            rp1 = min(gh - 1, r + 1)
            for c in range(gw):
                cm1 = max(0, c - 1)
                cp1 = min(gw - 1, c + 1)
                nxt[r][c] = (
                    4.0 * elev_g[r][c]
                    + 2.0 * (elev_g[rm1][c] + elev_g[rp1][c] + elev_g[r][cm1] + elev_g[r][cp1])
                    + (elev_g[rm1][cm1] + elev_g[rm1][cp1] + elev_g[rp1][cm1] + elev_g[rp1][cp1])
                ) / 16.0
        elev_g = nxt

    cell_dx_m = (canvas.wx_span / w) * step_px
    cell_dz_m = (canvas.wz_span / h) * step_px
    # Sun vector from NW (azimuth 315 deg, altitude 44 deg)
    lx, ly, lz = -0.51, 0.69, -0.51

    grid_r = [[0] * gw for _ in range(gh)]
    grid_g = [[0] * gw for _ in range(gh)]
    grid_b = [[0] * gw for _ in range(gh)]

    for r in range(gh):
        py = r * step_px
        rm1 = max(0, r - 1)
        rp1 = min(gh - 1, r + 1)
        for c in range(gw):
            px = c * step_px
            wx, wz = canvas.px_to_w(px, py)
            ev = elev_g[r][c]
            cm1 = max(0, c - 1)
            cp1 = min(gw - 1, c + 1)
            dedx = (elev_g[r][cp1] - elev_g[r][cm1]) / (2.0 * cell_dx_m)
            dedz = (elev_g[rp1][c] - elev_g[rm1][c]) / (2.0 * cell_dz_m)
            slope_mag = math.hypot(dedx, dedz)

            nx = -dedx * 2.5
            ny = 1.0
            nz = -dedz * 2.5
            nlen = math.sqrt(nx * nx + ny * ny + nz * nz)
            shade = (nx * lx + ny * ly + nz * lz) / nlen
            mult = max(0.76, min(1.12, 0.95 + (shade - 0.69) * 0.58))

            # Continuous latitude/elevation biome color blend (zero discrete biome jumps!)
            # Southern desert influence (smoothly ramps in for wz > 2200)
            t_south = max(0.0, min(1.0, (wz - 2200.0) / 3600.0))
            w_desert = t_south * t_south * (3.0 - 2.0 * t_south)

            # Temperate/Northern hypsometric ramp:
            # Lowland (< 90m): warm OSM Carto cream (242, 239, 231)
            # Foothill/Forest (90..580m): lush sage-green (202, 226, 184)
            # Alpine (> 580m): warm alpine rock/buff (220, 215, 205)
            t_forest = max(0.0, min(1.0, (ev - 65.0) / 220.0))
            t_forest = t_forest * t_forest * (3.0 - 2.0 * t_forest)
            t_alpine = max(0.0, min(1.0, (ev - 580.0) / 480.0))
            t_alpine = t_alpine * t_alpine * (3.0 - 2.0 * t_alpine)

            nr_c = 242.0 * (1.0 - t_forest) + 201.0 * t_forest
            ng_c = 239.0 * (1.0 - t_forest) + 225.0 * t_forest
            nb_c = 231.0 * (1.0 - t_forest) + 185.0 * t_forest

            nr_c = nr_c * (1.0 - t_alpine) + 222.0 * t_alpine
            ng_c = ng_c * (1.0 - t_alpine) + 216.0 * t_alpine
            nb_c = nb_c * (1.0 - t_alpine) + 206.0 * t_alpine

            # Southern desert & Hajar / Jebel Jais canyon hypsometric ramp:
            # Desert plain (< 110m): warm sand (244, 231, 202)
            # Hajar canyon slopes (> 110m): warm terracotta-ochre (224, 198, 168)
            t_canyon = max(0.0, min(1.0, (ev - 85.0) / 260.0))
            t_canyon = t_canyon * t_canyon * (3.0 - 2.0 * t_canyon)
            sr_c = 244.0 * (1.0 - t_canyon) + 224.0 * t_canyon
            sg_c = 231.0 * (1.0 - t_canyon) + 198.0 * t_canyon
            sb_c = 202.0 * (1.0 - t_canyon) + 168.0 * t_canyon

            base_r = nr_c * (1.0 - w_desert) + sr_c * w_desert
            base_g = ng_c * (1.0 - w_desert) + sg_c * w_desert
            base_b = nb_c * (1.0 - w_desert) + sb_c * w_desert

            # Subtle topographic contour lines every 125m on mountain slopes
            if ev > 120.0 and slope_mag > 0.025:
                rem_c = (ev % 125.0) / 125.0
                dist_c = min(rem_c, 1.0 - rem_c) * 125.0
                contour_w = max(3.5, slope_mag * cell_dx_m * 0.65)
                if dist_c < contour_w:
                    c_strength = 0.08 * (1.0 - dist_c / contour_w)
                    mult *= (1.0 - c_strength)

            grid_r[r][c] = max(0, min(255, int(base_r * mult)))
            grid_g[r][c] = max(0, min(255, int(base_g * mult)))
            grid_b[r][c] = max(0, min(255, int(base_b * mult)))

    # Bilinearly interpolate (grid_r, grid_g, grid_b) across all w x h pixels
    h_rows_r = []
    h_rows_g = []
    h_rows_b = []
    inv_step = 1.0 / step_px
    for r in range(gh):
        rr_row = grid_r[r]
        gg_row = grid_g[r]
        bb_row = grid_b[r]
        exp_r = [0] * w
        exp_g = [0] * w
        exp_b = [0] * w
        for c in range(gw - 1):
            r0, g0, b0 = rr_row[c], gg_row[c], bb_row[c]
            dr = (rr_row[c + 1] - r0) * inv_step
            dg = (gg_row[c + 1] - g0) * inv_step
            db = (bb_row[c + 1] - b0) * inv_step
            base_x = c * step_px
            for k in range(step_px):
                if base_x + k < w:
                    exp_r[base_x + k] = int(r0 + dr * k)
                    exp_g[base_x + k] = int(g0 + dg * k)
                    exp_b[base_x + k] = int(b0 + db * k)
        h_rows_r.append(exp_r)
        h_rows_g.append(exp_g)
        h_rows_b.append(exp_b)

    row_b = w * 3
    buf = canvas.buf
    for r in range(gh - 1):
        r0_list, g0_list, b0_list = h_rows_r[r], h_rows_g[r], h_rows_b[r]
        r1_list, g1_list, b1_list = h_rows_r[r + 1], h_rows_g[r + 1], h_rows_b[r + 1]
        base_y = r * step_px
        for ky in range(step_px):
            py = base_y + ky
            if py >= h:
                break
            wy1 = ky * inv_step
            wy0 = 1.0 - wy1
            row_ba = bytearray(row_b)
            row_ba[0::3] = [int(a * wy0 + b * wy1) for a, b in zip(r0_list, r1_list)]
            row_ba[1::3] = [int(a * wy0 + b * wy1) for a, b in zip(g0_list, g1_list)]
            row_ba[2::3] = [int(a * wy0 + b * wy1) for a, b in zip(b0_list, b1_list)]
            off = py * row_b
            buf[off : off + row_b] = row_ba


def render_atlas_view(
    out_path: Path,
    country: dict,
    regions: dict,
    width: int,
    height: int,
    wx_min: float,
    wz_min: float,
    wx_max: float,
    wz_max: float,
    title: str,
    subtitle: str,
    is_zoomed: bool = False,
):
    canvas = AtlasCanvas(width, height, wx_min, wz_min, wx_max, wz_max)

    # 1. Smooth Per-Pixel Hillshaded Land Base (Zero blocky pixels, zero rectangular edges!)
    render_smooth_hillshaded_land(canvas, country, regions)

    # 2. Landuse Zones (Forest, Park, Sand/Beach) from real OSM polygons
    for rid, rdata in regions.items():
        terrain = rdata.get("terrain", {})
        for lz in terrain.get("landuse_zones", []):
            pts_px = [canvas.w_to_px(p[0], p[1]) for p in lz.get("polygon", [])]
            kind = lz.get("kind", "park")
            if kind in ("forest", "wood"):
                canvas.fill_polygon(pts_px, (184, 218, 168))
            elif kind in ("park", "grass", "garden"):
                canvas.fill_polygon(pts_px, (204, 234, 178))
            elif kind in ("sand", "desert", "beach"):
                canvas.fill_polygon(pts_px, (245, 229, 194))

    # 3. Full-Resolution Natural Country Sea Polygons, Bathymetry Shelves & Inland Water
    for sp in country.get("terrain", {}).get("sea_polygons", []):
        pts_px = [canvas.w_to_px(p[0], p[1]) for p in sp.get("polygon", [])]
        if len(pts_px) >= 3:
            closed_px = pts_px + [pts_px[0]]
            # Sandy foreshore halo
            canvas.draw_polyline(closed_px, 8.0 if not is_zoomed else 12.0, (244, 231, 198))
            # Deep ocean cartographic blue fill
            canvas.fill_polygon(pts_px, (154, 205, 240))
            # Shallow coastal turquoise water shelf & crisp shoreline casing
            canvas.draw_polyline(closed_px, 9.0 if not is_zoomed else 14.0, (176, 219, 247))
            canvas.draw_polyline(closed_px, 4.5 if not is_zoomed else 7.0, (192, 228, 250))
            canvas.draw_polyline(closed_px, 1.8 if not is_zoomed else 2.4, (98, 158, 204))

    for rid, rdata in regions.items():
        terrain = rdata.get("terrain", {})
        for wp in terrain.get("water_polygons", []):
            pts_px = [canvas.w_to_px(p[0], p[1]) for p in wp.get("polygon", [])]
            if len(pts_px) >= 3:
                canvas.fill_polygon(pts_px, (164, 212, 246))
                canvas.draw_polyline(pts_px + [pts_px[0]], 1.5, (104, 164, 210))

        for cl in terrain.get("coastlines", []):
            pts_px = [canvas.w_to_px(p[0], p[1]) for p in cl.get("points", [])]
            canvas.draw_polyline(pts_px, 1.6 if not is_zoomed else 2.2, (94, 154, 200))

    # 4. City Blocks & Dense Real OSM Building Footprints
    for rid, rdata in regions.items():
        for blk in rdata.get("city_blocks", []):
            b_px = [canvas.w_to_px(p[0], p[1]) for p in blk.get("polygon", [])]
            canvas.fill_polygon(b_px, (234, 229, 221))
            for fp in blk.get("footprints", []):
                fp_px = [canvas.w_to_px(p[0], p[1]) for p in fp.get("poly", [])]
                h_m = fp.get("height_m", 20.0)
                fill_c = (188, 182, 173) if h_m > 45.0 else (208, 202, 194)
                canvas.fill_polygon(fp_px, fill_c)
                if is_zoomed and len(fp_px) >= 3:
                    canvas.draw_polyline(fp_px + [fp_px[0]], 0.9, (162, 156, 147))

    # 5. Multi-Pass Google Maps / OSM Carto Road Hierarchy (Casing + Fill)
    scale_mult = 1.65 if is_zoomed else 1.0
    road_styles = {
        "street": {
            "casing": (184, 178, 168),
            "fill": (255, 255, 255),
            "c_w": 3.2 * scale_mult,
            "f_w": 1.9 * scale_mult,
        },
        "mountain": {
            "casing": (168, 134, 54),
            "fill": (253, 232, 128),
            "c_w": 4.8 * scale_mult,
            "f_w": 3.0 * scale_mult,
        },
        "arterial": {
            "casing": (180, 122, 38),
            "fill": (252, 211, 86),
            "c_w": 5.8 * scale_mult,
            "f_w": 3.8 * scale_mult,
        },
        "motorway": {
            "casing": (136, 40, 20),
            "fill": (236, 112, 80),
            "c_w": 7.6 * scale_mult,
            "f_w": 5.0 * scale_mult,
        },
    }

    for rclass in ("street", "mountain", "arterial", "motorway"):
        st = road_styles[rclass]
        # Pass A: Casing
        for rid, rdata in regions.items():
            for r in rdata.get("roads", []):
                if r.get("road_class") != rclass:
                    continue
                pts_px = [canvas.w_to_px(p[0], p[2]) for p in r["control_points"]]
                canvas.draw_polyline(pts_px, st["c_w"], st["casing"], dashed=bool(r.get("tunnel")))
        if rclass == "motorway":
            for m in country.get("motorways", []):
                pts_px = [canvas.w_to_px(p[0], p[2]) for p in m["control_points"]]
                canvas.draw_polyline(pts_px, 8.6 * (1.25 if is_zoomed else 1.0), st["casing"])

        # Pass B: Fill
        for rid, rdata in regions.items():
            for r in rdata.get("roads", []):
                if r.get("road_class") != rclass:
                    continue
                pts_px = [canvas.w_to_px(p[0], p[2]) for p in r["control_points"]]
                canvas.draw_polyline(pts_px, st["f_w"], st["fill"], dashed=bool(r.get("tunnel")))
        if rclass == "motorway":
            for m in country.get("motorways", []):
                pts_px = [canvas.w_to_px(p[0], p[2]) for p in m["control_points"]]
                canvas.draw_polyline(pts_px, 5.8 * (1.25 if is_zoomed else 1.0), (234, 108, 76))
                # Subtle bright median highlight on motorways
                canvas.draw_polyline(pts_px, 1.3 * (1.25 if is_zoomed else 1.0), (253, 186, 116))

    # 6. Markers & Strict Non-Overlapping Labels (NO rectangular region boxes!)
    lbl_scale = 2

    # Organic cartographic region titles on full country map (placed like state/province headers)
    if not is_zoomed:
        region_headers = [
            (-8400.0, -14200.0, "COTE D'AZUR & MARITIME ALPS"),
            (6200.0, -12800.0, "KANTO NEON, HAKONE & SHONAN"),
            (-2800.0, 14200.0, "MIRAGE SKYLINE, AL QUDRA & JEBEL JAIS"),
            (-5200.0, 2100.0, "AZUR-MIRAGE GULF"),
            (13200.0, 2800.0, "SAGAMI & TOKYO BAY"),
        ]
        for wx_h, wz_h, h_txt in region_headers:
            px, py = canvas.w_to_px(wx_h, wz_h)
            is_water_lbl = "GULF" in h_txt or "BAY" in h_txt
            canvas.try_place_label(
                px,
                py,
                h_txt,
                scale=2 if is_water_lbl else 3,
                fg_rgb=(42, 98, 148) if is_water_lbl else (30, 48, 78),
                halo_rgb=(196, 228, 250) if is_water_lbl else (248, 246, 240),
                offsets=[(-len(h_txt) * 6, 0)],
            )

    # Interchanges
    for ic in country.get("interchanges", []):
        ix, _, iz = ic["position"]
        px, py = canvas.w_to_px(ix, iz)
        if 0 <= px < width and 0 <= py < height:
            canvas.fill_circle(px, py, 7.5, (136, 40, 20))
            canvas.fill_circle(px, py, 5.0, (254, 240, 138))
            canvas.try_place_label(
                px, py, f"{ic['id']} {ic['type']}", scale=lbl_scale, fg_rgb=(124, 45, 18)
            )

    # Motorway shields (collision-checked so they never overlap interchange labels)
    for m in country.get("motorways", []):
        pts = m["control_points"]
        for frac in (0.26, 0.72):
            mp = pts[int(len(pts) * frac)]
            px, py = canvas.w_to_px(mp[0], mp[2])
            if 30 <= px < width - 30 and 75 <= py < height - 85:
                if canvas.try_place_label(
                    px, py, f"[{m['id']}]", scale=2, fg_rgb=(136, 40, 20), halo_rgb=(254, 243, 199), offsets=[(-18, -7)]
                ):
                    pass

    # Landmarks
    for rid, rdata in regions.items():
        for lm in rdata.get("landmarks", []):
            lx, _, lz = lm["position"]
            px, py = canvas.w_to_px(lx, lz)
            if 0 <= px < width and 0 <= py < height:
                canvas.fill_circle(px, py, 6.2, (159, 18, 57))
                canvas.fill_circle(px, py, 3.6, (251, 113, 133))
                canvas.try_place_label(
                    px, py, f"* {lm['name'][:26]}", scale=lbl_scale, fg_rgb=(136, 19, 55)
                )

    # Petrol Stations (Real OSM amenity=fuel)
    for rid, rdata in regions.items():
        for ps in rdata.get("petrol_stations", []):
            px_w, _, pz_w = ps["position"]
            px, py = canvas.w_to_px(px_w, pz_w)
            if 0 <= px < width and 0 <= py < height:
                canvas.fill_rect(px - 5, py - 5, px + 5, py + 5, (20, 83, 45))
                canvas.fill_rect(px - 3, py - 3, px + 3, py + 3, (74, 222, 128))
                canvas.try_place_label(
                    px, py, f"FUEL {ps['name'][:22]}", scale=1 if not is_zoomed else 2, fg_rgb=(20, 83, 45)
                )

    # Major Named Roads (deduplicated, collision-checked)
    seen_road_names = set()
    for rid, rdata in regions.items():
        for r in rdata.get("roads", []):
            if r.get("road_class") not in ("motorway", "mountain", "arterial"):
                continue
            rname = r.get("name", "").strip()
            if not rname or "_" in rname or "Ramp" in rname or "Connector" in rname:
                continue
            norm_key = rname.upper()
            if norm_key in seen_road_names:
                continue
            pts = r["control_points"]
            mid = pts[len(pts) // 2]
            px, py = canvas.w_to_px(mid[0], mid[2])
            if 24 <= px < width - 24 and 72 <= py < height - 80:
                if canvas.try_place_label(
                    px, py, rname[:26], scale=1 if not is_zoomed else 2, fg_rgb=(51, 65, 85)
                ):
                    seen_road_names.add(norm_key)

    # 7. Top Title Banner & Bottom Attribution Footer
    canvas.fill_rect(0, 0, width, 54, (248, 246, 240))
    canvas.fill_rect(0, 52, width, 55, (180, 174, 164))
    canvas.try_place_label(
        18, 12, title, scale=3 if width >= 2400 else 2, fg_rgb=(15, 23, 42), halo_rgb=(248, 246, 240), offsets=[(0, 0)], force=True
    )
    canvas.try_place_label(
        18, 36, subtitle, scale=1 if width < 2400 else 2, fg_rgb=(71, 85, 105), halo_rgb=(248, 246, 240), offsets=[(0, 0)], force=True
    )

    fy0 = height - 48
    canvas.fill_rect(0, fy0, width, height, (248, 246, 240))
    canvas.fill_rect(0, fy0, width, fy0 + 2, (180, 174, 164))
    canvas.try_place_label(
        18,
        fy0 + 16,
        "ROAD DATA (C) OPENSTREETMAP CONTRIBUTORS, ODBL | ELEVATION: SRTM30M OPENTOPODATA | SEAMLESS V3 ATLAS",
        scale=1 if width < 2400 else 2,
        fg_rgb=(51, 65, 85),
        halo_rgb=(248, 246, 240),
        offsets=[(0, 0)],
        force=True,
    )

    write_png_rgb(out_path, width, height, canvas.buf)
    size_kb = out_path.stat().st_size / 1024.0
    print(f"Rendered {out_path.name} ({width}x{height} px, {size_kb:.1f} KB, {len(canvas.placed_labels)} non-overlapping labels).")


def render_svg_atlas(country: dict, regions: dict):
    """Refreshes docs/world_map.svg in clean cartographic atlas style."""
    out_svg = DOCS_DIR / "world_map.svg"
    svg_w, svg_h = 1600, 1680
    map_x0, map_y0, map_size = 40.0, 65.0, 1520.0
    w_min, w_span = -16384.0, 32768.0

    def wx_s(x: float) -> float:
        return map_x0 + ((x - w_min) / w_span) * map_size

    def wz_s(z: float) -> float:
        return map_y0 + ((z - w_min) / w_span) * map_size

    def pts_d(pts) -> str:
        if not pts:
            return ""
        return f"M {wx_s(pts[0][0]):.1f},{wz_s(pts[0][2]):.1f} " + " ".join(
            f"L {wx_s(p[0]):.1f},{wz_s(p[2]):.1f}" for p in pts[1:]
        )

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {svg_w} {svg_h}" width="{svg_w}" height="{svg_h}">',
        f'<rect x="0" y="0" width="{svg_w}" height="{svg_h}" fill="#f2efe9" />',
        f'<rect x="{map_x0}" y="{map_y0}" width="{map_size}" height="{map_size}" fill="#eee9df" stroke="#94a3b8" stroke-width="2" />',
        f'<text x="{map_x0}" y="32" font-family="sans-serif" font-size="20" font-weight="bold" fill="#0f172a">HORIZON TRILAND V3 — SEAMLESS REAL OPENSTREETMAP ATLAS (32x32 KM)</text>',
        f'<text x="{map_x0}" y="52" font-family="sans-serif" font-size="12" fill="#475569">Road data (c) OpenStreetMap contributors, ODbL | Real SRTM30m Continuous Elevation</text>',
    ]

    for sp in country.get("terrain", {}).get("sea_polygons", []):
        pstr = " ".join(f"{wx_s(p[0]):.1f},{wz_s(p[1]):.1f}" for p in sp.get("polygon", []))
        lines.append(f'<polygon points="{pstr}" fill="#9acdf0" stroke="#629ecc" stroke-width="1.5" />')

    for rid, rdata in regions.items():
        for lz in rdata.get("terrain", {}).get("landuse_zones", []):
            pstr = " ".join(f"{wx_s(p[0]):.1f},{wz_s(p[1]):.1f}" for p in lz.get("polygon", []))
            col = "#b8daa8" if lz.get("kind") in ("forest", "wood") else ("#f5e5c2" if lz.get("kind") in ("sand", "desert") else "#cceab2")
            lines.append(f'<polygon points="{pstr}" fill="{col}" opacity="0.85" />')
        for wp in rdata.get("terrain", {}).get("water_polygons", []):
            pstr = " ".join(f"{wx_s(p[0]):.1f},{wz_s(p[1]):.1f}" for p in wp.get("polygon", []))
            lines.append(f'<polygon points="{pstr}" fill="#a4d4f6" stroke="#68a4d2" stroke-width="0.8" />')
        for blk in rdata.get("city_blocks", []):
            for fp in blk.get("footprints", []):
                pstr = " ".join(f"{wx_s(p[0]):.1f},{wz_s(p[1]):.1f}" for p in fp.get("poly", []))
                lines.append(f'<polygon points="{pstr}" fill="#cfc9be" stroke="#a69f94" stroke-width="0.35" />')

    st_map = {
        "street": ("#b8b2a6", 2.2, "#ffffff", 1.3),
        "mountain": ("#a88636", 3.4, "#fde880", 2.1),
        "arterial": ("#b47a26", 4.2, "#fcd356", 2.6),
        "motorway": ("#882814", 5.6, "#ec7050", 3.6),
    }
    for rc in ("street", "mountain", "arterial", "motorway"):
        cc, cw, fc, fw = st_map[rc]
        for rid, rdata in regions.items():
            for r in rdata.get("roads", []):
                if r.get("road_class") == rc:
                    d = pts_d(r["control_points"])
                    lines.append(f'<path d="{d}" fill="none" stroke="{cc}" stroke-width="{cw}" stroke-linecap="round" stroke-linejoin="round" />')
                    lines.append(f'<path d="{d}" fill="none" stroke="{fc}" stroke-width="{fw}" stroke-linecap="round" stroke-linejoin="round" />')

    for m in country.get("motorways", []):
        d = pts_d(m["control_points"])
        lines.append(f'<path d="{d}" fill="none" stroke="#882814" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round" />')
        lines.append(f'<path d="{d}" fill="none" stroke="#ea6c4c" stroke-width="4.2" stroke-linecap="round" stroke-linejoin="round" />')

    for ic in country.get("interchanges", []):
        ix, _, iz = ic["position"]
        sx, sy = wx_s(ix), wz_s(iz)
        lines.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="5.5" fill="#fef08a" stroke="#882814" stroke-width="2" />')
        lines.append(f'<text x="{sx + 8:.1f}" y="{sy + 4:.1f}" font-family="sans-serif" font-size="10" font-weight="bold" fill="#7c2d12">{html.escape(ic["id"])}</text>')

    lines.append("</svg>")
    out_svg.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Updated vector atlas {out_svg.name} ({len(lines)} SVG elements).")


def render_all_maps():
    country = json.loads(COUNTRY_PATH.read_text(encoding="utf-8"))
    regions = {}
    for r_meta in country["regions"]:
        rid = r_meta["id"]
        regions[rid] = json.loads((REGIONS_DIR / f"{rid}.json").read_text(encoding="utf-8"))

    # 1. Full 32x32 km Country Map at 3000 x 3000 px
    render_atlas_view(
        DOCS_DIR / "world_map.png",
        country,
        regions,
        width=3000,
        height=3000,
        wx_min=-16384.0,
        wz_min=-16384.0,
        wx_max=16384.0,
        wz_max=16384.0,
        title="HORIZON TRILAND V3 - 32 X 32 KM SEAMLESS OPENSTREETMAP ATLAS",
        subtitle="TOKYO, HAKONE & SHONAN (NE)  |  MONACO & COL DE TURINI (NW)  |  DUBAI, AL QUDRA & JEBEL JAIS (S)",
        is_zoomed=False,
    )

    # 2. Zoomed Region 1: Tokyo, Hakone & Shonan
    tk_b = regions["tokyo_hakone"]["bounds_m"]
    render_atlas_view(
        DOCS_DIR / "world_map_tokyo.png",
        country,
        regions,
        width=1800,
        height=1800,
        wx_min=tk_b["min"][0],
        wz_min=tk_b["min"][1],
        wx_max=tk_b["max"][0],
        wz_max=tk_b["max"][1],
        title="REGION 1: TOKYO, HAKONE & SHONAN COAST (OSM V3)",
        subtitle="GINZA / SHIODOME / SHIBUYA / SHUTO C1 / RAINBOW BRIDGE / ROUTE 134 / HAKONE TURNPIKE & LAKE ASHI",
        is_zoomed=True,
    )

    # 3. Zoomed Region 2: Monaco & Col de Turini
    mc_b = regions["monaco_alps"]["bounds_m"]
    render_atlas_view(
        DOCS_DIR / "world_map_monaco.png",
        country,
        regions,
        width=1800,
        height=1800,
        wx_min=mc_b["min"][0],
        wz_min=mc_b["min"][1],
        wx_max=mc_b["max"][0],
        wz_max=mc_b["max"][1],
        title="REGION 2: MONACO & COL DE TURINI ALPS (OSM V3)",
        subtitle="PORT HERCULE / GP STREET CIRCUIT / TUNNEL LOUIS II / PLACE DU CASINO / CORNICHE / COL DE TURINI D2566",
        is_zoomed=True,
    )

    # 4. Zoomed Region 3: Dubai, Desert & Jebel Jais
    db_b = regions["dubai_jais"]["bounds_m"]
    render_atlas_view(
        DOCS_DIR / "world_map_dubai.png",
        country,
        regions,
        width=1800,
        height=1800,
        wx_min=db_b["min"][0],
        wz_min=db_b["min"][1],
        wx_max=db_b["max"][0],
        wz_max=db_b["max"][1],
        title="REGION 3: DUBAI, AL QUDRA DESERT & JEBEL JAIS (OSM V3)",
        subtitle="DOWNTOWN DUBAI / BURJ KHALIFA / DUBAI MARINA / SHEIKH ZAYED RD E11 / AL QUDRA & E77 / JEBEL JAIS",
        is_zoomed=True,
    )

    render_svg_atlas(country, regions)


if __name__ == "__main__":
    render_all_maps()
