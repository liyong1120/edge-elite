extends "res://scripts/player.gd"
class_name GBot

## 简单 bot：寻找最近敌人并移动朝向开火；T 携带者在后段尝试安包

var target: CSPlayer = null
var fire_cd := 0.0
var plant_pointed := false

## 三档人机难度的**全部**参数。想调难度手感只改这张表即可。
##   hit_chance_near/far  近距(<15m) / 远距 的命中概率
##   fire_interval        两次开火之间的最小间隔（秒）
##   head_chance          命中时判定为爆头的概率
##   reaction             刚发现目标时先"愣"多久才开第一枪（秒）—— 最直观的反应速度
##   sight_range          多远开始交战（米）
##   speed_mult           移动速度倍率（难度也体现在走位快慢上）
##   move_penalty_immune  移动中是否免疫精度惩罚（困难档走打也准）
const DIFFICULTY: Array[Dictionary] = [
	{   # 0 简单
		"name": "简单",
		"hit_chance_near": 0.30, "hit_chance_far": 0.06,
		"fire_interval": 0.42, "head_chance": 0.03,
		"reaction": 0.90, "sight_range": 32.0, "speed_mult": 0.85,
		"move_penalty_immune": false,
	},
	{   # 1 普通
		"name": "普通",
		"hit_chance_near": 0.50, "hit_chance_far": 0.18,
		"fire_interval": 0.18, "head_chance": 0.15,
		"reaction": 0.45, "sight_range": 45.0, "speed_mult": 1.0,
		"move_penalty_immune": false,
	},
	{   # 2 困难
		"name": "困难",
		"hit_chance_near": 0.75, "hit_chance_far": 0.38,
		"fire_interval": 0.12, "head_chance": 0.28,
		"reaction": 0.18, "sight_range": 60.0, "speed_mult": 1.10,
		"move_penalty_immune": true,
	},
]

var _reaction_left := 0.0   # 反应延迟倒计时
var _had_target := false
var _no_los_time := 0.0     # 有目标但一直看不到视线的累计时长（见 chase() 的绕行兜底）
const NO_LOS_ROUTE_GIVEUP := 5.0

# ---------------------------------------------------------------- 听声辨位
# GM.emit_noise() 会在半径内调用 on_hear_noise()。记住位置一段时间：
# 没有目标时过去查看；正躲在掩体后时，附近有动静就提前探身戒备。
const HEARD_MEMORY := 7.0
var _heard_pos := Vector3.ZERO
var _heard_timer := 0.0


## 根据全局人机难度返回该档位的全部属性
func _difficulty_stats() -> Dictionary:
	var d: int = GM.bot_difficulty if GM != null else 1
	return DIFFICULTY[clampi(d, 0, DIFFICULTY.size() - 1)]


## 该档位下的移动速度
func _move_speed() -> float:
	# 和玩家同一套移速体系：基础跑速 × 武器类型倍率 × 难度倍率
	return RUN_SPEED * float(WEAPON_SPEED.get(_weapon_class(), 1.0)) \
			* float(_difficulty_stats().get("speed_mult", 1.0))


func _ready() -> void:
	super._ready()
	is_bot = true
	# 尽量用主武器
	if not weapons[1].is_empty():
		active_slot = 1


## 听到动静（GM.emit_noise 在半径内调用）。枪声传得远、脚步/机械声很近。
func on_hear_noise(pos: Vector3, source: Node, _radius: float) -> void:
	if not alive or source == self:
		return
	_heard_pos = pos
	_heard_timer = HEARD_MEMORY
	# 正躲在掩体后：附近有动静就缩短躲藏时间、提前探身戒备
	# （别缩在墙后当聋子 —— 真人听到脚步会立刻举枪）
	if _cs == CS_COVER and _cover_valid:
		if global_position.distance_to(pos) < 12.0:
			_hide_left = minf(_hide_left, randf_range(0.05, 0.25))


## 去查看听到的动静；到了附近还没发现人就放弃
func _investigate_noise(delta: float) -> void:
	if global_position.distance_to(_heard_pos) < 2.0:
		_heard_timer = 0.0
		wander(delta)
		return
	_move_to(_heard_pos, delta)


## 脚步声（玩家和 bot 共用同一套判定：静步/蹲下无声，也不产生噪声事件）
func _footstep(delta: float) -> void:
	try_footstep(delta, Vector2(velocity.x, velocity.z).length() > 0.5)


## 复活后重置交战状态：掩体点可能已经过期（目标换位置了），
## 不重置的话 bot 会跑去一个早就不管用的掩体点蹲着。
func revive() -> void:
	super.revive()
	_cs = CS_APPROACH
	_cover_valid = false
	_cover_wait = 0.0
	_cover_cool = 0.0
	_peek_left = 0.0
	_fire_left = 0.0
	_jump_pending = false
	_no_los_time = 0.0
	set_crouch(false)


func _physics_process(delta: float) -> void:
	# ★ 联机时 AI 只在房主那台机器上跑 ★
	#   电脑的 authority = 1；客户端上这些节点的位置由 MultiplayerSynchronizer 写进来。
	#   不加这一句的话两台机器各跑一套 AI，bot 位置会互相打架（"人瞬移"）。
	if not is_multiplayer_authority():
		return
	# 死亡：让尸体受重力落到地面，落地后冻结（防止一直飘在空中）
	if not alive:
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
			move_and_slide()
		else:
			velocity = Vector3.ZERO
		return
	_pick_best_slot()
	find_target()
	_update_los()
	# 反应延迟：刚"发现"目标时先愣一下才开枪（难度越高愣得越短）
	# 只在 无目标→有目标 的那一刻重置，目标切换 / 短暂丢失视线不会反复重置
	if target != null and not _had_target:
		_reaction_left = float(_difficulty_stats().get("reaction", 0.0))
	_had_target = target != null
	_reaction_left = maxf(_reaction_left - delta, 0.0)
	_heard_timer = maxf(_heard_timer - delta, 0.0)
	# 开火阶段判定：
	#   · LIVE  → 正常开火
	#   · BUY   → **也允许开火**。本模式其实没有购买（B 键被屏蔽，只能去出生点捡枪），
	#             玩家在购买阶段本来就能开枪（main.gd `_check_elimination()` 也覆盖 BUY），
	#             只有 bot 被这条规则按住不开火 → 每回合前 10 秒"双方照面了却一枪不放"，
	#             就是玩家反馈的「见面半天不开火很呆」。
	#   · MENU / OVER → 只游走，不开火
	var can_fire_state := GM == null or GM.state == GM.STATE.LIVE or GM.state == GM.STATE.BUY
	if not can_fire_state:
		if target == null:
			wander(delta)
		else:
			chase(delta)
		return

	# ---------------------------------------------------------- 移动决策
	# 没主武器 → 先去捡地上的枪。本模式每回合**不再给 bot 发枪**，
	# 地上那 16 把出生点配枪就是唯一来源（本模式的玩法核心）。
	# 例外：身边有看得见的近敌时先打，别为了捡枪被贴脸打死。
	var gun: Node3D = null
	if not has_primary() and not _enemy_too_close():
		gun = _nearest_ground_weapon()
	if gun != null:
		_move_to(gun.global_position, delta)
	elif target == null:
		# 没目标：优先去查看最近听到的动静（听声辨位），没有动静才随机游走
		if _heard_timer > 0.0:
			_investigate_noise(delta)
		else:
			wander(delta)
	else:
		face_target()
		# 看不见目标、但听到了**更近的**动静 → 先去查看那个位置。
		# 真人循声找人就是这样：绕角的时候靠脚步判断方位，比"往最后看到的位置走"准。
		var d_heard := global_position.distance_to(_heard_pos)
		var d_tgt := global_position.distance_to(target.global_position)
		if not _los_ok and _heard_timer > 0.0 and d_tgt > 6.0 and d_heard < d_tgt - 3.0:
			_investigate_noise(delta)
		else:
			chase(delta)

	# ---------------------------------------------------------- 开火决策
	# 与移动解耦：跑着去捡枪的路上照样能开枪还击
	if target == null:
		return
	# 检查配置文件中是否允许 bot 攻击（枪/刀/手雷等所有攻击方式）
	var config_manager := ConfigManager.instance
	var can_attack := true
	if config_manager:
		can_attack = config_manager.get_bot_can_attack()
	
	# 开火（需要视线、在交战距离内、且反应延迟已过）
	var st := _difficulty_stats()
	fire_cd -= delta
	var dist := global_position.distance_to(target.global_position)
	# ★ 开火**不受距离限制** ★
	# 只要看得见就打 —— 真人看到视野里有人就开枪，不会因为"太远"就先不开。
	# （旧版还带一个 `dist < sight_range` 的条件，远处有敌人却一枪不放。）
	# 另外：**假动作探身时故意不开火** —— 只露身位骗对方开枪/暴露位置。
	# 开火与移动是解耦的，所以这里必须显式排除 _feint。
	if can_attack and not _feint and fire_cd <= 0.0 and _reaction_left <= 0.0 and _has_los():
		fire_cd = float(st["fire_interval"])
		var wid_cur := get_current_id()
		var spec: Dictionary = _effective_spec(wid_cur, WeaponDatabase.weapons().get(wid_cur, {}))
		if not spec.is_empty():
			var acc: float = float(st["hit_chance_near"] if dist < 15.0 else st["hit_chance_far"])
			# 简单/普通难度下还受移动误差影响，更贴近真实手感；困难档走打也准
			if not bool(st.get("move_penalty_immune", false)):
				acc *= 1.0 - clampf((velocity.length() * 0.08), 0.0, 0.25)
			var is_hit: bool = randf() < acc
			var is_head: bool = randf() < st["head_chance"]
			# 弹道特效：无论命中与否都生成曳光，让玩家能看到 bot 在开火
			# 注意：bot 必须用**世界空间 3D 曳光**（_spawn_tracer_3d），
			# 不能用玩家那套屏幕空间曳光 —— 那套挂在各自 CanvasLayer 上，
			# 会按 bot 自己的相机投影，全部叠到玩家屏幕上变成"子弹乱飞"。
			# 枪口高度跟随蹲姿（蹲下时整个上半身都降下来了）
			var muzzle: Vector3 = global_position + Vector3(0, eye_height(), 0)
			# 瞄"实际能看见的部位"：
			#   只有头露在矮墙外（胸被挡）→ 只能打头 —— 这就是玩家说的"站在远处打我头"
			#   身体可见 → 爆头判定为真时瞄头，否则瞄胸口
			var aim_y := LOS_CHEST_Y
			if _los_head and not _los_chest:
				aim_y = LOS_HEAD_Y
			elif is_head:
				aim_y = LOS_HEAD_Y
			elif not _los_chest:
				aim_y = LOS_WAIST_Y
			var aim_pos: Vector3 = target.global_position + Vector3(0, aim_y, 0)
			var aim_dir: Vector3 = (aim_pos - muzzle).normalized()
			# 枪口略向前 0.6m，避免光弹从角色体内穿出
			muzzle += aim_dir * 0.6
			var end_pos: Vector3 = aim_pos
			if not is_hit:
				# 未命中：在目标周围随机偏移，模拟打偏
				end_pos = aim_pos + Vector3(
					randf_range(-1.5, 1.5),
					randf_range(-0.8, 1.2),
					randf_range(-1.5, 1.5))
			_spawn_tracer_3d(muzzle, end_pos)
			_play_shot()
			if is_hit:
				target.apply_damage(spec, self, is_head)
				# 命中玩家：生成血溅特效（与玩家命中 bot 一致）
				_spawn_blood_spray(end_pos, aim_dir)


# ---------------------------------------------------------------- 视线采样
# 采样高度（相对目标原点）：头 / 胸 / 腰。
# ★ 只查胸口一个点是不够的 ★
# 玩家蹲在小围墙后只露出头时，胸口那条射线被墙挡住 → 会被判成"看不见"，
# bot 就会按"没视线"的逻辑一路贴到 1.2m 去找人。玩家看到的就是
# 「它明明在视野里、非要跑到我面前才开枪」。
# 三点采样任一可见即算有视线，并记录头/胸是否可见用于瞄准。
const LOS_HEAD_Y := 1.55
const LOS_CHEST_Y := 1.05
const LOS_WAIST_Y := 0.75
const LOS_HEIGHTS := [LOS_HEAD_Y, LOS_CHEST_Y, LOS_WAIST_Y]

var _los_ok := false      # 本帧能否看到目标（任一采样点可见）
var _los_head := false    # 头部可见
var _los_chest := false   # 胸部可见


## 每个物理帧刷新一次；chase / 开火 / 自检都读缓存值，避免同一帧重复打射线
func _update_los() -> void:
	_los_ok = false
	_los_head = false
	_los_chest = false
	if target == null:
		return
	var space := get_world_3d().direct_space_state
	# 视线起点跟随蹲姿：蹲在掩体后就不该"越过头顶"看到人
	var from := global_position + Vector3(0, eye_height(), 0)
	for h in LOS_HEIGHTS:
		var q := PhysicsRayQueryParameters3D.create(from, target.global_position + Vector3(0, h, 0))
		q.exclude = [self]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or hit.get("collider") == target:
			_los_ok = true
			if h >= LOS_HEAD_Y:
				_los_head = true
			elif h >= LOS_CHEST_Y:
				_los_chest = true


func _has_los() -> bool:
	if target == null:
		return true
	return _los_ok


## 有看得见的近敌（8m 内）→ 先打，别顾着捡枪
func _enemy_too_close() -> bool:
	if target == null:
		return false
	return _los_ok and global_position.distance_to(target.global_position) < 8.0


# ---------------------------------------------------------------- 捡地上的枪
# 本模式每回合**不再给 bot 发枪**，地上那 16 把出生点配枪就是唯一来源，
# 所以没主武器时必须主动去捡（见 _physics_process 的移动决策）。
const WEAPON_SEEK_RANGE := 30.0


## 最近的地面主武器（WEAPON_SEEK_RANGE 内），没有则返回 null
func _nearest_ground_weapon() -> Node3D:
	var best: Node3D = null
	var best_d := WEAPON_SEEK_RANGE
	for n in get_tree().get_nodes_in_group("weapon_pickups"):
		var w := n as Node3D
		if w == null or w.is_queued_for_deletion():
			continue
		var wid := str(w.get("weapon_id"))
		var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
		if spec.is_empty() or int(spec.get("slot", 1)) != 1:
			continue   # 只关心主武器
		var d := global_position.distance_to(w.global_position)
		if d < best_d:
			best_d = d
			best = w
	return best


## 朝一个点移动（捡枪用）：复用 nav 路径 + 卡死绕行，但不做交战距离判断。
## 到达判定 0.6m < 掉落物 1.05m 的检测半径，保证真的踩上去触发拾取。
func _move_to(goal: Vector3, delta: float) -> void:
	_update_stuck(delta)
	# 捡枪不需要侧翼包抄，强制直取
	_route = 0
	_route_valid = false
	_route_left = 0.0
	var flat := goal - global_position
	flat.y = 0.0
	if flat.length() < 0.6:
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y -= GRAVITY * delta
		move_and_slide()
		_try_play_anim("Idle")
		return
	_nav_cool -= delta
	if _nav_cool <= 0.0:
		_nav_cool = NAV_REPATH
		_repath(goal)
	var go := _dir_along_path(goal)
	if _side_step > 0.0:
		go = go.rotated(Vector3.UP, _side_sign * 0.6)
	var desired := atan2(-go.x, -go.z)
	rotation.y = lerp_angle(rotation.y, desired, 0.35)
	var spd := _move_speed()
	velocity.x = go.x * spd
	velocity.z = go.z * spd
	velocity.y -= GRAVITY * delta
	move_and_slide()
	_try_play_anim("Walk")
	_footstep(delta)


# ---------------------------------------------------------------- 寻路


func _pick_best_slot() -> void:
	var w: Dictionary = weapons.get(active_slot, {})
	if not w.is_empty(): return
	for s in [1, 4, 2, 3]:
		var ww: Dictionary = weapons.get(s, {})
		if not ww.is_empty():
			active_slot = s
			return


func find_target() -> void:
	target = null
	var best := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p == self or not p.alive: continue
		if p.team == team: continue
		var d := global_position.distance_to(p.global_position)
		if d < best:
			best = d
			target = p


func face_target() -> void:
	if target == null: return
	var dir := target.global_position - global_position
	dir.y = 0
	if dir.length() < 0.01: return
	var desired := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, desired, 0.35)


# ------------------------------------------------------------------ 寻路
# 走 main.gd 里那张 AStarGrid2D 栅格（0.5m 一格，障碍物按角色半径膨胀过）。
#
# 这里**不用**射线胡须避障：试过一轮，bot 在方块前面会左右横跳
# （射线结果每帧变、方向来回翻就是抖）。栅格 A* 的路径天生不碰障碍，
# 照着路点走就不会撞，也不会抖。
const NAV_REPATH := 0.35   # 重算路径间隔（秒）——目标一直在动，太慢会走老路
const NAV_WP_DIST := 0.9   # 判定"到达路点"的距离（米）

var _nav_cool := 0.0
var _nav_pts: PackedVector2Array = []
var _nav_i := 0

# ---- 路线多样化 ----
# A* 每次都给"最优解"，bot 会永远走同一条线，看起来像 NPC 在放录像。
# 三个手段让它像真人选路：
#   1) main.gd 建栅格时给每格 ±20% 的随机通行代价 → 不同回合路线本来就不同；
#   2) 侧翼方向用"摸球袋"左右交替抽（_next_side），不会连抽同一侧；
#   3) 中转点不是固定偏移，而是从直线中段往侧翼探到"最远可走点"（_pick_route_mid），
#      保证真的走进左右两条侧翼通道，而不是落进中央方块被 nav 吸到同一处。
#      中转点选定后**定死**（_route_wp），否则每 0.35s 随 bot 位置重算 = bot 追一个
#      会跑的目标 = 在两翼之间来回抽、永远到不了对面。走完就转直取。选择保持 8~14 秒。
var _route := 0            # 0 = 直取 / -1 / +1 = 左/右侧翼
var _route_side := 1.0
var _route_f := 0.45       # 中转点在直线上的位置比例
var _route_off := 18.0     # 实际取到的侧向偏移（米，诊断用）
var _route_left := 0.0     # >0 = 当前路线还剩多少秒
var _route_cool := 0.0
var _route_wp := Vector3.ZERO      # 中转点：选定路线时**定死**，不随 bot 位置重算
var _route_valid := false
var _side_bag: Array[float] = []   # 侧翼方向"摸球袋"：抽完再洗，保证左右交替

## 左右交替取侧翼方向：避免连续几次都抽到同一侧
## （旧版每次独立 50/50，运气差能连抽 5、6 次同一侧，看着就像固定路线）
func _next_side() -> float:
	if _side_bag.is_empty():
		_side_bag = [1.0, -1.0]
		_side_bag.shuffle()
	return _side_bag.pop_back()

func _update_route(delta: float, target_pos: Vector3) -> void:
	_route_cool -= delta
	if _route_left > 0.0:
		_route_left -= delta
		# 到达中转点就算这条绕行走完，改直取追人；
		# 否则会在"东翼→西翼→东翼"之间来回抽，永远到不了南边。
		if _route_valid and global_position.distance_to(_route_wp) < 2.5:
			_route = 0
			_route_valid = false
			_route_left = 0.0
			_route_cool = randf_range(3.0, 5.0)
	if _route_left <= 0.0 and _route_cool <= 0.0:
		_route_cool = randf_range(4.0, 7.0)
		_route_f = randf_range(0.35, 0.6)
		# 直取只留小概率：正对中央方块群时，A* 永远往"最近的一侧"绕，
		# 就是玩家看到的"总从同一边来"。改成绝大多数时候必选侧翼。
		if randf() < 0.15:
			_route = 0
			_route_valid = false
		else:
			_route_side = _next_side()
			_route = 1 if _route_side > 0.0 else -1
			_route_wp = _pick_route_mid(global_position, target_pos)
			_route_valid = true
		_route_left = randf_range(8.0, 14.0)


# 卡死检测：想走但走不动，就换个方向绕一会儿
var _last_pos := Vector3.ZERO
var _stuck_time := 0.0
var _side_step := 0.0     # >0 = 正在绕行
var _side_sign := 1.0

func _pick_route_mid(from: Vector3, to: Vector3) -> Vector3:
	var line_mid := from.lerp(to, _route_f)
	var perp := Vector3(-(to.z - from.z), 0.0, to.x - from.x)
	perp.y = 0.0
	if perp.length() < 0.01:
		return line_mid
	perp = perp.normalized() * _route_side
	# 从直线中段往侧翼一路探到底（越过中央方块、停在对面墙前），
	# 取"最远的那一格可走点"。这样中转点一定落在左右侧翼通道里；
	# 旧版固定偏移 7~14 米，经常整段落进中央方块，被 nav 吸到最近一格，
	# 两侧最后吸到同一处 —— 就是"总从同一边来"的根因。
	var best := line_mid
	var found := false
	var step := 2.0
	var k := 1
	while float(k) * step <= 34.0:
		var cand := line_mid + perp * (float(k) * step)
		if GM == null or GM.nav_is_free(cand):
			best = cand
			found = true
		elif found:
			break
		k += 1
	_route_off = best.distance_to(line_mid)
	return best


func _repath(to: Vector3) -> void:
	var d := to - global_position
	d.y = 0
	# 离得够远才值得绕（近身绕行只会显得发神经）
	if _route != 0 and _route_valid and d.length() > 8.0 and GM != null:
		var p1: PackedVector2Array = GM.nav_path(global_position, _route_wp)
		var p2: PackedVector2Array = GM.nav_path(_route_wp, to)
		if p1.size() > 1 and p2.size() > 1:
			var joined := PackedVector2Array()
			joined.append_array(p1)
			joined.append_array(p2)
			_nav_pts = joined
			_nav_i = 0
			return
	_nav_pts = GM.nav_path(global_position, to) if GM != null else PackedVector2Array()
	_nav_i = 0


# 返回"下一步该往哪走"的水平方向；没有路径时退回直线
func _dir_along_path(to: Vector3) -> Vector3:
	var want := to - global_position
	want.y = 0
	if want.length() < 0.01:
		return Vector3.ZERO
	want = want.normalized()
	if _nav_pts.is_empty():
		return want
	# 跳过已经走过的路点
	while _nav_i < _nav_pts.size():
		var p: Vector2 = _nav_pts[_nav_i]
		var d := Vector3(p.x, global_position.y, p.y) - global_position
		d.y = 0
		if d.length() < NAV_WP_DIST:
			_nav_i += 1
			continue
		return d.normalized()
	return want


func _update_stuck(delta: float) -> void:
	var here := global_position
	var moved := Vector2(here.x - _last_pos.x, here.z - _last_pos.z).length()
	_last_pos = here
	if moved < 0.02:
		_stuck_time += delta
		# 卡住超过 0.6 秒：换一侧绕，并立刻重算路径
		if _stuck_time > 0.6 and _side_step <= 0.0:
			_side_sign = 1.0 if randf() < 0.5 else -1.0
			_side_step = 0.8
			_stuck_time = 0.0
			_nav_cool = 0.0
	else:
		_stuck_time = 0.0
	if _side_step > 0.0:
		_side_step -= delta


# 各武器类别的"舒适交战距离"（米）。
#
# ★ 这只控制**移动**，不控制开火 ★
# 开火条件只有"有视线 + 过了反应延迟 + 在 sight_range 内"，一旦看见就能打
# （自检 --test-engage 实测：28m 对峙时第一次开火就在 27.6m）。
# 这个数值只回答"走到多近就不用再往前压了，改成走位对枪"。
const ENGAGE_RANGE := {
	"sniper": 22.0,    # 狙：远距离架枪
	"rifle": 13.0,
	"lmg": 15.0,
	"smg": 8.0,
	"shotgun": 5.0,
	"pistol": 7.0,
	"knife": 1.2,      # 刀只能贴身
}

# 超过"舒适距离"这么多倍才算"还太远"，需要一边打一边斜向推进；
# 在这个范围内就**原地走位**（左右横移）对枪，不再一路怼到脸上。
const CLOSE_IN_MULT := 1.5


func _engage_range() -> float:
	return float(ENGAGE_RANGE.get(_weapon_class(), 10.0))


# 交战走位状态。
# 真人躲子弹不只左右横移：还会**蹲下**缩小受弹面、偶尔**跳**一下换节奏。
# 三种动作轮流出现，按下面的概率抽（横移最常见）。
const DODGE_STRAFE := 0
const DODGE_CROUCH := 1
const DODGE_JUMP := 2

var _strafe_dir := 1.0      # 横移方向（+1 右 / -1 左）
var _dodge := DODGE_STRAFE  # 当前躲避动作
var _dodge_left := 0.0      # 当前动作剩余时间
var _dodge_cool := 0.0      # 两次动作之间的间隔
var _jump_pending := false  # 已经决定要跳，等落地那一刻执行


## 每个物理帧推进一次躲避动作状态机（只在交战时调用）
func _update_dodge(delta: float) -> void:
	_dodge_left = maxf(_dodge_left - delta, 0.0)
	if _dodge_left > 0.0:
		return
	if _dodge == DODGE_CROUCH:
		set_crouch(false)          # 蹲完站起来
		_dodge = DODGE_STRAFE
	_dodge_cool -= delta
	if _dodge_cool > 0.0:
		return
	_dodge_cool = randf_range(0.8, 2.0)
	var r := randf()
	if r < 0.55:
		_dodge = DODGE_STRAFE
		_dodge_left = randf_range(0.8, 1.6)
		_strafe_dir = 1.0 if randf() < 0.5 else -1.0
	elif r < 0.82:
		_dodge = DODGE_CROUCH
		_dodge_left = randf_range(0.45, 1.0)
		set_crouch(true)
	else:
		# 跳是"一次性"动作：置个待跳标记，落地那一刻在 chase() 里给竖直速度
		_dodge = DODGE_STRAFE
		_dodge_left = 0.30
		_strafe_dir = 1.0 if randf() < 0.5 else -1.0
		_jump_pending = true


## 统一的"给一个水平方向 → 施加速度 + move_and_slide"。
## face_movement=true 时转向行进方向（赶路用）；false 时**不改朝向**，
## 让 face_target() 设好的"面朝敌人"保持住 —— 横移走位时人是侧着挪、脸还朝着敌人的。
func _drive(dir: Vector3, spd: float, face_movement: bool, delta: float) -> void:
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length() < 0.01:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		d = d.normalized()
		if face_movement:
			rotation.y = lerp_angle(rotation.y, atan2(-d.x, -d.z), 0.35)
		velocity.x = d.x * spd
		velocity.z = d.z * spd
	velocity.y -= GRAVITY * delta
	move_and_slide()


# ---------------------------------------------------------------- 掩体利用 + peek 节奏
#
# 目标：bot 不再站在开阔地跟你硬换血，而是「躲到掩体后 → 探身打几枪 → 缩回去」。
#
# 状态机（只在"目标进入交战距离"后运行；目标没了 / 太远一律走 APPROACH）：
#   APPROACH  推进 / 找人（看不见时走 nav 找人；看得见但太远时斜向推进）
#   COVER     找一个"蹲着目标看不见自己"的点，走过去蹲好；躲够 _hide_left → PEEK
#   PEEK      站起来朝一侧横向探身；拿到视线 → FIRE；超时就换另一边再试
#   FIRE      有视线对枪（横移 / 蹲 / 跳）；打够 _fire_left → 回 COVER 重新找掩体
#
# 注意：**开火判定和这里完全无关**（在 _physics_process 里独立进行），
# 所以 COVER/PEEK 状态只是在决定"站哪、怎么动"，不会让 bot 白白不开枪。
const CS_APPROACH := 0
const CS_COVER := 1
const CS_PEEK := 2
const CS_FIRE := 3

const COVER_DIRS := 12                  # 找掩体时扫描的方向数
const COVER_RADII := [2.0, 3.2, 4.6]    # 候选掩体点的距离（米）
const COVER_SAMPLE_H := [0.95, 0.75]    # 判定"暴露"用的自身采样高度（蹲姿的头/胸）
const COVER_ARRIVE := 0.7               # 判定"已到达掩体点"的距离
const COVER_GIVEUP := 2.5               # 去掩体点的最长容忍时间（点不可达就放弃掩体）
const COVER_RESCAN := 0.4               # 找掩体的节流（一次扫描要几十条射线）
const COVER_AVOID_DIST := 1.8           # "换点"时避开旧掩体点的半径
const PEEK_MAX := 1.2                   # 单次探身的最长时长
const PEEK_SPEED := 0.6                 # 探身时的移速倍率
const FEINT_CHANCE := 0.25              # 这个概率的探身是"假动作"（只露一下不真打）
const RELOCATE_CHANCE := 0.45           # 对枪结束后换到另一个掩体点的概率

var _cs := CS_APPROACH
var _cover := Vector3.ZERO          # 掩体点（蹲在这里目标看不到）
var _cover_valid := false
var _cover_wait := 0.0              # 去掩体点的耗时（超 COVER_GIVEUP 就放弃）
var _cover_cool := 0.0              # 找掩体的节流计时
var _cover_avoid := Vector3.ZERO    # 换点时避开的旧掩体点
var _avoid_valid := false
var _hide_left := 0.0               # COVER 状态剩余躲藏时间
var _peek_left := 0.0               # PEEK 剩余时间
var _peek_sign := 1.0               # 探身方向
var _feint := false                 # 本次探身是不是"假动作"（只露身位骗枪，不开火）
var _fire_left := 0.0               # FIRE 剩余对枪时间


## 探身方向：左右交替（真人也是两边换着探），25% 概率连探同一侧
func _next_peek_sign() -> float:
	if randf() < 0.25:
		return _peek_sign
	return -_peek_sign


func _leave_cover() -> void:
	set_crouch(false)
	_cover_valid = false
	_cover_wait = 0.0
	# 进对枪阶段前把躲避动作重置，别带着躲掩体时的旧状态进去
	_dodge = DODGE_STRAFE
	_dodge_left = 0.0
	_dodge_cool = 0.0


## 从 cand 站着/蹲着能否被目标看到：头、胸两点各打一条射线，任一通就算暴露
func _is_exposed(cand: Vector3, tgt_eye: Vector3, space: PhysicsDirectSpaceState3D) -> bool:
	for h in COVER_SAMPLE_H:
		var q := PhysicsRayQueryParameters3D.create(cand + Vector3(0, h, 0), tgt_eye)
		q.exclude = [self]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or hit.get("collider") == target:
			return true
	return false


## 在周围扫一圈，找"蹲上去目标就看不见自己"的点，取最优。
## 采样高度用**蹲姿**（0.95/0.75）——因为躲进掩体后是蹲着的；
## 探身时站起来 + 横向移动自然就露出去了，不需要在这里保证"站着能看见"。
func _find_cover() -> bool:
	if target == null or GM == null:
		return false
	# 先按"避开旧掩体点"找；找不到就放宽条件（否则只有一处掩体时会退化成完全没掩体）
	if _avoid_valid and _scan_cover(true):
		return true
	return _scan_cover(false)


## 扫描一圈候选掩体点。use_avoid=true 时跳过靠近 _cover_avoid 的点（"换点"用）
func _scan_cover(use_avoid: bool) -> bool:
	var space := get_world_3d().direct_space_state
	var tgt_eye: Vector3 = target.global_position + Vector3(0, LOS_CHEST_Y, 0)
	var best := Vector3.ZERO
	var best_score := -INF
	var found := false
	for i in COVER_DIRS:
		var ang := TAU * float(i) / float(COVER_DIRS)
		for r in COVER_RADII:
			var cand: Vector3 = global_position + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
			if not GM.nav_is_free(cand):
				continue    # 走不过去的点（石块里 / 墙里）直接跳过
			if _is_exposed(cand, tgt_eye, space):
				continue
			# "换点"：避开刚用过的那个掩体点，逼它换个角度
			# （不这么做的话 bot 永远从同一个角探身，玩家架好枪就能一直蹲它）
			if use_avoid and _avoid_valid and cand.distance_to(_cover_avoid) < COVER_AVOID_DIST:
				continue
			# 打分：离自己越近越好；离目标太远扣分（探身要够得着）
			var d_self := global_position.distance_to(cand)
			var d_tgt := cand.distance_to(target.global_position)
			var score := -d_self - maxf(0.0, d_tgt - _engage_range() * CLOSE_IN_MULT) * 0.8
			if score > best_score:
				best_score = score
				best = cand
				found = true
	if found:
		_cover = best
		_avoid_valid = false   # 避开条件只用一次，下次重新随机
	return found


## 掩体状态机的状态转移（只改 _cs，不动位置）
func _advance_cover_state(delta: float, los: bool, dist: float) -> void:
	if target == null or dist > _engage_range() * CLOSE_IN_MULT:
		_leave_cover()
		_cs = CS_APPROACH
		return
	# ★ 长时间没视线 → 强制回去找人 ★
	# 躲掩体/探身期间本来就会短时丢视线（这是设计），但要是探了几轮都找不回来
	# （目标早走了），还继续躲就会变成"两边各自蹲着永远不见面"——实测能让一回合
	# 拖 79 秒不结束。所以超过 NO_LOS_ROUTE_GIVEUP 一律转回推进。
	if not los and _no_los_time > NO_LOS_ROUTE_GIVEUP:
		_leave_cover()
		_cs = CS_APPROACH
		return
	_cover_cool = maxf(_cover_cool - delta, 0.0)
	match _cs:
		CS_APPROACH:
			# ★ 只有"看得见"才开始找掩体 ★
			# 看不见就该继续推进找人；否则 bot 会在没交火的地方白白蹲着不动。
			if not los:
				return
			_cs = CS_COVER
			_cover_valid = false
			_cover_wait = 0.0
			_hide_left = randf_range(0.25, 0.9)
		CS_COVER:
			_feint = false        # 回到掩体就清掉假动作标记（否则会一直不开火）
			if not _cover_valid:
				if _cover_cool > 0.0:
					return
				_cover_cool = COVER_RESCAN
				if not _find_cover():
					# 周围没有可用掩体 → 就地走位对枪
					_cs = CS_FIRE
					_fire_left = randf_range(0.6, 1.4)
					return
				_cover_valid = true   # ★ 忘了这行的话 bot 永远"没掩体"，原地不动
				_cover_wait = 0.0
			if global_position.distance_to(_cover) < COVER_ARRIVE:
				set_crouch(true)              # 躲好：蹲下缩小受弹面
				_hide_left -= delta
				if _hide_left <= 0.0:
					_cs = CS_PEEK
					_peek_sign = _next_peek_sign()
					set_crouch(false)          # 站起来探身
					# 假动作：有一定概率只"露一下身位"骗对方开枪/暴露位置，
					# 缩回去之后还会换个掩体点 —— 这就是"假动作换点"。
					_feint = randf() < FEINT_CHANCE
					_peek_left = randf_range(0.25, 0.45) if _feint else PEEK_MAX
			else:
				_cover_wait += delta
				if _cover_wait > COVER_GIVEUP:
					# 掩体点走不到（隔墙 / 被卡）→ 放弃掩体，就地走位对枪
					_leave_cover()
					_cs = CS_FIRE
					_fire_left = randf_range(0.6, 1.4)
		CS_PEEK:
			_peek_left -= delta
			if los and not _feint:
				_cs = CS_FIRE
				_fire_left = randf_range(0.5, 1.4)
				_dodge = DODGE_STRAFE
				_dodge_left = 0.0
				_dodge_cool = 0.0
			elif _peek_left <= 0.0:
				if _feint:
					# 假动作做完：缩回去，并记住"这个点刚用过" → 下次换一个角
					_cover_avoid = _cover
					_avoid_valid = true
					_cover_valid = false
				else:
					# 这一侧探不出去 → 换另一边再试（不用重新找掩体点）
					_peek_sign = -_peek_sign
				_cs = CS_COVER
				_cover_wait = 0.0
				_hide_left = randf_range(0.2, 0.7)
		CS_FIRE:
			_fire_left -= delta
			if not los or _fire_left <= 0.0:
				# 目标躲起来了 / 打够了 → 重新找掩体换角度
				# 有概率强制"换点"：不这么做 bot 永远从同一个角探身，
				# 玩家架好枪就能一直蹲着它。
				if randf() < RELOCATE_CHANCE:
					_cover_avoid = _cover
					_avoid_valid = true
				_cs = CS_COVER
				_cover_valid = false
				_cover_wait = 0.0
				_hide_left = randf_range(0.25, 0.9)


## 推进 / 找人（原来的 chase 逻辑）
func _chase_approach(delta: float, flat_dir: Vector3, dist: float, spd: float, los: bool) -> void:
	if _dodge == DODGE_CROUCH:
		set_crouch(false)      # 赶路时别蹲着
		_dodge = DODGE_STRAFE
	if not los:
		if dist > 1.2:
			_nav_cool -= delta
			if _nav_cool <= 0.0:
				_nav_cool = NAV_REPATH
				_repath(target.global_position)
			var go := _dir_along_path(target.global_position)
			# 卡住时斜着绕一下（保留一点随机性，免得两个 bot 卡成对称死锁）
			if _side_step > 0.0:
				go = go.rotated(Vector3.UP, _side_sign * 0.6)
			_drive(go, spd, true, delta)
		else:
			_drive(Vector3.ZERO, 0.0, false, delta)
		return
	# 看得见但还太远 → 斜向推进（朝目标 0.85 + 横向 0.55），不是一条直线冲脸
	var right := transform.basis.x
	right.y = 0.0
	right = right.normalized()
	_drive(flat_dir.normalized() * 0.85 + right * _strafe_dir * 0.55, spd, false, delta)


## 去掩体点 / 蹲在掩体后
func _chase_cover(delta: float, flat_dir: Vector3, dist: float, spd: float) -> void:
	if not _cover_valid:
		# 掩体点还没定下来（或在等扫描节流）→ 先按对枪走位，别站着不动
		_chase_fire(delta, flat_dir, dist, spd)
		return
	if global_position.distance_to(_cover) < COVER_ARRIVE:
		_drive(Vector3.ZERO, 0.0, false, delta)   # 躲好，不动
	else:
		_move_to(_cover, delta)                   # 沿 nav 走过去


## 横向探身
func _chase_peek(delta: float, spd: float) -> void:
	var right := transform.basis.x
	right.y = 0.0
	right = right.normalized()
	_drive(right * _peek_sign, spd * PEEK_SPEED, false, delta)


## 有视线对枪：横移 / 蹲 / 跳
func _chase_fire(delta: float, flat_dir: Vector3, dist: float, spd: float) -> void:
	var right := transform.basis.x
	right.y = 0.0
	right = right.normalized()
	if _dodge == DODGE_CROUCH:
		_drive(Vector3.ZERO, 0.0, false, delta)   # 蹲着不动，缩小受弹面
	else:
		_drive(right * _strafe_dir, spd * 0.85, false, delta)
	# 跳：必须在 move_and_slide 之后再给竖直速度，否则会被 _drive 里的重力/清零吃掉
	if _jump_pending and is_on_floor():
		velocity.y = JUMP_VELOCITY
		_jump_pending = false


func chase(delta: float) -> void:
	_update_stuck(delta)
	_update_route(delta, target.global_position)
	var flat_dir := target.global_position - global_position
	flat_dir.y = 0.0
	var dist := flat_dir.length()
	var spd := _move_speed()
	var los := _has_los()
	# 长时间看不见目标 → 放弃侧翼绕行，直接怼过去。
	# 不这么做的话，两队各自按 _route 绕侧翼会互相错开：实测 8v8 打到残局 2v1 时，
	# 双方能各自绕 30 多秒谁也见不到谁（玩家看到的就是"剩下的 bot 在地图上瞎逛、
	# 回合一直不结束"）。
	if los:
		_no_los_time = 0.0
	else:
		_no_los_time += delta
		if _no_los_time > NO_LOS_ROUTE_GIVEUP:
			_route = 0
			_route_valid = false
			_route_left = 0.0
			_route_cool = 1.0   # 每帧压住，避免 _update_route 又挑一条侧翼路线

	_advance_cover_state(delta, los, dist)
	# 躲避动作（横移/蹲/跳）只在"对枪"阶段推进：
	# 躲掩体、探身的姿态由状态机自己管（一个要蹲、一个要站），这里再插一脚会互相打架。
	if _cs == CS_FIRE:
		_update_dodge(delta)
	if _side_step > 0.0:
		_strafe_dir = _side_sign   # 卡墙时按绕行方向走
	match _cs:
		CS_COVER:
			_chase_cover(delta, flat_dir, dist, spd)
		CS_PEEK:
			_chase_peek(delta, spd)
		CS_FIRE:
			_chase_fire(delta, flat_dir, dist, spd)
		_:
			_chase_approach(delta, flat_dir, dist, spd, los)
	_try_play_anim("Walk")
	_footstep(delta)


func wander(delta: float) -> void:
	_update_stuck(delta)
	# 随机游走：挑一个可走点走过去，避免原地站桩
	# （不再用"随机方向直冲"，那个一样会怼在墙上抽搐）
	_wander_timer -= delta
	var reached := global_position.distance_to(_wander_goal) < 1.5
	if not _wander_goal_set or _wander_timer <= 0.0 or reached:
		_wander_timer = randf_range(4.0, 8.0)
		_wander_goal = GM.nav_random_point() if GM != null else global_position
		_wander_goal_set = true
		_nav_cool = 0.0
	_nav_cool -= delta
	if _nav_cool <= 0.0:
		_nav_cool = NAV_REPATH
		_repath(_wander_goal)
	var go := _dir_along_path(_wander_goal)
	if go.length() < 0.01:
		go = -transform.basis.z
		go.y = 0
		go = go.normalized()
	if _side_step > 0.0:
		go = go.rotated(Vector3.UP, _side_sign * 0.6)
	var desired := atan2(-go.x, -go.z)
	rotation.y = lerp_angle(rotation.y, desired, 0.35)
	var spd := _move_speed() * 0.45
	velocity.x = go.x * spd
	velocity.z = go.z * spd
	velocity.y -= GRAVITY * delta
	move_and_slide()
	_try_play_anim("Walk")
	_footstep(delta)


var _wander_goal := Vector3.ZERO
var _wander_goal_set := false
var _wander_timer := 0.0


func get_current_id() -> String:
	var w: Dictionary = weapons.get(active_slot, {})
	return w.get("id", "Knife") if not w.is_empty() else "Knife"
