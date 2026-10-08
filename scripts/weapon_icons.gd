class_name WeaponIcons
extends Node

# ============================================================================
# 武器图标离线渲染器（击杀信息流用）
# ============================================================================
# 把 models/fpv/*.glb 逐把渲染成透明背景的侧视小图，输出到
# res://models/icons/weapons/<id>.png，枪口一律朝右。
#
# 运行：
#   godot --path <项目> --gen-weapon-icons
#   （**必须带窗口**，--headless 用的是 dummy 渲染器，SubViewport 不会真出图）
#
# 朝向策略：完全复用 player.gd 里已经被实战验证过的「最长轴 = 枪管方向」+
# 「包围盒中心在最长轴上的分量指向枪口」判定，先把枪管转到 -Z，
# 再把相机放在 +X 朝原点看 —— 此时相机的右手方向正好是 -Z，枪口就在画面右侧。
#
# 注意：本文件是开发期工具，不参与游戏运行时逻辑。

const OUT_DIR_RES := "res://models/icons/weapons"
const SHEET_RES := "res://screenshots/武器图标总览.png"
const TEX_W := 320          # 单张图标宽（像素）
const TEX_H := 160          # 单张图标高（像素，2:1）
const PAD := 0.09           # 四周留白（占正交视野的比例）
const CAM_DIST := 5.0       # 相机到模型中心距离（正交投影下只影响裁剪范围）

# 与 main.gd 出生点摆枪的兜底保持一致：XM1014 没有独立模型，用 MP5 顶。
const FALLBACK := {"XM1014": "MP5"}

# 渲染顺序 = 总览图里的排列顺序（6 列）
const ORDER: Array[String] = [
	"Knife", "Glock", "USP", "Deagle", "MP5", "P90",
	"XM1014", "AK47", "M4A1", "Galil", "FAMAS", "SG552",
	"AUG", "Scout", "SG550", "G3SG1", "AWP", "M249",
]
const SHEET_COLS := 6

var _cam: Camera3D


# 入口：渲染全部图标 + 生成一张总览图（供人工核对朝向）
func render_all() -> void:
	var abs_dir := ProjectSettings.globalize_path(OUT_DIR_RES)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var abs_sheet_dir := ProjectSettings.globalize_path(SHEET_RES).get_base_dir()
	DirAccess.make_dir_recursive_absolute(abs_sheet_dir)

	var vp := _build_viewport()
	var holder := Node3D.new()
	vp.add_child(holder)

	var images: Array[Image] = []
	var ok := 0
	for wid in ORDER:
		var img := await _render_one(vp, holder, wid)
		if img == null:
			print("[Icon] 跳过（无模型）：", wid)
			continue
		images.append(img)
		var path := "%s/%s.png" % [abs_dir, wid]
		var err := img.save_png(path)
		if err != OK:
			print("[Icon] 保存失败 ", path, " err=", err)
			continue
		ok += 1
		print("[Icon] ", wid, " -> ", path, "  ", img.get_width(), "x", img.get_height())

	print("[Icon] 完成：", ok, " / ", ORDER.size())
	_make_sheet(images)
	get_tree().quit()


# ---------------------------------------------------------------- 视口与灯光
func _build_viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(TEX_W, TEX_H)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	# 注意：**不要**开 use_hdr_2d —— 开了之后 get_image() 拿到的是 HDR 值，
	# 大量像素 >1.0，存成 PNG 时被整片截断成纯白，白模的明暗层次全丢。
	add_child(vp)

	# 环境：透明背景 + 纯色环境光，避免 GLB 自带的深色金属件渲成一片黑
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	# 白模渲染：所有网格统一套一层白色材质（见 _white_clay），
	# 所以这里只要给出「有明确明暗过渡」的光就够了 —— 靠明暗才能看出枪的立体形状。
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.96, 1.0)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	# 这里**故意不放灯光**：白模的明暗由 _clay_material() 里的自定义 shader 直接算。
	# 用场景灯光试过两轮，DirectionalLight 的方向在 SubViewport 里怎么调都会把
	# 正对相机的那个面均匀照亮 → 一片死白，看不出形状。shader 方案是确定性的，
	# 改一个向量就能调光位，不受 Godot 灯光/环境光的任何影响。

	# 正交相机：位于 +X 朝原点看 → 画面水平轴 = 相机右手 = -Z = 枪口方向
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.position = Vector3(CAM_DIST, 0.0, 0.0)
	cam.rotation = Vector3(0.0, deg_to_rad(90.0), 0.0)
	cam.near = 0.05
	cam.far = 50.0
	cam.size = 1.0
	cam.current = true
	vp.add_child(cam)
	_cam = cam
	return vp


# ---------------------------------------------------------------- 单把武器
func _render_one(vp: SubViewport, holder: Node3D, wid: String) -> Image:
	var model_id: String = FALLBACK.get(wid, wid)
	var scene := _load_glb(model_id)
	if scene == null:
		return null
	var inst: Node3D = scene.instantiate()
	holder.add_child(inst)

	# 隐藏手臂节点（击杀信息流只要枪，不要手）
	_hide_arms(inst)
	# 白模：统一套白色材质，只靠明暗表现枪的形状
	_white_clay(inst)
	var fitted := _normalize(inst, wid)
	if not fitted:
		holder.remove_child(inst)
		inst.queue_free()
		return null

	# 按最终尺寸设定正交视野，让枪完整落在画面内
	var aabb := _world_aabb(inst)
	var sz := aabb.size
	var aspect := float(TEX_W) / float(TEX_H)
	var ortho := maxf(sz.y, sz.z / aspect) / (1.0 - 2.0 * PAD)
	if _cam != null:
		_cam.size = maxf(ortho, 0.05)
		_cam.position = Vector3(CAM_DIST, 0.0, 0.0)

	# 等两帧确保渲染完成（SubViewport 的 texture 是异步填充的）
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	_dbg_luma(wid, img)
	img = _polish(img)

	holder.remove_child(inst)
	inst.queue_free()
	return img


# 出图后处理：加一圈深色描边。
#
# 白模在雪地 / 天空这种浅色背景上会「糊边」，单靠本体和白背景分不开，
# 所以向外扩 1px 深色轮廓 —— 这样深色背景上靠白身、浅色背景上靠描边，
# 两种情况都能看清。只填「空像素且八邻域有实体」的位置，不会吃掉枪身本身。
func _polish(src: Image) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var lifted := src
	var outline := Color(0.07, 0.07, 0.09, 0.9)
	var out := lifted.duplicate() as Image
	for y in h:
		for x in w:
			if lifted.get_pixel(x, y).a > 0.35:
				continue
			var hit := false
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var nx: int = x + int(dx)
					var ny: int = y + int(dy)
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					if lifted.get_pixel(nx, ny).a > 0.5:
						hit = true
						break
				if hit:
					break
			if hit:
				out.set_pixel(x, y, outline)
	return out


func _load_glb(wid: String) -> PackedScene:
	for ext in ["glb", "gltf"]:
		var p := "res://models/fpv/%s.%s" % [wid, ext]
		if ResourceLoader.exists(p):
			var r := load(p)
			if r is PackedScene:
				return r as PackedScene
	return null


# ---------------------------------------------------------------- 几何归一化
# 把模型摆成「枪管朝 -Z、中心在原点」的标准姿态
func _normalize(root: Node3D, wid: String) -> bool:
	root.transform = Transform3D.IDENTITY
	var aabb := _world_aabb(root)
	var size := aabb.size
	if size.length() < 0.0001:
		return false
	# 最长轴 = 枪长方向
	var axis := 0
	var longest := size.x
	if size.y > longest:
		axis = 1
		longest = size.y
	if size.z > longest:
		axis = 2
		longest = size.z
	# 枪口朝向：包围盒中心在最长轴上的分量符号（原点通常落在握把上）
	var c := aabb.get_center()
	var comp: float = [c.x, c.y, c.z][axis]
	var dir: Vector3 = [Vector3.RIGHT, Vector3.UP, Vector3.BACK][axis]
	if absf(comp) > longest * 0.02:
		dir = dir * signf(comp)
	root.basis = _rotation_to_forward(dir)
	# 把旋转后的包围盒中心挪到原点
	root.position = -_world_aabb(root).get_center()
	return true


# 求把 fwd 方向旋转到 -Z 所需的旋转（与 player.gd 同款）
func _rotation_to_forward(fwd: Vector3) -> Basis:
	if fwd.z < -0.5:
		return Basis()
	if fwd.z > 0.5:
		return Basis(Vector3.UP, PI)
	if fwd.x > 0.5:
		return Basis(Vector3.UP, deg_to_rad(90.0))
	if fwd.x < -0.5:
		return Basis(Vector3.UP, deg_to_rad(-90.0))
	if fwd.y > 0.5:
		return Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	return Basis(Vector3.RIGHT, deg_to_rad(90.0))


# 根节点下所有可见网格的世界空间包围盒（跳过手臂）
func _world_aabb(root: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null and mi.visible and not _is_arms(mi):
				var t := mi.global_transform
				var mbb := mi.mesh.get_aabb()
				for i in 8:
					var p: Vector3 = t * mbb.get_endpoint(i)
					if first:
						aabb = AABB(p, Vector3.ZERO)
						first = false
					else:
						aabb = aabb.expand(p)
		for ch in n.get_children():
			stack.push_back(ch)
	return aabb


# 新建一张 RGBA8 空图。Godot 4.4+ 把 Image.create 改名成 create_empty，两种都兼容。
func _blank(w: int, h: int) -> Image:
	if ClassDB.class_has_method("Image", "create_empty", true):
		return Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	return Image.create(w, h, false, Image.FORMAT_RGBA8)


# 调试用：统计不透明像素的亮度分布，确认白模到底有没有打出明暗层次
func _dbg_luma(wid: String, img: Image) -> void:
	var lo := 2.0
	var hi := -1.0
	var sum := 0.0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var l := (c.r + c.g + c.b) / 3.0
			lo = minf(lo, l)
			hi = maxf(hi, l)
			sum += l
			n += 1
	if n == 0:
		print("[Icon/dbg] ", wid, " 无实体像素")
		return
	print("[Icon/dbg] %s 亮部=%.3f 暗部=%.3f 均值=%.3f 像素=%d" % [wid, hi, lo, sum / n, n])


# 白模渲染：给每个网格套一层纯白材质。
#
# 为什么不用原始材质：
#   · CS2 模型的枪身是接近纯黑的枪金属，原样渲出来就是一团黑剪影，
#     压在 HUD 的深色背景上完全看不清；
#   · 木纹/聚合物色还会让同一把枪在不同光照下颜色飘。
# 白模只保留**形状**这一个信息量最大的特征 —— 枪型一眼可辨，
# 而且白底在深色画面上最醒目，这也是主流 FPS 击杀图标的一贯做法。
#
# 用 material_override 而不是改各 surface：一条覆盖全部子网格，干净且不会漏。
# 白模材质：unshaded + 自己算半兰伯特明暗。
#
# 为什么不用 StandardMaterial3D + 场景灯光：
#   SubViewport 里怎么摆 DirectionalLight，正对相机的那个面都会被均匀照亮，
#   白模只剩一片死白（实测均值 0.99、亮部全部顶到 1.0 被截断）。
#   这里直接对视图空间法线做半兰伯特，明暗完全由 light_view_dir 一个向量决定，
#   可复现、可调，不受环境光/曝光影响。
#
# light_view_dir 是**视图空间**方向（x=屏幕右, y=屏幕上, z=朝向相机）：
# 现在是左上方略偏相机，所以枪身上亮下暗、左侧亮右侧暗，立体感最明显。
const CLAY_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;

uniform vec3 light_view_dir = vec3(-0.34, 0.88, 0.34);
uniform vec3 lit_color   = vec3(0.93, 0.93, 0.97);
uniform vec3 shade_color = vec3(0.28, 0.31, 0.38);
uniform vec3 rim_color   = vec3(1.0, 1.0, 1.0);
uniform float rim_amount = 0.20;
uniform float rim_power  = 3.5;

void fragment() {
	vec3 n = normalize(NORMAL);
	// 半兰伯特：把 [-1,1] 映到 [0,1]，暗面不会全黑，保留体积感
	float d = dot(n, normalize(light_view_dir)) * 0.5 + 0.5;
	vec3 col = mix(shade_color, lit_color, pow(d, 1.5));
	// 轮廓光：法线越接近垂直于视线（n.z 越小）越亮，把外形从背景里拎出来
	float rim = pow(1.0 - clamp(abs(n.z), 0.0, 1.0), rim_power) * rim_amount;
	ALBEDO = mix(col, rim_color, rim);
}
"""

func _clay_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CLAY_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


func _white_clay(root: Node3D) -> void:
	var mat := _clay_material()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and not _is_arms(n):
			(n as MeshInstance3D).material_override = mat
		for ch in n.get_children():
			stack.push_back(ch)


func _is_arms(n: Node) -> bool:
	return n.name.to_lower().contains("arms")


func _hide_arms(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and _is_arms(n):
			(n as MeshInstance3D).visible = false
		for ch in n.get_children():
			stack.push_back(ch)


# ---------------------------------------------------------------- 总览图
# 把 18 张图标拼成一张带格线的网格图，方便一眼核对朝向/大小是否一致
func _make_sheet(images: Array[Image]) -> void:
	if images.is_empty():
		return
	var cols := SHEET_COLS
	var rows := int(ceil(float(images.size()) / float(cols)))
	var gap := 2
	var sw := cols * TEX_W + (cols - 1) * gap
	var sh := rows * TEX_H + (rows - 1) * gap
	var sheet := _blank(sw, sh)
	# 底色刻意用「雪地 + 天空」的中性中间调，方便一眼判断图标在实际游戏画面上
	# 到底看不看得清（太亮/太暗都会误判）
	sheet.fill(Color(0.34, 0.40, 0.50, 1.0))
	for i in images.size():
		var img: Image = images[i]
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		var cx := (i % cols) * (TEX_W + gap)
		var cy := int(i / cols) * (TEX_H + gap)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(cx, cy))
	var p := ProjectSettings.globalize_path(SHEET_RES)
	var err := sheet.save_png(p)
	print("[Icon] 总览图 ", p, " err=", err, " 顺序=", ", ".join(ORDER))
