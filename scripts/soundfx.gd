class_name SoundFX
extends RefCounted

## 程序化音效合成（**纯代码**，不依赖任何外部素材下载或在线生成服务）
##
## ------------------------------------------------------------------ 枪声为什么做成两层
## 素材库里只有一段真实录音 `sounds/shoot.wav`，所有枪共用它 —— 这是"枪声不逼真"的根源：
## 手枪、步枪、狙、机枪听感完全一样。
##
## 本文件的做法：给每把枪**合成一层"低频枪身 + 尾音"**（`gun_voice()` 返回的 `layer`），
## 播放时和真实录音**同时发声**，录音按每把枪的 `pitch` 走音高：
##   手枪 → 录音升调（脆、短） + 薄枪身
##   步枪 → 录音接近原调       + 中等枪身 + 回响尾音
##   狙   → 录音降调（低沉）   + 厚枪身 + 长尾音
##   机枪 → 录音略降           + 最厚枪身
##   霰弹 → 录音大降           + 低频"轰"
## 这样既保留了真实录音的爆裂感，又让每把枪明显不同，且不增加任何素材。
##
## ------------------------------------------------------------------ 机械声
## 换弹 / 拉栓 / 切枪是"多次金属撞击 + 金属摩擦"的组合音，用物理建模的素材块
## （模态共振 / 接触瞬态 / 刮擦 / 闷响）按时间摆好，见下面的"机械声（物理建模）"段。
## 想换成真实录音：把 wav 按 `MECH_FILES` 的名字丢进 `res://sounds/` 即可。

const RATE := 44100


static func _make_pcm(data: PackedFloat32Array, rate: int = RATE) -> AudioStreamWAV:
	# 归一化到 -0.92 再转 16bit：叠加多层后不削波爆音
	var peak := 0.0
	for s in data:
		peak = maxf(peak, absf(s))
	var k := 0.92 / maxf(peak, 0.0001)
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2, int(clampf(data[i] * k, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav


# ==================================================================== 枪声合成层

## 枪声的合成层：低频"枪身" + 尾音"回响"。
##   body_hz  枪身基频（越低越沉）
##   body_amp 枪身强度
##   body_dec 枪身衰减时间（秒）
##   tail_amp 尾音强度
##   tail_dec 尾音衰减时间（秒）
##   tail_lp  尾音低通系数（越小越闷）
static func _gun_layer(body_hz: float, body_amp: float, body_dec: float,
		tail_amp: float, tail_dec: float, tail_lp: float, dur: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var a := clampf(tail_lp, 0.02, 0.9)
	for i in n:
		var t := float(i) / float(RATE)
		var v := 0.0
		# 枪身：低频冲击（正弦 + 一点噪声让它不"纯电子音"）
		if t < body_dec:
			var be := pow(1.0 - t / body_dec, 2.0)
			v += sin(TAU * body_hz * t) * body_amp * be
			v += (randf() * 2.0 - 1.0) * body_amp * 0.22 * be
		# 尾音：低通白噪声，模拟枪声在场地里的回响
		if t < tail_dec:
			var te := pow(1.0 - t / tail_dec, 2.2)
			var nz := randf() * 2.0 - 1.0
			lp += (nz - lp) * a
			v += lp * tail_amp * te
		out[i] = v
	return _make_pcm(out)


## 每把枪的声音配置。键名：
##   pitch 真实录音 shoot.wav 的播放音高（1.0 = 原调）
##   body / ba / bd  合成层枪身（基频 / 强度 / 衰减秒）
##   ta / td / tl    合成层尾音（强度 / 衰减秒 / 低通）
##   dur             合成层总长（秒）
const GUN_VOICE := {
	# ---- 手枪：脆、短、升调 ----
	"Glock":  {"pitch": 1.22, "body": 170.0, "ba": 0.30, "bd": 0.045, "ta": 0.16, "td": 0.12, "tl": 0.55, "dur": 0.16},
	"USP":    {"pitch": 1.15, "body": 160.0, "ba": 0.32, "bd": 0.045, "ta": 0.18, "td": 0.13, "tl": 0.50, "dur": 0.17},
	"Deagle": {"pitch": 0.82, "body": 110.0, "ba": 0.70, "bd": 0.090, "ta": 0.42, "td": 0.28, "tl": 0.30, "dur": 0.32},
	# ---- 冲锋枪：更紧、更亮 ----
	"MP5":    {"pitch": 1.12, "body": 175.0, "ba": 0.28, "bd": 0.040, "ta": 0.16, "td": 0.11, "tl": 0.58, "dur": 0.15},
	"P90":    {"pitch": 1.10, "body": 180.0, "ba": 0.26, "bd": 0.040, "ta": 0.15, "td": 0.10, "tl": 0.60, "dur": 0.14},
	# ---- 霰弹：低频"轰" ----
	"XM1014": {"pitch": 0.78, "body": 72.0,  "ba": 0.85, "bd": 0.130, "ta": 0.55, "td": 0.36, "tl": 0.14, "dur": 0.42},
	# ---- 步枪 ----
	"AK47":   {"pitch": 0.90, "body": 92.0,  "ba": 0.62, "bd": 0.100, "ta": 0.40, "td": 0.30, "tl": 0.26, "dur": 0.34},
	"M4A1":   {"pitch": 0.98, "body": 105.0, "ba": 0.52, "bd": 0.090, "ta": 0.33, "td": 0.26, "tl": 0.34, "dur": 0.30},
	"Galil":  {"pitch": 0.94, "body": 98.0,  "ba": 0.56, "bd": 0.090, "ta": 0.36, "td": 0.27, "tl": 0.30, "dur": 0.31},
	"FAMAS":  {"pitch": 1.00, "body": 112.0, "ba": 0.50, "bd": 0.085, "ta": 0.31, "td": 0.24, "tl": 0.36, "dur": 0.28},
	"SG-552": {"pitch": 0.95, "body": 100.0, "ba": 0.58, "bd": 0.095, "ta": 0.37, "td": 0.28, "tl": 0.30, "dur": 0.32},
	"AUG":    {"pitch": 0.97, "body": 104.0, "ba": 0.54, "bd": 0.090, "ta": 0.34, "td": 0.26, "tl": 0.33, "dur": 0.30},
	# ---- 狙：低沉 + 长尾 ----
	"Scout":  {"pitch": 0.90, "body": 88.0,  "ba": 0.60, "bd": 0.100, "ta": 0.42, "td": 0.32, "tl": 0.24, "dur": 0.36},
	"AWP":    {"pitch": 0.70, "body": 66.0,  "ba": 0.95, "bd": 0.150, "ta": 0.80, "td": 0.62, "tl": 0.16, "dur": 0.70},
	"SG-550": {"pitch": 0.84, "body": 80.0,  "ba": 0.78, "bd": 0.120, "ta": 0.55, "td": 0.42, "tl": 0.20, "dur": 0.48},
	"G3SG1":  {"pitch": 0.82, "body": 78.0,  "ba": 0.80, "bd": 0.120, "ta": 0.58, "td": 0.44, "tl": 0.19, "dur": 0.50},
	# ---- 机枪：最厚 ----
	"M249":   {"pitch": 0.80, "body": 76.0,  "ba": 0.90, "bd": 0.130, "ta": 0.52, "td": 0.38, "tl": 0.20, "dur": 0.42},
}

## 未知武器按类别给的默认配置
const CLASS_VOICE := {
	"pistol":  {"pitch": 1.18, "body": 165.0, "ba": 0.32, "bd": 0.045, "ta": 0.17, "td": 0.12, "tl": 0.52, "dur": 0.16},
	"smg":     {"pitch": 1.12, "body": 178.0, "ba": 0.27, "bd": 0.040, "ta": 0.15, "td": 0.10, "tl": 0.58, "dur": 0.14},
	"rifle":   {"pitch": 0.95, "body": 100.0, "ba": 0.56, "bd": 0.090, "ta": 0.36, "td": 0.27, "tl": 0.30, "dur": 0.31},
	"sniper":  {"pitch": 0.78, "body": 74.0,  "ba": 0.86, "bd": 0.130, "ta": 0.62, "td": 0.48, "tl": 0.18, "dur": 0.54},
	"lmg":     {"pitch": 0.82, "body": 78.0,  "ba": 0.88, "bd": 0.120, "ta": 0.50, "td": 0.36, "tl": 0.20, "dur": 0.40},
	"shotgun": {"pitch": 0.78, "body": 72.0,  "ba": 0.85, "bd": 0.130, "ta": 0.55, "td": 0.36, "tl": 0.14, "dur": 0.42},
	"knife":   {"pitch": 1.00, "body": 200.0, "ba": 0.20, "bd": 0.030, "ta": 0.10, "td": 0.08, "tl": 0.60, "dur": 0.10},
}

## 每把枪只合成一次（合成层是静态的，播放时才配 pitch）
static var _voice_cache: Dictionary = {}


## 取某把枪的声音：`{pitch: float, layer: AudioStreamWAV}`
## 播放时用两个音源叠加：真实录音 shoot.wav 按 `pitch` 走调 + `layer` 原调播放。
static func gun_voice(wid: String, cls: String) -> Dictionary:
	var key := wid + "|" + cls
	if _voice_cache.has(key):
		return _voice_cache[key]
	var cfg: Dictionary = GUN_VOICE.get(wid, {})
	if cfg.is_empty():
		cfg = CLASS_VOICE.get(cls, CLASS_VOICE["pistol"])
	var layer := _gun_layer(float(cfg["body"]), float(cfg["ba"]), float(cfg["bd"]),
			float(cfg["ta"]), float(cfg["td"]), float(cfg["tl"]), float(cfg["dur"]))
	var out := {"pitch": float(cfg["pitch"]), "layer": layer}
	_voice_cache[key] = out
	return out


# ==================================================================== 机械声（物理建模）
#
# 旧版是"几个正弦叠一起的滴滴声"，电子味很重。现在按**真实金属声是怎么产生的**来建模，
# 四种素材块拼出换弹 / 拉栓 / 切枪：
#   _ring()   金属撞击 —— 非谐波模态各自按自己的时间衰减鸣响（金属的泛音本就不成整数倍），
#             高次模态衰减得更快，这是"金属"和"电子音"最本质的区别
#   _burst()  接触瞬态 —— 极短宽带噪声，可选带通（撞击那一下的"咔"）
#   _scrape() 金属摩擦 —— 带通噪声 + 中心频率扫动 + 低频"颗粒"调幅；
#             表面微观凸起互相刮出来的顿挫感就靠那个调幅
#   _thud()   结构闷响 —— 低频正弦 + 低通噪声（弹匣拍到底、枪机撞到位）
# 最后统一过一遍 _room()：几个早期反射 + 轻微低通，去掉"干巴巴的合成味"。
#
# ★ 想换成**真实录音**：把 wav 按 MECH_FILES 里的名字丢进 res://sounds/ 即可，
#   代码优先用录音，文件不存在才走上面的合成。

## 真实录音的落点（想换真声就把文件放进来，文件名别改）
const MECH_FILES := {
	"reload":      "res://sounds/mech_reload.wav",
	"reload_done": "res://sounds/mech_reload_done.wav",
	"bolt":        "res://sounds/mech_bolt.wav",
	"switch":      "res://sounds/mech_switch.wav",
}

## 每种机械声预生成 3 个变体（噪声种子不同），角色随机取一个 ——
## 场上 16 个人换弹不会听成"同一个人录了一遍"。合成只在第一次用到时做一次。
static var _mech_cache: Dictionary = {}


# ---------------------------------------------------------------- 素材块

## 一段带包络的白噪声（后面再滤波塑形）
static func _noise(dur: float, amp: float, shape: float) -> PackedFloat32Array:
	var n := maxi(1, int(dur * RATE))
	var b := PackedFloat32Array()
	b.resize(n)
	for i in n:
		var t := float(i) / float(n)
		b[i] = (randf() * 2.0 - 1.0) * amp * pow(1.0 - t, shape)
	return b


## 一阶低通：去掉白噪声的毛刺，让它像"实体"发出来的
static func _lp(buf: PackedFloat32Array, cutoff: float) -> PackedFloat32Array:
	var a := clampf(TAU * cutoff / float(RATE), 0.001, 1.0)
	var out := PackedFloat32Array()
	out.resize(buf.size())
	var z := 0.0
	for i in buf.size():
		z += (buf[i] - z) * a
		out[i] = z
	return out


## 带通（RBJ，峰值增益 0dB）：把宽带噪声塑造成"某一件金属在响"
static func _bp(buf: PackedFloat32Array, f0: float, q: float) -> PackedFloat32Array:
	var fs := float(RATE)
	var w0 := TAU * clampf(f0, 30.0, fs * 0.45) / fs
	var alpha := sin(w0) / (2.0 * maxf(q, 0.05))
	var b0 := alpha
	var b2 := -alpha
	var a0 := 1.0 + alpha
	var a1 := -2.0 * cos(w0)
	var a2 := 1.0 - alpha
	var out := PackedFloat32Array()
	out.resize(buf.size())
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	for i in buf.size():
		var x := buf[i]
		var y := (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		out[i] = y
	return out


## 把一段素材按时间叠加到总轨上
static func _mix(out: PackedFloat32Array, buf: PackedFloat32Array, t0: float) -> void:
	var off := int(t0 * RATE)
	for i in buf.size():
		var k := off + i
		if k >= 0 and k < out.size():
			out[k] += buf[i]


## 金属撞击（模态合成）。modes = [[频率Hz, 幅度, 衰减秒], ...]
## 频率取**非谐波**比值；衰减秒高次模态要小得多，这是金属听感的关键。
static func _ring(out: PackedFloat32Array, t0: float, modes: Array, gain: float) -> void:
	var start := int(t0 * RATE)
	for m in modes:
		var f := float(m[0])
		if f >= RATE * 0.45:
			continue
		var a := float(m[1]) * gain
		var d := float(m[2])
		var n := int(d * 7.0 * RATE)
		var ph := randf() * TAU
		for i in n:
			var k := start + i
			if k >= out.size():
				break
			var t := float(i) / float(RATE)
			out[k] += sin(TAU * f * t + ph) * a * exp(-t / d)


## 接触瞬态：极短宽带噪声（撞击那一下的"咔"），可选带通
static func _burst(out: PackedFloat32Array, t0: float, dur: float, amp: float,
		bp_hz := 0.0, bp_q := 2.0) -> void:
	var b := _noise(dur, amp, 3.0)
	if bp_hz > 0.0:
		b = _bp(b, bp_hz, bp_q)
	_mix(out, b, t0)


## 结构闷响：低频正弦 + 低通噪声（弹匣拍到底 / 枪机撞到位）
static func _thud(out: PackedFloat32Array, t0: float, hz: float, amp: float, dec: float) -> void:
	var start := int(t0 * RATE)
	var n := int(dec * 7.0 * RATE)
	var ph := randf() * TAU
	var ph2 := randf() * TAU
	for i in n:
		var k := start + i
		if k >= out.size():
			break
		var t := float(i) / float(RATE)
		var e := exp(-t / dec)
		out[k] += (sin(TAU * hz * t + ph) + 0.45 * sin(TAU * hz * 1.83 * t + ph2)) * amp * e
	_mix(out, _lp(_noise(dec * 1.5, amp * 0.5, 3.0), hz * 3.0), t0)


## 金属摩擦（拉栓行程 / 弹匣进出）：带通噪声，中心频率从 f0 扫到 f1，
## 再用 grain_hz 的"颗粒"调幅 —— 那是金属表面微观凸起互相刮出来的顿挫感。
static func _scrape(out: PackedFloat32Array, t0: float, dur: float, amp: float,
		f0: float, f1: float, grain_hz := 60.0, q := 2.8) -> void:
	var start := int(t0 * RATE)
	var n := maxi(1, int(dur * RATE))
	var fs := float(RATE)
	var step := 32          # 滤波器系数每 32 采样更新一次就够（省算力）
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var gph := randf() * TAU
	var b0 := 0.0
	var b2 := 0.0
	var a0 := 1.0
	var a1 := 0.0
	var a2 := 0.0
	for i in n:
		if i % step == 0:
			var f := clampf(lerpf(f0, f1, float(i) / float(n)), 40.0, fs * 0.45)
			var w0 := TAU * f / fs
			var al := sin(w0) / (2.0 * q)
			b0 = al
			b2 = -al
			a0 = 1.0 + al
			a1 = -2.0 * cos(w0)
			a2 = 1.0 - al
		var y := (b0 * (randf() * 2.0 - 1.0) + b2 * x2 - a1 * y1 - a2 * y2) / a0
		x2 = x1
		x1 = randf() * 2.0 - 1.0
		y2 = y1
		y1 = y
		var p := float(i) / float(n)
		var g := 1.0 + 0.6 * sin(TAU * grain_hz * float(i) / fs + gph)
		var env := minf(1.0, p / 0.10) * pow(1.0 - p, 0.7)
		var k := start + i
		if k >= 0 and k < out.size():
			out[k] += y * g * env * amp


## 早期反射 + 轻微低通：去掉"干合成味"，让声音像在一个真实空间里发出来的
static func _room(out: PackedFloat32Array, taps: Array) -> void:
	var dry := out.duplicate()
	for tp in taps:
		var d := int(float(tp[0]) * float(RATE))
		var g := float(tp[1])
		for i in out.size():
			var k := i - d
			if k >= 0:
				out[i] += dry[k] * g
	var a := clampf(TAU * 7200.0 / float(RATE), 0.001, 1.0)
	var z := 0.0
	for i in out.size():
		z += (out[i] - z) * a
		out[i] = z


# ---------------------------------------------------------------- 四条机械声

## 换弹：拍释放钮 → 旧弹匣滑出 → 新弹匣插入（里面子弹磕碰）→ 拍到底卡榫咬合
static func _reload_build() -> AudioStreamWAV:
	var out := PackedFloat32Array()
	out.resize(int(0.90 * RATE))
	# ① 手掌拍下弹匣释放钮：闷的一下 + 金属"哒"
	_thud(out, 0.000, 145.0, 0.32, 0.045)
	_burst(out, 0.000, 0.020, 0.55, 2600.0, 1.6)
	_ring(out, 0.005, [[2050.0, 0.50, 0.020], [3180.0, 0.30, 0.014], [4700.0, 0.16, 0.010]], 0.55)
	# ② 旧弹匣顺着弹匣井滑出来：一段下行刮擦，脱手时闷一声
	_scrape(out, 0.070, 0.14, 0.55, 900.0, 430.0, 48.0)
	_ring(out, 0.200, [[760.0, 0.35, 0.045], [1180.0, 0.22, 0.030]], 0.50)
	_thud(out, 0.200, 120.0, 0.30, 0.050)
	# ③ 新弹匣口磕上弹匣井，里面几发子弹互相碰撞（零散细碎的"嗒"）
	_burst(out, 0.320, 0.014, 0.40, 3400.0, 2.0)
	for _j in 5:
		_ring(out, 0.340 + randf() * 0.10,
				[[float(2400 + randi() % 1800), 0.30, 0.012]], 0.35)
	# ④ 往上插：一段上行刮擦，越插越顺
	_scrape(out, 0.460, 0.11, 0.50, 620.0, 1500.0, 70.0)
	# ⑤ 拍到底 + 卡榫咬合：全曲最重的一记
	_thud(out, 0.575, 95.0, 0.75, 0.075)
	_burst(out, 0.575, 0.022, 0.95, 2700.0, 1.8)
	_ring(out, 0.580, [[1520.0, 0.85, 0.055], [2320.0, 0.55, 0.035],
			[3700.0, 0.30, 0.020], [5300.0, 0.16, 0.012]], 0.90)
	_ring(out, 0.625, [[3100.0, 0.45, 0.018], [4700.0, 0.26, 0.012]], 0.60)
	_room(out, [[0.021, 0.22], [0.038, 0.14], [0.061, 0.08]])
	return _make_pcm(out)


## 上膛（换弹收尾）：拉机柄后拉 → 松手枪机被弹簧猛推复位 → 闭锁
static func _reload_done_build() -> AudioStreamWAV:
	var out := PackedFloat32Array()
	out.resize(int(0.38 * RATE))
	# ① 拉机柄向后：弹簧被压的细碎声 + 金属刮擦
	_scrape(out, 0.000, 0.10, 0.55, 700.0, 1750.0, 85.0)
	_ring(out, 0.020, [[2600.0, 0.22, 0.010], [3900.0, 0.14, 0.008]], 0.35)
	# ② 松手，枪机在弹簧推动下猛地复位：清脆的金属撞击
	_burst(out, 0.110, 0.020, 1.00, 3200.0, 2.0)
	_ring(out, 0.112, [[1320.0, 0.95, 0.060], [2100.0, 0.60, 0.038],
			[3300.0, 0.34, 0.022], [5000.0, 0.18, 0.014]], 1.00)
	# ③ 枪机撞到位（闭锁）：一记闷响
	_thud(out, 0.150, 110.0, 0.85, 0.080)
	_burst(out, 0.150, 0.030, 0.55, 900.0, 1.2)
	# ④ 闭锁到位的小"嗒"
	_ring(out, 0.175, [[2450.0, 0.50, 0.020], [3600.0, 0.30, 0.014], [5400.0, 0.16, 0.010]], 0.60)
	_room(out, [[0.019, 0.20], [0.035, 0.12]])
	return _make_pcm(out)


## 栓动狙拉栓：抬栓 → 后拉抽壳抛壳 → 前推上弹 → 压栓锁闭
static func _bolt_build() -> AudioStreamWAV:
	var out := PackedFloat32Array()
	out.resize(int(0.68 * RATE))
	# ① 抬栓：短促的金属"嗒"
	_burst(out, 0.000, 0.016, 0.75, 3000.0, 2.0)
	_ring(out, 0.002, [[1900.0, 0.70, 0.030], [2900.0, 0.42, 0.020], [4400.0, 0.22, 0.013]], 0.75)
	# ② 后拉：长刮擦（抽壳钩带着弹壳走）
	_scrape(out, 0.090, 0.19, 0.65, 780.0, 1650.0, 46.0)
	_ring(out, 0.100, [[1500.0, 0.30, 0.018]], 0.40)
	# 弹壳被抛出去撞到东西：黄铜的清脆"叮"（比钢件亮得多）
	_ring(out, 0.265, [[4200.0, 0.45, 0.045], [6300.0, 0.26, 0.030], [8800.0, 0.12, 0.020]], 0.55)
	_burst(out, 0.265, 0.014, 0.40, 5200.0, 2.2)
	# ③ 前推：反向刮擦，把新一发顶进膛
	_scrape(out, 0.330, 0.15, 0.55, 1700.0, 880.0, 58.0)
	_ring(out, 0.440, [[2100.0, 0.30, 0.016]], 0.35)
	# ④ 压栓锁闭：最重的一记
	_burst(out, 0.515, 0.024, 1.00, 2800.0, 1.9)
	_ring(out, 0.518, [[1400.0, 1.00, 0.075], [2200.0, 0.62, 0.045],
			[3600.0, 0.34, 0.025], [5200.0, 0.18, 0.015]], 1.00)
	_thud(out, 0.520, 100.0, 0.80, 0.070)
	# ⑤ 锁定的余震
	_ring(out, 0.600, [[2700.0, 0.35, 0.018], [4000.0, 0.20, 0.012]], 0.45)
	_room(out, [[0.023, 0.22], [0.041, 0.13], [0.067, 0.07]])
	return _make_pcm(out)


## 切枪：卸下当前武器 → 拿起新武器 → 握持到位
static func _switch_build() -> AudioStreamWAV:
	var out := PackedFloat32Array()
	out.resize(int(0.30 * RATE))
	# ① 卸下：短刮擦 + 闷响
	_scrape(out, 0.000, 0.07, 0.45, 1250.0, 620.0, 70.0)
	_thud(out, 0.045, 135.0, 0.35, 0.040)
	# ② 拿起新枪：反向短刮擦（手在枪身上蹭一下）
	_scrape(out, 0.090, 0.06, 0.40, 640.0, 1400.0, 80.0)
	# ③ 握持到位：干净的一记金属"嗒" + 一点布料摩擦
	_burst(out, 0.160, 0.014, 0.70, 2900.0, 2.0)
	_ring(out, 0.162, [[1800.0, 0.80, 0.045], [2800.0, 0.48, 0.028], [4200.0, 0.24, 0.016]], 0.80)
	_mix(out, _lp(_noise(0.075, 0.22, 1.6), 1100.0), 0.155)
	_room(out, [[0.019, 0.18], [0.034, 0.11]])
	return _make_pcm(out)


## 取一条机械声：有真实录音就用录音，没有才合成（并缓存 3 个变体）
static func _mech(key: String) -> AudioStreamWAV:
	var path: String = MECH_FILES.get(key, "")
	if path != "" and FileAccess.file_exists(path):
		var s := load(path) as AudioStreamWAV
		if s != null:
			return s
	if not _mech_cache.has(key):
		var v: Array = []
		for _i in 3:
			match key:
				"reload":      v.append(_reload_build())
				"reload_done": v.append(_reload_done_build())
				"bolt":        v.append(_bolt_build())
				_:             v.append(_switch_build())
		_mech_cache[key] = v
	var arr: Array = _mech_cache[key]
	return arr[randi() % arr.size()]


static func reload_snd() -> AudioStreamWAV:
	return _mech("reload")


static func reload_done_snd() -> AudioStreamWAV:
	return _mech("reload_done")


static func bolt_snd() -> AudioStreamWAV:
	return _mech("bolt")


static func switch_snd() -> AudioStreamWAV:
	return _mech("switch")


# ==================================================================== 受击 / UI

## 受击：低频钝击 + 一小段闷噪声（打在护甲/肉上的"噗"）
static func hurt_snd() -> AudioStreamWAV:
	var dur := 0.18
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var e := pow(1.0 - t / dur, 2.0)
		var nz := randf() * 2.0 - 1.0
		lp += (nz - lp) * 0.28
		var thud := sin(TAU * 78.0 * t) * 0.7 + sin(TAU * 120.0 * t) * 0.35
		out[i] = (thud + lp * 0.5) * e
	return _make_pcm(out)


static func buy_snd() -> AudioStreamWAV:
	# 清脆的双音"叮"，购买成功提示
	var rate := 22050
	var n := int(rate * 0.28)
	var data := PackedFloat32Array()
	data.resize(n)
	for i in n:
		var t := float(i) / float(n)
		var env := pow(1.0 - t, 1.8)
		var s := sin(TAU * 880.0 * t) * 0.6 + sin(TAU * 1320.0 * t) * 0.3
		data[i] = s * env * 0.7
	return _make_pcm(data, rate)


static func kill_snd() -> AudioStreamWAV:
	# 击杀：低沉的"咚"（鼓点感）+ 短噪声
	var rate := 22050
	var n := int(rate * 0.22)
	var data := PackedFloat32Array()
	data.resize(n)
	var prev := 0.0
	for i in n:
		var t := float(i) / float(n)
		var env := pow(1.0 - t, 1.5)
		var thump := sin(TAU * 90.0 * t) * 0.8 + sin(TAU * 60.0 * t) * 0.5
		var noise := randf() * 2.0 - 1.0
		var low := prev * 0.5 + noise * 0.5
		prev = low
		data[i] = (thump * 0.7 + low * 0.6) * env * 0.8
	return _make_pcm(data, rate)


static func headshot_snd() -> AudioStreamWAV:
	# 爆头：清脆高频"叮咚"（两段敲击）
	var rate := 22050
	var n := int(rate * 0.35)
	var data := PackedFloat32Array()
	data.resize(n)
	for i in n:
		var t := float(i) / float(n)
		var env := pow(1.0 - t, 1.2)
		var s := 0.0
		if t < 0.5:
			s += sin(TAU * 1560.0 * t) * 0.5
			s += sin(TAU * 2340.0 * t) * 0.3
		var t2 := t - 0.15
		if t2 > 0.0 and t2 < 0.18:
			s += sin(TAU * 660.0 * t2) * 0.6
			s += sin(TAU * 440.0 * t2) * 0.3
		data[i] = s * env * 0.75
	return _make_pcm(data, rate)
