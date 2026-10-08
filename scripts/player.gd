class_name CSPlayer
extends CharacterBody3D

const SoundFXScript := preload("res://scripts/soundfx.gd")
const CT_MODEL_PATH := "res://models/characters/player.glb"
const T_MODEL_PATH := "res://models/characters/t_player.glb"
const SND_SHOT := preload("res://sounds/shoot.wav")
const SND_STEP := preload("res://sounds/step.wav")
const SND_JUMP := preload("res://sounds/jump.wav")
const SND_LAND := preload("res://sounds/land.wav")
const SND_KNIFE_SWING := preload("res://sounds/knife_swing.wav")
const SND_KNIFE_HIT := preload("res://sounds/knife_hit.wav")
const SND_KNIFE_WALL := preload("res://sounds/knife_wall.wav")
const Tracer2D := preload("res://scripts/tracer2d.gd")

# 手动兜底：某些模型自动判定朝向会出错时，把型号写进这里强制翻转 180°。
# 正常情况应为空（当前 17 把武器全部能自动判对）。
const VM_FLIP_180: Array[String] = []

# 第一人称视模型专用渲染层。
# 手里的枪被渲染到这一层，配一盏 light_cull_mask 只含该层的补光，
# 于是「照亮枪」不会顺带把玩家贴着的墙也打亮 —— 场景光照完全不受影响。
const VM_LAYER := 2

## FPS 玩家角色：移动 / 跳跃 / 蹲伏 / 射击 / 伤害 / 槽位 / 购买

# 第 4 个参数 = 击杀者当时手持的武器 id，供 HUD 显示枪械图标
signal died(victim: CSPlayer, killer: CSPlayer, head: bool, weapon_id: String)
signal weapon_changed(slot: int)
signal ammo_changed(mag: int, reserve: int)

# ---- 移速体系 ----
# 原来只有一把 4.8 m/s 的死数（还只有狙击枪吃减速）——端着 AK 和端着小刀一样快，
# 在这张 36×42 米的小图上 9 秒就能从南墙跑到北墙，观感就是"飘"。
# 现在改成：基础跑速 × 武器类型倍率，Shift / 下蹲再各乘一个系数。
#
# 参考量级（主流 FPS 端枪跑速一般在 4~5.5 m/s 这一档）：
#   小刀 4.93 | 手枪 4.40 | 冲锋枪 4.22 | 霰弹 4.05 | 步枪 3.87 | 机枪 3.61 | 狙 3.43
#   静步（步枪）2.13 | 下蹲（步枪）1.74
const RUN_SPEED := 4.4
const WALK_SLOW_MULT := 0.55   # 静步（Shift）：跑速的 55%，且完全无声
const CROUCH_MULT := 0.45      # 下蹲：比静步更慢

# 各武器类型的移速倍率。`move_penalty` 字段另有一份用途（移动精度惩罚），
# 这里不共用它 —— 那份表里 AWP(0.25) 反而比步枪(1.0) 罚得轻，直接用会倒挂。
const WEAPON_SPEED: Dictionary = {
	"knife":   1.12,
	"pistol":  1.00,
	"smg":     0.96,
	"shotgun": 0.92,
	"rifle":   0.88,
	"lmg":     0.82,
	"sniper":  0.78,
}
const JUMP_VELOCITY := 5.0
const GRAVITY := 12.0
const STAND_HEIGHT := 1.75
const CROUCH_HEIGHT := 1.0
const EYE_HEIGHT := 1.55
const HEAD_LINE := 1.40

# ---------------------------------------------------------------- 后坐力模型
# 约定：武器表里的 `recoil` = **每发累积的散布半角（弧度）**。
#   · 累积到 _recoil，散布 = _recoil * RECOIL_SPREAD
#   · **第一发永远不吃后坐力**（后坐力在开火之后才累加）→ 点射/开镜狙击首发必中
#   · 连发时 _recoil 逐步爬升，散布锥变大；停火后按 RECOIL_DECAY 回落
# 数值参考：0.02 rad ≈ 1.15°，0.14 rad ≈ 8°
const RECOIL_MAX := 0.14          # _recoil 上限 → 最大散布锥约 8°
const RECOIL_SPREAD := 1.0        # 散布 = _recoil * 该系数
const RECOIL_DECAY_STILL := 0.10  # 站定时每秒回落量
const RECOIL_DECAY_MOVE := 0.05   # 移动时每秒回落量（移动更难压枪）
const PITCH_KICK := 1.2           # 每发镜头俯仰上抬 = recoil * 该系数
const PITCH_MAX := 0.12           # 镜头俯仰累积上限（约 6.9°）
const PITCH_DECAY_STILL := 0.6    # 镜头俯仰回正速度（比散布快，方便快速重新瞄准）
const PITCH_DECAY_MOVE := 0.3

# 栓动狙（AWP / Scout）拉栓时间：这期间不能开火，且**开枪瞬间自动退镜**
# （AWP/Scout 每打一发都会退镜，要重新开镜才能精准打下一发）
const BOLT_TIME := 1.4

var team := "T"
var is_bot := false
var nick := "AI"
var money := 10000
var health := 100.0
var armor := 0.0
var has_helmet := false
var alive := true
var kills := 0
var deaths := 0
var headshots := 0
var has_c4 := false
var has_defuser := false

var weapons: Dictionary[int, Dictionary] = {
	1: {},
	2: {},
	3: {"id": "Knife"},
	4: {},
}
var slots: Array[int] = [2, 3]
var active_slot := 2

var head_pitch := 0.0
var _crouching := false
var _walking_slow := false   # 是否按住 Shift 静步（慢走 + 无脚步声）
var _reloading := false
var reload_progress := -1.0  # -1=未换弹；0~1=换弹进度（供 HUD 进度条使用）
var _reload_timer := 0.0
var _reload_total := 0.0
var _reload_wep: Dictionary = {}
var _reload_spec: Dictionary = {}
var _next_fire := 0.0
var _recoil := 0.0
var _recoil_pitch := 0.0  # 后坐力导致的摄像机俯仰偏移（独立于玩家瞄准，衰减时自动回正）
var _zoom := false
var _moving := false
var _speed := RUN_SPEED
var _bolt_until := 0.0
var bolt_progress := -1.0   # -1=未拉栓；0~1=拉栓进度（供 HUD 进度条 + 视模型动作使用）
var _rescope_pending := false  # 拉栓结束后是否自动重新开镜（CF 手感）
var _bob := 0.0
var _kick := 0.0

var _scope_layer: CanvasLayer = null
var _tracer_layer: CanvasLayer = null   # 屏幕空间曳光的绘制层（层号低于狙击镜遮罩）
var _scope_view: Control = null
static var _scope_shader: Shader = null
var _scope_prev_cross := false  # 开镜前 crosshair 的可见状态，收镜后恢复

var _camera: Camera3D
var _view_anchor: Node3D
var _vm_root: Node3D
var _vm_light: OmniLight3D
var _visual: Node3D
var _name_tag: Label3D
var _body_collision: CollisionShape3D
var _snd_shot: AudioStreamPlayer3D
var _snd_shot_layer: AudioStreamPlayer3D   # 枪声的合成层（低频枪身+尾音），和录音叠加
var _snd_step: AudioStreamPlayer3D
var _snd_reload: AudioStreamPlayer3D
var _snd_reload_done: AudioStreamPlayer3D
var _snd_bolt: AudioStreamPlayer3D
var _snd_switch: AudioStreamPlayer3D
var _snd_hurt: AudioStreamPlayer3D
var _snd_jump: AudioStreamPlayer3D
var _snd_land: AudioStreamPlayer3D
var _step_cd := 0.0
var _was_on_floor := true
var _anim_player: AnimationPlayer
var _model_root: Node3D  # glb 实例根（仅挂载 glb 时非空）
var _foot_offset := 0.0   # 模型脚贴地的 position.y（每帧重设，防动画位移偷跑）
var _has_anim := false    # 模型是否存在可用的正常动画（Idle/Walk）
var _show_own_body := false  # 第一人称是否显示自己的身体模型（config.toml [graphics] show_own_body）
var _show_fpv_arms := true   # 第一人称武器是否带握枪手臂（config.toml [graphics] show_fpv_arms）

# ---------------------------------------------------------------- 视模型表现
# 枪口在 _vm_root 局部坐标中的位置（_fit_viewmodel / _build_box_viewmodel 算好后填入）
var _muzzle_local := Vector3(0.0, 0.02, -0.69)
var _flash_mesh: MeshInstance3D          # 枪口火焰面片
var _flash_light: OmniLight3D            # 枪口火焰的短时点光
var _flash_mat: ShaderMaterial
var _flash_until := 0.0                  # 火焰显示截止时刻（秒）
var _flash_peak := 3.0                   # 本次火焰的点光峰值能量（用于按剩余时间衰减）
# 小刀挥砍：-1 = 未挥砍；0~1 = 挥砍进度
var _knife_swing := -1.0
var _knife_dmg_done := false             # 本次挥砍是否已结算过伤害
var _knife_total := 0.36                 # 一次挥砍的总时长（秒）
var _snd_knife_swing: AudioStreamPlayer3D
var _snd_knife_hit: AudioStreamPlayer3D
var _snd_knife_wall: AudioStreamPlayer3D
var _scratch_tex: Texture2D = null       # 小刀划痕纹理（只生成一次复用）


func _ready() -> void:
	add_to_group("players")
	# 读取「是否显示自己的身体模型」（仅对人类玩家有意义）
	if ConfigManager.instance != null:
		var v: Variant = ConfigManager.instance.get_graphics("show_own_body")
		if v is bool:
			_show_own_body = v
		var va: Variant = ConfigManager.instance.get_graphics("show_fpv_arms")
		if va is bool:
			_show_fpv_arms = va
	_build_body()
	_build_camera()
	_build_viewmodel()
	_build_visual()
	_build_sounds()
	_build_scope_overlay()
	# 屏幕空间曳光层：层号 5，低于狙击镜遮罩(11)，开镜时曳光不会盖在镜片上
	_tracer_layer = CanvasLayer.new()
	_tracer_layer.layer = 5
	add_child(_tracer_layer)
	var pivot := "Glock" if team == "T" else "USP"
	give_weapon(2, pivot)
	_refresh_viewmodel()


# ---------------------------------------------------------------- 3D 定位音源
# 所有世界音效都挂在角色身上、走 AudioStreamPlayer3D：
# 带距离衰减 + 左右声像，所以"枪声/脚步在哪个方向、多远"是**听得出来**的。
# 旧版全是非定位 AudioStreamPlayer —— 无论多远、在哪个方向音量都一样，
# 玩家根本没法靠声音判断方位（"听声辨位"也就无从谈起）。
const SND_UNIT_SIZE := 7.0     # 反距离衰减的参考距离（越小衰减越快）
const SND_MAX_DIST := 90.0     # 衰减上限距离（再远保持一个很低的音量）
const SND_MAX_DB := 2.0        # 贴脸时的最大增益

func _build_sounds() -> void:
	_snd_shot = _add_sound(SND_SHOT, 0.45, 6)
	# 枪声的合成层（低频枪身 + 尾音）：和真实录音**同时播放**，
	# 让手枪/步枪/狙/机枪听感明显不同（素材只有一段 shoot.wav，所有枪共用）
	_snd_shot_layer = _add_sound(null, 0.60, 6)
	_snd_step = _add_sound(SND_STEP, 0.45, 6)
	_snd_reload = _add_sound(SoundFXScript.reload_snd(), 0.8, 2)
	_snd_reload_done = _add_sound(SoundFXScript.reload_done_snd(), 0.7, 2)
	_snd_bolt = _add_sound(SoundFXScript.bolt_snd(), 0.8, 2)
	_snd_switch = _add_sound(SoundFXScript.switch_snd(), 0.55, 2)
	_snd_hurt = _add_sound(SoundFXScript.hurt_snd(), 0.8, 3)
	_snd_jump = _add_sound(SND_JUMP, 0.5, 2)
	_snd_land = _add_sound(SND_LAND, 0.6, 2)
	# 小刀：挥空 / 命中身体 / 划到硬表面，三种声音分开，避免听起来一样
	_snd_knife_swing = _add_sound(SND_KNIFE_SWING, 0.55, 3)
	_snd_knife_hit = _add_sound(SND_KNIFE_HIT, 0.9, 2)
	_snd_knife_wall = _add_sound(SND_KNIFE_WALL, 0.7, 2)


## 脚步声（**玩家和 bot 共用**）：静步 / 蹲下完全无声，跑动按随机间隔发声。
## 同时向 GM 发一次噪声事件 → 半径内的 bot 会听到并过来查看（听声辨位）。
## 静步/蹲下不发声也**不产生噪声**，所以"摸过去"是真的能潜行。
## force_ground：远端角色本机不跑物理，`is_on_floor()` 永远是 false，只能按"同步过来的
## 动画是 Walk"当依据 —— 否则联机时别人跑过来你一点脚步声都听不到。
func try_footstep(delta: float, moving: bool, force_ground := false) -> void:
	_step_cd -= delta
	if not moving or _step_cd > 0.0:
		return
	if _crouching or _walking_slow or (not force_ground and not is_on_floor()):
		return
	_step_cd = randf_range(0.29, 0.35)
	if _snd_step:
		_snd_step.pitch_scale = randf_range(0.88, 1.14)
		_snd_step.volume_db = linear_to_db(randf_range(0.32, 0.52))
		_snd_step.play()
	if GM != null:
		GM.emit_noise(global_position, GM.NOISE_RADIUS_STEP, self)


func _add_sound(stream: AudioStreamWAV, volume: float, polyphony: int) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = linear_to_db(volume)
	p.max_polyphony = polyphony
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = SND_UNIT_SIZE
	p.max_distance = SND_MAX_DIST
	p.max_db = SND_MAX_DB
	p.position = Vector3(0, 1.2, 0)   # 从胸口高度发声（不是脚底）
	add_child(p)
	return p


func _build_visual() -> void:
	# 第三人称角色模型：
	# 1) CT → res://models/characters/player.glb，T → res://models/characters/t_player.glb
	# 2) 都不存在则使用程序化胶囊体人形兜底
	_visual = Node3D.new()
	add_child(_visual)
	var built := false
	var model_path := CT_MODEL_PATH if team == "CT" else T_MODEL_PATH
	if ResourceLoader.exists(model_path):
		built = _attach_glb(_visual, load(model_path))
	if not built:
		_build_fallback_visual()
	# 第一人称：默认隐藏自己的身体模型（只看得到手中武器）；
	# 打开 config.toml 的 show_own_body 后显示（CF 风格，低头能看到躯干和腿），
	# 此时必须把头部各分片隐藏，否则相机会被包在头里、整个视野被挡死。
	if not is_bot:
		_visual.visible = _show_own_body
		if _show_own_body:
			_hide_head_parts()
	_build_team_marker()


# 第一人称显示自身模型时隐藏头部。
# 头部和身体在同一个蒙皮网格里，没法单独隐藏节点；
# 但 GLB 里头部是独立分片（CT: ctm_fbi_v2_head_variantc / T: ctm_sas_head_gasmask），
# 所以给这些分片套一个全透明材质即可 —— 比缩放骨骼干净，不会留下塌缩残渣。
# 顺带把帽子/眼镜/镜片一起隐藏，否则会看到一顶悬空的头盔。
func _hide_head_parts() -> void:
	if _model_root == null:
		return
	var ghost := StandardMaterial3D.new()
	ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
	ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost.flags_unshaded = true
	ghost.cull_mode = BaseMaterial3D.CULL_DISABLED
	for node in _model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mat: Material = mi.get_active_material(si)
			if mat == null:
				mat = mi.mesh.surface_get_material(si)
			if mat == null:
				continue
			var mn := mat.resource_name.to_lower()
			if mn == "":
				mn = mat.resource_path.get_file().to_lower()
			if mn.contains("head") or mn.contains("hat") or mn.contains("lens"):
				mi.set_surface_override_material(si, ghost)


func _attach_glb(parent: Node3D, resource: PackedScene) -> bool:
	if resource == null or not resource.can_instantiate():
		return false
	var inst: Node3D = resource.instantiate()
	if inst == null:
		return false
	# 在加入场景树之前查找 AnimationPlayer 并清除 autoplay：
	# Sketchfab 导出的 CS2 模型自带动画是损坏的 eye_test/tools_preview，
	# add_child 后 autoplay 会立即播放它们把骨骼扭成扭曲姿态。
	# 注意：进入场景树后再设置 autoplay 无效（警告），必须提前。
	var animps := inst.find_children("*", "AnimationPlayer", true, false)
	for ap in animps:
		(ap as AnimationPlayer).autoplay = ""
	_anim_player = animps.front() as AnimationPlayer
	parent.add_child(inst)
	_model_root = inst
	# 用网格 AABB 定位模型：遍历所有网格的本地 AABB，累积本地变换到 inst 空间
	# 不用骨骼（骨骼空间和网格顶点空间不同，骨骼 48m 但网格只有 ~2m）
	_align_by_mesh_aabb(inst)
	# Sketchfab 模型正面朝 +Z，玩家视线朝 -Z，转 180°（放在缩放之后避免被覆盖）
	inst.rotate_y(PI)
	# 保留 GLB 自带材质/贴图（衣服/护甲/装备等细节颜色），
	# 不要用单色 material_override 覆盖——否则会变成"上色的玩具"
	var meshes := inst.find_children("*", "MeshInstance3D", true, false)
	for child in meshes:
		child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		child.visible = true
# 查找 AnimationPlayer；只有存在正常动画（Idle / Walk）才播放。
	# Sketchfab 导出的 CS2 模型自带的是损坏的 eye_test/tools_preview 动画，
	# 播放它们会让角色姿势扭曲（骨骼飞到几米外），必须跳过、保持静止姿态
	if _anim_player:
		# 不能强制把骨骼设成 Identity——mesh 是绑在 bent rest pose 上的，
		# 强行 Identity 会让整个 mesh 撕裂成乱麻（已验证）。
		if _anim_player.is_playing():
			_anim_player.stop()
		# 生成程序化 Idle/Walk 动画（模型自带的 eye_test/tools_preview 已损坏），
		# 供 _try_play_anim 播放，否则角色走路时不会摆腿。
		_build_procedural_anims(inst)
	return true


# 播放动画：仅当模型确实存在该动画时才切换，避免对无动画模型（CS2 导出模型）
# 调用 play 导致报错
func _try_play_anim(anim_name: String) -> void:
	net_anim = anim_name          # 记下来同步给别的机器（远端角色靠它播动画）
	if _anim_player == null or not _anim_player.has_animation(anim_name):
		return
	if _anim_player.current_animation == anim_name:
		return
	_anim_player.play(anim_name)


# ------------------------------------------------------------------ 程序化动画
# 对没有正常动画的模型（Sketchfab 导出的 CS2 模型，自带动画已损坏）在运行时生成
# Idle（站立呼吸）与 Walk（走路摆臂）动画，让角色有生命感。
# 骨骼按前缀匹配（两个模型的骨骼名后缀数字不同，如 leg_upper_l_78 / leg_upper_l_74）。

func _build_procedural_anims(root: Node3D) -> void:
	var skel: Skeleton3D = root.find_children("*", "Skeleton3D", true, false).front() as Skeleton3D
	if skel == null or _anim_player == null:
		return
	# 骨骼轨道路径：相对 AnimationPlayer 根节点到 Skeleton3D 的路径 + ":" + 骨骼名
	var root_node: Node = _anim_player.get_parent()
	if _anim_player.root_node != NodePath("..") and _anim_player.has_node(_anim_player.root_node):
		root_node = _anim_player.get_node(_anim_player.root_node)
	var skel_path: NodePath = root_node.get_path_to(skel)
	var walk := _build_walk_anim(skel, skel_path)
	var idle := _build_idle_anim(skel, skel_path)
	if walk == null or idle == null:
		return
	# Godot 4 中动画存放在 AnimationLibrary 里，AnimationPlayer 无 add_animation 方法。
	# 注意：GLB 自带同名 Walk/Idle（Sketchfab 预览微动动画），add_animation 对已存在名字
	# 会静默失败，程序化动画会完全装不上、游戏里一直播放自带微动 → 腿看起来不会动。
	# 因此必须"改写"自带动画资源的内容（清空旧轨道后写入我们的轨道）。
	var lib: AnimationLibrary = _anim_player.get_animation_library("")
	if lib == null:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library("", lib)
	_overwrite_anim(lib, "Walk", walk)
	_overwrite_anim(lib, "Idle", idle)
	# 改写后的轨道路径与改写前可能不同（前缀匹配条数变化），必须清缓存否则播放旧轨道
	_anim_player.clear_caches()
	_has_anim = true
	_anim_player.play("Idle")


# 把 new_anim 的轨道内容写入库中 name 动画（若不存在则新建）。绕开 add_animation
# 因同名静默失败的问题，保证程序化动画一定生效。
func _overwrite_anim(lib: AnimationLibrary, name: String, new_anim: Animation) -> void:
	var target: Animation
	if lib.has_animation(name):
		target = lib.get_animation(name)
		# 清空旧轨道（remove_track 会随索引收缩，始终删 0 号）
		while target.get_track_count() > 0:
			target.remove_track(0)
	else:
		target = Animation.new()
		lib.add_animation(name, target)
	target.length = new_anim.length
	target.loop_mode = new_anim.loop_mode
	for i in new_anim.get_track_count():
		var ttype := new_anim.track_get_type(i)
		target.add_track(ttype)
		target.track_set_path(i, new_anim.track_get_path(i))
		var kc := new_anim.track_get_key_count(i)
		for k in kc:
			target.track_insert_key(
				i,
				new_anim.track_get_key_time(i, k),
				new_anim.track_get_key_value(i, k),
				new_anim.track_get_key_transition(i, k),
			)


# 创建骨骼旋转轨道并插入关键帧：给所有匹配前缀的骨骼加轨道
# （含 twist 骨骼如 arm_upper_l_twist_28，它们与主骨骼方向一致，同步旋转避免网格撕裂）
#
# Godot 骨骼动画旋转轨道是"绝对局部旋转"——播放时直接写入 bone pose rotation，
# 不会自动叠加 rest pose。CS2/Sketchfab 模型 rest pose 带 bent（如 leg_upper_l 局部
# Y≈2.88 rad），若轨道直接写小角度增量，会把骨骼掰直导致模型对折/悬浮。
# 正确做法：每个关键帧 = rest_q * delta_q，在绑定姿态上叠加摆动。
func _rot_track(anim: Animation, skel: Skeleton3D, skel_path: NodePath, prefix: String, times: Array, quats: Array) -> void:
	for i in skel.get_bone_count():
		var nm := skel.get_bone_name(i)
		if not nm.begins_with(prefix):
			continue
		var rest_q: Quaternion = skel.get_bone_pose_rotation(i)
		var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(idx, NodePath(str(skel_path) + ":" + nm))
		for j in times.size():
			anim.track_insert_key(idx, times[j], rest_q * quats[j])


func _build_walk_anim(skel: Skeleton3D, skel_path: NodePath) -> Animation:
	var anim := Animation.new()
	anim.length = 1.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var times: Array = [0.0, 0.25, 0.5, 0.75, 1.0]

	var leg_l: Array = []
	var leg_r: Array = []
	var knee_l: Array = []
	var knee_r: Array = []
	var hip: Array = []
	var spine0: Array = []
	var spine1: Array = []
	# 幅度说明：之前误判存在"杠杆效应"（骨骼 rest 平移 17.9m+16.9m 导致小角度→大位移），
	# 因此把幅度压到 0.008/0.012，视觉上完全看不出。
	# 实测：蒙皮顶点位移 = 旋转角 × 顶点到骨骼轴的真实距离（≈腿长 0.5m），
	# 0.008 rad × 0.5m ≈ 4mm，当然不动；0.30 rad × 0.5m ≈ 15cm，才是正常步幅。
	# 注意：左右骨骼局部轴是镜像的，必须用"同号"旋转值才能让两腿交替迈步，
	# 用反号会导致两腿同向滑动（看起来像不会动）。探针已实测验证。
	for t in times:
		var s := sin(t * TAU)
		# 大腿绕局部 X 前后摆 ±0.30 rad（≈17°），正常走路幅度
		leg_l.append(Quaternion(Vector3.RIGHT, -0.30 * s))
		leg_r.append(Quaternion(Vector3.RIGHT, -0.30 * s))
		# 小腿：摆动腿前送时膝盖弯曲抬起（同号 + 时机反相），支撑腿基本伸直
		knee_l.append(Quaternion(Vector3.RIGHT, 0.40 * maxf(0.0, s)))
		knee_r.append(Quaternion(Vector3.RIGHT, 0.40 * maxf(0.0, -s)))
		# 骨盆/脊柱：小幅摆动增加自然感
		hip.append(Quaternion(Vector3.RIGHT, 0.03 * s) * Quaternion(Vector3.UP, 0.04 * s))
		spine0.append(Quaternion(Vector3.RIGHT, 0.02 * s))
		spine1.append(Quaternion(Vector3.RIGHT, -0.015 * s))

	_rot_track(anim, skel, skel_path, "leg_upper_l", times, leg_l)
	_rot_track(anim, skel, skel_path, "leg_upper_r", times, leg_r)
	_rot_track(anim, skel, skel_path, "leg_lower_l", times, knee_l)
	_rot_track(anim, skel, skel_path, "leg_lower_r", times, knee_r)
	_rot_track(anim, skel, skel_path, "pelvis", times, hip)
	_rot_track(anim, skel, skel_path, "spine_0", times, spine0)
	_rot_track(anim, skel, skel_path, "spine_1", times, spine1)
	return anim


func _build_idle_anim(skel: Skeleton3D, skel_path: NodePath) -> Animation:
	var anim := Animation.new()
	anim.length = 2.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var times: Array = [0.0, 0.5, 1.0, 1.5, 2.0]

	var breath0: Array = []
	var breath1: Array = []
	for t in times:
		var w := sin(t * PI)
		# 呼吸：脊柱 2 秒周期前后微动（杠杆放大，必须 0.001 级）
		breath0.append(Quaternion(Vector3.RIGHT, 0.001 * w))
		breath1.append(Quaternion(Vector3.RIGHT, -0.0008 * w))

	_rot_track(anim, skel, skel_path, "spine_0", times, breath0)
	_rot_track(anim, skel, skel_path, "spine_1", times, breath1)
	return anim


# 用蒙皮后顶点的真实世界 AABB 定位模型。skinned mesh 的 mi.get_aabb() 只返回网格
# 数据局部 AABB（很小 ~0.015m），不是蒙皮后的可见范围；而骨骼 rest pose 也很不可靠
# （CS2/Sketchfab 模型常把 leg_lower_l 之类的骨骼放到 y=17.9m 这种完全错乱的位置）。
#
# 唯一可靠的方案：枚举每个 mesh 的顶点，套上 skel.get_bone_global_pose() 做加权混合，
# 得到蒙皮后顶点在 mesh 局部空间中的真实 AABB，再换算到 inst 局部空间。
func _align_by_mesh_aabb(inst: Node3D) -> void:
	# 先重置 inst 的 transform，避免旧值污染
	inst.scale = Vector3.ONE
	inst.position = Vector3.ZERO
	inst.force_update_transform()

	var skel: Skeleton3D = inst.find_children("*", "Skeleton3D", true, false).front() as Skeleton3D
	var meshes: Array = inst.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		return

	# --- 收集所有蒙皮后顶点的 AABB（在 inst 局部空间）---
	var min_v := Vector3.INF
	var max_v := -Vector3.INF
	var total_verts: int = 0
	for mi_node in meshes:
		var mi: MeshInstance3D = mi_node as MeshInstance3D
		mi.force_update_transform()
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		# 找到这个 mesh 所属的 skeleton（可能就是这个 inst 下的全局 skel，也可能是 mesh 父级）
		# 注意：mi.skeleton 是 NodePath（节点路径），不是 Skeleton3D 节点本身，要 get_node() 解引用
		var mi_skel: Skeleton3D = skel
		if mi.skeleton != NodePath(""):
			var resolved: Node = mi.get_node_or_null(mi.skeleton)
			if resolved is Skeleton3D:
				mi_skel = resolved as Skeleton3D
		elif mi.get_parent() is Skeleton3D:
			mi_skel = mi.get_parent() as Skeleton3D
		# 两套变换：mesh 局部→inst（未蒙皮用），skeleton 局部→inst（蒙皮后用）
		var mi_to_inst: Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		var skel_to_inst: Transform3D = inst.global_transform.affine_inverse() * mi_skel.global_transform

		for surface_idx in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface_idx)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if vertices.is_empty():
				continue
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays.size() > Mesh.ARRAY_BONES else PackedInt32Array()
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays.size() > Mesh.ARRAY_WEIGHTS else PackedFloat32Array()
			var has_skin: bool = (bones.size() == vertices.size() * 4) and (weights.size() == vertices.size() * 4) and mi_skel != null

			for v_idx in vertices.size():
				var v: Vector3 = vertices[v_idx]
				var inst_corner: Vector3
				if has_skin:
					# 4 根骨加权混合。bone_xform * v 得到 skeleton 局部空间下的顶点
					var skinned := Vector3.ZERO
					var total_w: float = 0.0
					for j in 4:
						var bone_idx: int = bones[v_idx * 4 + j]
						var w: float = weights[v_idx * 4 + j]
						if w <= 0.0:
							continue
						var bone_xform: Transform3D = mi_skel.get_bone_global_pose(bone_idx)
						skinned += w * (bone_xform * v)
						total_w += w
					if total_w > 0.0001:
						# 通过 skeleton 的 global_transform 转到 inst 空间（不要再套 mi.transform）
						inst_corner = skel_to_inst * (skinned / total_w)
					else:
						inst_corner = mi_to_inst * v
				else:
					# 未蒙皮：直接从 mesh 局部转到 inst 空间
					inst_corner = mi_to_inst * v
				min_v = min_v.min(inst_corner)
				max_v = max_v.max(inst_corner)
				total_verts += 1

	if total_verts == 0:
		push_warning("[对齐] 无可用顶点，跳过")
		return

	var height: float = max_v.y - min_v.y

	# 高度合理（0.5~3m）才缩放；人模型应在 1.5~2.5m
	if height > 0.5 and height < 3.0:
		var s: float = STAND_HEIGHT / height
		inst.scale = Vector3(s, s, s)
		# 把脚（AABB 最低点）放到 y=0 地面上
		inst.position.y = -min_v.y * s
		_foot_offset = inst.position.y
	else:
		inst.scale = Vector3.ONE
		_foot_offset = 0.0



func _build_fallback_visual() -> void:
	# —— 胶囊体人形（高度约 1.7，与碰撞体一致) ——
	var suit := Color(0.72, 0.55, 0.32) if team == "T" else Color(0.24, 0.5, 0.78)
	var skin := Color(0.9, 0.75, 0.6)
	var boot := Color(0.28, 0.24, 0.2)
	# 头
	_sphereish(Vector3(0, 1.53, 0), 0.15, skin)
	# 躯干
	_capsule(Vector3(0, 0.9, 0), Vector3(0, 1.36, 0), 0.26, suit)
	_capsule(Vector3(0, 0.76, 0), Vector3(0, 0.96, 0), 0.22, suit)
	# 上肢（A字摆臂）
	_capsule(Vector3(-0.34, 1.31, 0), Vector3(-0.42, 0.85, 0), 0.075, suit)
	_capsule(Vector3(0.34, 1.31, 0), Vector3(0.42, 0.85, 0), 0.075, suit)
	# 手
	_sphereish(Vector3(-0.45, 0.83, 0), 0.065, skin)
	_sphereish(Vector3(0.45, 0.83, 0), 0.065, skin)
	# 下肢
	_capsule(Vector3(-0.13, 0.57, 0), Vector3(-0.14, 0.18, 0), 0.13, boot)
	_capsule(Vector3(0.13, 0.57, 0), Vector3(0.14, 0.18, 0), 0.13, boot)


func _capsule(a: Vector3, b: Vector3, radius: float, color: Color) -> void:
	var dist := a.distance_to(b)
	if dist < 0.001: return
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = dist
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	cm.material = mat
	mi.mesh = cm
	mi.position = (a + b) * 0.5
	var q := Quaternion(Vector3.UP, (b - a).normalized())
	mi.quaternion = q
	_visual.add_child(mi)


func _sphereish(pos: Vector3, radius: float, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	sm.material = mat
	mi.mesh = sm
	mi.position = pos
	_visual.add_child(mi)


func _build_team_marker() -> void:
	# 人类玩家第一人称不显示自己的模型
	if not is_bot:
		_visual.visible = false
		return
	# 腰部名字标签：默认隐藏，准星对准时由本地玩家射线控制显示（CF 风格）
	_name_tag = Label3D.new()
	_name_tag.text = nick
	_name_tag.font_size = 44
	_name_tag.pixel_size = 0.004
	_name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_tag.no_depth_test = true
	_name_tag.outline_size = 10
	_name_tag.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_name_tag.position = Vector3(0, 1.1, 0)
	# 队友显示绿色名字，敌人显示红色名字
	var local_team := "T"
	if GM != null and GM.player != null:
		local_team = GM.player.team
	_name_tag.modulate = Color(0.3, 0.95, 0.4) if team == local_team else Color(0.95, 0.25, 0.2)
	_name_tag.visible = false
	_visual.add_child(_name_tag)


func _build_body() -> void:
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	# 判定高度 = STAND_HEIGHT + 0.15：略高于模型显示（宽容判定，
	# 保证准星对模型头部/头盔也能命中，不会被模型头顶 mesh 挡住）
	shape.height = STAND_HEIGHT + 0.15
	col.shape = shape
	# 碰撞体从地面(0)延伸到头顶(STAND_HEIGHT + 0.1)，而不是居中在原点
	col.position.y = shape.height * 0.5
	add_child(col)
	_body_collision = col


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 90.0
	_camera.position = Vector3(0, EYE_HEIGHT, 0)
	add_child(_camera)
	if not is_bot:
		_camera.make_current()


func _build_viewmodel() -> void:
	_view_anchor = Node3D.new()
	_camera.add_child(_view_anchor)
	# 右下角：不影响准星视野
	_view_anchor.position = Vector3(0.32, -0.32, -0.6)
	_view_anchor.rotation_degrees = Vector3(0, 0, -4)
	_vm_root = Node3D.new()
	_vm_root.scale = Vector3(0.6, 0.6, 0.6)
	_view_anchor.add_child(_vm_root)
	_build_vm_light()


# 视模型补光。
# 场景里只有一盏太阳光，玩家站在阴影里时手里的枪就是一坨平光：
# 金属件没有高光、塑料件没有体积感，模型再精细也显不出来。
# 这里挂一盏只照亮视模型的小点光（左上前方），给枪一个稳定的高光和明暗交界，
# 观感立刻"立"起来 —— 主流 FPS 都会给视模型单独打一盏灯。
func _build_vm_light() -> void:
	_vm_light = OmniLight3D.new()
	# 只照视模型层：墙、地面、其他玩家都不受影响
	_vm_light.light_cull_mask = 1 << (VM_LAYER - 1)
	_vm_light.light_energy = 1.25
	_vm_light.light_color = Color(1.0, 0.97, 0.92)
	_vm_light.omni_range = 3.0
	_vm_light.omni_attenuation = 1.2
	# 左上前方（_view_anchor 局部），模拟从画面外斜上方打下来的补光
	_vm_light.position = Vector3(-0.22, 0.34, 0.10)
	_view_anchor.add_child(_vm_light)


# ------------------------------------------------------------------ 输入
func _unhandled_input(event: InputEvent) -> void:
	if is_bot or not alive: return
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			var sens := 0.0022
			rotate_y(-event.relative.x * sens)
			head_pitch -= event.relative.y * sens
			head_pitch = clampf(head_pitch, -1.55, 1.55)
			_camera.rotation.x = head_pitch + _recoil_pitch
	elif event is InputEventMouseButton:
		if GM != null and GM.buy_menu_visible: return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_auto_fire_pressed = event.pressed
			if event.pressed:
				fire()
		elif event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_zoom_toggle()


# 长按左键连发（半自动武器仍由 fire() 内部的 _next_fire 间隔控制）
var _auto_fire_pressed := false
func _auto_fire() -> void:
	# 购买菜单打开 / 主菜单 / 回合结束时不射击；购买阶段菜单关闭时可开火
	if GM != null and GM.buy_menu_visible: return
	if GM != null and (GM.state == GM.STATE.MENU or GM.state == GM.STATE.OVER): return
	if _auto_fire_pressed:
		fire()


func _process(delta: float) -> void:
	# 模型脚贴地：每帧重设 y，防止动画位移把模型抬离地面
	if _model_root != null:
		_model_root.position.y = _foot_offset
	# ★ 远端角色（别人的角色）：本机不跑 AI / 物理，所以动画和生死姿势都得自己补 ★
	if not is_multiplayer_authority():
		# 生死姿势：_die() 只在房主那边跑，客户端只有同步过来的 alive 值，
		# 不自己摆的话尸体会一直站着（alive=false 但模型还是站姿）
		if alive != _net_alive_prev:
			_net_alive_prev = alive
			if alive:
				revive()
			else:
				_lay_down()
		# 动画：靠同步过来的 net_anim
		if alive and net_anim != "":
			_try_play_anim(net_anim)
		# 脚步声：本机不跑物理，用"动画是不是 Walk"当依据
		# （顺带 emit_noise —— 房主那边的 bot 才听得到客户端在跑）
		try_footstep(delta, alive and net_anim == "Walk", true)


# ==================================================================== 局域网同步
# ★ 权威划分（房主就是服务器）★
#   · 电脑（bot）   → authority = 1（房主）。**只有房主跑 AI**，客户端只负责显示同步过来的位置。
#   · 真人玩家      → authority = 他自己那台机器。**移动由本人算**（客户端权威，手感不受延迟影响），
#                     别人看到的只是同步过来的位置。
#   · 伤害/死亡/回合 → 全部由房主结算（见 apply_damage / main.gd 的 _net_damage）。
# 同步的属性只挑"看得见的"：位置 / 朝向 / 血量 / 生死 / 有没有带包。
# 换弹进度、拉栓进度、后坐力这些是本机表现，不同步（省流量，也不影响判定）。
var _sync: MultiplayerSynchronizer
## 当前动画名（Idle / Walk）。远端角色靠它播动画 —— 本机不跑 AI/物理，
## 没法自己判断"在不在走"，不同步的话别人看到的就是"滑着走"。
var net_anim := "Idle"
## 主武器 id。房主需要知道客户端手里有什么枪，死亡时才能把对的那把掉在地上
## （客户端手里的武器只存在他自己那台机器上，房主那边是空的）。
var net_primary := ""
var _net_alive_prev := true


## 建好节点后调一次：设置 authority 并挂上同步器。
func setup_net(authority_id: int) -> void:
	set_multiplayer_authority(authority_id)
	if _sync != null:
		return
	_sync = MultiplayerSynchronizer.new()
	# ★ 名字必须写死 ★
	#   Godot 自动命名是 `@MultiplayerSynchronizer@770` 这种带进程内计数器的名字，
	#   两台机器上创建顺序稍有不同就会不一样 —— 而同步协议是**按节点路径**寻址的，
	#   路径对不上就报 `Node not found: "Main/Player_1/@MultiplayerSynchronizer@736"`，
	#   表现就是"两边都建了角色但位置永远不动"。
	_sync.name = "NetSync"
	var cfg := SceneReplicationConfig.new()
	for prop in ["position", "rotation", "health", "alive", "has_c4",
			"net_anim", "net_primary"]:
		var np := NodePath(".:" + prop)
		cfg.add_property(np)
		cfg.property_set_replication_mode(np, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_sync.replication_config = cfg
	_sync.set_multiplayer_authority(authority_id)
	add_child(_sync)


func _physics_process(delta: float) -> void:
	# ★ 联机时只模拟"自己拥有"的角色 ★
	#   别人的角色位置由 MultiplayerSynchronizer 写进来，本机不跑物理也不跑 AI
	#   （不然两台机器各算各的，位置会互相打架）。
	if not is_multiplayer_authority():
		return
	if is_bot or not alive:
		# 死亡：冻结在原地，不再施加重力/移动（防止尸体掉落地下）
		if not alive:
			velocity = Vector3.ZERO
			return
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y -= GRAVITY * delta
		move_and_slide()
		return
	_walking_slow = Input.is_action_pressed("walk")
	_update_speed()
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	_moving = dir.length() > 0.01
	velocity.x = dir.x * _speed
	velocity.z = dir.z * _speed

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY
		if _snd_jump: _snd_jump.play()

	set_crouch(Input.is_action_pressed("crouch"))
	move_and_slide()
	# 动画状态切换放在 move_and_slide 之后：is_on_floor() 才是本帧的最新值
	# （顺带把 net_anim 同步出去 —— 别人看到的你才不会"滑着走"）
	_try_play_anim("Walk" if (_moving and is_on_floor() and not _crouching) else "Idle")

	# 拉栓进度（栓动狙）：跑完自动清零，期间 fire() 会被 _bolt_until 挡住
	tick_bolt()

	# 手部晃动（走路摆、开枪后坐衰减）+ 换弹动作 + 拉栓动作 + 小刀挥砍 + 枪口火焰
	_kick = maxf(_kick - delta * 8.0, 0.0)
	_tick_muzzle_flash()
	# 小刀挥砍计时：与视模型解耦推进，保证伤害结算不依赖视模型是否存在
	if _knife_swing >= 0.0:
		_knife_swing += delta / maxf(_knife_total, 0.01)
		if not _knife_dmg_done and _knife_swing >= 0.42:
			_knife_dmg_done = true
			_resolve_knife_hit()
		if _knife_swing >= 1.0:
			_knife_swing = -1.0
	if _vm_root != null:
		var target_bob := 0.0
		if dir.length() > 0.01 and is_on_floor() and not _crouching:
			_bob += delta * 9.0
			target_bob = 0.012
		_bob = lerpf(_bob, target_bob, delta * 8.0)
		# 基础位姿：走路摆动 + 开枪后坐
		var vm_pos := Vector3(0.0, sin(_bob * 3.0) * 0.010 + _kick * 0.02, 0.0)
		var vm_rot := Vector3(-_kick * 0.10, 0.0, sin(_bob * 3.0) * 0.006)
		# 叠加换弹动作
		var rp := _reload_pose()
		vm_pos += rp[0]
		vm_rot += rp[1]
		# 叠加拉栓动作（栓动狙）
		var bp := _bolt_pose()
		vm_pos += bp[0]
		vm_rot += bp[1]
		# 叠加小刀挥砍
		var kp := _knife_pose()
		vm_pos += kp[0]
		vm_rot += kp[1]
		_vm_root.position = vm_pos
		_vm_root.rotation = vm_rot

	# 落地音效：随机音高，避免每次都一模一样
	if is_on_floor() and not _was_on_floor and _snd_land:
		_snd_land.pitch_scale = randf_range(0.9, 1.08)
		_snd_land.volume_db = linear_to_db(randf_range(0.5, 0.65))
		_snd_land.play()
	_was_on_floor = is_on_floor()

	# 脚步声：静步（Shift）与蹲下都完全无声，落地音效不受影响。
	# 玩家和 bot **共用** try_footstep()，所以 bot 走路也是听得见的
	# （之前 bot 移动完全无声：玩家听不到它靠近，bot 之间也互相听不到 —— 这是
	#   "听声辨位"根本无从谈起的原因之一）。
	try_footstep(delta, dir.length() > 0.01)

	if Input.is_action_just_pressed("reload"): reload()
	if Input.is_action_just_pressed("slot1"): _switch_slot(1)
	if Input.is_action_just_pressed("slot2"): _switch_slot(2)
	if Input.is_action_just_pressed("slot3"): _switch_slot(3)
	_auto_fire()

	# 换弹进度（供 HUD 进度条显示）
	if _reloading:
		_reload_timer += delta
		reload_progress = clampf(_reload_timer / maxf(_reload_total, 0.001), 0.0, 1.0)
		if _reload_timer >= _reload_total:
			_finish_reload()

	# 后坐力衰减：比"每秒累积量"慢，连发时散布才会持续变大
	_recoil = maxf(_recoil - delta * (RECOIL_DECAY_MOVE if _moving else RECOIL_DECAY_STILL), 0.0)
	# 摄像机后坐力偏移衰减（比散布回正快，方便快速重新瞄准）
	var old_rp := _recoil_pitch
	_recoil_pitch = maxf(_recoil_pitch - delta * (PITCH_DECAY_MOVE if _moving else PITCH_DECAY_STILL), 0.0)
	if not is_bot and _camera != null and _recoil_pitch != old_rp:
		_camera.rotation.x = head_pitch + _recoil_pitch

	# 本地玩家：准星对准其他玩家时显示其头顶名字（队友绿 / 敌人红）
	if not is_bot and alive:
		_update_name_tag()


# ---------------------------------------------------------------- 视模型程序化动作
# 武器模型没有骨骼，换弹/挥刀这些动作全部用「对 _vm_root 叠加位移与旋转」实现。
# 返回 [位移: Vector3, 旋转弧度: Vector3]，由 _process 叠加到基础位姿上。

# 换弹动作：枪身下沉 → 侧倾（退弹匣）→ 装匣顿挫 → 抬回上膛
func _reload_pose() -> Array:
	if not _reloading:
		return [Vector3.ZERO, Vector3.ZERO]
	var p := clampf(reload_progress, 0.0, 1.0)
	# 下沉曲线：0~18% 沉下去，18~62% 保持低位，62~88% 抬回
	var down := 0.0
	if p < 0.18:
		down = p / 0.18
	elif p < 0.62:
		down = 1.0
	elif p < 0.88:
		down = 1.0 - (p - 0.62) / 0.26
	down = clampf(down, 0.0, 1.0)
	var pos := Vector3(0.030 * down, -0.115 * down, 0.045 * down)
	var rot := Vector3(deg_to_rad(30.0) * down,
			deg_to_rad(-14.0) * down,
			deg_to_rad(24.0) * down)
	# 装匣瞬间的顿挫：60%~74% 之间短促抖一下，动作才有"咔哒"的实感
	if p > 0.60 and p < 0.74:
		var k := sin((p - 0.60) / 0.14 * PI)
		pos.y += k * 0.018
		rot.x -= deg_to_rad(9.0) * k
	# 拉栓上膛：86% 之后轻微前推
	if p > 0.86:
		var k2 := sin((p - 0.86) / 0.14 * PI)
		pos.z -= k2 * 0.014
		rot.x += deg_to_rad(6.0) * k2
	return [pos, rot]


# 拉栓动作（AWP / Scout）：枪身下沉后拉 → 顿挫推回上膛
func _bolt_pose() -> Array:
	if bolt_progress < 0.0:
		return [Vector3.ZERO, Vector3.ZERO]
	var p := clampf(bolt_progress, 0.0, 1.0)
	# 0~35% 后拉下沉，35~62% 保持低位，62~100% 推回
	var k := 0.0
	if p < 0.35:
		k = p / 0.35
	elif p < 0.62:
		k = 1.0
	else:
		k = 1.0 - (p - 0.62) / 0.38
	k = clampf(k, 0.0, 1.0)
	# 向右下后方沉（拉机柄在手右侧）
	var pos := Vector3(0.014 * k, -0.032 * k, 0.052 * k)
	var rot := Vector3(deg_to_rad(-7.0) * k, deg_to_rad(11.0) * k, deg_to_rad(-6.0) * k)
	# 推回上膛的顿挫：62%~78% 短促前推一下，动作才有"咔哒"的实感
	if p > 0.62 and p < 0.78:
		var j := sin((p - 0.62) / 0.16 * PI)
		pos.z -= j * 0.020
		rot.y -= deg_to_rad(13.0) * j
		rot.x += deg_to_rad(4.0) * j
	return [pos, rot]


# 小刀挥砍动作：抬刀蓄力 → 快速斜劈 → 收刀
func _knife_pose() -> Array:
	if _knife_swing < 0.0:
		return [Vector3.ZERO, Vector3.ZERO]
	var t := clampf(_knife_swing, 0.0, 1.0)
	# 0~30% 抬刀蓄力；30~60% 劈出；60~100% 收刀
	var lift := 0.0
	var slash := 0.0
	if t < 0.30:
		lift = t / 0.30
	elif t < 0.60:
		lift = 1.0 - (t - 0.30) / 0.30
		slash = (t - 0.30) / 0.30
	else:
		slash = 1.0 - (t - 0.60) / 0.40
	# 蓄力：刀抬向右上略后拉；劈出：向左下快速扫过
	var pos := Vector3(0.055 * lift - 0.080 * slash,
			-0.030 * lift - 0.080 * slash,
			0.070 * lift - 0.155 * slash)
	var rot := Vector3(deg_to_rad(-26.0) * lift + deg_to_rad(34.0) * slash,
			deg_to_rad(-18.0) * lift + deg_to_rad(22.0) * slash,
			deg_to_rad(-30.0) * lift + deg_to_rad(-38.0) * slash)
	return [pos, rot]


# 枪口的世界坐标（视模型枪口 _muzzle_local → 世界空间）。
# 枪口火焰、曳光起点都用它，保证特效从枪管末端发出而不是从画面中心冒出。
func _muzzle_world() -> Vector3:
	if _vm_root != null:
		return _vm_root.global_transform * _muzzle_local
	if _camera != null:
		return _camera.global_position - _camera.global_transform.basis.z * 0.8
	return global_position


# 从相机中心向前发射射线，命中玩家则显示其名字标签
func _update_name_tag() -> void:
	var cam: Camera3D = _camera
	if cam == null:
		return
	var space := get_world_3d().direct_space_state
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * 60.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	var target: CSPlayer = null
	if not hit.is_empty():
		var node: Node = hit.get("collider")
		while node != null and node != get_tree().root and not node.is_in_group("players"):
			node = node.get_parent()
		if node != null and node.is_in_group("players") and node != self:
			target = node
	for p in get_tree().get_nodes_in_group("players"):
		if p == self:
			continue
		p.set_name_tag_visible(target == p)


func set_name_tag_visible(on: bool) -> void:
	if _name_tag:
		_name_tag.visible = on


func _update_speed() -> void:
	_speed = RUN_SPEED * float(WEAPON_SPEED.get(_weapon_class(), 1.0))
	_apply_walk_slow()
	if _crouching:
		_speed *= CROUCH_MULT


# 当前手持武器的类型（knife / pistol / smg / shotgun / rifle / sniper / lmg）
func _weapon_class() -> String:
	return _weapon_class_of(get_current_id())


func _weapon_class_of(wid: String) -> String:
	var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
	spec = _effective_spec(wid, spec)
	return String(spec.get("class", "pistol"))


# 静步减速：蹲下时已经是最慢速度，不再二次叠加
func _apply_walk_slow() -> void:
	if _walking_slow and not _crouching:
		_speed *= WALK_SLOW_MULT


func get_current_id() -> String:
	var w: Dictionary = weapons.get(active_slot, {})
	return w.get("id", "Knife") if not w.is_empty() else "Knife"


# ------------------------------------------------------------------ 战斗
func fire() -> void:
	if _reloading or not alive: return
	# 仅购买菜单打开 / 主菜单 / 回合结束时不射击；购买阶段菜单关闭时可开火
	if GM != null and GM.buy_menu_visible: return
	if GM != null and (GM.state == GM.STATE.MENU or GM.state == GM.STATE.OVER): return
	var wid := get_current_id()
	if wid == "Knife":
		_fire_knife()
		return
	var wep: Dictionary = weapons.get(active_slot, {})
	if wep.is_empty(): return
	var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
	spec = _effective_spec(wid, spec)
	if spec.is_empty(): return
	if wep.get("mag", 0) <= 0:
		# 弹药打空自动开始装弹
		reload()
		return
	if _bolt_until > Time.get_ticks_msec() / 1000.0: return

	var now := Time.get_ticks_msec() / 1000.0
	var interval := 60.0 / float(spec.get("fire_rate", 400))
	if now < _next_fire: return
	_next_fire = now + interval

	var count: int = spec.get("burst_size", 1) if spec.get("burst", false) else 1
	var recoil_val := _recoil_add(spec)
	for i in range(count):
		if wep.get("mag", 0) <= 0: break
		# 先射击、**后**累加后坐力：
		#   这样每发子弹用的是"开火前"的散布，**第一发永远是准的**。
		#   （旧版先累加再射击，导致 AWP 开镜首发就被自己的后坐力顶偏 1.4°，
		#    再叠加随机散布，远距离必然打空 —— 这就是"开镜打不准"的根因。）
		_shoot_hitscan(wid, spec)
		wep["mag"] = wep.get("mag", 0) - 1
		_recoil = minf(_recoil + recoil_val, RECOIL_MAX)
		_kick = minf(_kick + 0.35, 1.0)
		if not is_bot and _camera != null:
			# 镜头后坐力同样在开火之后才叠加 → 只影响后续子弹的瞄准
			_recoil_pitch = minf(_recoil_pitch + recoil_val * PITCH_KICK, PITCH_MAX)
			_camera.rotation.x = head_pitch + _recoil_pitch
	ammo_changed.emit(wep.get("mag", 0), wep.get("reserve", 0))
	if spec.get("bolt", false):
		# 栓动狙：进入拉栓硬直（期间不能开火），并且**开枪瞬间自动退镜**。
		# 如果开枪前是开镜状态，拉栓结束会自动重新开镜（CF 手感），
		# 不用玩家自己再点一次右键。
		_bolt_until = Time.get_ticks_msec() / 1000.0 + BOLT_TIME
		bolt_progress = 0.0
		# 拉栓声：四段金属声，紧跟在枪声之后（真人也是打完立刻拉栓）
		if _snd_bolt:
			_snd_bolt.pitch_scale = randf_range(0.97, 1.04)
			_snd_bolt.play()
		if GM != null:
			GM.emit_noise(global_position, GM.NOISE_RADIUS_MECH, self)
		if not is_bot:
			_rescope_pending = _zoom
			_set_scope(false)


func _recoil_add(spec: Dictionary) -> float:
	# 全局后坐力系数（config.toml [weapons] recoil_multiplier）
	var mult := 1.0
	if ConfigManager.instance != null:
		mult = float(ConfigManager.instance.get_weapon_global("recoil_multiplier", 1.0))
	# 支持 config.toml [weapons] 中 recoil 属性覆盖
	if spec.has("recoil") and spec["recoil"] != null:
		return float(spec["recoil"]) * mult
	var c: String = spec.get("class", "pistol")
	match c:
		"rifle": return 0.021 * mult
		"sniper": return 0.026 * mult
		"lmg": return 0.032 * mult
		"smg": return 0.011 * mult
		"shotgun": return 0.035 * mult
		_: return 0.018 * mult


# 合并 config.toml [weapons] 的枪械属性覆盖，生成实际生效的属性表
func _effective_spec(wid: String, spec: Dictionary) -> Dictionary:
	if ConfigManager.instance == null:
		return spec
	var out := spec.duplicate()
	for k in ["damage", "fire_rate", "mag", "reserve", "armor_ratio", "head_mult", "move_penalty", "recoil", "price"]:
		var v: Variant = ConfigManager.instance.get_weapon_override(wid, k, null)
		if v != null:
			out[k] = v
	return out


func _shoot_hitscan(wid: String, spec: Dictionary) -> void:
	# 霰弹枪：一次打出多颗弹丸
	var pellets := int(spec.get("pellets", 1))
	for i in maxi(1, pellets):
		# with_sound 只给第 1 颗弹丸：霰弹一枪 8 颗，每颗都放一声会叠成 8 声
		_shoot_one_pellet(wid, spec, float(spec.get("spread", 0.0)), i == 0)
	_play_shot()
	_flash()


func _shoot_one_pellet(wid: String, spec: Dictionary, extra_spread: float,
		with_sound := false) -> void:
	if _camera == null: return
	var cam_basis := _camera.global_transform.basis
	var from := _camera.global_position
	var dir := -cam_basis.z
	# 散布：用相机右轴（水平）+ 世界上轴（垂直）构造散布平面
	# 这样散布在墙上始终是圆形，不受相机上跳倾斜影响
	# _recoil 越大子弹越飘（连发明显扩散）；第一发 _recoil=0 → 完全精准
	var spread := _recoil * RECOIL_SPREAD + extra_spread
	if _moving:
		spread += float(spec.get("move_penalty", 1.0)) * 0.012
	spread = minf(spread, 1.0)
	# 圆形均匀分布（随机角度 + sqrt 半径）
	var jitter_angle := randf() * TAU
	var jitter_r := sqrt(randf()) * spread
	var right := cam_basis.x  # 相机右轴 = 水平方向
	var up := Vector3.UP       # 世界上轴 = 垂直方向（不受相机倾斜影响）
	var jitter := right * cos(jitter_angle) * jitter_r + up * sin(jitter_angle) * jitter_r
	dir = (dir + jitter).normalized()
	var to := from + dir * 4000.0
	# 枪口起点：略微向前偏移（0.2m），避免被自身碰撞体挡住
	# 不能偏移太多（原 1.0m），否则近处目标在射线起点身后打不到
	var muzzle := from + dir * 0.2
	# 射线命中队友时跳过（子弹穿透队友，继续命中身后目标）
	var hit := _ray_ignore_teammates(muzzle, to)
	var end := to
	if not hit.is_empty():
		end = hit["position"]
		_apply_hit(hit, spec)
	else:
		# 打空（射向天空 / 无碰撞体的远处）：给曳光一个合理的飞行终点，
		# 否则会沿 4000m 的射线终点一路飞出去。30m 足够表现"子弹飞出去了"
		end = from + dir * 30.0

	# 子弹曳光：从视模型的真实枪口出发，沿真实弹道飞向命中点。
	# 枪口在画面右下方，曳光会自然向准星收敛。
	# 枪口离命中点太近时不画：短棒会反向，而且那么短的飞行也看不出来
	var visual_muzzle := _muzzle_world()
	if visual_muzzle.distance_to(end) > 0.6:
		_spawn_tracer(visual_muzzle, end)

	# 命中点特效：命中角色生成血溅，命中环境生成弹孔
	# （CS 打人没有弹孔，只有血溅；否则敌人倒下后弹孔会悬浮在空中）
	var hit_player := false
	if not hit.is_empty():
		var hit_obj: Object = hit.get("collider")
		if hit_obj is CSPlayer:
			hit_player = true
			_spawn_blood_spray(end, dir)
		else:
			_spawn_hitmarker(end, hit.get("normal", Vector3.UP))

	# ★ 联机：把这一发广播出去 ★ —— 别的机器据此重放枪口火光 / 曳光 / 血雾
	# （用 unreliable：特效丢一两条无所谓，不值得为它阻塞）
	if GM != null:
		GM.broadcast_shot(self, visual_muzzle, end, hit_player, end, dir, wid, with_sound)


# 射线逐段探测：命中队友时从命中点继续向前，子弹穿透队友命中其身后的目标
func _ray_ignore_teammates(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var start := from
	for i in 8:
		var q := PhysicsRayQueryParameters3D.create(start, to)
		q.collide_with_areas = true
		q.exclude = [self]
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return {}
		var obj: Object = hit.get("collider")
		if obj is CSPlayer and (obj as CSPlayer).team == team:
			# 队友：从命中点向前偏移一点继续探测
			var dir := (to - start).normalized()
			start = (hit["position"] as Vector3) + dir * 0.05
			continue
		return hit
	return {}


func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	# 曳光：屏幕空间的一段亮色短线，从枪口沿真实弹道飞向命中点
	# （观感参考 GTA 罪恶都市）
	#
	# 为什么用 2D 屏幕空间而不是 3D 短棒：
	# 第一人称下弹道几乎与视线平行，3D 短棒投影到屏幕上只剩几个像素，
	# 飞起来就是一个几乎看不见的小点 —— 物理上正确，但完全看不出弹道。
	# 屏幕空间画线不受透视缩短影响，始终能看清"一条线从枪口射向命中点"。
	#
	# 位置严格按真实弹道两端点的屏幕投影插值，不做任何额外拉伸，
	# 所以弹头屏幕位置始终对应子弹的真实位置。
	#
	# 参数可在 config.toml [effects] 中微调
	if _tracer_layer == null or _camera == null:
		return
	if from.distance_to(to) < 0.6:
		return
	var speed := 150.0
	var fade := 0.06
	var wpx := 3.0
	var col := Color(1.0, 0.90, 0.55)
	if ConfigManager.instance != null:
		speed = float(ConfigManager.instance.get_effect("tracer_speed", 150.0))
		fade = float(ConfigManager.instance.get_effect("tracer_lifetime", 0.06))
		wpx = float(ConfigManager.instance.get_effect("tracer_width_px", 3.0))
		var cv: Variant = ConfigManager.instance.get_effect("tracer_color", [255, 230, 140])
		if cv is Color:
			col = cv
		elif cv is Array and cv.size() >= 3:
			# 配置里是 0~255，转成 Godot 用的 0.0~1.0
			col = Color(float(cv[0]) / 255.0, float(cv[1]) / 255.0, float(cv[2]) / 255.0)

	var tr := Tracer2D.new()
	# 起点：此刻枪口的屏幕坐标，生成后锁定不再变。
	# 视模型挂在相机下，枪口屏幕位置本来就基本恒定；
	# 若改成每帧把固定世界坐标重新投影，相机侧移时这个近处点会横扫屏幕。
	tr.a = _camera.unproject_position(from)
	# 终点：命中点的世界坐标，每帧重新投影，视角转动时它会跟着动
	tr.to_world = to
	tr.camera = _camera
	tr.color = col
	tr.width_px = wpx
	# 速度按约 150 m/s 估算 —— 比真实子弹慢得多，这是有意的：
	# 真实子弹 38 米只飞 0.05 秒，一帧就过去了，屏幕上什么都看不到。
	# 夹在 70~220ms，保证任何距离都能看清飞行过程。
	tr.duration = clampf(from.distance_to(to) / speed, 0.07, 0.22)
	tr.fade_time = maxf(fade, 0.02)
	_tracer_layer.add_child(tr)


## 世界空间 3D 曳光 —— **专给 bot 用**。
##
## 为什么 bot 不能用上面那套屏幕空间曳光（_spawn_tracer）：
## 那套是给"本地玩家"画的，挂在**每个角色自己的 CanvasLayer** 上。
## CanvasLayer 是屏幕空间图层 —— 它不看"谁是当前相机"，只要节点存在就画到屏幕上。
## 而它的屏幕坐标是按**该角色自己的相机** unproject 出来的，
## 所以 8 个 bot 各自把弹道投成一堆毫无意义的屏幕坐标，全叠在玩家视野里 →
## 就是玩家看到的"子弹乱飞"（而且 bot 越多越乱）。
##
## 3D 短棒只在"真的看向它"时才可见，位置严格对应真实弹道，也不占用屏幕图层。
## 网格/材质全局共享，每次开火零资源分配。
static var _tracer3d_mesh: BoxMesh
static var _tracer3d_mat: StandardMaterial3D

static func _tracer3d_mesh_get() -> BoxMesh:
	if _tracer3d_mesh == null:
		_tracer3d_mesh = BoxMesh.new()
		# 单位长度沿 -Z（Godot 前向），截面很细；长度靠实例 scale.z 拉伸
		_tracer3d_mesh.size = Vector3(0.035, 0.035, 1.0)
	return _tracer3d_mesh

static func _tracer3d_mat_get() -> StandardMaterial3D:
	if _tracer3d_mat == null:
		_tracer3d_mat = StandardMaterial3D.new()
		_tracer3d_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tracer3d_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# 用普通 alpha 混合而不是加性混合：加性在浅色石头/地面上会"越加越白"，
		# 曳光直接看不见（地图整体偏亮的米黄石材）。普通混合在任何底色上都看得清。
		_tracer3d_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		_tracer3d_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_tracer3d_mat.albedo_color = Color(1.0, 0.85, 0.35, 1.0)
	return _tracer3d_mat


func _spawn_tracer_3d(from: Vector3, to: Vector3) -> void:
	var dist := from.distance_to(to)
	if dist < 0.6:
		return
	var t := MeshInstance3D.new()
	t.mesh = _tracer3d_mesh_get()
	t.material_override = _tracer3d_mat_get()
	t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(t)   # 先入树，再设全局变换（见 _spawn_blood_spray 的注释）
	t.global_position = from
	var dir := (to - from).normalized()
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT
	t.look_at(to, up)
	# 可见短段长度：太长会像激光，太短看不清
	t.scale = Vector3(1.0, 1.0, clampf(dist * 0.35, 1.0, 5.0))
	# 弹头从枪口飞到命中点；3D 短棒不需要像屏幕空间那样放慢到 0.07~0.22s
	var dur := clampf(dist / 260.0, 0.03, 0.10)
	var tw := create_tween()
	tw.tween_property(t, "global_position", to, dur).set_trans(Tween.TRANS_LINEAR)
	tw.parallel().tween_property(t, "transparency", 1.0, dur)
	tw.tween_callback(t.queue_free)


# ---------------------------------------------------------------- 远端开火特效
# 别人开枪时在本机重放：枪口火光 + 曳光 + 血雾。
# 不同步的话，别人只看到你"原地抖一下"，完全看不出你在开枪。
static var _rm_flash_tex: Texture2D = null


static func _rm_flash_texture() -> Texture2D:
	if _rm_flash_tex != null:
		return _rm_flash_tex
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := Vector2(s * 0.5, s * 0.5)
	for y in s:
		for x in s:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / (s * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 0.92, 0.72, a * a))
	_rm_flash_tex = ImageTexture.create_from_image(img)
	return _rm_flash_tex


## 世界空间枪口火光（本机自己的走 _flash()，那个是挂在视模型上的，别人看不到）
func _remote_muzzle_flash(from: Vector3) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.5, 0.5)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = _rm_flash_texture()
	mat.albedo_color = Color(1.0, 0.9, 0.6, 1.0)
	mat.disable_receive_shadows = true
	var m := MeshInstance3D.new()
	m.mesh = quad
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(m)      # 先入树，再设全局变换
	m.global_position = from
	var sc := randf_range(0.8, 1.3)
	m.scale = Vector3(sc, sc, sc)
	# 补间挂在特效节点自己身上：角色被回收时特效也不会漏在场上
	var tw := m.create_tween()
	tw.tween_property(m, "transparency", 1.0, 0.07)
	tw.tween_callback(m.queue_free)
	# 一束短光，让火光真的"照到"周围
	var li := OmniLight3D.new()
	li.light_color = Color(1.0, 0.85, 0.55)
	li.omni_range = 6.0
	li.light_energy = 2.6
	get_tree().current_scene.add_child(li)
	li.global_position = from
	var tw2 := li.create_tween()
	tw2.tween_property(li, "light_energy", 0.0, 0.08)
	tw2.tween_callback(li.queue_free)


## 本机一共重放了多少次"别人的开火特效"（自检用，确认广播真的到了）
static var remote_fx_count := 0


## 别的机器开火 → 在本机重放特效（由 GM 的 _net_shot 调用）
func remote_shot_fx(from: Vector3, to: Vector3, hit: bool,
		hit_pos: Vector3, hit_dir: Vector3, wid: String, with_sound: bool) -> void:
	remote_fx_count += 1
	_remote_muzzle_flash(from)
	if from.distance_to(to) > 0.6:
		_spawn_tracer_3d(from, to)
	if hit:
		_spawn_blood_spray(hit_pos, hit_dir)
	# 枪声（只在一发霰弹的第 1 颗弹丸上放一次，否则 8 颗弹丸会叠成 8 声）
	# 走 AudioStreamPlayer3D → 带距离衰减和方位，听声辨位才成立；
	# 顺带 emit_noise，房主那边的 bot 才能"听到"客户端开枪。
	if with_sound:
		_play_shot(wid)


## CF 风格弹孔纹理：黑心（洞）+ 灰色粉末环 + 尘土外环 + 不规则边缘
## 只生成一次并复用，避免每发子弹新建纹理
var _bullet_hole_tex: Texture2D = null
func _bullet_hole_texture() -> Texture2D:
	if _bullet_hole_tex != null: return _bullet_hole_tex
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size * 0.5, size * 0.5)
	var hole_r := size * 0.16    # 黑心半径（弹孔本体）
	var powder_r := size * 0.34  # 粉末环外径（被擦过的粉末化材质）
	var dust_r := size * 0.48    # 尘土外径（冲击扬尘，渐透明）
	for y in size:
		for x in size:
			var px := Vector2(x + 0.5, y + 0.5)
			var d := px.distance_to(center)
			# 不规则边缘：用多频率 sin 波动让圆变形，避免完美圆形（CF 弹孔边缘是锯齿的）
			var angle := atan2(px.y - center.y, px.x - center.x)
			var wobble := sin(angle * 5.0) * 2.5 + sin(angle * 9.0) * 1.5 + sin(angle * 13.0) * 1.0
			if d < hole_r + wobble:
				# 黑心：弹孔本体（接近纯黑）
				img.set_pixel(x, y, Color(0.02, 0.02, 0.03, 1.0))
			elif d < powder_r + wobble * 1.5:
				# 粉末环：从黑到灰渐变（弹头擦过墙面的粉末化区域）
				var t := (d - hole_r) / (powder_r - hole_r)
				var v := lerpf(0.05, 0.42, t)
				img.set_pixel(x, y, Color(v, v, v * 1.08, 1.0))
			elif d < dust_r:
				# 尘土外环：从灰到透明（冲击扬尘，越远越淡）
				var t := (d - powder_r) / (dust_r - powder_r)
				var a := (1.0 - t) * 0.55
				img.set_pixel(x, y, Color(0.28, 0.26, 0.24, a))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	_bullet_hole_tex = ImageTexture.create_from_image(img)
	return _bullet_hole_tex


## 血雾 Shader（全局缓存）
## 用程序化"血滴云"贴图 + **普通 alpha 混合**，而不是加性混合的纯色圆盘：
##   · 加性混合在浅色石头/地面上会越加越白，看着就是一团发光红球 → "很假"；
##   · 纯径向渐变太规整，改成不规则血滴云后才有"血被雾化喷出来"的颗粒感。
## ★ 注意：**绝不能**写 `depth_test_disabled` ★
##   写了它血雾会画在所有几何体之上 —— 隔着围墙/掩体也能看到血雾（用户报的"穿墙"）。
static var _blood_shader: Shader = null
static func _get_blood_shader() -> Shader:
	if _blood_shader != null:
		return _blood_shader
	_blood_shader = Shader.new()
	_blood_shader.code = """shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
uniform sampler2D splat : filter_linear, repeat_disable;
uniform vec4 blood_color : source_color = vec4(0.55, 0.04, 0.04, 1.0);
uniform float alpha = 1.0;
void fragment() {
	// 贴图里 R = 浓度（中心实、边缘稀），A = 覆盖度
	vec4 t = texture(splat, UV);
	// 越浓越暗（血厚的地方偏暗红），越稀越亮（薄雾偏亮红）
	vec3 rgb = blood_color.rgb * mix(1.25, 0.65, t.r);
	ALBEDO = rgb;
	ALPHA = t.a * alpha;
}
"""
	return _blood_shader


## 程序化血滴云贴图（128²，只生成一次）：
## 中心几团重叠的大软团 + 外围 20 多颗飞散小血滴，取"最浓的一团"做覆盖度，
## 避免简单相加变成一整片死红。**纯代码生成，不消耗任何生图额度。**
static var _blood_splat_tex: ImageTexture = null
static func _blood_splat_texture() -> ImageTexture:
	if _blood_splat_tex != null:
		return _blood_splat_tex
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260930   # 固定种子：贴图只生成一次，每次运行外观一致
	var center := Vector2(size * 0.5, size * 0.5)
	var blobs: Array = []
	# 中心主团：5 个重叠大软团
	for i in 5:
		var a := rng.randf() * TAU
		var rr := rng.randf() * size * 0.10
		blobs.append({"c": center + Vector2(cos(a), sin(a)) * rr,
				"r": size * rng.randf_range(0.16, 0.26), "w": rng.randf_range(0.60, 1.0)})
	# 外围飞散小血滴：24 颗
	for i in 24:
		var a := rng.randf() * TAU
		var rr := size * rng.randf_range(0.14, 0.47)
		blobs.append({"c": center + Vector2(cos(a), sin(a)) * rr,
				"r": size * rng.randf_range(0.014, 0.055), "w": rng.randf_range(0.30, 0.95)})
	for y in size:
		for x in size:
			var px := Vector2(x + 0.5, y + 0.5)
			var cov := 0.0   # 覆盖度
			var den := 0.0   # 浓度（中心更实）
			for b in blobs:
				var d := px.distance_to(b["c"])
				var r: float = b["r"]
				if d >= r:
					continue
				var t := 1.0 - d / r
				var w: float = b["w"]
				cov = maxf(cov, smoothstep(0.0, 1.0, t) * w)
				den = maxf(den, smoothstep(0.30, 0.92, t) * w)
			if cov <= 0.002:
				continue
			img.set_pixel(x, y, Color(den, den, den, clampf(cov, 0.0, 1.0)))
	_blood_splat_tex = ImageTexture.create_from_image(img)
	return _blood_splat_tex


## 血雾材质（按颜色缓存，全局共享；淡出走 MeshInstance3D.transparency）
static var _blood_mist_mat: ShaderMaterial = null
static var _blood_mist_mat_col := Color(0, 0, 0, 0)
static func _blood_mist_mat_get(col: Color) -> ShaderMaterial:
	if _blood_mist_mat == null or _blood_mist_mat_col != col:
		var m := ShaderMaterial.new()
		m.shader = _get_blood_shader()
		m.set_shader_parameter("splat", _blood_splat_texture())
		# 真血雾偏暗红，直接拿配置里的鲜红会显得像番茄酱
		m.set_shader_parameter("blood_color", col.darkened(0.25))
		m.set_shader_parameter("alpha", 1.0)
		m.render_priority = 10
		_blood_mist_mat = m
		_blood_mist_mat_col = col
	return _blood_mist_mat


## 血溅用到的网格/材质全部做成**全局共享**：
## 旧版每颗血滴都 new 一个 SphereMesh 再改 radius，等于每命中一次就重建 8 份
## 球体顶点数据（Godot 默认 64×32 段，单颗上千面）+ 8 份材质 —— 8 个 bot 一起开火时
## 每秒几百次网格重建，是真正的内存/CPU 瓶颈。改成"单位球 + scale 控制大小"后，
## 每次命中只 new 8 个轻量 MeshInstance3D，网格和材质零分配。
static var _blood_mist_mesh: PlaneMesh
static var _blood_drop_mesh: SphereMesh
static var _blood_drop_mat: StandardMaterial3D
static var _blood_drop_mat_col := Color(0, 0, 0, 0)

static func _blood_mist_mesh_get() -> PlaneMesh:
	if _blood_mist_mesh == null:
		_blood_mist_mesh = PlaneMesh.new()
		_blood_mist_mesh.orientation = PlaneMesh.FACE_Z
		_blood_mist_mesh.size = Vector2(0.7, 0.7)
	return _blood_mist_mesh

static func _blood_drop_mesh_get() -> SphereMesh:
	if _blood_drop_mesh == null:
		# 单位球：半径 0.5 → 直径 1，血滴直径直接用 scale 表达。
		# 分段数压到 8×4（默认 64×32）——血滴只有几厘米大，看不出差别。
		_blood_drop_mesh = SphereMesh.new()
		_blood_drop_mesh.radius = 0.5
		_blood_drop_mesh.height = 1.0
		_blood_drop_mesh.radial_segments = 8
		_blood_drop_mesh.rings = 4
	return _blood_drop_mesh

static func _blood_drop_mat_get(col: Color) -> StandardMaterial3D:
	if _blood_drop_mat == null or _blood_drop_mat_col != col:
		var m := StandardMaterial3D.new()
		# 血滴偏暗红：原来的 emission 1.5 会让血滴变成"发光的小红灯泡"，很假
		m.albedo_color = col.darkened(0.2)
		m.emission_enabled = true
		m.emission = col * 0.35
		m.emission_energy_multiplier = 0.45
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# 开 alpha 透明：淡出改用 MeshInstance3D.transparency（材质共享后不能再动画材质参数）
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_blood_drop_mat = m
		_blood_drop_mat_col = col
	return _blood_drop_mat


# 血溅特效：命中角色时生成血雾光晕 + 飞散血滴
# pos=命中点, shot_dir=子弹飞行方向（血溅沿此方向继续喷射，符合物理）
func _spawn_blood_spray(pos: Vector3, shot_dir: Vector3) -> void:
	var col := Color(200.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0)
	var lt: float = 0.45
	if ConfigManager.instance != null:
		var cv: Variant = ConfigManager.instance.get_effect("blood_color", [200, 20, 20])
		if cv is Color:
			col = cv
		elif cv is Array and cv.size() >= 3:
			col = Color(float(cv[0]) / 255.0, float(cv[1]) / 255.0, float(cv[2]) / 255.0)
		lt = float(ConfigManager.instance.get_effect("blood_lifetime", 0.45))

	# --- 血雾：3 团程序化"血滴云"，朝相机，快速扩散+淡出 ---
	var cam: Camera3D = get_viewport().get_camera_3d()
	# 朝向相机的方向。注意：命中本地玩家头部时 pos 恰好等于相机位置
	# （bot 爆头瞄 y+1.55，正好等于 EYE_HEIGHT=1.55），差向量为零，
	# look_at 会报 "origin and target are in the same position" 并每命中刷一条。
	# 这里退化成"朝后"的固定方向。
	var to_cam := Vector3.BACK
	if cam != null:
		var dc := cam.global_position - pos
		if dc.length() > 0.05:
			to_cam = dc.normalized()
	# 相机几乎在正上方时 to_cam ≈ UP，look_at 的 up 向量不能与之平行，换一个
	var mist_up := Vector3.RIGHT if absf(to_cam.dot(Vector3.UP)) > 0.99 else Vector3.UP
	# 网格 + 材质都是全局共享的（见 _blood_mist_mesh_get / _blood_mist_mat_get），
	# 每团只 new 一个 MeshInstance3D，淡出走实例的 transparency → 零资源分配。
	var mist_mesh := _blood_mist_mesh_get()
	var mist_mat := _blood_mist_mat_get(col)
	for i in 3:
		var mist := MeshInstance3D.new()
		mist.mesh = mist_mesh
		mist.material_override = mist_mat
		mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mist.extra_cull_margin = 1.0   # 贴片很小，放宽裁剪边界避免边缘被剔掉
		# ★ 必须先 add_child 再设 global_position / look_at ★
		# 节点不在场景树里时 Node3D 拿不到全局变换，会刷
		#   "Condition !is_inside_tree() is true. Returning: Transform3D()"
		# 而且位置直接被丢弃（血雾/血滴全跑到世界原点）。
		get_tree().current_scene.add_child(mist)
		# 三团各自错开一点，避免完全重合看起来像一张贴纸
		mist.global_position = pos + shot_dir * randf_range(-0.05, 0.16) \
				+ Vector3(randf_range(-0.13, 0.13), randf_range(-0.13, 0.13), randf_range(-0.13, 0.13))
		mist.look_at(mist.global_position + to_cam, mist_up)
		# 每团随机绕视线自转，避免三团纹理完全重影
		mist.rotate_object_local(Vector3.FORWARD, randf() * TAU)
		var s0 := randf_range(0.42, 0.66)
		var s1 := s0 * randf_range(1.7, 2.4)
		mist.scale = Vector3(s0, s0, s0)
		var lt_i := lt * randf_range(0.80, 1.15)
		var mist_tw := create_tween()
		mist_tw.tween_property(mist, "scale", Vector3(s1, s1, s1), lt_i * 0.8) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		mist_tw.parallel().tween_property(mist, "transparency", 1.0, lt_i) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		mist_tw.tween_callback(mist.queue_free)

	# --- 飞散血滴：8 个红色小球，沿子弹方向喷射+随机扩散+重力下落 ---
	var drop_mesh := _blood_drop_mesh_get()
	var drop_mat := _blood_drop_mat_get(col)
	var g := Vector3.DOWN * 4.0
	for i in 8:
		var drop := MeshInstance3D.new()
		drop.mesh = drop_mesh
		drop.material_override = drop_mat
		drop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().current_scene.add_child(drop)
		# 血滴直径 0.03~0.08m（单位球直径 1，scale 即直径）
		var r0 := randf_range(0.03, 0.08)
		drop.global_position = pos
		drop.scale = Vector3(r0, r0, r0)
		# 初速度：沿子弹方向（主方向）+ 球面随机扰动（向四面八方飞溅）
		var vel := shot_dir * randf_range(2.0, 4.5) \
			+ Vector3(randf_range(-2.0, 2.0), randf_range(-1.0, 2.5), randf_range(-2.0, 2.0))
		# 重力下落：终点位置 = 起点 + 速度*时间 + 0.5*g*t^2（抛物线）
		var end_pos := pos + vel * lt + g * lt * lt * 0.5
		var drop_tw := create_tween()
		# 用 ease 模拟抛物线：前半段 ease_out（快速飞出），后半段 ease_in（下落加速）
		drop_tw.tween_property(drop, "global_position", end_pos, lt) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		# 末段缩小+淡出（材质共享，淡出走实例的 transparency）
		drop_tw.parallel().tween_property(drop, "transparency", 1.0, lt * 0.5) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		drop_tw.parallel().tween_property(drop, "scale", Vector3(r0 * 0.2, r0 * 0.2, r0 * 0.2), lt * 0.5) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		drop_tw.tween_callback(drop.queue_free)


## wid 留空 = 用本机当前手里的枪。远端角色本机武器表是空的，所以由广播把枪 id 传进来。
func _play_shot(wid := "") -> void:
	if _snd_shot == null:
		return
	if wid == "":
		wid = get_current_id()
	# 两层叠加：真实录音 shoot.wav（按该武器的音高走调）+ 合成层（低频枪身/尾音）
	var voice := SoundFXScript.gun_voice(wid, _weapon_class_of(wid))
	_snd_shot.pitch_scale = float(voice["pitch"]) * randf_range(0.97, 1.03)
	_snd_shot.play()
	if _snd_shot_layer != null:
		_snd_shot_layer.stream = voice["layer"]
		_snd_shot_layer.pitch_scale = randf_range(0.97, 1.03)
		_snd_shot_layer.play()
	# 枪声是最响的噪声事件：很远处的 bot 也会被吸引过来查看
	if GM != null:
		GM.emit_noise(global_position, GM.NOISE_RADIUS_SHOT, self)


func _spawn_hitmarker(pos: Vector3, normal: Vector3) -> void:
	# CF 风格弹孔：贴墙平面 + 程序化纹理（黑心+粉末环+尘土+不规则边缘）
	# 参数可在 config.toml [effects] 中微调
	var r: float = 0.05
	var col_r := 15.0 / 255.0
	var col_g := 15.0 / 255.0
	var col_b := 18.0 / 255.0
	if ConfigManager.instance != null:
		r = float(ConfigManager.instance.get_effect("hitmarker_radius", 0.05))
		var c: Variant = ConfigManager.instance.get_effect("hitmarker_color", [15, 15, 18])
		if c is Color:
			col_r = c.r
			col_g = c.g
			col_b = c.b
		elif c is Array and c.size() >= 3:
			# 配置里是 0~255，转成 Godot 用的 0.0~1.0
			col_r = float(c[0]) / 255.0
			col_g = float(c[1]) / 255.0
			col_b = float(c[2]) / 255.0
	var n := normal.normalized() if normal.length() > 0.01 else Vector3.UP

	# 弹孔平面：PlaneMesh + 纹理材质（与曳光同类方案，已验证可靠显示）
	var hole := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.orientation = PlaneMesh.FACE_Z
	# 大小=半径×2（直径），含外环尘土
	mesh.size = Vector2(r * 2.0, r * 2.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _bullet_hole_texture()
	# 纹理自带灰度渐变，配置色与白色混合做轻微偏色（纯用配置色太暗看不见）
	mat.albedo_color = Color(col_r, col_g, col_b, 1.0).lerp(Color.WHITE, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.flags_unshaded = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mesh.material = mat
	hole.mesh = mesh
	# 略微离开墙面（1cm），避免与墙 z-fighting 闪烁
	hole.position = pos + n * 0.01

	# 朝向：平面法线(Z) = 墙面法线
	var up := Vector3.UP
	if absf(n.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var b := Basis()
	b.z = n
	b.x = up.cross(n).normalized()
	b.y = n.cross(b.x).normalized()
	hole.transform.basis = b
	# 绕法线随机旋转，配合纹理不规则边缘，让每个弹孔朝向不同
	hole.rotate_object_local(Vector3.FORWARD, randf_range(0.0, TAU))
	get_tree().current_scene.add_child(hole)

	# 8 秒后淡出 2 秒消失
	var tw := create_tween()
	tw.tween_interval(8.0)
	tw.tween_property(mat, "albedo_color:a", 0.0, 2.0) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): hole.queue_free())


func _apply_hit(hit: Dictionary, spec: Dictionary) -> void:
	var target: Object = hit.get("collider")
	if target is CSPlayer and target != self:
		var p: CSPlayer = target as CSPlayer
		if p.team == self.team: return
		var local: Vector3 = p.to_local(hit["position"])
		var is_head := local.y > HEAD_LINE
		p.apply_damage(spec, self, is_head)


func _fire_knife() -> void:
	# 只负责"起手"：挥砍动作 + 破空声。
	# 伤害在挥到位的瞬间（_knife_swing 越过 0.42）由 _resolve_knife_hit 结算，
	# 这样打击感和动作对得上，而不是一按就出伤害。
	if _knife_swing >= 0.0:
		return  # 上一次挥砍还没结束
	_knife_swing = 0.0
	_knife_dmg_done = false
	_knife_total = 0.36
	if _snd_knife_swing != null:
		_snd_knife_swing.pitch_scale = randf_range(0.94, 1.08)
		_snd_knife_swing.play()


# 挥砍到位的那一帧结算：优先命中玩家，没打到人就找墙面留划痕
func _resolve_knife_hit() -> void:
	# 1) 面前 2.2m 内的敌人
	var hit_player := false
	for t in get_tree().get_nodes_in_group("players"):
		if t == self or not t.alive: continue
		if t.team == self.team: continue
		if global_position.distance_to(t.global_position) > 2.2: continue
		t.apply_damage({"damage": 65.0, "head_mult": 4.0, "armor_ratio": 0.7}, self, false)
		hit_player = true
	if hit_player:
		if _snd_knife_hit != null:
			_snd_knife_hit.pitch_scale = randf_range(0.92, 1.06)
			_snd_knife_hit.play()
		return

	# 2) 没打到人 → 向前射线找硬表面，留划痕 + 刮擦声
	if _camera == null:
		return
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2.6)
	q.exclude = [get_rid()]
	q.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	if hit.get("collider") is CSPlayer:
		return
	_spawn_knife_scratch(hit["position"], hit.get("normal", Vector3.UP), dir)
	if _snd_knife_wall != null:
		_snd_knife_wall.pitch_scale = randf_range(0.90, 1.12)
		_snd_knife_wall.play()


# 刀划墙面：贴一组划痕（复用弹孔的平面贴花方案，保证各角度都能看到）
func _spawn_knife_scratch(pos: Vector3, normal: Vector3, look_dir: Vector3) -> void:
	var n := normal.normalized() if normal.length() > 0.01 else Vector3.UP
	var sc := 0.32
	var s := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.orientation = PlaneMesh.FACE_Z
	mesh.size = Vector2(sc, sc)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _knife_scratch_texture()
	# 纹理自带「深色芯 + 亮色边」，这里用白色做中性染色：
	# 芯比墙暗、边比墙亮，所以在浅色墙和深色墙上都能看出来
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.flags_unshaded = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mesh.material = mat
	s.mesh = mesh
	# 略微离开墙面（8mm），避免与墙 z-fighting 闪烁
	s.position = pos + n * 0.008
	var up := Vector3.UP
	if absf(n.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var b := Basis()
	b.z = n
	b.x = up.cross(n).normalized()
	b.y = n.cross(b.x).normalized()
	s.transform.basis = b
	# 刀痕是「劈」出来的斜痕，不是沿着视线方向的直线：
	# 给一个随机的斜角（-70°~-25°），再加一点随机抖动，避免每条都一模一样
	s.rotate_object_local(Vector3.FORWARD, randf_range(deg_to_rad(-70.0), deg_to_rad(-25.0)))
	s.rotate_object_local(Vector3.FORWARD, randf_range(-0.16, 0.16))
	get_tree().current_scene.add_child(s)
	# 12 秒后淡出消失
	var tw := create_tween()
	tw.tween_interval(12.0)
	tw.tween_property(mat, "albedo_color:a", 0.0, 2.5) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): s.queue_free())


## 小刀划痕纹理：一条主痕 + 两条副痕
## 每条 = 深色芯（被刀削出的沟）+ 亮色边（削掉的表层），这样在浅色墙和深色墙上都看得见
## 只生成一次并复用
func _knife_scratch_texture() -> Texture2D:
	if _scratch_tex != null:
		return _scratch_tex
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# v=纵向位置, w=半宽, u0/u1=起止横向范围, k=整体强度（副痕比主痕淡）
	var lines := [
		{"v": 0.50, "w": 0.045, "u0": 0.05, "u1": 0.95, "k": 1.0},
		{"v": 0.63, "w": 0.020, "u0": 0.22, "u1": 0.80, "k": 0.62},
	]
	for y in size:
		var v := float(y) / float(size)
		for x in size:
			var u := float(x) / float(size)
			var core := 0.0
			var edge := 0.0
			for i in range(lines.size()):
				var L: Dictionary = lines[i]
				# 位置带低频抖动，看起来像手划的、不是机器刻的
				var wob := sin(u * 7.0 + float(i) * 2.1) * 0.014 \
						+ sin(u * 19.0 + float(i) * 1.3) * 0.005
				var d := absf(v - (float(L["v"]) + wob))
				var w := float(L["w"])
				var k := float(L["k"])
				# 首尾淡出，避免划痕两端是硬切口
				var span := smoothstep(float(L["u0"]), float(L["u0"]) + 0.09, u) \
						* smoothstep(float(L["u1"]), float(L["u1"]) - 0.09, u)
				if span <= 0.0:
					continue
				# 深芯要够宽 —— 太细会被线性过滤糊掉，整条划痕只剩亮边、看起来像白漆
				core = maxf(core, (1.0 - smoothstep(w * 0.72, w, d)) * span * k)
				# 亮边只做一圈窄边：太宽会在深色墙上变成一条白漆
				edge = maxf(edge, (1.0 - smoothstep(w, w * 1.35, d)) * span * k)
			# 芯 → 深色（削出的沟）；边 → 亮色（削掉的表层）；两者之外透明
			var a := maxf(core, edge * 0.55)
			var val := 0.16 if core >= edge else 0.94
			img.set_pixel(x, y, Color(val, val, val, a))
	_scratch_tex = ImageTexture.create_from_image(img)
	return _scratch_tex


func apply_damage(spec: Dictionary, attacker: CSPlayer, head: bool) -> float:
	if not alive: return 0.0
	# ★ 联机时伤害统一交给房主结算 ★
	#   客户端自己扣血只改本地，下一帧就被同步覆盖回去 —— 表现就是"打不死人"。
	#   所以客户端只上报"谁打谁、用什么枪、是不是爆头"，扣血/死亡/加分都在房主那边算。
	if GM != null and GM.net_is_client():
		GM.report_damage(self, str(spec.get("id", "")), head, attacker)
		return 0.0
	if _snd_hurt:
		_snd_hurt.pitch_scale = randf_range(0.9, 1.2)
		_snd_hurt.play()
	var dmg := float(spec["damage"])
	if head:
		dmg *= float(spec.get("head_mult", 4.0))
	var ratio := float(spec.get("armor_ratio", 0.7))
	var actual := dmg
	if armor > 0.0:
		if head and has_helmet and spec.get("high_pen", false):
			pass
		else:
			var absorbed := minf(armor, dmg * (1.0 - ratio) * 0.6)
			armor -= absorbed
			actual = maxf(dmg * ratio, 1.0)
	health -= actual
	if health <= 0.0 and alive:
		health = 0.0
		_die(attacker if attacker != null else self, head)
	return actual


func shoot_via_bot(spec: Dictionary, attacker: CSPlayer) -> void:
	# 由 bot 脚本直接调用，以命中概率结算
	var di := attacker.global_position.distance_to(global_position)
	var acc := 0.85 if di < 25.0 else 0.45
	if randf() < acc:
		apply_damage(spec, attacker, randf() < 0.2)


func _die(attacker: CSPlayer, head: bool) -> void:
	deaths += 1
	alive = false
	velocity = Vector3.ZERO
	# 死亡立即中断换弹/拉栓，避免 HUD 进度条卡住
	_reloading = false
	reload_progress = -1.0
	_bolt_until = 0.0
	bolt_progress = -1.0
	_rescope_pending = false
	# 隐藏第一人称武器，避免尸体倒地后枪还悬在空中
	if _vm_root:
		_vm_root.visible = false
	# 死亡立即收起狙击镜遮罩（crosshair 状态交给主逻辑处理）
	_zoom = false
	if _scope_layer:
		_scope_layer.visible = false
	if head:
		headshots += 1
	if _name_tag:
		_name_tag.visible = false
	# 带上击杀者当时手持的武器 id，供右上角信息流显示枪械图案
	var kill_wid := attacker.get_current_id() if attacker != null else ""
	died.emit(self, attacker, head, kill_wid)
	if attacker != self:
		attacker.kills += 1
	if has_c4:
		has_c4 = false
		GM.on_c4_dropped(self)
	# 死亡立即倒地（不再延迟 2 秒）
	_lay_down()

## 蹲下 / 站起（玩家走输入，bot 走 AI 的走位决策）。
## 三个效果一起生效，缺一不可：
##   · 碰撞胶囊变矮 → 上半身不再被子弹打中（蹲下的实际收益）
##   · 相机降低 → 玩家视角跟着下来
##   · 模型纵向压扁 → 第三人称看起来是"蹲着"（脚仍在地面，不会陷进地里）
const CROUCH_VISUAL_SCALE := 0.75

func set_crouch(on: bool) -> void:
	if on == _crouching:
		return
	_crouching = on
	if _camera != null:
		_camera.position.y = CROUCH_HEIGHT if on else EYE_HEIGHT
	if _body_collision != null and _body_collision.shape is CapsuleShape3D:
		var cap := _body_collision.shape as CapsuleShape3D
		var h := CROUCH_HEIGHT if on else STAND_HEIGHT + 0.15
		cap.height = h
		_body_collision.position.y = h * 0.5
	if _visual != null:
		_visual.scale.y = CROUCH_VISUAL_SCALE if on else 1.0


## 眼睛/胸口的高度：蹲下时整个人的上半身都降下来了，
## bot 的视线采样起点与枪口位置都要跟着降（否则蹲在掩体后还能"越过头顶"打人）。
func eye_height() -> float:
	return 0.95 if _crouching else 1.35


# 尸体躺倒后的模型抬高量（米）：绕 X 轴转 -90° 后身体的"厚度"会落到地面以下，
# 抬高半个身位厚度让尸体正好趴在地面上。数值靠实拍调，见 --screenshot-blood 同款截图流程。
const CORPSE_LIFT := 0.26

func _lay_down() -> void:
	# 倒地：禁用碰撞（不再挡路/挡视线）
	if _body_collision:
		_body_collision.disabled = true
	if _visual == null: return
	# 本地玩家死亡后隐藏自身模型：相机就在身体里，否则会看到尸体内部
	if not is_bot:
		_visual.visible = false
		return
	# ★ 必须停住动画 ★
	# bot 死后 _physics_process 直接 return，不再调 _try_play_anim，
	# 但最后播的 Walk/Idle 是**循环**动画 —— 于是尸体躺在地上，两条腿还在原地踏步。
	# 这里用 pause() 而不是 stop()：stop() 会把骨骼还原成模型的 bind pose
	# （Sketchfab 模型是四肢张开的"海星"姿），冻在死亡瞬间的体态反而更像尸体。
	if _anim_player != null and _anim_player.is_playing():
		_anim_player.pause()
	# 平躺：绕 X 轴 -90°（原来 -80° 是"半躺半坐"，看着别扭），并抬高到贴地
	_visual.rotation.x = deg_to_rad(-90.0)
	_visual.position.y = CORPSE_LIFT
	# 蹲着死的话模型是压扁的，尸体要恢复原比例
	_visual.scale.y = 1.0
	_crouching = false
	# 不再给尸体盖灰色材质：用户反馈"模型颜色都改变了"，保留 GLB 自带贴图。
	# 死亡状态由「躺平 + 名字标签隐藏 + 碰撞关闭」表达。


func revive() -> void:
	alive = true
	health = 100.0
	_reloading = false
	reload_progress = -1.0
	_bolt_until = 0.0
	bolt_progress = -1.0
	_rescope_pending = false
	_set_scope(false)
	# 尸体被 _lay_down 的 pause() 冻住过，复活必须恢复播放。
	# 否则 _try_play_anim 会因为"current_animation 已经是 Idle"直接 return，
	# 人复活了却一直僵在死亡姿势上。
	if _anim_player != null:
		_anim_player.play()
	if _vm_root:
		_vm_root.visible = true
	if _body_collision:
		_body_collision.disabled = false
	set_crouch(false)   # 复活一律站起来（清掉 _lay_down 残留的蹲姿/压扁）
	if _visual:
		# Bot / 其他玩家显示模型；人类本体按 show_own_body 决定
		_visual.visible = is_bot or _show_own_body
		_visual.rotation.x = 0.0
		_visual.position.y = 0.0   # 清掉 _lay_down 的尸体抬高
		for m in _visual.find_children("*", "MeshInstance3D", true, false):
			m.material_override = null
		# 显示自身模型时头部必须重新透明化（低头看不到自己的头）
		if _show_own_body and not is_bot:
			_hide_head_parts()


func reload() -> void:
	if _reloading: return
	var wep: Dictionary = weapons.get(active_slot, {})
	if wep.is_empty(): return
	var wid: String = wep.get("id", "")
	if wid == "" or wid == "Knife": return
	var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
	spec = _effective_spec(wid, spec)
	if spec.is_empty(): return
	if wep.get("mag", 0) >= spec["mag"]: return
	if wep.get("reserve", 0) <= 0: return
	# 开镜换弹：先关镜（不能开着镜换子弹）
	if _zoom:
		_set_scope(false)
	if _snd_reload:
		# 音高/音量各抖一点：同一个人连着换两次弹不该是同一段波形
		_snd_reload.pitch_scale = randf_range(0.96, 1.05)
		_snd_reload.play()
	if GM != null:
		GM.emit_noise(global_position, GM.NOISE_RADIUS_MECH, self)
	_reloading = true
	reload_progress = 0.0
	_reload_wep = wep
	_reload_spec = spec
	_reload_total = 2.8 if spec.get("class", "pistol") in ["rifle", "sniper", "lmg"] else 1.8
	_reload_timer = 0.0
	ammo_changed.emit(wep.get("mag", 0), wep.get("reserve", 0))


func _finish_reload() -> void:
	_reloading = false
	reload_progress = -1.0
	if _snd_reload_done:
		_snd_reload_done.pitch_scale = randf_range(0.96, 1.05)
		_snd_reload_done.play()
	var need: int = _reload_spec["mag"] - int(_reload_wep.get("mag", 0))
	var take: int = min(need, int(_reload_wep.get("reserve", 0)))
	_reload_wep["mag"] = _reload_wep.get("mag", 0) + take
	_reload_wep["reserve"] = _reload_wep.get("reserve", 0) - take
	ammo_changed.emit(_reload_wep["mag"], _reload_wep["reserve"])


# ---------------------------------------------------------------- 狙击镜
# 圆形镜片视野（CF 风格）：圆内为画面、圆外全黑，带镜内细十字和边缘亮圈
func _build_scope_overlay() -> void:
	_scope_layer = CanvasLayer.new()
	_scope_layer.layer = 11
	_scope_layer.visible = false
	add_child(_scope_layer)
	# 必须用 ColorRect：Control 默认不绘制任何内容，shader 的 fragment 不会执行
	# ColorRect 会绘制自身矩形，shader 才能在矩形区域生效
	_scope_view = ColorRect.new()
	_scope_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scope_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scope_view.color = Color(0, 0, 0, 1)
	_scope_layer.add_child(_scope_view)
	var mat := ShaderMaterial.new()
	mat.shader = _get_scope_shader()
	_scope_view.material = mat
	_scope_view.resized.connect(_update_scope_shader)
	_update_scope_shader()


static func _get_scope_shader() -> Shader:
	if _scope_shader != null:
		return _scope_shader
	_scope_shader = Shader.new()
	_scope_shader.code = """shader_type canvas_item;
uniform float scope_radius = 0.45;
uniform vec2 viewport_size = vec2(1920.0, 1080.0);

void fragment() {
	vec2 px = (UV - vec2(0.5)) * viewport_size;
	float R = min(viewport_size.x, viewport_size.y) * scope_radius;
	float d = length(px);
	// 镜外全黑（完全不透明），镜内透明，边缘渐变柔和
	float black = smoothstep(R - 4.0, R + 4.0, d);
	// 镜内大号黑色十字准星（CF 风格：长线、不粗）
	// 宽度细（2px），长度接近镜片半径（0.92R），保证清晰可见且不挡视野
	float w = 2.0;
	float len = R * 0.92;
	float cross = 0.0;
	if (d < R * 0.96) {
		float vline = (1.0 - smoothstep(0.0, w, abs(px.x))) * (1.0 - smoothstep(len - w * 3.0, len + w * 3.0, abs(px.y)));
		float hline = (1.0 - smoothstep(0.0, w, abs(px.y))) * (1.0 - smoothstep(len - w * 3.0, len + w * 3.0, abs(px.x)));
		cross = max(vline, hline);
	}
	// 镜片边缘微亮环
	float ring = smoothstep(R + 6.0, R + 1.0, d) * smoothstep(R - 1.0, R + 2.0, d);
	float a = clamp(black + cross + ring * 0.4, 0.0, 1.0);
	COLOR = vec4(0.0, 0.0, 0.0, a);
}"""
	return _scope_shader


func _update_scope_shader() -> void:
	if _scope_view == null:
		return
	var m := _scope_view.material as ShaderMaterial
	if m == null:
		return
	m.set_shader_parameter("viewport_size", _scope_view.size)


func _set_scope(on: bool) -> void:
	if on == _zoom:
		return
	if on:
		_scope_prev_cross = GM != null and GM.crosshair_layer != null and GM.crosshair_layer.visible
	_zoom = on
	if _camera:
		_camera.fov = 25.0 if _zoom else 90.0
	if _scope_layer:
		_scope_layer.visible = _zoom
		if _zoom:
			_update_scope_shader()
			# 镜片半径支持 config.toml [weapons] 中 scope_radius 覆盖
			var wid := get_current_id()
			var spec: Dictionary = _effective_spec(wid, WeaponDatabase.weapons().get(wid, {}))
			var sr: Variant = spec.get("scope_radius", null)
			if sr != null:
				var m := _scope_view.material as ShaderMaterial
				if m != null:
					m.set_shader_parameter("scope_radius", float(sr))
	if GM != null and GM.crosshair_layer != null:
		GM.crosshair_layer.visible = _scope_prev_cross if not _zoom else false


func _zoom_toggle() -> void:
	# 玩家手动操作过开镜 → 取消"拉栓结束自动开镜"的待办，尊重手动意图
	_rescope_pending = false
	var wid := get_current_id()
	var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
	spec = _effective_spec(wid, spec)
	if spec.get("zoom", false):
		_set_scope(not _zoom)


# 是否"拿着狙击枪但没开镜" → 此时不应显示准星（CS 里狙击枪未开镜无准星）
func is_unscoped_sniper() -> bool:
	var spec: Dictionary = WeaponDatabase.weapons().get(get_current_id(), {})
	if str(spec.get("class", "")) != "sniper":
		return false
	return not _zoom


# 推进拉栓进度（由 _physics_process 每帧调用；自检里也可直接调用来跳过等待）。
# 拉栓跑完：清进度，并且如果开枪前是开镜状态就自动重新开镜（CF 手感）。
func tick_bolt() -> void:
	if bolt_progress < 0.0:
		return
	var left := _bolt_until - Time.get_ticks_msec() / 1000.0
	if left <= 0.0:
		bolt_progress = -1.0
		if _rescope_pending and not is_bot:
			_set_scope(true)
		_rescope_pending = false
	else:
		bolt_progress = clampf(1.0 - left / BOLT_TIME, 0.0, 1.0)


func _switch_slot(s: int) -> void:
	if s == 1:
		# 主武器键：在两把主武器（槽1/槽4）间轮换，只有一把则直接切到它
		var primaries: Array[int] = []
		for ps in [1, 4]:
			if not weapons.get(ps, {}).is_empty():
				primaries.append(ps)
		if primaries.is_empty():
			return
		if active_slot in primaries:
			active_slot = primaries[(primaries.find(active_slot) + 1) % primaries.size()]
		else:
			active_slot = primaries[0]
	elif s in slots:
		active_slot = s
	else:
		return
	_reloading = false
	reload_progress = -1.0
	# 切枪的金属滑动声
	if _snd_switch:
		_snd_switch.pitch_scale = randf_range(0.95, 1.06)
		_snd_switch.play()
	# 切枪取消拉栓硬直（CS 里换枪就等于打断上膛动作）
	_bolt_until = 0.0
	bolt_progress = -1.0
	_rescope_pending = false
	_set_scope(false)
	_refresh_viewmodel()
	weapon_changed.emit(s)


func _refresh_viewmodel() -> void:
	# 防空：自检脚本用 CSPlayer.new() 造了「没进场景树」的玩家（_ready 没跑，
	# _build_viewmodel 没执行），这类实例调到这里 _vm_root 是空的。
	if _vm_root == null:
		return
	for c in _vm_root.get_children():
		c.queue_free()
	var wid := get_current_id()
	# 优先使用 models/fpv/{id}.glb 真素材（放入即生效）
	var fpv := _load_fpv_model(wid)
	if fpv != null:
		# 先入树再适配（_fit_viewmodel 依赖 global_transform 测量包围盒）
		_vm_root.add_child(fpv)
		_fit_viewmodel(fpv, wid)
		_set_vm_layer(_vm_root)
		return
	_build_box_viewmodel(wid)
	_set_vm_layer(_vm_root)


# 把视模型整个子树挪到 VM_LAYER 层，配合 _vm_light 实现「只照亮枪」。
# 只改 VisualInstance3D：枪口火焰的 OmniLight3D 不在其列，它仍会照亮场景（本来就要）。
func _set_vm_layer(root: Node3D) -> void:
	var mask := 1 << (VM_LAYER - 1)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			(n as VisualInstance3D).layers = mask
		for c in n.get_children():
			stack.push_back(c)


# 自动适配任意来源的 FPV 模型（单位/朝向/原点各异）：
# 测包围盒 → 判断枪口朝向并转到相机前方 -Z → 缩放到与 box 持枪等长 → 居中并放持枪位
func _fit_viewmodel(root: Node3D, wid: String = "") -> void:
	root.transform = Transform3D.IDENTITY  # 忽略 glb 根自带变换，以包围盒为准
	var aabb := _model_aabb(root)
	var size := aabb.size
	if size.length() < 0.001:
		return  # 空模型，放弃适配
	# 最长轴 = 枪长方向
	var axis := 0
	var len := size.x
	if size.y > len:
		axis = 1
		len = size.y
	if size.z > len:
		axis = 2
		len = size.z
	# 枪口朝向判定后旋转到 -Z（相机前方）
	root.basis = _rotation_to_forward(_guess_muzzle_dir(aabb, axis, len))
	# 手动兜底：个别模型判定不准时强制翻转
	if wid != "" and VM_FLIP_180.has(wid):
		root.basis = Basis(Vector3.UP, PI) * root.basis
	# 先旋转再测量：旋转后的包围盒才是最终朝向，按它居中+缩放
	var aabb2 := _model_aabb(root)
	var center2 := aabb2.get_center()
	# 缩放：目标枪长与 box 持枪模型一致（vm_root 局部约 0.73）
	var target_len := 0.73
	var s := target_len / len
	root.scale = Vector3.ONE * s
	# 居中（补偿旋转后中心 × 缩放）+ 持枪位偏移（枪口朝右下，与原 box 视角一致）
	var offset := Vector3(-0.05, -0.02, 0.0)
	root.position = -center2 * s + offset
	# 记录枪口位置。不能简单用「持枪位偏移 + (0,0,-枪长/2)」——
	# 那是包围盒 -Z 端面的几何中心，而弹匣会把竖直方向的中心往下拽，
	# 枪管其实在中心上方，结果枪口火焰挂在枪管下方（实测偏约 40 像素）。
	# 取「-Z 端面附近顶点的重心」才是真正的枪口。
	_muzzle_local = root.position + _muzzle_point(root, aabb2) * s
	# 顺序有讲究：先升级材质，再按阵营给袖管染色 ——
	# _tint_arms 是「复制 get_active_material() 再改色」，放在后面才能把
	# 升级后的副本一起带上（否则染色会覆盖掉各向异性设置）。
	_upgrade_materials(root)
	_tint_arms(root)
	_apply_arms_visible(root)
	_build_muzzle_flash()


# 第一人称武器材质升级：把纹理过滤换成各向异性。
#
# 为什么需要：glTF 导入的材质默认是 LINEAR_WITH_MIPMAPS，不带各向异性。
# 枪身斜对着相机（持枪姿势必然如此）时，长边方向会被 mip 糊成一片，
# 机匣的刻字、护木的纹理全都看不清 —— 这是"模型显得不精致"最廉价也最有效的修法。
#
# 为什么用 override 而不是直接改原材质：GLB 里的材质是所有玩家共享的资源，
# 就地改会影响别的实例（而且导入资源在运行时改属性不干净）。
# 用 override + 缓存，同一份材质只复制一次。
# 金属度上限 / 粗糙度下限。
# 武器 GLB 的金属件是 metallic=0.9 且**完全不带贴图**（只有 baseColorFactor），
# 而场景里唯一的反射源是那张蓝色程序化天空 → 枪身整片变成蓝灰色的镜子，
# 既不像枪金属，也把木纹压得发灰。
# 压到 0.45 以下：保留一点高光，但主色回归 baseColor 的深灰，观感从"蓝色塑料"变回"钢件"。
# 觉得太哑就把 VM_METALLIC_MAX 调大（0.9 = 恢复原始素材设定）。
const VM_METALLIC_MAX := 0.45
const VM_ROUGHNESS_MIN := 0.35

static var _mat_upgrade_cache: Dictionary = {}

func _upgrade_materials(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				for si in mi.mesh.get_surface_count():
					# 注意：**不要**用 resource_path 是否为空来判断"是不是 GLB 材质" ——
					# glTF 导入的材质是嵌在场景里的子资源，resource_path 也是空的。
					# 这里只会被 _fit_viewmodel（真素材分支）调用，
					# 程序化生成的 box 兜底材质走的是另一条路，不会被误伤。
					var m := mi.get_active_material(si)
					if m == null:
						continue
					var key := m.get_rid()
					var dup: Material = _mat_upgrade_cache.get(key)
					if dup == null:
						dup = m.duplicate() as Material
						var sm := dup as StandardMaterial3D
						if sm != null:
							sm.texture_filter = \
								BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
							sm.metallic = minf(sm.metallic, VM_METALLIC_MAX)
							sm.roughness = maxf(sm.roughness, VM_ROUGHNESS_MIN)
						_mat_upgrade_cache[key] = dup
					mi.set_surface_override_material(si, dup)
		for c in n.get_children():
			stack.push_back(c)


# 第一人称手臂显隐（手臂是武器 GLB 里名为 arms 的独立节点）
func _apply_arms_visible(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and _is_arms_node(n):
			(n as MeshInstance3D).visible = _show_fpv_arms
		for c in n.get_children():
			stack.push_back(c)


# 第一人称手臂的袖管按阵营染色（CT 深蓝 / T 土棕）。
# GLB 里的材质是所有玩家共享的资源，必须先 duplicate 再改，
# 否则后加入的玩家会把先前玩家的颜色覆盖掉。
func _tint_arms(root: Node3D) -> void:
	var sleeve_col := Color(0.35, 0.29, 0.18) if team == "T" else Color(0.09, 0.13, 0.26)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				for si in mi.mesh.get_surface_count():
					var mat: Material = mi.get_active_material(si)
					if mat == null:
						continue
					if mat.resource_name.to_lower().contains("sleeve"):
						var dup := mat.duplicate() as StandardMaterial3D
						if dup != null:
							dup.albedo_color = sleeve_col
							mi.set_surface_override_material(si, dup)
		for c in n.get_children():
			stack.push_back(c)


# 判断模型枪口指向。
# 枪口必定在「最长轴」方向上，关键只是判断正负：
# 武器模型的原点通常落在握把上，枪身整体朝枪口延伸，
# 所以「包围盒中心在最长轴上的分量」的符号就指向枪口。
# 该分量过小（原点在几何中心）时，退回「最长轴正方向 = 枪口」的假设。
#
# 注意：不要用「偏移量最大的那个轴」来判断 —— 无托结构的枪（如 P90，
# 弹匣在机匣顶部）重心明显偏上，竖直分量会盖过水平分量，导致误判。
func _guess_muzzle_dir(aabb: AABB, axis: int, longest: float) -> Vector3:
	var c := aabb.get_center()
	var comp: float = [c.x, c.y, c.z][axis]
	var dir: Vector3 = [Vector3.RIGHT, Vector3.UP, Vector3.BACK][axis]
	if absf(comp) > longest * 0.02:
		return dir * signf(comp)
	return dir


# 求把 fwd 方向旋转到 -Z（相机前方）所需的旋转
func _rotation_to_forward(fwd: Vector3) -> Basis:
	if fwd.z < -0.5:
		return Basis()                                   # 已经是 -Z，不用转
	if fwd.z > 0.5:
		return Basis(Vector3.UP, PI)                     # +Z → -Z
	if fwd.x > 0.5:
		return Basis(Vector3.UP, deg_to_rad(90.0))       # +X → -Z
	if fwd.x < -0.5:
		return Basis(Vector3.UP, deg_to_rad(-90.0))      # -X → -Z
	if fwd.y > 0.5:
		return Basis(Vector3.RIGHT, deg_to_rad(-90.0))   # +Y → -Z
	return Basis(Vector3.RIGHT, deg_to_rad(90.0))        # -Y → -Z


# 第一人称手臂节点判定（GLB 里手臂是独立于武器的另一个节点，名字含 arms）
func _is_arms_node(n: Node) -> bool:
	return n.name.to_lower().contains("arms")


# 计算模型根节点下所有 MeshInstance 合并后的包围盒（相对根节点局部坐标）
func _model_aabb(root: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			# 跳过第一人称手臂：它只是挂在武器上的装饰，不能参与包围盒/枪口计算，
			# 否则手臂会把包围盒撑大、把武器整体缩小、枪口位置也算偏
			if mi.mesh != null and not _is_arms_node(mi):
				var t: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
				var mbb := mi.mesh.get_aabb()
				for i in 8:
					var p: Vector3 = t * mbb.get_endpoint(i)
					if first:
						aabb = AABB(p, Vector3.ZERO)
						first = false
					else:
						aabb = aabb.expand(p)
		for c in n.get_children():
			stack.push_back(c)
	return aabb


# 求枪口在 root 局部坐标中的位置：取「对齐后包围盒 -Z 端面附近」顶点的重心。
# 直接用端面几何中心会被弹匣/瞄具带偏（竖直方向尤其明显）。
func _muzzle_point(root: Node3D, aabb: AABB) -> Vector3:
	var z_min := aabb.position.z
	var band := maxf(aabb.size.z * 0.05, 0.003)
	var sum := Vector3.ZERO
	var n := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh != null and not _is_arms_node(mi):
				var t: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
				for v in mi.mesh.get_faces():
					var p: Vector3 = t * v
					if p.z <= z_min + band:
						sum += p
						n += 1
		for c in node.get_children():
			stack.push_back(c)
	if n == 0:
		return Vector3(0.0, 0.0, z_min)
	return sum / float(n)


func _load_fpv_model(wid: String) -> Node3D:
	var candidates: Array[String] = [
		"res://models/fpv/%s.glb" % wid,
		"res://models/fpv/%s.gltf" % wid,
		"res://models/fpv/%s.tres" % wid,
	]
	for path in candidates:
		if not ResourceLoader.exists(path):
			continue
		var res := load(path)
		if res is PackedScene:
			var inst := (res as PackedScene).instantiate()
			if inst is Node3D:
				return inst
	return null


# ------------------------------------------------------------------ 枪口火焰
# 挂在 _vm_root 下的加性混合星形面片 + 短时点光，开火瞬间闪现约 45ms。
# 面片用 billboard 模式常朝摄像机，从任意角度都能看到。
func _build_muzzle_flash() -> void:
	if _vm_root == null:
		return
	# _vm_root 的子节点会在切枪时被整体 queue_free，这里要用 is_instance_valid 防野指针
	if is_instance_valid(_flash_mesh):
		_flash_mesh.queue_free()
	_flash_mesh = null
	if is_instance_valid(_flash_light):
		_flash_light.queue_free()
	_flash_light = null
	_flash_until = 0.0

	_flash_mesh = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.30, 0.30)
	_flash_mat = ShaderMaterial.new()
	_flash_mat.shader = _get_flash_shader()
	_flash_mat.set_shader_parameter("flash_color", Color(1.0, 0.82, 0.42))
	_flash_mat.set_shader_parameter("energy", 3.4)
	_flash_mat.set_shader_parameter("seed", 0.0)
	_flash_mat.render_priority = 11
	quad.material = _flash_mat
	_flash_mesh.mesh = quad
	_flash_mesh.position = _muzzle_local
	_flash_mesh.visible = false
	_flash_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vm_root.add_child(_flash_mesh)

	# 点光：让开火瞬间枪口附近的地面和墙面被照亮，火焰才有"在发光"的感觉
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.80, 0.45)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 4.5
	_flash_light.shadow_enabled = false
	_flash_light.position = _muzzle_local
	_vm_root.add_child(_flash_light)


# 开火时调用：点亮火焰，每发随机旋转/缩放，避免连发时火焰一模一样
func _flash() -> void:
	if not is_instance_valid(_flash_mesh):
		return
	_flash_until = Time.get_ticks_msec() / 1000.0 + 0.045
	_flash_mesh.visible = true
	_flash_mesh.rotation.z = randf_range(0.0, TAU)
	var sc := randf_range(0.82, 1.28)
	_flash_mesh.scale = Vector3(sc, sc, sc)
	if _flash_mat != null:
		_flash_mat.set_shader_parameter("seed", randf())
	if is_instance_valid(_flash_light):
		_flash_peak = randf_range(2.4, 3.4)
		_flash_light.light_energy = _flash_peak


func _tick_muzzle_flash() -> void:
	if _flash_until <= 0.0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now >= _flash_until:
		_flash_until = 0.0
		if is_instance_valid(_flash_mesh):
			_flash_mesh.visible = false
		if is_instance_valid(_flash_light):
			_flash_light.light_energy = 0.0
		return
	# 点光按剩余时间线性衰减（用绝对时间算，不受帧率影响）
	if is_instance_valid(_flash_light):
		_flash_light.light_energy = (_flash_until - now) / 0.045 * _flash_peak


## 枪口火焰 Shader（全局缓存）：中心亮斑 + 星形放射光晕
static var _flash_shader: Shader = null
static func _get_flash_shader() -> Shader:
	if _flash_shader != null:
		return _flash_shader
	_flash_shader = Shader.new()
	_flash_shader.code = """shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_test_disabled;

uniform vec4 flash_color : source_color = vec4(1.0, 0.82, 0.42, 1.0);
uniform float energy = 3.4;
uniform float seed = 0.0;

void fragment() {
	vec2 uv = UV - vec2(0.5);
	float d = length(uv) * 2.0;              // 0=中心, 1=边缘
	float a = atan(uv.y, uv.x);
	// 星形放射：主刺数量固定，相位随 seed 变化，保证每发形状不同
	float spikes = 0.45 + 0.55 * pow(abs(cos(a * 3.0 + seed * 6.28318)), 1.5);
	float core = 1.0 - smoothstep(0.0, 0.42, d);   // 中心亮斑
	float halo = (1.0 - smoothstep(0.0, 1.0, d)) * spikes;  // 外圈光晕
	float v = clamp(core * 1.8 + halo * 0.85, 0.0, 2.2);
	ALBEDO = flash_color.rgb * energy;
	ALPHA = v;
}
"""
	return _flash_shader


func _build_box_viewmodel(wid: String) -> void:
	var body_col := Color(0.18, 0.19, 0.22)      # 枪体
	var steel_col := Color(0.30, 0.32, 0.36)     # 金属
	var mag_col := Color(0.22, 0.2, 0.16)        # 弹匣

	match wid:
		"Knife":
			_part(Vector3(0, 0, -0.32), Vector3(0.02, 0.02, 0.32), Color(0.75, 0.78, 0.82))  # 刀刃
			_part(Vector3(0, 0.01, -0.02), Vector3(0.05, 0.045, 0.16), Color(0.42, 0.3, 0.16)) # 刀柄
			_add_glove(0)
			return
		"AK47":
			body_col = Color(0.28, 0.2, 0.12)
			mag_col = Color(0.32, 0.22, 0.12)
		"M4A1":
			body_col = Color(0.14, 0.16, 0.2)
			mag_col = Color(0.2, 0.24, 0.28)
		"AWP":
			body_col = Color(0.1, 0.18, 0.16)
		"Deagle":
			body_col = Color(0.35, 0.3, 0.22)
		"Glock":
			body_col = Color(0.3, 0.3, 0.33)

	# 机匣
	_part(Vector3(0, 0.01, -0.18), Vector3(0.055, 0.07, 0.22), body_col)
	# 枪管
	_part(Vector3(0, 0.02, -0.5), Vector3(0.03, 0.03, 0.38), steel_col)
	# 弹匣
	_part(Vector3(0, -0.09, -0.14), Vector3(0.045, 0.1, 0.05), mag_col)
	# 握把
	_part(Vector3(0, -0.1, -0.02), Vector3(0.045, 0.1, 0.05), body_col)
	# 瞄具（狙/步枪）
	_part(Vector3(0, 0.075, -0.06), Vector3(0.02, 0.03, 0.1), Color(0.15, 0.16, 0.18))
	_add_glove(1)
	# box 模型的枪管末端在 z=-0.69（-0.5 - 0.38/2），枪口火焰挂这里
	_muzzle_local = Vector3(0.0, 0.02, -0.69)
	_build_muzzle_flash()


func _add_glove(side: int) -> void:
	# 底部握把位置补一个手套小圆球，表示握着枪
	var g := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.045
	s.height = 0.09
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.18, 0.15) if team == "T" else Color(0.15, 0.2, 0.25)
	mat.roughness = 0.8
	s.material = mat
	g.mesh = s
	g.position = Vector3(0, -0.06, 0.04)
	_vm_root.add_child(g)


func _part(pos: Vector3, size: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	box.material = mat
	mi.mesh = box
	mi.position = pos
	_vm_root.add_child(mi)


# ------------------------------------------------------------------ 装备 / 购买
## 换阵营（房间里真人自己选的那个）。
## CT / T 是**两套角色模型 + 两种起始手枪**，所以换阵营必须把这两样一起重建；
## 出生点（`_pick_spawn(team)`）/ 队友敌人判定 / HUD 阵营名都是现读 `team`，不用管。
func set_team(t: String) -> void:
	if t == team or (t != "CT" and t != "T"):
		return
	team = t
	# 1) 重建第三人称模型（_build_visual 会新建 _visual 并重新挂 GLB）
	if _visual != null:
		if _visual.get_parent() == self:
			remove_child(_visual)
		_visual.queue_free()
		_visual = null
	_model_root = null
	_anim_player = null
	_build_visual()
	# 2) 起始手枪跟着换。只在"手里还没主武器"时换 —— 别覆盖玩家自己捡的枪
	if not is_bot and get_primary_id() == "":
		give_weapon(2, "Glock" if team == "T" else "USP")
		_refresh_viewmodel()


func give_weapon(slot: int, id: String) -> void:
	var spec: Dictionary = WeaponDatabase.weapons().get(id, {})
	if spec.is_empty(): return
	weapons[slot] = {"id": id, "mag": spec["mag"], "reserve": spec["reserve"]}
	_update_slots()


func _update_slots() -> void:
	slots.clear()
	for s in [1, 2, 3, 4]:
		var w: Dictionary = weapons.get(s, {})
		if not w.is_empty() and w.get("id", "") != "":
			slots.append(s)
	if slots.is_empty():
		slots.append(3)
	# 主武器 id 同步给房主：死亡掉枪要用（房主那边没有客户端本机的武器表）
	net_primary = get_primary_id()


func add_money(amount: int) -> void:
	money = clampi(money + amount, 0, 16000)


func buy(id: String) -> bool:
	var spec: Dictionary = WeaponDatabase.weapons().get(id, {})
	if spec.is_empty(): return false
	spec = _effective_spec(id, spec)
	if spec.get("team", "any") != "any" and spec.get("team") != team: return false
	if int(spec.get("price", 0)) > money: return false
	# 已拥有的武器不能重复购买
	if has_weapon_id(id): return false
	var target_slot := int(spec["slot"])
	if target_slot == 1:
		# 主武器最多两把且不重复：放入空闲的主武器槽（槽1 / 槽4）
		target_slot = _free_primary_slot()
		if target_slot == 0:
			return false
	money -= int(spec["price"])
	give_weapon(target_slot, id)
	# 买后自动切到新武器
	if target_slot in slots:
		_switch_slot(target_slot)
	return true


# 是否已持有指定武器（任意槽位）
func has_weapon_id(id: String) -> bool:
	for s: int in weapons:
		var w: Dictionary = weapons[s]
		if not w.is_empty() and w.get("id", "") == id:
			return true
	return false


# 主武器槽是否已满（两把）
func primaries_full() -> bool:
	return not weapons.get(1, {}).is_empty() and not weapons.get(4, {}).is_empty()


# 是否已持有任意主武器（槽 1 / 槽 4）
func has_primary() -> bool:
	return not weapons.get(1, {}).is_empty() or not weapons.get(4, {}).is_empty()


# 当前主武器 id（槽 1 优先，其次槽 4）；没有主武器返回 ""
func get_primary_id() -> String:
	for s in [1, 4]:
		var w: Dictionary = weapons.get(s, {})
		if not w.is_empty():
			return str(w.get("id", ""))
	return ""


# 取下主武器并返回它的 id（槽 1 优先，其次槽 4）；没有则返回 ""。
# 给 bot 换枪用：旧枪由调用方丢回地上，避免地图上的枪被 bot 吃光。
func take_primary() -> String:
	for s in [1, 4]:
		var w: Dictionary = weapons.get(s, {})
		if w.is_empty():
			continue
		var wid := str(w.get("id", ""))
		weapons[s] = {}
		_update_slots()
		# 手里拿的正好是被取走的那把 → 切到其它还有枪的槽，别拿着空槽
		if active_slot == s:
			active_slot = 0
			for t in [4, 1, 2, 3]:
				if not weapons.get(t, {}).is_empty():
					active_slot = t
					break
			if active_slot == 0:
				active_slot = 3
		_reloading = false
		reload_progress = -1.0
		_refresh_viewmodel()
		weapon_changed.emit(active_slot)
		return wid
	return ""


# 从地上捡枪。
# **规则**：手里已有主武器就不能再捡（必须先按 G 丢掉），避免"无限叠枪"。
# 手枪（槽2）不受此限，但同一把枪不重复持有。
func pickup_weapon(id: String) -> bool:
	var spec: Dictionary = WeaponDatabase.weapons().get(id, {})
	if spec.is_empty(): return false
	if has_weapon_id(id): return false          # 已有同一把
	var target := int(spec.get("slot", 1))
	if target == 1:
		if has_primary():
			return false                         # 有主武器就不能捡第二把
		target = _free_primary_slot()
		if target == 0:
			return false
	give_weapon(target, id)
	if target in slots:
		_switch_slot(target)
	return true


# 按 G 丢掉当前手里的枪（刀不能丢）。返回丢掉的武器 id，没丢成返回 ""
func drop_current() -> String:
	var w: Dictionary = weapons.get(active_slot, {})
	if w.is_empty():
		return ""
	var wid: String = w.get("id", "")
	if wid == "" or wid == "Knife":
		return ""
	weapons[active_slot] = {}
	_update_slots()
	# 优先切回还没丢的主武器，否则切到手枪/刀
	if active_slot == 1 and not weapons.get(4, {}).is_empty():
		active_slot = 4
	else:
		var fallback := 0
		for s in [4, 1, 2, 3]:
			if s != active_slot and not weapons.get(s, {}).is_empty():
				fallback = s
				break
		if fallback != 0:
			active_slot = fallback
	_reloading = false
	reload_progress = -1.0
	_bolt_until = 0.0
	bolt_progress = -1.0
	_rescope_pending = false
	_set_scope(false)
	_refresh_viewmodel()
	weapon_changed.emit(active_slot)
	return wid


# 返回空闲主武器槽（1 或 4），已满返回 0
func _free_primary_slot() -> int:
	if weapons.get(1, {}).is_empty(): return 1
	if weapons.get(4, {}).is_empty(): return 4
	return 0


func buy_kit() -> bool:
	if has_defuser: return false
	if money < 200: return false
	money -= 200
	has_defuser = true
	return true


func buy_armor(full: bool) -> bool:
	var cost := 1000 if full else 650
	if money < cost: return false
	money -= cost
	armor = 100.0
	has_helmet = full
	return true
