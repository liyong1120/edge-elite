extends Node

## 对局总体（GM 自动加载）：菜单 / 建地图 / 建玩家与bot / 回合与爆炸 / HUD / 购物 / bot动态增减

const SoundFXScript := preload("res://scripts/soundfx.gd")
# C4 爆炸音效：素材库里一直有 explode.wav，但之前**从未被使用**（爆炸只有 _end_round）
const SND_EXPLODE := preload("res://sounds/explode.wav")
enum STATE { MENU, BUY, LIVE, OVER }

# ---------------------------------------------------------------- 游戏标识
# ★ 改游戏名只需要改这两行 ★
#   （窗口标题在 project.godot 的 config/name，那是引擎配置、脚本读不到）
# 游戏名 / 阵营名 / 所有界面文案 → scripts/ui_text.gd
# 所有界面配色                        → scripts/ui_theme.gd
const MENU_BG_PATH := "res://resources/menu_bg.png"

const MAX_ROUNDS := 5        # 一局最多打几个回合（兜底，防止无限拖）
const WIN_ROUNDS := 5        # 先赢够这么多回合就赢下整场（顶部计分板中间显示的就是它）
const MAX_TEAM_PLAYERS := 8  # 每队人数上限（含人类玩家）

# ---------------------------------------------------------------- 阵营（点自己的东西，不叫 CT / T）
# ★ 想换阵营名 / 配色，**只改这一张表** ★（下面 team_name / team_full / team_color 会自动跟着变）
#   内部 id 仍然是 "CT" / "T"：几十处游戏逻辑（出生点、A* 寻路、bot 组队、回合判定、
#   player.team）都依赖这两个字符串，改 id 风险大而玩家根本看不到。
#     name  = 短名（顶部比分条）
#     full  = 全名（Tab 计分板 / 房间名册）
#     color = 阵营色（比分条 / 计分板 / 名册 / 缩略图出生点）
# 阵营短名（比分条）—— 名字在 ui_text.gd
func team_name(team: String) -> String:
	return String(UIText.TEAM_NAME.get(team, team))


# 阵营全名（计分板 / 房间名册）
func team_full(team: String) -> String:
	return String(UIText.TEAM_NAME_FULL.get(team, team))


# 阵营色（比分条 / 计分板 / 名册 / 出生点）—— 颜色在 ui_theme.gd
func team_color(team: String) -> Color:
	var c: Color = UITheme.TEAM_COLOR.get(team, Color.WHITE)
	return c
const BUY_TIME := 10.0
const ROUND_TIME := 180.0
const BOMB_TIME := 40.0
const PLANT_TIME := 3.0
const DEFUSE_TIME := 10.0
const DEFUSE_KIT_TIME := 5.0

var bombsite_a := Vector3(-16, 0, -20)
var bombsite_b := Vector3(16, 0, -20)

# 地图库：id -> 名称 / 描述 / 预览色
# 地图库：id -> 名称 / 描述（文字在 ui_text.gd）/ 预览色
var MAP_INFO := {
	"iceworld": {"name": UIText.MAP_NAME["iceworld"], "desc": UIText.MAP_DESC["iceworld"],
		"preview": Color(0.82, 0.76, 0.63)},
}

var players: Array[CSPlayer] = []       # Array[CSPlayer]
var player: CSPlayer          # 人类控制
var bots: Array[CSPlayer] = []          # Array[CSPlayer]

var round_num := 1
var ct_wins := 0
var t_wins := 0
var state: int = STATE.MENU
var timer := 0.0

var bomb_planted := false
var bomb_pos := Vector3.ZERO
var bomb_timer := 0.0
var plant_progress := 0.0
var defuse_progress := 0.0
var bomb_holder: CSPlayer
var has_bomb_bot_planted := false

var hud_root: Control
var buy_menu: Control
# 已取消独立「开始菜单」：打开游戏直接就是局域网大厅（界面1）。
# 人机难度选择下放到界面2（房间界面）。
var lan: LanNet              # 局域网：房间发现 + 连接
var center_msg: Label
var hud_ammo: Label
var hud_status: Label
var hud_score: Label
var hud_time: Label
var help_label: Control
var hud_toast: Label
var _toast_tween: Tween
var minimap: Control
# 顶部中央比分条（CF 风格）
var hud_score_ct_head: Label
var hud_score_t_head: Label
var hud_score_ct: Label
var hud_score_total: Label
var hud_score_t: Label
# 屏幕中下动作进度条（换弹/安装/拆除 C4 通用）
var hud_progress: ProgressBar
var hud_progress_label: Label
var crosshair_layer: CanvasLayer
var crosshair_control: Control
var kill_feed: VBoxContainer
var kill_notice: TextureRect
var _snd_kill: AudioStreamPlayer

# 计分板相关
var scoreboard: Control
var scoreboard_visible := false
var scoreboard_t_container: VBoxContainer
var scoreboard_ct_container: VBoxContainer
var scoreboard_score: Label            # 计分板顶部总比分
var scoreboard_t_title: Label          # T 队"X 胜"
var scoreboard_ct_title: Label         # CT 队"X 胜"

var t_spawns: Array[Vector3] = []
var ct_spawns: Array[Vector3] = []

var buy_menu_visible := false
# 玩家昵称（大厅输入框填的）。创建房间时房间名 = "<昵称> 的房间"，
# 房间名册 / Tab 计分板 / 击杀信息流都用它。
var player_nick := UIText.LOBBY_NICK_FMT % randi_range(100, 999)   # 玩家 + 3 位随机数字
var _peer_nicks: Dictionary = {}     # 对端 id -> 昵称（客户端连上后自己上报）
# ★ 阵营由真人自己在房间里选 ★
#   local_team  = 本机玩家的阵营（单机 / 客户端直接用它）
#   _peer_teams = 对端 id -> 阵营。**房主是唯一权威**：谁换了阵营都走房主改 + 广播，
#                 否则每台机器各算各的，名册会对不上。
# 默认磐垒（= 以前的固定行为：本机玩家一直在 CT 列），选了别的队才变
var local_team := "CT"
var _peer_teams: Dictionary = {}
var bot_difficulty := 1  # 0=简单 1=普通 2=困难
var diff_buttons: Array[Button] = []   # 人机难度分段控件（现在在界面2 房间界面上）
var game_over_menu: Control
# 整场结束面板：显示哪一方最终胜利 + 比分，停留几秒后自动回房间界面
var game_over_winner: Label
var game_over_score: Label
var game_over_hint: Label
var _match_over_pending := false      # 结束面板正在倒计时（防"倒计时"和"手动点按钮"重复返回）
const GAME_OVER_HOLD := 4.0           # 结果停留秒数
var pause_menu: Control
var _paused := false
# 地图选择相关
var selected_map := "iceworld"
var map_root: Node3D
var map_select_menu: Control        # 界面2：房间界面（成员 / 难度 / 选图）
var map_pick: OptionButton          # 地图下拉框
var map_ids: Array[String] = []     # 下拉框 index → 地图 id
var map_desc_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_setup")


func _setup() -> void:
	# ---- 工具模式：只跑武器图标渲染，不构建游戏场景 ----
	# 构建整套地图 + 16 个角色要几十秒且吃显存，图标工具完全用不上，直接提前返回。
	for arg in OS.get_cmdline_args():
		if arg == "--gen-weapon-icons":
			var tool := WeaponIcons.new()
			add_child(tool)
			tool.render_all()
			return
	# 初始化配置管理器
	ConfigManager.new()
	# 局域网：房间发现（UDP 广播）+ ENet 连接。常驻监听，进大厅就能看到房间
	lan = LanNet.new()
	lan.name = "LanNet"
	add_child(lan)
	# 有玩家连进来 → 位置不够就踢一个 bot 腾地方（CS 的做法）
	multiplayer.peer_connected.connect(_on_peer_connected)
	# 有玩家断开（含被房主踢掉）→ 房间界面的名册要立刻刷新
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	# 客户端连上房主后，把自己的昵称报上去（房主的名册才显示真名而不是"玩家 2"）
	multiplayer.connected_to_server.connect(_send_nick)
	# 读取上次选择的人机难度（存 user://config.toml，重启后保留）
	if ConfigManager.instance != null:
		bot_difficulty = ConfigManager.instance.get_bot_difficulty()
	var scene := get_tree().current_scene
	# 地图根节点：切换地图时整体清空重建
	map_root = Node3D.new()
	map_root.name = "MapRoot"
	scene.add_child(map_root)
	_add_environment(scene)
	# 先算出出生点，地图里的"出生点面前摆枪"要用到
	_build_spawns()
	_build_map(selected_map)
	_build_nav_grid()
	_build_players(scene)
	_build_hud(scene)
	_build_buy_menu(scene)
	_build_lan_menu(scene)
	_build_map_select_menu(scene)
	_setup_net_sync()
	_build_game_over_menu(scene)
	_build_pause_menu(scene)
	_build_crosshair(scene)
	# 开局不开回合：打开游戏**直接停在局域网大厅（界面1）**，没有独立开始菜单
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_open_lan_lobby()
	# 菜单里不该有角色在场上走动 / 有枪声脚步（用户反馈"还能听到游戏里的声音"）
	_set_world_active(false)

	# cmdline 触发截图模式（用于冰岛图调试）：跑 2.5 秒后截两张图（Fpv + 顶视）后退出
	for arg in OS.get_cmdline_args():
		if arg == "--screenshot-iceworld":
			_schedule_iceworld_screenshot()
			break
		if arg == "--test-pickup":
			_test_pickup_system()
			break
		if arg == "--test-bolt":
			_test_bolt()
			break
		if arg == "--test-difficulty":
			_test_difficulty()
			break
		if arg == "--dump-guns":
			_dump_gun_nodes()
			break
		if arg == "--screenshot-ui":
			_schedule_ui_screenshot()
			break
		if arg == "--screenshot-minimap":
			_schedule_minimap_screenshot()
			break
		if arg == "--screenshot-killfeed":
			_schedule_killfeed_screenshot()
			break
		if arg == "--test-walk":
			_test_walk()
			break
		if arg == "--test-nav":
			_test_nav()
			break
		if arg == "--test-roundend":
			_test_roundend()
			break
		if arg == "--test-botroute":
			_test_botroute()
			break
		if arg == "--test-buykill":
			_test_buykill()
			break
		if arg == "--dump-weapons":
			_dump_weapons()
			break
		if arg == "--screenshot-crosshair":
			_schedule_crosshair_screenshot()
			break
		if arg == "--screenshot-blood":
			_schedule_blood_screenshot()
			break
		if arg == "--screenshot-corpse":
			_schedule_corpse_screenshot()
			break
		if arg == "--test-botdiag":
			_test_botdiag()
			break
		if arg == "--test-killfeed":
			_test_killfeed()
			break
		if arg == "--test-botmatch":
			_test_botmatch()
			break
		if arg == "--test-botpickup":
			_test_botpickup()
			break
		if arg == "--test-engage":
			_test_engage()
			break
		if arg == "--test-botgun":
			_test_botgun()
			break
		if arg == "--test-los":
			_test_los()
			break
		if arg == "--test-cover":
			_test_cover()
			break
		if arg == "--test-sound":
			_test_sound()
			break
		if arg == "--test-hearing":
			_test_hearing()
			break
		if arg == "--test-lan":
			_test_lan()
			break
		if arg == "--screenshot-lan":
			_schedule_lan_screenshot()
			break
		if arg == "--screenshot-credits":
			_schedule_credits_screenshot()
			break
		if arg == "--diag-move":
			_diag_move()
			break
		if arg == "--lan-host":
			_lan_autotest_host()
			break
		if arg == "--lan-client":
			_lan_autotest_client()
			break


# 准星调试截图（跑法：godot --path <项目> --screenshot-crosshair）
# 三种状态各截一张：步枪（有准星）/ 狙击未开镜（无准星）/ 狙击开镜（镜内十字）
func _schedule_crosshair_screenshot() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	if minimap != null:
		minimap.visible = false
	if hud_root != null:
		hud_root.visible = false      # 只隐藏 HUD，准星在独立 CanvasLayer 上不受影响
	await get_tree().create_timer(1.0).timeout
	if player == null:
		get_tree().quit()
		return
	var cases: Array = [
		["AK47", false, "步枪"],
		["AWP", false, "狙击未开镜"],
		["AWP", true, "狙击开镜"],
	]
	for cs in cases:
		player.give_weapon(1, str(cs[0]))
		player._switch_slot(1)
		player._set_scope(false)
		await get_tree().create_timer(0.15).timeout
		if bool(cs[1]):
			player._set_scope(true)
		await get_tree().create_timer(0.35).timeout
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(_shot_dir() + "准星_%s.png" % str(cs[2]))
		print("[Screenshot] Crosshair saved: ", cs[2])
	get_tree().quit()


# 诊断：打印各枪械"实际生效"的属性与后坐力推算
# 跑法：godot --headless --path <项目> --dump-weapons
func _dump_weapons() -> void:
	var mult := 1.0
	if ConfigManager.instance != null:
		mult = float(ConfigManager.instance.get_weapon_global("recoil_multiplier", 1.0))
	print("recoil_multiplier = ", mult,
			"   （散布上限 %.3f rad ≈ %.1f°）" % [CSPlayer.RECOIL_MAX,
			rad_to_deg(CSPlayer.RECOIL_MAX * CSPlayer.RECOIL_SPREAD)])
	print("%-9s %-8s %6s %5s %5s %8s %9s %9s %8s" % [
			"武器", "类别", "伤害", "RPM", "弹匣", "每发后坐", "首发散度", "满散锥度", "顶满(s)"])
	var p := CSPlayer.new()
	var all := WeaponDatabase.weapons()
	for wid: String in all:
		var spec: Dictionary = all[wid]
		var cls: String = str(spec.get("class", ""))
		if cls == "knife":
			continue
		var eff := p._effective_spec(wid, spec)
		var r := p._recoil_add(eff)
		var rate := float(eff.get("fire_rate", 400)) / 60.0
		# 连发平衡点 = 每秒累积 - 每秒衰减（站定 0.10/s）；>0 才会越打越散
		var net := rate * r - CSPlayer.RECOIL_DECAY_STILL
		var t_max := (CSPlayer.RECOIL_MAX / net) if net > 0.0001 else -1.0
		var extra := float(eff.get("spread", 0.0))
		print("%-9s %-8s %6d %5d %5d %8.4f %9s %9.1f° %8s" % [
				wid, cls, int(eff.get("damage", 0)), int(eff.get("fire_rate", 0)),
				int(eff.get("mag", 0)), r,
				"%.1f°" % rad_to_deg(extra),
				rad_to_deg(CSPlayer.RECOIL_MAX * CSPlayer.RECOIL_SPREAD),
				("-" if t_max < 0.0 else "%.2f" % t_max)])
	p.free()
	print("\n说明：首发散度 = 第一发（不吃后坐力）的固定散布；")
	print("      顶满(s) = 连续扫射多久达到最大散布锥；\"-\" 表示永远到不了（可控）。")

	# 连发散布序列：模拟 fire() 的累积顺序（**先射击、后累加**）
	# 第 1 列必须是 0.0° —— 这就是"AWP 开镜首发必中"的证明
	print("\n连发散布序列（每发开火瞬间的散布半角，度）：")
	var p2 := CSPlayer.new()
	for wid: String in ["AK47", "M4A1", "M249", "MP5", "P90", "Deagle", "AWP"]:
		var spec2: Dictionary = all.get(wid, {})
		if spec2.is_empty():
			continue
		var eff2 := p2._effective_spec(wid, spec2)
		var r2 := p2._recoil_add(eff2)
		var dt := 60.0 / float(eff2.get("fire_rate", 400))
		var rc := 0.0
		var seq := ""
		for i in 8:
			seq += "%7.2f" % rad_to_deg(rc * CSPlayer.RECOIL_SPREAD)
			rc = minf(rc + r2, CSPlayer.RECOIL_MAX)
			rc = maxf(rc - dt * CSPlayer.RECOIL_DECAY_STILL, 0.0)
		print("%-8s%s" % [wid, seq])
	p2.free()
	get_tree().quit()


# 确保截图目录存在（用户可能手动清理掉 screenshots/），返回带斜杠的目录前缀
func _shot_dir() -> String:
	if DirAccess.open("res://screenshots") == null:
		DirAccess.make_dir_recursive_absolute("res://screenshots")
	return "res://screenshots/"


# 诊断：打印武器 GLB 的节点树 / 包围盒（跑法：godot --headless --path <项目> --dump-guns）
func _dump_gun_nodes() -> void:
	for wid: String in ["AK47", "MP5", "AWP", "Deagle", "M249"]:
		var path: String = "res://models/fpv/" + wid + ".glb"
		if not ResourceLoader.exists(path):
			print("--- ", wid, " 缺失"); continue
		var ps: PackedScene = load(path)
		var root: Node3D = ps.instantiate()
		print("\n=== ", wid, " ===")
		_dump_node(root, 0, Transform3D.IDENTITY)
		root.free()
	get_tree().quit()


func _dump_node(n: Node, depth: int, xf: Transform3D) -> void:
	var pad := "  ".repeat(depth)
	if n is Node3D and depth > 0:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var bb: AABB = mi.mesh.get_aabb() if mi.mesh != null else AABB()
		print(pad, mi.name, " size=", bb.size, " center=", bb.get_center(),
				" worldCenter=", xf * bb.get_center())
	else:
		print(pad, n.name, " (", n.get_class(), ")")
	for c in n.get_children():
		_dump_node(c, depth + 1, xf)


# 捡枪/丢枪自检（跑法：godot --path <项目> --test-pickup）
func _test_pickup_system() -> void:
	var fails := 0

	var p := CSPlayer.new()
	p.weapons = {1: {}, 2: {"id": "USP", "mag": 12, "reserve": 100}, 3: {"id": "Knife"}, 4: {}}
	p.active_slot = 2
	p._update_slots()

	if p.pickup_weapon("AK47") and p.weapons[1].get("id", "") == "AK47":
		print("[OK] 捡到 AK47 → 槽1，active_slot=", p.active_slot)
	else:
		print("[FAIL] 捡 AK47 失败"); fails += 1

	# 已有主武器时**不能再捡**（用户报的 BUG）
	if p.pickup_weapon("M4A1"):
		print("[FAIL] 已有主武器还能再捡 M4A1（BUG 未修）"); fails += 1
	else:
		print("[OK] 已有主武器时正确拒绝捡 M4A1")

	# 已有同一把也不能重复捡
	if p.pickup_weapon("AK47"):
		print("[FAIL] 重复捡同一把 AK47"); fails += 1
	else:
		print("[OK] 重复捡同一把 AK47 被拒绝")

	# 手枪不受限（但同一把不重复）
	if p.pickup_weapon("Deagle") and p.weapons[2].get("id", "") == "Deagle":
		print("[OK] 捡手枪 Deagle → 槽2")
	else:
		print("[FAIL] 捡手枪 Deagle 失败"); fails += 1

	p._switch_slot(1)
	var dropped := p.drop_current()
	if dropped == "AK47" and p.weapons[1].is_empty():
		print("[OK] 按 G 丢掉 AK47")
	else:
		print("[FAIL] 丢 AK47 失败，dropped=", dropped); fails += 1

	if p.pickup_weapon("AK47") and p.weapons[1].get("id", "") == "AK47":
		print("[OK] 丢枪后可再捡回")
	else:
		print("[FAIL] 丢枪后无法捡回"); fails += 1

	p._switch_slot(3)
	if p.drop_current() == "":
		print("[OK] 刀不可丢弃")
	else:
		print("[FAIL] 刀被丢掉了"); fails += 1

	# 端到端：地图上的 16 个掉落物都是合法武器 id
	var picks := get_tree().get_nodes_in_group("weapon_pickups")
	if picks.size() == 16:
		print("[OK] 地图上共 16 把出生点武器")
	else:
		print("[FAIL] 出生点武器数量 = ", picks.size(), "（期望 16）"); fails += 1
	var bad := 0
	for pk in picks:
		if not WeaponDatabase.weapons().has(pk.weapon_id):
			bad += 1
	if bad == 0:
		print("[OK] 掉落物武器 id 全部合法")
	else:
		print("[FAIL] 有 %d 个掉落物武器 id 非法" % bad); fails += 1

	# 模拟"捡走几把 → 回合刷新 → 又回到 16 把"
	if picks.size() >= 3:
		for i in 3:
			picks[i].queue_free()
		_respawn_spawn_weapons()
		var after := get_tree().get_nodes_in_group("weapon_pickups")
		if after.size() == 16:
			print("[OK] 回合刷新后出生点武器恢复 16 把")
		else:
			print("[FAIL] 回合刷新后数量 = ", after.size(), "（期望 16）"); fails += 1
		var bad2 := 0
		for pk in after:
			if not pk.is_spawn:
				bad2 += 1
		if bad2 == 0:
			print("[OK] 刷新出的武器全部标记为出生点配枪")
		else:
			print("[FAIL] 有 %d 把刷新武器未标记 is_spawn" % bad2); fails += 1

	# ---- 小墙几何：中间墙紧贴大围墙内表面、与上下墙首尾相接、两段和 = 围墙到石块距离
	# 围墙厚度 t=1.0 → 内表面在 ∓ICE_HALF_X(=18.0)；石块外沿 ∓11.5
	var wall_inner := ICE_HALF_X                        # 18.0
	var stone_edge := 6.25 + BLOCK_W * 0.5              # 11.5
	var mid_out := absf(MID_WALLS[0].x) + WALL_L * 0.5  # 中间墙靠围墙那一端 → 应 = 18.0
	var mid_in := absf(MID_WALLS[0].x) - WALL_L * 0.5   # 中间墙靠场心那一端 → 应 = 14.75
	var sml_out := absf(SMALL_WALLS[0].x) + WALL_L * 0.5  # 上下墙靠围墙那一端 → 应 = 14.75
	var sml_in := absf(SMALL_WALLS[0].x) - WALL_L * 0.5   # 上下墙靠石块那一端 → 应 = 11.5
	if absf(mid_out - wall_inner) < 0.001:
		print("[OK] 中间小墙紧贴大围墙内表面（%.3f，零空隙）" % mid_out)
	else:
		print("[FAIL] 中间小墙与围墙有空隙：%.3f vs %.3f" % [mid_out, wall_inner]); fails += 1
	if absf(sml_in - stone_edge) < 0.001:
		print("[OK] 上下小墙外沿与石块边共线（%.3f）" % sml_in)
	else:
		print("[FAIL] 上下小墙未贴石块：%.3f vs %.3f" % [sml_in, stone_edge]); fails += 1
	if absf(mid_in - sml_out) < 0.001:
		print("[OK] 中间小墙与上下小墙首尾相接（%.3f）" % mid_in)
	else:
		print("[FAIL] 中间/上下小墙未相接：%.3f vs %.3f" % [mid_in, sml_out]); fails += 1
	if absf((mid_out - mid_in + sml_out - sml_in) - (wall_inner - stone_edge)) < 0.001:
		print("[OK] 两段之和 = 大围墙到石块边距离（%.2fm）" % (wall_inner - stone_edge))
	else:
		print("[FAIL] 两段之和 != 围墙到石块距离"); fails += 1

	# ---- 丢枪防"秒捡回"：丢出距离 > 检测半径，且有落地保护
	if DROP_DIST > 1.05:
		print("[OK] 丢枪距离 %.1fm > 检测半径 1.05m" % DROP_DIST)
	else:
		print("[FAIL] 丢枪距离 %.1fm 未超过检测半径 1.05m" % DROP_DIST); fails += 1
	var pk_test := WeaponPickup.new()
	pk_test.weapon_id = "AK47"
	pk_test.arm_delay = 5.0
	map_root.add_child(pk_test)
	if not pk_test._armed:
		print("[OK] 落地保护期内不可被捡（arm_delay=%.1fs）" % pk_test.arm_delay)
	else:
		print("[FAIL] 落地保护未生效"); fails += 1
	pk_test.queue_free()

	p.free()
	print("\n==== 捡枪/丢枪自检 %s（失败 %d 项）====" %
			["全部通过" if fails == 0 else "有失败", fails])
	get_tree().quit(1 if fails > 0 else 0)


# AWP / Scout 拉栓 + 自动退镜自检（跑法：godot --path <项目> --test-bolt）
func _test_bolt() -> void:
	var fails := 0
	state = STATE.LIVE   # 绕过"菜单/回合结束不能开火"的守卫
	var p := CSPlayer.new()
	p.weapons = {1: {"id": "AWP", "mag": 10, "reserve": 30}, 2: {},
			3: {"id": "Knife"}, 4: {}}
	p.active_slot = 1
	p._update_slots()

	# 1) 开镜
	p._set_scope(true)
	if p._zoom:
		print("[OK] AWP 可以开镜")
	else:
		print("[FAIL] AWP 开镜失败"); fails += 1

	# 2) 开枪 → 自动退镜
	p._next_fire = 0.0
	p.fire()
	if p._zoom:
		print("[FAIL] AWP 开枪后没有自动退镜"); fails += 1
	else:
		print("[OK] AWP 开枪后自动退镜")

	# 3) 进入拉栓硬直
	if p.bolt_progress >= 0.0 and p._bolt_until > 0.0:
		print("[OK] 开枪后进入拉栓硬直（BOLT_TIME=%.1fs）" % CSPlayer.BOLT_TIME)
	else:
		print("[FAIL] 开枪后没有进入拉栓"); fails += 1

	# 4) 拉栓期间无法开下一发
	var mag_a := int(p.weapons[1].get("mag", 0))
	p._next_fire = 0.0
	p.fire()
	if int(p.weapons[1].get("mag", 0)) == mag_a:
		print("[OK] 拉栓期间无法开下一发（当前剩 %d 发）" % mag_a)
	else:
		print("[FAIL] 拉栓期间还能开火"); fails += 1

	# 5) 拉栓期间可以重新开镜（提前准备好下一发）
	p._set_scope(true)
	if p._zoom:
		print("[OK] 拉栓期间可以重新开镜")
	else:
		print("[FAIL] 拉栓期间无法重新开镜"); fails += 1

	# 5b) 拉栓期间手动开镜后，拉栓结束不再自动开镜（尊重手动意图）
	p._bolt_until = 0.0
	p.tick_bolt()
	if p.bolt_progress < 0.0:
		print("[OK] 拉栓结束（手动开镜时不会重复开镜）")
	else:
		print("[FAIL] 拉栓进度未清零"); fails += 1

	# 6) 拉栓结束后可以开下一发
	p._next_fire = 0.0
	p.fire()
	if int(p.weapons[1].get("mag", 0)) == mag_a - 1:
		print("[OK] 拉栓结束后可开下一发")
	else:
		print("[FAIL] 拉栓结束后仍无法开火"); fails += 1

	# 6b) 开镜状态开枪 → 拉栓跑完自动重新开镜（CF 手感）
	p._bolt_until = 0.0
	p.bolt_progress = -1.0
	p._rescope_pending = false
	p._set_scope(true)
	p._next_fire = 0.0
	p.fire()                      # 开枪：应退镜 + 记下"待自动开镜"
	if p._zoom:
		print("[FAIL] 开枪后没有退镜"); fails += 1
	if not p._rescope_pending:
		print("[FAIL] 未记下自动开镜待办"); fails += 1
	p._bolt_until = 0.0           # 模拟拉栓跑完
	p.tick_bolt()
	if p._zoom:
		print("[OK] 拉栓结束后自动重新开镜（CF 手感）")
	else:
		print("[FAIL] 拉栓结束后没有自动开镜"); fails += 1

	# 6c) 未开镜开枪 → 拉栓结束不自动开镜
	p._bolt_until = 0.0
	p.bolt_progress = -1.0
	p._set_scope(false)
	p._rescope_pending = false
	p._next_fire = 0.0
	p.fire()
	p._bolt_until = 0.0
	p.tick_bolt()
	if not p._zoom:
		print("[OK] 未开镜开枪时拉栓结束不会自动开镜")
	else:
		print("[FAIL] 未开镜开枪却自动开镜了"); fails += 1

	# 7) 非栓动武器（AUG 也有镜）不应自动退镜
	p.weapons[1] = {"id": "AUG", "mag": 30, "reserve": 90}
	p.active_slot = 1
	p._bolt_until = 0.0
	p.bolt_progress = -1.0
	p._next_fire = 0.0
	p._set_scope(true)
	p.fire()
	if p._zoom:
		print("[OK] 非栓动武器（AUG）开枪后保持开镜")
	else:
		print("[FAIL] AUG 被误判成栓动狙，开枪后错误退镜"); fails += 1
	p._set_scope(false)

	# 7b) 狙击枪未开镜无准星；开镜 / 非狙击枪都要有准星
	p.weapons[1] = {"id": "AWP", "mag": 10, "reserve": 30}
	p.active_slot = 1
	if p.is_unscoped_sniper():
		print("[OK] AWP 未开镜 → 不显示准星")
	else:
		print("[FAIL] AWP 未开镜仍有准星"); fails += 1
	p._set_scope(true)
	if not p.is_unscoped_sniper():
		print("[OK] AWP 开镜后 → 恢复准星判定")
	else:
		print("[FAIL] AWP 开镜后仍判定为无准星"); fails += 1
	p._set_scope(false)
	p.weapons[1] = {"id": "AK47", "mag": 30, "reserve": 90}
	if not p.is_unscoped_sniper():
		print("[OK] 步枪（AK47）任何状态都有准星")
	else:
		print("[FAIL] 步枪被误判成狙击枪"); fails += 1

	# 8) 复活 / 死亡会清掉拉栓状态
	p.weapons[1] = {"id": "AWP", "mag": 10, "reserve": 30}
	p.active_slot = 1
	p._bolt_until = Time.get_ticks_msec() / 1000.0 + 5.0
	p.bolt_progress = 0.5
	p._rescope_pending = true
	p.revive()
	if p._bolt_until == 0.0 and p.bolt_progress < 0.0 and not p._rescope_pending:
		print("[OK] 复活清空拉栓/自动开镜状态")
	else:
		print("[FAIL] 复活后拉栓状态残留"); fails += 1

	p.free()
	print("\n==== AWP 拉栓/自动退镜自检 %s（失败 %d 项）====" %
			["全部通过" if fails == 0 else "有失败", fails])
	get_tree().quit(1 if fails > 0 else 0)


# 人机难度自检（跑法：godot --path <项目> --test-difficulty）
func _test_difficulty() -> void:
	var fails := 0
	var b := GBot.new()
	var prev_near := -1.0
	var prev_far := -1.0
	var prev_head := -1.0
	var prev_interval := 999.0
	var prev_reaction := 999.0
	var prev_sight := 0.0
	var prev_speed := 0.0
	print("%-4s %-6s %8s %8s %9s %8s %9s %8s %9s" % [
			"档位", "名称", "近距命中", "远距命中", "开火间隔", "爆头率", "反应(s)", "交战(m)", "速度×"])
	for d in [0, 1, 2]:
		_set_difficulty(d)
		if bot_difficulty != d:
			print("[FAIL] _set_difficulty(%d) 未写入 bot_difficulty" % d); fails += 1
		var st: Dictionary = b._difficulty_stats()
		var near := float(st.get("hit_chance_near", -1.0))
		var far := float(st.get("hit_chance_far", -1.0))
		var itv := float(st.get("fire_interval", -1.0))
		var head := float(st.get("head_chance", -1.0))
		var reac := float(st.get("reaction", -1.0))
		var sight := float(st.get("sight_range", -1.0))
		var spd := float(st.get("speed_mult", -1.0))
		print("%-4d %-6s %8.2f %8.2f %9.2f %8.2f %9.2f %8.1f %9.2f" % [
				d, str(st.get("name", "?")), near, far, itv, head, reac, sight, spd])
		# 难度必须单调变强：命中↑ 爆头↑ 交战距离↑ 速度↑，间隔↓ 反应时间↓
		if d > 0:
			if not (near > prev_near and far > prev_far and head > prev_head
					and itv < prev_interval and reac < prev_reaction
					and sight > prev_sight and spd > prev_speed):
				print("[FAIL] 难度 %d 未比上一档全面更强" % d); fails += 1
		prev_near = near
		prev_far = far
		prev_head = head
		prev_interval = itv
		prev_reaction = reac
		prev_sight = sight
		prev_speed = spd
	if fails == 0:
		print("[OK] 三档难度全面单调递增（命中/爆头/交战距离/速度↑，间隔/反应时间↓）")

	# 移动速度真的跟着难度变
	_set_difficulty(0)
	var spd_easy := b._move_speed()
	_set_difficulty(2)
	var spd_hard := b._move_speed()
	if spd_hard > spd_easy:
		print("[OK] bot 移动速度随难度变化（%.2f → %.2f）" % [spd_easy, spd_hard])
	else:
		print("[FAIL] bot 移动速度没随难度变化"); fails += 1
	b.free()

	# 持久化：写进去能读回来
	if ConfigManager.instance != null:
		_set_difficulty(2)
		var back := ConfigManager.instance.get_bot_difficulty()
		if back == 2:
			print("[OK] 难度已持久化到配置（读回 = %d）" % back)
		else:
			print("[FAIL] 难度持久化失败，读回 = ", back); fails += 1
	else:
		print("[FAIL] ConfigManager 未初始化"); fails += 1

	# UI 选中态是否跟着走
	if diff_buttons.size() == UIText.DIFFICULTY_NAMES.size():
		_set_difficulty(2)
		var sel := -1
		for j in diff_buttons.size():
			var btn: Button = diff_buttons[j]
			if bool(btn.get_meta("seg_on", false)):
				sel = j
		if sel == 2:
			print("[OK] 难度按钮选中高亮跟随选择")
		else:
			print("[FAIL] 难度按钮高亮不对，sel=", sel); fails += 1
	else:
		print("[FAIL] 难度按钮数量 = ", diff_buttons.size(),
				"（期望 %d）" % UIText.DIFFICULTY_NAMES.size()); fails += 1
	_set_difficulty(1)

	print("\n==== 人机难度自检 %s（失败 %d 项）====" %
			["全部通过" if fails == 0 else "有失败", fails])
	get_tree().quit(1 if fails > 0 else 0)


# 冰雪图调试用截图：跳到 LIVE，把玩家移到场地南端朝北看，截第一人称 + 顶视两张图
func _schedule_iceworld_screenshot() -> void:
	# 隐藏所有菜单/UI（小地图、计分板、HUD 等）以免遮挡地图观感
	for c in [lan_menu, buy_menu, map_select_menu, game_over_menu, pause_menu,
			scoreboard, minimap, hud_toast, hud_ammo, hud_status, hud_score, hud_time,
			hud_score_ct_head, hud_score_t_head, hud_score_ct, hud_score_total, hud_score_t,
			hud_progress]:
		if c != null:
			c.visible = false
	if center_msg != null:
		center_msg.text = ""
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# 进入 LIVE 状态，并**走真实的出生点分配逻辑**（便于验证出生点是否正确）
	state = STATE.LIVE
	round_num = 1
	timer = ROUND_TIME
	_spawn_counter = {}
	for p in players:
		p.revive()
		p.velocity = Vector3.ZERO
		p.global_position = _pick_spawn(p.team)
		p.rotation.y = 0.0 if p.team == "CT" else PI
	print("[Screenshot] ct_spawns = ", ct_spawns)
	print("[Screenshot] t_spawns = ", t_spawns)
	if player:
		print("[Screenshot] 玩家出生在 ", player.global_position)
	# 列出地上所有的枪，确认"出生点面前各一把"
	var picks := get_tree().get_nodes_in_group("weapon_pickups")
	print("[Screenshot] 地上的枪数量 = ", picks.size())
	for pk in picks:
		print("   ", pk.weapon_id, " @ ", pk.global_position)

	# 调试可视化：把 16 个出生点都画出来（CT 蓝 / T 红），方便一眼确认位置
	for sp in ct_spawns:
		_spawn_dot(sp, Color(0.35, 0.6, 1.0))
	for sp in t_spawns:
		_spawn_dot(sp, Color(1.0, 0.4, 0.3))

	# 等场景稳定 + 资源导入完毕
	await get_tree().create_timer(2.5).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img := get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_fpv.png")
	print("[Screenshot] FPV saved")

	# 视线验证：从**最靠中间**的出生点（x=-1.5，紧邻十字缝）朝北看对面 ——
	# 如果这里还能一眼看到 T 出生点，说明石块还不够大 / 缝太宽
	var aim_cam := Camera3D.new()
	get_tree().current_scene.add_child(aim_cam)
	aim_cam.position = Vector3(-1.5, 1.55, 17.0)
	aim_cam.look_at(Vector3(-1.5, 1.55, -17.0), Vector3.UP)
	aim_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_对视线.png")
	print("[Screenshot] Aim saved")

	aim_cam.queue_free()

	# 切到顶视：在玩家相机上方放一个临时俯视相机
	var top_cam := Camera3D.new()
	top_cam.position = Vector3(0, 42, 0)
	top_cam.rotation = Vector3(-PI * 0.5, 0, 0)
	top_cam.current = true
	get_tree().current_scene.add_child(top_cam)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_top.png")
	print("[Screenshot] Top saved")

	# 斜俯视（对齐参考图那种 45° 俯瞰视角，方便和原图直接对比）
	var iso_cam := Camera3D.new()
	get_tree().current_scene.add_child(iso_cam)
	iso_cam.position = Vector3(0, 24, 17)
	iso_cam.look_at(Vector3(0, 0, 0), Vector3.UP)
	iso_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_俯瞰.png")
	print("[Screenshot] Iso saved")

	# 侧视：看左右两侧「贴墙长方体矮墙」和大围墙
	var side_cam := Camera3D.new()
	get_tree().current_scene.add_child(side_cam)
	side_cam.position = Vector3(-11.0, 2.6, 0.0)
	side_cam.look_at(Vector3(-17.2, 0.7, 0.0), Vector3.UP)
	side_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_斜坡墙.png")
	print("[Screenshot] Side saved")

	# 中墙贴墙验证：俯视局部放大左侧「中墙 ↔ 大围墙内表面」的接缝，确认零空隙
	var flush_cam := Camera3D.new()
	get_tree().current_scene.add_child(flush_cam)
	flush_cam.position = Vector3(-16.5, 7.0, 0.0)
	flush_cam.rotation = Vector3(-PI * 0.5, 0, 0)
	flush_cam.fov = 46.0
	flush_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_中墙贴墙.png")
	print("[Screenshot] Flush saved")

	flush_cam.queue_free()

	# 对齐验证：俯视局部放大，专门看「上排小墙上边 ↔ 石块上边」是否成一条线
	var align_cam := Camera3D.new()
	get_tree().current_scene.add_child(align_cam)
	align_cam.position = Vector3(-13.5, 16.0, -11.4)
	align_cam.rotation = Vector3(-PI * 0.5, 0, 0)
	align_cam.fov = 42.0
	align_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_对齐验证.png")
	print("[Screenshot] Align saved")

	align_cam.queue_free()

	# 武器特写：斜俯视 CT 出生点那把 AK47，检查平躺姿态与贴地高度
	var gun_cam := Camera3D.new()
	get_tree().current_scene.add_child(gun_cam)
	gun_cam.position = Vector3(-10.5, 0.62, 14.75)
	gun_cam.look_at(Vector3(-10.5, 0.06, 15.9), Vector3.UP)
	gun_cam.fov = 40.0
	gun_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_武器特写.png")
	print("[Screenshot] Gun saved")

	gun_cam.queue_free()

	# 场外视角：看围墙外的虚无 + 蓝天 + 远山
	var out_cam := Camera3D.new()
	get_tree().current_scene.add_child(out_cam)
	out_cam.position = Vector3(0, 12, 62)
	out_cam.look_at(Vector3(0, 4, 0), Vector3.UP)
	out_cam.current = true

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "冰雪世界_新版_场外.png")
	print("[Screenshot] Outside saved")

	out_cam.queue_free()
	side_cam.queue_free()
	iso_cam.queue_free()
	top_cam.queue_free()
	get_tree().quit()


# 菜单 UI 截图（跑法：godot --path <项目> --screenshot-ui）
# 截「购买菜单 / 暂停菜单 / 整场结束 / 计分板」，用于核对文案与排版。
# （界面1 大厅 / 界面2 房间界面的截图由 --screenshot-lan 负责）
func _schedule_ui_screenshot() -> void:
	# 房间界面（界面2）的截图由 --screenshot-lan 负责（那里会真开一个房间，
	# 右上角房间名/状态栏才有内容）。这里只借它走一遍真实流程。
	_open_map_select()

	# 进对局，依次截「购买菜单 / 暂停菜单 / 整场结束」
	_start_game_with_map("iceworld")
	await get_tree().create_timer(1.0).timeout
	if player == null:
		get_tree().quit()
		return

	buy_menu.visible = true
	buy_menu_visible = true
	_refresh_buy_menu()
	await get_tree().create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "UI_购买菜单.png")
	print("[Screenshot] Buy menu saved")
	buy_menu.visible = false
	buy_menu_visible = false

	pause_menu.visible = true
	await get_tree().create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "UI_暂停菜单.png")
	print("[Screenshot] Pause menu saved")
	pause_menu.visible = false

	# 整场结束面板：走真实的 _game_over()，好让"哪一方胜利 / 比分"有内容
	ct_wins = 5
	t_wins = 3
	_game_over()
	await get_tree().create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "UI_整场结束.png")
	print("[Screenshot] Game over saved")
	game_over_menu.visible = false
	_match_over_pending = false      # 别让倒计时真的把我们带回房间界面
	ct_wins = 0
	t_wins = 0

	# 计分板：补满 8v8 并塞点假的击杀/死亡，不然只有一两个人看不出排版效果
	while players.size() < 16:
		_add_bot_pair(get_tree().current_scene)
		await get_tree().create_timer(0.12).timeout
	var _rng := RandomNumberGenerator.new()
	_rng.seed = 20260930
	for p in players:
		p.kills = _rng.randi_range(0, 18)
		p.deaths = _rng.randi_range(0, 14)
		if p.team == "CT":
			p.alive = _rng.randf() > 0.35
	ct_wins = 5
	t_wins = 3
	_update_scoreboard()
	scoreboard.visible = true
	await get_tree().create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	img = get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "UI_计分板.png")
	print("[Screenshot] Scoreboard saved")

	get_tree().quit()


# 小地图（雷达）调试截图（跑法：godot --path <项目> --screenshot-minimap）
# 直接把玩家摆到几个典型位置/朝向，截全屏（含左上角雷达）便于核对墙体轮廓是否准确
func _schedule_minimap_screenshot() -> void:
	_open_map_select()                       # 走真实流程：先隐藏开始菜单
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.2).timeout

	var shots: Array = [
		[Vector3(0.0, 0.1, 10.0), 0.0, "南侧朝北"],
		[Vector3(0.0, 0.1, 0.0), 0.0, "场心朝北"],
		[Vector3(-14.0, 0.1, 0.0), -PI * 0.5, "贴西墙朝东"],
		[Vector3(0.0, 0.1, -17.0), PI, "北侧朝南"],
	]
	for sh in shots:
		if player == null:
			break
		player.global_position = sh[0]
		player.velocity = Vector3.ZERO
		player.rotation.y = sh[1]
		await get_tree().create_timer(0.45).timeout
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(_shot_dir() + "小地图_%s.png" % sh[2])
		print("[Screenshot] Minimap saved: ", sh[2])
	get_tree().quit()


# bot 导航自检（跑法：godot --path <项目> --test-nav）
# 把 bot 和玩家分别放在场心方块群的南北两侧（直线距离 32 米，中间被 4 块 10.5m 的
# 大方块完全挡死），跑 12 秒看 bot 能不能绕过去、距离是否持续缩短。
func _test_nav() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	if player == null:
		print("[Nav] 没有玩家"); get_tree().quit(); return
	var bot: CSPlayer = null
	for p in get_tree().get_nodes_in_group("players"):
		if p != player and p.is_bot:
			bot = p
			break
	if bot == null:
		print("[Nav] 没有 bot"); get_tree().quit(); return

	# 刻意摆成"两点连线正好穿过场心方块群"：
	# 场地 x ∈ [-18, 18]，方块群覆盖 x ∈ [-11.5, 11.5]、z ∈ [-11.75, 11.75]，
	# 所以 (-12, -9) → (12, 9) 的直线会直接扎进方块里，必须绕。
	# （别摆在 x=0 —— 那是方块之间 2m 的十字缝，bot 能直接穿过去，测不出避障）
	player.global_position = Vector3(12.0, 0.2, 9.0)
	bot.global_position = Vector3(-12.0, 0.2, -9.0)
	bot.velocity = Vector3.ZERO
	var start_d := bot.global_position.distance_to(player.global_position)
	print("[Nav] 起始距离 = %.2f m（直线穿越方块群，必须绕行）" % start_d)
	var best := start_d
	var no_progress := 0
	for i in 12:
		await get_tree().create_timer(1.0).timeout
		# 关掉侧翼绕行：本自检只验证「A* 栅格能不能绕开中央石块群」，
		# 侧翼选路是 --test-botroute 的职责。不关的话 bot 可能整段 12 秒都在绕远路，
		# best 一直降不下来 → 间歇性误报失败。
		bot.set("_route", 0)
		bot.set("_route_left", 0.0)
		bot.set("_route_cool", 999.0)
		var d := bot.global_position.distance_to(player.global_position)
		print("[Nav] t=%2ds 距离=%6.2f  位置=(%5.1f, %5.1f)" \
			% [i + 1, d, bot.global_position.x, bot.global_position.z])
		if d < best - 0.3:
			best = d
			no_progress = 0
		else:
			no_progress += 1
	var ok := best < start_d - 4.0
	print("=== 导航自检：%s（最近 %.2f m，起始 %.2f m）===" \
		% ["通过" if ok else "失败 —— bot 没能接近目标", best, start_d])
	get_tree().quit(0 if ok else 1)


# bot 选路自检（跑法：godot --path <项目> --test-botroute）
# 让 bot 从固定出生点追一个固定位置的玩家，每 2 秒打印一次它的路线参数和位置，
# 用来判断"bot 是否总走同一条路（总从同一侧包抄）"。
func _test_botroute() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	if player == null or bots.is_empty():
		print("[BR] 缺少玩家或 bot"); get_tree().quit(1); return
	var bot: CSPlayer = bots[0]
	player.global_position = Vector3(0, 0.2, 17)
	var seen := {}
	for i in 15:
		await get_tree().create_timer(2.0).timeout
		var key := "%d/%.0f" % [bot._route, bot._route_side]
		seen[key] = int(seen.get(key, 0)) + 1
		print("[BR] t=%2ds route=%2d side=%3.0f f=%.2f off=%4.1f pos=(%5.1f,%5.1f) dist=%.1f" % [
			(i + 1) * 2, bot._route, bot._route_side, bot._route_f, bot._route_off,
			bot.global_position.x, bot.global_position.z,
			bot.global_position.distance_to(player.global_position)])
	print("[BR] route/side 取值分布：", seen)
	get_tree().quit()


# 购买阶段击杀自检（跑法：godot --path <项目> --test-buykill）
# 在 BUY 阶段杀光敌人，量多久才进入回合结束 —— 复现"杀完人迟迟不出胜利提示"。
func _test_buykill() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	# 保持 BUY 阶段（不改 state），只把计时拉长一点便于观察
	state = STATE.BUY
	timer = BUY_TIME
	await get_tree().create_timer(0.5).timeout
	var enemies: Array = []
	for p in players:
		if p.team != player.team:
			enemies.append(p)
	print("[BK] BUY 阶段：敌人 %d 个，state=%d，timer=%.1f" % [enemies.size(), state, timer])
	for e in enemies:
		e.apply_damage({"damage": 9999.0, "armor_ratio": 1.0, "head_mult": 1.0}, player, false)
	var t0 := Time.get_ticks_msec()
	var ended := false
	for j in 900:
		if state != STATE.BUY:
			ended = true
			break
		await get_tree().process_frame
	print("[BK] 杀完 → 离开 BUY 耗时 = %d ms（ended=%s, state=%d, text=\"%s\"）" % [
		Time.get_ticks_msec() - t0, str(ended), state, center_msg.text])
	get_tree().quit()


# 回合结束判定自检（跑法：godot --path <项目> --test-roundend）
# 模拟真实对局：加 2 组 bot（场上 3v3），按真实节奏一个一个杀，
# 量「最后一个敌人倒下」到「进入回合结束」隔了多少毫秒。
func _test_roundend() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	_add_bot_pair(get_tree().current_scene)
	_add_bot_pair(get_tree().current_scene)
	await get_tree().create_timer(0.5).timeout

	var enemies: Array = []
	for p in players:
		if p != player and p.team != player.team:
			enemies.append(p)
	print("[RE] 场上敌人 = %d 个，我方 = %d 人" % [enemies.size(), players.size() - enemies.size()])

	var last_kill_ms := 0
	for i in enemies.size():
		await get_tree().create_timer(0.8).timeout   # 模拟真实交战节奏
		var e: CSPlayer = enemies[i]
		e.apply_damage({"damage": 9999.0, "armor_ratio": 1.0, "head_mult": 1.0}, player, false)
		last_kill_ms = Time.get_ticks_msec()
		var alive_n := 0
		for q in players:
			if q.alive and q.team != player.team:
				alive_n += 1
		print("[RE] 杀死第 %d/%d 个，还剩 %d 个活着的敌人" % [i + 1, enemies.size(), alive_n])

	print("[RE] 最后一个敌人已倒下，开始计时…")
	for j in 600:
		if state != STATE.LIVE:
			break
		await get_tree().process_frame
	var ms := Time.get_ticks_msec() - last_kill_ms
	print("[RE] 最后一个死亡 → 回合结束 = %d ms，文字=\"%s\"" % [ms, center_msg.text])
	var ok_a := ms < 100

	# ---- 场景 B：回合结束后 HUD 不得覆盖胜利文字 ----
	# 之前 _update_hud 里 `if bomb_planted:` 没看 state，回合结束后每帧把
	# center_msg 冲成炸弹倒计时，「X 阵营胜利」一帧就被冲掉了。
	bomb_planted = true
	# 用同一张阵营表拼期望值，别把显示名写死在自检里（改名后自检就误报）
	var expect_msg := UIText.TEAM_WIN % team_name("CT")
	center_msg.text = expect_msg
	await get_tree().create_timer(0.3).timeout
	var kept := center_msg.text == expect_msg
	bomb_planted = false
	print("[RE] 胜利文字是否保住 = %s（text=\"%s\"）" % [str(kept), center_msg.text])

	print("=== 回合结束自检：%s ===" % ("通过" if ok_a and kept else "失败"))
	get_tree().quit(0 if ok_a and kept else 1)


# bot 压力诊断（跑法：godot --path <项目> --test-botdiag）
# 复现「加到 8 个 bot 后一开火就卡 / 内存涨」的场景，量的是**持续交火**下的真实峰值：
#   · 补满 16 个角色（8v8），把所有角色摆成半径 6m 的环、互相可见并锁血
#     （不锁血的话第一轮接触就互相打死，后面没有开火负载，量不出峰值）
#   · 每 0.5s 打印 节点数 / 孤儿节点数 / 对象数 / 资源数 / 静态内存 / 显存
#     / 绘制调用 / FPS / 场景子节点 / 开火特效节点数
# 判读：`orphan` 与 `mem`/`vram` 长时间不涨 = 没有泄漏；只在小范围波动 = 分配被正常回收。
# 结束时把当前画面存成 screenshots/_botdiag.png。
func _test_botdiag() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.5).timeout
	while players.size() < 16:
		_add_bot_pair(get_tree().current_scene)
		await get_tree().create_timer(0.3).timeout
	print("[DIAG] bots=%d players=%d" % [bots.size(), players.size()])
	var t0 := Time.get_ticks_msec()
	for i in 40:
		await get_tree().create_timer(0.5).timeout
		# 持续交火压力：把所有角色按半径 6m 的环摆到场地中央、互相可见，并锁血
		# （否则第一轮接触就互相打死，后面根本没有开火负载，量不出真实峰值）
		var k := 0
		var n := players.size()
		for p in players:
			p.health = 1000.0
			p.armor = 0.0
			p.alive = true
			var ang := TAU * float(k) / float(maxi(n, 1))
			p.global_position = Vector3(cos(ang) * 6.0, 1.0, sin(ang) * 6.0)
			# 一律朝场地中心（这样本地玩家的镜头里能看到对面一圈 bot 在开火）
			p.rotation.y = ang
			k += 1
		print("[DIAG t=%.1fs] nodes=%d orphan=%d obj=%d res=%d mem=%.1fMB vram=%.1fMB draw=%d fps=%.0f scene_children=%d effects=%d" % [
			(Time.get_ticks_msec() - t0) / 1000.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
			float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
			float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			float(Performance.get_monitor(Performance.TIME_FPS)),
			get_tree().current_scene.get_child_count(),
			_count_effect_nodes()])
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "_botdiag.png")
	get_tree().quit()


# 统计挂在场景根下、由开火特效产生的临时节点数（弹孔/血雾/血滴/曳光）
func _count_effect_nodes() -> int:
	var n := 0
	for c in get_tree().current_scene.get_children():
		if c is MeshInstance3D or c is Label3D:
			n += 1
	for p in players:
		if p.get("_tracer_layer") != null:
			n += (p.get("_tracer_layer") as Node).get_child_count()
	return n


# 血溅特效截图（跑法：godot --path <项目> --screenshot-blood）
# 玩家站到场地南侧正对场心，连截 3 帧核对血雾形态：
#   A) 正前方 4m 开阔处 → 应该看到暗红血滴云 + 飞散血滴
#   B) 北围墙外侧（屏幕同一位置、被墙挡住）→ **不应该**看到任何血雾
#      （血雾 shader 曾带 depth_test_disabled，会隔着围墙显示，B 就是这条的回归检查）
func _schedule_blood_screenshot() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.OVER
	for p in players:
		if p != player and p.get("_visual") != null:
			(p.get("_visual") as Node3D).visible = false
	player.global_position = Vector3(0, 1.0, 6.0)
	player.rotation.y = 0.0
	player._camera.rotation.x = 0.0
	await get_tree().create_timer(0.6).timeout
	# A：正前方 4m、相机高度
	player._spawn_blood_spray(Vector3(0.0, 2.5, 2.0), Vector3(0, 0, -1))
	# B：北围墙外侧（约 36m 外，视线被墙挡住）
	player._spawn_blood_spray(Vector3(0.0, 1.5, -30.0), Vector3(0, 0, 1))
	for i in 3:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_shot_dir() + "血溅_%d.png" % i)
	print("[Screenshot] Blood saved")
	get_tree().quit()


# 尸体倒地截图（跑法：godot --path <项目> --screenshot-corpse）
# 在玩家正前方 4m 打死一个 bot，等 1 秒后截图，核对：
#   · 倒地姿势是否平躺贴地（而不是"半躺半坐"）
#   · 两条腿是否已经停下（不能还在原地踏步）
#   · 模型颜色是否还是 GLB 自带贴图（不再被灰材质覆盖）
#   · 主武器是否掉在尸体旁边
func _schedule_corpse_screenshot() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.OVER
	for p in players:
		if p != player and p.get("_visual") != null:
			(p.get("_visual") as Node3D).visible = false
	player.global_position = Vector3(0, 1.0, 5.0)
	player.rotation.y = 0.0
	# 稍微低头，让 2m 外地面上的尸体落在画面中央
	player._camera.rotation.x = -0.62
	await get_tree().create_timer(0.5).timeout
	var victim: CSPlayer = bots[0]
	if victim.get("_visual") != null:
		(victim.get("_visual") as Node3D).visible = true
	victim.global_position = Vector3(0.0, 0.1, 3.0)
	victim.rotation.y = 0.0
	victim.apply_damage({"damage": 9999.0, "armor_ratio": 1.0, "head_mult": 1.0}, player, false)
	# 等击杀提示图标淡出，否则它会盖住尸体
	if kill_notice != null:
		kill_notice.visible = false
	await get_tree().create_timer(1.6).timeout
	if kill_notice != null:
		kill_notice.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "尸体倒地.png")
	print("[Screenshot] Corpse saved")
	get_tree().quit()


# 击杀信息流裁剪自检（跑法：godot --path <项目> --test-killfeed）
# 关键：`queue_free()` 是**延迟删除**（本帧末尾才真正移除），
# 所以 `while kill_feed.get_child_count() > 5: get_child(..).queue_free()` 里
# 子节点数在循环内根本不会减少 —— 第 6 条击杀进来时就是死循环（卡死）。
# 本自检连插 10 行，验证行数能收敛到 5 且不挂。
func _test_killfeed() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	await get_tree().create_timer(0.5).timeout
	print("[KF] 起始行数 = %d" % kill_feed.get_child_count())
	for i in 10:
		_feed_add_row("K%d" % i, "CT", "AK47", "V%d" % i, "T")
		print("[KF] 插入第 %d 行后 → 行数 = %d（队列删除前）" % [i + 1, kill_feed.get_child_count()])
	await get_tree().create_timer(0.3).timeout
	var n := kill_feed.get_child_count()
	print("[KF] 一帧后 行数 = %d" % n)
	print("=== 击杀信息流自检：%s ===" % ("通过" if n == 5 else "失败"))
	get_tree().quit(0 if n == 5 else 1)


# 真实对局浸泡测试（跑法：godot --path <项目> --test-botmatch）
# 复现用户场景：补满 8v8（16 角色）后**不做任何干预**，让 bot 自由交战、回合自然推进，
# 每 2 秒打印一次内存/显存/对象数。用来抓"开火后内存持续爬升"的慢泄漏。
func _test_botmatch() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	while players.size() < 16:
		_add_bot_pair(get_tree().current_scene)
		await get_tree().create_timer(0.3).timeout
	print("[SOAK] bots=%d players=%d" % [bots.size(), players.size()])
	var t0 := Time.get_ticks_msec()
	var mem0 := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	for i in 45:
		await get_tree().create_timer(2.0).timeout
		# 顺带统计 bot 交战状态：有目标 / 有视线 的数量，判断"不开火"是不是真的
		var alive_ct := 0
		var alive_t := 0
		var engaged := 0
		var los_ok := 0
		var armed := 0
		var pickups := 0
		for p in players:
			if p.alive:
				if p.team == "CT":
					alive_ct += 1
				else:
					alive_t += 1
			if p.is_bot and p.has_primary():
				armed += 1
			if not p.is_bot or not p.alive:
				continue
			var tgt: Object = p.get("target")
			if tgt != null:
				engaged += 1
				if bool(p.call("_has_los")):
					los_ok += 1
		pickups = get_tree().get_nodes_in_group("weapon_pickups").size()
		print("[SOAK t=%.0fs] mem=%.1fMB(+%.1f) vram=%.1fMB nodes=%d orphan=%d obj=%d res=%d draw=%d fps=%.0f effects=%d | round=%d ct=%d t=%d state=%d 存活CT=%d 存活T=%d 有目标=%d 有视线=%d bot有枪=%d 地上枪=%d" % [
			(Time.get_ticks_msec() - t0) / 1000.0,
			float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
			float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0 - mem0,
			float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			float(Performance.get_monitor(Performance.TIME_FPS)),
			_count_effect_nodes(), round_num, ct_wins, t_wins, state,
			alive_ct, alive_t, engaged, los_ok, armed, pickups])
	get_tree().quit()


# bot 捡枪/换枪策略自检（跑法：godot --path <项目> --test-botpickup）
# 断言：没主武器必捡 / 明显更贵的换 / 只贵一点的不换 / 换枪后旧枪回到地上
func _test_botpickup() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.OVER
	await get_tree().create_timer(0.8).timeout
	var bot: CSPlayer = bots[0]
	var before := get_tree().get_nodes_in_group("weapon_pickups").size()

	# 1) 没有主武器 → 必捡
	bot.take_primary()
	bot.weapons[2] = {"id": "USP", "mag": 12, "reserve": 100}
	bot.weapons[3] = {"id": "Knife"}
	bot._update_slots()
	if try_pickup_weapon(bot, "MP5") and bot.get_primary_id() == "MP5":
		print("[OK] bot 没主武器 → 捡起 MP5")
	else:
		print("[FAIL] bot 没主武器却没捡 MP5（当前=%s）" % bot.get_primary_id()); fails += 1

	# 2) 拿着 MP5(1500) 遇到 AWP(4750)：差 3250 > 500 → 应该换，且旧枪掉回地上
	var n_before := get_tree().get_nodes_in_group("weapon_pickups").size()
	if try_pickup_weapon(bot, "AWP") and bot.get_primary_id() == "AWP":
		print("[OK] MP5 → AWP（明显更贵）成功换枪")
	else:
		print("[FAIL] MP5 → AWP 没换（当前=%s）" % bot.get_primary_id()); fails += 1
	var n_after := get_tree().get_nodes_in_group("weapon_pickups").size()
	if n_after == n_before + 1:
		print("[OK] 换枪后旧枪回到地上（掉落物 %d → %d）" % [n_before, n_after])
	else:
		print("[FAIL] 换枪后旧枪没掉回地上（%d → %d）" % [n_before, n_after]); fails += 1

	# 3) 拿着 Galil(2000) 遇到 AK47(2500)：差 500 ≤ 阈值 800 → 不换
	bot.take_primary()
	bot.give_weapon(1, "Galil")
	if try_pickup_weapon(bot, "AK47"):
		print("[FAIL] 只贵 250 也换了（当前=%s）" % bot.get_primary_id()); fails += 1
	else:
		print("[OK] 只贵一点不换（保持 %s）" % bot.get_primary_id())

	# 4) 人类玩家规则不变：已有主武器就拒绝
	player.take_primary()
	player.give_weapon(1, "M4A1")
	if try_pickup_weapon(player, "AWP"):
		print("[FAIL] 人类玩家已有主武器却捡起了 AWP"); fails += 1
	else:
		print("[OK] 人类玩家已有主武器时仍然拒绝拾取（规则未变）")

	# 5) 死亡掉落主武器
	var n2 := get_tree().get_nodes_in_group("weapon_pickups").size()
	_drop_primary_on_death(bot)
	if get_tree().get_nodes_in_group("weapon_pickups").size() == n2 + 1 and bot.get_primary_id() == "":
		print("[OK] 倒地后主武器掉到地上、身上清空")
	else:
		print("[FAIL] 倒地掉落主武器失败"); fails += 1

	print("=== bot 捡枪自检：%s（掉落物初始 %d）===" % ["全部通过" if fails == 0 else "%d 项失败" % fails, before])
	get_tree().quit(0 if fails == 0 else 1)


# bot 交战行为自检（跑法：godot --path <项目> --test-engage）
# A) 远距离开火：用"简单"档（sight_range=32m）把两人放到 34m 开外。
#    旧版会因为 dist >= sight 一枪不放；断言新版只要看得见就打。
# B) 近距走位：在北侧开阔带对峙 8m，统计 12 秒内的
#    横向摆动幅度 / 下蹲帧数 / 腾空帧数。断言三种躲避动作都出现过。
func _test_engage() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	var diff_bak: int = bot_difficulty
	bot_difficulty = 0                      # 简单档：sight_range 只有 32m
	player.global_position = Vector3(-17.0, 0.2, 0.0)
	player.rotation.y = -PI / 2.0           # 朝 +X（面向 bot）
	var bot: CSPlayer = bots[0]
	bot.global_position = Vector3(17.0, 0.2, 0.0)
	bot.give_weapon(1, "AK47")
	bot._switch_slot(1)
	bot.velocity = Vector3.ZERO
	var d0 := bot.global_position.distance_to(player.global_position)
	var min_d := 9999.0
	var shots_from := -1.0
	for i in 60:
		await get_tree().create_timer(0.1).timeout
		player.health = 1000.0
		bot.health = 1000.0
		bot.set("_route", 0)
		bot.set("_route_left", 0.0)
		bot.set("_route_cool", 999.0)
		var d := bot.global_position.distance_to(player.global_position)
		min_d = minf(min_d, d)
		if shots_from < 0.0 and float(bot.get("fire_cd")) > 0.0:
			shots_from = d
	print("[ENG] A 远距离（简单档 sight=32m，相距 %.1fm）：首次开火 %.1fm，最近接近 %.1fm" % [
			d0, shots_from, min_d])
	if shots_from > 32.0:
		print("[OK] 超出 sight_range 照样开火（开火不受距离限制）")
	else:
		print("[FAIL] 远距离没开火（首次开火 %.1fm）" % shots_from); fails += 1
	if min_d >= 9.0:
		print("[OK] 没有怼到脸上")
	else:
		print("[FAIL] 贴到 %.1fm 了" % min_d); fails += 1
	bot_difficulty = diff_bak

	# ---- B 近距走位：横移 / 下蹲 / 跳 ----
	# 北侧开阔带（z ∈ [12,20] 无障碍）：垂直视线方向是 X 轴，左右各有一大片空间
	player.global_position = Vector3(0.0, 0.2, 12.0)
	player.rotation.y = PI                  # 朝 -Z（面向 bot）
	bot.global_position = Vector3(0.0, 0.2, 20.0)
	bot.velocity = Vector3.ZERO
	await get_tree().create_timer(0.5).timeout
	var trail: Array[Vector3] = []
	var crouch_n := 0
	var jump_n := 0
	for i in 120:
		await get_tree().create_timer(0.1).timeout
		player.health = 1000.0
		bot.health = 1000.0
		bot.set("_route", 0)
		bot.set("_route_left", 0.0)
		bot.set("_route_cool", 999.0)
		trail.append(bot.global_position)
		if bool(bot.get("_crouching")):
			crouch_n += 1
		if bot.global_position.y > 0.6:
			jump_n += 1
	var lateral := 0.0
	if trail.size() >= 2:
		var fwd := player.global_position - trail[0]
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := Vector3(-fwd.z, 0.0, fwd.x)
		var lo := INF
		var hi := -INF
		for p in trail:
			var rel := p - trail[0]
			rel.y = 0.0
			var v := rel.dot(right)
			lo = minf(lo, v)
			hi = maxf(hi, v)
		lateral = hi - lo
	print("[ENG] B 近距走位（12 秒）：横移幅度 %.1fm，下蹲采样 %d 次，腾空采样 %d 次" % [
			lateral, crouch_n, jump_n])
	if lateral >= 2.0:
		print("[OK] 会左右横移")
	else:
		print("[FAIL] 几乎不横移（站桩）"); fails += 1
	if crouch_n >= 1:
		print("[OK] 会下蹲躲避（缩小受弹面）")
	else:
		print("[WARN] 12 秒随机采样里没抽到下蹲（27% 概率，属正常抖动）")
	# 下蹲/跳是随机动作，短时间采样可能抽不到 → 再**确定性**验证一次机制本身：
	# 反复推进躲避状态机，直到它抽到下蹲为止（27% 概率，30 次几乎必中）。
	bot.set_crouch(false)
	var got_crouch := false
	for i in 40:
		bot.set("_dodge_left", 0.0)
		bot.set("_dodge_cool", 0.0)
		bot.call("_update_dodge", 0.0)
		if int(bot.get("_dodge")) == 1:
			got_crouch = true
			break
	if got_crouch and bool(bot.get("_crouching")):
		print("[OK] 躲避状态机抽到下蹲时确实会蹲下")
	else:
		print("[FAIL] 抽到下蹲却没蹲"); fails += 1
	# 跳跃是 18% 概率的随机动作，12 秒里不一定抽到 —— 所以这里**确定性**验证跳跃机制：
	# 直接置上待跳标记，看 bot 是否真的离地。
	bot.set("_jump_pending", true)
	var peak := 0.0
	for i in 12:
		await get_tree().create_timer(0.05).timeout
		peak = maxf(peak, bot.global_position.y)
	print("[ENG] B2 强制跳跃：最高离地 %.2fm" % peak)
	if peak > 0.5:
		print("[OK] 跳跃机制生效（会真的跳起来）")
	else:
		print("[FAIL] 置了待跳标记却没离地"); fails += 1

	# 存两张现场图：蹲下 / 跳跃（玩家在 8m 外正对 bot，看得清姿势）
	# 先把它摆回玩家正前方 —— 走位 12 秒后它早就横移走了
	bot.global_position = Vector3(0.0, 0.2, 20.0)
	bot.rotation.y = PI
	bot.velocity = Vector3.ZERO
	bot.set_crouch(true)
	await get_tree().create_timer(0.4).timeout
	bot.global_position = Vector3(0.0, 0.2, 20.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "bot下蹲.png")
	bot.set_crouch(false)
	bot.set("_jump_pending", true)
	await get_tree().create_timer(0.42).timeout   # 接近跳跃最高点（v/g = 5/12 ≈ 0.42s）
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "bot跳跃.png")
	print("[ENG] 现场图已存：bot下蹲.png / bot跳跃.png")

	print("=== 交战行为自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 「不发枪 + bot 主动捡枪」自检（跑法：godot --path <项目> --test-botgun）
# 断言：① 开局不给 bot 发主武器（只有手枪/刀）② 一段时间后 bot 自己走去捡到了枪
func _test_botgun() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.5).timeout
	while bots.size() < 6:
		_add_bot_pair(get_tree().current_scene)
		await get_tree().create_timer(0.3).timeout
	# ① 直接验证 _bot_buy 不发枪。
	# 注意别用"等 1.5 秒再看 bot 有没有主武器"——bot 可能已经自己跑去地上捡到了，
	# 那是假阳性。这里先清空再调一次 _bot_buy，看它是否凭空变出枪来。
	var probe: CSPlayer = bots[0]
	probe.take_primary()
	_bot_buy(probe)
	if probe.has_primary():
		print("[FAIL] _bot_buy 仍然给 bot 发了枪（当前=%s）" % probe.get_primary_id()); fails += 1
	else:
		print("[OK] _bot_buy 不再给 bot 发枪（地上那 16 把才是唯一来源）")
	# ② 锁血跑 10 秒，看 bot 会不会自己走去捡枪
	for p in players:
		p.take_primary()
	for i in 50:
		await get_tree().create_timer(0.2).timeout
		for p in players:
			p.health = 1000.0
			p.armor = 0.0
	var armed := 0
	for b in bots:
		if b.has_primary():
			armed += 1
	print("[GUN] 10 秒后 %d 个 bot 中有主武器的 = %d" % [bots.size(), armed])
	if armed >= maxi(1, bots.size() / 2):
		print("[OK] bot 会自己走到地上捡枪")
	else:
		print("[FAIL] 多数 bot 没去捡枪"); fails += 1
	# 存一张现场图：把玩家摆到最近一个"已捡到枪"的 bot 面前
	var shot_bot: CSPlayer = null
	for b in bots:
		if b.has_primary() and b.alive:
			shot_bot = b
			break
	if shot_bot != null:
		state = STATE.OVER
		var fwd := -shot_bot.global_transform.basis.z
		player.global_position = shot_bot.global_position - fwd * 5.0 + Vector3(0, 1.0, 0)
		player.look_at(shot_bot.global_position + Vector3(0, 1.2, 0), Vector3.UP)
		player._camera.rotation.x = 0.0
		await get_tree().create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_shot_dir() + "bot捡枪.png")
		print("[GUN] 现场图已存：%s 手持 %s" % [shot_bot.nick, shot_bot.get_primary_id()])
	print("=== bot 捡枪行为自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 矮墙后视线采样自检（跑法：godot --path <项目> --test-los）
# 复现玩家反馈：「我站小围墙后、头已经露出来了，bot 却看不见我，非要跑到我面前才开枪」。
# 做法：沿场心那条 2m 十字缝（z=0，无遮挡）把玩家放西侧、bot 放东侧，相距 18m，
#       然后在两人正中间立一块**只有 1.30m 高**的挡板。
#       几何上：头那条射线（中点 y≈1.46）越过挡板 → 可见；
#               胸（y≈1.18）/ 腰（y≈1.02）被挡板挡住 → 不可见。
# 断言：bot 仍然判定"有视线"（因为头露着），且记录到"只有头可见"。
#       —— 旧版只查胸口一个点，这里会判成"看不见"，于是 bot 一路贴到 1.2m。
func _test_los() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	player.global_position = Vector3(-8.0, 0.2, 0.0)
	var bot: CSPlayer = bots[0]
	bot.global_position = Vector3(10.0, 0.2, 0.0)
	bot.velocity = Vector3.ZERO
	player.health = 1000.0
	bot.health = 1000.0
	# 先量"没有挡板"时的基准
	await get_tree().create_timer(0.3).timeout
	print("[LOS] 无遮挡：有视线=%s 头=%s 胸=%s" % [
			bot.get("_los_ok"), bot.get("_los_head"), bot.get("_los_chest")])
	if not bool(bot.get("_los_ok")):
		print("[FAIL] 无遮挡时竟然没有视线（测试环境有问题）"); fails += 1

	# 立一块 1.30m 高的挡板（只挡住胸/腰，头露在上面）
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 1.30, 6.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.6, 0.6)
	box.material = mat
	mi.mesh = box
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	col.shape = bs
	body.add_child(col)
	body.position = Vector3(0.0, 0.65, 0.0)
	map_root.add_child(body)

	await get_tree().create_timer(0.3).timeout
	var ok := bool(bot.get("_los_ok"))
	var head := bool(bot.get("_los_head"))
	var chest := bool(bot.get("_los_chest"))
	print("[LOS] 1.3m 矮墙后：有视线=%s 头=%s 胸=%s" % [ok, head, chest])
	if ok and head and not chest:
		print("[OK] 只有头露出来时仍判定为「有视线」，且识别到只有头可见（→ 会瞄头远距离打）")
	else:
		print("[FAIL] 矮墙后露头被误判为没有视线（bot 会跑去贴脸）"); fails += 1

	# 再等 3 秒，确认 bot 真的没有一路贴上来
	var d0 := bot.global_position.distance_to(player.global_position)
	var min_d := d0
	for i in 30:
		await get_tree().create_timer(0.1).timeout
		player.health = 1000.0
		bot.health = 1000.0
		min_d = minf(min_d, bot.global_position.distance_to(player.global_position))
	print("[LOS] 3 秒内最近接近 %.1fm（起始 %.1fm，步枪偏好 %.1fm）" % [min_d, d0, bot._engage_range()])
	if min_d >= 9.0:
		print("[OK] bot 没有贴脸（停在交战距离外开火）")
	else:
		print("[FAIL] bot 还是贴到 %.1fm 了" % min_d); fails += 1

	print("=== 矮墙视线自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 掩体 + peek 节奏自检（跑法：godot --path <项目> --test-cover）
# 在北侧开阔带摆一块真实掩体（宽 1.6 / 高 2.4，会登记进导航网格），玩家和 bot 分列两侧。
# 断言：bot 会跑完 COVER（躲）→ PEEK（探身）→ FIRE（对枪）三个阶段，
#       并且在躲的时候真的**断掉视线 + 蹲下**（这才叫躲掩体，而不是站在开阔地换血）。
func _test_cover() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(1.0).timeout
	# 掩体宽度取 2.6m：保证"换点"时一定存在 ≥1.8m 的替代点（否则只有一处掩体，
	# 测试会偶发失败，而那是合法情况不是 bug）
	_make_static(Vector3(0.0, 1.2, 17.0), Vector3(2.6, 2.4, 0.5),
			Color(0.62, 0.60, 0.56), true)
	_build_nav_grid()
	player.global_position = Vector3(0.0, 0.2, 20.0)
	player.rotation.y = PI              # 朝 -Z（面向 bot）
	var bot: CSPlayer = bots[0]
	# 起点放在掩体侧前方：一开始**看得见**玩家（否则会先走"没视线→找人"的推进逻辑），
	# 但身边有掩体可用（横向挪到 |x|<1.6 就被石块挡住）。
	bot.global_position = Vector3(3.0, 0.2, 14.0)
	bot.rotation.y = 0.0                # 朝 +Z（面向玩家）
	bot.give_weapon(1, "AK47")
	bot._switch_slot(1)
	bot.velocity = Vector3.ZERO
	bot.set("_cs", 0)                   # 从 APPROACH 开始
	bot.set("_cover_valid", false)
	# 侧上方观察相机：只为截图用。bot 的"目标"仍是玩家（位置没变），行为不受影响。
	var obs := Camera3D.new()
	obs.position = Vector3(9.5, 4.2, 11.0)
	get_tree().current_scene.add_child(obs)
	obs.look_at(Vector3(0.4, 1.0, 15.5), Vector3.UP)
	obs.current = true
	await get_tree().create_timer(0.3).timeout

	var st_cover := 0
	var st_peek := 0
	var st_fire := 0
	var hidden := 0                     # bot 看不到玩家 = 真的躲起来了
	var crouch := 0
	var shot_cover := false
	var shot_fire := false
	for i in 250:                       # 25 秒
		await get_tree().create_timer(0.1).timeout
		player.health = 1000.0
		bot.health = 1000.0
		match int(bot.get("_cs")):
			1: st_cover += 1
			2: st_peek += 1
			3: st_fire += 1
		if not bool(bot.call("_has_los")):
			hidden += 1
		if bool(bot.get("_crouching")):
			crouch += 1
		# 抓两张现场图：躲在掩体后（蹲着） / 探身对枪
		if not shot_cover and int(bot.get("_cs")) == 1 and bool(bot.get("_crouching")):
			shot_cover = true
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(_shot_dir() + "bot躲掩体.png")
		if not shot_fire and int(bot.get("_cs")) == 3:
			shot_fire = true
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(_shot_dir() + "bot探身开火.png")
	print("[COVER] 25 秒采样（仅供参考）：COVER=%d PEEK=%d FIRE=%d 无视线=%d 蹲下=%d" % [
			st_cover, st_peek, st_fire, hidden, crouch])

	# ---- B 状态机转移（确定性）----
	# 上面那 25 秒采样会受 bot 走位/地图几何影响而抖动（偶发一次都抽不到），
	# 所以关键路径改成**直接驱动状态机**逐条验证转移条件，不再靠采样。
	var pin2 := Vector3(3.0, 0.2, 14.0)
	bot.global_position = pin2
	bot.set("_avoid_valid", false)
	bot.set("_cs", 0)                                  # APPROACH
	bot.call("_advance_cover_state", 0.1, true, 8.0)    # 看得见 + 在交战距离内
	if int(bot.get("_cs")) == 1:
		print("[OK] APPROACH + 有视线 → 进入 COVER（找掩体）")
	else:
		print("[FAIL] 没能进入 COVER（cs=%d）" % int(bot.get("_cs"))); fails += 1
	bot.set("_cover_valid", true)
	bot.set("_cover", bot.global_position)
	bot.set("_hide_left", 5.0)                          # 先"躲着"，检查是否蹲下
	bot.call("_advance_cover_state", 0.05, false, 8.0)
	var hid_crouch := bool(bot.get("_crouching"))
	bot.set("_hide_left", 0.01)                         # 再让躲藏时间到点
	bot.call("_advance_cover_state", 0.05, false, 8.0)
	# 注意：转入 PEEK 的同一帧会 set_crouch(false)（站起来探身），
	# 所以"蹲下"必须在**躲藏中**检查，不能在转移之后查。
	if int(bot.get("_cs")) == 2 and hid_crouch:
		print("[OK] 躲藏中会蹲下，躲够时间 → 进入 PEEK（站起来探身）")
	else:
		print("[FAIL] 躲藏中没蹲下或没能进入 PEEK（cs=%d crouch=%s）" % [
				int(bot.get("_cs")), str(hid_crouch)]); fails += 1
	bot.set("_feint", false)
	bot.set("_peek_left", 1.0)
	bot.call("_advance_cover_state", 0.05, true, 8.0)   # 探身拿到视线
	if int(bot.get("_cs")) == 3:
		print("[OK] 探身拿到视线 → 进入 FIRE（对枪）")
	else:
		print("[FAIL] 没能进入 FIRE（cs=%d）" % int(bot.get("_cs"))); fails += 1
	# 看不见时必须转回 APPROACH 去找人（这是之前"回合卡死 79 秒"的修复点）
	bot.set("_cs", 3)
	bot.set("_no_los_time", 99.0)
	bot.call("_advance_cover_state", 0.05, false, 8.0)
	if int(bot.get("_cs")) == 0:
		print("[OK] 长时间没视线 → 强制转回 APPROACH 找人（不会各自蹲着不见面）")
	else:
		print("[FAIL] 长时间没视线却没转回 APPROACH（cs=%d）" % int(bot.get("_cs"))); fails += 1

	# ---- C 假动作：探身时不开火（只露身位骗对方开枪/暴露位置）----
	# 把 bot 钉在开阔地正对玩家（保证有视线），分别测"假动作探身"和"正常对枪"
	var pin := Vector3(6.0, 0.2, 15.0)
	bot.set("_cs", 2)              # CS_PEEK
	bot.set("_peek_left", 9.0)     # 撑住不退出该状态
	bot.set("_feint", true)
	var fired_feint := 0
	# 前 6 个采样（0.3s）只用来"等上一次开火残留的 fire_cd 归零"，不计入统计 ——
	# 否则刚设上 _feint 的头几帧仍能读到正值，被误判成"假动作期间开了火"。
	for i in 18:
		await get_tree().create_timer(0.05).timeout
		player.health = 1000.0
		bot.health = 1000.0
		bot.global_position = pin
		bot.set("_cs", 2)
		bot.set("_peek_left", 9.0)
		bot.set("_feint", true)
		if i >= 6 and float(bot.get("fire_cd")) > 0.0:
			fired_feint += 1
	print("[COVER] 假动作探身 0.6s 内 fire_cd 为正（=刚开过火）的采样数 = %d" % fired_feint)
	if fired_feint == 0:
		print("[OK] 假动作探身期间不开火（只露身位骗枪）")
	else:
		print("[FAIL] 假动作期间仍然开了火"); fails += 1
	# 对照组：清掉假动作标记，同样条件下应该开火
	bot.set("_feint", false)
	var fired_norm := 0
	for i in 12:
		await get_tree().create_timer(0.05).timeout
		player.health = 1000.0
		bot.health = 1000.0
		bot.global_position = pin
		if float(bot.get("fire_cd")) > 0.0:
			fired_norm += 1
	print("[COVER] 对照组（无假动作）fire_cd 为正的采样数 = %d" % fired_norm)
	if fired_norm >= 1:
		print("[OK] 对照组正常开火（证明上面「不开火」确实是假动作造成的）")
	else:
		print("[FAIL] 对照组也不开火，测试前提不成立"); fails += 1
	bot.set("_cs", 0)

	# ---- D 换点：给一个"要避开的旧掩体点"，新找到的点必须离它够远 ----
	# 两次扫描之间**不 await**：bot 会自己走动，一旦位置变了几何就变了，测试会抖。
	bot.global_position = Vector3(3.0, 0.2, 14.0)
	bot.set("_avoid_valid", false)
	var ok1 := bool(bot.call("_find_cover"))
	var c1: Vector3 = bot.get("_cover")
	bot.global_position = Vector3(3.0, 0.2, 14.0)   # 保证两次扫描几何完全一致
	bot.set("_cover_avoid", c1)
	bot.set("_avoid_valid", true)
	var ok2 := bool(bot.call("_find_cover"))
	var c2: Vector3 = bot.get("_cover")
	print("[COVER] 换点：旧点 (%.1f,%.1f) → 新点 (%.1f,%.1f)，间距 %.2fm" % [
			c1.x, c1.z, c2.x, c2.z, c1.distance_to(c2)])
	if not ok1 or not ok2:
		print("[FAIL] 换点后完全找不到掩体（扫描逻辑坏了）"); fails += 1
	elif c1.distance_to(c2) >= 1.8:
		print("[OK] 换点生效（新掩体点与旧点相距 %.2fm，不会永远从同一个角探身）" % c1.distance_to(c2))
	else:
		# 周围只有这一处可用掩体 → 换不了点是**合法情况**，不算 bug
		print("[WARN] 该位置只有一处可用掩体，无法换点（间距 %.2fm）" % c1.distance_to(c2))

	print("=== 掩体/peek 自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 音效自检（跑法：godot --path <项目> --test-sound）
# 断言三件事：
#   ① 18 把枪都能生成"音高 + 合成层"，且音高按类别分层（手枪 > 步枪 > 狙）
#   ② 换弹/上膛/拉栓/切枪/受击这些合成音都不是静音
#   ③ 世界音源必须是 AudioStreamPlayer3D（否则没有方位感，"听声辨位"无从谈起）
func _test_sound() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.OVER
	await get_tree().create_timer(0.6).timeout

	var ids := ["Glock", "USP", "Deagle", "MP5", "P90", "XM1014", "AK47", "M4A1",
			"Galil", "FAMAS", "SG-552", "AUG", "Scout", "AWP", "SG-550", "G3SG1", "M249"]
	var pitches := {}
	var layers_ok := true
	for wid in ids:
		var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
		var cls := String(spec.get("class", "pistol"))
		var v: Dictionary = SoundFXScript.gun_voice(wid, cls)
		var layer: AudioStreamWAV = v["layer"]
		if layer == null or layer.data.is_empty():
			print("[FAIL] %s 的枪声合成层为空" % wid)
			fails += 1
			layers_ok = false
		pitches[wid] = float(v["pitch"])
	if layers_ok:
		print("[OK] %d 把枪的枪声合成层全部生成成功" % ids.size())
	if pitches["Glock"] > pitches["AK47"] and pitches["AK47"] > pitches["AWP"]:
		print("[OK] 音高分层正确：手枪 %.2f > 步枪 %.2f > 狙 %.2f（听感明显不同）" % [
				pitches["Glock"], pitches["AK47"], pitches["AWP"]])
	else:
		print("[FAIL] 枪声音高没有按类别分层"); fails += 1

	# 第三项 = 期望的"独立事件"数量：机械声必须是**多段**的（撞击 / 刮擦 / 闷响），
	# 不能是"一声滴"—— 旧版就是几个正弦叠一起的单段音，电子味很重。
	# 第 4 项 = 对应的真实录音文件名 key。★ 录音存在时跳过"多段"检查 ★ ——
	# 那条断言是给合成声写的（防它退回"一声滴"）；真实录音本来就是一整段，不该按段数判。
	for pair in [["换弹", SoundFXScript.reload_snd(), 3, "reload"],
			["上膛", SoundFXScript.reload_done_snd(), 2, "reload_done"],
			["拉栓", SoundFXScript.bolt_snd(), 3, "bolt"],
			["切枪", SoundFXScript.switch_snd(), 2, "switch"],
			["受击", SoundFXScript.hurt_snd(), 0, ""]]:
		var w: AudioStreamWAV = pair[1]
		var dur := float(w.data.size()) / 2.0 / float(w.mix_rate)
		var nonzero := 0
		for b in w.data:
			if b != 0:
				nonzero += 1
		if w.data.is_empty() or nonzero < w.data.size() / 8:
			print("[FAIL] %s 几乎是静音" % pair[0]); fails += 1
			continue
		# 按 10ms 分窗算 RMS，数一数有多少段"明显在响"
		var win := int(w.mix_rate * 0.010) * 2
		var rms: Array = []
		var o := 0
		while o + win <= w.data.size():
			var acc := 0.0
			for j in win / 2:
				var s := float(w.data.decode_s16(o + j * 2)) / 32767.0
				acc += s * s
			rms.append(sqrt(acc / float(win / 2)))
			o += win
		var peak_rms := 0.0
		for r in rms:
			peak_rms = maxf(peak_rms, float(r))
		var events := 0
		var loud := false
		for r in rms:
			var on := float(r) > peak_rms * 0.12
			if on and not loud:
				events += 1
			loud = on
		var key: String = pair[3]
		var real := key != "" and FileAccess.file_exists(
				String(SoundFXScript.MECH_FILES.get(key, "")))
		var need: int = 0 if real else int(pair[2])
		if events < need:
			print("[FAIL] %s 只有 %d 段（期望 ≥%d），听着会像单声电子音" % [pair[0], events, need])
			fails += 1
		elif real:
			print("[OK] %s 用的是真实录音 %s（%.2fs），跳过段数检查" % [
					pair[0], SoundFXScript.MECH_FILES[key].get_file(), dur])
		else:
			print("[OK] %s 已生成（%.2fs，%d 段机械声）" % [pair[0], dur, events])

	var all3d := true
	for nm in ["_snd_shot", "_snd_shot_layer", "_snd_step", "_snd_reload",
			"_snd_reload_done", "_snd_bolt", "_snd_switch", "_snd_knife_hit"]:
		if not (player.get(nm) is AudioStreamPlayer3D):
			print("[FAIL] %s 不是 AudioStreamPlayer3D（没有方位感）" % nm)
			fails += 1
			all3d = false
	if all3d:
		print("[OK] 所有世界音效都是 AudioStreamPlayer3D（带距离衰减 + 方位声像）")

	print("=== 音效自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 听声辨位自检（跑法：godot --path <项目> --test-hearing）
# 断言四件事：
#   ① 半径内的噪声能传到 bot（_heard_pos / _heard_timer 被设置）
#   ② 超出半径的噪声收不到
#   ③ 同队噪声被忽略（否则一群 bot 会互相追着队友的脚步跑）
#   ④ 躲在掩体后的 bot 听到近处动静会缩短躲藏时间、提前探身戒备
func _test_hearing() -> void:
	var fails := 0
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	await get_tree().create_timer(0.8).timeout
	while bots.size() < 3:
		_add_bot_pair(get_tree().current_scene)
		await get_tree().create_timer(0.3).timeout
	var bot: CSPlayer = bots[0]     # T 方
	player.global_position = Vector3(0.0, 0.2, 18.0)

	# 注意：①②③ 全部**同步**断言（emit_noise 是同步调用 on_hear_noise 的）。
	# 不能 await 之后再查 —— bot 走动/开火自己也会产生噪声事件，等一帧就会被污染。
	# ① 8m 外的敌方脚步 → 应该听到
	bot.global_position = Vector3(0.0, 0.2, 10.0)
	bot.set("_heard_timer", 0.0)
	emit_noise(Vector3(0.0, 0.2, 18.0), NOISE_RADIUS_STEP, player)
	if float(bot.get("_heard_timer")) > 0.0:
		print("[OK] 8m 外的敌方脚步：听到了（_heard_timer=%.1fs）" % float(bot.get("_heard_timer")))
	else:
		print("[FAIL] bot 没听到近处脚步"); fails += 1

	# ② 50m 外的脚步 → 超出半径，听不到（用 _heard_pos 判断，它不会恰好是 ZERO）
	bot.set("_heard_pos", Vector3.ZERO)
	emit_noise(Vector3(0.0, 0.2, 60.0), NOISE_RADIUS_STEP, player)
	if (bot.get("_heard_pos") as Vector3) == Vector3.ZERO:
		print("[OK] 50m 外的脚步：超出 %.0fm 半径，没听到" % NOISE_RADIUS_STEP)
	else:
		print("[FAIL] 超半径的噪声也听到了"); fails += 1

	# ③ 同队噪声 → 忽略
	var mate: CSPlayer = null
	for b in bots:
		if b.team == bot.team and b != bot:
			mate = b
			break
	if mate != null:
		bot.set("_heard_pos", Vector3.ZERO)
		mate.global_position = Vector3(0.0, 0.2, 12.0)
		emit_noise(mate.global_position, NOISE_RADIUS_SHOT, mate)
		if (bot.get("_heard_pos") as Vector3) == Vector3.ZERO:
			print("[OK] 同队枪声被忽略（不会追着队友的脚步跑）")
		else:
			print("[FAIL] 同队噪声没被忽略"); fails += 1

	# ④ 躲掩体时听到近处动静 → 缩短躲藏时间
	bot.global_position = Vector3(0.0, 0.2, 10.0)
	bot.set("_cs", 1)            # CS_COVER
	bot.set("_cover_valid", true)
	bot.set("_cover", Vector3(0.0, 0.2, 10.0))
	bot.set("_hide_left", 5.0)
	emit_noise(Vector3(0.0, 0.2, 16.0), NOISE_RADIUS_STEP, player)   # 6m 内
	await get_tree().create_timer(0.05).timeout
	var h := float(bot.get("_hide_left"))
	print("[COVER] 躲藏剩余时间 5.00s → %.2fs" % h)
	if h < 0.5:
		print("[OK] 听到近处动静后提前探身戒备")
	else:
		print("[FAIL] 听到动静没有反应"); fails += 1

	print("=== 听声辨位自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 局域网自检（跑法：godot --path <项目> --test-lan）
# 断言：
#   ① 畸形包 / 魔数不对的包会被忽略（不会把随便什么 UDP 流量当房间）
#   ② 收到合法信标 → 房间列表出现该房间（名字/人数正确）
#   ③ 超过 ROOM_TIMEOUT 没再收到信标 → 房间自动消失（主机关了房间会自然消失）
#   ③b 同一台机器开两份也能互相看到（第二个实例落到备用发现端口，主机往整组端口发信标）
#   ④ 创建房间能真的把 ENet 服务器拉起来；自己的房间会进大厅列表；关掉后收干净
#   ⑤ 大厅列表增行 / 删行都生效（清空后不残留旧行 —— "解散按钮没作用"的回归）
#   ⑥ 名册里显示的电脑数量 == 开局后场上的电脑数量
#   ⑦ 位置不够时踢 bot 腾位置
func _test_lan() -> void:
	var fails := 0
	# 直接用 GM 自己那个常驻监听的实例（_setup 里已经建好并绑定了 27777）。
	# ★ 不能再 new 一个 ★ —— 两个 socket 抢同一个 UDP 端口会 err=2（端口不可用）。
	var client := lan
	if client == null or client._listener == null:
		print("[FAIL] 局域网监听没起来：%s" % (client.last_error if client != null else "lan 未创建"))
		get_tree().quit(1)
		return
	print("[OK] 已监听 UDP %d 端口等待房间广播" % client.listen_port)

	# 用裸 UDP 直接发包，模拟"局域网里另一台机器开的房间"
	var sender := PacketPeerUDP.new()
	sender.set_dest_address("127.0.0.1", client.listen_port)

	# ① 畸形包 + 魔数不对的包
	sender.put_packet("这不是 JSON".to_utf8_buffer())
	sender.put_packet(JSON.stringify({"magic": "XXXX", "name": "冒牌房间"}).to_utf8_buffer())
	await get_tree().create_timer(0.25).timeout
	client.poll(0.0)
	if client.rooms().is_empty():
		print("[OK] 畸形包 / 魔数不对的包被忽略（不会误认成房间）")
	else:
		print("[FAIL] 垃圾包被当成了房间"); fails += 1

	# ② 合法信标 → 房间出现
	sender.put_packet(JSON.stringify({
		"magic": LanNet.MAGIC, "name": "老王的房间", "players": 3,
		"max": 16, "port": client.game_port, "id": 424242,
	}).to_utf8_buffer())
	await get_tree().create_timer(0.25).timeout
	client.poll(0.0)
	var rs := client.rooms()
	if rs.size() == 1 and String(rs[0]["name"]) == "老王的房间" and int(rs[0]["players"]) == 3:
		print("[OK] 收到信标 → 房间列表出现「%s」（%d/%d 人，来自 %s）" % [
				rs[0]["name"], rs[0]["players"], rs[0]["max"], rs[0]["ip"]])
	else:
		print("[FAIL] 合法信标没有正确变成房间：%s" % str(rs)); fails += 1

	# ③ 超时未再收到信标 → 房间消失
	client.poll(LanNet.ROOM_TIMEOUT + 1.0)   # 直接推进时间
	if client.rooms().is_empty():
		print("[OK] 超过 %.1fs 没再收到信标 → 房间自动消失（主机关房间会自然消失）" % LanNet.ROOM_TIMEOUT)
	else:
		print("[FAIL] 过期房间没有清理"); fails += 1

	# ③b ★ 同一台机器开两份也要能互相看到 ★（用户没有第二台机器，只能双开自测局域网）
	# 回归点：UDP 端口只能被一个进程独占 bind —— 第二个实例 bind 27777 会 err=2、
	# socket 无效、一个包都收不到。现在监听端口是一组（DISCOVERY_PORTS），
	# 主机把信标往整组都发一遍，所以第二份绑到 27787 也能收到。
	var second := LanNet.new()
	add_child(second)                      # _ready 里绑 DISCOVERY_PORTS 里第一个空闲端口
	if second._listener == null:
		print("[FAIL] 同机第二份没能绑到备用发现端口：%s" % second.last_error); fails += 1
	else:
		print("[OK] 同机第二份绑到了备用发现端口 %d（第一份是 %d），最多同时开 %d 份" % [
				second.listen_port, client.listen_port, LanNet.MAX_LOCAL_INSTANCES])
		if second.start_host("第二份的房间"):
			second.poll(0.0)               # 立刻广播一次
			var seen := false
			for i in 10:
				await get_tree().create_timer(0.1).timeout
				client.poll(0.0)
				if not client.rooms().is_empty():
					seen = true
					break
			var nm := ""
			for r in client.rooms():
				if String(r["name"]) == "第二份的房间":
					nm = String(r["name"])
			if seen and nm != "":
				print("[OK] 同机双开：第一份能看到第二份开的房间（信标发到了整组端口）")
			else:
				print("[FAIL] 同机双开看不到第二份的房间 -> %s" % str(client.rooms())); fails += 1
			second.stop_host()
		else:
			print("[FAIL] 同机第二份建房失败：%s" % second.last_error); fails += 1
	second.stop_discovery()
	remove_child(second)
	second.queue_free()
	client._rooms.clear()                  # 别把这条留到后面的断言里

	# ④ 创建房间 → ENet 服务器起来；关闭 → 收干净
	if client.start_host("自检房间"):
		var peer := client.multiplayer.multiplayer_peer
		var ok_up := peer is ENetMultiplayerPeer \
				and (peer as ENetMultiplayerPeer).get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
		# 主机态下推进一帧：会走到 _send_beacon()，那里要统计人数。
		# 回归点：以前写成 peer.get_peers() → 运行时报
		# "Nonexistent function 'get_peers' in base 'ENetMultiplayerPeer'"（开着房间就刷屏）。
		# get_peers() 只在 MultiplayerAPI 上，必须走 multiplayer.get_peers()。
		client.poll(1.1)
		var ok_beacon := client.hosting and client._beacon != null
		if ok_beacon:
			print("[OK] 主机广播信标能统计人数（1 人）且不报错")
		else:
			print("[FAIL] 主机广播信标异常"); fails += 1
		# 自己的房间必须出现在大厅列表里（用户报过"创建房间后回大厅看不到自己的房间"）
		var mine_n := 0
		for r in client.rooms():
			if bool(r.get("mine", false)):
				mine_n += 1
		if mine_n == 1:
			print("[OK] 房主自己的房间会出现在大厅列表里（标记 mine，置顶）")
		else:
			print("[FAIL] 自己的房间没出现在大厅列表（mine 数 = %d）" % mine_n); fails += 1
		client.stop_host()
		var left_n := 0
		for r in client.rooms():
			if bool(r.get("mine", false)):
				left_n += 1
		if left_n == 0:
			print("[OK] 解散房间后自己的房间从列表里消失")
		else:
			print("[FAIL] 解散后房间还留在列表里"); fails += 1
		var ok_down := client.multiplayer.multiplayer_peer == null
		if ok_up and ok_down:
			print("[OK] 创建房间能拉起 ENet 服务器，关闭后端口与信标都收干净")
		else:
			print("[FAIL] ENet 服务器状态不对（up=%s down=%s）" % [str(ok_up), str(ok_down)]); fails += 1
	else:
		print("[FAIL] 创建房间失败：%s" % client.last_error); fails += 1

	# ⑤ 大厅 UI：增行 / 删行都要生效。
	# 回归点：清空房间时 sig 恰好是空串，若"强制刷新"用 "" 当哨兵值就会被判成
	# "没变化"而跳过重建 → 点了「解散」那一行还留在列表里（用户报的"解散没作用"）。
	lan_menu.visible = true
	_refresh_lan_rooms(true)
	var rows_empty := _count_room_rows()
	lan.debug_add_room("10.0.0.9", "UI 测试房间", 5)
	_refresh_lan_rooms(true)
	var rows_one := _count_room_rows()
	lan._rooms.clear()
	_refresh_lan_rooms(true)
	var rows_cleared := _count_room_rows()
	if rows_empty == 0 and rows_one == 1 and rows_cleared == 0:
		print("[OK] 房间列表能正确增行 / 删行（清空后不会残留旧行）")
	else:
		print("[FAIL] 房间列表刷新异常（%d → %d → %d，期望 0 → 1 → 0）" % [
				rows_empty, rows_one, rows_cleared]); fails += 1
	lan_menu.visible = false

	# ⑥ 名册里显示的电脑数量 == 开局后场上的电脑数量（用户明确要求两者一致）
	# 阵营现在由真人自己选，所以假成员要显式给 team（以前是"交替占位"）
	local_team = "CT"
	debug_fake_members = [
		{"name": "假A", "tag": "玩家", "peer": 101, "self": false, "team": "T"},
		{"name": "假B", "tag": "玩家", "peer": 102, "self": false, "team": "CT"},
	]
	var mem := _room_members()          # 本机(CT) + 假A(T) + 假B(CT) → CT 2 真人 / T 1 真人
	var want_ct := _team_bot_count("CT", mem)
	var want_t := _team_bot_count("T", mem)
	_balance_teams_with_bots()
	var have_ct := 0
	var have_t := 0
	for b in bots:
		if b.team == "CT":
			have_ct += 1
		else:
			have_t += 1
	if want_ct == have_ct and want_t == have_t and want_ct + want_t > 0:
		print("[OK] 名册显示几个电脑，场上就是几个电脑（CT %d / T %d）" % [want_ct, want_t])
	else:
		print("[FAIL] 名册与场上电脑数不一致（名册 CT %d/T %d，场上 CT %d/T %d）"
				% [want_ct, want_t, have_ct, have_t]); fails += 1
	debug_fake_members = []
	local_team = "CT"

	# ⑥b 配平按**真人自己选的阵营**分组（不再是"CT/T 交替占位"）。
	#     纯函数断言，跟 UI / 网络无关。
	var fake: Array = [{"team": "CT"}, {"team": "CT"}, {"team": "T"}]
	if _team_bot_count("CT", fake) == 0 and _team_bot_count("T", fake) == 1:
		print("[OK] 换队后电脑配平按各自选的阵营算（CT 2 真人 → 0 电脑 / T 1 真人 → 1 电脑）")
	else:
		print("[FAIL] 阵营分组配平算错（CT %d / T %d，期望 0 / 1）" % [
				_team_bot_count("CT", fake), _team_bot_count("T", fake)]); fails += 1

	# ⑥c 换阵营要真的把角色模型换掉（CT / T 是两套 GLB，不重建就会"选了锐刃还穿磐垒的皮"）
	if player != null:
		var old_vis: Node = player.get("_visual")
		player.set_team("T")
		var new_vis: Node = player.get("_visual")
		if player.team == "T" and new_vis != null and new_vis != old_vis \
				and new_vis.get_parent() == player:
			print("[OK] 换阵营会重建角色模型（旧模型已移除、新模型已挂到角色上）")
		else:
			print("[FAIL] 换阵营没有重建角色模型（team=%s）" % player.team); fails += 1
		player.set_team("CT")

	# ⑦ 位置不够时踢 bot 腾位置（CS 的做法）
	while players.size() < 16:
		_add_bot_pair(get_tree().current_scene)
		await get_tree().create_timer(0.15).timeout
	var before := players.size()
	var kicked := _make_room_for_player()
	var after := players.size()
	print("[LAN] 踢 bot 腾位置：场上 %d → %d 人（每队上限 %d）" % [before, after, MAX_TEAM_PLAYERS])
	if kicked and after == before - 1:
		print("[OK] 两队都满时新玩家加入会踢掉一个 bot 腾位置")
	else:
		print("[FAIL] 没有正确踢 bot 腾位置"); fails += 1
	if not _make_room_for_player():
		print("[OK] 有空位时不踢 bot")
	else:
		print("[FAIL] 有空位也踢了 bot"); fails += 1

	client.stop_discovery()
	client.leave()
	print("=== 局域网自检：%s ===" % ["全部通过" if fails == 0 else "%d 项失败" % fails])
	get_tree().quit(0 if fails == 0 else 1)


# 局域网界面截图（跑法：godot --path <项目> --screenshot-lan）
# 真开一个房间 + 塞几个假房间（本机不一定有别的机器在开房），
# 把「界面1 房间列表」和「界面2 房间界面」各截一张，核对排版
func _schedule_lan_screenshot() -> void:
	# 先开房，这样界面1 里能看到自己的房间（「返回房间」/「解散」两个按钮）
	# 不覆盖输入框：截图直接反映"打开游戏看到的默认昵称"（玩家 + 3 位随机数字）
	_read_nick()
	lan.start_host(UIText.ROOM_NAME_FMT % player_nick)
	_open_lan_lobby()
	lan.debug_add_room("192.168.1.7", "老王的房间", 3)
	lan.debug_add_room("192.168.1.12", "小明的房间", 1)
	lan.debug_add_room("192.168.1.31", "训练场（带 bot）", 8)
	_refresh_lan_rooms(true)
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "UI_局域网大厅.png")
	print("[Screenshot] LAN lobby saved")

	# 界面2：右上角房间名 / 状态栏 / 成员名册（含「踢」按钮）/ 难度 / 缩略图
	debug_fake_members = [
		{"name": "玩家 2", "tag": "玩家", "peer": 2, "self": false, "team": "CT"},
		{"name": "玩家 3", "tag": "玩家", "peer": 3, "self": false, "team": "T"},
	]
	_open_map_select()
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "UI_房间界面.png")
	print("[Screenshot] Room screen saved")
	debug_fake_members = []
	lan.stop_host()
	get_tree().quit()


# 特别鸣谢窗口截图（跑法：godot --path <项目> --screenshot-credits）
# 只截大窗口本身；要检查右下角那个「特别鸣谢」按钮用 --screenshot-lan。
# 临时诊断：单机进对局后到底能不能动（跑法：godot --headless --path . --diag-move）
func _diag_move() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	await get_tree().create_timer(0.6).timeout
	if player == null:
		print("[DIAG] player 是 null！角色没建出来")
		get_tree().quit(1)
		return
	print("[DIAG] 角色=%s  authority=%d  unique_id=%d  is_authority=%s  alive=%s  team=%s  名字=%s" % [
			str(player), player.get_multiplayer_authority(), multiplayer.get_unique_id(),
			str(player.is_multiplayer_authority()), str(player.alive), player.team, player.name])
	var before := player.global_position
	Input.action_press("move_forward")
	await get_tree().create_timer(1.5).timeout
	Input.action_release("move_forward")
	var after := player.global_position
	print("[DIAG] 移动前 %s → 移动后 %s（位移 %.2f m）" % [
			str(before), str(after), before.distance_to(after)])
	print("[DIAG] 同步器=%s  子节点数=%d  process_mode=%d  鼠标模式=%d" % [
			str(player.get("_sync") != null), player.get_child_count(),
			player.process_mode, Input.get_mouse_mode()])
	# ★ 压测"别人开火"特效：真实对局里 8 个 bot 一秒能打十几发，
	#   如果特效节点不回收，几秒钟就能把场景塞满（画面糊成一片 = 玩不了）
	var before_n := get_tree().current_scene.get_child_count()
	for i in 100:
		player._remote_muzzle_flash(player.global_position + Vector3(0, 1.5, -1.0))
	await get_tree().create_timer(1.0).timeout
	var after_n := get_tree().current_scene.get_child_count()
	var lights := 0
	var quads := 0
	for n in get_tree().current_scene.get_children():
		if n is OmniLight3D:
			lights += 1
		elif n is MeshInstance3D:
			quads += 1
	print("[DIAG] 连发 100 次特效：场景子节点 %d → %d（1 秒后），残留 灯=%d 面片=%d" % [
			before_n, after_n, lights, quads])

	# 顺手开一枪再截个图：看枪口火焰会不会一直亮着
	player.fire()
	await get_tree().create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "DIAG_开火后.png")
	print("[DIAG] 截图已存 DIAG_开火后.png")
	get_tree().quit()


# ============================================================ 局域网对局同步自检（双进程）
#
# 用户只有一台机器，所以用**两个进程**跑真实的 UDP 广播 + ENet 连接来验证联机：
#   进程 A：godot --path . --lan-host
#   进程 B：godot --path . --lan-client
# A 建房 → 等 B 连上 → 开局 → 跑几秒 → 打印"我这边的角色表（名字/阵营/authority/坐标/血量）"
# B 找房 → 加入 → 等 A 开局 → 跑几秒 → 打印同样内容
# 两条日志一对比就知道同步对不对：角色数一致、电脑在动、两边同一角色的坐标接近。
# （实测：同机两个进程能互相发现房间 —— 见 lan.gd DISCOVERY_PORTS）

func _lan_autotest_host() -> void:
	_read_nick()
	if not lan.start_host(UIText.ROOM_NAME_FMT % player_nick):
		print("[LAN2] 房主建房失败：%s" % lan.last_error)
		get_tree().quit(1)
		return
	_open_lan_lobby()
	print("[LAN2] 房主已开房「%s」，监听端口 %d" % [lan.room_name, lan.listen_port])
	var waited := 0.0
	while multiplayer.get_peers().size() == 0 and waited < 40.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	if multiplayer.get_peers().is_empty():
		print("[LAN2] 失败：等不到客户端连进来")
		get_tree().quit(1)
		return
	print("[LAN2] 房主看到对端：%s" % str(multiplayer.get_peers()))
	await get_tree().create_timer(1.5).timeout     # 等客户端把昵称报上来
	print("[LAN2] 房主名册：%s" % str(_room_members()))
	_start_game_with_map("iceworld")
	# 房主也往前走一段 —— 验证反方向（房主 → 客户端）的位置同步
	await _lan_autotest_trace("房主", 12.0, 1.0, 2.5, 3.5, 6.0, 4.5)
	_lan_autotest_report("房主")
	lan.stop_host()
	get_tree().quit()


func _lan_autotest_client() -> void:
	_read_nick()
	var waited := 0.0
	while lan.rooms().is_empty() and waited < 40.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	var rooms: Array = lan.rooms()
	print("[LAN2] 客户端看到 %d 个房间：%s" % [rooms.size(), str(rooms)])
	var ip := ""
	for r in rooms:
		if not bool(r.get("mine", false)):
			ip = String(r["ip"])
	if ip == "":
		print("[LAN2] 失败：没发现别人的房间（本机监听端口 %d）" % lan.listen_port)
		get_tree().quit(1)
		return
	if not lan.join(ip):
		print("[LAN2] 失败：连接 %s 失败（%s）" % [ip, lan.last_error])
		get_tree().quit(1)
		return
	print("[LAN2] 客户端正在连接 %s" % ip)
	waited = 0.0
	while not lan.is_connected_to_host() and waited < 20.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	print("[LAN2] 客户端已连接房主：%s" % str(lan.is_connected_to_host()))
	# 跟房主选同一队 → 对面那队会按配平公式自动补电脑，顺便验证 bot 的同步
	_on_pick_team("CT")
	await get_tree().create_timer(0.6).timeout
	# 等房主广播开局（state 从 MENU 变掉就说明 _net_start_match 到了）
	waited = 0.0
	while state == STATE.MENU and waited < 40.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	print("[LAN2] 客户端已进对局：state=%d" % state)
	# ★ 让客户端自己的角色往前走一段 ★
	#   房主那份日志里 Player_<客户端id> 的坐标应该跟着离开出生点 —— 这才证明位置同步真的在跑
	#   （两边都站着不动的话，坐标一致只是因为出生点一样，证明不了任何事）。
	await _lan_autotest_trace("客户端", 12.0, 1.0, 2.5, 6.0, 9.0)
	_lan_autotest_report("客户端")
	get_tree().quit()


## 每 0.5s 打一行：谁在什么位置、血量多少。
## 比"最后只看一眼"可靠得多 —— 能看出同步是"一直没动"还是"跑到一半断了"。
func _lan_autotest_trace(who: String, secs: float, walk_after := -1.0, walk_for := 0.0,
		fire_at := -1.0, shot_at := -1.0, add_bot_at := -1.0) -> void:
	var t := 0.0
	var walking := false
	var fired := false
	var added := false
	while t < secs:
		await get_tree().create_timer(0.5).timeout
		t += 0.5
		if walk_after >= 0.0 and not walking and t >= walk_after:
			walking = true
			Input.action_press("move_forward")
		elif walking and t >= walk_after + walk_for:
			walking = false
			Input.action_release("move_forward")
		# 开一枪：验证开火特效的广播（别的机器会重放枪口火光/曳光/血雾）
		if fire_at >= 0.0 and not fired and t >= fire_at and player != null:
			fired = true
			for _i in 3:
				player.fire()
			print("[LAN2] %s 连开 3 枪（测试开火特效/枪声广播）" % who)
		# 按 + 加一对电脑：验证"房主加减电脑会同步给客户端"
		if add_bot_at >= 0.0 and not added and t >= add_bot_at:
			added = true
			_add_bot_pair(get_tree().current_scene)
			print("[LAN2] %s 按了一次 +（加一对电脑）" % who)
		if shot_at >= 0.0 and absf(t - shot_at) < 0.26:
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(
					_shot_dir() + "DIAG_%s_t%.1f.png" % [who, t])
			print("[LAN2] %s 截图 DIAG_%s_t%.1f.png" % [who, who, t])
		var parts: Array = []
		for p in players:
			if is_instance_valid(p):
				parts.append("%s(%.1f,%.1f)hp%.0f" % [
						p.name, p.global_position.x, p.global_position.z, p.health])
		print("[LAN2] %s t=%.1f state=%d r=%d 地面枪=%d 鼠标=%d | %s" % [
				who, t, state, round_num, _ground.size(), Input.get_mouse_mode(), " ".join(parts)])
	if walking:
		Input.action_release("move_forward")


func _lan_autotest_report(who: String) -> void:
	print("[LAN2] ===== %s 报告（state=%d round=%d 比分 CT %d:%d T）=====" % [
			who, state, round_num, ct_wins, t_wins])
	print("[LAN2] 角色数=%d（其中电脑 %d）  我是=%s" % [
			players.size(), bots.size(), player.nick if player != null else "<无>"])
	for p in players:
		if not is_instance_valid(p):
			continue
		print("[LAN2]   %-12s team=%s bot=%-5s authority=%-11d pos=(%6.1f,%5.1f,%6.1f) hp=%.0f anim=%s 主武器=%s" % [
				p.name, p.team, str(p.is_bot), p.get_multiplayer_authority(),
				p.global_position.x, p.global_position.y, p.global_position.z, p.health,
				p.net_anim, p.net_primary if p.net_primary != "" else "-"])
	print("[LAN2] 本机重放「别人开火」特效 %d 次 / 地面武器 %d 把" % [
			CSPlayer.remote_fx_count, _ground.size()])


func _schedule_credits_screenshot() -> void:
	_open_lan_lobby()
	_open_credits()
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir() + "UI_特别鸣谢.png")
	print("[Screenshot] Credits saved")
	get_tree().quit()


# Shift 静步自检（跑法：godot --path <项目> --test-walk）
func _test_walk() -> void:
	var fails := 0

	if InputMap.has_action("walk"):
		print("[OK] 输入映射存在 walk 动作")
	else:
		print("[FAIL] 输入映射缺少 walk 动作"); fails += 1
	var bound := false
	for e in InputMap.action_get_events("walk"):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_SHIFT:
			bound = true
	print("[OK] walk 绑定到 Shift" if bound else "[FAIL] walk 未绑定 Shift")
	if not bound: fails += 1

	var p := CSPlayer.new()
	p.weapons = {1: {"id": "AK47", "mag": 30, "reserve": 90}, 2: {}, 3: {"id": "Knife"}, 4: {}}
	p.active_slot = 1
	p._update_slots()
	# AK47 是步枪档：期望速度 = 基础跑速 × 步枪倍率
	var expect_normal := CSPlayer.RUN_SPEED * float(CSPlayer.WEAPON_SPEED["rifle"])

	p._crouching = false
	p._walking_slow = false
	p._update_speed()
	var normal := p._speed
	if is_equal_approx(normal, expect_normal):
		print("[OK] 正常跑速（步枪）= %.3f" % normal)
	else:
		print("[FAIL] 正常跑速异常 = %.3f（期望 %.3f）" % [normal, expect_normal]); fails += 1

	p._walking_slow = true
	p._update_speed()
	var slow := p._speed
	if is_equal_approx(slow, expect_normal * CSPlayer.WALK_SLOW_MULT):
		print("[OK] 静步速度 = %.3f（跑速 ×%.2f）" % [slow, CSPlayer.WALK_SLOW_MULT])
	else:
		print("[FAIL] 静步速度异常 = %.3f" % slow); fails += 1
	if slow < normal:
		print("[OK] 静步确实比跑慢")
	else:
		print("[FAIL] 静步没有减速"); fails += 1

	p._walking_slow = false
	p._crouching = true
	p._update_speed()
	var crouch_spd := p._speed
	if is_equal_approx(crouch_spd, expect_normal * CSPlayer.CROUCH_MULT):
		print("[OK] 蹲下速度 = %.3f" % crouch_spd)
	else:
		print("[FAIL] 蹲下速度异常 = %.3f" % crouch_spd); fails += 1

	# 蹲下 + Shift 不能二次减速（蹲下已是最慢，Shift 只在站着时生效）
	p._walking_slow = true
	p._update_speed()
	if is_equal_approx(p._speed, crouch_spd):
		print("[OK] 蹲下 + 静步不二次减速（= %.3f）" % p._speed)
	else:
		print("[FAIL] 蹲下 + 静步被重复减速 = %.3f" % p._speed); fails += 1

	# 换武器移速应该不一样（端 AWP 不能跟端小刀一样快）
	p.weapons[1] = {"id": "AWP", "mag": 10, "reserve": 30}
	p._update_slots()
	p._crouching = false
	p._walking_slow = false
	p._update_speed()
	var awp_spd := p._speed
	if awp_spd < normal:
		print("[OK] 端狙击枪比端步枪慢（%.3f < %.3f）" % [awp_spd, normal])
	else:
		print("[FAIL] 狙击枪移速没有比步枪慢 = %.3f" % awp_spd); fails += 1

	print("=== 静步自检完成：", "全部通过" if fails == 0 else "%d 项失败" % fails, " ===")
	get_tree().quit(1 if fails > 0 else 0)


# 击杀信息流调试截图（跑法：godot --path <项目> --screenshot-killfeed）
# 直接往右上角塞几条假击杀，覆盖 步枪 / 狙击 / 手枪 / 刀 四种武器图案，
# 用来核对「枪械图标是否显示、大小与对齐是否合适」。
func _schedule_killfeed_screenshot() -> void:
	_open_map_select()
	_start_game_with_map("iceworld")
	state = STATE.LIVE
	timer = ROUND_TIME
	if minimap != null:
		minimap.visible = false
	await get_tree().create_timer(1.0).timeout
	var rows: Array = [
		["Ghost77", "CT", "AK47", "Viper21", "T"],
		["Viper21", "T", "AWP", "Raptor09", "CT"],
		["Raptor09", "CT", "Deagle", "Ghost77", "T"],
		["YOU", "CT", "Knife", "Reaper55", "T"],
		["Reaper55", "T", "MP5", "Eagle12", "CT"],
	]
	# 倒序插入，最新的排最上面
	for i in range(rows.size() - 1, -1, -1):
		var r: Array = rows[i]
		_feed_add_row(str(r[0]), str(r[1]), str(r[2]), str(r[3]), str(r[4]))
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shot_dir() + "击杀信息流.png")
	print("[Screenshot] Killfeed saved")
	get_tree().quit()


func _add_environment(scene: Node) -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	# 天空：**蓝天**。墙外是虚无，所以地平线以下也刷成同色蓝 ——
	# 从上往下看时，围墙外就是一片蓝天，不会露出"地板"。
	sky_mat.sky_top_color = Color(0.10, 0.34, 0.85)
	sky_mat.sky_horizon_color = Color(0.42, 0.68, 0.97)
	sky_mat.ground_horizon_color = Color(0.42, 0.68, 0.97)
	sky_mat.ground_bottom_color = Color(0.22, 0.48, 0.90)
	sky_mat.sky_curve = 0.06
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_energy_multiplier = 1.35
	# 环境光：**不用 SKY**（天空是深蓝的，会把白雪、米黄石块统统染成蓝灰），
	# 改用固定的暖白色环境光 —— 保住参考图那种"暖米白雪地 + 浅米黄石块"的调子。
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.94, 0.94, 0.96)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 3.0
	# 雾：淡蓝白，只作用于远景（密度压很低，近处雪地不泛灰）
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.78, 0.95)
	env.fog_density = 0.0012
	env.fog_aerial_perspective = 0.25
	we.environment = env
	for n in scene.find_children("*", "DirectionalLight3D", true, false):
		var dl := n as DirectionalLight3D
		dl.light_energy = 1.1
		dl.light_color = Color(0.96, 0.98, 1.0)
	scene.add_child(we)


# =========================================================== 地图
func _build_map(_map_id: String) -> void:
	nav_obstacles.clear()          # 障碍物在 _make_static 里重新登记
	_build_map_iceworld()


# ============================================================ 冰雪世界（经典雪地对枪小图）
# 经典雪地对枪小图（南北 42 x 东西 36 米）：
#   · 矩形雪地，四面围墙（内角有台阶状平台）；墙外雪山背景环
#   · 场心 2×2 聚集的冰石大方块：2.5m 高实心掩体，方块间留十字窄缝
#   · 两翼各一块小方块点缀
#   · 8 道深色砖墙散布全图作齐腰掩体（中心对称布置）
#   · 地上散落步枪（本图招牌：出生就满地捡枪）
#   · A/B 包点：场地南北两端空地，地面发光圆 + 上方 A/B 字母
const ICE_HALF_X := 18.0      # 场地半宽（米）
const ICE_HALF_Z := 21.0      # 场地半长（米）
const ICE_WALL_H := 3.2       # 围墙高（矮墙，抬头能看见雪山天空）

# 场心 2×2 大石块（几乎填满场地中央，块间只留一条细缝 —— 参考图的核心特征）
# 尺寸按"出生点完全被遮挡"反推：出生点 x 铺到 ±10.5，石块群必须覆盖到 ±11.5，
# 所以 石块边长 10.5 + 中心 ±6.25 → 覆盖 ±11.5，十字缝正好 2.0m。
const BLOCK_POS: Array[Vector3] = [
	Vector3(-6.25, 0, -6.25), Vector3(6.25, 0, -6.25),
	Vector3(-6.25, 0, 6.25), Vector3(6.25, 0, 6.25),
]
const BLOCK_W := 10.5         # 石块边长（四块之间只留 2.0m 窄缝）
const BLOCK_H := 2.9          # 石块高（比人高一大截，是实打实的高掩体）

# 6 个小围墙（**全部横着放**：长边沿 X 轴，长度规格完全一致）
# 长度关系（用户的硬要求）：
#   大围墙内表面(∓18.0) 到 石块边(∓11.5) 的净距 = 6.5m
#   「中间小墙 + 上/下小墙」两段刚好把这个距离铺满 → 每段 3.25m
#   即：中间小墙 -18.0 → -14.75，上/下小墙 -14.75 → -11.5，**首尾相接且中间墙紧贴围墙**
# 注意：围墙厚度 t=1.0（`_build_map_iceworld` 里的局部变量），
#       墙中心在 ∓(18.0+0.5)=∓18.5 → 内表面在 ∓18.0（**不是 17.5**）
const WALL_L := 3.25          # 墙长（X 方向，横着）—— 上下 4 道与中间 2 道**完全一致**
const WALL_H := 1.4           # 墙高（齐胸，蹲下能藏）
const WALL_T := 0.5           # 墙厚（Z 方向）
# 6 个小围墙分两种：
#   · 「上下」4 道：**上边/下边与石块边严格共线**，直立、横着放
#   · 「中间」2 道：同上规格，一端**紧挨着大围墙内侧**
# 石块外沿 = ∓(6.25 + 10.5/2) = ∓11.5（石块是完整立方体，没有进退）
# 上排小墙的上边（北缘）对齐 -11.5 → 中心 z = -11.5 + T/2 = -11.25
# 下排小墙的下边（南缘）对齐 +11.5 → 中心 z = +11.5 - T/2 = +11.25
# 上/下小墙 X 中心 = ∓(11.5 + WALL_L/2) = ∓13.125
const SMALL_WALLS: Array[Vector3] = [
	Vector3(-13.125, 0, -11.25),  # 上排石块**上边**的向西延长
	Vector3(13.125, 0, -11.25),   # 上排石块**上边**的向东延长
	Vector3(-13.125, 0, 11.25),   # 下排石块**下边**的向西延长
	Vector3(13.125, 0, 11.25),    # 下排石块**下边**的向东延长
]
# 「中间」2 道矮墙：**横着放**、同长度，一端**紧贴大围墙内表面(∓18.0)**（零空隙）
# X 中心 = ∓(18.0 - WALL_L/2) = ∓16.375
const MID_WALLS: Array[Vector3] = [
	Vector3(-16.375, 0, 0.0),     # 左侧 · 中（紧贴西围墙内侧，横着）
	Vector3(16.375, 0, 0.0),      # 右侧 · 中（紧贴东围墙内侧，横着）
]

const ICE_SNOW := Color(0.92, 0.93, 0.96)
const ICE_WALL := Color(0.95, 0.95, 0.95)               # 石材 albedo = 白色，让 _stone_tex 的纹理色完整显示
const ICE_BRICK := Color(0.95, 0.95, 0.95)              # 砖墙 albedo = 白色，让 _brick_tex 的深色砖纹完整显示
const ICE_MOUNTAIN := Color(0.95, 0.95, 0.95)           # 雪山色：让 _snow_mountain_tex 的纹理色主导
const ICE_STONE := Color(0.95, 0.95, 0.95)              # 中央大石块：浅灰石色（纹理主导）
const ICE_CRATE := Color(0.95, 0.95, 0.95)              # 小木箱：深棕木色（纹理主导）


func _build_map_iceworld() -> void:
	var hx := ICE_HALF_X
	var hz := ICE_HALF_Z
	var t := 1.0

	# 包点位置：场地南北两端空地（A 南、B 北）
	bombsite_a = Vector3(0, 0, 15)
	bombsite_b = Vector3(0, 0, -15)

	# 雪地：只铺场地内部（外围是虚无，不铺地面，避免露出"悬崖外的地板"）
	_make_static(Vector3(0, -0.5, 0), Vector3(hx * 2 + 0.2, 1, hz * 2 + 0.2),
			ICE_SNOW, false, _ice_floor_tex(), Vector3(14, 14, 14))

	# 四面围墙：**笔直**（不倾斜），石材砌块贴面
	var wuv := Vector3(12, 1, 1)
	_make_static(Vector3(0, ICE_WALL_H * 0.5, -hz - t * 0.5),
			Vector3(hx * 2 + t * 2, ICE_WALL_H, t), ICE_WALL, true, _wall_tex(), wuv)
	_make_static(Vector3(0, ICE_WALL_H * 0.5, hz + t * 0.5),
			Vector3(hx * 2 + t * 2, ICE_WALL_H, t), ICE_WALL, true, _wall_tex(), wuv)
	_make_static(Vector3(-hx - t * 0.5, ICE_WALL_H * 0.5, 0),
			Vector3(t, ICE_WALL_H, hz * 2 + t * 2), ICE_WALL, true, _wall_tex(), wuv)
	_make_static(Vector3(hx + t * 0.5, ICE_WALL_H * 0.5, 0),
			Vector3(t, ICE_WALL_H, hz * 2 + t * 2), ICE_WALL, true, _wall_tex(), wuv)

	# 场心 2×2 大石块（中间留 4 米十字通道）
	for p in BLOCK_POS:
		_make_stone_block(p.x, p.z)

	# 「上下」4 道小围墙：上边/下边与石块边严格共线（直立、横着放）
	for c in SMALL_WALLS:
		_make_static(Vector3(c.x, WALL_H * 0.5, c.z),
				Vector3(WALL_L, WALL_H, WALL_T), ICE_CRATE, true,
				_crate_tex(), Vector3(1.0, 0.5, 0.25))

	# 「中间」2 道：同样横着放、同长度的矮墙，贴着左右大围墙内侧
	for c in MID_WALLS:
		_make_static(Vector3(c.x, WALL_H * 0.5, c.z),
				Vector3(WALL_L, WALL_H, WALL_T), ICE_CRATE, true,
				_crate_tex(), Vector3(1.0, 0.5, 0.25))

	# 围墙外是**虚无**：不放任何东西（没有地面、没有远山）

	# 出生点面前各一把枪（其余位置不放枪）
	_build_spawn_weapons()
	# 包点圆形标记（地面发光圆盘 + 贴地 A/B 字母）
	_make_site_disk(bombsite_a, Color(0.95, 0.35, 0.30), "A")
	_make_site_disk(bombsite_b, Color(0.40, 0.65, 0.95), "B")
	_build_pickups()


# ============================================================ 地图工具
func _rebuild_map(map_id: String) -> void:
	for c in map_root.get_children():
		map_root.remove_child(c)
		c.queue_free()
	selected_map = map_id
	_build_spawns()
	_build_map(map_id)
	_build_nav_grid()
	if minimap != null:
		minimap.reset_walls()


# ============================================================ 导航栅格（bot 寻路）
# 地图是代码生成的轴对齐方块掩体，所以直接在建图时把每块障碍物的 AABB 收集起来，
# 铺成一张 0.5m 的栅格交给 AStarGrid2D 跑 A*。
#
# 为什么不烘焙 NavigationMesh：地图是运行时用 BoxMesh 拼的，没有现成的 mesh 源；
# 而且方块接缝（尤其场心那条 2m 十字缝）烘出来的 navmesh 经常破洞，
# bot 照样会卡在那儿 —— 栅格反而最稳，6048 格跑一次 A* 也就零点几毫秒。
var nav_obstacles: Array = []
var _nav: AStarGrid2D = null

const NAV_CELL := 0.5       # 栅格边长（米）
const NAV_AGENT_R := 0.55   # 障碍物膨胀半径：让路径离墙面留出角色半径，不贴着蹭

func _build_nav_grid() -> void:
	if _nav != null:
		_nav = null
	var cols := int(ceil(ICE_HALF_X * 2.0 / NAV_CELL))
	var rows := int(ceil(ICE_HALF_Z * 2.0 / NAV_CELL))
	_nav = AStarGrid2D.new()
	_nav.region = Rect2i(0, 0, cols, rows)
	_nav.cell_size = Vector2(NAV_CELL, NAV_CELL)
	_nav.offset = Vector2(-ICE_HALF_X, -ICE_HALF_Z)
	# 允许贴着障碍物的角走：否则场心那条 2m 十字缝会被判成走不通
	_nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	_nav.update()
	for o in nav_obstacles:
		var bb: AABB = o
		_nav_mark_box(bb.position.x - NAV_AGENT_R, bb.position.z - NAV_AGENT_R,
				bb.end.x + NAV_AGENT_R, bb.end.z + NAV_AGENT_R)
	# 给每格一个 ±18% 的随机通行代价：A* 不再永远给同一条"最优解"，
	# 不同回合、不同 bot 会走出不同路线，不会像在放录像。
	# （幅度压在 ±20%：足够让不同回合走出不同路线，又不至于绕远/贴墙走怪路）
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for y in rows:
		for x in cols:
			_nav.set_point_weight_scale(Vector2i(x, y), rng.randf_range(0.80, 1.20))


func _nav_mark_box(x0: float, z0: float, x1: float, z1: float) -> void:
	var c0 := _nav_cell(Vector2(x0, z0))
	var c1 := _nav_cell(Vector2(x1, z1))
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if cx < 0 or cz < 0 or cx >= _nav.region.size.x or cz >= _nav.region.size.y:
				continue
			_nav.set_point_solid(Vector2i(cx, cz), true)


func _nav_cell(w: Vector2) -> Vector2i:
	return Vector2i(
		int((w.x - _nav.offset.x) / _nav.cell_size.x),
		int((w.y - _nav.offset.y) / _nav.cell_size.y))


# 找离 c 最近的可走格子（起点/终点正好落在障碍里时用），找不到返回 (-1,-1)
func _nav_free_near(c: Vector2i) -> Vector2i:
	if c.x >= 0 and c.y >= 0 and c.x < _nav.region.size.x and c.y < _nav.region.size.y \
			and not _nav.is_point_solid(c):
		return c
	for r in range(1, 10):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var n := Vector2i(c.x + dx, c.y + dz)
				if n.x < 0 or n.y < 0 or n.x >= _nav.region.size.x or n.y >= _nav.region.size.y:
					continue
				if not _nav.is_point_solid(n):
					return n
	return Vector2i(-1, -1)


# bot 调用：求一条从 from 到 to 的路径，返回世界坐标点列（x,z）。找不到返回空。
func nav_path(from: Vector3, to: Vector3) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _nav == null:
		return out
	var a := _nav_free_near(_nav_cell(Vector2(from.x, from.z)))
	var b := _nav_free_near(_nav_cell(Vector2(to.x, to.z)))
	if a.x < 0 or b.x < 0:
		return out
	var ids := _nav.get_id_path(a, b)
	for id in ids:
		var vid: Vector2i = id
		out.append(_nav.offset + (Vector2(vid) + Vector2(0.5, 0.5)) * _nav.cell_size)
	return out


# bot 选绕行中转点用：世界坐标处是否可通行（在栅格范围内且不是实心点）
func nav_is_free(world: Vector3) -> bool:
	if _nav == null:
		return true
	var c := _nav_cell(Vector2(world.x, world.z))
	return _nav_free_near(c) == c


# bot 游走用：随机取一个可走点
func nav_random_point() -> Vector3:
	if _nav == null:
		return Vector3(randf_range(-ICE_HALF_X, ICE_HALF_X), 0.0,
				randf_range(-ICE_HALF_Z, ICE_HALF_Z))
	for i in 40:
		var c := Vector2i(randi() % _nav.region.size.x, randi() % _nav.region.size.y)
		if not _nav.is_point_solid(c):
			return Vector3(_nav.offset.x + (float(c.x) + 0.5) * _nav.cell_size.x, 0.0,
					_nav.offset.y + (float(c.y) + 0.5) * _nav.cell_size.y)
	return Vector3.ZERO


# 建一个静态方块（墙体 / 掩体 / 台阶通用）
func _make_static(pos: Vector3, size: Vector3, color: Color, permeable: bool,
		texture: Texture2D = null, uv_scale: Vector3 = Vector3(1, 1, 1)) -> void:
	var body := StaticBody3D.new()
	if permeable:
		body.collision_layer |= 8
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if texture != null:
		mat.albedo_texture = texture
		mat.uv1_scale = uv_scale
	mat.roughness = 0.85
	box.material = mat
	mi.mesh = box
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	body.position = pos
	map_root.add_child(body)
	# permeable=true 的方块（围墙 / 石块 / 掩体）登记为寻路障碍，
	# 供 bot 的栅格 A* 使用。雪地地面传的是 false，不会被算进去。
	if permeable:
		nav_obstacles.append(AABB(pos - size * 0.5, size))


# 调试用：在出生点画一个小圆盘（CT 蓝 / T 红），方便一眼确认出生点位置
func _spawn_dot(pos: Vector3, color: Color) -> void:
	var dot := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.55
	cyl.bottom_radius = 0.55
	cyl.height = 0.06
	var dm := StandardMaterial3D.new()
	dm.albedo_color = color
	dm.emission_enabled = true
	dm.emission = color
	dm.emission_energy_multiplier = 0.7
	cyl.material = dm
	dot.mesh = cyl
	dot.position = pos + Vector3(0, 0.07, 0)
	map_root.add_child(dot)


# 包点视觉标记（旧版：两道贴地横条，新版用 _make_site_disk 替代）
func _site_marker(pos: Vector3, _color: Color) -> void:
	pass


# 包点圆形标记：地面发光圆盘 + **贴地**的 A/B 字母，
# A 红、B 蓝，半透明叠加在雪地上，远看也很醒目
func _make_site_disk(pos: Vector3, color: Color, label_text: String) -> void:
	# 地面圆盘（半透明发光，不挡路，小地图上可见）
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var cyl_mesh := CylinderMesh.new()
	cyl_mesh.top_radius = 2.6
	cyl_mesh.bottom_radius = 2.6
	cyl_mesh.height = 0.04
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.55)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cyl_mesh.material = mat
	mi.mesh = cyl_mesh
	body.add_child(mi)
	body.position = pos + Vector3(0, 0.04, 0)
	map_root.add_child(body)

	# A/B 字母：**平贴在地面上**（绕 X 轴 -90° 躺平，且关掉 billboard）
	var lbl := Label3D.new()
	lbl.text = label_text
	lbl.font_size = 40
	lbl.outline_size = 8
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.modulate = color
	lbl.pixel_size = 0.04
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.rotation = Vector3(-PI * 0.5, 0, 0)   # 躺平贴地
	lbl.position = pos + Vector3(0, 0.06, 0)
	lbl.no_depth_test = false
	map_root.add_child(lbl)


# ---------------------------------------------------------------- 出生点武器 / 掉落物
# 每队 8 把主武器（双方一致）：AK47 / M4A1 / AWP / MP5 / P90 / XM1014 / Deagle / M249
const SPAWN_WEAPON_IDS: Array[String] = [
	"AK47", "M4A1", "AWP", "MP5", "P90", "XM1014", "Deagle", "M249",
]

# 每个出生点面前摆一把对应的枪（T 与 CT 各自一排，顺序一致）
# R7 第 5 项：标记为"出生点配枪"，每回合开始调用 _respawn_spawn_weapons() 重新铺一遍
func _build_spawn_weapons() -> void:
	var weapons := WeaponDatabase.weapons()
	for i in ct_spawns.size():
		var wid: String = SPAWN_WEAPON_IDS[i % SPAWN_WEAPON_IDS.size()]
		if not weapons.has(wid):
			wid = "AK47"
		_make_pickup(_weapon_front_of(ct_spawns[i]), wid, true)
	for i in t_spawns.size():
		var wid: String = SPAWN_WEAPON_IDS[i % SPAWN_WEAPON_IDS.size()]
		if not weapons.has(wid):
			wid = "AK47"
		_make_pickup(_weapon_front_of(t_spawns[i]), wid, true)


# 每回合开始：清掉上一回合的出生点配枪（含被捡走/丢下的），重新铺 16 把
# 玩家手动丢在地上的枪也会一并清掉，避免每回合地上越堆越多
func _respawn_spawn_weapons() -> void:
	# ★ 客户端不自己铺 ★：地面武器全部由房主广播过来（见 _net_ground）
	if net_is_client():
		return
	for id in _ground_nodes.keys():
		var n = _ground_nodes[id]
		if is_instance_valid(n):
			var par: Node = n.get_parent()
			if par != null:
				par.remove_child(n)
			n.queue_free()
	_ground_nodes.clear()
	_ground.clear()
	_build_spawn_weapons()
	_ground_dirty = true


# 出生点"面前"的位置：CT 朝北(-Z)、T 朝南(+Z)，往前 1.1 米
func _weapon_front_of(spawn: Vector3) -> Vector3:
	var fwd := 1.1
	if spawn.z < 0.0:      # T 在 z=-17，朝南(+Z)
		return Vector3(spawn.x, 0.0, spawn.z + fwd)
	return Vector3(spawn.x, 0.0, spawn.z - fwd)   # CT 在 z=+17，朝北(-Z)


# ---------------------------------------------------------------- 地面武器（房主记账）
# 地上的枪由**房主统一记账**：房主给每把枪一个自增 id，任何增减都广播整张表。
# 客户端不自己判断"能不能捡"，只把"我踩到了第 N 号枪"报给房主，房主校验后再广播。
# ★ 不这么做的话两台机器地上的枪会越差越多（你捡走了、我这边还躺在地上）。
var _ground: Dictionary = {}          # id -> {"w": 武器id, "p": Vector3, "s": is_spawn, "a": arm_delay}
var _ground_nodes: Dictionary = {}    # id -> WeaponPickup 节点（本机显示用）
var _ground_next_id := 1
var _ground_dirty := false


## 把账本里的枪同步到本机的节点（多退少补）
func _rebuild_ground_nodes() -> void:
	for id in _ground_nodes.keys():
		if _ground.has(id):
			continue
		var n = _ground_nodes[id]
		if is_instance_valid(n):
			var par: Node = n.get_parent()
			if par != null:
				par.remove_child(n)
			n.queue_free()
		_ground_nodes.erase(id)
	for id in _ground:
		_spawn_ground_node(int(id), _ground[id])


func _spawn_ground_node(id: int, rec: Dictionary) -> void:
	if _ground_nodes.has(id) and is_instance_valid(_ground_nodes[id]):
		return
	var area := WeaponPickup.new()
	area.net_id = id
	area.weapon_id = str(rec["w"])
	area.is_spawn = bool(rec.get("s", false))
	area.arm_delay = float(rec.get("a", 0.0))
	area.collision_layer = 0
	area.collision_mask = 1            # 检测站在 layer 1 的玩家
	area.monitoring = true
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.3, 1.6, 1.3)
	col.shape = shape
	col.position = Vector3(0, 0.8, 0)
	area.add_child(col)

	# 武器模型（躺在地上，绕自身 Y 轴缓慢自转，方便看清）
	var holder := Node3D.new()
	# y 抬到"枪身半厚"的位置，让枪贴地而不是陷进雪里
	holder.position = Vector3(0, 0.09, 0)
	var model := _load_ground_weapon(area.weapon_id)
	if model != null:
		holder.add_child(model)
	area.add_child(holder)

	area.position = rec["p"]
	map_root.add_child(area)
	_ground_nodes[id] = area


func _broadcast_ground() -> void:
	if lan == null or not lan.hosting:
		return
	_net_ground.rpc(_ground)


@rpc("authority", "call_remote", "reliable")
func _net_ground(table: Dictionary) -> void:
	_ground = table.duplicate(true)
	_rebuild_ground_nodes()


## 房主从账本里拿掉一把枪（被捡走 / 每回合清场）
func take_ground(id: int) -> void:
	if not _ground.has(id):
		return
	_ground.erase(id)
	_ground_dirty = true
	var n = _ground_nodes.get(id)
	if is_instance_valid(n):
		var par: Node = n.get_parent()
		if par != null:
			par.remove_child(n)
		n.queue_free()
	_ground_nodes.erase(id)


## 客户端请求捡枪。房主**只信"你在枪旁边"这件事**，不信客户端说"我捡到了"。
func request_pickup(pl: CSPlayer, ground_id: int) -> void:
	if pl == null or not net_is_client():
		return
	_net_request_pickup.rpc_id(1, pl.get_path(), ground_id)


@rpc("any_peer", "call_remote", "reliable")
func _net_request_pickup(pl_path: NodePath, ground_id: int) -> void:
	if not multiplayer.is_server() or not _ground.has(ground_id):
		return
	var pl := get_node_or_null(pl_path) as CSPlayer
	if pl == null or not pl.alive:
		return
	var rec: Dictionary = _ground[ground_id]
	var at: Vector3 = rec["p"]
	if pl.global_position.distance_to(at) > 2.0:
		return                       # 离得太远 → 不认（防作弊 / 防误判）
	if not try_pickup_weapon(pl, str(rec["w"])):
		return
	take_ground(ground_id)


## 客户端按 G 丢枪：本机扣掉手里的枪，地上那把由房主记账后广播回来
@rpc("any_peer", "call_remote", "reliable")
func _net_drop_weapon(pos: Vector3, wid: String) -> void:
	if not multiplayer.is_server():
		return
	_make_pickup(pos, wid, false, DROP_ARM_DELAY)


# 掉在地上的枪：Area3D 触发体（站上去即捡），带一个悬浮旋转的模型
# is_spawn  := true 表示"出生点配枪"，每回合开始会重新铺一遍（捡了也没关系）
# arm_delay := 落地后多少秒内不可被捡（防止"按 G 丢出去的枪立刻又被自己捡回来"）
# ★ 客户端直接 return：地面武器全部由房主广播过来（见 _net_ground）★
func _make_pickup(pos: Vector3, weapon_id: String, is_spawn := false, arm_delay := 0.0) -> void:
	if net_is_client():
		return
	var id := _ground_next_id
	_ground_next_id += 1
	_ground[id] = {"w": weapon_id, "p": pos, "s": is_spawn, "a": arm_delay}
	_spawn_ground_node(id, _ground[id])
	_ground_dirty = true


# 躺在地上的枪：用和手持同一套 GLB。
# 关键点（之前看起来"不像枪"的原因）：
#   ① fpv 模型里**带手臂**，地上必须隐藏手臂；
#   ② 每个模型的原点/朝向/单位都不一样，不能直接 scale 0.9 + 转 90°；
#      要按包围盒把「最长轴 = 枪长」统一归一到 0.85m，再平放到地面；
#   ③ 要居中，否则模型可能飘在原点旁边。
const GROUND_GUN_LEN := 0.85      # 地上枪的统一长度（米）
const GROUND_GUN_FLAT := 0.0      # 平放时离地高度，由调用方决定

func _load_ground_weapon(weapon_id: String) -> Node3D:
	var inst := _instance_weapon_glb(weapon_id)
	if inst == null:
		return null

	# 1) 隐藏第一人称手臂
	_hide_arms(inst)

	# 2) 测包围盒 → 找最长轴（枪长方向）与次长轴（枪"厚度"方向）
	inst.transform = Transform3D.IDENTITY
	var aabb := _node_aabb(inst)
	var size := aabb.size
	if size.length() < 0.0001:
		return inst
	# 最长轴 = 枪长（fpv 模型里通常是 Z）；次长轴 = 枪身厚度（如 AK 的 0.24）
	var axis := 0
	var len := size.x
	if size.y > len:
		axis = 1
		len = size.y
	if size.z > len:
		axis = 2
		len = size.z
	if len < 0.0001:
		return inst
	var rest: Array[int] = []
	for a: int in [0, 1, 2]:
		if a != axis:
			rest.append(a)
	var thick_axis: int = rest[0]
	if size[rest[1]] > size[rest[0]]:
		thick_axis = rest[1]

	# 3) 先摆正：把「枪长轴」统一转到 Z（模型原本的持握方向）
	var to_z := Basis.IDENTITY
	if axis == 0:
		to_z = Basis(Vector3.UP, -PI * 0.5)            # X → Z
	elif axis == 1:
		to_z = Basis(Vector3.RIGHT, -PI * 0.5)         # Y → Z
	# 4) 再绕 Z（枪长）转 90°：让枪的"厚度"朝地面、"窄边"朝上
	#    —— 这才是枪**侧躺**在地上的姿态（从上往下看到的是枪的侧面）
	var lie := Basis(Vector3.BACK, PI * 0.5)           # 绕 Z 轴
	var b := lie * to_z
	# 5) 最后把枪长从 Z 摆到 **世界 X**，并整体平放在 XZ 平面
	var to_x := Basis(Vector3.UP, PI * 0.5)            # Z → X
	inst.basis = to_x * b
	var aabb2 := _node_aabb(inst)
	inst.position = -aabb2.get_center()

	# 4) 整体缩放到统一长度
	var holder := Node3D.new()
	holder.add_child(inst)
	var s := GROUND_GUN_LEN / len
	holder.scale = Vector3.ONE * s
	# 缩放后重新居中（缩放在 holder 上，inst 已在原点居中）
	return holder


# 载入武器 GLB，缺素材时回退
func _instance_weapon_glb(weapon_id: String) -> Node3D:
	var path := "res://models/fpv/" + weapon_id + ".glb"
	if not ResourceLoader.exists(path):
		# 缺模型（如 XM1014）→ 用 MP5 顶（霰弹枪大小接近），其余用 AK47
		var fallback := "MP5" if weapon_id == "XM1014" else "AK47"
		path = "res://models/fpv/" + fallback + ".glb"
		if not ResourceLoader.exists(path):
			return null
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	return scene.instantiate()


# 隐藏模型里名为 arms 的手臂节点（地上不能出现手臂）。
# 注意：手臂是 MeshInstance3D，且 GLB 里就叫 "arms"，用可见性隐藏即可
func _hide_arms(root: Node) -> void:
	for n in _walk(root):
		if _is_arms_node(n):
			(n as Node3D).visible = false


# 判断某个节点是不是第一人称手臂
func _is_arms_node(n: Node) -> bool:
	var name_l := String(n.name).to_lower()
	return name_l.contains("arm") or name_l.contains("hand")


# 深度遍历所有子节点
func _walk(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.push_back(c)
	return out


# 求节点（含所有子 MeshInstance3D）在 root 局部空间的包围盒。
# 不依赖节点入树：用逐级累乘的**局部变换**而不是 global_transform
func _node_aabb(root: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		if n is Node3D and n != root:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null and not _is_arms_node(mi):
				var mbb := mi.mesh.get_aabb()
				for i in 8:
					var p: Vector3 = xf * mbb.get_endpoint(i)
					if first:
						aabb = AABB(p, Vector3.ZERO)
						first = false
					else:
						aabb = aabb.expand(p)
		for c in n.get_children():
			stack.push_back([c, xf])
	return aabb


# ---------------------------------------------------------------- 掉落物节点
# 站在上面自动捡起（拿起后自动消失）；缓慢自转方便辨认
class WeaponPickup:
	extends Area3D
	var net_id := 0           # 房主账本里的编号（客户端靠它上报"我要捡第几号"）
	var weapon_id := ""
	var is_spawn := false     # true = 出生点配枪（每回合刷新）
	var arm_delay := 0.0      # 落地后多久才能被捡（秒）
	var _taken := false
	var _armed := true
	var _arm_t := 0.0
	var _check_t := 0.0
	var _req_cool := 0.0      # 客户端上报捡枪的冷却（房主没批准就隔一会儿再报）

	func _ready() -> void:
		add_to_group("weapon_pickups")
		if is_spawn:
			add_to_group("spawn_weapon_pickups")
		if arm_delay > 0.0:
			_armed = false

	func _process(delta: float) -> void:
		rotation.y += delta * 0.9
		# 落地保护：丢出去的枪先"冷却"一会儿才允许被捡，避免刚丢就被自己踩回去
		if not _armed:
			_arm_t += delta
			if _arm_t >= arm_delay:
				_armed = true
		# 兜底扫描：Area3D 的 body_entered 对高速/瞬移不一定触发，
		# 这里每 0.1 秒主动查一次附近有没有玩家
		_req_cool = maxf(_req_cool - delta, 0.0)
		_check_t += delta
		if _check_t < 0.1:
			return
		_check_t = 0.0
		if _req_cool > 0.0:
			return
		_scan()

	func _scan() -> void:
		if _taken or not _armed or GM == null:
			return
		for p in GM.players:
			var pl := p as CSPlayer
			if pl == null or not pl.alive:
				continue
			var d := pl.global_position - global_position
			d.y = 0.0
			if d.length() < 1.05:
				_try_pickup(pl)

	func _try_pickup(pl: CSPlayer) -> void:
		if _taken or weapon_id == "" or GM == null:
			return
		# 客户端不自己判定：只上报"我踩到了第 N 号枪"，房主校验后广播新的地面武器表
		if GM.net_is_client():
			GM.request_pickup(pl, net_id)
			_req_cool = 0.35
			return
		# 人类玩家和 bot 的拾取策略不同，统一交给 GM 判断
		if GM.try_pickup_weapon(pl, weapon_id):
			_taken = true
			GM.take_ground(net_id)
			queue_free()


# 每帧检查玩家是否站在掉落物上（备用：Area3D 触发偶尔漏检，这里做兜底扫描）
func _build_pickups() -> void:
	pass


# 按 G：把当前手里的枪丢到脚边，变成一个可再捡起的掉落物
# 丢出去的距离（1.8m）**要大于** pickup 的检测半径（1.05m），
# 再加 0.9s 落地保护，双重保证"刚丢出去的枪不会立刻又被自己捡回来"
const DROP_DIST := 1.8
const DROP_ARM_DELAY := 0.9

func _drop_current_weapon() -> void:
	if player == null or not player.alive:
		return
	var wid := player.drop_current()
	if wid == "":
		return
	var fwd := -player.global_transform.basis.z
	var at := player.global_position + fwd * DROP_DIST
	at.y = 0.0
	# 客户端只上报"我在这个位置丢了一把 X"，地上的枪由房主记账后广播回来
	if net_is_client():
		_net_drop_weapon.rpc_id(1, at, wid)
	else:
		_make_pickup(at, wid, false, DROP_ARM_DELAY)
	_show_toast(UIText.TOAST_DROP_WEAPON % wid)


# 一块中央大石块：**一个完整的立方体**（不做底座/压顶的进退，外轮廓齐平）
func _make_stone_block(cx: float, cz: float) -> void:
	_make_static(Vector3(cx, BLOCK_H * 0.5, cz),
			Vector3(BLOCK_W, BLOCK_H, BLOCK_W), ICE_STONE, true,
			_block_tex(), Vector3(1.6, 0.7, 1.6))


# ---------------------------------------------------------------- 程序化贴图
# 用多频正弦 + 随机噪声生成无缝纹理，不依赖外部图片资源。
# 结果缓存起来 —— 地图里会反复请求同一张纹理，每次重新生成会很慢。
var _tex_cache: Dictionary = {}

func _make_noise_texture(seedv: int, base: Color, strength: float,
		stripe: float = 0.0, stripe_scale: float = 1.0) -> Texture2D:
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seedv
	for y in size:
		for x in size:
			var u := float(x) / float(size)
			var v := float(y) / float(size)
			var n := sin(u * TAU * 3.0 + float(seedv)) * 0.5
			n += sin(v * TAU * 5.0 + float(seedv) * 1.7) * 0.3
			n += sin((u + v) * TAU * 11.0) * 0.2
			n += rng.randf_range(-0.5, 0.5) * 0.4
			var k := 1.0 + n * strength
			if stripe > 0.0:
				k *= 1.0 - stripe * 0.5 + stripe * (sin(v * TAU * stripe_scale) * 0.5 + 0.5)
			img.set_pixel(x, y, Color(base.r * k, base.g * k, base.b * k))
	return ImageTexture.create_from_image(img)


func _sand_tex() -> Texture2D:
	if not _tex_cache.has("sand"):
		_tex_cache["sand"] = _make_noise_texture(11, Color(0.80, 0.70, 0.52), 0.12, 0.35, 14.0)
	return _tex_cache["sand"]


func _rock_tex() -> Texture2D:
	if not _tex_cache.has("rock"):
		_tex_cache["rock"] = _make_noise_texture(23, Color(0.69, 0.61, 0.47), 0.20, 0.18, 5.0)
	return _tex_cache["rock"]


func _wood_tex() -> Texture2D:
	# 深棕色木质（角落小木箱那种），带横向木纹
	if not _tex_cache.has("wood"):
		_tex_cache["wood"] = _make_noise_texture(37, Color(0.36, 0.22, 0.12), 0.18, 0.45, 9.0)
	return _tex_cache["wood"]


func _snow_tex() -> Texture2D:
	# 雪地：白底 + 轻微颗粒（颗粒太弱会糊成纯白一片，看不出雪面质感）
	if not _tex_cache.has("snow"):
		_tex_cache["snow"] = _make_noise_texture(53, Color(0.93, 0.94, 0.96), 0.13, 0.06, 7.0)
	return _tex_cache["snow"]


# 雪山专用纹理：比 _snow_tex 更亮更冷，模拟远处高海拔雪原在阳光下泛白
# 同时带一点冷蓝调阴影，跟近处纯白雪地拉开层次
func _snow_mountain_tex() -> Texture2D:
	if not _tex_cache.has("snow_mountain"):
		_tex_cache["snow_mountain"] = _make_noise_texture(89, Color(0.78, 0.82, 0.92), 0.18)
	return _tex_cache["snow_mountain"]


# 围墙专用纹理：大块石砌（横向 3 层、层间错缝），比 _brick_tex 的砖块大得多，
# 对应"大石块垒起来的矮墙"那种质感
# 中央石块纹理：浅米黄大理石（斜向纹理 + 云状斑驳）——
# 参考图里石块是暖米黄带斜纹的，不是冷灰色
func _block_tex() -> Texture2D:
	if _tex_cache.has("block"):
		return _tex_cache["block"]
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 173
	var base := Color(0.90, 0.86, 0.72)   # 浅米黄（参考图石块是明显的暖米黄）
	for y in size:
		for x in size:
			var u := float(x) / float(size)
			var v := float(y) / float(size)
			# 斜向大理石纹（两组不同角度的正弦叠加）
			var n := sin((u + v * 1.7) * TAU * 2.0) * 0.40
			n += sin((u - v * 0.8) * TAU * 5.0) * 0.22
			# 大尺度云状斑驳
			n += sin(u * TAU * 1.3 + 0.5) * sin(v * TAU * 1.1) * 0.6
			n += rng.randf_range(-0.5, 0.5) * 0.28
			var k := 1.0 + n * 0.15
			img.set_pixel(x, y, Color(base.r * k, base.g * k, base.b * k))
	_tex_cache["block"] = ImageTexture.create_from_image(img)
	return _tex_cache["block"]


# 小围墙纹理：深棕色砖块（横向砖缝 + 层间错缝）——
# 参考图里那 6 道小墙是深棕砖砌的，不是木箱
func _crate_tex() -> Texture2D:
	if _tex_cache.has("crate"):
		return _tex_cache["crate"]
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var brick := Color(0.34, 0.20, 0.12)   # 深棕砖
	var mortar := Color(0.21, 0.13, 0.08)  # 更深的砖缝
	var rows := 6
	var cols := 3
	var rh := float(size) / float(rows)
	var cw := float(size) / float(cols)
	var rng := RandomNumberGenerator.new()
	rng.seed = 211
	for y in size:
		var r := int(float(y) / rh)
		var k := 1.0 + rng.randf_range(-0.08, 0.08)
		var offset := 0.0 if r % 2 == 0 else cw * 0.5
		for x in size:
			var fx := fmod(float(x) + offset, cw)
			var fy := fmod(float(y), rh)
			var c := mortar if (fx < 2.0 or fy < 2.0) else Color(brick.r * k, brick.g * k, brick.b * k)
			img.set_pixel(x, y, c)
	_tex_cache["crate"] = ImageTexture.create_from_image(img)
	return _tex_cache["crate"]


func _wall_tex() -> Texture2D:
	if _tex_cache.has("wall"):
		return _tex_cache["wall"]
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var stone := Color(0.86, 0.85, 0.80)      # 石色：浅灰偏暖（参考图里墙是接近米白的）
	var seam := Color(0.68, 0.67, 0.62)       # 砌缝：深一档
	var rows := 3
	var rh := float(size) / float(rows)
	var rng := RandomNumberGenerator.new()
	rng.seed = 97
	# 每层随机分配 2~3 块石头
	var cols_per_row: Array[int] = []
	for r in rows:
		cols_per_row.append(rng.randi_range(2, 3))
	for y in size:
		var r := int(float(y) / rh)
		var cols: int = cols_per_row[r]
		var cw := float(size) / float(cols)
		var offset := 0.0 if r % 2 == 0 else cw * 0.5
		var shade := 1.0 + rng.randf_range(-0.06, 0.06)
		for x in size:
			var fx := fmod(float(x) + offset, cw)
			var fy := fmod(float(y), rh)
			# 缝宽 3px（横向缝 + 竖向缝）
			var is_seam := fy < 3.0 or fx < 3.0
			# 石面加点细颗粒，避免死板
			var grain := 1.0 + rng.randf_range(-0.03, 0.03)
			var c := seam if is_seam else Color(stone.r * shade * grain,
					stone.g * shade * grain, stone.b * shade * grain)
			img.set_pixel(x, y, c)
	_tex_cache["wall"] = ImageTexture.create_from_image(img)
	return _tex_cache["wall"]


# 地面纹理：大尺度云状斑驳（像冰面/大理石的色块），
# 比 _snow_tex 的均匀颗粒更有"整片地面"的实体感 —— 参考图的地面就是这个调子
func _ice_floor_tex() -> Texture2D:
	if _tex_cache.has("ice_floor"):
		return _tex_cache["ice_floor"]
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 131
	# 预生成若干随机斑块，用径向衰减叠加出云状斑驳
	var blobs: Array[Dictionary] = []
	for i in 10:
		blobs.append({
			"x": rng.randf(), "y": rng.randf(),
			"r": 0.18 + rng.randf() * 0.32,
			"s": rng.randf_range(-0.6, 0.6),
		})
	var base := Color(0.93, 0.92, 0.88)   # 暖米白（参考图地面偏暖，不是冷灰）
	for y in size:
		for x in size:
			var u := float(x) / float(size)
			var v := float(y) / float(size)
			var n := 0.0
			for b in blobs:
				var dx := u - float(b.x)
				var dy := v - float(b.y)
				var d := sqrt(dx * dx + dy * dy)
				n += float(b.s) * maxf(0.0, 1.0 - d / float(b.r))
			n += rng.randf_range(-0.5, 0.5) * 0.16   # 颗粒（参考图雪地颗粒感很强）
			var k := 1.0 + n * 0.16
			img.set_pixel(x, y, Color(base.r * k, base.g * k, base.b * k))
	_tex_cache["ice_floor"] = ImageTexture.create_from_image(img)
	return _tex_cache["ice_floor"]


func _stone_tex() -> Texture2D:
	# 石材表面：米黄偏灰的石色 + 云状斑驳（中央大石块就是这种调子，
	# 比雪地暗一档才看得出"石块"的形体，不然全白糊成一片）
	if not _tex_cache.has("stone"):
		_tex_cache["stone"] = _make_noise_texture(67, Color(0.80, 0.78, 0.70), 0.20)
	return _tex_cache["stone"]


# 砖墙：真正的砖块排布（错缝 + 勾缝），不是噪声
func _brick_tex() -> Texture2D:
	# 真正的砖块排布（错缝 + 勾缝），砖本身是较深的红，勾缝是浅灰
	if _tex_cache.has("brick"):
		return _tex_cache["brick"]
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var base := Color(0.78, 0.32, 0.22)        # 砖红：足够饱和，远处也能看清
	var mortar := Color(0.62, 0.55, 0.45)     # 勾缝：中性灰，跟周围环境协调
	var rows := 8
	var cols := 4
	var rh := float(size) / float(rows)
	var cw := float(size) / float(cols)
	var rng := RandomNumberGenerator.new()
	rng.seed = 71
	for y in size:
		var r := int(float(y) / rh)
		# 每行随机一点深浅，砖块才不呆板
		var k := 1.0 + rng.randf_range(-0.10, 0.10)
		var offset := 0.0 if r % 2 == 0 else cw * 0.5
		for x in size:
			var fx := fmod(float(x) + offset, cw)
			var fy := fmod(float(y), rh)
			var c := mortar if (fx < 2.0 or fy < 2.0) else Color(base.r * k, base.g * k, base.b * k)
			img.set_pixel(x, y, c)
	_tex_cache["brick"] = ImageTexture.create_from_image(img)
	return _tex_cache["brick"]


# ---------------------------------------------------------------- 出生点
func _build_spawns() -> void:
	# 出生点分**上下两排**，每排**横着**沿 X 轴排开（各 8 个）：
	#   · 南排（A 包点那一侧 z=+17）：CT
	#   · 北排（B 包点那一侧 z=-17）：T
	t_spawns.clear()
	ct_spawns.clear()
	var xs: Array[float] = [-10.5, -7.5, -4.5, -1.5, 1.5, 4.5, 7.5, 10.5]
	for sx in xs:
		ct_spawns.append(Vector3(sx, 0, 17.0))
		t_spawns.append(Vector3(sx, 0, -17.0))


# ============================================================ 玩家
func _build_players(scene: Node) -> void:
	# 仅人类玩家（CT） + 1 个对手 T bot，之后用 +/- 动态增减
	player = _make_player(scene, "CT", false, "YOU")
	players.append(player)
	var t0 := _make_player(scene, "T", true, _random_bot_name())
	bots.append(t0)
	players.append(t0)



func _random_bot_name() -> String:
	return UIText.BOT_NICKS[randi() % UIText.BOT_NICKS.size()] + str(randi_range(10, 99))


# 队伍内轮询分配出生点，避免同队玩家重叠
var _spawn_counter: Dictionary = {}

func _pick_spawn(team: String) -> Vector3:
	if not _spawn_spawns_ready():
		return Vector3(0, 0.1, 0)
	var arr := (ct_spawns if team == "CT" else t_spawns)
	var i: int = _spawn_counter.get(team, 0)
	_spawn_counter[team] = i + 1
	return arr[i % arr.size()] + Vector3(0, 0.1, 0)


func _spawn_spawns_ready() -> bool:
	# 出生成未就绪时兜底，wait 不抛错也可直接使用空数组
	return not ct_spawns.is_empty() and not t_spawns.is_empty()


func _make_player(scene: Node, team: String, is_bot: bool, nick: String) -> CSPlayer:
	var p: CSPlayer
	if is_bot:
		p = load("res://scripts/bot.gd").new()
	else:
		p = CSPlayer.new()
	p.team = team
	p.is_bot = is_bot
	p.nick = nick
	p.died.connect(_on_player_died)
	scene.add_child(p)
	# 创建后立即放到出生点，避免在 (0,0,0) 中央掩体内被物理弹飞
	p.global_position = _pick_spawn(team)
	return p


func _count_team(team: String) -> int:
	var n := 0
	for p in players:
		if p.team == team:
			n += 1
	return n


# ---------------------------------------------------------------- 运行时增减电脑（联机同步）
# +/- 加电脑：**只有房主能改**（电脑归房主模拟），改完广播给客户端，
# 两边建出同名、同 authority 的节点 —— 否则房主自己加的电脑在别人屏幕上根本不存在。
# 名字用独立的 `BotR_` 前缀 + 房主自增序号，跟开局名单里的 `Bot_<序号>` 不会撞。
var _runtime_bot_seq := 0


func _spawn_bot_synced(team: String) -> bool:
	if _count_team(team) >= MAX_TEAM_PLAYERS:
		return false
	_runtime_bot_seq += 1
	var nm := "BotR_%d" % _runtime_bot_seq
	var nick := _random_bot_name()
	var pos := _pick_spawn(team)
	_make_runtime_bot(nm, team, nick, pos)
	# 大厅里按 +/- 只是本地看看，不用广播（进对局时整份名单会重建）
	if lan != null and lan.hosting and state != STATE.MENU:
		_net_bot_spawn.rpc(nm, team, nick, pos)
	return true


@rpc("authority", "call_remote", "reliable")
func _net_bot_spawn(nm: String, team: String, nick: String, pos: Vector3) -> void:
	_make_runtime_bot(nm, team, nick, pos)


func _make_runtime_bot(nm: String, team: String, nick: String, pos: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.get_node_or_null(NodePath(nm)) != null:
		return
	var b: CSPlayer = load("res://scripts/bot.gd").new()
	b.name = nm
	b.team = team
	b.is_bot = true
	b.nick = nick
	b.died.connect(_on_player_died)
	scene.add_child(b)
	b.global_position = pos
	b.setup_net(1)                 # 电脑永远归房主（authority = 1）
	bots.append(b)
	players.append(b)
	# 只有房主需要给新电脑买装备 / 补弹（客户端那份不跑 AI）
	if multiplayer.is_server() and (state == STATE.BUY or state == STATE.LIVE):
		_bot_buy(b)


func _despawn_bot_synced(victim: CSPlayer) -> void:
	if victim == null:
		return
	var nm := victim.name
	_kick_bot(victim)
	if lan != null and lan.hosting and state != STATE.MENU:
		_net_bot_despawn.rpc(nm)


@rpc("authority", "call_remote", "reliable")
func _net_bot_despawn(nm: String) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var n := scene.get_node_or_null(NodePath(nm))
	if n is CSPlayer:
		_kick_bot(n)


func _add_bot_pair(scene: Node) -> void:
	# 各队加 1 个 bot，每队上限 MAX_TEAM_PLAYERS（含人类玩家），已满则提示
	var ct_full := _count_team("CT") >= MAX_TEAM_PLAYERS
	var t_full := _count_team("T") >= MAX_TEAM_PLAYERS
	if ct_full and t_full:
		_show_toast(UIText.TOAST_ALL_FULL % MAX_TEAM_PLAYERS)
		return
	if ct_full:
		_show_toast(UIText.TOAST_TEAM_FULL % [team_name("CT"), MAX_TEAM_PLAYERS])
	if t_full:
		_show_toast(UIText.TOAST_TEAM_FULL % [team_name("T"), MAX_TEAM_PLAYERS])
	var added := false
	if not ct_full and _spawn_bot_synced("CT"):
		added = true
	if not t_full and _spawn_bot_synced("T"):
		added = true
	if added and state == STATE.LIVE and not bomb_planted:
		_assign_c4()


## 给指定队伍补 1 个电脑（配平用，不带上限提示）
func _add_one_bot(team: String) -> void:
	if _count_team(team) >= MAX_TEAM_PLAYERS:
		return
	var b := _make_player(get_tree().current_scene, team, true, _random_bot_name())
	bots.append(b)
	players.append(b)


## 开打前配平：**名册里给某队显示几个电脑，场上就补几个电脑**（同一个公式 `_team_bot_count`）。
## 例：磐垒 3 真人、锐刃 1 真人 → 名册上锐刃多 2 个电脑 → 场上锐刃也补 2 个电脑。
## 两队真人一样多时一个电脑都不补。
## 注：远端真人目前不会作为角色进对局（联机同步还没做），他们的位置不额外补人 ——
##     这里只保证"电脑数量和名册一致"。
func _balance_teams_with_bots() -> void:
	var members := _room_members()
	for team in ["CT", "T"]:
		var want := _team_bot_count(team, members)
		var local_in := 1 if (player != null and player.team == team) else 0
		if local_in + want < 1:
			want = 1        # 保底：别把一整队清空（否则连对手都没有）
		var have := 0
		for b in bots:
			if b.team == team:
				have += 1
		while have < want:
			_add_one_bot(team)
			have += 1
		while have > want:
			_remove_one_bot(team)
			have -= 1


func _show_toast(text: String) -> void:
	if hud_toast == null:
		return
	hud_toast.text = text
	hud_toast.visible = true
	hud_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.6)
	_toast_tween.tween_property(hud_toast, "modulate:a", 0.0, 0.8)


func _remove_bot_pair() -> void:
	# 各队移除 1 个 bot（保留每队至少 1 个 bot 作为对手）
	_remove_one_bot("CT")
	_remove_one_bot("T")


func _remove_one_bot(team: String) -> void:
	var to_remove: CSPlayer = null
	for b in bots:
		if b.team == team:
			to_remove = b
	if to_remove == null:
		return
	# 该队只剩 1 个 bot 时不再移除（保留对手）
	if _count_team(team) <= 1:
		return
	_despawn_bot_synced(to_remove)


## 真正把某个 bot 从场上摘掉（不带上限判断，供"腾位置"用）
func _kick_bot(victim: CSPlayer) -> void:
	if victim == null:
		return
	bots.erase(victim)
	if victim in players:
		players.erase(victim)
	victim.queue_free()


# ---------------------------------------------------------------- 局域网：玩家加入
## 有玩家连进来（服务器侧）。CS 的做法：位置不够就踢掉一个 bot 腾地方。
## 现在只做"踢 bot"这一步；位置/伤害/拾取/回合的同步是后续服务器权威改造的内容。
func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	print("[LAN] 玩家 %d 已连接" % id)
	# 新玩家先补一个默认阵营，再广播给所有人（否则各人屏幕上名册不一致）
	_ensure_peer_teams()
	_net_team_sync.rpc(_peer_teams)
	if _make_room_for_player():
		_show_toast(UIText.TOAST_NEW_PLAYER)


## 给新玩家腾位置：**两队都满**才需要踢人（任意一队有空位，新玩家直接进那一队就行）。
## 返回是否真的踢了。
func _make_room_for_player() -> bool:
	var ct := _count_team("CT")
	var t := _count_team("T")
	if ct < MAX_TEAM_PLAYERS or t < MAX_TEAM_PLAYERS:
		return false          # 还有空位
	# 从人多的一队踢，保持两队人数均衡
	var team := "T" if t > ct else "CT"
	var victim: CSPlayer = null
	for b in bots:
		if b.team == team:
			victim = b
	if victim == null:
		return false
	_despawn_bot_synced(victim)     # 联机时客户端也要跟着少一个
	return true


# ============================================================ 回合
func _begin_round() -> void:
	state = STATE.BUY
	timer = BUY_TIME
	# 清除上一回合的胜利文字
	if center_msg != null:
		center_msg.text = ""
		center_msg.add_theme_font_size_override("font_size", 40)
	bomb_planted = false
	bomb_timer = 0.0
	plant_progress = 0.0
	defuse_progress = 0.0
	has_bomb_bot_planted = false
	# 重置玩家
	_spawn_counter = {}
	for p in players:
		p.revive()
		p.velocity = Vector3.ZERO
		p.global_position = _pick_spawn(p.team)
		# 设置朝向：两队面对面（CT 在南朝北 -Z、T 在北朝南 +Z）
		p.rotation.y = 0.0 if p.team == "CT" else PI
	_assign_c4()
	# 每回合刷新地面武器：清掉上回合捡剩的 / 玩家丢的，重新铺 16 把出生点配枪
	_respawn_spawn_weapons()
	for b in bots:
		_bot_buy(b)
	# 开局不自动弹购买界面，等玩家按 B
	buy_menu_visible = false
	buy_menu.visible = false
	_capture_mouse()


func _assign_c4() -> void:
	bomb_holder = null
	for p in players:
		p.has_c4 = false
	var t_alive: Array[CSPlayer] = []
	for p in players:
		if p.team == "T" and p.alive:
			t_alive.append(p)
	if not t_alive.is_empty():
		bomb_holder = t_alive[randi() % t_alive.size()]
		bomb_holder.has_c4 = true


# bot 每回合的"采购"。
# ★ 本模式**不发枪** ★
# 地上那 16 把出生点配枪就是唯一来源（本图玩法核心：出生就满地捡枪）。
# 之前每回合给 bot 发 AK47/M4A1，等于把地上 8 把枪变成摆设 —— 玩家看着 bot 走过去
# 视而不见。现在 bot 只买护甲，枪必须自己走去捡（bot.gd 的 _nearest_ground_weapon/_move_to）。
func _bot_buy(p: CSPlayer) -> void:
	p.buy_armor(p.money > 4600)
	# 手上那把（上回合捡的 / 活下来带的）补满弹药，
	# 否则打空备弹后就只能拿着手枪发呆
	_bot_refill(p)


# bot 已有主武器（无法重复购买）时，直接补满弹药
func _bot_refill(p: CSPlayer) -> void:
	for s in [1, 4]:
		var w: Dictionary = p.weapons.get(s, {})
		if w.is_empty(): continue
		var wid: String = w.get("id", "")
		var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
		if spec.is_empty(): continue
		w["mag"] = spec.get("mag", 0)
		w["reserve"] = spec.get("reserve", 0)
		return


var _prtsc_prev := false

func _physics_process(delta: float) -> void:
	if buy_menu == null: return
	# 局域网房间发现 / 信标广播
	if lan != null:
		lan.poll(delta)
	# 大厅开着的时候定期刷新房间列表（每秒自动刷新，不用手点）
	if lan_menu != null and lan_menu.visible:
		_lan_refresh_cool -= delta
		if _lan_refresh_cool <= 0.0:
			_lan_refresh_cool = 0.4
			_refresh_lan_rooms()
	# 房间界面开着的时候定期刷新名册/状态（有人连进来 / 掉线要能反映出来）
	if map_select_menu != null and map_select_menu.visible:
		_lan_refresh_cool -= delta
		if _lan_refresh_cool <= 0.0:
			_lan_refresh_cool = 0.4
			_refresh_room_screen()
	# P 键截图（轮询检测）
	var prtsc_now := Input.is_key_pressed(KEY_P)
	if prtsc_now and not _prtsc_prev:
		_take_screenshot()
	_prtsc_prev = prtsc_now
	# ★ 联机时回合只由房主推进 ★
	#   客户端的 state / timer / 比分 / 炸弹状态由 _net_sync 同步器写进来；
	#   自己再算一遍会和房主打架（倒计时两边不一样、回合数越跑越偏）。
	if not net_is_client():
		_step_match(delta)
		# 地面武器有变动就广播一次（合并到一帧里发，避免每回合铺枪时连发 16 条）
		if _ground_dirty:
			_ground_dirty = false
			_broadcast_ground()
	_update_hud()
	if scoreboard_visible:
		_update_scoreboard()


## 推进对局（只有房主 / 单机走这里）
func _step_match(delta: float) -> void:
	match state:
		STATE.MENU:
			pass   # 菜单态没有逐帧逻辑（原来的"开始按钮呼吸灯"随开始菜单一起删了）
		STATE.BUY:
			timer -= delta
			# 购买阶段也要判胜负：玩家此刻就能开枪，把敌人清光应立即结算。
			# 之前只在 LIVE 阶段判定，购买阶段杀完人得干等满 10 秒购买时间才出胜利提示。
			_check_elimination()
			if state == STATE.BUY and timer <= 0.0:
				buy_menu.visible = false
				buy_menu_visible = false
				state = STATE.LIVE
				timer = ROUND_TIME
				_capture_mouse()
		STATE.LIVE:
			timer -= delta
			_check_live(delta)
			if state == STATE.LIVE and timer <= 0.0:
				_end_round("CT")
		STATE.OVER:
			pass


func _unhandled_input(event: InputEvent) -> void:
	# ESC：房间界面返回上一步（回房间列表）；游戏中切换暂停（暂停时再按 ESC 继续）
	var ek_esc := event as InputEventKey
	if ek_esc != null and ek_esc.pressed and ek_esc.keycode == KEY_ESCAPE:
		if map_select_menu != null and map_select_menu.visible:
			_close_room_screen()
			return
		if state == STATE.LIVE or state == STATE.BUY:
			if _paused:
				_resume_game()
			else:
				_pause_game()
		return
	# 处理 Tab 键按下/松开（计分板显示/隐藏）
	var ek_tab := event as InputEventKey
	if ek_tab != null and ek_tab.keycode == KEY_TAB:
		if ek_tab.pressed:
			_show_scoreboard()
		else:
			_hide_scoreboard()
		return
	
	var ek := event as InputEventKey
	if ek == null or not ek.pressed: return
	var key := ek.keycode
	# Bot 数量 + / -
	# ★ 联机时只有房主能改 ★：电脑是房主统一模拟的，客户端自己加一个只会让两台机器
	#   的角色表对不上（那个人在别人屏幕上根本不存在）。房主改完会广播给所有人。
	if key == KEY_PLUS or key == KEY_EQUAL or key == KEY_MINUS:
		if net_is_client():
			_show_toast(UIText.TOAST_BOT_HOST_ONLY)
			return
		if key == KEY_MINUS:
			_remove_bot_pair()
		else:
			_add_bot_pair(get_tree().current_scene)
		return
	# 菜单阶段不接受键盘开局：只认「开始游戏」按钮的点击。
	# 之前回车/空格会直接进游戏，玩家在菜单随手按空格（想跳一下）就误开局了。
	if state == STATE.MENU:
		return
	# 游戏中：B 键购物已**屏蔽**（本模式不爆破、且能捡枪，不需要买枪）
	if key == KEY_B and (state == STATE.BUY or state == STATE.LIVE):
		_show_toast(UIText.TOAST_NO_BUY)
		return
	# 数字键快速购买（仅 BUY 阶段且菜单打开时）
	if state == STATE.BUY and buy_menu_visible:
		var hotkey_map := {
			KEY_1: "AK47", KEY_2: "M4A1", KEY_3: "Deagle",
			KEY_4: "MP5", KEY_5: "AWP", KEY_6: "ARMOR",
			KEY_7: "KIT", KEY_8: "AMMO"
		}
		if key in hotkey_map:
			_on_buy_press(hotkey_map[key])
	# G：丢掉当前手里的枪（刀不能丢），枪落在脚边可以再捡回来
	if key == KEY_G and (state == STATE.BUY or state == STATE.LIVE):
		_drop_current_weapon()


func _show_scoreboard() -> void:
	if scoreboard == null: return
	_update_scoreboard()
	scoreboard.visible = true
	scoreboard_visible = true


func _hide_scoreboard() -> void:
	if scoreboard == null: return
	scoreboard.visible = false
	scoreboard_visible = false


# PrtSc 截图：捕获整个窗口画面，保存为 PNG 到专门文件夹
func _take_screenshot() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	# 等一帧让渲染完成，再抓取画面（立即抓取可能拿到上一帧/空白图）
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	if img == null:
		_show_toast(UIText.TOAST_SHOT_FAIL)
		return
	# 截图目录：优先项目目录 screenshots/（开发时方便直接查看），
	# 发布后 res:// 只读则回退到 user://screenshots/（%APPDATA% 等用户目录）
	var dirs: Array[String] = ["res://screenshots", "user://screenshots"]
	var save_path := ""
	for d in dirs:
		if DirAccess.open(d) == null:
			DirAccess.make_dir_recursive_absolute(d)
		var fname := "shot_%s_%s.png" % [Time.get_datetime_string_from_system().replace(":", ""), Time.get_ticks_msec() % 100000]
		var cand := d + "/" + fname
		if img.save_png(cand) == OK:
			save_path = cand
			break
	if save_path.is_empty():
		_show_toast(UIText.TOAST_SHOT_SAVE_FAIL)
		return
	_show_toast(UIText.TOAST_SHOT_SAVED % save_path.get_file())


func _set_difficulty(i: int) -> void:
	bot_difficulty = clampi(i, 0, UIText.DIFFICULTY_NAMES.size() - 1)
	# 持久化，重启后保留选择
	if ConfigManager.instance != null:
		ConfigManager.instance.set_bot_difficulty(bot_difficulty)
	_set_difficulty_ui()


func _set_difficulty_ui() -> void:
	for j in diff_buttons.size():
		var b: Button = diff_buttons[j]
		var on := j == bot_difficulty
		# 选中段：金底深字；未选中段：透明底灰字（hover 才浮出一层浅底）
		b.add_theme_stylebox_override("normal", _seg_style(on))
		b.add_theme_stylebox_override("hover", _seg_style(on, true))
		b.add_theme_stylebox_override("pressed", _seg_style(on, true))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.add_theme_color_override("font_color",
				UITheme.ON_ACCENT if on else UITheme.TEXT_DIM)
		b.add_theme_color_override("font_hover_color",
				UITheme.ON_ACCENT if on else UITheme.TEXT)
		b.add_theme_color_override("font_pressed_color",
				UITheme.ON_ACCENT if on else UITheme.TEXT)
		# 供自检识别当前选中项（比看颜色稳）
		b.set_meta("seg_on", on)


func _open_map_select() -> void:
	if lan_menu != null:
		lan_menu.visible = false
	map_select_menu.visible = true
	_room_sig = ""           # 强制重建一次名册
	_refresh_room_screen()
	_refresh_map_select()


# 选定地图后正式开始对局
# ============================================================ 局域网对局同步
#
# ★ 房主就是服务器 ★（没有独立服务端进程，房主那台机器兼任）：
#   · 电脑（bot）       —— 只有房主跑 AI，客户端只显示同步过来的位置
#   · 每个真人          —— 移动由**本人那台机器**算（客户端权威，手感不吃延迟）
#   · 伤害/死亡/回合/炸弹 —— 全部由房主结算，客户端上报"谁打了谁"、接收结果
#
# 节点怎么对上：房主开局时算一份**名单**（roster）广播下去，两边按同一份名单
# 建同样的角色节点（同名字、同顺序、同 authority）。所以不需要 MultiplayerSpawner，
# 每台机器上的节点路径天然一致，MultiplayerSynchronizer 才认得出来。

## 本机是客户端吗（连到别人房间的那台）
func net_is_client() -> bool:
	return lan != null and lan.is_connected_to_host()


## 对局状态同步器（挂在 GM 自己身上 —— autoload 路径 /root/GM 两边一致，不用管节点名）
## 只同步"两台机器必须一致"的那几样。玩家/电脑的位置各自有各自的同步器（player.gd setup_net）。
var _net_sync: MultiplayerSynchronizer


func _setup_net_sync() -> void:
	_net_sync = MultiplayerSynchronizer.new()
	_net_sync.name = "NetSync"
	var cfg := SceneReplicationConfig.new()
	for prop in ["state", "timer", "round_num", "ct_wins", "t_wins",
			"bomb_planted", "bomb_pos", "bomb_timer",
			"plant_progress", "defuse_progress"]:
		cfg.add_property(NodePath(".:" + prop))
	_net_sync.replication_config = cfg
	add_child(_net_sync)


## 开火特效广播：让别的机器也看到枪口火光 / 曳光 / 血雾。
## 不同步的话别人只看到你在原地"抖一下"，完全看不出你在开枪。
## 用 unreliable —— 特效丢一两条无所谓，不值得为它阻塞。
func broadcast_shot(shooter: CSPlayer, from: Vector3, to: Vector3,
		hit: bool, hit_pos: Vector3, hit_dir: Vector3,
		wid: String, with_sound: bool) -> void:
	if lan == null or not (lan.hosting or lan.is_connected_to_host()):
		return
	if shooter == null:
		return
	_net_shot.rpc(shooter.get_path(), from, to, hit, hit_pos, hit_dir, wid, with_sound)


## ★ 用 reliable 而不是 unreliable ★
## 这一条不只带特效，还带**枪声** —— 丢一条就是"这一枪没听见"，听声辨位直接失效。
## 局域网带宽不值钱（一发也就百来字节），宁可慢一点点也不要丢。
@rpc("any_peer", "call_remote", "reliable")
func _net_shot(shooter_path: NodePath, from: Vector3, to: Vector3,
		hit: bool, hit_pos: Vector3, hit_dir: Vector3,
		wid: String, with_sound: bool) -> void:
	var sh := get_node_or_null(shooter_path) as CSPlayer
	if sh == null:
		return
	sh.remote_shot_fx(from, to, hit, hit_pos, hit_dir, wid, with_sound)


## 击杀信息流：伤害是房主结算的，所以这一条也由房主广播给客户端
@rpc("authority", "call_remote", "reliable")
func _net_kill_feed(kname: String, kteam: String, weapon_id: String,
		vname: String, vteam: String) -> void:
	_feed_add_row(kname, kteam, weapon_id, vname, vteam)


## 开局名单（只有房主算，然后广播给所有人）
## 条目：{"peer": 对端 id, "team": "CT"/"T", "nick": 昵称, "bot": bool}
## ★ 电脑的名字也在房主这边生成后一起发下去 ★ —— 两边各自 randi 的话名字会对不上。
func _match_roster() -> Array:
	var members := _room_members()
	var out: Array = []
	for team in ["CT", "T"]:
		for m in members:
			if str(m.get("team", "CT")) != team:
				continue
			var pid := int(m.get("peer", 0))
			if pid <= 0:
				pid = multiplayer.get_unique_id()   # 自己（房主）
			out.append({"peer": pid, "team": team,
					"nick": str(m.get("name", "")), "bot": false})
		var bots_n := _team_bot_count(team, members)
		for i in bots_n:
			out.append({"peer": 1, "team": team, "nick": _random_bot_name(), "bot": true})
	return out


## 按名单建角色。房主和客户端跑的是同一段代码 + 同一份名单，
## 所以两台机器上的节点名/路径完全一致（这是同步能对上的前提）。
func _build_match_players(roster: Array) -> void:
	var scene := get_tree().current_scene
	# 先清掉上一局的角色：**先 remove_child 再 queue_free** —— 立刻脱离树，
	# 不然新角色和还没释放的旧角色会在同一帧里抢名字（节点路径一变同步就废了）。
	for p in players:
		if is_instance_valid(p):
			var par := p.get_parent()
			if par != null:
				par.remove_child(p)
			p.queue_free()
	players.clear()
	bots.clear()
	player = null
	_spawn_counter.clear()
	var idx := 0
	for e in roster:
		var is_bot := bool(e.get("bot", false))
		var team := str(e.get("team", "CT"))
		var pid := int(e.get("peer", 1))
		var p: CSPlayer
		if is_bot:
			p = load("res://scripts/bot.gd").new()
			p.name = "Bot_%d" % idx
		else:
			p = CSPlayer.new()
			p.name = "Player_%d" % pid
		p.team = team
		p.is_bot = is_bot
		p.nick = str(e.get("nick", ""))       # 必须在 add_child 之前（_build_team_marker 要用）
		p.died.connect(_on_player_died)
		scene.add_child(p)
		p.global_position = _pick_spawn(team)
		# ★ authority ★：电脑归房主(1)，真人归他自己那台机器
		p.setup_net(1 if is_bot else pid)
		players.append(p)
		if is_bot:
			bots.append(p)
		elif pid == multiplayer.get_unique_id():
			player = p
		idx += 1


## 客户端把"我打中了谁"上报给房主（自己扣血会被同步覆盖回去，等于打不死人）
func report_damage(victim: CSPlayer, weapon_id: String, head: bool, attacker: CSPlayer) -> void:
	if victim == null or attacker == null or weapon_id == "":
		return
	if not net_is_client():
		return
	_net_damage.rpc_id(1, victim.get_path(), weapon_id, head, attacker.get_path())


## 房主侧结算伤害。**只信客户端报的"谁打谁 + 什么枪 + 是不是爆头"**，
## 伤害数值一律用服务器这边的武器数据重算（客户端传数值的话改一个数字就能秒人）。
@rpc("any_peer", "call_remote", "reliable")
func _net_damage(victim_path: NodePath, weapon_id: String, head: bool, attacker_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var victim := get_node_or_null(victim_path) as CSPlayer
	var attacker := get_node_or_null(attacker_path) as CSPlayer
	if victim == null or attacker == null or victim.team == attacker.team:
		return
	var spec: Dictionary = WeaponDatabase.weapons().get(weapon_id, {})
	if spec.is_empty():
		return
	spec = attacker._effective_spec(weapon_id, spec)
	victim.apply_damage(spec, attacker, head)


func _start_game_with_map(map_id: String) -> void:
	# 客户端不能自己开局（会跟房主各跑各的），只能等房主广播 _net_start_match
	if net_is_client():
		return
	var roster := _match_roster()
	if lan != null and lan.hosting:
		# 房主：地图 + 名单 + 难度 一起广播，两边同时进对局
		_net_start_match.rpc(map_id, roster, bot_difficulty)
	_apply_match_start(map_id, roster, bot_difficulty)


## 房主广播开局，客户端收到后走**同一个** _apply_match_start
@rpc("authority", "call_remote", "reliable")
func _net_start_match(map_id: String, roster: Array, diff: int) -> void:
	_apply_match_start(map_id, roster, diff)


## 真正开局。房主和客户端都走这里（只是名单来源不同：房主自己算，客户端收广播）
func _apply_match_start(map_id: String, roster: Array, diff: int) -> void:
	bot_difficulty = diff
	_rebuild_map(map_id)
	if map_select_menu != null:
		map_select_menu.visible = false
	if lan_menu != null:
		lan_menu.visible = false
	_build_match_players(roster)
	_set_world_active(true)            # 角色重新出现在场上
	state = STATE.BUY
	if crosshair_layer != null:
		crosshair_layer.visible = true
	_begin_round()
	# 开局提示当前人机难度（顺便告诉玩家这个选项确实生效了）
	_show_toast(UIText.TOAST_DIFFICULTY % UIText.DIFFICULTY_NAMES[bot_difficulty])


func _capture_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## ★ 一台机器开两份时，两个窗口会互相抢鼠标 ★
## 对局里鼠标是 `MOUSE_MODE_CAPTURED`（光标被藏起来 + 锁在窗口内），
## 这时候你去点另一个窗口，**光标根本够不着** —— 表现就是"两个窗口都动不了、像卡死"。
## 所以窗口一失焦就主动放开鼠标；切回来时如果还在对局再重新捕获。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if _paused:
			return
		if pause_menu != null and pause_menu.visible:
			return
		if state == STATE.LIVE or state == STATE.BUY:
			_capture_mouse()


# 只判"一方被打光"。任何阶段（含购买阶段）都能立刻结算，返回 true 表示本回合已结束。
func _check_elimination() -> bool:
	var ct_alive := 0
	var t_alive := 0
	for p in players:
		if p.alive:
			if p.team == "CT": ct_alive += 1
			else: t_alive += 1
	if ct_alive == 0:
		_end_round("T")
		return true
	if t_alive == 0 and not bomb_planted:
		_end_round("CT")
		return true
	return false


func _check_live(delta: float) -> void:
	if _check_elimination():
		return

	_fire_plant(player, delta)
	_fire_defuse(player, delta)

	if bomb_planted:
		bomb_timer -= delta
		if bomb_timer <= 0.0:
			_do_bomb_explode()
			_end_round("T")


# ---------------------------------------------------------------- 噪声事件（听声辨位）
# 开枪 / 脚步 / 拉栓 / 换弹 都会产生一次"噪声事件"，半径内的 bot 会"听到"并做出反应
# （见 bot.gd 的 on_hear_noise）：
#   · 当前没目标 → 把这个位置当临时搜索点，走过去查看
#   · 正躲在掩体后 → 附近有动静就缩短躲藏时间、提前探身戒备
# 这样玩家开枪/跑动会引来 bot，bot 之间也会靠枪声互相判断方位。
#
# 半径按"响度"给：枪声传得远、脚步很近、机械声更近。
const NOISE_RADIUS_SHOT := 55.0
const NOISE_RADIUS_STEP := 16.0
const NOISE_RADIUS_MECH := 11.0

func emit_noise(pos: Vector3, radius: float, source: Node) -> void:
	if radius <= 0.0:
		return
	var src_team := ""
	if source is CSPlayer:
		src_team = (source as CSPlayer).team
	for b in bots:
		var bot := b as CSPlayer
		if bot == null or bot == source or not bot.alive:
			continue
		# 同队的动静不"听"：队友在哪本来就知道，否则一群 bot 会互相追着队友的
		# 脚步来回跑，看起来像发神经。听声辨位只对**敌方**生效。
		if src_team != "" and bot.team == src_team:
			continue
		# 用水平距离判定：隔着一层楼板听到脚步没有意义（本图是单层，够用）
		var d := Vector2(bot.global_position.x - pos.x, bot.global_position.z - pos.z).length()
		if d <= radius:
			bot.call("on_hear_noise", pos, source, radius)



# C4 爆炸表现：响一声（3D 定位）+ 一团膨胀的橙色火球 + 闪光。
# 之前这里直接 _end_round，既没声音也没画面，explode.wav 一直躺在素材库里没人用。
func _do_bomb_explode() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var pos := bomb_pos
	var snd := AudioStreamPlayer3D.new()
	snd.stream = SND_EXPLODE
	snd.unit_size = 22.0
	snd.max_distance = 200.0
	snd.max_db = 4.0
	snd.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	scene.add_child(snd)
	snd.global_position = pos + Vector3(0, 1.0, 0)
	snd.play()
	snd.finished.connect(snd.queue_free)

	var mi := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.5
	sph.height = 1.0
	sph.radial_segments = 16
	sph.rings = 8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.15)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.45, 0.10)
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sph.material = mat
	mi.mesh = sph
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(mi)
	mi.global_position = pos + Vector3(0, 0.8, 0)
	var tw := create_tween()
	tw.tween_property(mi, "scale", Vector3(7.0, 5.0, 7.0), 0.45) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(mi, "transparency", 1.0, 0.8) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(mi.queue_free)

	var lt := OmniLight3D.new()
	lt.light_color = Color(1.0, 0.6, 0.25)
	lt.light_energy = 9.0
	lt.omni_range = 18.0
	scene.add_child(lt)
	lt.global_position = pos + Vector3(0, 1.2, 0)
	var tw2 := create_tween()
	tw2.tween_property(lt, "light_energy", 0.0, 0.5)
	tw2.tween_callback(lt.queue_free)


func _fire_plant(p: CSPlayer, delta: float) -> void:
	if bomb_planted or p == null or not p.alive or not p.has_c4:
		return
	if not _near_site(p.global_position):
		plant_progress = 0.0
		return
	if Input.is_action_pressed("plant"):
		plant_progress += delta
		if plant_progress >= PLANT_TIME:
			_do_plant(p.global_position)
	else:
		plant_progress = 0.0


func _fire_defuse(p: CSPlayer, delta: float) -> void:
	if not bomb_planted or p == null or not p.alive or p.team != "CT": return
	if p.global_position.distance_to(bomb_pos) > 3.0:
		defuse_progress = 0.0
		return
	if Input.is_action_pressed("plant"):
		defuse_progress += delta
		var need := DEFUSE_KIT_TIME if p.has_defuser else DEFUSE_TIME
		if defuse_progress >= need:
			bomb_planted = false
			p.add_money(1000)
			_end_round("CT")
	else:
		defuse_progress = 0.0


func _near_site(pos: Vector3) -> bool:
	return pos.distance_to(bombsite_a) < 9.0 or pos.distance_to(bombsite_b) < 9.0


func _do_plant(pos: Vector3) -> void:
	bomb_planted = true
	bomb_pos = pos + Vector3(0, 0.8, 0)
	bomb_timer = BOMB_TIME
	if player and player.has_c4:
		player.has_c4 = false
		player.add_money(800)
	var phys := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.3, 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.3, 0.1)
	box.material = mat
	mi.mesh = box
	phys.add_child(mi)
	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	col.shape = bs
	phys.add_child(col)
	phys.position = bomb_pos
	map_root.add_child(phys)


func _end_round(winner: String) -> void:
	state = STATE.OVER
	timer = 0.0
	# 全程不显示鼠标（除购买/菜单界面）
	_capture_mouse()
	if winner == "CT":
		ct_wins += 1
	else:
		t_wins += 1
	_award_money(winner)
	_round_over_msg(winner)
	if ct_wins >= WIN_ROUNDS or t_wins >= WIN_ROUNDS or round_num >= MAX_ROUNDS:
		_game_over()
		return
	round_num += 1
	await get_tree().create_timer(2.6).timeout
	_begin_round()


func _award_money(winner: String) -> void:
	for p in players:
		if winner == "T" and p.team == "T":
			p.add_money(2000)
		elif winner == "CT" and p.team == "CT":
			p.add_money(2000)
		else:
			p.add_money(500)


func _round_over_msg(winner: String) -> void:
	center_msg.text = UIText.TEAM_WIN % team_name(winner)
	_style_center_msg(40)


# 中间提示统一加高对比描边。
# 默认 Label 是纯白字，这张图满屏亮白雪 + 浅蓝天，白字压上去对比度极低，
# 用户反馈"杀完人要等好一会才看到胜利提示"—— 其实早就显示了，只是看不清。
func _style_center_msg(fsize: int) -> void:
	center_msg.add_theme_font_size_override("font_size", fsize)
	center_msg.add_theme_color_override("font_color", UITheme.ACCENT)
	center_msg.add_theme_color_override("font_outline_color", UITheme.OUTLINE_MID)
	center_msg.add_theme_constant_override("outline_size", 12)


func _game_over() -> void:
	# 明确告诉玩家**哪一方最终胜利**（颜色也区分：CT 蓝 / T 红 / 平局金）
	var ct_won := ct_wins > t_wins
	var t_won := t_wins > ct_wins
	if game_over_winner != null:
		game_over_winner.text = UIText.TEAM_WIN % team_name("CT") if ct_won \
				else (UIText.TEAM_WIN % team_name("T") if t_won else UIText.TEAM_DRAW)
		game_over_winner.add_theme_color_override("font_color",
				UITheme.TEAM_CT_TEXT if ct_won
				else (Color(1.0, 0.52, 0.40) if t_won else UITheme.ACCENT))
	if game_over_score != null:
		game_over_score.text = UIText.TEAM_SCORE_TIGHT % [
				team_name("CT"), ct_wins, t_wins, team_name("T")]
	if center_msg != null:
		center_msg.text = ""
	if player != null:
		player._set_scope(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	crosshair_layer.visible = false
	if game_over_menu != null:
		game_over_menu.visible = true
	# ★ 不弹"继续下一场"了 ★
	# 最后一枪打完的瞬间鼠标就会显示出来，玩家还在按射击节奏点击，
	# 而按钮正好在屏幕正中（准星位置）→ 一不留神就点掉、又开一局。
	# 现在只停留展示结果，然后自动回房间界面，要不要再来一局由玩家在房间页点。
	_match_over_pending = true
	_countdown_to_room()


# 结果面板停留若干秒（带倒计时），然后自动回房间界面
func _countdown_to_room() -> void:
	var left := int(GAME_OVER_HOLD)
	while left > 0 and _match_over_pending:
		if game_over_hint != null:
			game_over_hint.text = UIText.GAME_OVER_COUNTDOWN % left
		await get_tree().create_timer(1.0).timeout
		left -= 1
	if _match_over_pending:
		_return_to_room_after_match()


# 整场结束后回房间界面（界面2）：重置比分与场面，等玩家自己再点「进入游戏」。
func _return_to_room_after_match() -> void:
	if not _match_over_pending:
		return          # 已经返回过了（倒计时与手动点按钮的竞态）
	_match_over_pending = false
	round_num = 1
	ct_wins = 0
	t_wins = 0
	bomb_planted = false
	bomb_timer = 0.0
	plant_progress = 0.0
	defuse_progress = 0.0
	_paused = false
	get_tree().paused = false
	if game_over_menu != null:
		game_over_menu.visible = false
	if pause_menu != null:
		pause_menu.visible = false
	if buy_menu != null:
		buy_menu.visible = false
	buy_menu_visible = false
	if center_msg != null:
		center_msg.text = ""
	crosshair_layer.visible = false
	# 复活并放回出生点，避免尸体 / 倒地状态留到下一场
	_spawn_counter = {}
	for p in players:
		p.revive()
		p.velocity = Vector3.ZERO
		p.global_position = _pick_spawn(p.team)
		p.rotation.y = 0.0 if p.team == "CT" else PI
	state = STATE.MENU
	_set_world_active(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_open_map_select()


# 暂停菜单 →「回到房间」：结束本场对局，回房间界面（界面2）
func _leave_match_to_room() -> void:
	round_num = 1
	ct_wins = 0
	t_wins = 0
	bomb_planted = false
	bomb_timer = 0.0
	plant_progress = 0.0
	defuse_progress = 0.0
	# 关闭所有菜单面板（含暂停菜单），取消暂停状态
	_paused = false
	get_tree().paused = false
	if game_over_menu != null:
		game_over_menu.visible = false
	if pause_menu != null:
		pause_menu.visible = false
	if buy_menu != null:
		buy_menu.visible = false
	buy_menu_visible = false
	if player != null:
		player._set_scope(false)
	if center_msg != null:
		center_msg.text = ""
	crosshair_layer.visible = false
	# 客户端断开；房主**保留房间**（回房间页还能接着开）
	if lan != null and lan.is_connected_to_host() and not lan.hosting:
		lan.leave()
	state = STATE.MENU
	_set_world_active(false)       # 角色离场 + 场上音效全停
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_open_map_select()


## 菜单态 / 对局态切换。
## on=false → 所有角色隐藏 + **停止处理**（不再走动、不再发枪声脚步）+ 停掉正在播的音效；
## on=true  → 恢复。
## ★ 只设 visible 是不够的：角色看不见但仍在跑，脚步声照样听得见（用户反馈过）。
func _set_world_active(on: bool) -> void:
	for p in players:
		if p == null:
			continue
		p.visible = on
		p.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
		if not on:
			_stop_sounds_under(p)


## 递归停掉某个节点下面所有正在播的音源
func _stop_sounds_under(n: Node) -> void:
	for c in n.get_children():
		if c is AudioStreamPlayer3D:
			(c as AudioStreamPlayer3D).stop()
		elif c is AudioStreamPlayer:
			(c as AudioStreamPlayer).stop()
		_stop_sounds_under(c)


# ============================================================ 菜单统一视觉规范
# 所有界面（大厅 / 房间 / 购买 / 暂停 / 整场结束 / 计分板 / HUD / 击杀信息流 / 小地图）
# 共用同一套配色与组件。
# ★ 想整体换配色：只改 scripts/ui_theme.gd 那一个文件 ★
# 组件形态（圆角 / 内边距 / 描边宽度）改下面这几个 _menu_* / _btn_* / _card_* 函数。


# 菜单背景层：底色（可选主视觉图）+ 两层渐变遮罩 + 极细暖金内框
# use_art = true 时铺 resources/menu_bg.png；dim 控制整体压暗程度
# （暂停/整场结束用 dim≈0.74 半透明压在游戏画面上，其余菜单用 0.90 近乎不透明）
func _menu_backdrop(parent: Control, use_art := false, dim := -1.0) -> void:
	if dim < 0.0:
		dim = UITheme.SCRIM_BOTTOM.a
	var art: Texture2D = null
	if use_art and ResourceLoader.exists(MENU_BG_PATH):
		var r: Resource = load(MENU_BG_PATH)
		if r is Texture2D:
			art = r
	if art != null:
		var bg_img := TextureRect.new()
		bg_img.texture = art
		bg_img.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(bg_img)
		# 纵向：上浅下深；横向：左深右浅（左侧留给标题，右侧露出主视觉）
		parent.add_child(_menu_scrim(Vector2(0.5, 0.0), Vector2(0.5, 1.0),
				UITheme.SCRIM_TOP, Color(UITheme.SCRIM_BOTTOM.r, UITheme.SCRIM_BOTTOM.g, UITheme.SCRIM_BOTTOM.b, dim)))
		parent.add_child(_menu_scrim(Vector2(0.0, 0.5), Vector2(1.0, 0.5),
				UITheme.SCRIM_LEFT, UITheme.SCRIM_RIGHT))
	else:
		var bg := ColorRect.new()
		bg.color = Color(UITheme.BG.r, UITheme.BG.g, UITheme.BG.b, dim)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(bg)

	var frame := Panel.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 16.0
	frame.offset_top = 16.0
	frame.offset_right = -16.0
	frame.offset_bottom = -16.0
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0)
	fsb.border_color = UITheme.FRAME
	fsb.set_border_width_all(1)
	frame.add_theme_stylebox_override("panel", fsb)
	parent.add_child(frame)


# 标准卡片（面板）样式
func _card_style(pad_h := 26.0, pad_v := 22.0, radius := 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.CARD
	sb.border_color = UITheme.CARD_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


# 主按钮（金色 CTA）
func _btn_primary(text: String, w := 300.0, h := 58.0, fsize := 22) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, h)
	b.add_theme_font_size_override("font_size", fsize)
	# 不接受键盘焦点：否则点过一次后按钮一直持有焦点，之后按空格/回车
	# 会再次触发它 —— 表现就是"在主菜单按空格居然开局了、准星也出来了"
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", UITheme.ON_ACCENT)
	b.add_theme_color_override("font_hover_color", UITheme.ON_ACCENT_DIM)
	b.add_theme_color_override("font_pressed_color", UITheme.ON_ACCENT_DIM)
	b.add_theme_color_override("font_focus_color", UITheme.ON_ACCENT)
	b.add_theme_stylebox_override("normal", _cta_style(UITheme.CTA))
	b.add_theme_stylebox_override("hover", _cta_style(UITheme.CTA_HOVER))
	b.add_theme_stylebox_override("pressed", _cta_style(UITheme.CTA_DOWN))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


# 次按钮（幽灵按钮：透明底 + 细边，hover 才浮出底色并转金）
func _btn_ghost(text: String, w := 300.0, h := 46.0, fsize := 17) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, h)
	b.add_theme_font_size_override("font_size", fsize)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", UITheme.ACCENT)
	b.add_theme_color_override("font_pressed_color", UITheme.ACCENT)
	b.add_theme_stylebox_override("normal", _ghost_style(false))
	b.add_theme_stylebox_override("hover", _ghost_style(true))
	b.add_theme_stylebox_override("pressed", _ghost_style(true))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _ghost_style(hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.GHOST_BG if hover else Color(0, 0, 0, 0)
	sb.border_color = Color(UITheme.ACCENT_DIM.r, UITheme.ACCENT_DIM.g, UITheme.ACCENT_DIM.b, 0.85) if hover \
			else UITheme.GHOST_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(7)
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb


# 菜单大标题（金色 + 深描边）
func _menu_title(text: String, fsize := 40) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fsize)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", UITheme.ACCENT)
	l.add_theme_color_override("font_outline_color", UITheme.OUTLINE)
	l.add_theme_constant_override("outline_size", 10)
	return l


# 暖金细线 + 45° 菱形装饰（开始菜单同款语汇）
func _menu_rule(centered := false, line_w := 104.0) -> HBoxContainer:
	var rule := HBoxContainer.new()
	rule.add_theme_constant_override("separation", 10)
	rule.alignment = BoxContainer.ALIGNMENT_CENTER if centered else BoxContainer.ALIGNMENT_BEGIN
	var line := ColorRect.new()
	line.color = Color(UITheme.ACCENT_DIM.r, UITheme.ACCENT_DIM.g, UITheme.ACCENT_DIM.b, 0.85)
	line.custom_minimum_size = Vector2(line_w, 2)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_child(line)
	var dia := ColorRect.new()
	dia.color = UITheme.ACCENT
	dia.custom_minimum_size = Vector2(8, 8)
	dia.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dia.pivot_offset = Vector2(4, 4)
	dia.rotation = PI * 0.25
	dia.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_child(dia)
	return rule


# 带竖条的小标题行（如「▎操作说明」）
func _menu_heading(text: String, fsize := 17, centered := false) -> HBoxContainer:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 9)
	head.alignment = BoxContainer.ALIGNMENT_CENTER if centered else BoxContainer.ALIGNMENT_BEGIN
	var bar := ColorRect.new()
	bar.color = UITheme.ACCENT_DIM
	bar.custom_minimum_size = Vector2(3, 18)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(bar)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", UITheme.TEXT)
	head.add_child(l)
	return head


func _build_game_over_menu(scene: Node) -> void:
	game_over_menu = Control.new()
	game_over_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	game_over_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	game_over_menu.visible = false
	scene.add_child(game_over_menu)

	_menu_backdrop(game_over_menu, false, 0.74)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	game_over_menu.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_stylebox_override("panel", _card_style(44.0, 32.0, 14))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	vb.add_child(_menu_title(UIText.GAME_OVER_TITLE, 32))
	vb.add_child(_menu_rule(true, 76.0))

	# 哪一方最终胜利（颜色区分：CT 蓝 / T 红 / 平局金）
	game_over_winner = Label.new()
	game_over_winner.add_theme_font_size_override("font_size", 40)
	game_over_winner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_over_winner.add_theme_color_override("font_outline_color", UITheme.OUTLINE)
	game_over_winner.add_theme_constant_override("outline_size", 8)
	vb.add_child(game_over_winner)

	game_over_score = Label.new()
	game_over_score.add_theme_font_size_override("font_size", 26)
	game_over_score.add_theme_color_override("font_color", UITheme.TEXT)
	game_over_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(game_over_score)

	game_over_hint = Label.new()
	game_over_hint.add_theme_font_size_override("font_size", 15)
	game_over_hint.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	game_over_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(game_over_hint)

	# ★ 这里**故意没有"继续下一场"** ★
	# 最后一枪打完的瞬间鼠标就恢复显示，玩家还在按射击节奏点击，
	# 而按钮正好在屏幕正中（准星位置）→ 一不留神就点掉、又开一局。
	# 现在只保留「返回房间」，而且不点它也会自动回房间界面。
	var btn_room := _btn_primary(UIText.BTN_BACK_ROOM, 280.0, 52.0, 19)
	btn_room.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn_room.pressed.connect(_return_to_room_after_match)
	vb.add_child(btn_room)


# 暂停菜单（ESC 唤出）：风格与 game_over_menu 一致
func _build_pause_menu(scene: Node) -> void:
	pause_menu = Control.new()
	pause_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_menu.visible = false
	# 暂停时仍可响应输入（process_mode = ALWAYS）
	pause_menu.process_mode = Node.PROCESS_MODE_ALWAYS
	scene.add_child(pause_menu)

	_menu_backdrop(pause_menu, false, 0.74)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_stylebox_override("panel", _card_style(40.0, 30.0, 14))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	panel.add_child(vb)
	vb.add_child(_menu_title(UIText.PAUSE_TITLE, 38))
	vb.add_child(_menu_rule(true, 76.0))

	var btn_resume := _btn_primary(UIText.BTN_RESUME, 260.0, 52.0, 19)
	btn_resume.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn_resume.pressed.connect(_resume_game)
	vb.add_child(btn_resume)

	var btn_menu := _btn_ghost(UIText.BTN_LEAVE_TO_ROOM, 260.0, 46.0, 17)
	btn_menu.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn_menu.pressed.connect(_leave_match_to_room)
	vb.add_child(btn_menu)


# 暂停游戏
func _pause_game() -> void:
	if _paused: return
	_paused = true
	get_tree().paused = true
	if player != null:
		player._set_scope(false)
	pause_menu.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	crosshair_layer.visible = false


# 继续游戏
func _resume_game() -> void:
	if not _paused: return
	_paused = false
	get_tree().paused = false
	pause_menu.visible = false
	_capture_mouse()
	crosshair_layer.visible = true


# ============================================================ HUD
func _build_hud(scene: Node) -> void:
	hud_root = Control.new()
	hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 必须设为 IGNORE：FULL_RECT 后 hud_root 占满屏幕，默认 STOP 会拦截所有鼠标事件
	# 导致开火/视角旋转等游戏输入失效
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scene.add_child(hud_root)

	hud_ammo = _label(Vector2(20, 820), 30)
	hud_status = _label(Vector2(20, 760), 24)
	# 左下角血量上方的提示条（人数上限等提示，短暂显示后淡出）
	hud_toast = _label(Vector2(20, 700), 20)
	hud_toast.visible = false
	hud_toast.add_theme_color_override("font_color", UITheme.ACCENT)
	center_msg = _label(Vector2(0, 231), 48)
	# 定位到倒计时(底边y=92)与准星(y=450)的中间，文字中心在 y=271
	center_msg.size = Vector2(1600, 80)
	center_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center_msg.visible = true
	_build_top_score(hud_root)
	_build_progress_bar(hud_root)
	# 左上角圆形雷达小地图（T红 CT蓝，跟随视角，只显示视野内目标）
	minimap = load("res://scripts/minimap.gd").new()
	minimap.position = Vector2(20, 20)
	minimap.custom_minimum_size = Vector2(210, 210)
	minimap.size = Vector2(210, 210)
	minimap.visible = false
	hud_root.add_child(minimap)
	# 右上角击杀信息流（谁击杀了谁，与小地图左上角对称，距右边 50px 留白）
	kill_feed = VBoxContainer.new()
	kill_feed.position = Vector2(1600 - 300 - 50, 20)
	kill_feed.size = Vector2(300, 0)
	kill_feed.custom_minimum_size = Vector2(300, 0)
	hud_root.add_child(kill_feed)
	# 屏幕中间下方（约 62% 高度处）的击杀/爆头图标提示
	kill_notice = TextureRect.new()
	kill_notice.position = Vector2(1600 * 0.5 - 240, 900 * 0.62)
	kill_notice.custom_minimum_size = Vector2(480, 120)
	kill_notice.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	kill_notice.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	kill_notice.modulate = Color(1, 1, 1, 1)
	kill_notice.visible = false
	hud_root.add_child(kill_notice)
	_snd_kill = AudioStreamPlayer.new()
	_snd_kill.volume_db = linear_to_db(0.7)
	_snd_kill.max_polyphony = 3
	hud_root.add_child(_snd_kill)
	
	_build_scoreboard(scene)


# ============================================================ 计分板
func _build_scoreboard(scene: Node) -> void:
	scoreboard = Control.new()
	scoreboard.set_anchors_preset(Control.PRESET_FULL_RECT)
	scoreboard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scoreboard.visible = false
	scene.add_child(scoreboard)

	# 半透明深色背景
	var bg := ColorRect.new()
	bg.color = UITheme.MODAL_DIM
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	scoreboard.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	scoreboard.add_child(center)

	# 面板固定尺寸：无论加入多少 bot，高度都不变（不足的队伍补空行）
	var main_panel := PanelContainer.new()
	main_panel.custom_minimum_size = Vector2(1040, 0)
	var panel_style := _card_style(28.0, 20.0, 14)
	panel_style.bg_color = UITheme.MODAL
	panel_style.border_color = Color(UITheme.ACCENT_DIM.r, UITheme.ACCENT_DIM.g, UITheme.ACCENT_DIM.b, 0.55)
	panel_style.set_border_width_all(2)
	panel_style.shadow_color = UITheme.SHADOW
	panel_style.shadow_size = 18
	main_panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(main_panel)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 8)
	main_panel.add_child(main_vbox)

	# 标题（与其它菜单同一套金字 + 细线语汇）
	var title_label := Label.new()
	title_label.text = UIText.SCORE_TITLE
	title_label.add_theme_font_size_override("font_size", 32)
	title_label.add_theme_color_override("font_color", UITheme.ACCENT)
	title_label.add_theme_color_override("font_outline_color", UITheme.OUTLINE)
	title_label.add_theme_constant_override("outline_size", 8)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.custom_minimum_size = Vector2(0, 42)
	main_vbox.add_child(title_label)
	main_vbox.add_child(_menu_rule(true, 140.0))

	# 总比分（CT 蓝 / T 红，一眼看出谁领先）
	scoreboard_score = Label.new()
	scoreboard_score.add_theme_font_size_override("font_size", 24)
	scoreboard_score.add_theme_color_override("font_color", UITheme.TEXT)
	scoreboard_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	scoreboard_score.custom_minimum_size = Vector2(0, 32)
	main_vbox.add_child(scoreboard_score)

	# 表头
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 0)
	header.custom_minimum_size = Vector2(0, 30)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_vbox.add_child(header)
	header.add_child(_score_header(UIText.SCORE_COL_RANK, 60))
	var header_dot := _score_header("", 22)
	header.add_child(header_dot)
	var header_name := _score_header(UIText.SCORE_COL_NAME, 10)
	header_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	header_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_name)
	header.add_child(_score_header(UIText.SCORE_COL_KILLS, 110))
	header.add_child(_score_header(UIText.SCORE_COL_DEATHS, 110))

	var sep := HSeparator.new()
	sep.modulate = UITheme.SEP_LINE
	main_vbox.add_child(sep)

	# T 阵营（占一半高度）
	var t_section := VBoxContainer.new()
	t_section.add_theme_constant_override("separation", 4)
	t_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(t_section)
	var t_head := _score_team_head("T", team_color("T"))
	t_section.add_child(t_head[0])
	scoreboard_t_title = t_head[2]
	scoreboard_t_container = VBoxContainer.new()
	scoreboard_t_container.add_theme_constant_override("separation", 3)
	scoreboard_t_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	t_section.add_child(scoreboard_t_container)

	# CT 阵营（占一半高度）
	var ct_section := VBoxContainer.new()
	ct_section.add_theme_constant_override("separation", 4)
	ct_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(ct_section)
	var ct_head := _score_team_head("CT", team_color("CT"))
	ct_section.add_child(ct_head[0])
	scoreboard_ct_title = ct_head[2]
	scoreboard_ct_container = VBoxContainer.new()
	scoreboard_ct_container.add_theme_constant_override("separation", 3)
	scoreboard_ct_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ct_section.add_child(scoreboard_ct_container)

	# 底部说明
	var hint := Label.new()
	hint.text = UIText.SCORE_HINT
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.custom_minimum_size = Vector2(0, 26)
	main_vbox.add_child(hint)


func _score_header(text: String, width: float) -> Label:
	var hl := Label.new()
	hl.text = text
	hl.add_theme_font_size_override("font_size", 18)
	hl.add_theme_color_override("font_color", UITheme.TEXT_SOFT)
	hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hl.custom_minimum_size = Vector2(width, 30)
	hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return hl


## 队伍标题行：色条 + 队名 + 右侧"X 胜"。
## 返回 [整行, 队名 Label, 胜场 Label]，胜场那个要留着每帧更新。
func _score_team_head(team: String, color: Color) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 34)
	var bar := ColorRect.new()
	bar.color = color
	bar.custom_minimum_size = Vector2(4, 22)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	var nm := Label.new()
	nm.text = team_full(team)
	nm.add_theme_font_size_override("font_size", 20)
	nm.add_theme_color_override("font_color", color)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(nm)
	var win := Label.new()
	win.add_theme_font_size_override("font_size", 18)
	win.add_theme_color_override("font_color", color)
	win.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(win)
	return [row, nm, win]


func _update_scoreboard() -> void:
	if scoreboard_t_container == null or scoreboard_ct_container == null:
		return
	
	# 清空现有内容
	for child in scoreboard_t_container.get_children():
		child.queue_free()
	for child in scoreboard_ct_container.get_children():
		child.queue_free()
	
	# 收集所有玩家数据
	var t_players: Array[Dictionary] = []
	var ct_players: Array[Dictionary] = []
	
	for p in players:
		var data := {
			"player": p,
			"nick": p.nick,
			"team": p.team,
			"kills": p.kills,
			"deaths": p.deaths,
			"alive": p.alive,
			"is_human": not p.is_bot
		}
		if p.team == "T":
			t_players.append(data)
		else:
			ct_players.append(data)
	
	# 按击杀数排序（击杀高的在前）
	t_players.sort_custom(func(a, b): return a["kills"] > b["kills"])
	ct_players.sort_custom(func(a, b): return a["kills"] > b["kills"])
	
	# 总比分 + 两队的胜场数
	if scoreboard_score != null:
		scoreboard_score.text = UIText.TEAM_SCORE % [
				team_name("CT"), ct_wins, t_wins, team_name("T")]
		scoreboard_score.add_theme_color_override("font_color",
				UITheme.TEAM_CT_TEXT if ct_wins > t_wins
				else (UITheme.TEAM_T_TEXT if t_wins > ct_wins else UITheme.TEXT))
	if scoreboard_t_title != null:
		scoreboard_t_title.text = UIText.TEAM_WINS % t_wins
	if scoreboard_ct_title != null:
		scoreboard_ct_title.text = UIText.TEAM_WINS % ct_wins

	# 填充 T 阵营
	_fill_scoreboard_team(scoreboard_t_container, t_players, team_color("T"))

	# 填充 CT 阵营
	_fill_scoreboard_team(scoreboard_ct_container, ct_players, team_color("CT"))


# 从 config.toml [ui] 读取颜色（RGB 取值 0~255 三通道，alpha 用默认值；也兼容四通道写法），引擎内自动转 0~1
func _ui_color(key: String, default: Array) -> Color:
	var def_r := float(default[0]) / 255.0
	var def_g := float(default[1]) / 255.0
	var def_b := float(default[2]) / 255.0
	var def_a := float(default[3]) / 255.0
	var v: Variant = null
	if ConfigManager.instance != null:
		v = ConfigManager.instance.get_ui(key, null)
	if v == null or not (v is Array) or v.size() < 3:
		return Color(def_r, def_g, def_b, def_a)
	var a := def_a
	if v.size() >= 4:
		a = float(v[3]) / 255.0
	return Color(float(v[0]) / 255.0, float(v[1]) / 255.0, float(v[2]) / 255.0, a)


func _fill_scoreboard_team(container: VBoxContainer, team_players: Array[Dictionary], team_color: Color) -> void:
	# 隔行背景色（浅灰，可在 config.toml [ui] 修改）
	var odd_col := _ui_color("score_row_color_odd", [128, 135, 153, 56])
	var even_col := _ui_color("score_row_color_even", [0, 0, 0, 0])
	# 名次配色：前三名金银铜，其余暗色
	var rank_cols: Array[Color] = [
		UITheme.RANK_1, UITheme.RANK_2, UITheme.RANK_3,
	]
	# 固定渲染 MAX_TEAM_PLAYERS 行：玩家不足时补空行，保证面板高度不随 bot 增减而浮动
	for i in range(MAX_TEAM_PLAYERS):
		if i >= team_players.size():
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(0, 32)
			spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
			container.add_child(spacer)
			continue
		var p := team_players[i]
		# 整行一个 PanelContainer：自带隔行底色 / 自己的高亮金边
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(0, 32)
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var rsb := StyleBoxFlat.new()
		rsb.bg_color = odd_col if i % 2 == 0 else even_col
		rsb.set_corner_radius_all(4)
		rsb.content_margin_left = 6.0
		rsb.content_margin_right = 6.0
		if p["is_human"]:
			# 自己那一行：淡金底 + 左侧金条，一眼找到
			rsb.bg_color = Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.14)
			rsb.border_color = UITheme.ACCENT
			rsb.border_width_left = 3
		row.add_theme_stylebox_override("panel", rsb)
		container.add_child(row)

		var inner := HBoxContainer.new()
		inner.add_theme_constant_override("separation", 0)
		row.add_child(inner)

		# 名次（最左）
		var rank_label := Label.new()
		rank_label.text = str(i + 1)
		rank_label.add_theme_font_size_override("font_size", 17)
		rank_label.add_theme_color_override("font_color",
				rank_cols[i] if i < rank_cols.size() else UITheme.RANK_OTHER)
		rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rank_label.custom_minimum_size = Vector2(60, 32)
		inner.add_child(rank_label)

		# 存活指示（● 亮绿 / 阵亡灰）
		var alive_label := Label.new()
		alive_label.text = "●"
		alive_label.add_theme_font_size_override("font_size", 13)
		alive_label.add_theme_color_override("font_color",
				UITheme.ALIVE_DOT if p["alive"] else UITheme.DEAD_DOT)
		alive_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		alive_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		alive_label.custom_minimum_size = Vector2(22, 32)
		inner.add_child(alive_label)

		# 名字（弹性撑满中间）
		var name_label := Label.new()
		# 直接显示玩家填的昵称。自己那一行靠左侧金条 + 淡金底标识，不再缀 "(你)"
		name_label.text = str(p["nick"])
		name_label.add_theme_font_size_override("font_size", 17)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.add_child(name_label)

		# 击杀 / 死亡（各自一列，比"12 / 3"更好对位）
		var kills_label := Label.new()
		kills_label.text = str(p["kills"])
		kills_label.add_theme_font_size_override("font_size", 17)
		kills_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		kills_label.custom_minimum_size = Vector2(110, 32)
		inner.add_child(kills_label)

		var deaths_label := Label.new()
		deaths_label.text = str(p["deaths"])
		deaths_label.add_theme_font_size_override("font_size", 17)
		deaths_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		deaths_label.custom_minimum_size = Vector2(110, 32)
		inner.add_child(deaths_label)

		# 阵亡置灰；存活显示阵营色
		var text_color := team_color if p["alive"] else UITheme.DEAD_TEXT
		for child in [name_label, kills_label, deaths_label]:
			(child as Label).add_theme_color_override("font_color", text_color)


func _label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	hud_root.add_child(l)
	return l


## 顶部中央比分条：总局数最大加粗居中最显眼，两侧 CT/T 阵营赢局数用蓝/红色区分（CF 风格）
func _build_top_score(root: Control) -> void:
	var bar := PanelContainer.new()
	bar.position = Vector2(1600 * 0.5 - 215, 12)
	bar.custom_minimum_size = Vector2(430, 96)
	var style := StyleBoxFlat.new()
	style.bg_color = UITheme.PANEL
	style.border_color = Color(UITheme.ACCENT_DIM.r, UITheme.ACCENT_DIM.g, UITheme.ACCENT_DIM.b, 0.60)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.shadow_color = UITheme.SHADOW
	style.shadow_size = 12
	bar.add_theme_stylebox_override("panel", style)
	root.add_child(bar)

	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 0)
	bar.add_child(hb)

	# ---------------- 左：防守方（磐垒）
	var ct_col := team_color("CT")
	var ct_vb := _score_side_column(team_name("CT"), ct_col)
	hb.add_child(ct_vb[0])
	hud_score_ct_head = ct_vb[1]
	hud_score_ct = ct_vb[2]
	hb.add_child(_score_vline())

	# ---------------- 中：胜利条件（先赢够 N 回合）
	# ★ 这个数字是"赢多少回合算赢"，不是"总局数"，也不是"当前第几回合" ★
	var mid_vb := VBoxContainer.new()
	mid_vb.add_theme_constant_override("separation", 2)
	mid_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	mid_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(mid_vb)

	# 只放一个大数字（= 先赢够几个回合算赢），不放任何说明文字
	hud_score_total = Label.new()
	hud_score_total.text = str(WIN_ROUNDS)
	hud_score_total.add_theme_font_size_override("font_size", 52)
	hud_score_total.add_theme_color_override("font_color", UITheme.ACCENT)
	hud_score_total.add_theme_constant_override("outline_size", 10)
	hud_score_total.add_theme_color_override("font_outline_color", UITheme.OUTLINE_ACCENT)
	hud_score_total.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_score_total.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud_score_total.custom_minimum_size = Vector2(96, 0)
	mid_vb.add_child(hud_score_total)

	hb.add_child(_score_vline())

	# ---------------- 右：进攻方（锐刃）
	var t_col := team_color("T")
	var t_vb := _score_side_column(team_name("T"), t_col)
	hb.add_child(t_vb[0])
	hud_score_t_head = t_vb[1]
	hud_score_t = t_vb[2]

	# 剩余时间 / 剩余敌人数（小字，压在比分条正下方中央）
	hud_time = Label.new()
	hud_time.position = Vector2(1600 * 0.5 - 150, 114)
	hud_time.custom_minimum_size = Vector2(300, 26)
	hud_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_time.add_theme_font_size_override("font_size", 18)
	hud_time.add_theme_color_override("font_color", UITheme.TEXT_HUD)
	hud_time.add_theme_color_override("font_outline_color", UITheme.OUTLINE_HUD)
	hud_time.add_theme_constant_override("outline_size", 8)
	hud_time.text = ""
	hud_time.visible = false
	root.add_child(hud_time)


## 比分条左右两侧的"队名 + 胜场数"竖列。返回 [整列, 队名 Label, 胜场 Label]
func _score_side_column(team_name: String, col: Color) -> Array:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.custom_minimum_size = Vector2(140, 0)
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var head := Label.new()
	head.text = team_name
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", Color(col.r, col.g, col.b, 0.95))
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(head)

	var num := Label.new()
	num.text = "0"
	num.add_theme_font_size_override("font_size", 38)
	num.add_theme_color_override("font_color", col)
	num.add_theme_constant_override("outline_size", 8)
	num.add_theme_color_override("font_outline_color", UITheme.OUTLINE_SCORE)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(num)
	return [vb, head, num]


## 比分条里的竖分隔线
func _score_vline() -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(UITheme.ACCENT_DIM.r, UITheme.ACCENT_DIM.g, UITheme.ACCENT_DIM.b, 0.35)
	line.custom_minimum_size = Vector2(1, 56)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _build_progress_bar(root: Control) -> void:
	hud_progress_label = _label(Vector2(1600 * 0.5 - 200, 668), 18)
	hud_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_progress_label.text = ""
	hud_progress_label.visible = false
	hud_progress = ProgressBar.new()
	hud_progress.position = Vector2(1600 * 0.5 - 200, 696)
	hud_progress.custom_minimum_size = Vector2(400, 18)
	hud_progress.max_value = 1.0
	hud_progress.show_percentage = false
	hud_progress.visible = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = UITheme.BAR_BG
	bg.border_color = UITheme.BAR_EDGE
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(9)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UITheme.ACCENT
	fill.set_corner_radius_all(9)
	hud_progress.add_theme_stylebox_override("background", bg)
	hud_progress.add_theme_stylebox_override("fill", fill)
	root.add_child(hud_progress)


func _update_hud() -> void:
	if hud_ammo == null: return
	# 顶部回合计分板：双方胜场 + 当前回合 / 总回合
	hud_score_ct.text = str(ct_wins)
	hud_score_t.text = str(t_wins)
	hud_score_total.text = str(WIN_ROUNDS)   # 胜利条件（先赢够 N 回合），恒定值
	# 显示倒计时（剩余时间小字，放总局数下方；仅对局阶段显示，购买计时在购买面板中）
	if state == STATE.LIVE:
		var time_left := int(timer)
		var minutes := time_left / 60
		var seconds := time_left % 60
		# 顶部同时显示剩余敌人数：用户反馈"杀了最后一个却没反应"，
		# 多半是还有敌人藏在视野外 —— 一直没这个数字，玩家根本无从判断
		var enemies_left := 0
		if player != null:
			for q in players:
				if q.alive and q.team != player.team:
					enemies_left += 1
		hud_time.text = UIText.HUD_TIME % [minutes, seconds, enemies_left]
		hud_time.visible = true
		# 最后 60 秒：红色并闪烁（每 0.5 秒一亮一灭）
		if time_left <= 60:
			hud_time.add_theme_color_override("font_color", UITheme.WARN_TEXT)
			var flash := int(Time.get_ticks_msec() / 500) % 2 == 0
			hud_time.modulate.a = 1.0 if flash else 0.25
		else:
			hud_time.add_theme_color_override("font_color", UITheme.TEXT_HUD)
			hud_time.modulate.a = 1.0
	else:
		hud_time.visible = false
	if player:
		var cur: Dictionary = player.weapons.get(player.active_slot, {})
		var mag: int = cur.get("mag", 0)
		var res: int = cur.get("reserve", 0)
		# 弹药前显示当前武器名（从武器数据库取中文名）
		var wid: String = cur.get("id", "")
		var wname: String = WeaponDatabase.weapons().get(wid, {}).get("name", wid)
		# 小刀是近战武器，不显示弹药
		if wid == "Knife":
			hud_ammo.text = UIText.HUD_MELEE % wname
		else:
			hud_ammo.text = UIText.HUD_AMMO % [wname, mag, res]
		var at := "%.0f" % player.armor
		hud_status.text = UIText.HUD_STATUS % [player.health, at, player.money, team_name(player.team)]
		# 准星动态扩散：跟随后坐力，开火时变大停火回正
		if crosshair_control != null:
			crosshair_control.spread = player._recoil
			# 狙击枪未开镜时不该有准星（CS 行为）—— 交给准星自己跳过绘制，
			# 不去动 crosshair_layer.visible，避免和开镜/菜单的显隐逻辑打架
			crosshair_control.hidden_by_weapon = player.is_unscoped_sniper()
			crosshair_control.queue_redraw()
		# 只在对局进行中才显示炸弹倒计时。
		# 之前少了 state 判断 —— 回合结束后这里**每帧都把 center_msg 覆盖成倒计时**，
		# 「X 阵营胜利」刚写上去下一帧就被冲掉了，玩家根本看不到胜利提示。
		if bomb_planted and state == STATE.LIVE:
			# C4 已安放时杀光 T 不会立刻结束回合（CS 规则：CT 必须拆弹），
			# 这时候一定要告诉玩家该干嘛，否则就像"卡住了"。
			var t_left := 0
			for q in players:
				if q.alive and q.team == "T":
					t_left += 1
			if t_left == 0 and player != null and player.alive and player.team == "CT":
				center_msg.text = UIText.HUD_C4_CLEARED % bomb_timer
			else:
				center_msg.text = UIText.HUD_C4_TIMER % bomb_timer
	# 屏幕中下动作进度条：换弹 / 拉栓 / 安装 C4 / 拆除 C4
	var progress_visible := false
	if player != null and player.reload_progress >= 0.0:
		hud_progress.value = player.reload_progress
		hud_progress_label.text = UIText.HUD_RELOADING
		progress_visible = true
	elif player != null and player.bolt_progress >= 0.0:
		# 栓动狙（AWP / Scout）打完一发的拉栓硬直，期间不能开火
		hud_progress.value = player.bolt_progress
		hud_progress_label.text = UIText.HUD_BOLTING
		progress_visible = true
	elif player != null and plant_progress > 0.0 and player.team == "T" and player.has_c4:
		hud_progress.value = plant_progress / PLANT_TIME
		hud_progress_label.text = UIText.HUD_PLANTING
		progress_visible = true
	elif player != null and defuse_progress > 0.0 and player.team == "CT":
		var need := DEFUSE_KIT_TIME if player.has_defuser else DEFUSE_TIME
		hud_progress.value = defuse_progress / need
		hud_progress_label.text = UIText.HUD_DEFUSING
		progress_visible = true
	hud_progress.visible = progress_visible
	hud_progress_label.visible = progress_visible
	# 小地图只在游戏对局阶段显示
	if minimap != null:
		minimap.visible = state == STATE.LIVE or state == STATE.BUY


# ============================================================ 击杀提示
func _on_player_died(victim: CSPlayer, killer: CSPlayer, head: bool, weapon_id: String) -> void:
	_push_kill_feed(victim, killer, head, weapon_id)
	# 联机时只有房主会结算伤害 → 信息流也由房主广播一份给客户端
	if lan != null and lan.hosting:
		_net_kill_feed.rpc(
				killer.nick if killer != null else "? ? ?",
				killer.team if killer != null else "T",
				weapon_id, victim.nick, victim.team)
	_drop_primary_on_death(victim)
	if killer == player:
		player.add_money(300 if not head else 450)
		_show_kill_notice(UIText.KILL_HEADSHOT if head else UIText.KILL_NORMAL, head)


# 倒地后把主武器掉到地上，别人可以捡（CF / CS 行为）
func _drop_primary_on_death(victim: CSPlayer) -> void:
	if victim == null:
		return
	var wid := victim.take_primary()
	# 远端真人的武器只存在他自己那台机器上，房主这边手里是空的 —— 用同步过来的 id 兜底
	if wid == "":
		wid = victim.net_primary
	if wid == "":
		return
	# 尸体脚下往前一点（沿用丢枪那套距离 + 落地保护，避免刚落地就被踩回去）
	var fwd := -victim.global_transform.basis.z
	var at := victim.global_position + fwd * DROP_DIST
	at.y = 0.0
	_make_pickup(at, wid, false, DROP_ARM_DELAY)


# 地面武器拾取策略（人类玩家与 bot 不同）：
#   · 人类玩家 → 沿用 pickup_weapon 的规则：已有主武器就不能再捡（必须先按 G 丢掉）
#   · bot      → 没有主武器必捡；地上的枪**明显更好**（价格高出 BOT_SWAP_MARGIN 以上）也换，
#                换枪时把旧主武器丢回地上 —— 不然十几个 bot 会把地图上的枪吃光，玩家没得捡。
# 阈值取 800：只做"真正的升级"（如 Galil→AWP），同类步枪之间（Galil→AK47 差 500）不来回换。
const BOT_SWAP_MARGIN := 800

func try_pickup_weapon(pl: CSPlayer, weapon_id: String) -> bool:
	if pl == null or not pl.alive:
		return false
	if not pl.is_bot:
		return pl.pickup_weapon(weapon_id)
	var spec: Dictionary = WeaponDatabase.weapons().get(weapon_id, {})
	if spec.is_empty():
		return false
	# 非主武器（手枪等）仍走原规则
	if int(spec.get("slot", 1)) != 1:
		return pl.pickup_weapon(weapon_id)
	# bot 手上没主武器 → 直接捡
	if not pl.has_primary():
		return pl.pickup_weapon(weapon_id)
	# 已有主武器 → 只换"更值钱"的（价格差超过阈值），避免来回换枪抖动
	var cur_id := pl.get_primary_id()
	if cur_id == "" or cur_id == weapon_id:
		return false
	var cur_spec: Dictionary = WeaponDatabase.weapons().get(cur_id, {})
	if int(spec.get("price", 0)) - int(cur_spec.get("price", 0)) <= BOT_SWAP_MARGIN:
		return false
	var old_id := pl.take_primary()
	if old_id == "":
		return false
	pl.give_weapon(1, weapon_id)
	pl._switch_slot(1)
	# 旧枪丢回地上，保持地图上的枪总数不变
	# （GM 根节点是 Node，没有 global_position，这里只能用 bot 自己的朝向）
	var fwd: Vector3 = -pl.global_transform.basis.z
	var at: Vector3 = pl.global_position + fwd * DROP_DIST
	at.y = 0.0
	_make_pickup(at, old_id, false, DROP_ARM_DELAY)
	return true


# ---------------------------------------------------------------- 枪械图标
# 图标由 scripts/weapon_icons.gd 离线渲染（godot --gen-weapon-icons），
# 存在 res://models/icons/weapons/<武器 id>.png。这里做一层缓存，
# 避免每次击杀都去查盘；查不到也缓存 null，不会反复 exists()。
const KILL_FEED_ICON_W := 78.0
const KILL_FEED_ICON_H := 39.0

var _weapon_icon_cache: Dictionary = {}

func _weapon_icon(wid: String) -> Texture2D:
	if wid == "":
		return null
	if _weapon_icon_cache.has(wid):
		return _weapon_icon_cache[wid] as Texture2D
	var tex: Texture2D = null
	var path := "res://models/icons/weapons/%s.png" % wid
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_weapon_icon_cache[wid] = tex
	return tex


func _feed_name(text: String, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", col)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


# 信息流中段的「武器」位。图标缺失（新武器还没渲染图标）时退回文字，保证信息不丢。
func _feed_weapon(wid: String) -> Control:
	var tex := _weapon_icon(wid)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = Vector2(KILL_FEED_ICON_W, KILL_FEED_ICON_H)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		return tr
	var l := Label.new()
	l.text = UIText.KILL_NOTICE_BADGE
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	return l


func _push_kill_feed(victim: CSPlayer, killer: CSPlayer, head: bool, weapon_id: String) -> void:
	if kill_feed == null: return
	_feed_add_row(
		killer.nick if killer != null else "? ? ?",
		killer.team if killer != null else "T",
		weapon_id,
		victim.nick,
		victim.team)


# 信息流单行：击杀者名 / 武器图案 / 被击杀者名（按阵营着色）
# 拆成独立函数是为了让调试截图能直接塞假数据，不必先造出 CSPlayer 实例
func _feed_add_row(kname: String, kteam: String, weapon_id: String, vname: String, vteam: String) -> void:
	if kill_feed == null: return
	var kcol := UITheme.TEAM_CT_TEXT if kteam == "CT" else UITheme.TEAM_T_TEXT
	var vcol := UITheme.TEAM_T_TEXT if vteam == "T" else UITheme.TEAM_CT_TEXT
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 6)
	row.add_child(_feed_name(kname, kcol))
	row.add_child(_feed_weapon(weapon_id))
	row.add_child(_feed_name(vname, vcol))
	kill_feed.add_child(row)
	kill_feed.move_child(row, 0)
	# 只保留最近 5 条。
	#
	# ★ 必须"先 remove_child 再 queue_free"，不能只 queue_free ★
	# queue_free() 是**延迟删除**（本帧末尾才真正移除），所以
	#   while kill_feed.get_child_count() > 5:
	#       kill_feed.get_child(...).queue_free()
	# 里 get_child_count() 在循环内根本不会变小 → 死循环。
	# 更致命的是：每次 queue_free() 都会把同一个对象再压一次 SceneTree 的删除队列，
	# 死循环每秒压几百万次 → 进程内存狂涨，几秒内卡死/崩溃。
	# （用户报的"第 6 条击杀后内存一直飙升到卡死"就是这个。）
	while kill_feed.get_child_count() > 5:
		var last := kill_feed.get_child(kill_feed.get_child_count() - 1)
		kill_feed.remove_child(last)
		last.queue_free()
	# 4 秒后淡出移除
	var tw := row.create_tween()
	tw.tween_interval(3.6)
	tw.tween_property(row, "modulate:a", 0.0, 0.4)
	tw.tween_callback(row.queue_free)


var _kill_notice_tween: Tween
func _show_kill_notice(text: String, head: bool) -> void:
	if kill_notice == null: return
	# 击杀/爆头图标 + 对应音效
	var icon_path := "res://models/icons/headshot.png" if head else "res://models/icons/kill.png"
	kill_notice.texture = load(icon_path)
	kill_notice.pivot_offset = Vector2.ZERO
	kill_notice.scale = Vector2(1.0, 1.0)
	kill_notice.visible = true
	kill_notice.modulate = Color(1, 1, 1, 1)
	if _kill_notice_tween:
		_kill_notice_tween.kill()
	_kill_notice_tween = kill_notice.create_tween()
	# 弹出效果：先放大到1.15再回落到1.0
	kill_notice.scale = Vector2(0.5, 0.5)
	_kill_notice_tween.tween_property(kill_notice, "scale", Vector2(1.15, 1.15), 0.12)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_kill_notice_tween.tween_property(kill_notice, "scale", Vector2(1.0, 1.0), 0.08)
	_kill_notice_tween.tween_interval(1.0)
	_kill_notice_tween.tween_property(kill_notice, "modulate:a", 0.0, 0.4)
	_kill_notice_tween.tween_callback(func(): kill_notice.visible = false)
	# 音效
	if _snd_kill:
		_snd_kill.pitch_scale = randf_range(0.95, 1.05)
		_snd_kill.stream = SoundFXScript.headshot_snd() if head else SoundFXScript.kill_snd()
		_snd_kill.play()


# ============================================================ 购买菜单
var buy_buttons: Dictionary = {}
var money_label: Label
var buy_tip: Label
var buy_timer_label: Label
var pack_vbox: VBoxContainer

func _build_buy_menu(scene: Node) -> void:
	buy_menu = Control.new()
	buy_menu.position = Vector2(430, 140)
	scene.add_child(buy_menu)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _card_style(18.0, 14.0, 12))
	buy_menu.add_child(panel)
	# 左右两栏：左=购买装备，右=背包（已有武器查看）
	var main_hb := HBoxContainer.new()
	main_hb.add_theme_constant_override("separation", 24)
	panel.add_child(main_hb)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	main_hb.add_child(vb)

	# 购买倒计时（醒目，右上或标题行）
	buy_timer_label = Label.new()
	buy_timer_label.text = ""
	buy_timer_label.add_theme_font_size_override("font_size", 20)
	buy_timer_label.add_theme_color_override("font_color", UITheme.ACCENT)
	buy_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(buy_timer_label)

	money_label = Label.new()
	money_label.text = UIText.BUY_MONEY_INIT
	money_label.add_theme_font_size_override("font_size", 22)
	money_label.add_theme_color_override("font_color", UITheme.MONEY_TEXT)
	money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(money_label)

	buy_tip = Label.new()
	buy_tip.text = UIText.BUY_TIP_IDLE
	buy_tip.add_theme_font_size_override("font_size", 15)
	buy_tip.add_theme_color_override("font_color", UITheme.OK_TEXT)
	vb.add_child(buy_tip)

	# 数字键快捷购买提示
	var hotkey_tip := Label.new()
	hotkey_tip.text = UIText.BUY_HOTKEY_TIP
	hotkey_tip.add_theme_font_size_override("font_size", 14)
	hotkey_tip.add_theme_color_override("font_color", UITheme.HINT_TEXT)
	vb.add_child(hotkey_tip)

	# 条目文字在 ui_text.gd 的 BUY_ITEMS（[显示文字, 武器 id]）
	for item in UIText.BUY_ITEMS:
		_ab_add(vb, str(item[0]), str(item[1]))

	# 右栏：背包（当前已有装备）
	var pack_panel := PanelContainer.new()
	pack_panel.add_theme_stylebox_override("panel", _card_style(14.0, 10.0, 9))
	pack_panel.custom_minimum_size = Vector2(240, 0)
	main_hb.add_child(pack_panel)
	pack_vbox = VBoxContainer.new()
	pack_vbox.add_theme_constant_override("separation", 4)
	pack_panel.add_child(pack_vbox)
	buy_menu.visible = false


func _ab_add(vb: VBoxContainer, text: String, id: String) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 40)
	b.add_theme_font_size_override("font_size", 16)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", UITheme.TEXT)
	b.add_theme_color_override("font_hover_color", UITheme.ACCENT)
	# 与其它菜单同款：深底 + 细边，hover 转暖金
	var bs := StyleBoxFlat.new()
	bs.bg_color = UITheme.BUY_BG
	bs.border_color = UITheme.BUY_EDGE
	bs.set_border_width_all(1)
	bs.set_corner_radius_all(6)
	var bs_hover := bs.duplicate()
	bs_hover.bg_color = UITheme.BUY_HOVER_BG
	bs_hover.border_color = Color(UITheme.ACCENT_DIM.r, UITheme.ACCENT_DIM.g, UITheme.ACCENT_DIM.b, 0.9)
	var bs_pressed := bs.duplicate()
	bs_pressed.bg_color = UITheme.BUY_DOWN_BG
	b.add_theme_stylebox_override("normal", bs)
	b.add_theme_stylebox_override("hover", bs_hover)
	b.add_theme_stylebox_override("pressed", bs_pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): _on_buy_press(id))
	vb.add_child(b)
	buy_buttons[id] = b


func _refresh_buy_menu() -> void:
	if player == null or buy_buttons.is_empty(): return
	money_label.text = UIText.BUY_MONEY % player.money
	buy_tip.text = UIText.BUY_FOOTER
	if buy_timer_label != null:
		var left := int(maxf(timer, 0.0))
		if state == STATE.BUY:
			buy_timer_label.text = UIText.BUY_TIME_LEFT % left
		else:
			buy_timer_label.text = UIText.BUY_TIME_UP
	# 开局 10 秒后（进入对局）购买不可用，左栏全部置灰
	var can_buy := state == STATE.BUY
	for id: String in buy_buttons:
		var b: Button = buy_buttons[id]
		# 武器按钮文本中的价格随配置文件实时更新
		if WeaponDatabase.weapons().has(id):
			b.text = _weapon_buy_text(id)
		var locked := false
		if not can_buy:
			locked = true
		elif id == "AK47": locked = player.team != "T"
		elif id == "M4A1": locked = player.team != "CT"
		elif id == "KIT": locked = player.team != "CT"
		# 已有武器不能重复购买（含主武器已满两把）
		if not locked and player.has_weapon_id(id):
			locked = true
		if not locked:
			var spec: Dictionary = WeaponDatabase.weapons().get(id, {})
			if not spec.is_empty() and int(spec.get("slot", 0)) == 1 and player.primaries_full():
				locked = true
		# 拆弹器 / 防弹衣已持有
		if not locked and id == "KIT" and player.has_defuser:
			locked = true
		if not locked and id == "ARMOR" and player.has_helmet:
			locked = true
		var price := 0
		var wspec: Dictionary = WeaponDatabase.weapons().get(id, {})
		if not wspec.is_empty():
			price = _effective_weapon_price(id, int(wspec.get("price", 0)))
		else:
			match id:
				"ARMOR": price = 1000
				"KIT": price = 200
		if not locked and price > player.money:
			locked = true
		b.disabled = locked
		b.modulate = UITheme.LOCKED_MODULATE if locked else Color(1, 1, 1)
	_refresh_pack_panel()


# 武器购买按钮文本（价格取配置文件覆盖后的值，实时更新）
func _weapon_buy_text(id: String) -> String:
	var spec: Dictionary = WeaponDatabase.weapons().get(id, {})
	if spec.is_empty(): return id
	var idx := {1: "1", 2: "2", 3: "3", 4: "4", 5: "5"}
	var idxmap := {"AK47": "1", "M4A1": "2", "Deagle": "3", "MP5": "4", "AWP": "5"}
	var price := _effective_weapon_price(id, int(spec.get("price", 0)))
	var suffix := ""
	if spec.get("team") == "T": suffix = " T"
	elif spec.get("team") == "CT": suffix = " CT"
	return "[%s] %s ($%d)%s" % [idxmap.get(id, idx.get(int(spec.get("slot", 0)), "?")), spec.get("name", id), price, suffix]


# 武器价格：优先取 config.toml [weapons] 覆盖值
func _effective_weapon_price(id: String, base: int) -> int:
	if ConfigManager.instance != null:
		var v: Variant = ConfigManager.instance.get_weapon_override(id, "price", null)
		if v != null:
			return int(v)
	return base


# 右栏背包：列出当前持有的所有装备与弹药
func _refresh_pack_panel() -> void:
	if pack_vbox == null or player == null: return
	for c in pack_vbox.get_children():
		c.queue_free()
	var head := Label.new()
	head.text = UIText.BUY_PACK_TITLE
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color", UITheme.ACCENT)
	pack_vbox.add_child(head)
	var slot_names: Dictionary = UIText.BUY_SLOT_NAMES
	for s in [1, 4, 2, 3]:
		var w: Dictionary = player.weapons.get(s, {})
		var nm: String = slot_names[s]
		if w.is_empty():
			_pack_line(UIText.BUY_SLOT_EMPTY % nm, UITheme.TEXT_MUTED)
		else:
			var wid: String = w.get("id", "?")
			var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
			var wname: String = spec.get("name", wid)
			var is_active: bool = (s == player.active_slot)
			_pack_line("%s：%s  %d/%d" % [nm, wname, w.get("mag", 0), w.get("reserve", 0)],
				UITheme.ACCENT if is_active else UITheme.TEXT)
	_pack_line(UIText.BUY_ARMOR % [UIText.BUY_YES if player.armor > 0.0 else UIText.BUY_NO, int(player.armor)],
		UITheme.OK_TEXT)
	_pack_line(UIText.BUY_DEFUSER % (UIText.BUY_YES if player.has_defuser else UIText.BUY_NO),
		UITheme.OK_TEXT)
	var hint := Label.new()
	hint.text = UIText.BUY_SWITCH_HINT
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	pack_vbox.add_child(hint)


func _pack_line(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", color)
	pack_vbox.add_child(l)


func _on_buy_press(id: String) -> void:
	if player == null: return
	if buy_tip == null: return
	var SND_BUY := preload("res://sounds/shoot.wav")  # 使用现有音效作为购买提示
	match id:
		"ARMOR":
			if player.buy_armor(true):
				buy_tip.text = UIText.BUY_OK_ARMOR
				_play_buy_sound()
			else:
				buy_tip.text = UIText.BUY_FAIL_HOLD
		"KIT":
			if player.buy_kit():
				buy_tip.text = UIText.BUY_OK_DEFUSER
				_play_buy_sound()
			else:
				buy_tip.text = UIText.BUY_FAIL_HOLD
		"AMMO":
			if player.money >= 200:
				player.money -= 200
				var wep: Dictionary = player.weapons.get(player.active_slot, {})
				if not wep.is_empty():
					var wid: String = wep.get("id", "")
					var spec: Dictionary = WeaponDatabase.weapons().get(wid, {})
					if not spec.is_empty():
						wep["reserve"] = wep.get("reserve", 0) + spec.get("mag", 30)
						buy_tip.text = UIText.BUY_OK_AMMO
						_play_buy_sound()
			else:
				buy_tip.text = UIText.BUY_FAIL_MONEY
		_:
			if player.buy(id):
				buy_tip.text = UIText.BUY_OK_ITEM + id
				_play_buy_sound()
			else:
				buy_tip.text = UIText.BUY_FAIL_LIMIT
	_refresh_buy_menu()


var _buy_snd_player: AudioStreamPlayer
func _play_buy_sound() -> void:
	if _buy_snd_player == null:
		_buy_snd_player = AudioStreamPlayer.new()
		_buy_snd_player.stream = SoundFXScript.buy_snd()
		_buy_snd_player.volume_db = linear_to_db(0.6)
		_buy_snd_player.max_polyphony = 4
		add_child(_buy_snd_player)
	_buy_snd_player.pitch_scale = randf_range(0.9, 1.1)
	_buy_snd_player.play()


func open_buy(p: CSPlayer) -> void:
	if state == STATE.BUY or state == STATE.LIVE:
		buy_menu_visible = true
		buy_menu.visible = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_refresh_buy_menu()


func on_c4_dropped(p: CSPlayer) -> void:
	pass


# ============================================================ 开始菜单
# 程序化生成做旧石板纹理（噪点 + 裂纹），用于复古面板
func _make_stone_texture() -> Texture2D:
	var size := Vector2i(256, 256)
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 20240817
	noise.frequency = 0.03
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	var noise2 := FastNoiseLite.new()
	noise2.seed = 777
	noise2.frequency = 0.12
	noise2.noise_type = FastNoiseLite.TYPE_SIMPLEX
	for y in size.y:
		for x in size.x:
			var n := noise.get_noise_2d(x, y) * 0.5 + 0.5
			var m := noise2.get_noise_2d(x, y) * 0.5 + 0.5
			var base := 0.16 + 0.05 * n
			var dark := 0.03 * (1.0 - m) * (0.5 + 0.5 * n)
			var v := clampf(base - dark, 0.04, 0.30)
			img.set_pixel(x, y, Color(v, v * 0.95, v * 0.8, 1.0))
	return ImageTexture.create_from_image(img)


# ============================================================ 开始菜单（已取消）
# 2026-09-30：用户要求去掉独立开始菜单 —— 打开游戏直接进局域网大厅（界面1），
# 人机难度选择下放到界面2（房间界面）。原 _build_start_menu / _build_start_content /
# _menu_title_layer / _menu_key_column / _letter_spaced 已删除。


# 一层线性渐变遮罩（用于压暗背景，保证文字可读）
func _menu_scrim(from: Vector2, to: Vector2, c0: Color, c1: Color) -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([c0, c1])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = from
	gt.fill_to = to
	gt.width = 128
	gt.height = 128
	var tr := TextureRect.new()
	tr.texture = gt
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


# 主按钮（金色 CTA）样式
func _cta_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = UITheme.CTA_EDGE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(7)
	sb.shadow_color = UITheme.CTA_GLOW
	sb.shadow_size = 16
	sb.content_margin_left = 30.0
	sb.content_margin_right = 30.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


# 难度分段按钮样式（on = 当前选中）
func _seg_style(on: bool, hover := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if on:
		sb.bg_color = UITheme.ACCENT_HOVER if hover else UITheme.SEG_ON
		sb.border_color = UITheme.SEG_EDGE
	else:
		sb.bg_color = UITheme.TRACK_HOVER if hover else Color(0, 0, 0, 0)
		sb.border_color = Color(0, 0, 0, 0)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(4.0)
	return sb


# ============================================================ 局域网大厅（界面1）
#
# 本作就是**局域网对战**（不做单机/局域网二选一），而且**没有独立开始菜单**：
#   打开游戏 → 界面1（房间列表 + 帮助栏）→ 界面2（成员 / 难度 / 选图）→ 开战
# 房间列表靠 UDP 广播自动刷新，不用手填 IP。
#
# 界面1 布局：上方游戏名；左边房间列表（两栏：房间名 | 进入）；右边帮助栏；
#             列表下面「创建房间」。见 _build_lan_menu。
var lan_menu: Control
var lan_room_list: VBoxContainer
var lan_status: Label
var lan_name_edit: LineEdit
var _lan_refresh_cool := 0.0
var _lan_room_sig := ""      # 房间列表的"签名"，只有变化时才重建 UI

# 界面2 用的控件（房间界面 = 成员名册 + 地图缩略图 + 选图）。
# 变量名沿用 map_select_menu / _open_map_select：自检与截图里几十处都依赖它们，
# 改名的风险远大于收益。
var room_members_box: VBoxContainer    # 成员名册容器（动态重建）
var room_members_hint: Label           # 名册上方的"在线 N 人"说明
var room_thumb: Control                # 地图缩略图
var room_status: Label                 # 房间状态栏
var room_name_label: Label             # 右上角房间名
var _room_sig := ""                    # 房间界面的"签名"，只有变化时才重建 UI
# 调试用：截图时塞几个假成员，好把「踢」按钮也拍进去（同 lan.debug_add_room）
var debug_fake_members: Array = []


func _open_lan_lobby() -> void:
	map_select_menu.visible = false
	lan_menu.visible = true
	_refresh_lan_rooms(true)       # 强制刷一次


func _build_lan_menu(scene: Node) -> void:
	lan_menu = Control.new()
	lan_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	lan_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	lan_menu.visible = false
	scene.add_child(lan_menu)
	_menu_backdrop(lan_menu, true)

	var margin := _menu_margin(lan_menu)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	margin.add_child(vb)

	# ---------------- 上方：游戏名 ----------------
	# 这是打开游戏看到的第一个界面，没有"上一级"可返回（开始菜单已取消）
	vb.add_child(_menu_brand_header(44))

	# ---------------- 主体：左 房间列表 / 右 帮助栏 ----------------
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 22)
	# 固定高度 + 竖直居中：面板不铺满整屏（撑太高会显得空）
	body.custom_minimum_size = Vector2(0, 440)
	body.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.add_child(body)

	# ==== 左：房间列表（两栏：左房间名 / 右进入按钮） ====
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.7
	body.add_child(left)

	var list_head := HBoxContainer.new()
	list_head.add_theme_constant_override("separation", 10)
	left.add_child(list_head)
	var lh := Label.new()
	lh.text = UIText.LOBBY_LIST_TITLE
	lh.add_theme_font_size_override("font_size", 22)
	lh.add_theme_color_override("font_color", UITheme.ACCENT)
	list_head.add_child(lh)
	var lhint := Label.new()
	lhint.text = UIText.LOBBY_LIST_HINT
	lhint.add_theme_font_size_override("font_size", 14)
	lhint.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	lhint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lhint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	lhint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_head.add_child(lhint)

	var list_wrap := PanelContainer.new()
	list_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_wrap.custom_minimum_size = Vector2(0, 300)
	list_wrap.add_theme_stylebox_override("panel", _card_style(14.0, 12.0, 12))
	left.add_child(list_wrap)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_wrap.add_child(scroll)
	lan_room_list = VBoxContainer.new()
	lan_room_list.add_theme_constant_override("separation", 8)
	lan_room_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(lan_room_list)

	# ---- 列表下面：创建房间 ----
	var create_row := HBoxContainer.new()
	create_row.add_theme_constant_override("separation", 12)
	left.add_child(create_row)
	var name_lab := Label.new()
	name_lab.text = UIText.LOBBY_NICK_LABEL
	name_lab.add_theme_font_size_override("font_size", 17)
	name_lab.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	create_row.add_child(name_lab)
	lan_name_edit = LineEdit.new()
	lan_name_edit.text = player_nick       # 玩家 + 3 位随机数字，进游戏就是这个昵称
	lan_name_edit.custom_minimum_size = Vector2(0, 48)
	lan_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_name_edit.max_length = 6
	lan_name_edit.add_theme_font_size_override("font_size", 17)
	lan_name_edit.add_theme_color_override("font_color", UITheme.TEXT)
	lan_name_edit.add_theme_color_override("caret_color", UITheme.ACCENT)
	lan_name_edit.add_theme_stylebox_override("normal", _card_style(14.0, 8.0, 8))
	lan_name_edit.add_theme_stylebox_override("focus", _card_style(14.0, 8.0, 8))
	create_row.add_child(lan_name_edit)
	var btn_create := _btn_primary(UIText.BTN_CREATE_ROOM, 170.0, 48.0, 18)
	btn_create.pressed.connect(_on_create_room)
	create_row.add_child(btn_create)

	# ==== 右：帮助栏 ====
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(430, 0)
	right.add_theme_constant_override("separation", 10)
	body.add_child(right)
	var help_wrap := PanelContainer.new()
	help_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	help_wrap.add_theme_stylebox_override("panel", _card_style(20.0, 18.0, 12))
	right.add_child(help_wrap)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 9)
	help_wrap.add_child(hv)
	hv.add_child(_menu_heading(UIText.HELP_LAN_TITLE, 19))
	hv.add_child(_help_para(UIText.HELP_LAN_BODY))
	hv.add_child(_menu_rule(false, 120.0))
	hv.add_child(_menu_heading(UIText.HELP_KEY_TITLE, 19))
	# 按键 | 说明 | 按键 | 说明 —— 按键和说明分列，说明文字开头才能对齐
	hv.add_child(_help_key_grid())

	# ---------------- 底部状态栏 ----------------
	lan_status = Label.new()
	lan_status.add_theme_font_size_override("font_size", 15)
	lan_status.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	lan_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(lan_status)

	# ---------------- 特别鸣谢（右下角）----------------
	# 做成 lan_menu 的子节点：跟着大厅一起隐藏，不用手动管开关。
	var credit_row := HBoxContainer.new()
	credit_row.alignment = BoxContainer.ALIGNMENT_END
	vb.add_child(credit_row)
	var btn_credits := _btn_ghost(UIText.BTN_CREDITS, 150.0, 36.0, 15)
	btn_credits.pressed.connect(_open_credits)
	credit_row.add_child(btn_credits)

	_build_credits_menu(lan_menu)


# ============================================================ 特别鸣谢（界面1 右下角按钮 → 大窗口）
#
# 正文直接读 `res://特别鸣谢.txt`（素材授权信息）。txt 不参与资源导入，
# 用 FileAccess 读原始文本；读不到也不会白屏，会显示一句兜底提示。
const CREDITS_FILE := "res://特别鸣谢.txt"
var credits_menu: Control


func _open_credits() -> void:
	if credits_menu != null:
		credits_menu.visible = true


func _close_credits() -> void:
	if credits_menu != null:
		credits_menu.visible = false


func _build_credits_menu(parent: Control) -> void:
	credits_menu = Control.new()
	credits_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	credits_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	credits_menu.visible = false
	parent.add_child(credits_menu)

	# 点面板外的空白也能关：底下垫一层透明按钮。
	# 上面的 CenterContainer 必须 MOUSE_FILTER_IGNORE，点击才透得下来。
	var catcher := Button.new()
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.flat = true
	catcher.focus_mode = Control.FOCUS_NONE
	catcher.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	catcher.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	catcher.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	catcher.pressed.connect(_close_credits)
	credits_menu.add_child(catcher)

	_menu_backdrop(credits_menu, false, 0.78)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	credits_menu.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(980, 660)
	panel.add_theme_stylebox_override("panel", _card_style(44.0, 30.0, 16))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var title := Label.new()
	title.text = UIText.CREDITS_TITLE
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", UITheme.ACCENT)
	title.add_theme_color_override("font_outline_color", UITheme.OUTLINE)
	title.add_theme_constant_override("outline_size", 8)
	vb.add_child(title)
	vb.add_child(_menu_rule(true, 170.0))

	# 正文区：可滚动（素材条目里的 URL 很长，窗口再大也塞不下）
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	for blk in _credits_blocks():
		body.add_child(blk)

	var btn_close := _btn_primary(UIText.BTN_CLOSE, 240.0, 52.0, 20)
	btn_close.pressed.connect(_close_credits)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(btn_close)
	vb.add_child(row)


## 把 特别鸣谢.txt 解析成一串控件：
## 【...】开头的行做成小标题，其余做成可换行的正文，空行跳过。
## 读不到文件就返回一句兜底提示 —— 别让大窗口开出来是空白的。
func _credits_blocks() -> Array:
	var out: Array = []
	var text := ""
	var f := FileAccess.open(CREDITS_FILE, FileAccess.READ)
	if f != null:
		text = f.get_as_text()
		f.close()
	if text.strip_edges().is_empty():
		var miss := Label.new()
		miss.text = UIText.CREDITS_MISSING % CREDITS_FILE.trim_prefix("res://")
		miss.add_theme_font_size_override("font_size", 16)
		miss.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		miss.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		miss.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		miss.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		out.append(miss)
		return out
	if text.contains(char(0xFFFD)):
		# Godot 的 FileAccess 只按 UTF-8 解码。中文 Windows 记事本默认存 GBK，
		# 读出来全是 U+FFFD —— 不给提示的话用户只会看到一堆问号，不知道为什么。
		var warn := Label.new()
		warn.text = UIText.CREDITS_BAD_ENCODING
		warn.add_theme_font_size_override("font_size", 16)
		warn.add_theme_constant_override("line_spacing", 5)
		warn.add_theme_color_override("font_color", UITheme.ACCENT)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		out.append(warn)
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("【"):
			out.append(_menu_heading(line, 20))
			continue
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_constant_override("line_spacing", 5)
		l.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		out.append(l)
	return out


# 菜单统一外边距（界面1 / 界面2 共用，保证两页切换时标题位置不跳）
func _menu_margin(parent: Control) -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", 56)
	m.add_theme_constant_override("margin_right", 56)
	m.add_theme_constant_override("margin_top", 30)
	m.add_theme_constant_override("margin_bottom", 34)
	parent.add_child(m)
	return m


# 菜单顶部"品牌区"：游戏名（中文大字）+ 英文小字 + 金色细线
func _menu_brand_header(title_size := 44) -> VBoxContainer:
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	head.add_child(_menu_title(UIText.TITLE, title_size))
	var en := Label.new()
	en.text = UIText.TITLE_EN
	en.add_theme_font_size_override("font_size", 15)
	en.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	en.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	en.add_theme_color_override("font_outline_color", UITheme.OUTLINE_SOFT)
	en.add_theme_constant_override("outline_size", 6)
	head.add_child(en)
	head.add_child(_menu_rule(true, 150.0))
	return head


# 帮助栏正文段落（自动换行、行距放宽一点，别挤成一坨）
func _help_para(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_constant_override("line_spacing", 6)
	l.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## 操作帮助表：4 列网格（按键 | 说明 | 按键 | 说明）。
## ★ 按键和说明必须分列 ★ —— 以前是 "WASD 移动" 这种把键和说明拼在一个字符串里，
##   键名长短不一（WASD / Shift / Tab），说明文字的开头就参差不齐。
func _help_key_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 6)
	var rows := maxi(UIText.HELP_KEY_LEFT.size(), UIText.HELP_KEY_RIGHT.size())
	for i in rows:
		_help_key_row(g, UIText.HELP_KEY_LEFT, i)
		_help_key_row(g, UIText.HELP_KEY_RIGHT, i)
	return g


# 一行里的一组「按键 + 说明」；该列没有这一条时补两个空格子，保持列位置不变
func _help_key_row(g: GridContainer, items: Array, i: int) -> void:
	if i >= items.size():
		g.add_child(_help_key_cell(""))
		g.add_child(_help_key_cell(""))
		return
	var it = items[i]
	g.add_child(_help_key_cell(str(it[0])))
	g.add_child(_help_key_cell(str(it[1])))


func _help_key_cell(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# 给 Label / Button 的文字加一层深描边 —— 主视觉右半是亮区，
# 压在亮背景上的文字不加描边基本看不清。
func _text_outline(c: Control, size := 6) -> void:
	c.add_theme_color_override("font_outline_color", UITheme.OUTLINE_HUD)
	c.add_theme_constant_override("outline_size", size)


## 重建房间列表。只在"房间集合变了"或菜单刚打开时重建，
## 否则每秒都重建一遍 UI，按钮会跟着闪。
##
## ★ force 参数是必须的 ★
## 房间清空时 sig 恰好是空串 ""。如果"强制刷新"也用 "" 当哨兵值（先 `_lan_room_sig = ""`
## 再调本函数），两边都是 "" → 判定"没变化" → 重建被跳过 → 点了「解散」房间还留在列表里
## （用户报的"解散按钮没作用"）。所以强制刷新必须走 force 分支，不能靠改哨兵值。
func _refresh_lan_rooms(force := false) -> void:
	if lan_room_list == null:
		return
	var rooms: Array = lan.rooms() if lan != null else []
	var sig := ""
	for r in rooms:
		sig += "%s|%s|%d|%s;" % [r["ip"], r["name"], r["players"], str(r.get("mine", false))]
	if force or sig != _lan_room_sig:
		_lan_room_sig = sig
		for c in lan_room_list.get_children():
			lan_room_list.remove_child(c)
			c.queue_free()
		if rooms.is_empty():
			var empty := Label.new()
			empty.text = UIText.LOBBY_EMPTY
			empty.add_theme_font_size_override("font_size", 16)
			empty.add_theme_color_override("font_color", UITheme.TEXT_DIM)
			empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
			lan_room_list.add_child(empty)
		else:
			for r in rooms:
				lan_room_list.add_child(_build_room_row(r))
	# 状态栏
	if lan_status != null:
		var st := UIText.LOBBY_STATUS_IDLE % lan.discovery_ports[0]
		if lan.hosting:
			st = UIText.LOBBY_STATUS_HOSTING % lan.room_name
		if lan.is_connected_to_host():
			st = UIText.LOBBY_STATUS_CLIENT
		if lan.last_error != "":
			st += " · " + lan.last_error
		lan_status.text = st


## 大厅列表里当前有几行房间（空列表时是一句提示 Label，不算行）
func _count_room_rows() -> int:
	var n := 0
	if lan_room_list == null:
		return 0
	for c in lan_room_list.get_children():
		if c is PanelContainer:
			n += 1
	return n


## 一行房间：**两栏** —— 左边房间名（下面一行小字放人数/主机 IP），右边按钮。
## 自己的房间按钮是「返回房间」+「解散」；别人的房间是「加入」。
func _build_room_row(r: Dictionary) -> Control:
	var mine := bool(r.get("mine", false))
	var row := PanelContainer.new()
	var rsb := _card_style(14.0, 8.0, 8)
	if mine:
		# 自己的房间加一圈金边，一眼能认出来
		rsb.border_color = UITheme.ACCENT_DIM
		rsb.set_border_width_all(1)
	row.add_theme_stylebox_override("panel", rsb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	row.add_child(hb)

	# 左栏：房间名 + 次要信息
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(left)
	var nm := Label.new()
	nm.text = (UIText.LOBBY_MINE_SUFFIX % str(r["name"])) if mine else str(r["name"])
	nm.add_theme_font_size_override("font_size", 19)
	nm.add_theme_color_override("font_color", UITheme.ACCENT if mine else UITheme.TEXT)
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	left.add_child(nm)
	var meta := Label.new()
	meta.text = UIText.LOBBY_ROW_META % [int(r["players"]), int(r["max"]),
			UIText.LOBBY_ROW_META_MINE if mine else str(r["ip"])]
	meta.add_theme_font_size_override("font_size", 14)
	meta.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	left.add_child(meta)

	# 右栏：按钮
	if mine:
		var back_btn := _btn_primary(UIText.BTN_BACK_ROOM, 132.0, 42.0, 17)
		back_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		back_btn.pressed.connect(_open_map_select)
		hb.add_child(back_btn)
		var close_btn := _btn_ghost(UIText.BTN_DISMISS, 78.0, 42.0, 16)
		close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		close_btn.pressed.connect(_on_dismiss_room)
		hb.add_child(close_btn)
	else:
		var join_btn := _btn_primary(UIText.BTN_JOIN, 112.0, 42.0, 17)
		join_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		join_btn.pressed.connect(_on_join_room.bind(String(r["ip"])))
		hb.add_child(join_btn)
	return row


## 解散自己开的房间（停播信标 + 关掉 ENet 服务器）
func _on_dismiss_room() -> void:
	if lan == null:
		return
	lan.stop_host()
	_refresh_lan_rooms(true)


## 默认昵称 = 玩家 + 3 位随机数字（同机双开 / 多台机器同时进来不会重名）
func _random_nick() -> String:
	return UIText.LOBBY_NICK_FMT % randi_range(100, 999)


## 从大厅输入框读昵称（创建 / 加入房间时都先读一次）
func _read_nick() -> void:
	if lan_name_edit == null:
		return
	var nm := lan_name_edit.text.strip_edges()
	player_nick = nm if nm != "" else _random_nick()


func _on_create_room() -> void:
	_read_nick()
	# 房间名直接用昵称拼：别人在大厅看到的就是「某某的房间」
	if not lan.start_host(UIText.ROOM_NAME_FMT % player_nick):
		_show_toast(lan.last_error)
		return
	# 建好房间直接进「房间界面」（界面2）：房主选图 → 进入游戏；机器人会补满人数
	_open_map_select()


func _on_join_room(ip: String) -> void:
	_read_nick()
	if not lan.join(ip):
		_show_toast(lan.last_error)
		return
	# 点了「加入」就进「房间界面」（界面2），连接状态在那里显示
	_open_map_select()


# ============================================================ 房间界面（界面2）
#
# 界面2 = 「点已有房间的进入 / 自己创建房间」之后进入的页面：
#   上方  游戏名（右上角带房间名）
#   左边  房间成员名册（CT / T 各 8 位：真人优先占位，其余显示「机器人」）+ 人机难度
#   右边  地图缩略图（俯视示意图）+ 地图下拉框
#   下面  「进入游戏」/「返回上一步」
# 左右宽度按 1.6 : 1 分配 —— 成员名册是这一页的重点，地图框不用那么大。
#
# 变量名沿用 map_select_menu / _open_map_select()：自检与截图里几十处依赖它们，
# 改名的风险远大于收益。
func _build_map_select_menu(scene: Node) -> void:
	map_select_menu = Control.new()
	map_select_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_select_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	map_select_menu.visible = false
	scene.add_child(map_select_menu)

	# 与开始菜单同一张主视觉 + 同一套渐变遮罩，切换页面时背景不跳
	_menu_backdrop(map_select_menu, true)

	var margin := _menu_margin(map_select_menu)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	margin.add_child(vb)

	# ---------------- 上方：游戏名（居中） ----------------
	vb.add_child(_menu_brand_header(44))

	# 房间名**单独一行、左对齐、紧贴下面的成员面板**：
	# 不跟游戏名挤同一行抢位置，也不离成员列表太远。
	room_name_label = Label.new()
	room_name_label.add_theme_font_size_override("font_size", 28)
	room_name_label.add_theme_color_override("font_color", UITheme.ACCENT)
	room_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	room_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	room_name_label.custom_minimum_size = Vector2(0, 40)
	_text_outline(room_name_label, 9)      # 压在亮背景上也要看得清
	vb.add_child(room_name_label)

	# ---------------- 主体 ----------------
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 22)
	# 固定高度 + 竖直居中：面板不铺满整屏（撑太高会显得空）
	body.custom_minimum_size = Vector2(0, 440)
	body.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.add_child(body)

	# ==== 左：房间成员（比右边地图框大，成员列表是这一页的重点） ====
	var mem_wrap := PanelContainer.new()
	mem_wrap.custom_minimum_size = Vector2(800, 0)
	mem_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mem_wrap.size_flags_stretch_ratio = 1.6
	# 撑满 body 的高度：这样「人机难度」能钉在左栏底部
	mem_wrap.add_theme_stylebox_override("panel", _card_style(20.0, 16.0, 12))
	body.add_child(mem_wrap)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 8)
	mem_wrap.add_child(mv)
	mv.add_child(_menu_heading(UIText.ROOM_MEMBERS_TITLE, 19))
	room_members_hint = Label.new()
	room_members_hint.add_theme_font_size_override("font_size", 14)
	room_members_hint.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	room_members_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mv.add_child(room_members_hint)
	room_members_box = VBoxContainer.new()
	# 不撑满：高度跟内容走。否则人少的时候（1~2 行）行会被拉成一条条大空条。
	mv.add_child(room_members_box)

	# 弹性空档：把「人机难度」压到左栏底部（用户要求固定在下方）
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mv.add_child(gap)

	# ---- 人机难度（原来挂在开始菜单上；开始菜单取消后下放到这里）----
	mv.add_child(_menu_heading(UIText.ROOM_DIFF_TITLE, 19))
	var diff_row := HBoxContainer.new()
	diff_row.add_theme_constant_override("separation", 10)
	mv.add_child(diff_row)
	var track := PanelContainer.new()
	track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = UITheme.TRACK_BG
	tsb.border_color = UITheme.TRACK_EDGE
	tsb.set_border_width_all(1)
	tsb.set_corner_radius_all(7)
	tsb.set_content_margin_all(3.0)
	track.add_theme_stylebox_override("panel", tsb)
	diff_row.add_child(track)
	var segs := HBoxContainer.new()
	segs.add_theme_constant_override("separation", 3)
	track.add_child(segs)
	for i in UIText.DIFFICULTY_NAMES.size():
		var b := Button.new()
		b.text = UIText.DIFFICULTY_NAMES[i]
		b.custom_minimum_size = Vector2(78, 36)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 16)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_set_difficulty.bind(i))
		segs.add_child(b)
		diff_buttons.push_back(b)
	_set_difficulty_ui.call_deferred()
	var diff_hint := Label.new()
	diff_hint.text = UIText.ROOM_DIFF_HINT
	diff_hint.add_theme_font_size_override("font_size", 13)
	diff_hint.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	mv.add_child(diff_hint)

	# ==== 右：地图缩略图 + 选图（比左边成员框窄） ====
	var map_wrap := PanelContainer.new()
	map_wrap.custom_minimum_size = Vector2(360, 0)
	map_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_wrap.size_flags_stretch_ratio = 1.0
	map_wrap.add_theme_stylebox_override("panel", _card_style(18.0, 16.0, 12))
	body.add_child(map_wrap)
	var mpv := VBoxContainer.new()
	mpv.add_theme_constant_override("separation", 8)
	map_wrap.add_child(mpv)

	var mh := HBoxContainer.new()
	mh.add_theme_constant_override("separation", 10)
	mpv.add_child(mh)
	mh.add_child(_menu_heading(UIText.ROOM_MAP_TITLE, 19))
	map_desc_label = Label.new()
	map_desc_label.add_theme_font_size_override("font_size", 14)
	map_desc_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	map_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	map_desc_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	map_desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_desc_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	mh.add_child(map_desc_label)

	# 缩略图：直接读主场景登记好的寻路障碍画俯视图，换地图自动跟着变
	var thumb_frame := PanelContainer.new()
	thumb_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	thumb_frame.custom_minimum_size = Vector2(0, 260)
	thumb_frame.add_theme_stylebox_override("panel", _card_style(10.0, 10.0, 10))
	mpv.add_child(thumb_frame)
	room_thumb = load("res://scripts/map_thumb.gd").new()
	room_thumb.provider = _map_thumb_data
	room_thumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_thumb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	thumb_frame.add_child(room_thumb)

	var legend := Label.new()
	legend.text = UIText.MAP_LEGEND
	legend.add_theme_font_size_override("font_size", 13)
	legend.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mpv.add_child(legend)

	# 地图名下拉框（以后加地图只要往 MAP_INFO 里加一条，这里自动多一个选项）
	mpv.add_child(_build_map_picker())

	# ---------------- 下面：状态 + 进入游戏 / 返回上一步 ----------------
	room_status = Label.new()
	room_status.add_theme_font_size_override("font_size", 15)
	room_status.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	room_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(room_status)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 16)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(btns)
	var btn_start := _btn_primary(UIText.BTN_START, 300.0, 54.0, 20)
	btn_start.pressed.connect(_on_room_enter)
	btns.add_child(btn_start)
	var btn_back := _btn_ghost(UIText.BTN_BACK_PREV, 220.0, 54.0, 17)
	btn_back.pressed.connect(_close_room_screen)
	btns.add_child(btn_back)

	_refresh_room_screen()


# 地图下拉框（OptionButton）。样式做成和卡片一致的深色 + 金边，
# 展开的弹层也要单独上色，否则默认是浅灰的、和整体风格打架。
func _build_map_picker() -> OptionButton:
	map_pick = OptionButton.new()
	map_pick.custom_minimum_size = Vector2(0, 46)
	map_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_pick.add_theme_font_size_override("font_size", 17)
	map_pick.add_theme_color_override("font_color", UITheme.TEXT)
	map_pick.add_theme_color_override("font_hover_color", UITheme.ACCENT)
	map_pick.add_theme_color_override("font_pressed_color", UITheme.ACCENT)
	map_pick.add_theme_color_override("font_focus_color", UITheme.TEXT)
	map_pick.add_theme_stylebox_override("normal", _card_style(16.0, 8.0, 8))
	map_pick.add_theme_stylebox_override("hover", _card_style(16.0, 8.0, 8))
	map_pick.add_theme_stylebox_override("pressed", _card_style(16.0, 8.0, 8))
	map_pick.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var pop := map_pick.get_popup()
	pop.add_theme_font_size_override("font_size", 16)
	pop.add_theme_color_override("font_color", UITheme.TEXT)
	pop.add_theme_color_override("font_hover_color", UITheme.ON_ACCENT)
	var pbg := StyleBoxFlat.new()
	pbg.bg_color = UITheme.MODAL
	pbg.border_color = UITheme.CARD_EDGE
	pbg.set_border_width_all(1)
	pbg.set_corner_radius_all(6)
	pbg.set_content_margin_all(4.0)
	pop.add_theme_stylebox_override("panel", pbg)
	var phover := StyleBoxFlat.new()
	phover.bg_color = UITheme.CTA
	phover.set_corner_radius_all(4)
	pop.add_theme_stylebox_override("hover", phover)

	map_ids.clear()
	for map_id: String in MAP_INFO:
		map_ids.append(map_id)
		map_pick.add_item(str(MAP_INFO[map_id].get("name", map_id)))
	map_pick.item_selected.connect(_on_map_picked)
	return map_pick


func _on_map_picked(idx: int) -> void:
	if idx >= 0 and idx < map_ids.size():
		_select_map(map_ids[idx])


func _select_map(map_id: String) -> void:
	selected_map = map_id
	_refresh_map_select()


func _refresh_map_select() -> void:
	if map_pick != null:
		var idx := map_ids.find(selected_map)
		if idx >= 0 and map_pick.selected != idx:
			map_pick.selected = idx      # 代码改 selected 不会触发 item_selected，安全
	if map_desc_label != null:
		var info: Dictionary = MAP_INFO.get(selected_map, {})
		var desc := str(info.get("desc", "")).replace("\n", " · ")
		map_desc_label.text = UIText.MAP_PICKED % [info.get("name", selected_map), desc]
	if room_thumb != null:
		room_thumb.refresh()


## 缩略图数据源：每次重绘现取，换地图后自动更新
func _map_thumb_data() -> Dictionary:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for o in nav_obstacles:
		var bb: AABB = o
		mn.x = minf(mn.x, bb.position.x)
		mn.y = minf(mn.y, bb.position.z)
		mx.x = maxf(mx.x, bb.position.x + bb.size.x)
		mx.y = maxf(mx.y, bb.position.z + bb.size.z)
	if mn.x > mx.x:
		# 还没登记障碍（理论上不会发生）→ 用地图常量兜底
		mn = Vector2(-ICE_HALF_X, -ICE_HALF_Z)
		mx = Vector2(ICE_HALF_X, ICE_HALF_Z)
	return {
		"obstacles": nav_obstacles,
		"sites": [
			{"pos": bombsite_a, "label": "A", "color": Color(0.92, 0.36, 0.30)},
			{"pos": bombsite_b, "label": "B", "color": Color(0.34, 0.60, 0.95)},
		],
		"spawns": {"CT": ct_spawns, "T": t_spawns},
		"bounds": Rect2(mn, mx - mn),
	}


# ---------------- 房间界面：进入 / 返回 / 刷新 ----------------

func _on_room_enter() -> void:
	# 进对局后的位置/伤害/拾取/回合同步还没做，客户端先进去会跟房主各跑各的。
	# 所以只有房主能真正开局，客户端在这里等房主。
	if lan != null and lan.is_connected_to_host() and not lan.hosting:
		_show_toast(UIText.TOAST_WAIT_HOST)
		return
	_start_game_with_map(selected_map)


func _close_room_screen() -> void:
	# 返回上一步 = 回大厅列表。
	# ★ 房主**保留房间**（不然刚建的房间一返回就没了，大厅里也看不到自己的房间）；
	#   要关掉房间在大厅那一行点「解散」。客户端则断开连接。
	if lan != null and lan.is_connected_to_host() and not lan.hosting:
		lan.leave()
	map_select_menu.visible = false
	lan_menu.visible = true
	_refresh_lan_rooms(true)


## 刷新房间界面。只在"签名变化"时重建名册，避免每 0.4 秒重建导致闪烁。
func _refresh_room_screen() -> void:
	if map_select_menu == null:
		return
	if lan != null and lan.hosting:
		_ensure_peer_teams()      # 兜底：保证每个对端都有阵营，名册才有列可放
	var members := _room_members()
	# 签名里带上阵营：换队后名册要重建（否则点完没反应）
	var sig := "map=%s;me=%s;" % [selected_map, local_team]
	if lan != null and lan.hosting:
		sig += "host=%s;" % lan.room_name
	for m in members:
		if int(m.get("peer", 0)) > 0:
			sig += "%d:%s:%s," % [int(m["peer"]), str(m["name"]), str(m.get("team", "CT"))]
	if lan != null and lan.is_connected_to_host():
		sig += "client=1;"
	if sig != _room_sig:
		_room_sig = sig
		_rebuild_room_members(members)
		_refresh_map_select()
	if room_status != null:
		room_status.text = _room_status_text()
	if room_name_label != null:
		if lan != null and lan.hosting:
			room_name_label.text = lan.room_name     # 已经是"某某的房间"
		else:
			room_name_label.text = ""


## 房间名册的成员列表（本机 + 已连接的对端 + 调试假成员）。
## 条目：{"name": 昵称, "tag": 身份标签, "peer": 对端 id(自己=0), "self": 是不是自己,
##        "team": "CT"/"T"}
## ★ 名册显示和开局配平都读它 ★ —— 这样"房间里几个电脑，进游戏就几个电脑"永远不会对不上。
func _room_members() -> Array:
	var members: Array = []
	if lan != null and lan.hosting:
		members.append({"name": player_nick, "tag": UIText.TAG_HOST, "peer": 0,
				"self": true, "team": _team_of_peer(0)})
		for id in multiplayer.get_peers():
			members.append({"name": str(_peer_nicks.get(id, UIText.PEER_NAME_FMT % id)),
					"tag": UIText.TAG_PLAYER, "peer": id, "self": false,
					"team": _team_of_peer(id)})
	elif lan != null and lan.is_connected_to_host():
		# 客户端目前只能看到「自己 + 房主」：完整玩家列表要等服务器权威改造
		members.append({"name": player_nick, "tag": UIText.TAG_PLAYER, "peer": 0,
				"self": true, "team": _team_of_peer(0)})
		members.append({"name": UIText.TAG_HOST, "tag": UIText.TAG_HOST, "peer": 1,
				"self": false, "team": _team_of_peer(1)})
	else:
		members.append({"name": player_nick, "tag": UIText.TAG_LOCAL, "peer": 0,
				"self": true, "team": _team_of_peer(0)})
	# 调试用：截图时塞几个假成员，好把「踢」按钮也拍进去（同 lan.debug_add_room）
	for m in debug_fake_members:
		members.append(m)
	return members


## 某个真人当前在哪一队。id<=0 或就是自己 → 直接读 `local_team`
## （本地点的换队立刻生效，不用等房主广播回来）。
func _team_of_peer(id: int) -> String:
	if id <= 0 or id == multiplayer.get_unique_id():
		return local_team
	var t := String(_peer_teams.get(id, "CT"))
	return t if t == "T" else "CT"


## 某队应该有几个电脑 = 目标人数(真人多的那队) - 该队真人。
## ★ 名册和开局配平共用这一个公式 ★，两边永远不会对不上。
## 真人现在可以自己选阵营，所以按成员身上的 `team` 分组数，不再"交替占位"。
func _team_bot_count(team: String, members: Array) -> int:
	var ct_h := 0
	var t_h := 0
	for m in members:
		if str(m.get("team", "CT")) == "T":
			t_h += 1
		else:
			ct_h += 1
	var humans := ct_h if team == "CT" else t_h
	return maxi(0, maxi(ct_h, t_h) - humans)


## 重建成员名册：CT / T 两列。
## **按每个真人自己选的阵营分列**（点队头「加入」选，不再交替占位）。
## 只有两队真人数量不对等时，才给人少的一方补电脑（补齐到人多的那队的人数）。
func _rebuild_room_members(members: Array) -> void:
	if room_members_box == null:
		return
	for c in room_members_box.get_children():
		room_members_box.remove_child(c)
		c.queue_free()

	# 按阵营分组（保持 members 原有先后，房主排最前）
	var by_team := {"CT": [], "T": []}
	for m in members:
		var tm := str(m.get("team", "CT"))
		if not by_team.has(tm):
			tm = "CT"
		by_team[tm].append(m)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	room_members_box.add_child(cols)
	for team in ["CT", "T"]:
		var team_col: Color = team_color(team)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cols.add_child(col)

		# 队头：色条 + 队名 + 人数
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 7)
		col.add_child(head)
		var bar := ColorRect.new()
		bar.color = team_col
		bar.custom_minimum_size = Vector2(3, 18)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_child(bar)
		var th := Label.new()
		th.text = team_full(team)
		th.add_theme_font_size_override("font_size", 16)
		th.add_theme_color_override("font_color", team_col)
		head.add_child(th)
		# ★ 选阵营就靠这个：点哪一队的「加入」就进哪一队（所有人都能点）★
		head.add_child(_btn_join_team(team))
		var cnt := Label.new()
		cnt.add_theme_font_size_override("font_size", 14)
		cnt.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cnt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(cnt)

		var humans: Array = by_team[team]
		var bots_n := _team_bot_count(team, members)   # 与开局配平用同一个公式
		for slot in range(humans.size() + bots_n):
			# slot < 真人数 → 真人行；否则是配平补上的电脑行（空字典）
			var m: Dictionary = humans[slot] if slot < humans.size() else {}
			col.add_child(_build_member_row(m, team_col))
		cnt.text = UIText.ROOM_TEAM_COUNT % [humans.size(), bots_n]

	if room_members_hint != null:
		room_members_hint.text = UIText.ROOM_MEMBERS_HINT % [members.size(), MAX_TEAM_PLAYERS]


## 名册里的一行：圆形头像 + 昵称 + 身份标签 +（只有房主能看到别人的）「踢」按钮。
## m 为空字典 = 这个位置是机器人。
func _build_member_row(m: Dictionary, team_col: Color) -> Control:
	var is_human := not m.is_empty()
	var is_self := is_human and bool(m.get("self", false))
	var peer_id := int(m.get("peer", 0))
	# 只有房主能踢人，而且不能踢自己（客户端看不到别人的列表，自然也踢不了）
	var can_kick := is_human and not is_self and lan != null and lan.hosting and peer_id > 0

	var row := PanelContainer.new()
	# 固定行高（不 EXPAND）：行框不随面板高度撑大
	row.custom_minimum_size = Vector2(0, 40)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.ROW_BG if is_human else UITheme.ROW_BG_FAINT
	sb.border_color = UITheme.ACCENT_DIM if is_self else UITheme.ROW_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	row.add_theme_stylebox_override("panel", sb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 9)
	row.add_child(hb)

	# 圆形头像：真人用队伍色 + 昵称首字，机器人用暗灰 + 「机」
	var av := PanelContainer.new()
	av.custom_minimum_size = Vector2(26, 26)
	av.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var avsb := StyleBoxFlat.new()
	avsb.bg_color = team_col if is_human else UITheme.AVATAR_BOT
	avsb.set_corner_radius_all(13)
	av.add_theme_stylebox_override("panel", avsb)
	hb.add_child(av)
	var initial := Label.new()
	initial.text = str(m.get("name", UIText.BOT_AVATAR_CHAR)).substr(0, 1) if is_human else UIText.BOT_AVATAR_CHAR
	initial.add_theme_font_size_override("font_size", 15)
	initial.add_theme_color_override("font_color",
			UITheme.ON_ACCENT if is_human else UITheme.AVATAR_TEXT)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	av.add_child(initial)

	# 昵称
	var nm := Label.new()
	nm.text = str(m.get("name", UIText.BOT_NAME_FALLBACK)) if is_human else UIText.BOT_NAME_FALLBACK
	nm.add_theme_font_size_override("font_size", 16)
	nm.add_theme_color_override("font_color",
			UITheme.TEXT if is_human else Color(UITheme.TEXT_DIM.r, UITheme.TEXT_DIM.g, UITheme.TEXT_DIM.b, 0.70))
	# ★ 必须 EXPAND_FILL：Label 一旦设了 overrun_trim，最小宽度就是 0，
	#   在 HBox 里不给 EXPAND 会被压成 0 宽 → 名字完全看不见。
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hb.add_child(nm)

	# 身份标签
	hb.add_child(_member_tag(str(m.get("tag", "")) if is_human else UIText.TAG_BOT))

	# 踢人（房主专属）
	if can_kick:
		var kick := _btn_kick()
		kick.pressed.connect(_on_kick_player.bind(peer_id))
		hb.add_child(kick)
	return row


## 小号「踢」按钮（红色系，一眼看出是踢人）
func _btn_kick() -> Button:
	var b := Button.new()
	b.text = UIText.BTN_KICK
	b.custom_minimum_size = Vector2(40, 24)
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", UITheme.KICK_TEXT)
	b.add_theme_color_override("font_hover_color", UITheme.KICK_TEXT_HOVER)
	b.add_theme_color_override("font_pressed_color", UITheme.KICK_TEXT_HOVER)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.KICK_BG
	sb.border_color = UITheme.KICK_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(4.0)
	var hover := sb.duplicate()
	hover.bg_color = UITheme.KICK_HOVER_BG
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


## 队头的选阵营按钮（CF 那种：点哪一队的「加入」就进哪一队）。
## 已经在本队 → 「当前队伍」置灰；队满 → 「已满」置灰。
## 用队伍本色着色，一眼看出是"加入这一队"。
func _btn_join_team(team: String) -> Button:
	var cur := team == local_team
	var full := not cur and not _can_join_team(team)
	var edge: Color = team_color(team)
	var b := Button.new()
	b.text = UIText.TEAM_CURRENT if cur else (UIText.TEAM_FULL if full else UIText.BTN_JOIN_TEAM)
	b.custom_minimum_size = Vector2(68, 24)
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = cur or full
	b.add_theme_color_override("font_color", edge if not cur else UITheme.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", UITheme.TEXT)
	b.add_theme_color_override("font_pressed_color", UITheme.TEXT)
	b.add_theme_color_override("font_disabled_color", UITheme.TEXT_DIM)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(edge.r, edge.g, edge.b, 0.14)
	sb.border_color = Color(edge.r, edge.g, edge.b, 0.60)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(4.0)
	var hover := sb.duplicate()
	hover.bg_color = Color(edge.r, edge.g, edge.b, 0.32)
	var dim := StyleBoxFlat.new()
	dim.bg_color = Color(UITheme.TEXT_DIM.r, UITheme.TEXT_DIM.g, UITheme.TEXT_DIM.b, 0.06)
	dim.border_color = UITheme.ROW_EDGE
	dim.set_border_width_all(1)
	dim.set_corner_radius_all(5)
	dim.set_content_margin_all(4.0)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("disabled", dim)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	if not cur and not full:
		b.pressed.connect(_on_pick_team.bind(team))
	return b


## 本机玩家能不能进这一队（给队头按钮置灰用）。
## 客户端本地看不到别人的阵营，先放行 —— 真满了房主会回一条 toast 拒绝。
func _can_join_team(team: String) -> bool:
	if team == local_team:
		return false
	if lan != null and lan.hosting:
		return _team_has_room(team, multiplayer.get_unique_id())
	return true


## 身份标签小胶囊（房主金 / 玩家蓝 / 电脑灰 / 本机灰）
func _member_tag(text: String) -> Control:
	var col := UITheme.ACCENT
	if text == UIText.TAG_PLAYER:
		col = UITheme.TAG_PLAYER
	elif text == UIText.TAG_BOT or text == UIText.TAG_LOCAL:
		col = UITheme.TEXT_DIM
	var chip := PanelContainer.new()
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r, col.g, col.b, 0.16)
	sb.border_color = Color(col.r, col.g, col.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 1.0
	sb.content_margin_bottom = 1.0
	chip.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", col)
	chip.add_child(l)
	return chip


# ---------------------------------------------------------------- 阵营选择
#
# 真人可以自己选阵营：点某一队队头的「加入」（CF 那种，点哪队进哪队）。
# ★ 房主是唯一权威 ★：谁改了都走房主改 `_peer_teams`，再 `_net_team_sync` 广播给所有人 ——
#   各台机器各算各的话，同一份名册在不同屏幕上会显示得不一样。
# 单机模式没有对端，直接改 `local_team` 就行。

## 本机玩家点了某一队队头的「加入」。team = **要加入的那一队**。
func _on_pick_team(team: String) -> void:
	if team != "CT" and team != "T":
		return
	if team == local_team:
		return
	local_team = team
	if lan != null and lan.hosting:
		_peer_teams[multiplayer.get_unique_id()] = team
		_net_team_sync.rpc(_peer_teams)      # call_local：本机也会跟着同步一遍
	elif lan != null and lan.is_connected_to_host():
		_net_pick_team.rpc_id(1, team)       # 交给房主校验人数上限 + 广播
	_show_toast(UIText.TOAST_TEAM_SWITCHED % team_full(team))
	_room_sig = ""
	_refresh_room_screen()


## 客户端请求换队 → 房主校验人数上限，通过就改 `_peer_teams` 并广播
@rpc("any_peer", "call_remote", "reliable")
func _net_pick_team(team: String) -> void:
	if not multiplayer.is_server():
		return
	if team != "CT" and team != "T":
		return
	var id := multiplayer.get_remote_sender_id()
	if not _team_has_room(team, id):
		_net_team_full.rpc_id(id, team)
		return
	_peer_teams[id] = team
	_net_team_sync.rpc(_peer_teams)


## 房主广播所有人的阵营（含房主自己）。客户端从里面认领自己那一行。
@rpc("authority", "call_local", "reliable")
func _net_team_sync(teams: Dictionary) -> void:
	_peer_teams = teams.duplicate()
	var mine := String(_peer_teams.get(multiplayer.get_unique_id(), local_team))
	if mine == "CT" or mine == "T":
		local_team = mine
	_room_sig = ""
	_refresh_room_screen()


## 房主告诉某个客户端"那队满了"
@rpc("authority", "call_remote", "reliable")
func _net_team_full(team: String) -> void:
	_show_toast(UIText.TOAST_TEAM_FULL % [team_name(team), MAX_TEAM_PLAYERS])


## 该队还能不能再进一个真人（每队上限 MAX_TEAM_PLAYERS）。
## except_id = 正要换进来的那个人（他自己原来那队的名额不算数）。
func _team_has_room(team: String, except_id := 0) -> bool:
	var n := 0
	for id in _peer_teams:
		if int(id) == except_id:
			continue
		if String(_peer_teams[id]) == team:
			n += 1
	return n + 1 <= MAX_TEAM_PLAYERS


## 给还没选过阵营的真人补默认值：哪队真人少就进哪队（一样多进磐垒）。
## 这样 1 个人在磐垒、2 个人自动分成磐垒 + 锐刃 —— 和以前"交替占位"的观感一致。
## 只在房主侧跑；客户端靠 `_net_team_sync` 认领自己那一行。
func _ensure_peer_teams() -> void:
	if not multiplayer.is_server():
		return
	var ids: Array = [multiplayer.get_unique_id()]
	for id in multiplayer.get_peers():
		ids.append(id)
	for id in ids:
		if _peer_teams.has(id):
			continue
		var ct := 0
		var t := 0
		for k in _peer_teams:
			if String(_peer_teams[k]) == "CT":
				ct += 1
			else:
				t += 1
		_peer_teams[id] = "CT" if ct <= t else "T"
	local_team = String(_peer_teams.get(multiplayer.get_unique_id(), local_team))


## 房主踢人：服务器侧断开该玩家
func _on_kick_player(peer_id: int) -> void:
	if lan == null or not lan.hosting or peer_id <= 0:
		return
	multiplayer.disconnect_peer(peer_id)
	_show_toast(UIText.TOAST_KICKED % peer_id)
	_room_sig = ""              # 强制重建名册
	_refresh_room_screen()


## 客户端连上房主后，把自己的昵称报上去（房主的名册才显示真名而不是"玩家 2"）
func _send_nick() -> void:
	if lan == null or not lan.is_connected_to_host():
		return
	_net_hello.rpc_id(1, player_nick)


## 房主侧收到客户端的昵称
@rpc("any_peer", "call_remote", "reliable")
func _net_hello(nick: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	var nm := nick.strip_edges()
	_peer_nicks[id] = nm if nm != "" else UIText.PEER_NAME_FMT % id
	_ensure_peer_teams()
	_net_team_sync.rpc(_peer_teams)
	_room_sig = ""
	_refresh_room_screen()


## 有玩家断开（服务器侧）→ 名册立刻刷新
func _on_peer_disconnected(id: int) -> void:
	print("[LAN] 玩家 %d 已断开" % id)
	_peer_nicks.erase(id)
	_peer_teams.erase(id)
	if _room_sig != "":
		_room_sig = ""
		_refresh_room_screen()


func _room_status_text() -> String:
	if lan == null:
		return UIText.ROOM_STATUS_NO_LAN
	if lan.hosting:
		return UIText.ROOM_STATUS_HOST % [lan.room_name, lan.game_port]
	if lan.is_connected_to_host():
		return UIText.ROOM_STATUS_CLIENT
	if lan.last_error != "":
		return lan.last_error
	return UIText.ROOM_STATUS_LOCAL


func _build_crosshair(scene: Node) -> void:
	var layers := CanvasLayer.new()
	layers.layer = 10
	scene.add_child(layers)
	var ch: Control = load("res://scripts/crosshair.gd").new()
	ch.set_anchors_preset(Control.PRESET_FULL_RECT)
	layers.add_child(ch)
	crosshair_control = ch
	crosshair_layer = layers
	crosshair_layer.visible = false
