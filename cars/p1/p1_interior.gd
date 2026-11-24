class_name P1Interior
extends RefCounted
## P1 cockpit (R5/S2): curved dash with binnacle hood, door cards, carbon tub + tunnel + bulkhead, two bucket seats,
## alcantara headliner, canopy-following A-pillars. Built once from parametric surfaces into one mesh per material
## (alcantara / leather / carbon / aluminium / soft plastic / accent). Car space, front = -Z, driver at x = -0.34.

const DX: float = -0.34
const FLOOR: float = 0.27
const CAB: Vector3 = Vector3(0.0, 0.85, 0.1)  # faces of every surface point toward here
const ACCENT: Color = Color(1.0, 0.38, 0.04)
const IRIS_POS: Vector3 = Vector3(0.0, 0.682, -0.646)  # portrait infotainment, on the fascia
const IRIS_N: Vector3 = Vector3(-0.42, 0.38, 0.83)  # faces the driver's eye
const IRIS_SIZE: Vector2 = Vector2(0.15, 0.21)

static var _meshes: Dictionary = {}
static var _mats: Dictionary = {}


static func meshes() -> Dictionary:
	if _meshes.is_empty():
		_build()
	return _meshes


static func material(key: String) -> Material:
	if _mats.is_empty():
		_mats = _materials()
	return _mats[key]


# ---- helpers ----

## Parametric surface f(u, v) -> Vector3 sampled nu x nv; smooth normals, facing CAB.
static func surf(mb: MeshBuilder, nu: int, nv: int, col: Color, f: Callable, face: Vector3 = CAB) -> void:
	var g: Array[PackedVector3Array] = []
	for i: int in nu + 1:
		var row := PackedVector3Array()
		for j: int in nv + 1:
			row.append(f.call(float(i) / nu, float(j) / nv))
		g.append(row)
	var nn: Array[PackedVector3Array] = []
	for i: int in nu + 1:
		var row := PackedVector3Array()
		for j: int in nv + 1:
			var du: Vector3 = g[mini(i + 1, nu)][j] - g[maxi(i - 1, 0)][j]
			var dv: Vector3 = g[i][mini(j + 1, nv)] - g[i][maxi(j - 1, 0)]
			var n: Vector3 = du.cross(dv)
			n = n.normalized() if n.length_squared() > 1e-14 else Vector3.UP
			if n.dot(face - g[i][j]) < 0.0:
				n = -n
			row.append(n)
		nn.append(row)
	for i: int in nu:
		for j: int in nv:
			mb.quad(g[i][j], g[i + 1][j], g[i + 1][j + 1], g[i][j + 1], nn[i][j], nn[i + 1][j], nn[i + 1][j + 1], nn[i][j + 1], col)


## Tube of radius r along a closed/open polyline (used for wheel rim, stitching, belts).
static func tube(mb: MeshBuilder, pts: PackedVector3Array, r: float, col: Color, closed: bool = false, sides: int = 8) -> void:
	var n: int = pts.size()
	var rings: Array[PackedVector3Array] = []
	var tans: Array[Vector3] = []
	for i: int in n:
		var a: Vector3 = pts[(i - 1 + n) % n] if (closed or i > 0) else pts[i]
		var b: Vector3 = pts[(i + 1) % n] if (closed or i < n - 1) else pts[i]
		var t: Vector3 = (b - a).normalized()
		tans.append(t)
		var up: Vector3 = Vector3.BACK if absf(t.dot(Vector3.BACK)) < 0.9 else Vector3.UP
		var s: Vector3 = t.cross(up).normalized()
		var u: Vector3 = s.cross(t).normalized()
		var ring := PackedVector3Array()
		for k: int in sides:
			var an: float = TAU * k / sides
			ring.append(pts[i] + (s * cos(an) + u * sin(an)) * r)
		rings.append(ring)
	var segs: int = n if closed else n - 1
	for i: int in segs:
		var i2: int = (i + 1) % n
		for k: int in sides:
			var k2: int = (k + 1) % sides
			var c0: Vector3 = (rings[i][k] - pts[i]).normalized()
			var c1: Vector3 = (rings[i][k2] - pts[i]).normalized()
			var c2: Vector3 = (rings[i2][k2] - pts[i2]).normalized()
			var c3: Vector3 = (rings[i2][k] - pts[i2]).normalized()
			mb.quad(rings[i][k], rings[i][k2], rings[i2][k2], rings[i2][k], c0, c1, c2, c3, col)


## Canopy surface point pulled slightly into the cabin.
static func _can(z: float, a_deg: float, inset: float) -> Vector3:
	var p: Vector3 = P1Mesh._canopy_pt(z, deg_to_rad(a_deg))
	return Vector3(p.x * (1.0 - inset / maxf(absf(p.x), 0.3)), p.y - inset * 0.8, p.z)


static func dash_y(x: float, z: float) -> float:
	var bump: float = 0.07 * exp(-pow((x - DX) / 0.2, 2.0) - pow((z + 0.67) / 0.1, 2.0))
	return 0.795 + 0.035 * clampf((z + 1.06) / 0.46, 0.0, 1.0) + bump


## Fascia point: v 0 at the dash lip, 1 at the knee line.
static func fascia(x: float, v: float) -> Vector3:
	var top: float = dash_y(x, -0.60)
	return Vector3(x, lerpf(top, 0.46, v), -0.60 - 0.17 * pow(v, 1.25))


static func _build() -> void:
	var alc := MeshBuilder.new()
	var lea := MeshBuilder.new()
	var car := MeshBuilder.new()
	var alu := MeshBuilder.new()
	var pla := MeshBuilder.new()
	var acc := MeshBuilder.new()
	# sRGB; MeshBuilder stores them linear. Dark cloth still has to be light enough to read under the cabin lamps.
	var c_alc := Color(0.22, 0.21, 0.20)
	var c_alc2 := Color(0.18, 0.175, 0.17)
	var c_lea := Color(0.055, 0.048, 0.044)
	var c_car := Color(0.42, 0.42, 0.44)
	var c_alu := Color(0.62, 0.62, 0.64)
	var c_pla := Color(0.10, 0.10, 0.11)

	# dash top with the binnacle hood bump, and the curved fascia down to the knee line
	surf(alc, 40, 14, c_alc, func(u: float, v: float) -> Vector3:
		var x: float = lerpf(-0.74, 0.74, u)
		var z: float = lerpf(-1.08, -0.60, v)
		return Vector3(x, dash_y(x, z), z)
	)
	surf(lea, 40, 10, c_lea, func(u: float, v: float) -> Vector3:
		return fascia(lerpf(-0.74, 0.74, u), v)
	)
	surf(pla, 20, 4, c_pla, func(u: float, v: float) -> Vector3:  # knee bolster down to the floor
		var x: float = lerpf(-0.70, 0.70, u)
		var f: Vector3 = fascia(x, 1.0)
		return Vector3(x, lerpf(f.y, FLOOR, v), lerpf(f.z, f.z - 0.08, v))
	)
	# cluster binnacle: carbon bezel + hood lip
	var cx: float = DX
	car.box(Transform3D(Basis.IDENTITY, Vector3(cx, 0.84, -0.606)), Vector3(0.235, 0.1, 0.05), c_car)  # binnacle housing
	var cb := Basis(Vector3.RIGHT, deg_to_rad(-14.0))
	var cpos := Vector3(cx, 0.836, -0.578)
	for strip: Array in [[0.0, 0.0535, 0.225, 0.011], [0.0, -0.0535, 0.225, 0.011], [-0.1055, 0.0, 0.011, 0.096], [0.1055, 0.0, 0.011, 0.096]]:
		car.box(Transform3D(cb, cpos + cb * Vector3(float(strip[0]), float(strip[1]), -0.002)), Vector3(float(strip[2]), float(strip[3]), 0.014), c_car)
	car.box(Transform3D(Basis.IDENTITY, Vector3(cx, 0.905, -0.585)), Vector3(0.25, 0.012, 0.075), c_car)

	# centre stack: aluminium vent strip, IRIS bezel, switch row
	var ib := Basis.looking_at(-IRIS_N, Vector3.UP)
	for strip: Array in [[0.0, 0.1125, 0.174, 0.012], [0.0, -0.1125, 0.174, 0.012], [-0.081, 0.0, 0.012, 0.21], [0.081, 0.0, 0.012, 0.21]]:
		car.box(Transform3D(ib, IRIS_POS + ib * Vector3(float(strip[0]), float(strip[1]), -0.012)), Vector3(float(strip[2]), float(strip[3]), 0.03), c_car)
	car.box(Transform3D(ib, IRIS_POS + ib * Vector3(0.0, 0.0, -0.03)), Vector3(0.16, 0.22, 0.03), c_car)  # housing behind the glass
	for vx: float in [-0.20, 0.20]:
		var vp: Vector3 = fascia(vx, 0.18)
		alu.box(Transform3D(Basis.IDENTITY, vp + Vector3(0.0, 0.0, 0.008)), Vector3(0.10, 0.042, 0.016), c_alu)
		pla.box(Transform3D(Basis.IDENTITY, vp + Vector3(0.0, 0.0, 0.017)), Vector3(0.085, 0.028, 0.004), c_pla)
	alu.box(Transform3D(Basis.IDENTITY, fascia(0.0, 0.17) + Vector3(0.0, 0.0, 0.008)), Vector3(0.36, 0.014, 0.016), c_alu)
	for i: int in 5:
		var bp: Vector3 = fascia(-0.10 + i * 0.05, 0.78)
		pla.box(Transform3D(Basis.IDENTITY, bp + Vector3(0.0, 0.0, 0.012)), Vector3(0.034, 0.02, 0.014), c_pla)
		acc.box(Transform3D(Basis.IDENTITY, bp + Vector3(0.0, 0.011, 0.02)), Vector3(0.022, 0.003, 0.002), ACCENT)
	# stitching along the fascia lip
	var st := PackedVector3Array()
	for i: int in 41:
		var x: float = lerpf(-0.70, 0.70, i / 40.0)
		st.append(fascia(x, 0.07) + Vector3(0.0, 0.0, 0.004))
	tube(acc, st, 0.0016, ACCENT, false, 4)

	# door cards: belt rail top, then inner wall (alcantara upper, carbon lower) with armrest bulge
	for s: float in [-1.0, 1.0]:
		surf(alc, 6, 24, c_alc2, func(u: float, v: float) -> Vector3:
			var z: float = lerpf(-0.86, 0.66, v)
			return Vector3(s * lerpf(0.52, P1Mesh._interp(P1Mesh.CAN, 3, z)[0] - 0.012, u), 0.80 + 0.012 * (1.0 - u), z)
		)
		surf(alc, 8, 24, c_alc, func(u: float, v: float) -> Vector3:
			var z: float = lerpf(-0.86, 0.66, v)
			var arm: float = 0.05 * exp(-pow((z - 0.15) / 0.4, 2.0)) * sin(PI * clampf(u * 1.3, 0.0, 1.0))
			return Vector3(s * (0.56 - 0.045 * u * u - arm), lerpf(0.80, 0.52, u), z)
		)
		surf(car, 8, 24, c_car, func(u: float, v: float) -> Vector3:
			var z: float = lerpf(-0.86, 0.66, v)
			return Vector3(s * lerpf(0.515, 0.44, u), lerpf(0.52, FLOOR, u), z)
		)
		# door pull + speaker grille
		alu.box(Transform3D(Basis.IDENTITY, Vector3(s * 0.535, 0.66, 0.1)), Vector3(0.02, 0.03, 0.2), c_alu)
		pla.box(Transform3D(Basis.IDENTITY, Vector3(s * 0.548, 0.50, -0.45)), Vector3(0.012, 0.11, 0.11), c_pla)

	# tub: floor, rear bulkhead, tunnel
	surf(car, 8, 16, c_car, func(u: float, v: float) -> Vector3:
		return Vector3(lerpf(-0.66, 0.66, u), FLOOR, lerpf(-0.82, 0.74, v))
	)
	surf(car, 16, 8, c_car, func(u: float, v: float) -> Vector3:
		return Vector3(lerpf(-0.66, 0.66, u), lerpf(FLOOR, 1.0, v), 0.74 + 0.05 * sin(PI * u))
	)
	surf(alc, 14, 16, c_alc, func(u: float, v: float) -> Vector3:  # tunnel: half-ellipse cross-section, rises into the fascia
		var z: float = lerpf(-0.72, 0.56, v)
		var h: float = lerpf(0.34, 0.27, clampf((z + 0.72) / 1.28, 0.0, 1.0))
		var a: float = PI * u
		return Vector3(-cos(a) * 0.125, FLOOR + sin(a) * h, z)
	)
	alu.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.603, -0.18)), Vector3(0.14, 0.006, 0.26), c_alu)  # switch gate plate
	for i: int in 3:
		pla.box(Transform3D(Basis.IDENTITY, Vector3(-0.04 + i * 0.04, 0.609, -0.24)), Vector3(0.026, 0.008, 0.026), c_pla)
	acc.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.610, -0.12)), Vector3(0.05, 0.004, 0.05), ACCENT)  # start button
	# pedals (aluminium + rubber)
	for pz: Array in [[0.18, -0.58, 0.036, 0.03], [0.26, -0.62, 0.03, 0.02], [0.34, -0.56, 0.12, 0.025]]:
		var px: float = DX + float(pz[0]) - 0.18
		alu.box(Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-35.0)), Vector3(px, 0.40, float(pz[1]))), Vector3(float(pz[2]) * 2.0, 0.11, 0.012), c_alu)

	# seats
	for sx: float in [DX, -DX]:
		_seat(sx, alc, lea, car, acc, c_alc, c_alc2, c_lea, c_car)

	# headliner is behind the eye line so its front edge is not a bar across the windscreen
	surf(alc, 16, 12, c_alc2, func(u: float, v: float) -> Vector3:
		return _can(lerpf(0.18, 0.72, v), lerpf(55.0, 125.0, u), 0.03)
	)
	# carbon windscreen frame from the dash corners up to a header bar
	var c_frame := Color(0.2, 0.2, 0.21)
	for s: float in [-1.0, 1.0]:
		var foot := Vector3(s * 0.68, 0.78, -0.92)
		var cap := Vector3(s * 0.46, 0.99, -0.68)
		var dir: Vector3 = cap - foot
		car.box(Transform3D(Basis.looking_at(dir, Vector3.UP), (foot + cap) * 0.5), Vector3(0.04, 0.05, dir.length()), c_frame)
	car.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.99, -0.68)), Vector3(0.96, 0.04, 0.04), c_frame)
	# rear-view mirror housing + stalk
	alu.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.075, -0.50)), Vector3(0.012, 0.05, 0.012), c_alu)
	pla.box(Transform3D(Basis(Vector3.UP, deg_to_rad(-25.0)), Vector3(0.0, 1.03, -0.488)), Vector3(0.235, 0.075, 0.03), c_pla)

	for k: Array in [["alc", alc], ["lea", lea], ["carbon", car], ["alu", alu], ["plastic", pla], ["accent", acc]]:
		_meshes[k[0]] = (k[1] as MeshBuilder).mesh(material(k[0]))


static func _seat(cx: float, alc: MeshBuilder, lea: MeshBuilder, car: MeshBuilder, acc: MeshBuilder, c_alc: Color, c_alc2: Color, c_lea: Color, c_car: Color) -> void:
	# cushion: centre insert in alcantara, bolsters in leather, skirt to the floor
	for seg: Array in [[-1.0, -0.5, true], [-0.5, 0.5, false], [0.5, 1.0, true]]:
		surf(lea if seg[2] else alc, 8, 14, c_lea if seg[2] else c_alc, func(u: float, v: float) -> Vector3:
			var uu: float = lerpf(float(seg[0]), float(seg[1]), u)
			return Vector3(cx + uu * 0.235, 0.335 + 0.03 * v + 0.075 * pow(absf(uu), 2.5) + 0.03 * (1.0 - v) * pow(absf(uu), 2.0), lerpf(-0.06, 0.42, v))
		)
	for sd: float in [-1.0, 1.0]:  # cushion sides
		surf(car, 4, 6, c_car, func(u: float, v: float) -> Vector3:
			var top: float = 0.41
			return Vector3(cx + sd * 0.235, lerpf(top, FLOOR, u), lerpf(-0.06, 0.42, v))
		)
	surf(car, 4, 6, c_car, func(u: float, v: float) -> Vector3:
		return Vector3(cx + lerpf(-1.0, 1.0, v) * 0.235, lerpf(0.34, FLOOR, u), -0.06)
	)
	# backrest: leather bolsters wrap forward, alcantara insert, narrowing to the integrated headrest
	for seg: Array in [[-1.0, -0.52, true], [-0.52, 0.52, false], [0.52, 1.0, true]]:
		surf(lea if seg[2] else alc, 8, 14, c_lea if seg[2] else c_alc, func(u: float, v: float) -> Vector3:
			var uu: float = lerpf(float(seg[0]), float(seg[1]), u)
			var w: float = 0.245 - 0.085 * smoothstep(0.66, 1.0, v)
			var wrap: float = 0.09 * pow(absf(uu), 2.4) * (1.0 - 0.55 * v)
			var dish: float = -0.012 * (1.0 - uu * uu)
			return Vector3(cx + uu * w, 0.40 + 0.62 * v, 0.36 + 0.12 * v - wrap + dish)
		)
	surf(car, 8, 12, c_car, func(u: float, v: float) -> Vector3:  # carbon shell behind
		var w: float = 0.245 - 0.085 * smoothstep(0.66, 1.0, v)
		return Vector3(cx + lerpf(-1.0, 1.0, u) * w, 0.40 + 0.62 * v, 0.44 + 0.12 * v)
	)
	# harness stitching + headrest accent
	var st := PackedVector3Array()
	for i: int in 13:
		var v: float = 0.1 + 0.8 * i / 12.0
		st.append(Vector3(cx - 0.12, 0.40 + 0.62 * v, 0.355 + 0.12 * v - 0.004))
	tube(acc, st, 0.0016, ACCENT, false, 4)
	var st2 := PackedVector3Array()
	for i: int in 13:
		var v: float = 0.1 + 0.8 * i / 12.0
		st2.append(Vector3(cx + 0.12, 0.40 + 0.62 * v, 0.355 + 0.12 * v - 0.004))
	tube(acc, st2, 0.0016, ACCENT, false, 4)


# ---- materials ----

static func _fibre() -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 60017
	for y: int in 32:
		for x: int in 32:
			var v: float = rng.randf_range(0.78, 1.0)
			img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _weave() -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	for y: int in 32:
		for x: int in 32:
			var cell: int = ((x / 4) + (y / 4)) % 2
			var t: float = float((x % 4) if cell == 0 else (y % 4)) / 3.0
			var v: float = 0.5 + 0.38 * (t if cell == 0 else 1.0 - t) - (0.12 if ((x / 4) + (y / 4)) % 4 >= 2 else 0.0)
			img.set_pixel(x, y, Color(v, v, v * 1.04))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _materials() -> Dictionary:
	var m: Dictionary = {}
	var DBG: bool = false
	var alc := StandardMaterial3D.new()  # fuzzy sheen via rim light + a short fibre grain
	alc.vertex_color_use_as_albedo = true
	alc.albedo_texture = _fibre()
	alc.uv1_triplanar = true
	alc.uv1_scale = Vector3(38.0, 38.0, 38.0)
	alc.roughness = 0.92
	alc.rim_enabled = true
	alc.rim = 0.22
	alc.rim_tint = 0.7
	m["alc"] = alc
	var lea := StandardMaterial3D.new()
	lea.vertex_color_use_as_albedo = true
	lea.roughness = 0.5
	lea.clearcoat_enabled = true
	lea.clearcoat = 0.25
	lea.clearcoat_roughness = 0.45
	m["lea"] = lea
	var cb := StandardMaterial3D.new()
	cb.vertex_color_use_as_albedo = true
	cb.albedo_texture = _weave()
	cb.uv1_triplanar = true
	cb.uv1_scale = Vector3(26.0, 26.0, 26.0)
	cb.roughness = 0.3
	cb.metallic = 0.35
	cb.clearcoat_enabled = true
	cb.clearcoat = 1.0
	cb.clearcoat_roughness = 0.05
	m["carbon"] = cb
	var al := StandardMaterial3D.new()
	al.vertex_color_use_as_albedo = true
	al.metallic = 0.75
	al.roughness = 0.5
	m["alu"] = al
	var pl := StandardMaterial3D.new()
	pl.vertex_color_use_as_albedo = true
	pl.roughness = 0.6
	m["plastic"] = pl
	var ac := StandardMaterial3D.new()
	ac.vertex_color_use_as_albedo = true
	ac.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m["accent"] = ac
	if DBG:
		for k: String in m:
			(m[k] as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
