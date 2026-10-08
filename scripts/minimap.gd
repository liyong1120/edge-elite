extends Control
## 左上角圆形小地图（雷达，跟随玩家朝向旋转）
## - 以玩家为原点、半径 MAP_HALF 米的局部俯视窗口；玩家恒朝屏幕上方（CS 雷达模式），
##   这样无论面朝哪个方向，"朝左走图上就向左"，不会出现南向时左右反转
## - 自身：白色小箭头（恒指屏幕上方）
## - 友军：绿色圆点；敌军：红色圆点（需视线，隔墙不可见）
## - 墙体：俯视矩形（填充 + 描边），**按圆形做精确多边形裁剪**
##   （旧版是"把超出圆的顶点拉回圆周"，会把矩形扯成梯形/扇形，位置也不对）

const MAP_HALF := 20.0        # 雷达可视半径（米）：只显示玩家周围 20 米（局部视野）
const WALL_MIN_TOP := 0.30    # 方块**顶面**低于此高度（米）的视为地面/贴地薄板，不算墙体
const CIRCLE_SEGS := 48       # 圆形裁剪用的正多边形边数

# 颜色统一从 scripts/ui_theme.gd 取（想换配色只改那一个文件）
const COL_BG := UITheme.RADAR_BG
const COL_RING := UITheme.RADAR_RING
const COL_WALL_FILL := UITheme.RADAR_WALL_FILL
const COL_WALL_LINE := UITheme.RADAR_WALL_LINE
const COL_ALLY := UITheme.RADAR_ALLY
const COL_ENEMY := UITheme.RADAR_ENEMY

var _walls: Array[Dictionary] = []
var _walls_scanned := false

# 墙体裁剪结果缓存。
# 为什么需要：裁剪一个矩形要跑 CIRCLE_SEGS(48) 次半平面裁剪，每次分配一个
# PackedVector2Array，外加 duplicate/dedupe —— 全场约 40 面墙就是每帧上千次堆分配。
# 玩家只挪几厘米时雷达上根本看不出差别，所以按"位移/转角阈值"复用上一帧的结果。
var _cache_pos := Vector3(INF, INF, INF)
var _cache_ry := INF
var _cache_fills: Array[PackedVector2Array] = []
var _cache_lines: Array[PackedVector2Array] = []
const CACHE_MOVE := 0.08      # 玩家位移超过 8cm 才重算墙体
const CACHE_TURN := 0.008     # 玩家转动超过约 0.46° 才重算墙体

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	queue_redraw()  # 每帧重绘，保证位置实时更新

## 切换地图后清空墙体缓存，下次绘制时重新扫描
func reset_walls() -> void:
	_walls.clear()
	_walls_scanned = false
	_cache_pos = Vector3(INF, INF, INF)
	_cache_ry = INF
	_cache_fills.clear()
	_cache_lines.clear()

## 扫描场景中所有墙体（StaticBody3D + BoxShape），缓存**世界坐标**位置与半尺寸
func _scan_walls(tree: SceneTree) -> void:
	if _walls_scanned: return
	_walls_scanned = true
	var scene := tree.current_scene
	if scene == null: return
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is StaticBody3D:
			var m: StaticBody3D = n as StaticBody3D
			for child in m.get_children():
				if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
					var shape: BoxShape3D = (child as CollisionShape3D).shape as BoxShape3D
					var half := shape.size * 0.5
					# 用"方块顶面高度"判定是不是墙：
					#   地面(pos.y=-0.5, half.y=0.5) 顶面 = 0 → 排除；
					#   围墙/石块/小墙 顶面 ≥ 1.4 → 保留。
					# 旧版用 half.y >= 0.08，地面的 half.y=0.5 会被误判成墙，
					# 结果雷达上多出一圈巨大的假矩形。
					var top := m.global_position.y + half.y
					if top >= WALL_MIN_TOP:
						_walls.append({"pos": m.global_position, "half": half})
					break
		for child in n.get_children():
			stack.push_back(child)

func _draw() -> void:
	var tree := get_tree()
	if tree == null: return
	# 找到人类玩家（雷达核心）
	var me: Node3D = null
	for p in tree.get_nodes_in_group("players"):
		if p != null and is_instance_valid(p) and not p.is_bot:
			me = p
			break
	if me == null or not me.is_inside_tree(): return
	_scan_walls(tree)

	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 4.0
	var scale := radius / MAP_HALF
	# 基础映射 (x, z)：北在上、东在右；再绕中心旋转玩家朝向 ry（玩家恒朝上，左右不反转）
	var ry := me.global_rotation.y
	var c := cos(ry)
	var s := sin(ry)
	var origin: Vector3 = me.global_position

	# 圆形底色 + 边框
	draw_circle(center, radius, COL_BG)
	draw_arc(center, radius, 0.0, TAU, 64, COL_RING, 2.0)

	# 墙体轮廓（全图背景，按圆精确裁剪）
	# 只在玩家位移/转角超过阈值时重算几何，其余帧直接复用缓存（见 _rebuild_wall_cache）
	if _cache_pos.distance_to(origin) > CACHE_MOVE or absf(ry - _cache_ry) > CACHE_TURN:
		_rebuild_wall_cache(center, scale, radius, c, s, origin)
		_cache_pos = origin
		_cache_ry = ry
	_draw_cached_walls()

	# 友军绿点 / 敌军红点（敌军需视线）
	var my_team: String = str(me.get("team"))
	for p in tree.get_nodes_in_group("players"):
		if p == null or not is_instance_valid(p) or p == me: continue
		var wp := _to_screen(p.global_position, origin, center, scale, c, s)
		if wp.distance_to(center) > radius - 3.0: continue
		var pteam: String = str(p.get("team"))
		if pteam == my_team:
			draw_circle(wp, 3.5, COL_ALLY)
		else:
			if not _has_los(me, p): continue  # 隔墙不可见
			var col := COL_ENEMY
			if not p.alive: col = col.darkened(0.6)
			draw_circle(wp, 3.5, col)

	# 玩家自身：白色小箭头（跟随朝向旋转，恒指屏幕上方）
	_draw_self_arrow(me, center, scale, c, s, origin)


# 世界坐标 -> 雷达屏幕坐标（以玩家为原点，基础俯视 (x, z)：北在上；再绕中心旋转玩家朝向，玩家恒朝上）
func _to_screen(v: Vector3, origin: Vector3, center: Vector2, scale: float, c: float, s: float) -> Vector2:
	var rx := v.x - origin.x
	var rz := v.z - origin.z
	var x := rx * c - rz * s
	var y := rx * s + rz * c
	return center + Vector2(x, y) * scale


## 重算墙体几何缓存：每个墙是一个轴对齐矩形，投影到雷达后再**裁剪进圆内**（不拉伸、不变形）
## 只由 _draw 在"玩家移动/转动超过阈值"时调用 —— 每帧都算的话是纯浪费（见缓存注释）
func _rebuild_wall_cache(center: Vector2, scale: float, radius: float, c: float, s: float, origin: Vector3) -> void:
	_cache_fills.clear()
	_cache_lines.clear()
	var clip_r := radius - 1.0
	for w in _walls:
		var wp: Vector3 = w.pos
		var half: Vector3 = w.half
		# 粗筛：玩家到该矩形的世界最短距离若已超出雷达半径，直接跳过
		var dx := maxf(absf(origin.x - wp.x) - half.x, 0.0)
		var dz := maxf(absf(origin.z - wp.z) - half.z, 0.0)
		if sqrt(dx * dx + dz * dz) > MAP_HALF + 1.0:
			continue
		var quad := PackedVector2Array([
			_to_screen(Vector3(wp.x - half.x, 0.0, wp.z - half.z), origin, center, scale, c, s),
			_to_screen(Vector3(wp.x + half.x, 0.0, wp.z - half.z), origin, center, scale, c, s),
			_to_screen(Vector3(wp.x + half.x, 0.0, wp.z + half.z), origin, center, scale, c, s),
			_to_screen(Vector3(wp.x - half.x, 0.0, wp.z + half.z), origin, center, scale, c, s),
		])
		var poly := _clip_poly_to_circle(quad, center, clip_r)
		if poly.size() < 3:
			continue
		# 矩形 ∩ 圆 仍是凸多边形，可直接填充
		_cache_fills.append(poly)
		var line := poly.duplicate()
		line.append(poly[0])
		_cache_lines.append(line)


## 把缓存的墙体多边形画出来：每帧调用，**零堆分配**
func _draw_cached_walls() -> void:
	for poly in _cache_fills:
		draw_colored_polygon(poly, COL_WALL_FILL)
	for line in _cache_lines:
		draw_polyline(line, COL_WALL_LINE, 1.0, true)


## 把凸多边形裁剪到圆内：用正 CIRCLE_SEGS 边形近似圆，逐条边做半平面裁剪
## （圆与矩形都是凸集，逐边裁剪的结果与真实圆裁剪完全一致）
func _clip_poly_to_circle(poly: PackedVector2Array, center: Vector2, radius: float) -> PackedVector2Array:
	var out := poly
	for i in CIRCLE_SEGS:
		var a0 := TAU * float(i) / float(CIRCLE_SEGS)
		var a1 := TAU * float(i + 1) / float(CIRCLE_SEGS)
		var p0 := center + Vector2(cos(a0), sin(a0)) * radius
		var p1 := center + Vector2(cos(a1), sin(a1)) * radius
		out = _clip_halfplane(out, p0, p1, center)
		if out.size() < 3:
			return PackedVector2Array()
	return _dedupe(out)


## 保留多边形位于"有向直线 a→b 的 keep 侧"的部分（Sutherland–Hodgman 单边裁剪）
func _clip_halfplane(poly: PackedVector2Array, a: Vector2, b: Vector2, keep: Vector2) -> PackedVector2Array:
	var cnt := poly.size()
	if cnt == 0: return poly
	var nrm := Vector2(b.y - a.y, -(b.x - a.x))
	var k := nrm.dot(keep - a)
	if absf(k) < 1e-9: return poly
	k = signf(k)
	var out := PackedVector2Array()
	for i in cnt:
		var cur := poly[i]
		var nxt := poly[(i + 1) % cnt]
		var dc := nrm.dot(cur - a) * k
		var dn := nrm.dot(nxt - a) * k
		if dc >= 0.0:
			out.append(cur)
		if (dc >= 0.0) != (dn >= 0.0):
			var t := dc / (dc - dn)
			out.append(cur + (nxt - cur) * t)
	return out


## 去掉相邻重复点（裁剪会在顶点处产生重合点，容易生成退化三角形）
func _dedupe(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		if out.size() > 0 and out[out.size() - 1].distance_to(p) < 0.02:
			continue
		out.append(p)
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) < 0.02:
		out.remove_at(out.size() - 1)
	return out


## 视线检测：从玩家头部到目标胸部做射线，被墙体挡住则无视线
func _has_los(me: Node3D, target: Node3D) -> bool:
	var space := me.get_world_3d().direct_space_state
	var from := me.global_position + Vector3(0, 1.35, 0)
	var to := target.global_position + Vector3(0, 1.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [me, target]
	return space.intersect_ray(q).is_empty()


func _draw_self_arrow(me: Node3D, center: Vector2, scale: float, c: float, s: float, origin: Vector3) -> void:
	var p := _to_screen(me.global_position, origin, center, scale, c, s)
	var f := _forward_of(me)
	# 世界朝向经基础俯视 + 玩家朝向旋转后即屏幕方向（旋转后恒指上方）
	var n := _rot_dir(Vector2(f.x, f.z), c, s).normalized()
	var r := Vector2(-n.y, n.x)
	var len := 8.0
	var half_w := 3.5
	var p0 := p + n * len
	var p1 := p - n * len * 0.4 + r * half_w
	var p2 := p - n * len * 0.4 - r * half_w
	draw_colored_polygon(PackedVector2Array([p0, p1, p2]), Color(1.0, 1.0, 1.0, 0.95))


# 方向向量应用与点相同的旋转（基础俯视 (x,z) + 玩家朝向 ry）
func _rot_dir(d: Vector2, c: float, s: float) -> Vector2:
	return Vector2(d.x * c - d.y * s, d.x * s + d.y * c)


func _forward_of(n: Node3D) -> Vector3:
	var f := -n.global_transform.basis.z
	f.y = 0.0
	return f.normalized()
