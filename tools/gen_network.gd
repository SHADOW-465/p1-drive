extends SceneTree
## Builds data/roads/network.json from asymmetric routes, interchanges, bridges,
## roundabouts, and tunnel in data/world_def.json + data/hero/*.json (RD2).
## Run: godot --headless --path . -s res://tools/gen_network.gd

const CTRL: float = 40.0
const SUB: int = 48
const SNAP_DIST: float = 4.0
const OVERPASS_CLEARANCE: float = 7.4

var nodes: Array[Dictionary] = []
var edges: Array[Dictionary] = []
var _pinned_y: Dictionary[int, float] = {}
var _min_y: Dictionary[int, float] = {}
var bad: int = 0


func _init() -> void:
	var hero_files: Array[String] = _list_hero_files()
	var hero_data: Array[Dictionary] = []
	for path: String in hero_files:
		var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		hero_data.append(d)
		var id_map: Dictionary[int, int] = {}
		for hn: Dictionary in d["nodes"]:
			var p := Vector3(hn["p"][0], hn["p"][1], hn["p"][2])
			var nid: int = _get_or_create_node(p, true, bool(hn.get("town", false)), "normal", 0.0)
			id_map[int(hn["id"])] = nid
		d["_id_map"] = id_map

	var routes: Array = TerrainFn.def["routes"]
	var roundabouts: Array = TerrainFn.def.get("roundabouts", [])
	var rbt_map: Dictionary[Vector2, float] = {}
	for rb: Dictionary in roundabouts:
		var rp: Array = rb["pos"]
		rbt_map[_key_xz(float(rp[0]), float(rp[1]))] = float(rb.get("radius", 20.0))

	var hwy_uses: Dictionary[Vector2, int] = {}
	var surf_uses: Dictionary[Vector2, int] = {}
	for r: Dictionary in routes:
		var wp: Array = r["wp"]
		var is_hwy: bool = str(r["type"]) == "highway"
		var is_closed: bool = bool(r.get("closed", false))
		var umap: Dictionary[Vector2, int] = hwy_uses if is_hwy else surf_uses
		for i: int in wp.size():
			var wk: Vector2 = _key_xz(float(wp[i][0]), float(wp[i][1]))
			var add_w: int = 1 if is_closed else (2 if (i == 0 or i == wp.size() - 1) else 1)
			umap[wk] = umap.get(wk, 0) + add_w

	var hwy_pieces: Array[Dictionary] = []
	var surf_pieces: Array[Dictionary] = []
	for r: Dictionary in routes:
		var wp: Array = r["wp"]
		var rtype: String = str(r["type"])
		var rname: String = str(r["name"])
		var is_hwy: bool = rtype == "highway"
		var is_closed: bool = bool(r.get("closed", false))
		var is_tunnel: bool = bool(r.get("tunnel", false))
		var umap: Dictionary[Vector2, int] = hwy_uses if is_hwy else surf_uses

		var fine: PackedVector3Array
		var span_count: int
		var wp_indices: Array[int] = []
		if r.has("fillet_r"):
			var built: Dictionary = _build_filleted_polyline(wp, is_closed, float(r["fillet_r"]))
			fine = built["fine"]
			wp_indices = built["wp_indices"]
			span_count = wp.size() if is_closed else (wp.size() - 1)
		elif is_closed and wp.size() >= 3:
			var wn: int = wp.size()
			var ext := PackedVector3Array()
			for idx_e: int in range(-2, wn + 3):
				var wi: int = posmod(idx_e, wn)
				ext.append(Vector3(float(wp[wi][0]), 0.0, float(wp[wi][1])))
			var full_fine: PackedVector3Array = RoadGraph.spline(ext, SUB)
			fine = full_fine.slice(2 * SUB, (2 + wn) * SUB + 1)
			span_count = wn
		else:
			var line := PackedVector3Array()
			for p: Array in wp:
				line.append(Vector3(float(p[0]), 0.0, float(p[1])))
			fine = RoadGraph.spline(line, SUB)
			span_count = wp.size() - 1

		var split_idx: Array[int] = [0]
		for k: int in range(1, span_count):
			var wk: Vector2 = _key_xz(float(wp[k][0]), float(wp[k][1]))
			if umap.get(wk, 0) >= 2 or rbt_map.has(wk):
				split_idx.append(wp_indices[k] if not wp_indices.is_empty() else k * SUB)
		split_idx.append(fine.size() - 1)

		if is_closed and split_idx.size() == 2:
			var mid_i: int = wp_indices[span_count / 2] if not wp_indices.is_empty() else (span_count / 2) * SUB
			split_idx = [0, mid_i, fine.size() - 1]

		for si: int in split_idx.size() - 1:
			var i0: int = split_idx[si]
			var i1: int = split_idx[si + 1]
			if i1 <= i0:
				continue
			var slice_pts: PackedVector3Array = fine.slice(i0, i1 + 1)
			var pc := {
				"name": rname,
				"type": rtype,
				"kind": "tunnel" if is_tunnel else "road",
				"pts": RoadGraph.resample(slice_pts, CTRL),
				"overpass_zones": [],
				"underpass_zones": [],
			}
			if is_hwy:
				hwy_pieces.append(pc)
			else:
				surf_pieces.append(pc)

	surf_pieces = _split_crossings(surf_pieces)

	var ramp_pieces: Array[Dictionary] = []
	_resolve_highway_crossings(hwy_pieces, surf_pieces, ramp_pieces)

	var hwy_targets := PackedVector3Array()
	var surf_targets := PackedVector3Array()
	for rpc: Dictionary in ramp_pieces:
		for tp: Vector3 in (rpc.get("hwy_targets", []) as Array):
			hwy_targets.append(tp)
		for tp: Vector3 in (rpc.get("surf_targets", []) as Array):
			surf_targets.append(tp)
	hwy_pieces = _split_at_targets(hwy_pieces, hwy_targets)
	surf_pieces = _split_at_targets(surf_pieces, surf_targets)

	var all_pieces: Array[Dictionary] = []
	all_pieces.append_array(hwy_pieces)
	all_pieces.append_array(surf_pieces)
	all_pieces.append_array(ramp_pieces)
	all_pieces = _split_bridges_and_overpasses(all_pieces)

	for pc: Dictionary in all_pieces:
		var pts: PackedVector3Array = pc["pts"]
		if pts.size() < 2:
			continue
		pc["a"] = _get_or_create_node(pts[0], false, false, "normal", 0.0)
		pc["b"] = _get_or_create_node(pts[pts.size() - 1], false, false, "normal", 0.0)

	# Set minimum deck heights on bridges & overpasses BEFORE relaxing node heights.
	for pc: Dictionary in all_pieces:
		if not pc.has("a"):
			continue
		if pc["kind"] == "bridge":
			_set_bridge_min_y(pc)
		elif pc["kind"] == "overpass":
			_set_overpass_min_y(pc)

	for rb: Dictionary in roundabouts:
		var rp: Array = rb["pos"]
		var nid: int = _find_node_near(Vector3(float(rp[0]), 0.0, float(rp[1])), 12.0)
		if nid >= 0:
			nodes[nid]["kind"] = "roundabout"
			nodes[nid]["radius"] = float(rb.get("radius", 20.0))

	for pc: Dictionary in all_pieces:
		if pc["type"] == "ramp" or pc["type"] == "highway":
			for end_key: String in ["a", "b"]:
				if pc.has(end_key):
					var nid: int = int(pc[end_key])
					if str(nodes[nid].get("kind", "normal")) == "normal":
						if _node_touches_types(nid, all_pieces, ["highway", "ramp"]):
							nodes[nid]["kind"] = "merge"

	_relax_node_heights(all_pieces)
	for pc: Dictionary in all_pieces:
		_solve_edge_vertical(pc)

	for pc: Dictionary in all_pieces:
		_emit_generated_edge(pc)

	for d: Dictionary in hero_data:
		var id_map: Dictionary = d["_id_map"]
		for he: Dictionary in d["edges"]:
			var a: int = id_map[int(he["a"])]
			var b: int = id_map[int(he["b"])]
			var elev: bool = bool(he.get("elevated", false))
			edges.append({
				"id": edges.size(),
				"a": a,
				"b": b,
				"type": he["type"],
				"kind": "bridge" if elev else "road",
				"elevated": elev,
				"pts": he["pts"],
			})

	for tw: Array in TerrainFn.def.get("towns", []):
		var tp := Vector2(tw[0], tw[1])
		var best_n: int = -1
		var best_d: float = 140.0 * 140.0
		for n: Dictionary in nodes:
			var np := Vector2(n["p"][0], n["p"][2])
			var d2: float = np.distance_squared_to(tp)
			if d2 < best_d:
				best_d = d2
				best_n = int(n["id"])
		if best_n >= 0:
			nodes[best_n]["town"] = true

	var spawn_info: Dictionary = _pick_spawn()
	var out_dict: Dictionary = {
		"version": 2,
		"seed": TerrainFn.world_seed,
		"nodes": nodes,
		"edges": edges,
		"spawn": spawn_info,
	}
	var f := FileAccess.open("res://data/roads/network.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out_dict))
	f.close()

	RoadGraph.load_file("res://data/roads/network.json")
	var km: PackedFloat32Array = RoadGraph.km_by_type()
	print("network: %d nodes, %d edges, %.1f km (highway %.1f, country %.1f, mountain %.1f, city %.1f, ramp %.1f, rural %.1f)" % [
		nodes.size(), edges.size(), RoadGraph.total_km(), km[0], km[1], km[2], km[3], km[4], km[5]])
	var counts: Dictionary = _count_kinds()
	print("features: bridges=%d overpasses=%d tunnels=%d roundabouts=%d merges=%d | spawn edge=%d idx=%d pos=%s" % [
		counts["bridge"], counts["overpass"], counts["tunnel"], counts["roundabout"], counts["merge"],
		RoadGraph.spawn_edge, RoadGraph.spawn_i, RoadGraph.spawn_pos])

	var msg: String = RoadGraph.self_check()
	if msg != "":
		print("NETWORK FAIL: ", msg)
		bad += 1
	if RoadGraph.total_km() < 100.0:
		print("NETWORK FAIL: total km %.1f < 100" % RoadGraph.total_km())
		bad += 1
	if not _check_connected():
		print("NETWORK FAIL: graph disconnected")
		bad += 1
	_check_flat_highway_nodes()
	_check_radii()
	quit(1 if bad > 0 else 0)


func _build_filleted_polyline(wp: Array, is_closed: bool, target_r: float) -> Dictionary:
	var wn: int = wp.size()
	var pts3: Array[Vector3] = []
	for p: Array in wp:
		pts3.append(Vector3(float(p[0]), 0.0, float(p[1])))
	var t0s: Array[Vector3] = []
	var t1s: Array[Vector3] = []
	var u_ins: Array[Vector3] = []
	var u_outs: Array[Vector3] = []
	var ds: PackedFloat32Array = []
	var is_corner: PackedByteArray = []
	t0s.resize(wn)
	t1s.resize(wn)
	u_ins.resize(wn)
	u_outs.resize(wn)
	ds.resize(wn)
	is_corner.resize(wn)

	for k: int in wn:
		var pk: Vector3 = pts3[k]
		if not is_closed and (k == 0 or k == wn - 1):
			t0s[k] = pk
			t1s[k] = pk
			continue
		var p_prev: Vector3 = pts3[posmod(k - 1, wn)]
		var p_next: Vector3 = pts3[posmod(k + 1, wn)]
		var vin: Vector3 = pk - p_prev
		var vout: Vector3 = p_next - pk
		var lin: float = vin.length()
		var lout: float = vout.length()
		var uin: Vector3 = vin / maxf(lin, 1e-4)
		var uout: Vector3 = vout / maxf(lout, 1e-4)
		var ang: float = acos(clampf(uin.dot(uout), -1.0, 1.0))
		if ang < 0.03:
			t0s[k] = pk
			t1s[k] = pk
			continue
		var d: float = minf(target_r * tan(ang * 0.5), minf(lin * 0.42, lout * 0.42))
		t0s[k] = pk - uin * d
		t1s[k] = pk + uout * d
		u_ins[k] = uin
		u_outs[k] = uout
		ds[k] = d
		is_corner[k] = 1

	var fine := PackedVector3Array()
	var wp_indices: Array[int] = []
	wp_indices.resize(wn)
	var span_n: int = wn if is_closed else (wn - 1)
	for k: int in wn:
		if k == 0:
			wp_indices[0] = 0
			fine.append(t1s[0] if is_corner[0] == 1 else pts3[0])
		if k < span_n:
			var k_nxt: int = posmod(k + 1, wn)
			var a: Vector3 = t1s[k]
			var b: Vector3 = t0s[k_nxt]
			var seg_len: float = a.distance_to(b)
			var steps: int = maxi(ceili(seg_len / 12.0), 1)
			for s: int in range(1, steps + 1):
				fine.append(a.lerp(b, float(s) / float(steps)))
			if k_nxt != 0 or is_closed:
				if is_corner[k_nxt] == 1:
					var p0: Vector3 = t0s[k_nxt]
					var p3: Vector3 = t1s[k_nxt]
					var h: float = ds[k_nxt] * 0.62
					var p1: Vector3 = p0 + u_ins[k_nxt] * h
					var p2: Vector3 = p3 - u_outs[k_nxt] * h
					var arc_len: float = p0.distance_to(p3) * 1.15
					var a_steps: int = maxi(ceili(arc_len / 12.0), 8)
					if k_nxt != 0:
						wp_indices[k_nxt] = fine.size() - 1 + a_steps / 2
					for s: int in range(1, a_steps + 1):
						var t: float = float(s) / float(a_steps)
						var omt: float = 1.0 - t
						var pt: Vector3 = p0 * (omt * omt * omt) + p1 * (3.0 * omt * omt * t) + p2 * (3.0 * omt * t * t) + p3 * (t * t * t)
						fine.append(pt)
				elif k_nxt != 0:
					wp_indices[k_nxt] = fine.size() - 1
	return {"fine": fine, "wp_indices": wp_indices}


func _key_xz(x: float, z: float) -> Vector2:
	return Vector2(snappedf(x, 0.5), snappedf(z, 0.5))


func _list_hero_files() -> Array[String]:
	var out: Array[String] = []
	if DirAccess.dir_exists_absolute("res://data/hero"):
		for fn: String in DirAccess.get_files_at("res://data/hero"):
			if fn.ends_with(".json"):
				out.append("res://data/hero/" + fn)
	out.sort()
	return out


func _get_or_create_node(p: Vector3, pin_y: bool, town: bool, kind: String, radius: float) -> int:
	var pxz := Vector2(p.x, p.z)
	for n: Dictionary in nodes:
		var nxz := Vector2(n["p"][0], n["p"][2])
		if nxz.distance_to(pxz) < SNAP_DIST:
			var nid: int = int(n["id"])
			if pin_y:
				n["p"] = _arr(p)
				_pinned_y[nid] = p.y
			if town:
				n["town"] = true
			if kind != "normal":
				n["kind"] = kind
				n["radius"] = radius
			return nid
	var id: int = nodes.size()
	var y: float = p.y if pin_y else TerrainFn.base_height(p.x, p.z)
	nodes.append({"id": id, "p": _arr(Vector3(p.x, y, p.z)), "town": town, "kind": kind, "radius": radius})
	if pin_y:
		_pinned_y[id] = y
	return id


func _find_node_near(p: Vector3, max_d: float) -> int:
	var pxz := Vector2(p.x, p.z)
	var best: int = -1
	var best_d2: float = max_d * max_d
	for n: Dictionary in nodes:
		var d2: float = Vector2(n["p"][0], n["p"][2]).distance_squared_to(pxz)
		if d2 < best_d2:
			best_d2 = d2
			best = int(n["id"])
	return best


func _node_touches_types(nid: int, all_pieces: Array[Dictionary], types: Array[String]) -> bool:
	var has_hwy: bool = false
	var count: int = 0
	for pc: Dictionary in all_pieces:
		if not pc.has("a"):
			continue
		if int(pc["a"]) == nid or int(pc["b"]) == nid:
			var t: String = str(pc["type"])
			if t in types:
				count += 1
			if t == "highway":
				has_hwy = true
	return has_hwy and count >= 3


func _split_crossings(pieces: Array[Dictionary]) -> Array[Dictionary]:
	var cur: Array[Dictionary] = pieces
	for _round: int in 12:
		var did_split: bool = false
		for i: int in cur.size():
			var pts_a: PackedVector3Array = cur[i]["pts"]
			for j: int in range(i, cur.size()):
				var pts_b: PackedVector3Array = cur[j]["pts"]
				var hit: Dictionary = _find_crossing(pts_a, pts_b, i == j, 50.0)
				if not hit.is_empty():
					var ix_p: Vector3 = hit["pos"]
					var ia: int = hit["ia"]
					var ib: int = hit["ib"]
					var new_list: Array[Dictionary] = []
					for k: int in cur.size():
						if k == i and k == j:
							var s0: PackedVector3Array = pts_a.slice(0, ia + 1) + PackedVector3Array([ix_p])
							var s1: PackedVector3Array = PackedVector3Array([ix_p]) + pts_a.slice(ia + 1, ib + 1) + PackedVector3Array([ix_p])
							var s2: PackedVector3Array = PackedVector3Array([ix_p]) + pts_a.slice(ib + 1)
							for sub: PackedVector3Array in [s0, s1, s2]:
								if sub.size() >= 2:
									new_list.append(_sub_piece(cur[i], RoadGraph.resample(sub, CTRL)))
						elif k == i:
							var sa0: PackedVector3Array = pts_a.slice(0, ia + 1) + PackedVector3Array([ix_p])
							var sa1: PackedVector3Array = PackedVector3Array([ix_p]) + pts_a.slice(ia + 1)
							new_list.append(_sub_piece(cur[i], RoadGraph.resample(sa0, CTRL)))
							new_list.append(_sub_piece(cur[i], RoadGraph.resample(sa1, CTRL)))
						elif k == j:
							var sb0: PackedVector3Array = pts_b.slice(0, ib + 1) + PackedVector3Array([ix_p])
							var sb1: PackedVector3Array = PackedVector3Array([ix_p]) + pts_b.slice(ib + 1)
							new_list.append(_sub_piece(cur[j], RoadGraph.resample(sb0, CTRL)))
							new_list.append(_sub_piece(cur[j], RoadGraph.resample(sb1, CTRL)))
						else:
							new_list.append(cur[k])
					cur = new_list
					did_split = true
					break
			if did_split:
				break
		if not did_split:
			break
	return cur


func _sub_piece(src: Dictionary, pts: PackedVector3Array) -> Dictionary:
	return {
		"name": src["name"],
		"type": src["type"],
		"kind": src["kind"],
		"pts": pts,
		"overpass_zones": [],
		"underpass_zones": [],
	}


func _find_crossing(a: PackedVector3Array, b: PackedVector3Array, same: bool, end_margin: float) -> Dictionary:
	for ia: int in a.size() - 1:
		var a0 := Vector2(a[ia].x, a[ia].z)
		var a1 := Vector2(a[ia + 1].x, a[ia + 1].z)
		var j_start: int = ia + 3 if same else 0
		for ib: int in range(j_start, b.size() - 1):
			if not same and ((ia <= 1 and ib <= 1) or (ia >= a.size() - 3 and ib >= b.size() - 3) or (ia <= 1 and ib >= b.size() - 3) or (ia >= a.size() - 3 and ib <= 1)):
				continue
			var b0 := Vector2(b[ib].x, b[ib].z)
			var b1 := Vector2(b[ib + 1].x, b[ib + 1].z)
			var res: Variant = Geometry2D.segment_intersects_segment(a0, a1, b0, b1)
			if res is Vector2:
				var p2 := res as Vector2
				if p2.distance_to(Vector2(a[0].x, a[0].z)) < end_margin or p2.distance_to(Vector2(a[a.size() - 1].x, a[a.size() - 1].z)) < end_margin:
					continue
				if p2.distance_to(Vector2(b[0].x, b[0].z)) < end_margin or p2.distance_to(Vector2(b[b.size() - 1].x, b[b.size() - 1].z)) < end_margin:
					continue
				return {"ia": ia, "ib": ib, "pos": Vector3(p2.x, 0.0, p2.y)}
	return {}


func _resolve_highway_crossings(hwy_pieces: Array[Dictionary], surf_pieces: Array[Dictionary], ramp_pieces: Array[Dictionary]) -> void:
	var ic_cfg: Array = TerrainFn.def.get("interchanges", [])
	for hpc: Dictionary in hwy_pieces:
		var hpts: PackedVector3Array = hpc["pts"]
		for spc: Dictionary in surf_pieces:
			var spts: PackedVector3Array = spc["pts"]
			var hit: Dictionary = _find_crossing(hpts, spts, false, 20.0)
			if hit.is_empty():
				continue
			var ix_p: Vector3 = hit["pos"]
			var ih: int = hit["ia"]
			var is_i: int = hit["ib"]
			var base_y: float = TerrainFn.base_height(ix_p.x, ix_p.z)
			var under_y: float = base_y - 3.2
			var over_y: float = under_y + OVERPASS_CLEARANCE
			(hpc["overpass_zones"] as Array).append({"idx": ih, "pos": ix_p, "target_y": over_y})
			(spc["underpass_zones"] as Array).append({"idx": is_i, "pos": ix_p, "target_y": under_y})

			for ic: Dictionary in ic_cfg:
				if str(ic.get("kind", "")) != "diamond":
					continue
				var icp: Array = ic["pos"]
				if Vector2(ix_p.x, ix_p.z).distance_to(Vector2(float(icp[0]), float(icp[1]))) < 350.0:
					_build_diamond_ramps(hpc, ih, spc, is_i, ix_p, ramp_pieces)
					break

	for ic: Dictionary in ic_cfg:
		if str(ic.get("kind", "")) != "y_split":
			continue
		var icp: Array = ic["pos"]
		_build_y_flyover_ramp(Vector2(float(icp[0]), float(icp[1])), hwy_pieces, ramp_pieces)


func _build_diamond_ramps(hpc: Dictionary, ih: int, spc: Dictionary, is_i: int, ix_p: Vector3, ramp_pieces: Array[Dictionary]) -> void:
	var hpts: PackedVector3Array = hpc["pts"]
	var spts: PackedVector3Array = spc["pts"]
	var h_step: int = maxi(roundi(260.0 / CTRL), 5)
	var c_step: int = maxi(roundi(200.0 / CTRL), 4)
	var ih_back: int = maxi(ih - h_step, 3)
	var ih_fwd: int = mini(ih + h_step, hpts.size() - 4)
	var ic_a: int = maxi(is_i - c_step, 2)
	var ic_b: int = mini(is_i + c_step, spts.size() - 3)
	if ih_back >= ih - 2 or ih_fwd <= ih + 2 or ic_a >= is_i - 1 or ic_b <= is_i + 1:
		return

	var h_fwd: Vector3 = _dir_xz(hpts, ih)
	var h_rt: Vector3 = h_fwd.cross(Vector3.UP).normalized()
	var p_ca: Vector3 = spts[ic_a]
	var p_cb: Vector3 = spts[ic_b]
	# Determine which side of highway p_ca lies on so ramps don't cross the highway centerline.
	if (p_ca - ix_p).dot(h_rt) < 0.0:
		var tmp: Vector3 = p_ca
		p_ca = p_cb
		p_cb = tmp

	var c_dir_a: Vector3 = (ix_p - p_ca)
	c_dir_a.y = 0.0
	c_dir_a = c_dir_a.normalized()
	var c_dir_b: Vector3 = (ix_p - p_cb)
	c_dir_b.y = 0.0
	c_dir_b = c_dir_b.normalized()

	var ih_back_2: int = maxi(ih - h_step - 2, 2)
	var ih_fwd_2: int = mini(ih + h_step + 2, hpts.size() - 3)

	var specs: Array[Array] = [
		[hpts[ih_back], _dir_xz(hpts, ih_back), p_ca, -c_dir_a],
		[hpts[ih_fwd], -_dir_xz(hpts, ih_fwd), p_ca, -c_dir_a],
		[hpts[ih_back_2], _dir_xz(hpts, ih_back_2), p_cb, -c_dir_b],
		[hpts[ih_fwd_2], -_dir_xz(hpts, ih_fwd_2), p_cb, -c_dir_b],
	]
	for sp: Array in specs:
		var p0: Vector3 = sp[0]
		var t0: Vector3 = sp[1]
		var p1: Vector3 = sp[2]
		var t1: Vector3 = sp[3]
		var rpts: PackedVector3Array = _hermite_arc(p0, t0, p1, t1)
		ramp_pieces.append({
			"name": "ramp_diamond",
			"type": "ramp",
			"kind": "road",
			"pts": RoadGraph.resample(rpts, CTRL),
			"overpass_zones": [],
			"underpass_zones": [],
			"hwy_targets": [p0],
			"surf_targets": [p1],
		})


func _build_y_flyover_ramp(node_xz: Vector2, hwy_pieces: Array[Dictionary], ramp_pieces: Array[Dictionary]) -> void:
	var touching: Array[Dictionary] = []
	for hpc: Dictionary in hwy_pieces:
		var pts: PackedVector3Array = hpc["pts"]
		var d0: float = Vector2(pts[0].x, pts[0].z).distance_to(node_xz)
		var d1: float = Vector2(pts[pts.size() - 1].x, pts[pts.size() - 1].z).distance_to(node_xz)
		if d0 < 30.0:
			touching.append({"pc": hpc, "at_start": true, "dir": _dir_xz(pts, 2)})
		elif d1 < 30.0:
			touching.append({"pc": hpc, "at_start": false, "dir": -_dir_xz(pts, pts.size() - 3)})
	if touching.size() < 3:
		return
	var best_i: int = 0
	var best_j: int = 1
	var best_dot: float = -2.0
	for i: int in touching.size():
		for j: int in range(i + 1, touching.size()):
			var d: float = (touching[i]["dir"] as Vector3).dot(touching[j]["dir"] as Vector3)
			if d > best_dot:
				best_dot = d
				best_i = i
				best_j = j
	var a_info: Dictionary = touching[best_i]
	var b_info: Dictionary = touching[best_j]
	var pa_pts: PackedVector3Array = a_info["pc"]["pts"]
	var pb_pts: PackedVector3Array = b_info["pc"]["pts"]
	var off_i: int = mini(12, pa_pts.size() - 3)
	var off_j: int = mini(12, pb_pts.size() - 3)
	var ia: int = off_i if bool(a_info["at_start"]) else (pa_pts.size() - 1 - off_i)
	var ib: int = off_j if bool(b_info["at_start"]) else (pb_pts.size() - 1 - off_j)
	var pa: Vector3 = pa_pts[ia]
	var pb: Vector3 = pb_pts[ib]
	var ta: Vector3 = -(a_info["dir"] as Vector3)
	var tb: Vector3 = (b_info["dir"] as Vector3)
	var rpts: PackedVector3Array = _hermite_arc(pa, ta, pb, tb)
	var resampled: PackedVector3Array = RoadGraph.resample(rpts, CTRL)
	ramp_pieces.append({
		"name": "ramp_y_slip",
		"type": "ramp",
		"kind": "road",
		"pts": resampled,
		"overpass_zones": [],
		"underpass_zones": [],
		"hwy_targets": [pa, pb],
		"surf_targets": [],
	})


func _hermite_arc(p0: Vector3, t0: Vector3, p1: Vector3, t1: Vector3) -> PackedVector3Array:
	var dist: float = Vector2(p1.x - p0.x, p1.z - p0.z).length()
	var m0: Vector3 = Vector3(t0.x, 0.0, t0.z).normalized() * (dist * 0.55)
	var m1: Vector3 = Vector3(t1.x, 0.0, t1.z).normalized() * (dist * 0.55)
	var out := PackedVector3Array([p0])
	var steps: int = maxi(roundi(dist / 20.0), 10)
	for s: int in range(1, steps + 1):
		var t: float = float(s) / float(steps)
		var t2: float = t * t
		var t3: float = t2 * t
		var h00: float = 2.0 * t3 - 3.0 * t2 + 1.0
		var h10: float = t3 - 2.0 * t2 + t
		var h01: float = -2.0 * t3 + 3.0 * t2
		var h11: float = t3 - t2
		var pt: Vector3 = p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
		pt.y = 0.0
		out.append(pt)
	return out


func _dir_xz(pts: PackedVector3Array, i: int) -> Vector3:
	var a: Vector3 = pts[maxi(i - 1, 0)]
	var b: Vector3 = pts[mini(i + 1, pts.size() - 1)]
	var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
	return d.normalized() if d.length_squared() > 1e-4 else Vector3.FORWARD


func _split_at_targets(pieces: Array[Dictionary], targets: PackedVector3Array) -> Array[Dictionary]:
	if targets.is_empty():
		return pieces
	var out: Array[Dictionary] = []
	for pc: Dictionary in pieces:
		var pts: PackedVector3Array = pc["pts"]
		var cuts: Array[int] = [0]
		for tp: Vector3 in targets:
			var best_i: int = -1
			var best_d2: float = 16.0 * 16.0
			for i: int in range(2, pts.size() - 2):
				var d2: float = Vector2(pts[i].x - tp.x, pts[i].z - tp.z).length_squared()
				if d2 < best_d2:
					best_d2 = d2
					best_i = i
			if best_i > 0 and not cuts.has(best_i):
				cuts.append(best_i)
		cuts.append(pts.size() - 1)
		cuts.sort()
		if cuts.size() == 2:
			out.append(pc)
			continue
		for ci: int in cuts.size() - 1:
			var i0: int = cuts[ci]
			var i1: int = cuts[ci + 1]
			if i1 <= i0:
				continue
			var sub := _sub_piece(pc, pts.slice(i0, i1 + 1))
			for oz: Dictionary in (pc["overpass_zones"] as Array):
				var idx: int = int(oz["idx"])
				if idx >= i0 and idx <= i1:
					var nz: Dictionary = oz.duplicate()
					nz["idx"] = idx - i0
					(sub["overpass_zones"] as Array).append(nz)
			for uz: Dictionary in (pc["underpass_zones"] as Array):
				var idx: int = int(uz["idx"])
				if idx >= i0 and idx <= i1:
					var nz: Dictionary = uz.duplicate()
					nz["idx"] = idx - i0
					(sub["underpass_zones"] as Array).append(nz)
			out.append(sub)
	return out


func _split_bridges_and_overpasses(pieces: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for pc: Dictionary in pieces:
		var pts: PackedVector3Array = pc["pts"]
		var n: int = pts.size()
		if n < 4 or pc["kind"] == "tunnel":
			out.append(pc)
			continue
		var flags := PackedInt32Array()
		flags.resize(n)
		for i: int in n:
			var p: Vector3 = pts[i]
			var rq: Vector4 = TerrainFn.river_query(p.x, p.z)
			if rq.x < rq.z + 18.0:
				flags[i] = 1
			elif TerrainFn._has_lake and TerrainFn.lake_signed_dist(p.x, p.z) < 12.0:
				flags[i] = 1
			elif not TerrainFn._ravine_pts.is_empty() and p.x >= TerrainFn._ravine_min.x and p.x <= TerrainFn._ravine_max.x and p.z >= TerrainFn._ravine_min.y and p.z <= TerrainFn._ravine_max.y:
				if _dist_to_ravine(p.x, p.z) < 92.0:
					flags[i] = 1
		for oz: Dictionary in (pc.get("overpass_zones", []) as Array):
			var center_i: int = int(oz["idx"])
			for j: int in range(maxi(center_i - 1, 1), mini(center_i + 2, n - 1)):
				flags[j] = 2

		if n > 6:
			flags[0] = 0
			flags[n - 1] = 0

		var runs: Array[Vector3i] = []
		var s: int = 0
		for i: int in range(1, n):
			if flags[i] != flags[s] and i - s >= 2:
				runs.append(Vector3i(s, i, flags[s]))
				s = i
		runs.append(Vector3i(s, n - 1, flags[s]))

		if runs.size() == 1 and runs[0].z == 0:
			out.append(pc)
			continue

		for r: Vector3i in runs:
			if r.y <= r.x:
				continue
			var sub := _sub_piece(pc, pts.slice(r.x, r.y + 1))
			sub["kind"] = "bridge" if r.z == 1 else ("overpass" if r.z == 2 else "road")
			for oz: Dictionary in (pc.get("overpass_zones", []) as Array):
				var idx: int = int(oz["idx"])
				if idx >= r.x and idx <= r.y:
					var nz: Dictionary = oz.duplicate()
					nz["idx"] = idx - r.x
					(sub["overpass_zones"] as Array).append(nz)
			for uz: Dictionary in (pc.get("underpass_zones", []) as Array):
				var idx: int = int(uz["idx"])
				if idx >= r.x and idx <= r.y:
					var nz: Dictionary = uz.duplicate()
					nz["idx"] = idx - r.x
					(sub["underpass_zones"] as Array).append(nz)
			out.append(sub)
	return out


func _dist_to_ravine(wx: float, wz: float) -> float:
	var best2: float = 1e18
	for i: int in TerrainFn._ravine_pts.size() - 1:
		var a: Vector3 = TerrainFn._ravine_pts[i]
		var b: Vector3 = TerrainFn._ravine_pts[i + 1]
		var abx: float = b.x - a.x
		var abz: float = b.z - a.z
		var ab2: float = maxf(abx * abx + abz * abz, 1e-4)
		var t: float = clampf(((wx - a.x) * abx + (wz - a.z) * abz) / ab2, 0.0, 1.0)
		var dx: float = wx - (a.x + abx * t)
		var dz: float = wz - (a.z + abz * t)
		best2 = minf(best2, dx * dx + dz * dz)
	return sqrt(best2)


func _set_bridge_min_y(pc: Dictionary) -> void:
	for nid: int in [int(pc["a"]), int(pc["b"])]:
		var p: Vector3 = Vector3(float(nodes[nid]["p"][0]), float(nodes[nid]["p"][1]), float(nodes[nid]["p"][2]))
		var min_y: float = p.y
		var rq: Vector4 = TerrainFn.river_query(p.x, p.z)
		if rq.x < rq.z + 70.0:
			min_y = maxf(min_y, rq.y + (7.0 if pc["type"] == "highway" else 5.0))
		elif TerrainFn._has_lake and TerrainFn.lake_signed_dist(p.x, p.z) < 60.0:
			min_y = maxf(min_y, TerrainFn._lake_y + 3.8)
		elif _dist_to_ravine(p.x, p.z) < 130.0:
			min_y = maxf(min_y, maxf(TerrainFn.base_height(p.x, p.z), 74.0))
		_raise_node_floor(nid, min_y)


func _set_overpass_min_y(pc: Dictionary) -> void:
	var ozs: Array = pc.get("overpass_zones", [])
	if ozs.is_empty():
		return
	var tgt_y: float = float(ozs[0]["target_y"])
	for nid: int in [int(pc["a"]), int(pc["b"])]:
		_raise_node_floor(nid, tgt_y)


func _raise_node_floor(nid: int, floor_y: float) -> void:
	if _pinned_y.has(nid):
		return
	_min_y[nid] = maxf(_min_y.get(nid, -1e9), floor_y)
	if float(nodes[nid]["p"][1]) < _min_y[nid]:
		nodes[nid]["p"][1] = snappedf(_min_y[nid], 0.01)


func _relax_node_heights(pieces: Array[Dictionary]) -> void:
	for _pass: int in 700:
		for pc: Dictionary in pieces:
			if not pc.has("a"):
				continue
			var a: int = pc["a"]
			var b: int = pc["b"]
			if a == b:
				continue
			var type: int = RoadGraph.TYPE_NAMES.find(pc["type"])
			var pts: PackedVector3Array = pc["pts"]
			var elen: float = 0.0
			for i: int in pts.size() - 1:
				elen += pts[i].distance_to(pts[i + 1])
			var max_dy: float = RoadGraph.MAX_GRADE[type] * 0.72 * elen
			var ya: float = nodes[a]["p"][1]
			var yb: float = nodes[b]["p"][1]
			var diff: float = yb - ya
			if absf(diff) > max_dy:
				var excess: float = (absf(diff) - max_dy) * signf(diff)
				var pin_a: bool = _pinned_y.has(a)
				var pin_b: bool = _pinned_y.has(b)
				if not pin_a and not pin_b:
					ya += excess * 0.5
					yb -= excess * 0.5
				elif not pin_a:
					ya += excess
				elif not pin_b:
					yb -= excess
				if _min_y.has(a):
					ya = maxf(ya, _min_y[a])
				if _min_y.has(b):
					yb = maxf(yb, _min_y[b])
				nodes[a]["p"][1] = snappedf(ya, 0.01)
				nodes[b]["p"][1] = snappedf(yb, 0.01)


func _solve_edge_vertical(pc: Dictionary) -> void:
	var pts: PackedVector3Array = pc["pts"]
	var n: int = pts.size()
	if n < 2 or not pc.has("a"):
		return
	var type: int = RoadGraph.TYPE_NAMES.find(pc["type"])
	var a: int = int(pc["a"])
	var b: int = int(pc["b"])
	var ya: float = float(nodes[a]["p"][1])
	var yb: float = float(nodes[b]["p"][1])
	var y := PackedFloat32Array()
	y.resize(n)
	var is_struct: bool = (pc["kind"] == "bridge" or pc["kind"] == "overpass" or pc["kind"] == "tunnel")
	for i: int in n:
		var t: float = float(i) / float(n - 1)
		if is_struct:
			var arch: float = 0.7 * sin(t * PI) if pc["kind"] == "bridge" else 0.0
			y[i] = lerpf(ya, yb, t) + arch
		else:
			y[i] = TerrainFn.base_height(pts[i].x, pts[i].z)
	y[0] = ya
	y[n - 1] = yb

	if not is_struct:
		for uz: Dictionary in (pc.get("underpass_zones", []) as Array):
			var c_i: int = int(uz["idx"])
			var tgt_y: float = float(uz["target_y"])
			for i: int in range(1, n - 1):
				var dist_m: float = absf(i - c_i) * CTRL
				if dist_m < 170.0:
					var w: float = 1.0 - smoothstep(25.0, 170.0, dist_m)
					y[i] = lerpf(y[i], tgt_y, w)
		for oz: Dictionary in (pc.get("overpass_zones", []) as Array):
			var c_i: int = int(oz["idx"])
			var tgt_y: float = float(oz["target_y"])
			for i: int in range(1, n - 1):
				var dist_m: float = absf(i - c_i) * CTRL
				if dist_m < 210.0:
					var w: float = 1.0 - smoothstep(25.0, 210.0, dist_m)
					y[i] = lerpf(y[i], tgt_y, w)

		var smooth_passes: int = 36 if (type == RoadGraph.HIGHWAY or type == RoadGraph.RAMP) else 18
		for _pass: int in smooth_passes:
			var prev: float = y[0]
			for i: int in range(1, n - 1):
				var cur: float = y[i]
				y[i] = (prev + 2.0 * cur + y[i + 1]) * 0.25
				prev = cur

	var ds: float = pts[0].distance_to(pts[1])
	var g: float = RoadGraph.MAX_GRADE[type] * 0.82 * ds
	for _it: int in 40:
		var any_over: bool = false
		for i: int in n - 1:
			var dy: float = y[i + 1] - y[i]
			if absf(dy) > g:
				any_over = true
				var fix: float = (absf(dy) - g) * signf(dy) * 0.45
				if i > 0:
					y[i] += fix
				if i + 1 < n - 1:
					y[i + 1] -= fix
		if not any_over:
			break
	for i: int in range(1, n - 1):
		var rem: float = (n - 1 - i) * g
		y[i] = clampf(y[i], maxf(y[i - 1] - g, y[n - 1] - rem), minf(y[i - 1] + g, y[n - 1] + rem))
	for i: int in range(n - 2, 0, -1):
		y[i] = clampf(y[i], y[i + 1] - g, y[i + 1] + g)
	pc["solved_y"] = y


func _emit_generated_edge(pc: Dictionary) -> void:
	if not pc.has("solved_y"):
		return
	var pts: PackedVector3Array = pc["pts"]
	var n: int = pts.size()
	if n < 2:
		return
	var rtype: String = str(pc["type"])
	var type: int = RoadGraph.TYPE_NAMES.find(rtype)
	var a: int = int(pc["a"])
	var b: int = int(pc["b"])
	if a == b and n < 4:
		return
	var y: PackedFloat32Array = pc["solved_y"]
	var ds: float = pts[0].distance_to(pts[1])
	var worst: float = 0.0
	var out: Array = []
	for i: int in n:
		if i > 0:
			worst = maxf(worst, absf(y[i] - y[i - 1]) / maxf(ds, 0.1))
		if i == 0:
			out.append([nodes[a]["p"][0], snappedf(y[0], 0.01), nodes[a]["p"][2]])
		elif i == n - 1:
			out.append([nodes[b]["p"][0], snappedf(y[n - 1], 0.01), nodes[b]["p"][2]])
		else:
			out.append(_arr(Vector3(pts[i].x, y[i], pts[i].z)))
	if worst > RoadGraph.MAX_GRADE[type]:
		print("NETWORK FAIL: %s grade %.3f (a=%d y=%.1f b=%d y=%.1f n=%d)" % [pc["name"], worst, a, y[0], b, y[n - 1], n])
		bad += 1
	var kind: String = str(pc["kind"])
	edges.append({
		"id": edges.size(),
		"a": a,
		"b": b,
		"type": rtype,
		"kind": kind,
		"elevated": (kind == "bridge" or kind == "overpass"),
		"pts": out,
	})


func _pick_spawn() -> Dictionary:
	var best_e: int = 0
	var best_score: float = -1e9
	var target_xz := Vector2(-200.0, 1200.0)
	for e: int in edges.size():
		var ed: Dictionary = edges[e]
		if str(ed["type"]) != "highway" or bool(ed["elevated"]):
			continue
		var pts: Array = ed["pts"]
		if pts.size() < 40:
			continue
		var mid_i: int = pts.size() / 2
		var mid: Array = pts[mid_i]
		var dist_target: float = Vector2(float(mid[0]), float(mid[2])).distance_to(target_xz)
		var len_m: float = pts.size() * CTRL
		var i_lo: int = maxi(mid_i - 8, 1)
		var i_hi: int = mini(mid_i + 8, pts.size() - 2)
		var d_lo := Vector2(float(pts[i_lo][0]) - float(pts[i_lo - 1][0]), float(pts[i_lo][2]) - float(pts[i_lo - 1][2])).normalized()
		var d_hi := Vector2(float(pts[i_hi + 1][0]) - float(pts[i_hi][0]), float(pts[i_hi + 1][2]) - float(pts[i_hi][2])).normalized()
		var straight_bonus: float = maxf(d_lo.dot(d_hi), 0.0) * 3000.0
		var score: float = len_m + straight_bonus - dist_target * 0.45
		if score > best_score:
			best_score = score
			best_e = e
	var spts: Array = edges[best_e]["pts"]
	var s_ctrl_i: int = spts.size() / 2
	var approx_dense_i: int = s_ctrl_i * roundi(CTRL / RoadGraph.STEP)
	return {"edge": best_e, "i": approx_dense_i, "dir": 1}


func _count_kinds() -> Dictionary:
	var c := {"bridge": 0, "overpass": 0, "tunnel": 0, "roundabout": 0, "merge": 0}
	for ed: Dictionary in edges:
		var k: String = str(ed.get("kind", "road"))
		if c.has(k):
			c[k] += 1
	for nd: Dictionary in nodes:
		var nk: String = str(nd.get("kind", "normal"))
		if c.has(nk):
			c[nk] += 1
	return c


func _check_flat_highway_nodes() -> void:
	for nid: int in RoadGraph.nodes.size():
		var es: PackedInt32Array = RoadGraph.node_edges[nid]
		var has_hwy: bool = false
		var has_non_hwy_surf: bool = false
		for e: int in es:
			if RoadGraph.e_type[e] == RoadGraph.HIGHWAY:
				has_hwy = true
			elif RoadGraph.e_type[e] != RoadGraph.RAMP:
				has_non_hwy_surf = true
		if has_hwy and has_non_hwy_surf:
			print("NETWORK FAIL: flat crossing on highway node %d" % nid)
			bad += 1


func _check_connected() -> bool:
	if nodes.is_empty():
		return false
	var adj: Array[Array] = []
	adj.resize(nodes.size())
	for i: int in nodes.size():
		adj[i] = []
	for e: Dictionary in edges:
		adj[int(e["a"])].append(int(e["b"]))
		adj[int(e["b"])].append(int(e["a"]))
	var seen: Dictionary[int, bool] = {0: true}
	var q: Array[int] = [0]
	while not q.is_empty():
		var u: int = q.pop_back()
		for v: int in adj[u]:
			if not seen.has(v):
				seen[v] = true
				q.append(v)
	if seen.size() != nodes.size():
		var unvis: int = 0
		for i: int in nodes.size():
			if not seen.has(i):
				unvis += 1
				if unvis <= 10:
					print("  disconnected node %d at %s" % [i, nodes[i]["p"]])
		print("  total disconnected nodes: %d / %d" % [unvis, nodes.size()])
	return seen.size() == nodes.size()


func _check_radii() -> void:
	var min_r := PackedFloat32Array([1e9, 1e9, 1e9, 1e9, 1e9, 1e9])
	for e: int in RoadGraph.e_pts.size():
		var t: int = RoadGraph.e_type[e]
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var ds: float = RoadGraph.e_step[e] * 4.0
		for i: int in range(4, pts.size() - 4, 4):
			var v0 := Vector2(pts[i].x - pts[i - 4].x, pts[i].z - pts[i - 4].z).normalized()
			var v1 := Vector2(pts[i + 4].x - pts[i].x, pts[i + 4].z - pts[i].z).normalized()
			var ang: float = acos(clampf(v0.dot(v1), -1.0, 1.0))
			if ang > 0.01:
				min_r[t] = minf(min_r[t], ds / ang)
	print("min radius (m): highway %.0f country %.0f mountain %.0f city %.0f ramp %.0f rural %.0f" % [
		min_r[0], min_r[1], min_r[2], min_r[3], min_r[4], min_r[5]])


func _arr(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]
