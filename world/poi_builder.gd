class_name PoiBuilder
extends RefCounted
## Worker-side OSM petrol-station markers (data/world/baked/meta.json "petrol"): a canopy on four pillars over two pump
## islands on a concrete apron, with a tall lit price totem. Merged into the tile's props mesh (one draw, no extra node).


static func build(d: Dictionary, tx: int, tz: int) -> void:
	var ox: float = tx * TileGen.TILE
	var oz: float = tz * TileGen.TILE
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var g_verts := PackedVector3Array()
	var g_norms := PackedVector3Array()
	var g_uvs := PackedVector2Array()
	var g_cols := PackedColorArray()
	var g_idx := PackedInt32Array()
	var conc := Color(0.75, 0.74, 0.71).srgb_to_linear()
	conc.a = 0.45
	var post := Color(0.36, 0.38, 0.41).srgb_to_linear()
	post.a = 0.25
	var lamp := Color(1.0, 0.86, 0.62, 0.84)
	var red := Color(0.85, 0.12, 0.10).srgb_to_linear()
	red.a = 0.45
	var any: bool = false
	for p: Dictionary in OsmWorld.meta.get("petrol", []):
		var pos: Array = p["pos"]
		if floori(float(pos[0]) / TileGen.TILE) != tx or floori(float(pos[2]) / TileGen.TILE) != tz:
			continue
		var yaw: float = deg_to_rad(float(p.get("yaw", 0.0)))
		var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
		var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
		var c := Vector3(float(pos[0]) - ox, float(pos[1]), float(pos[2]) - oz)
		if not _site_clear(c, fwd, rt, Vector3(ox, 0.0, oz)):
			continue
		any = true
		RoadMesher._add_box(c + Vector3(0.0, -0.1, 0.0), fwd, rt, Vector3(26.0, 0.5, 18.0), conc, verts, norms, uvs, cols, idx)
		RoadMesher._add_box(c + Vector3(0.0, 5.6, 0.0), fwd, rt, Vector3(18.0, 0.5, 11.0), conc, verts, norms, uvs, cols, idx)
		RoadMesher._add_box(c + Vector3(0.0, 5.95, 0.0), fwd, rt, Vector3(18.2, 0.25, 11.2), red, verts, norms, uvs, cols, idx)
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				RoadMesher._add_box(c + rt * (sx * 7.5) + fwd * (sz * 4.0) + Vector3(0.0, 2.8, 0.0), fwd, rt, Vector3(0.5, 5.6, 0.5), post, verts, norms, uvs, cols, idx)
			RoadMesher._add_box(c + rt * (sx * 3.0) + Vector3(0.0, 0.8, 0.0), fwd, rt, Vector3(1.0, 1.5, 6.0), post, verts, norms, uvs, cols, idx)
		RoadMesher._add_box(c + rt * 12.5 + fwd * 7.0 + Vector3(0.0, 4.0, 0.0), fwd, rt, Vector3(0.6, 8.0, 0.6), post, verts, norms, uvs, cols, idx)
		RoadMesher._add_box(c + rt * 12.5 + fwd * 7.0 + Vector3(0.0, 8.6, 0.0), fwd, rt, Vector3(2.6, 1.6, 0.5), lamp, verts, norms, uvs, cols, idx)
		RoadMesher._add_glow_quad(c + Vector3(0.0, 5.3, 0.0), fwd, rt, 8.0, Color(1.0, 0.84, 0.56, 1.0), g_verts, g_norms, g_uvs, g_cols, g_idx)
	if not any:
		return
	var pd: Dictionary = d.get("props", {"verts": PackedVector3Array(), "norms": PackedVector3Array(), "uvs": PackedVector2Array(), "cols": PackedColorArray(), "idx": PackedInt32Array()})
	_append(pd, verts, norms, uvs, cols, idx)
	var gd: Dictionary = pd.get("glow", {"verts": PackedVector3Array(), "norms": PackedVector3Array(), "uvs": PackedVector2Array(), "cols": PackedColorArray(), "idx": PackedInt32Array()})
	_append(gd, g_verts, g_norms, g_uvs, g_cols, g_idx)
	pd["glow"] = gd
	d["props"] = pd


## The apron (26 x 18 m) and the price totem stay off every road corridor; a station whose site overlaps a road is skipped.
static func _site_clear(c: Vector3, fwd: Vector3, rt: Vector3, origin: Vector3) -> bool:
	for sx: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		for sz: float in [-1.0, 0.0, 1.0]:
			if not RoadMesher._clear(c + rt * (sx * 13.0) + fwd * (sz * 9.0), origin, 2.0, c.y - 0.4, c.y + 6.0):
				return false
	return RoadMesher._clear(c + rt * 12.5 + fwd * 7.0, origin, 1.4, c.y, c.y + 9.4)


static func _append(dst: Dictionary, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var base: int = (dst["verts"] as PackedVector3Array).size()
	dst["verts"] = (dst["verts"] as PackedVector3Array) + verts
	dst["norms"] = (dst["norms"] as PackedVector3Array) + norms
	dst["uvs"] = (dst["uvs"] as PackedVector2Array) + uvs
	dst["cols"] = (dst["cols"] as PackedColorArray) + cols
	var shifted := PackedInt32Array()
	for k: int in idx:
		shifted.append(k + base)
	dst["idx"] = (dst["idx"] as PackedInt32Array) + shifted
