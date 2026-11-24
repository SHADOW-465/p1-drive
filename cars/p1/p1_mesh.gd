class_name P1Mesh
extends Node3D
## P1 procedural meshes (PLAN T07, T17a): spline-lofted shell with cut wheel arches and door
## scallops, teardrop canopy, wing, flaps, 10-spoke wheels, calipers and light strips.
## Panel colours, intakes, lamp housings and shut lines are masks in car_paint.gdshader.
## Built once, shared between instances. Attached to the Body node; fills meshes into siblings.
## Dimensions follow the real car: L 4588, W 1946, H 1188, wheelbase 2670 mm.

const PAINT: Color = Color(1.0, 0.36, 0.02, 0.3)  # only for the non-shader viewers; shader uses paint_color
const BLACK: Color = Color(0.03, 0.03, 0.035, 0.45)  # sRGB, a = roughness
const GREY: Color = Color(0.55, 0.55, 0.57, 0.3)
const DARK: Color = Color(0.13, 0.13, 0.14, 0.32)
const TYRE: Color = Color(0.035, 0.035, 0.035, 0.85)
const LAMP: Color = Color(1.0, 1.0, 1.0, 0.3)
const CALIPER: Color = Color(0.96, 0.46, 0.04, 0.28)
const TITANIUM: Color = Color(0.62, 0.59, 0.54, 0.24)
const ALLOY: Color = Color(0.24, 0.25, 0.28, 0.26)
# material ids for MeshBuilder.cur_uv.y (see car_paint.gdshader)
const M_PLAIN: float = -1.0
const M_GRILLE: float = -2.0
const M_PAINT: float = -3.0
const M_METAL: float = -4.0
const M_CARBON: float = -5.0
const M_GLASS: float = -6.0

# shell stations: z, y bottom, y centre top, y fender crest, half width, bottom half width, y valley
const ST: PackedFloat32Array = [
	-2.57, 0.19, 0.43, 0.40, 0.22, 0.18, 0.42,
	-2.555, 0.175, 0.445, 0.425, 0.42, 0.36, 0.435,
	-2.50, 0.16, 0.475, 0.465, 0.64, 0.56, 0.46,
	-2.40, 0.14, 0.51, 0.53, 0.79, 0.72, 0.495,
	-2.20, 0.13, 0.555, 0.615, 0.90, 0.84, 0.535,
	-2.00, 0.13, 0.595, 0.685, 0.945, 0.88, 0.57,
	-1.75, 0.13, 0.64, 0.765, 0.962, 0.90, 0.61,
	-1.47, 0.13, 0.70, 0.805, 0.968, 0.90, 0.67,
	-1.15, 0.13, 0.775, 0.80, 0.962, 0.90, 0.75,
	-0.70, 0.13, 0.80, 0.775, 0.950, 0.91, 0.77,
	-0.20, 0.13, 0.80, 0.78, 0.945, 0.92, 0.78,
	0.30, 0.13, 0.82, 0.81, 0.955, 0.92, 0.80,
	0.75, 0.13, 0.86, 0.87, 0.970, 0.92, 0.84,
	1.20, 0.14, 0.885, 0.905, 0.973, 0.91, 0.87,
	1.60, 0.17, 0.875, 0.89, 0.965, 0.89, 0.865,
	1.90, 0.24, 0.85, 0.86, 0.93, 0.84, 0.845,
	2.02, 0.30, 0.83, 0.835, 0.885, 0.78, 0.825,
]
# canopy stations: z, half width, top y
const CAN: PackedFloat32Array = [
	-1.18, 0.52, 0.74,
	-0.90, 0.67, 0.93,
	-0.55, 0.715, 1.085,
	-0.20, 0.72, 1.17,
	0.10, 0.70, 1.186,
	0.45, 0.64, 1.14,
	0.85, 0.54, 1.05,
	1.25, 0.42, 0.96,
	1.60, 0.33, 0.90,
	1.75, 0.28, 0.87,
]
const CAN_Z0: float = -1.18
const CAB_Z0: float = -1.06  # cabin opening in the shell deck, z range
const CAB_Z1: float = 0.76
const CAN_Z1: float = 1.75
const ARCH: PackedFloat32Array = [-1.4685, 0.34, 0.40, 1.2015, 0.36, 0.42]  # z, y, radius per axle
const Z0: float = -2.57
const Z1: float = 2.02
const NZ: int = 96
const LAMP_A: Vector2 = Vector2(0.50, -2.36)  # headlamp leaf axis in (|x|, z)
const LAMP_B: Vector2 = Vector2(0.87, -1.97)
const WHEELS: PackedStringArray = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]

static var _meshes: Dictionary = {}

var _wheels: Array[VehicleWheel3D] = []
var _calipers: Array[Node3D] = []


func _ready() -> void:
	if _meshes.is_empty():
		_build_all()
	var car: Node = get_parent()
	_mi(self, "Shell", "shell")
	_mi(car.get_node("Aero/WingPivot"), "Wing", "wing")
	_mi(car.get_node("Aero/Struts"), "Mesh", "struts")
	_mi(car.get_node("Aero/FlapL"), "Mesh", "flap")
	_mi(car.get_node("Aero/FlapR"), "Mesh", "flap")
	var disc_mat := ShaderMaterial.new()
	disc_mat.shader = preload("res://shaders/brake_disc.gdshader")
	for w: String in WHEELS:
		var front: bool = w[5] == "F"
		var sfx: String = "_l" if w[6] == "L" else "_r"
		var wheel: VehicleWheel3D = car.get_node(w)
		_mi(wheel, "Rim", ("wheel_f" if front else "wheel_r") + sfx)
		_mi(wheel, "Disc", ("disc_f" if front else "disc_r") + sfx).material_override = disc_mat
		_wheels.append(wheel)
		_calipers.append(_mi(self, "Caliper" + w.substr(5), ("caliper_f" if front else "caliper_r") + sfx))
	var lights: Node = car.get_node("Lights")
	_mi(lights, "Head", "head").material_override = _glow_mat(Color(0.96, 0.98, 1.0), 1.6)
	_mi(lights, "Tail", "tail").material_override = _glow_mat(Color(1.0, 0.04, 0.02), 0.45)
	_mi(lights, "Reverse", "reverse").material_override = _glow_mat(Color(1.0, 1.0, 1.0), 0.0)


func _mi(parent: Node, node_name: String, key: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _meshes[key]
	mi.layers = 2  # car renders into main camera, excluded from its own ReflectionProbe cubemap
	parent.add_child(mi)
	return mi


func _process(_dt: float) -> void:
	for i: int in 4:  # calipers ride with the hub but do not spin
		_calipers[i].position = _wheels[i].position
		_calipers[i].rotation.y = _wheels[i].steering


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
	rev.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.40, 2.03)), Vector3(0.12, 0.03, 0.02), LAMP)
	_meshes["reverse"] = rev.mesh()
	_meshes["wing"] = _wing().mesh(paint)
	var struts := MeshBuilder.new()
	for sx: float in [-0.42, 0.42]:
		struts.box(Transform3D(Basis.IDENTITY, Vector3(sx, -0.20, 0.0)), Vector3(0.045, 0.34, 0.07), BLACK)
		struts.cur_uv.y = M_METAL
		struts.box(Transform3D(Basis.IDENTITY, Vector3(sx, -0.10, 0.045)), Vector3(0.02, 0.2, 0.02), GREY)
		struts.cur_uv.y = M_PLAIN
	_meshes["struts"] = struts.mesh(paint)
	var flap := MeshBuilder.new()
	flap.cur_uv.y = M_CARBON
	flap.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.1)), Vector3(0.5, 0.012, 0.2), BLACK)
	_meshes["flap"] = flap.mesh(paint)
	for side: float in [-1.0, 1.0]:
		var sfx: String = "_l" if side < 0.0 else "_r"
		_meshes["wheel_f" + sfx] = _wheel(0.34, 0.25, side).mesh(paint)
		_meshes["wheel_r" + sfx] = _wheel(0.36, 0.32, side).mesh(paint)
		_meshes["disc_f" + sfx] = _disc(0.25, 0.195, side).mesh()
		_meshes["disc_r" + sfx] = _disc(0.32, 0.19, side).mesh()
		_meshes["caliper_f" + sfx] = _caliper(0.25, side).mesh(paint)
		_meshes["caliper_r" + sfx] = _caliper(0.32, side).mesh(paint)


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


## Section control points at z, bottom centre (s = 0) to top centre (s = 12).
static func _keys(z: float) -> PackedVector2Array:
	var p: PackedFloat32Array = _interp(ST, 7, z)
	var yb: float = p[0]
	var yc: float = p[1]
	var yf: float = p[2]
	var ws: float = p[3]
	var wb: float = p[4]
	var yv: float = p[5]
	var h: float = yf - yb
	return PackedVector2Array([
		Vector2(0.0, yb), Vector2(0.55 * wb, yb), Vector2(wb, yb),
		Vector2(lerpf(wb, ws, 0.75), yb + 0.06),
		Vector2(ws, yb + 0.30 * h), Vector2(ws, yb + 0.58 * h),
		Vector2(ws * 0.985, yb + 0.80 * h), Vector2(ws * 0.94, yf - 0.035),
		Vector2(ws * 0.85, yf), Vector2(ws * 0.68, lerpf(yf, yv, 0.75)), Vector2(ws * 0.46, yv),
		Vector2(ws * 0.24, lerpf(yv, yc, 0.85)), Vector2(0.0, yc)])


## Door scallop depth (inward) at side position (z, y). Mirrored in car_paint.gdshader.
static func _scallop(z: float, y: float) -> float:
	var t: float = clampf((z + 1.0) / 1.65, 0.0, 1.0)
	var yc: float = lerpf(0.40, 0.50, t)
	var hh: float = lerpf(0.06, 0.24, t)
	var up: float = smoothstep(0.0, 1.0, (yc + hh - y) / (0.35 * hh))
	var dn: float = smoothstep(0.0, 1.0, (y - (yc - hh)) / (1.2 * hh))
	return 0.16 * t * t * (3.0 - 2.0 * t) * up * dn * (1.0 - smoothstep(0.66, 0.80, z))


## Sculpted twin bonnet nostril channels curving back from nose splitter.
static func _hood_dip(ax: float, z: float) -> float:
	if z < -2.25 or z > -1.35 or ax < 0.10 or ax > 0.44:
		return 0.0
	var tz: float = smoothstep(-2.22, -1.90, z) * (1.0 - smoothstep(-1.58, -1.38, z))
	var tx: float = 1.0 - clampf(absf(ax - lerpf(0.22, 0.27, (z + 2.2) / 0.8)) / 0.12, 0.0, 1.0)
	return 0.028 * tz * tx * tx


static func _pk(k: PackedVector2Array, z: float, s: float, side: float) -> Vector3:
	var i: int = clampi(int(s), 0, 11)
	var pre: Vector2 = k[i - 1] if i > 0 else Vector2(-k[1].x, k[1].y)
	var post: Vector2 = k[i + 2] if i < 11 else Vector2(-k[11].x, k[11].y)
	var q: Vector2 = k[i].cubic_interpolate(k[i + 1], pre, post, s - i)
	var dip: float = _hood_dip(q.x, z) if s > 8.6 else 0.0
	return Vector3(side * (q.x - _scallop(z, q.y)), q.y - dip, z)


## Point on the shell: s = 0 (bottom centre) .. 12 (top centre), side = +-1.
static func _p(z: float, s: float, side: float) -> Vector3:
	return _pk(_keys(z), z, s, side)


static func _nrm(z: float, s: float, side: float) -> Vector3:
	var dz: Vector3 = _p(minf(z + 0.02, Z1), s, side) - _p(maxf(z - 0.02, Z0), s, side)
	var ds: Vector3 = _p(z, minf(s + 0.2, 12.0), side) - _p(z, maxf(s - 0.2, 0.0), side)
	return (ds.cross(dz) * side).normalized()  # s runs bottom -> side -> top, so this is outward


## Headlamp leaf signed distance in the top view. Mirrored in car_paint.gdshader.
static func _lamp_d(q: Vector2) -> float:
	var ba: Vector2 = LAMP_B - LAMP_A
	var h: float = clampf((q - LAMP_A).dot(ba) / ba.length_squared(), 0.0, 1.0)
	return (q - LAMP_A - ba * h).length() - (0.028 + 0.055 * sin(PI * pow(h, 0.7)))


static func _shell(mb: MeshBuilder) -> void:
	var ss := PackedFloat32Array([0.0, 1.0, 2.0, 2.5])
	for k: int in 31:
		ss.append(3.0 + k * 0.3)
	var nh: int = ss.size() - 1
	var nj: int = nh * 2
	var zs := PackedFloat32Array()
	var g: Array[PackedVector3Array] = []  # arch-snapped positions
	var gn: Array[PackedVector3Array] = []
	var inside: Array[PackedByteArray] = []
	for i: int in NZ + 1:
		var z: float = lerpf(Z0, Z1, pow(float(i) / NZ, 1.25))  # finer rings at the nose
		zs.append(z)
		var k: PackedVector2Array = _keys(z)
		var row := PackedVector3Array()
		for j: int in nj + 1:
			row.append(_pk(k, z, ss[j if j <= nh else nj - j], 1.0 if j <= nh else -1.0))
		g.append(row)
	for i: int in NZ + 1:
		var nrow := PackedVector3Array()
		for j: int in nj + 1:
			var dz: Vector3 = g[mini(i + 1, NZ)][j] - g[maxi(i - 1, 0)][j]
			var ds: Vector3 = g[i][j + 1 if j < nj else 1] - g[i][j - 1 if j > 0 else nj - 1]
			nrow.append(ds.cross(dz).normalized())
		gn.append(nrow)
	for i: int in NZ + 1:
		var irow := PackedByteArray()
		for j: int in nj + 1:
			var pt: Vector3 = g[i][j]
			var s: float = ss[j if j <= nh else nj - j]
			var ins: int = 0
			if absf(pt.x) > 0.6 and s >= 2.0 and s <= 9.0:  # cut the wheel arches
				for a: int in 2:
					var c: Vector2 = Vector2(ARCH[a * 3], ARCH[a * 3 + 1])
					var d: Vector2 = Vector2(pt.z, pt.y) - c
					var r: float = ARCH[a * 3 + 2]
					if d.length() < r:
						ins = 1
						if d.length() > r - 0.09:  # near the edge: snap onto the circle
							d = d.normalized() * r
							g[i][j] = Vector3(pt.x, c.y + d.y, c.x + d.x)
			if s >= 8.0 and pt.z > CAB_Z0 and pt.z < CAB_Z1 and absf(pt.x) < _interp(CAN, 3, pt.z)[0] * 0.97 - 0.015:
				ins = 1  # open the cabin under the canopy; P1Interior (dash, tub, seats) fills it
			irow.append(ins)
		inside.append(irow)
	for i: int in NZ:
		for j: int in nj:
			var idx: Array[Vector2i] = [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
			for t: Array in [[0, 1, 2], [0, 2, 3]]:
				var a: Vector2i = idx[t[0]]
				var b: Vector2i = idx[t[1]]
				var d: Vector2i = idx[t[2]]
				if inside[a.x][a.y] + inside[b.x][b.y] + inside[d.x][d.y] == 3:
					continue
				mb.tri_uv(g[a.x][a.y], g[b.x][b.y], g[d.x][d.y], gn[a.x][a.y], gn[b.x][b.y], gn[d.x][d.y], PAINT,
					Vector2(zs[a.x], ss[a.y if a.y <= nh else nj - a.y]), Vector2(zs[b.x], ss[b.y if b.y <= nh else nj - b.y]),
					Vector2(zs[d.x], ss[d.y if d.y <= nh else nj - d.y]))
	# nose cap (shader paints the mouth on it)
	mb.cur_uv = Vector2(Z0, 5.0)
	var mid: Vector3 = (g[0][0] + g[0][nh]) * 0.5
	for j: int in nj:
		mb.tri(mid, g[0][j], g[0][j + 1], Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD, PAINT)
	# recessed rear fascia: black rim, grille back wall
	var ctr: Vector3 = Vector3(0.0, 0.57, Z1)
	for j: int in nj:
		var a: Vector3 = g[NZ][j]
		var b: Vector3 = g[NZ][j + 1]
		var ai: Vector3 = ctr.lerp(a, 0.93) - Vector3(0.0, 0.0, 0.07)
		var bi: Vector3 = ctr.lerp(b, 0.93) - Vector3(0.0, 0.0, 0.07)
		mb.cur_uv.y = M_PLAIN
		mb.flat(a, b, bi, ai, ctr - a, BLACK)
		mb.cur_uv.y = M_GRILLE
		mb.tri(ctr - Vector3(0.0, 0.0, 0.07), ai, bi, Vector3.BACK, Vector3.BACK, Vector3.BACK, BLACK)
	# arch liners: tunnel + inner wall
	mb.cur_uv.y = M_PLAIN
	for a: int in 2:
		var az: float = ARCH[a * 3]
		var ay: float = ARCH[a * 3 + 1]
		var r: float = ARCH[a * 3 + 2]
		for side: float in [-1.0, 1.0]:
			var x_out: float = side * (_interp(ST, 7, az)[3] - 0.012)
			var x_in: float = side * 0.56
			var prev: Vector3 = Vector3.ZERO
			for k: int in 19:
				var ang: float = lerpf(-0.32, PI + 0.32, k / 18.0)
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
	var y0: float = _interp(ST, 7, z)[1] - 0.05
	var h: float = maxf(c[1] - y0, 0.02)
	var ca: float = cos(a)
	return Vector3(c[0] * signf(ca) * pow(absf(ca), 0.8), y0 + h * pow(maxf(sin(a), 0.0), 0.72), z)


static func _canopy(mb: MeshBuilder) -> void:
	const RZ: int = 40
	const RA: int = 26
	var g: Array[PackedVector3Array] = []
	for i: int in RZ + 1:
		var row := PackedVector3Array()
		for j: int in RA + 1:
			row.append(_canopy_pt(lerpf(CAN_Z0, CAN_Z1, float(i) / RZ), PI * j / RA))
		g.append(row)
	for i: int in RZ:
		for j: int in RA:
			var q4: Array[Vector2i] = [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
			var nn: Array[Vector3] = []
			var uu: Array[Vector2] = []
			for q: Vector2i in q4:
				var dz: Vector3 = g[mini(q.x + 1, RZ)][q.y] - g[maxi(q.x - 1, 0)][q.y]
				var da: Vector3 = g[q.x][mini(q.y + 1, RA)] - g[q.x][maxi(q.y - 1, 0)]
				var v: Vector3 = dz.cross(da)
				v = v.normalized() if v.length_squared() > 1e-12 else Vector3.UP
				nn.append(v if v.y + absf(v.x) * signf(g[q.x][q.y].x) * signf(v.x) > 0.0 else -v)
				uu.append(Vector2(g[q.x][q.y].z, 21.0 - absf(2.0 * q.y / RA - 1.0)))  # 20 = belt, 21 = roof centre
			for t: Array in [[0, 1, 2], [0, 2, 3]]:
				mb.tri_uv(g[q4[t[0]].x][q4[t[0]].y], g[q4[t[1]].x][q4[t[1]].y], g[q4[t[2]].x][q4[t[2]].y],
					nn[t[0]], nn[t[1]], nn[t[2]], PAINT, uu[t[0]], uu[t[1]], uu[t[2]])
	# roof snorkel: half-ellipse loft, open black mouth at the front
	mb.cur_uv.y = M_CARBON
	var sn: PackedFloat32Array = [0.02, 0.12, 0.055, 0.30, 0.13, 0.06, 0.60, 0.10, 0.04, 0.88, 0.05, 0.004]  # z, half width, height
	var prev := PackedVector3Array()
	for i: int in 4:
		var row := PackedVector3Array()
		var base: float = _interp(CAN, 3, sn[i * 3])[1] - 0.012
		for j: int in 9:
			var a: float = PI * j / 8.0
			row.append(Vector3(cos(a) * sn[i * 3 + 1], base + sin(a) * sn[i * 3 + 2] + 0.012 * absf(cos(a)) * 0.0, sn[i * 3]))
		if i == 0:
			mb.cur_uv.y = M_PLAIN
			for j: int in 8:
				mb.tri(Vector3(0.0, base, sn[0]), row[j], row[j + 1], Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD, Color(0.0, 0.0, 0.0, 0.9))
			mb.cur_uv.y = M_CARBON
		else:
			for j: int in 8:
				var na: Vector3 = Vector3(cos(PI * j / 8.0), sin(PI * j / 8.0), 0.15).normalized()
				var nb: Vector3 = Vector3(cos(PI * (j + 1) / 8.0), sin(PI * (j + 1) / 8.0), 0.15).normalized()
				mb.quad(prev[j], row[j], row[j + 1], prev[j + 1], na, na, nb, nb, BLACK)
		prev = row


## Re-samples the shell between (z0..z1, s0..s1) on both sides, lifted by off along the normal.
## keep (optional) filters cells by their centre point.
static func _patch(mb: MeshBuilder, z0: float, z1: float, s0: float, s1: float, col: Color, off: float = 0.006,
		dz: float = 0.1, ds: float = 0.5, keep: Callable = Callable()) -> void:
	var nz: int = maxi(1, int(ceil((z1 - z0) / dz)))
	var ns: int = maxi(1, int(ceil((s1 - s0) / ds)))
	for side: float in [-1.0, 1.0]:
		for i: int in nz:
			var ka: PackedVector2Array = _keys(lerpf(z0, z1, float(i) / nz))
			var kb: PackedVector2Array = _keys(lerpf(z0, z1, float(i + 1) / nz))
			for j: int in ns:
				var sa: float = lerpf(s0, s1, float(j) / ns)
				var sb: float = lerpf(s0, s1, float(j + 1) / ns)
				var za: float = lerpf(z0, z1, float(i) / nz)
				var zb: float = lerpf(z0, z1, float(i + 1) / nz)
				var p: Array[Vector3] = [_pk(ka, za, sa, side), _pk(kb, zb, sa, side), _pk(kb, zb, sb, side), _pk(ka, za, sb, side)]
				if keep.is_valid() and not keep.call((p[0] + p[2]) * 0.5):
					continue
				var nn: Vector3 = _nrm((za + zb) * 0.5, (sa + sb) * 0.5, side)
				mb.quad(p[0] + nn * off, p[1] + nn * off, p[2] + nn * off, p[3] + nn * off, nn, nn, nn, nn, col)


## Finds top-surface shell point and normal matching (|x| = ax, z) for flush trim placement.
static func _surf_at(ax: float, z: float, side: float) -> Array[Vector3]:
	var k: PackedVector2Array = _keys(z)
	var s_lo: float = 5.5
	var s_hi: float = 12.0
	for _it: int in 10:
		var mid: float = 0.5 * (s_lo + s_hi)
		var pt_m: Vector3 = _pk(k, z, mid, 1.0)
		if pt_m.x > ax:
			s_lo = mid
		else:
			s_hi = mid
	var s_best: float = 0.5 * (s_lo + s_hi)
	return [_pk(k, z, s_best, side), _nrm(z, s_best, side)]


static func _add_ribbon(pts_xz: PackedVector2Array, half_w: float, lift: float, mb: MeshBuilder, col: Color) -> void:
	for side: float in [-1.0, 1.0]:
		var prev_l := Vector3.ZERO
		var prev_r := Vector3.ZERO
		var prev_n := Vector3.UP
		for i: int in pts_xz.size():
			var c2: Vector2 = pts_xz[i]
			var tgt: Vector2 = pts_xz[mini(i + 1, pts_xz.size() - 1)] - pts_xz[maxi(i - 1, 0)]
			var perp2: Vector2 = Vector2(-tgt.y, tgt.x).normalized() * half_w
			var sl: Array[Vector3] = _surf_at(c2.x + perp2.x, c2.y + perp2.y, side)
			var sr: Array[Vector3] = _surf_at(c2.x - perp2.x, c2.y - perp2.y, side)
			var sc: Array[Vector3] = _surf_at(c2.x, c2.y, side)
			var pl: Vector3 = sl[0] + sc[1] * lift
			var pr: Vector3 = sr[0] + sc[1] * lift
			if i > 0:
				var q_a: Vector3 = prev_l if side > 0.0 else prev_r
				var q_b: Vector3 = pl if side > 0.0 else pr
				var q_c: Vector3 = pr if side > 0.0 else pl
				var q_d: Vector3 = prev_r if side > 0.0 else prev_l
				mb.quad(q_a, q_b, q_c, q_d, prev_n, sc[1], sc[1], prev_n, col)
			prev_l = pl
			prev_r = pr
			prev_n = sc[1]


static func _details(mb: MeshBuilder, head: MeshBuilder, tail: MeshBuilder) -> void:
	# Smooth boomerang McLaren P1 DRL spline hugging the curved inner/lower housing contour + projectors
	var drl_curve := PackedVector2Array()
	var ba: Vector2 = LAMP_B - LAMP_A
	for i: int in 20:
		var t: float = float(i) / 19.0
		var center: Vector2 = LAMP_A + ba * t
		var perp_in: Vector2 = Vector2(-ba.y, ba.x).normalized()  # toward inner centerline / lower boomerang edge
		var off: float = 0.014 + 0.036 * sin(PI * pow(t, 0.72))
		drl_curve.append(center - perp_in * off)
	_add_ribbon(drl_curve, 0.007, 0.004, head, LAMP)
	for pt_t: float in [0.34, 0.62]:
		var pc: Vector2 = LAMP_A + ba * pt_t
		for side: float in [-1.0, 1.0]:
			var sn: Array[Vector3] = _surf_at(pc.x, pc.y, side)
			head.ellipsoid(sn[0] + sn[1] * 0.004, Vector3(0.020, 0.012, 0.020), LAMP, 6)

	# Sculpted rear perimeter LED blade hugging ONLY the outer/lower curved fascia edge (no flat top cross-bar)
	var ctr: Vector3 = Vector3(0.0, 0.56, Z1 + 0.008)
	for side: float in [-1.0, 1.0]:
		for j: int in 19:
			var s0: float = 4.2 + j * 0.21
			var s1: float = 4.41 + j * 0.21
			var a: Vector3 = _p(Z1, s0, side) + Vector3(0.0, 0.0, 0.008)
			var b: Vector3 = _p(Z1, s1, side) + Vector3(0.0, 0.0, 0.008)
			var a_out: Vector3 = ctr.lerp(a, 0.990)
			var b_out: Vector3 = ctr.lerp(b, 0.990)
			var a_in: Vector3 = ctr.lerp(a, 0.946)
			var b_in: Vector3 = ctr.lerp(b, 0.946)
			tail.flat(a_out, b_out, b_in, a_in, Vector3.BACK, LAMP)

		# Sculpted carbon aero wing mirrors anchored neatly into A-pillar shoulder & tucked inside housing
		mb.cur_uv.y = M_CARBON
		var p_root := Vector3(side * 0.69, 0.835, -0.82)
		var p_tip := Vector3(side * 0.96, 0.895, -0.75)
		var arm_mid: Vector3 = (p_root + p_tip) * 0.5
		var arm_dir: Vector3 = (p_tip - p_root).normalized()
		var arm_len: float = (p_tip - p_root).length()
		var arm_b := Basis(arm_dir * side, Vector3.UP, Vector3.FORWARD * side).orthonormalized()
		mb.box(Transform3D(arm_b, arm_mid), Vector3(arm_len, 0.020, 0.048), BLACK)
		mb.cur_uv.y = M_PAINT
		mb.ellipsoid(p_tip, Vector3(0.10, 0.048, 0.052), PAINT, 9)
		mb.cur_uv.y = M_GLASS
		mb.ellipsoid(p_tip + Vector3(0.0, 0.0, 0.016), Vector3(0.085, 0.038, 0.040), BLACK, 7)

		# Sill aero blade + upright front-fender bargeboard winglets + rear corner aero flicks
		mb.cur_uv.y = M_CARBON
		mb.box(Transform3D(Basis.IDENTITY, Vector3(side * 0.915, 0.128, -0.12)), Vector3(0.16, 0.018, 1.72), BLACK)
		mb.box(Transform3D(Basis(Vector3.UP, side * 0.18), Vector3(side * 0.935, 0.21, -1.04)), Vector3(0.016, 0.16, 0.22), BLACK)
		mb.box(Transform3D(Basis(Vector3.UP, -side * 0.14), Vector3(side * 0.855, 0.30, 1.94)), Vector3(0.018, 0.19, 0.26), BLACK)
		# Wipers
		mb.cur_uv.y = M_PLAIN
		mb.box(Transform3D(Basis(Vector3.UP, side * 0.25) * Basis(Vector3.RIGHT, 0.12), Vector3(side * 0.24, 0.80, -1.07)), Vector3(0.46, 0.012, 0.018), BLACK)

	# Front splitter following the nose plan (carbon)
	mb.cur_uv.y = M_CARBON
	var pz: float = Z0 - 0.085
	var px: float = 0.0
	for i: int in 15:
		var z: float = lerpf(Z0 - 0.085, -1.92, pow(i / 14.0, 1.6))
		var x: float = minf(_interp(ST, 7, clampf(z + 0.085, Z0, Z1))[3] + 0.055, 0.995) if i > 0 else 0.32
		if i > 0:
			for y: float in [0.116, 0.136]:
				mb.flat(Vector3(-px, y, pz), Vector3(px, y, pz), Vector3(x, y, z), Vector3(-x, y, z), Vector3.UP if y > 0.12 else Vector3.DOWN, BLACK)
			for side: float in [-1.0, 1.0]:
				mb.flat(Vector3(side * px, 0.116, pz), Vector3(side * px, 0.136, pz), Vector3(side * x, 0.136, z), Vector3(side * x, 0.116, z),
					Vector3(side, 0.0, -1.0), BLACK)
		else:
			mb.flat(Vector3(-x, 0.116, z), Vector3(x, 0.116, z), Vector3(x, 0.136, z), Vector3(-x, 0.136, z), Vector3.FORWARD, BLACK)
		pz = z
		px = x

	# Aggressive 4-strake Venturi rear diffuser + lower carbon valance beam
	mb.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.39, 1.98)), Vector3(1.56, 0.055, 0.10), BLACK)
	var ramp: Basis = Basis(Vector3.RIGHT, -0.26)
	mb.box(Transform3D(ramp, Vector3(0.0, 0.245, 1.78)), Vector3(1.52, 0.016, 0.62), BLACK)
	for fx: float in [-0.62, -0.24, 0.24, 0.62]:
		mb.box(Transform3D(ramp, Vector3(fx, 0.185, 1.82)), Vector3(0.018, 0.145, 0.56), BLACK)

	# Proud P1 central Titanium hex-trapezoid exhaust bezel + soot interior
	var ex: PackedVector2Array = [
		Vector2(-0.165, 0.680), Vector2(0.165, 0.680), Vector2(0.195, 0.642),
		Vector2(0.140, 0.568), Vector2(-0.140, 0.568), Vector2(-0.195, 0.642),
	]
	for k: int in ex.size():
		var a: Vector2 = ex[k]
		var b: Vector2 = ex[(k + 1) % ex.size()]
		var out: Vector3 = Vector3(a.x + b.x, a.y + b.y - 1.248, 0.0)
		mb.cur_uv.y = M_METAL
		mb.flat(Vector3(a.x, a.y, 1.91), Vector3(b.x, b.y, 1.91), Vector3(b.x, b.y, 2.045), Vector3(a.x, a.y, 2.045), out, TITANIUM)
		var c_ex := Vector2(0.0, 0.624)
		var ai: Vector2 = c_ex.lerp(a, 0.88)
		var bi: Vector2 = c_ex.lerp(b, 0.88)
		mb.flat(Vector3(ai.x, ai.y, 1.91), Vector3(bi.x, bi.y, 1.91), Vector3(bi.x, bi.y, 2.045), Vector3(ai.x, ai.y, 2.045), -out, DARK)
		mb.flat(Vector3(a.x, a.y, 2.045), Vector3(b.x, b.y, 2.045), Vector3(bi.x, bi.y, 2.045), Vector3(ai.x, ai.y, 2.045), Vector3.BACK, TITANIUM)
		mb.cur_uv.y = M_PLAIN
		mb.tri(Vector3(0.0, 0.624, 1.95), Vector3(ai.x, ai.y, 1.95), Vector3(bi.x, bi.y, 1.95), Vector3.BACK, Vector3.BACK, Vector3.BACK, Color(0.01, 0.01, 0.01, 0.9))


static func _wing() -> MeshBuilder:
	var mb := MeshBuilder.new()
	var sec: PackedVector2Array = [
		Vector2(0.0, 0.0), Vector2(0.06, 0.068), Vector2(0.35, 0.105), Vector2(0.75, 0.068), Vector2(1.0, 0.022),
		Vector2(1.0, -0.010), Vector2(0.7, -0.032), Vector2(0.3, -0.056), Vector2(0.06, -0.042),
	]
	var st: PackedFloat32Array = [
		0.0, 0.36, 0.18, 0.0, 0.35, 0.36, 0.18, 0.0, 0.62, 0.34, 0.17, -0.005,
		0.78, 0.29, 0.15, -0.018, 0.86, 0.22, 0.12, -0.036, 0.91, 0.14, 0.09, -0.060,
	]
	for side: float in [-1.0, 1.0]:
		for i: int in 5:
			for k: int in sec.size():
				var p: Array[Vector3] = []
				for q: Vector2i in [Vector2i(i, k), Vector2i(i + 1, k), Vector2i(i + 1, (k + 1) % sec.size()), Vector2i(i, (k + 1) % sec.size())]:
					var c: float = st[q.x * 4 + 1]
					p.append(Vector3(side * st[q.x * 4], st[q.x * 4 + 3] + sec[q.y].y * 0.36 * (0.5 + 0.5 * c / 0.36), st[q.x * 4 + 2] - c * (1.0 - sec[q.y].x)))
				var e: Vector2 = sec[(k + 1) % sec.size()] - sec[k]
				mb.cur_uv.y = M_PAINT if k < 4 else M_CARBON
				mb.flat(p[0], p[1], p[2], p[3], Vector3(0.0, e.x, -e.y) if k != 4 else Vector3.BACK, PAINT if k < 4 else BLACK)
	return mb


static func _wheel(r: float, w: float, side: float) -> MeshBuilder:
	var mb := MeshBuilder.new()
	var rr: float = r - 0.088  # rim radius
	var h: float = w * 0.5
	mb.lathe([
		Vector2(-h + 0.01, rr), Vector2(-h - 0.006, rr + 0.04), Vector2(-h + 0.004, r - 0.030), Vector2(-h + 0.035, r - 0.006),
		Vector2(-h + 0.075, r), Vector2(h - 0.075, r), Vector2(h - 0.035, r - 0.006), Vector2(h - 0.004, r - 0.030),
		Vector2(h + 0.006, rr + 0.04), Vector2(h - 0.01, rr),
	], 32, TYRE, Vector2(0.0, r - 0.05), true)
	mb.cur_uv.y = M_METAL
	mb.lathe([
		Vector2(side * (h - 0.008), rr + 0.006), Vector2(side * (h - 0.020), rr - 0.012),
		Vector2(side * (h - 0.052), rr - 0.020), Vector2(-side * h, rr - 0.020),
	], 32, ALLOY, Vector2(0.0, r + 1.0))
	var xo: float = side * (h - 0.036)
	var xd: float = side * (h - 0.115)
	mb.lathe([Vector2(xd, 0.085), Vector2(xo - side * 0.02, 0.068), Vector2(xo + side * 0.012, 0.054), Vector2(xo + side * 0.018, 0.0)],
		16, ALLOY, Vector2(xo - side, 0.0))
	# Anodized gold/orange center-lock cap ring
	mb.box(Transform3D(Basis.IDENTITY, Vector3(xo + side * 0.016, 0.0, 0.0)), Vector3(0.012, 0.042, 0.042), CALIPER)
	# 5 twin-spoke Y-pattern forged arms
	var r_root: float = 0.055
	var r_fork: float = lerpf(r_root, rr - 0.012, 0.36)
	var r_rim: float = rr - 0.010
	for k: int in 5:
		var a0: float = TAU * k / 5.0
		for fork: float in [-1.0, 1.0]:
			var a_tip: float = a0 + fork * 0.25
			var p_in: Vector3 = Vector3(xo - side * 0.008, cos(a0 + fork * 0.06) * r_root, sin(a0 + fork * 0.06) * r_root)
			var p_mid: Vector3 = Vector3(xo - side * 0.004, cos(a0 + fork * 0.14) * r_fork, sin(a0 + fork * 0.14) * r_fork)
			var p_out: Vector3 = Vector3(xo - side * 0.016, cos(a_tip) * r_rim, sin(a_tip) * r_rim)
			for seg: Array in [[p_in, p_mid], [p_mid, p_out]]:
				var pa: Vector3 = seg[0]
				var pb: Vector3 = seg[1]
				var sdir: Vector3 = (pb - pa).normalized()
				var stang: Vector3 = Vector3.RIGHT.cross(sdir).normalized()
				var bx: Vector3 = sdir.cross(stang).normalized()
				mb.box(Transform3D(Basis(bx, sdir, stang).orthonormalized(), (pa + pb) * 0.5), Vector3(0.022, (pb - pa).length() + 0.012, 0.021), ALLOY)
	mb.cur_uv.y = M_PLAIN
	mb.lathe([Vector2(side * (h - 0.175), 0.0), Vector2(side * (h - 0.175), rr - 0.02)], 16, Color(0.01, 0.01, 0.01, 0.9), Vector2(-side, 0.1))
	return mb


static func _disc(w: float, r: float, side: float) -> MeshBuilder:
	var mb := MeshBuilder.new()
	var x: float = side * (w * 0.5 - 0.11)
	mb.lathe([Vector2(x + 0.014, 0.085), Vector2(x + 0.014, r), Vector2(x - 0.014, r), Vector2(x - 0.014, 0.085)], 28, GREY, Vector2(x, 0.14))
	return mb


static func _caliper(w: float, side: float) -> MeshBuilder:
	var mb := MeshBuilder.new()
	var cx: float = side * (w * 0.5 - 0.105)
	for k: int in 6:
		var ang: float = lerpf(0.42, 1.48, float(k) / 5.0)
		var b: Basis = Basis(Vector3.RIGHT, ang)
		mb.box(Transform3D(b, Vector3(cx, 0.0, 0.0) + b * Vector3(0.0, 0.172, 0.0)), Vector3(0.072, 0.074, 0.058), CALIPER)
	return mb
