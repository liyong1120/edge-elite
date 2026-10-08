extends Control

## 地图缩略图（俯视示意图）
##
## 不预生成图片：每次重绘都向 provider 取一次"当前地图"的数据，直接用主场景里
## 登记好的寻路障碍 AABB 画俯视图。好处是换地图 / 改地图几何后缩略图自动跟着变，
## 不用额外维护一套贴图资源（也就不会出现"贴图还是上一张地图"的问题）。
##
## provider 必须返回：
##   {
##     "obstacles": Array,       # 墙体 / 石块 / 矮墙（主场景的 nav_obstacles，元素是 AABB）
##     "sites":     Array,       # [{"pos": Vector3, "label": "A", "color": Color}, ...]
##     "spawns":    Dictionary,  # {"CT": Array[Vector3], "T": Array[Vector3]}
##     "bounds":    Rect2,       # 世界 XZ 范围：position.x→左, position.y→上(北),
##                               #              size.x→宽,     size.y→高(南北)
##   }
##
## 画法约定：世界 -Z（北）在屏幕上方、+Z（南）在下方，与游戏内小地图一致。

const PAD := 14.0          # 四周留白（像素）

var provider: Callable = Callable()


func _ready() -> void:
	# 缩略图只做展示，不吃鼠标事件（否则会挡住父面板的交互）
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 数据变了（换地图 / 地图重建）后调一次，下一帧重绘
func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	if not provider.is_valid():
		return
	var d: Dictionary = provider.call()
	if d.is_empty():
		return
	var bounds: Rect2 = d.get("bounds", Rect2())
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return

	# 等比缩放，保证整个地图完整装进控件（不裁切、不拉伸）
	var s: float = minf((size.x - PAD * 2.0) / bounds.size.x,
			(size.y - PAD * 2.0) / bounds.size.y)
	if s <= 0.0:
		return
	var origin := Vector2((size.x - bounds.size.x * s) * 0.5,
			(size.y - bounds.size.y * s) * 0.5)
	var full := Rect2(origin, bounds.size * s)

	# ---- 底板（雪地）+ 外框 ----
	draw_rect(full, Color(0.90, 0.92, 0.96, 0.94), true)
	draw_rect(full, Color(0.36, 0.45, 0.60, 0.9), false, 1.0)

	# ---- 障碍物：按高度分色 ----
	#   高（围墙 3.2 / 大石块 2.9）→ 石灰色
	#   矮（齐胸矮墙 1.4）      → 木箱棕色
	for o in d.get("obstacles", []):
		var bb: AABB = o
		var r := Rect2(origin + Vector2((bb.position.x - bounds.position.x) * s,
						(bb.position.z - bounds.position.y) * s),
				Vector2(bb.size.x * s, bb.size.z * s))
		var col := Color(0.70, 0.68, 0.66) if bb.size.y >= 2.5 \
				else Color(0.80, 0.60, 0.36)
		draw_rect(r, col, true)
		draw_rect(r, Color(0.20, 0.22, 0.28, 0.55), false, 1.0)

	var font: Font = ThemeDB.fallback_font

	# ---- 包点：半透明圆盘 + 贴地字母 ----
	for sd in d.get("sites", []):
		var sp: Vector3 = sd["pos"]
		var c := origin + Vector2((sp.x - bounds.position.x) * s,
				(sp.z - bounds.position.y) * s)
		var col2: Color = sd.get("color", Color(0.92, 0.36, 0.30))
		var rad := maxf(5.0, 2.6 * s)
		draw_circle(c, rad, Color(col2.r, col2.g, col2.b, 0.45))
		draw_arc(c, rad, 0.0, TAU, 28, col2, 1.5, true)
		if font != null:
			draw_string(font, c + Vector2(-3.5, 5.0), String(sd.get("label", "")),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.10, 0.12, 0.16))

	# ---- 出生点：CT 蓝 / T 红 ----
	var sps: Dictionary = d.get("spawns", {})
	for team in ["CT", "T"]:
		var col3 := Color(0.28, 0.60, 0.95) if team == "CT" else Color(0.92, 0.40, 0.30)
		for p in sps.get(team, []):
			var pp: Vector3 = p
			draw_circle(origin + Vector2((pp.x - bounds.position.x) * s,
					(pp.z - bounds.position.y) * s), 2.6, col3)
