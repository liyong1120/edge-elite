extends Control

## 经典十字准星：四根绿色细线，随窗口大小居中
## spread 跟随后坐力动态扩散（开火时准星变大，停火后回正）
## 注意：狙击枪未开镜时由 main.gd 置 hidden_by_weapon，此时不画任何东西

var spread := 0.0  # 后坐力扩散量（0=最紧凑），由 main.gd 每帧更新
var hidden_by_weapon := false  # true = 当前武器不该有准星（狙击枪未开镜）

const CROSS_LEN := 15.0
const CROSS_THICK := 2.0            # 线条粗细
const CROSS_GAP := 6.0              # 中心空隙（不含后坐力扩散）
const CROSS_COLOR := UITheme.CROSSHAIR   # 绿色（配色见 scripts/ui_theme.gd）

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	set_process(true)


# 每帧重绘，确保 spread 变化即时反映（开火时准星张大可见）
func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if hidden_by_weapon:
		return
	var c := size * 0.5
	# gap 跟随 spread 扩大（开火时准星明显张开，模拟子弹散布范围）
	var gap := CROSS_GAP + spread * 250.0
	var length := CROSS_LEN
	var thick := CROSS_THICK
	var col := CROSS_COLOR
	# 上
	draw_rect(Rect2(c + Vector2(-thick * 0.5, -length), Vector2(thick, length - gap)), col)
	# 下
	draw_rect(Rect2(c + Vector2(-thick * 0.5, gap), Vector2(thick, length - gap)), col)
	# 左
	draw_rect(Rect2(c + Vector2(-length, -thick * 0.5), Vector2(length - gap, thick)), col)
	# 右
	draw_rect(Rect2(c + Vector2(gap, -thick * 0.5), Vector2(length - gap, thick)), col)

