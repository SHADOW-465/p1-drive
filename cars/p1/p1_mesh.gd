extends Node3D
## P1-inspired procedural meshes (PLAN T07): lofted shell with cut wheel arches, canopy, panel
## details, wing, flaps, wheels and light strips. Built once, shared between instances.
## Attached to the Body node; fills meshes into sibling nodes.

const PAINT: Color = Color(1.0, 0.5, 0.0, 0.28)  # sRGB, a = roughness
const BLACK: Color = Color(0.035, 0.035, 0.04, 0.5)
const GLASS: Color = Color(0.03, 0.04, 0.055, 0.05)
const GREY: Color = Color(0.3, 0.3, 0.32, 0.35)
const TYRE: Color = Color(0.04, 0.04, 0.04, 0.9)
const LAMP: Color = Color(1.0, 1.0, 1.0, 0.3)

# shell stations: z, y bottom, y centre top, y fender crest, half width, bottom half width
const ST: PackedFloat32Array = [
	-2.57, 0.22, 0.34, 0.33, 0.30, 0.25,
	-2.50, 0.17, 0.42, 0.42, 0.62, 0.55,
	-2.35, 0.14, 0.48, 0.52, 0.82, 0.76,
	-2.10, 0.13, 0.53, 0.63, 0.93, 0.86,
	-1.80, 0.13, 0.57, 0.73, 0.965, 0.90,
	-1.47, 0.13, 0.61, 0.79, 0.975, 0.90,
	-1.10, 0.13, 0.67, 0.77, 0.965, 0.90,
	-0.70, 0.13, 0.73, 0.74, 0.955, 0.91,
	-0.20, 0.13, 0.76, 0.75, 0.955, 0.92,
	0.30, 0.13, 0.80, 0.78, 0.965, 0.92,
	0.75, 0.13, 0.85, 0.84, 0.98, 0.92,
	1.20, 0.14, 0.87, 0.87, 0.985, 0.91,
	1.65, 0.18, 0.86, 0.85, 0.965, 0.88,
	1.95, 0.26, 0.84, 0.82, 0.92, 0.82,
	2.02, 0.32, 0.80, 0.78, 0.86, 0.76,
]
# canopy stations: z, half width, top y
const CAN: PackedFloat32Array = [
	-1.15, 0.50, 0.66,
	-0.85, 0.66, 0.90,
	-0.50, 0.71, 1.07,
	-0.10, 0.71, 1.15,
	0.30, 0.67, 1.14,
	0.70, 0.58, 1.06,
	1.10, 0.46, 0.96,
	1.45, 0.36, 0.89,
	1.70, 0.30, 0.85,
]
const ARCH: PackedFloat32Array = [-1.4685, 0.34, 0.42, 1.2015, 0.36, 0.44]  # z, y, radius per axle
const Z0: float = -2.57
const Z1: float = 2.02
const NZ: int = 52
const NJ: int = 44  # ring samples (22 per side, s = 0..11 in half steps)

static var _meshes: Dictionary = {}


func _ready() -> void:
	if _meshes.is_empty():
		_build_all()
	var car: Node = get_parent()
	_mi(self, "Shell", "shell")
	_mi(car.get_node("Aero/WingPivot"), "Wing", "wing")
	_mi(car.get_node("Aero/Struts"), "Mesh", "struts")
	_mi(car.get_node("Aero/FlapL"), "Mesh", "flap")
	_mi(car.get_node("Aero/FlapR"), "Mesh", "flap")
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.25, 0.25, 0.27)
	disc_mat.metallic = 0.8
	disc_mat.roughness = 0.4
	disc_mat.emission_enabled = true
	disc_mat.emission = Color(1.0, 0.25, 0.05)
	disc_mat.emission_energy_multiplier = 0.0
	for w: String in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		var key: String = ("wheel_f" if w[5] == "F" else "wheel_r") + ("_l" if w[6] == "L" else "_r")
		_mi(car.get_node(w), "Rim", key)
		_mi(car.get_node(w), "Disc", key.replace("wheel", "disc")).material_override = disc_mat
	var lights: Node = car.get_node("Lights")
	_mi(lights, "Head", "head").material_override = _glow_mat(Color(1.0, 0.97, 0.9), 1.5)
	_mi(lights, "Tail", "tail").material_override = _glow_mat(Color(1.0, 0.05, 0.02), 0.4)
	_mi(lights, "Reverse", "reverse").material_override = _glow_mat(Color(1.0, 1.0, 1.0), 0.0)


func _mi(parent: Node, node_name: String, key: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _meshes[key]
	parent.add_child(mi)
	return mi


static func _glow_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col * 0.5
	m.roughness = 0.3
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


static func _build_all() -> void:
	var paint := ShaderMaterial.new()
	paint.shader = preload("res://shaders/car_paint.gdshader")
	var shell := MeshBuilder.new()
	var head := MeshBuilder.new()
	var tail := MeshBuilder.new()
	_shell(shell)
	_canopy(shell)
	_details(shell, head, tail)
	_meshes["shell"] = shell.mesh(paint)
	_meshes["head"] = head.mesh()
	_meshes["tail"] = tail.mesh()
	var rev := MeshBuilder.new()
	rev.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.40, 2.03)), Vector3(0.12, 0.035, 0.02), LAMP)
	_meshes["reverse"] = rev.mesh()
	_meshes["wing"] = _wing().mesh(paint)
	var struts := MeshBuilder.new()
	for sx: float in [-0.45, 0.45]:
		struts.box(Transform3D(Basis.IDENTITY, Vector3(sx, -0.19, 0.0)), Vector3(0.05, 0.36, 0.09), BLACK)
	_meshes["struts"] = struts.mesh(paint)
	var flap := MeshBuilder.new()
	flap.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.1)), Vector3(0.5, 0.012, 0.2), BLACK)
	_meshes["flap"] = flap.mesh(paint)
	for side: float in [-1.0, 1.0]:
		var sfx: String = "_l" if side < 0.0 else "_r"
		_meshes["wheel_f" + sfx] = _wheel(0.34, 0.25, side).mesh(paint)
		_meshes["wheel_r" + sfx] = _wheel(0.36, 0.32, side).mesh(paint)
		_meshes["disc_f" + sfx] = _disc(0.25, side).mesh()
		_meshes["disc_r" + sfx] = _disc(0.32, side).mesh()


# ---- parametric shell ----

static func _interp(tab: PackedFloat32Array, stride: int, z: float) -> PackedFloat32Array:
	var cnt: int = tab.size() / stride
	var i: int = 0
	while i < cnt - 2 and z > tab[(i + 1) * stride]:
		i += 1
	var i0: int = maxi(i - 1, 0)
	var i3: int = mini(i + 2, cnt - 1)
	var z1: float = tab[i * stride]
	var dz: float = tab[(i + 1) * stride] - z1
	var t: float = clampf((z - z1) / dz, 0.0, 1.0)
	var out := PackedFloat32Array()
	for k: int in range(1, stride):
		out.append(cubic_interpolate_in_time(tab[i * stride + k], tab[(i + 1) * stride + k], tab[i0 * stride + k],
			tab[i3 * stride + k], t, dz, tab[i0 * stride] - z1, tab[i3 * stride] - z1))
	return out


## Point on the shell: s = 0 (bottom centre) .. 11 (top centre), side = +-1.
static func _p(z: float, s: float, side: float) -> Vector3:
	var p: PackedFloat32Array = _interp(ST, 6, z)
	var yb: float = p[0]
	var yc: float = p[1]
	var yf: float = p[2]
	var ws: float = p[3]
	var wb: float = p[4]
	var k: PackedVector2Array = [
		Vector2(0.0, yb), Vector2(0.5 * wb, yb), Vector2(0.97 * wb, yb),
		Vector2(lerpf(wb, ws, 0.6), yb + 0.05),
		Vector2(ws, lerpf(yb, yf, 0.32)), Vector2(ws, lerpf(yb, yf, 0.56)),
		Vector2(ws * 0.98, lerpf(yb, yf, 0.80)), Vector2(ws * 0.93, yf - 0.03),
		Vector2(ws * 0.84, yf), Vector2(ws * 0.62, lerpf(yf, yc, 0.6)), Vector2(ws * 0.36, yc), Vector2(0.0, yc)]
	var i: int = clampi(int(s), 0, 10)
	var q: Vector2 = k[i].lerp(k[i + 1], s - i)
	return Vector3(side * q.x, q.y, z)


static func _nrm(z: float, s: float, side: float) -> Vector3:
	var dz: Vector3 = _p(minf(z + 0.03, Z1), s, side) - _p(maxf(z - 0.03, Z0), s, side)
	var ds: Vector3 = _p(z, minf(s + 0.3, 11.0), side) - _p(z, maxf(s - 0.3, 0.0), side)
	return (ds.cross(dz) * side).normalized()  # s runs bottom -> side -> top, so this is outward


static func _shell(mb: MeshBuilder) -> void:
	var g: Array[PackedVector3Array] = []
	var gn: Array[PackedVector3Array] = []
	var inside: Array[PackedByteArray] = []
	for i: int in NZ + 1:
		var z: float = lerpf(Z0, Z1, float(i) / NZ)
		var row := PackedVector3Array()
		var nrow := PackedVector3Array()
		var irow := PackedByteArray()
		for j: int in NJ + 1:
			var side: float = 1.0 if j <= NJ / 2 else -1.0
			var s: float = (j if j <= NJ / 2 else NJ - j) * 0.5
			var pt: Vector3 = _p(z, s, side)
			nrow.append(_nrm(z, s, side))
			var ins: int = 0
			if absf(pt.x) > 0.6 and s >= 1.5 and s <= 9.0:  # cut the wheel arches
				for a: int in 2:
					var c: Vector2 = Vector2(ARCH[a * 3], ARCH[a * 3 + 1])
					var d: Vector2 = Vector2(pt.z, pt.y) - c
					var r: float = ARCH[a * 3 + 2]
					if d.length() < r:
						ins = 1
						if d.length() > r - 0.13:  # near the edge: snap onto the circle
							d = d.normalized() * r
							pt = Vector3(pt.x, c.y + d.y, c.x + d.x)
			row.append(pt)
			irow.append(ins)
		g.append(row)
		gn.append(nrow)
		inside.append(irow)
	for i: int in NZ:
		var zc: float = lerpf(Z0, Z1, (i + 0.5) / NZ)
		for j: int in NJ:
			var s_low: float = minf(j if j <= NJ / 2 else NJ - j, (j + 1) if j + 1 <= NJ / 2 else NJ - j - 1) * 0.5
			var col: Color = BLACK if s_low < (3.5 if zc > -2.0 else 2.5) else PAINT
			var idx: Array[Vector2i] = [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
			for t: Array in [[0, 1, 2], [0, 2, 3]]:
				var a: Vector2i = idx[t[0]]
				var b: Vector2i = idx[t[1]]
				var d: Vector2i = idx[t[2]]
				if inside[a.x][a.y] + inside[b.x][b.y] + inside[d.x][d.y] == 3:
					continue
				mb.tri(g[a.x][a.y], g[b.x][b.y], g[d.x][d.y], gn[a.x][a.y], gn[b.x][b.y], gn[d.x][d.y], col)
	# end caps
	for e: int in 2:
		var row: PackedVector3Array = g[0] if e == 0 else g[NZ]
		var nn: Vector3 = Vector3(0.0, 0.0, -1.0 if e == 0 else 1.0)
		var mid: Vector3 = (row[0] + row[NJ / 2]) * 0.5
		for j: int in NJ:
			mb.tri(mid, row[j], row[j + 1], nn, nn, nn, PAINT if e == 0 else BLACK)
	# arch liners: tunnel + inner wall
	for a: int in 2:
		var az: float = ARCH[a * 3]
		var ay: float = ARCH[a * 3 + 1]
		var r: float = ARCH[a * 3 + 2]
		for side: float in [-1.0, 1.0]:
			var x_out: float = side * (_interp(ST, 6, az)[3] - 0.012)
			var x_in: float = side * 0.56
			var prev: Vector3 = Vector3.ZERO
			for k: int in 15:
				var ang: float = lerpf(-0.32, PI + 0.32, k / 14.0)
				var dir: Vector3 = Vector3(0.0, sin(ang), cos(ang))
				var cur: Vector3 = Vector3(0.0, ay, az) + dir * r
				if k > 0:
					var pdir: Vector3 = (prev - Vector3(0.0, ay, az)) / r
					mb.quad(prev + Vector3(x_out, 0, 0), cur + Vector3(x_out, 0, 0), cur + Vector3(x_in, 0, 0), prev + Vector3(x_in, 0, 0),
						-pdir, -dir, -dir, -pdir, BLACK)
					var cn: Vector3 = Vector3(side, 0.0, 0.0)
					mb.tri(Vector3(x_in, ay, az), prev + Vector3(x_in, 0, 0), cur + Vector3(x_in, 0, 0), cn, cn, cn, BLACK)
				prev = cur


static func _canopy_pt(z: float, a: float) -> Vector3:
	var c: PackedFloat32Array = _interp(CAN, 3, z)
	var y0: float = _interp(ST, 6, z)[1] - 0.05
	var h: float = maxf(c[1] - y0, 0.02)
	var ca: float = cos(a)
	return Vector3(c[0] * signf(ca) * pow(absf(ca), 0.7), y0 + h * pow(sin(a), 0.7), z)


static func _canopy(mb: MeshBuilder) -> void:
	const RZ: int = 24
	const RA: int = 18
	var g: Array[PackedVector3Array] = []
	for i: int in RZ + 1:
		var row := PackedVector3Array()
		for j: int in RA + 1:
			row.append(_canopy_pt(lerpf(-1.15, 1.70, float(i) / RZ), PI * j / RA))
		g.append(row)
	for i: int in RZ:
		var zc: float = lerpf(-1.15, 1.70, (i + 0.5) / RZ)
		for j: int in RA:
			var af: float = 180.0 * (j + 0.5) / RA
			af = minf(af, 180.0 - af)
			var col: Color = GLASS
			if zc > 0.45:
				col = BLACK if af > 50.0 and zc > 0.65 else PAINT
			elif zc > -0.42 and af > 60.0:
				col = PAINT
			var nn: Array[Vector3] = []
			for q: Vector2i in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]:
				var dz: Vector3 = g[mini(q.x + 1, RZ)][q.y] - g[maxi(q.x - 1, 0)][q.y]
				var da: Vector3 = g[q.x][mini(q.y + 1, RA)] - g[q.x][maxi(q.y - 1, 0)]
				var v: Vector3 = dz.cross(da).normalized()
				nn.append(v if v.y + absf(v.x) * signf(g[q.x][q.y].x) * signf(v.x) > 0.0 else -v)
			mb.quad(g[i][j], g[i + 1][j], g[i + 1][j + 1], g[i][j + 1], nn[0], nn[1], nn[2], nn[3], col)
	# roof snorkel
	var top: float = _interp(CAN, 3, 0.35)[1]
	mb.box(Transform3D(Basis(Vector3.RIGHT, -0.08), Vector3(0.0, top + 0.015, 0.45)), Vector3(0.26, 0.07, 0.5), PAINT)
	mb.box(Transform3D(Basis(Vector3.RIGHT, -0.08), Vector3(0.0, top + 0.02, 0.195)), Vector3(0.21, 0.045, 0.012), BLACK)


## Re-samples the shell between (z0..z1, s0..s1) on both sides, lifted by off along the normal.
static func _patch(mb: MeshBuilder, z0: float, z1: float, s0: float, s1: float, col: Color, off: float = 0.006) -> void:
	var nz: int = maxi(1, int(ceil((z1 - z0) / 0.1)))
	var ns: int = maxi(1, int(ceil((s1 - s0) * 2.0)))
	for side: float in [-1.0, 1.0]:
		for i: int in nz:
			for j: int in ns:
				var p: Array[Vector3] = []
				var nn: Array[Vector3] = []
				for q: Vector2i in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]:
					var z: float = lerpf(z0, z1, float(q.x) / nz)
					var s: float = lerpf(s0, s1, float(q.y) / ns)
					var v: Vector3 = _nrm(z, s, side)
					nn.append(v)
					p.append(_p(z, s, side) + v * off)
				mb.quad(p[0], p[1], p[2], p[3], nn[0], nn[1], nn[2], nn[3], col)


static func _details(mb: MeshBuilder, head: MeshBuilder, tail: MeshBuilder) -> void:
	_patch(mb, -2.53, -2.33, 3.2, 6.3, BLACK)  # front intakes
	_patch(mb, -1.95, -1.55, 9.3, 10.5, BLACK)  # hood vents
	_patch(mb, 0.12, 0.74, 4.5, 7.3, BLACK)  # side intakes
	_patch(mb, -0.80, -0.788, 3.5, 8.6, BLACK, 0.004)  # door shut lines
	_patch(mb, 0.10, 0.112, 3.5, 8.6, BLACK, 0.004)
	_patch(mb, 1.50, 1.98, 9.2, 11.0, BLACK)  # rear deck mesh
	_patch(head, -2.37, -2.07, 7.0, 8.7, LAMP)
	# tail-light arc following the rear edge
	var ctr: Vector3 = Vector3(0.0, 0.55, Z1 + 0.008)
	for side: float in [-1.0, 1.0]:
		for j: int in 12:
			var a: Vector3 = _p(Z1, 4.4 + j * 0.5, side) + Vector3(0, 0, 0.008)
			var b: Vector3 = _p(Z1, 4.9 + j * 0.5, side) + Vector3(0, 0, 0.008)
			tail.flat(ctr.lerp(a, 0.97), ctr.lerp(b, 0.97), ctr.lerp(b, 0.89), ctr.lerp(a, 0.89), Vector3.BACK, LAMP)
		# mirrors
		mb.box(Transform3D(Basis.IDENTITY, Vector3(side * 1.0, 0.86, -0.72)), Vector3(0.15, 0.075, 0.09), PAINT)
		mb.box(Transform3D(Basis.IDENTITY, Vector3(side * 0.88, 0.82, -0.72)), Vector3(0.16, 0.025, 0.05), BLACK)
	mb.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.135, -2.36)), Vector3(1.5, 0.02, 0.42), BLACK)  # splitter
	for k: int in 6:  # diffuser fins
		mb.box(Transform3D(Basis(Vector3.RIGHT, 0.3), Vector3(-0.5 + k * 0.2, 0.3, 1.9)), Vector3(0.016, 0.1, 0.24), BLACK)
	mb.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.57, 2.02)), Vector3(0.30, 0.10, 0.05), GREY)  # exhaust


static func _wing() -> MeshBuilder:
	var mb := MeshBuilder.new()
	# section (z, y): leading edge at -z
	var sec: PackedVector2Array = [Vector2(-0.17, 0.0), Vector2(-0.10, 0.017), Vector2(0.02, 0.02), Vector2(0.17, 0.005),
		Vector2(0.17, -0.004), Vector2(0.02, -0.014), Vector2(-0.10, -0.012)]
	var xs: PackedFloat32Array = [-0.82, -0.45, 0.0, 0.45, 0.82]
	for i: int in xs.size() - 1:
		for k: int in sec.size():
			var a: Vector2 = sec[k]
			var b: Vector2 = sec[(k + 1) % sec.size()]
			var e: Vector2 = b - a
			var hint: Vector3 = Vector3(0.0, -e.x, e.y)  # outward for a clockwise (z, y) outline
			mb.flat(Vector3(xs[i], a.y, a.x), Vector3(xs[i + 1], a.y, a.x), Vector3(xs[i + 1], b.y, b.x), Vector3(xs[i], b.y, b.x),
				hint, PAINT if k < 3 else BLACK)
	for side: float in [-1.0, 1.0]:
		mb.box(Transform3D(Basis.IDENTITY, Vector3(side * 0.825, 0.012, 0.0)), Vector3(0.012, 0.075, 0.36), BLACK)
	return mb


static func _wheel(r: float, w: float, side: float) -> MeshBuilder:
	var mb := MeshBuilder.new()
	var rr: float = r - 0.085  # rim radius
	var h: float = w * 0.5
	mb.lathe([Vector2(-h, rr), Vector2(-h, r - 0.035), Vector2(-h + 0.035, r), Vector2(h - 0.035, r),
		Vector2(h, r - 0.035), Vector2(h, rr)], 20, TYRE)
	mb.lathe([Vector2(-h, rr), Vector2(h, rr)], 20, GREY, true)  # barrel
	var xo: float = side * (h - 0.03)  # spoke plane near the outer face
	mb.lathe([Vector2(side * (h - 0.13), rr), Vector2(side * (h - 0.13), 0.0)] if side > 0.0 else
		[Vector2(side * (h - 0.13), 0.0), Vector2(side * (h - 0.13), rr)], 20, BLACK)  # backing plate
	for k: int in 10:  # five twin spokes
		var ang: float = TAU * (k / 2) / 5.0 + (0.16 if k % 2 == 0 else -0.16)
		var b: Basis = Basis(Vector3.RIGHT, ang)
		mb.box(Transform3D(b, Vector3(xo, 0, 0) + b * Vector3(0.0, rr * 0.5 + 0.02, 0.0)), Vector3(0.03, rr - 0.04, 0.028), GREY)
	mb.lathe([Vector2(xo + side * 0.02, 0.0), Vector2(xo + side * 0.02, 0.065), Vector2(xo - side * 0.03, 0.075)] if side < 0.0 else
		[Vector2(xo - side * 0.03, 0.075), Vector2(xo + side * 0.02, 0.065), Vector2(xo + side * 0.02, 0.0)], 10, GREY)  # hub
	return mb


static func _disc(w: float, side: float) -> MeshBuilder:
	var mb := MeshBuilder.new()
	var x: float = side * (w * 0.5 - 0.10)
	mb.lathe([Vector2(x, 0.20), Vector2(x, 0.09)] if side > 0.0 else [Vector2(x, 0.09), Vector2(x, 0.20)], 20, GREY)
	return mb
