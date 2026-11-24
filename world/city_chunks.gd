class_name CityChunks
extends RefCounted
## Worker-side OSM building builder (M3 pipeline applied to real footprints). Per 256 m chunk of a FULL tile: ONE merged
## facade mesh (LOD0, extruded footprints), ONE simplified box mesh of the big buildings (LOD1), one occluder; per tile
## one wall collider next to roads. MID/FAR tiles get a skyline prism mesh. Same vertex layout as building.gdshader:
## UV = facade metres, UV2.x = building height, COLOR.rgb = tint, COLOR.a = (style + seed) / 4.

const CHUNK: float = 256.0
const COLL_H: float = 6.0  # colliders only reach this high: a car never gets above it
const PALETTE: PackedColorArray = [
	Color(0.58, 0.68, 0.78),  # cool reflective glass/steel (Dubai/Tokyo towers)
	Color(0.76, 0.75, 0.72),  # crisp architectural limestone/concrete
	Color(0.86, 0.76, 0.65),  # warm Riviera stucco/ochre (Monaco)
	Color(0.72, 0.68, 0.64),  # modern urban commercial stone/brick
	Color(0.48, 0.56, 0.66),  # dark architectural steel/slate supertall
]
static var _pal_lin: PackedColorArray = []


static func _static_init() -> void:
	for c: Color in PALETTE:
		_pal_lin.append(c.srgb_to_linear())


class Acc:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()

	func tri(a: Vector3, b: Vector3, cc: Vector3, nrm: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, bh: float, tint: Color, lit: float = 0.0) -> void:
		var o: int = v.size()
		v.append_array([a, b, cc])
		for k: int in 3:
			n.append(nrm)
			c.append(tint)
			uv2.append(Vector2(bh, lit))
		uv.append_array([ua, ub, uc])
		# Godot front faces wind clockwise: flip when the triangle is counter-clockwise seen from the normal's side
		if (b - a).cross(cc - a).dot(nrm) > 0.0:
			idx.append_array([o, o + 2, o + 1])
		else:
			idx.append_array([o, o + 1, o + 2])

	func arrays() -> Array:
		if v.is_empty():
			return []
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
		arr[Mesh.ARRAY_INDEX] = idx
		return arr


static func _seed(b: Array) -> float:
	var f: PackedFloat32Array = PackedFloat32Array(b[2])
	return fposmod(sin(f[0] * 12.9898 + f[1] * 78.233) * 43758.5453, 1.0)


static func _tint(style: int, hgt: float, sd: float) -> Color:
	var pi: int = style if style < 4 else 1
	if hgt >= 90.0:
		pi = 4 if sd > 0.5 else 0
	var col: Color = _pal_lin[pi]
	return Color(col.r, col.g, col.b, (mini(style, 3) + 0.06 + sd * 0.86) / 4.0)


## Appends the extruded footprint to acc (walls + roof, no floor). Points are tile-local (x, z) pairs. UV.v is metres
## above floor_y (default y0): wall below the floor (a plinth on a slope) has v < 0, which the shaders draw as plain stone.
static func _extrude(acc: Acc, pts: PackedVector2Array, y0: float, y1: float, tint: Color, floor_y: float = NAN, lit: float = 0.0) -> void:
	if is_nan(floor_y):
		floor_y = y0
	var np: int = pts.size()
	var bh: float = y1 - floor_y
	var vb: float = y0 - floor_y
	var u: float = 0.0
	for k: int in np:
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[(k + 1) % np]
		var d: Vector2 = b - a
		var len: float = d.length()
		if len < 0.05:
			continue
		var nrm := Vector3(d.y, 0.0, -d.x) / len  # footprints are baked counter-clockwise (x right, z up)
		var a0 := Vector3(a.x, y0, a.y)
		var b0 := Vector3(b.x, y0, b.y)
		var b1 := Vector3(b.x, y1, b.y)
		var a1 := Vector3(a.x, y1, a.y)
		acc.tri(a0, b0, b1, nrm, Vector2(u, vb), Vector2(u + len, vb), Vector2(u + len, bh), bh, tint, lit)
		acc.tri(a0, b1, a1, nrm, Vector2(u, vb), Vector2(u + len, bh), Vector2(u, bh), bh, tint, lit)
		u += len
	var tri: PackedInt32Array = Geometry2D.triangulate_polygon(pts)
	for t: int in range(0, tri.size(), 3):
		var p0: Vector2 = pts[tri[t]]
		var p1: Vector2 = pts[tri[t + 1]]
		var p2: Vector2 = pts[tri[t + 2]]
		acc.tri(Vector3(p0.x, y1, p0.y), Vector3(p1.x, y1, p1.y), Vector3(p2.x, y1, p2.y), Vector3.UP, p0, p1, p2, bh, tint, lit)


## Adds an inset architectural rooftop penthouse / mechanical crown on medium and tall buildings (stays strictly
## inside the clipped footprint so road clearance is guaranteed untouched, zero extra draw calls).
static func _add_crown(acc: Acc, pts: PackedVector2Array, y1: float, hgt: float, tint: Color) -> void:
	if hgt < 16.0 or pts.size() < 3:
		return
	var c := Vector2.ZERO
	for p: Vector2 in pts:
		c += p
	c /= float(pts.size())
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p: Vector2 in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	if minf(hi.x - lo.x, hi.y - lo.y) < 9.0:
		return
	# Verify centroid lies inside the polygon before insetting toward it
	if not Geometry2D.is_point_in_polygon(c, pts):
		return
	var crown_frac: float = 0.56 if hgt >= 42.0 else 0.38
	var crown_h: float = minf(hgt * 0.14, 7.5) if hgt >= 42.0 else clampf(hgt * 0.10, 1.8, 3.2)
	var inset := PackedVector2Array()
	for p: Vector2 in pts:
		inset.append(c.lerp(p, crown_frac))
	# Slight plinth-style shade on mechanical crown (plinth UV v < 0 renders clean architectural stone/concrete)
	var c_tint := Color(tint.r * 0.86, tint.g * 0.86, tint.b * 0.88, tint.a)
	_extrude(acc, inset, y1, y1 + crown_h, c_tint, y1 + crown_h + 1.0, 0.0)


static func _box(acc: Acc, lo: Vector2, hi: Vector2, y0: float, y1: float, tint: Color, floor_y: float = NAN, lit: float = 0.0) -> void:
	var p := PackedVector2Array([Vector2(lo.x, lo.y), Vector2(hi.x, lo.y), Vector2(hi.x, hi.y), Vector2(lo.x, hi.y)])
	_extrude(acc, p, y0, y1, tint, floor_y, lit)


const MAX_SLOPE_DROP: float = 8.0  # ground fall across a footprint above this: no building there (too steep a site)
const ROAD_GAP: float = 0.3  # facades stand this far behind the sidewalk / shoulder edge


## Ground height at a tile-local point, bilinear on the margin grid.
static func _ground_bl(h: PackedFloat32Array, n: int, x: float, z: float) -> float:
	var cell: float = TileGen.TILE / (n - 1)
	var m: int = n + 2
	var fx: float = clampf(x / cell + 1.0, 0.0, m - 1.001)
	var fz: float = clampf(z / cell + 1.0, 0.0, m - 1.001)
	var i: int = int(fx)
	var j: int = int(fz)
	fx -= i
	fz -= j
	return lerpf(lerpf(h[j * m + i], h[j * m + i + 1], fx), lerpf(h[(j + 1) * m + i], h[(j + 1) * m + i + 1], fx), fz)


static func _lit_bias(style: int, hgt: float, sd: float) -> float:
	var r: float = fposmod(sd * 7.31 + hgt * 0.017, 1.0)
	if hgt >= 48.0 or style == 0:
		return lerpf(0.30, 0.88, r)
	if hgt >= 16.0:
		return lerpf(0.22, 0.72, r)
	return lerpf(0.18, 0.55, r * r)


## Placed buildings of the tile: footprints clipped out of every road corridor (carriageway, shoulder, sidewalk), floor on
## the highest ground under the footprint with a plinth down to the lowest, too-steep sites dropped.
## Each: [pieces: Array of PackedVector2Array (tile-local), y0, floor, y1, tint, hgt, chunk key, lit_bias].
static func _prepare(list: Array, ox: float, oz: float, h: PackedFloat32Array, n: int) -> Array:
	var out: Array = []
	for b: Array in list:
		var f: Array = b[2]
		var pts := PackedVector2Array()
		var c := Vector2.ZERO
		for k: int in range(0, f.size(), 2):
			var p := Vector2(float(f[k]) - ox, float(f[k + 1]) - oz)
			pts.append(p)
			c += p
		c /= pts.size()
		var gmin: float = _ground_bl(h, n, c.x, c.y)
		var gmax: float = gmin
		for p: Vector2 in pts:
			var g: float = _ground_bl(h, n, p.x, p.y)
			gmin = minf(gmin, g)
			gmax = maxf(gmax, g)
		if gmax - gmin > MAX_SLOPE_DROP:
			continue
		var hgt: float = float(b[0])
		var y0: float = gmin - 1.0
		var y1: float = gmax + hgt
		var pieces: Array = _clip_to_roads(pts, ox, oz, y0, y1)
		if pieces.is_empty():
			continue
		var key := Vector2i(clampi(floori(c.x / CHUNK), 0, 3), clampi(floori(c.y / CHUNK), 0, 3))
		var sd: float = _seed(b)
		var st: int = int(b[1])
		out.append([pieces, y0, gmax, y1, _tint(st, hgt, sd), hgt, key, _lit_bias(st, hgt, sd)])
	return out


## Footprint minus the road corridors that cross it (Geometry2D.clip_polygons per 4 m road segment). Pieces under
## 25 m2 or thinner than ~4 m are dropped; a road passing wholly inside a footprint drops the building.
static func _clip_to_roads(pts: PackedVector2Array, ox: float, oz: float, y0: float, y1: float) -> Array:
	if not OsmWorld.enabled or not _touches_road(pts, ox, oz, y0, y1):
		return [pts]
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p: Vector2 in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	var cw: bool = Geometry2D.is_polygon_clockwise(pts)
	var reach: float = RoadMesher._max_clear + RoadMesher.SIDEWALK + ROAD_GAP + 1.0
	var pieces: Array = [pts]
	var cell: float = RoadGraph.FINE
	for cz: int in range(floori((lo.y + oz - reach) / cell), floori((hi.y + oz + reach) / cell) + 1):
		for cx: int in range(floori((lo.x + ox - reach) / cell), floori((hi.x + ox + reach) / cell) + 1):
			for code: int in RoadGraph._fine.get(Vector2i(cx, cz), PackedInt32Array()):
				var e: int = code >> 16
				var ep: PackedVector3Array = RoadGraph.e_pts[e]
				var i: int = code & 0xFFFF
				if i + 1 >= ep.size():
					continue
				var a3: Vector3 = ep[i]
				var b3: Vector3 = ep[i + 1]
				if maxf(a3.y, b3.y) + 5.0 < y0 or minf(a3.y, b3.y) - 1.0 > y1:
					continue  # far under the building (tunnel) or a deck high over it
				var a := Vector2(a3.x - ox, a3.z - oz)
				var bb := Vector2(b3.x - ox, b3.z - oz)
				var dv: Vector2 = (bb - a).normalized()
				var nv := Vector2(-dv.y, dv.x)
				var w: float = RoadMesher.clear_hw(e) + (RoadMesher.SIDEWALK if RoadGraph.e_type[e] == RoadGraph.CITY else 0.0) + ROAD_GAP
				var ql: Vector2 = a - dv * 0.6
				var qr: Vector2 = bb + dv * 0.6
				if maxf(ql.x, qr.x) + w < lo.x or minf(ql.x, qr.x) - w > hi.x or maxf(ql.y, qr.y) + w < lo.y or minf(ql.y, qr.y) - w > hi.y:
					continue
				var quad := PackedVector2Array([ql + nv * w, qr + nv * w, qr - nv * w, ql - nv * w])
				var next: Array = []
				for pc: PackedVector2Array in pieces:
					for r: PackedVector2Array in Geometry2D.clip_polygons(pc, quad):
						if Geometry2D.is_polygon_clockwise(r) != cw:
							return []  # a hole: the road runs inside the footprint
						next.append(r)
				pieces = next
				if pieces.is_empty():
					return []
	var keep: Array = []
	for pc: PackedVector2Array in pieces:
		var area: float = 0.0
		var per: float = 0.0
		for k: int in pc.size():
			var p0: Vector2 = pc[k]
			var p1: Vector2 = pc[(k + 1) % pc.size()]
			area += p0.x * p1.y - p1.x * p0.y
			per += p0.distance_to(p1)
		area = absf(area) * 0.5
		if area >= 25.0 and area / per >= 1.0:
			keep.append(pc)
	return keep


## Cheap pre-test: does any footprint edge (every ~2.5 m) or the centre come near a road corridor?
static func _touches_road(pts: PackedVector2Array, ox: float, oz: float, y0: float, y1: float) -> bool:
	var np: int = pts.size()
	var c := Vector2.ZERO
	for k: int in np:
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[(k + 1) % np]
		c += a
		var steps: int = maxi(1, ceili(a.distance_to(b) / 2.5))
		for s: int in steps:
			var p: Vector2 = a.lerp(b, float(s) / steps)
			if RoadMesher.corridor_edge(p.x + ox, p.y + oz, y0, y1, ROAD_GAP + 1.0, true) >= 0:
				return true
	c /= np
	return RoadMesher.corridor_edge(c.x + ox, c.y + oz, y0, y1, ROAD_GAP + 1.0, true) >= 0


## A tile-local rectangle (prism y0..y1) that stays out of every road corridor (sampled every ~6 m).
static func _rect_clear(lo: Vector2, hi: Vector2, ox: float, oz: float, y0: float, y1: float) -> bool:
	if not OsmWorld.enabled:
		return true
	var nx: int = maxi(1, ceili((hi.x - lo.x) / 6.0))
	var nz: int = maxi(1, ceili((hi.y - lo.y) / 6.0))
	for j: int in nz + 1:
		for i: int in nx + 1:
			var p: Vector2 = lo + Vector2((hi.x - lo.x) * i / nx, (hi.y - lo.y) * j / nz)
			if RoadMesher.corridor_edge(p.x + ox, p.y + oz, y0, y1, ROAD_GAP, true) >= 0:
				return false
	return true


static func _bounds(pieces: Array) -> Rect2:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for pc: PackedVector2Array in pieces:
		for p: Vector2 in pc:
			lo = lo.min(p)
			hi = hi.max(p)
	return Rect2(lo, hi - lo)


static func build(d: Dictionary, tx: int, tz: int, h: PackedFloat32Array, n: int, lod: int) -> void:
	var list: Array = OsmWorld.buildings_in_tile(tx, tz)
	if list.is_empty():
		return
	var ox: float = tx * TileGen.TILE
	var oz: float = tz * TileGen.TILE
	var placed: Array = _prepare(list, ox, oz, h, n)
	var sky := Acc.new()
	_sky_prisms(sky, placed, ox, oz)
	var sm: Array = sky.arrays()
	if not sm.is_empty():
		d["city_sky"] = sm
	if lod != TileGen.FULL:
		return
	var chunks: Dictionary[Vector2i, Array] = {}
	for pb: Array in placed:
		if not chunks.has(pb[6]):
			chunks[pb[6]] = []
		chunks[pb[6]].append(pb)
	var road_cells: PackedByteArray = _road_cells(tx, tz)
	var guard: Array = _road_guard(tx, tz)
	var out: Array = []
	var faces := PackedVector3Array()
	for key: Vector2i in chunks:
		var lod0 := Acc.new()
		var lod1 := Acc.new()
		var occ: Array[Array] = []  # [area, lo, hi, y]
		for pb: Array in chunks[key]:
			var y0: float = pb[1]
			var fl: float = pb[2]
			var y1: float = pb[3]
			var tint: Color = pb[4]
			var hgt: float = pb[5]
			var lit: float = float(pb[7])
			for pts: PackedVector2Array in pb[0]:
				var r: Rect2 = _bounds([pts])
				_extrude(lod0, pts, y0, y1, tint, fl, lit)
				_add_crown(lod0, pts, y1, hgt, tint)
				var area: float = r.get_area()
				if hgt >= 18.0 or area >= 400.0:
					# LOD1 is the footprint's box unless that box would reach over a road (L-shapes, clipped pieces)
					if _rect_clear(r.position, r.end, ox, oz, y0, y1):
						_box(lod1, r.position, r.end, y0, y1, tint, fl, lit)
					else:
						_extrude(lod1, pts, y0, y1, tint, fl, lit)
				if hgt >= 12.0:
					occ.append([area, r.position, r.end, fl, y1 - 0.8])
				if _near_road(road_cells, r.position, r.end):
					_wall_faces(faces, pts, y0, fl + minf(hgt, COLL_H), guard)
		var m0: Array = lod0.arrays()
		if m0.is_empty():
			continue
		var entry: Dictionary = {"lod0": m0, "lod1": lod1.arrays(), "occ": _occluder(occ)}
		out.append(entry)
	d["city"] = out
	if not faces.is_empty():
		d["city_faces"] = faces


static func _sky_prisms(acc: Acc, placed: Array, ox: float, oz: float) -> void:
	# one prism per ~64 m cell: footprint bounds of the buildings in it, height of the tallest. A cell whose box would
	# reach over a road falls back to its buildings' own footprints.
	var cells: Dictionary[Vector2i, Array] = {}
	for pb: Array in placed:
		var c: Vector2 = _bounds(pb[0]).get_center()
		var key := Vector2i(floori(c.x / 64.0), floori(c.y / 64.0))
		if not cells.has(key):
			cells[key] = []
		cells[key].append(pb)
	for key: Vector2i in cells:
		var list: Array = cells[key]
		var r: Rect2 = _bounds(list[0][0])
		var y0: float = 1e9
		var top: float = -1e9
		var tall: Array = list[0]
		for pb: Array in list:
			r = r.merge(_bounds(pb[0]))
			y0 = minf(y0, float(pb[1]))
			if float(pb[3]) > top:
				top = pb[3]
				tall = pb
		if r.size.x < 6.0 or r.size.y < 6.0:
			continue
		if _rect_clear(r.position, r.end, ox, oz, y0, top):
			_box(acc, r.position, r.end, y0, top, tall[4], tall[2], float(tall[7]))
		else:
			for pb: Array in list:
				for pts: PackedVector2Array in pb[0]:
					_extrude(acc, pts, pb[1], pb[3], pb[4], pb[2], float(pb[7]))


static func _occluder(occ: Array[Array]) -> Array:
	if occ.is_empty():
		return []
	occ.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for k: int in mini(occ.size(), 24):
		var e: Array = occ[k]
		var lo: Vector2 = (e[1] as Vector2) + Vector2(0.7, 0.7)
		var hi: Vector2 = (e[2] as Vector2) - Vector2(0.7, 0.7)
		if hi.x - lo.x < 3.0 or hi.y - lo.y < 3.0:
			continue
		var y0: float = float(e[3]) + 1.0
		var y1: float = float(e[4])
		if y1 <= y0 + 4.0:
			continue
		var o: int = verts.size()
		for yy: float in [y0, y1]:
			verts.append_array([Vector3(lo.x, yy, lo.y), Vector3(hi.x, yy, lo.y), Vector3(hi.x, yy, hi.y), Vector3(lo.x, yy, hi.y)])
		# 6 quads as 12 triangles (outward is not required by the occluder rasteriser)
		for q: Array in [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]:
			idx.append_array([o + q[0], o + q[1], o + q[2], o + q[0], o + q[2], o + q[3]])
	if verts.is_empty():
		return []
	return [verts, idx]


## Road samples in tile-local xz plus the clearance (half width + 1.5 m). Walls inside that
## corridor are skipped so a footprint that overlaps the carriageway cannot block a lane.
static func _road_guard(tx: int, tz: int) -> Array:
	var pts := PackedVector2Array()
	var clr := PackedFloat32Array()
	var ox: float = tx * TileGen.TILE
	var oz: float = tz * TileGen.TILE
	for r: Vector3i in RoadGraph.runs_in_tile(tx, tz):
		var ep: PackedVector3Array = RoadGraph.e_pts[r.x]
		var hw: float = RoadGraph.e_width[r.x] * 0.5 + 1.5
		var i: int = r.y
		while i <= r.z:
			var p: Vector3 = ep[i]
			pts.append(Vector2(p.x - ox, p.z - oz))
			clr.append(hw)
			i += 2
	return [pts, clr]


static func _on_road(guard: Array, a: Vector2, b: Vector2) -> bool:
	var pts: PackedVector2Array = guard[0]
	var clr: PackedFloat32Array = guard[1]
	var m: Vector2 = (a + b) * 0.5
	for i: int in pts.size():
		if m.distance_squared_to(pts[i]) < clr[i] * clr[i]:
			return true
	return false


static func _wall_faces(faces: PackedVector3Array, pts: PackedVector2Array, y0: float, y1: float, guard: Array) -> void:
	var np: int = pts.size()
	for k: int in np:
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[(k + 1) % np]
		if _on_road(guard, a, b):
			continue
		var a0 := Vector3(a.x, y0, a.y)
		var b0 := Vector3(b.x, y0, b.y)
		faces.append_array([a0, b0, Vector3(b.x, y1, b.y), a0, Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y)])


## 32 m cells of the tile (+ one cell margin each side) touched by a road: 34 x 34 flags.
static func _road_cells(tx: int, tz: int) -> PackedByteArray:
	var cells := PackedByteArray()
	cells.resize(34 * 34)
	var ox: float = tx * TileGen.TILE
	var oz: float = tz * TileGen.TILE
	for r: Vector3i in RoadGraph.runs_in_tile(tx, tz):
		var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
		for i: int in range(r.y, r.z + 1):
			var cx: int = floori((pts[i].x - ox) / 32.0) + 1
			var cz: int = floori((pts[i].z - oz) / 32.0) + 1
			if cx >= 0 and cx < 34 and cz >= 0 and cz < 34:
				cells[cz * 34 + cx] = 1
	return cells


static func _near_road(cells: PackedByteArray, lo: Vector2, hi: Vector2) -> bool:
	var x0: int = clampi(floori((lo.x - 12.0) / 32.0) + 1, 0, 33)
	var x1: int = clampi(floori((hi.x + 12.0) / 32.0) + 1, 0, 33)
	var z0: int = clampi(floori((lo.y - 12.0) / 32.0) + 1, 0, 33)
	var z1: int = clampi(floori((hi.y + 12.0) / 32.0) + 1, 0, 33)
	for z: int in range(z0, z1 + 1):
		for x: int in range(x0, x1 + 1):
			if cells[z * 34 + x] == 1:
				return true
	return false
