extends Control
# 屏幕空间曳光（观感参考 GTA 罪恶都市）
#
# 为什么不用 3D 物体：
# 第一人称下弹道几乎与视线平行，3D 短棒投影到屏幕上只剩几个像素，
# 飞起来就是一个几乎看不见的小点（物理上正确，但完全看不出"弹道"）。
# 屏幕空间画线不受透视缩短影响，始终能看清一条线从枪口射向命中点。
#
# 为什么起点要锁定屏幕坐标：
# 枪口离相机只有约 0.8m。若每帧把固定的世界坐标重新投影，侧移时相机横向移动
# 会让这个近处点横扫整个屏幕（实测 0.22s 内从 x=1083 甩到 x=48），
# 而远处命中点几乎不动 —— 结果就是"站着不动正常，一晃就散"。
# 视模型本身挂在相机下、枪口屏幕位置恒定，所以起点锁定屏幕坐标才是对的。
#
# 由 CSPlayer._spawn_tracer() 创建，自己负责在寿命结束后 queue_free()

var a := Vector2.ZERO            # 枪口屏幕坐标（生成时锁定，之后不再变）
var to_world := Vector3.ZERO     # 命中点世界坐标（每帧重新投影，跟随视角）
var camera: Camera3D             # 用于把命中点转到屏幕坐标
var color := Color(1.0, 0.9, 0.55)
var width_px := 3.0              # 线宽（像素）
var duration := 0.12             # 从枪口飞到命中点的时间
var fade_time := 0.06            # 到达后的淡出时长
var dash_frac := 0.22            # 可见短段占整条弹道的比例

var _t := 0.0
var _b_locked := Vector2.ZERO    # 命中点屏幕坐标缓存（首帧算一次，用于退化判断）


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	if _t >= duration + fade_time:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	# 终点每帧按当前视角重新投影：命中点是固定在世界里的，视角转动时它应该跟着动
	var b := camera.unproject_position(to_world)
	_b_locked = b
	# 弹头进度 0→1
	var p := clampf(_t / maxf(duration, 0.001), 0.0, 1.0)
	# 可见短段：尾端跟在前端后面 dash_frac 处，随弹头一起推进
	var tail := clampf(p - dash_frac, 0.0, 1.0)
	var alpha := 1.0
	if _t > duration:
		alpha = 1.0 - clampf((_t - duration) / maxf(fade_time, 0.001), 0.0, 1.0)
	var p0 := a.lerp(b, tail)
	var p1 := a.lerp(b, p)
	# 抗锯齿画线
	draw_line(p0, p1, Color(color.r, color.g, color.b, alpha), width_px, true)
	# 弹头再点一个亮点，让"子弹本体"更醒目
	if p1.distance_to(p0) > 2.0:
		draw_circle(p1, width_px * 0.75, Color(color.r, color.g, color.b, alpha))
