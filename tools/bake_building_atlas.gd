extends SceneTree
## Dev tool (M3): bakes the 2-texture building atlas from the 4 facade PBR sets.
## Run: Godot --headless --path . -s res://tools/bake_building_atlas.gd
## Out: assets/textures/buildings/atlas_diff.png (sRGB) and atlas_nra.png (R,G normal.xy, B roughness, A AO).
## Tiles (2x2, 512 px each): 0 plaster, 1 concrete, 2 brick A, 3 brick B.

const T: int = 512
const B: String = "res://assets/textures/buildings/"
const SETS: Array[Array] = [
	["beige_wall_001/beige_wall_001_diff_1k.jpg", "beige_wall_001/beige_wall_001_nor_gl_1k.jpg", "beige_wall_001/beige_wall_001_arm_1k.jpg"],
	["../props/concrete_panels/concrete_panels_diff_1k.jpg", "../props/concrete_panels/concrete_panels_nor_gl_1k.jpg", "../props/concrete_panels/concrete_panels_arm_1k.jpg"],
	["brick_wall_001/brick_wall_001_diffuse_1k.jpg", "brick_wall_001/brick_wall_001_nor_gl_1k.jpg", "brick_wall_001/brick_wall_001_arm_1k.jpg"],
	["brick_wall_02/brick_wall_02_diff_1k.jpg", "brick_wall_02/brick_wall_02_nor_gl_1k.jpg", "brick_wall_02/brick_wall_02_arm_1k.jpg"],
]


func _img(rel: String) -> Image:
	var im: Image = (load(B + rel) as Texture2D).get_image()
	if im.is_compressed():
		im.decompress()
	im.convert(Image.FORMAT_RGBA8)
	im.resize(T, T, Image.INTERPOLATE_LANCZOS)
	return im


func _init() -> void:
	var diff := Image.create(T * 2, T * 2, false, Image.FORMAT_RGBA8)
	var nra := Image.create(T * 2, T * 2, false, Image.FORMAT_RGBA8)
	for i: int in 4:
		var d: Image = _img(SETS[i][0])
		var n: Image = _img(SETS[i][1])
		var a: Image = _img(SETS[i][2])
		var o := Vector2i((i & 1) * T, (i >> 1) * T)
		diff.blit_rect(d, Rect2i(0, 0, T, T), o)
		for y: int in T:
			for x: int in T:
				var nc: Color = n.get_pixel(x, y)
				var ac: Color = a.get_pixel(x, y)
				nra.set_pixel(o.x + x, o.y + y, Color(nc.r, nc.g, ac.g, ac.r))
	diff.save_png(B + "atlas_diff.png")
	nra.save_png(B + "atlas_nra.png")
	print("atlas baked")
	quit()
