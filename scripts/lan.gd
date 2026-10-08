class_name LanNet
extends Node

## 局域网联机：**房间发现**（UDP 广播信标）+ **连接**（ENet）。
##
## ------------------------------------------------------------------ 房间发现怎么做的
## 局域网里没有中心服务器，最省事、零配置的做法是 UDP 广播：
##   主机   —— 每 BEACON_INTERVAL 秒向广播地址 255.255.255.255:DISCOVERY_PORT 发一个信标包
##              （房间名 / 人数 / 游戏端口 / 主机随机 id）
##   客户端 —— 监听同一个 UDP 端口，收到信标就按"发送方 IP"记一条房间；
##              超过 ROOM_TIMEOUT 没再收到就自动从列表里消失（主机关了房间会自然消失）
## 这样进游戏点一下就能看到局域网里所有人的房间，不用手填 IP。
##
## 信标用 JSON 字符串（带魔数 CSPL），解析简单、以后加字段也方便。
##
## 注意：本文件只负责"找到房间 + 建立 ENet 连接"。
## 真正让两边画面同步（位置/伤害/拾取/回合）需要**服务器权威改造**，是后续独立的一步。

const BASE_DISCOVERY_PORT := 27777   # 发现用的 UDP 端口（同一局域网内所有机器一致）
# ★ 同一台机器要能同时开两份（用户没第二台机器，只能双开自测局域网）★
#   UDP 端口只能被**一个进程独占** bind —— 实测第二个进程 bind 27777 返回 err=2、
#   socket 无效、一个包都收不到（这就是"开两份看不到第一份房间"的原因）。
#   所以再放一个备用端口：每个实例按顺序 bind 第一个能用的；
#   主机把信标**往这一组端口全发一遍**，这样不管对方绑到哪个端口都收得到。
#   （实测：进程 A 绑 27777、进程 B 绑 27787，A 往 27787 发广播 B 能收到。）
#   ★ 这一组**只放两个端口 = 一台机器最多开 2 份**（用户要求）★：
#     第 3 份两个端口都绑不上 → last_error 有提示，大厅状态栏会写出来。
const BASE_DISCOVERY_PORTS: Array[int] = [27777, 27787]
const MAX_LOCAL_INSTANCES := 2    # 一台机器最多同时开几份（= BASE_DISCOVERY_PORTS.size()）
const BASE_GAME_PORT := 27778     # 实际对局的 ENet 端口
# ★ 实际用的端口 = 基准 + 环境变量 CS_LAN_PORT_OFFSET ★
#   自检/联机调试时设成 100 之类的值，就能和"正在跑的游戏"错开端口，
#   不用先把游戏关掉才能跑双进程测试。发布出去的包没人设这个变量 → 偏移 0，行为不变。
var discovery_ports: Array[int] = []
var game_port := BASE_GAME_PORT
const BEACON_INTERVAL := 1.0      # 主机发信标的间隔（秒）
const ROOM_TIMEOUT := 3.5         # 这么久没收到信标就认为房间没了
const MAX_PLAYERS := 8            # 每队人数上限（与 main.gd MAX_TEAM_PLAYERS 一致）
const MAGIC := "CSPL"
# 自己开的房间在大厅列表里的 key。**不能靠"收到自己发的广播"**来显示自己的房间
# （UDP 广播能不能回到自己这套 socket 是不确定的），所以直接往 _rooms 里塞一条，
# 由 poll() 每帧刷新 seen，保证它永远不过期。
const SELF_ROOM_KEY := "@self"

var room_name := ""               # 主机：本房间名
var hosting := false
var host_id := 0                  # 随机 id：用来把自己发的信标认出来并忽略
var listen_port := 0              # 本进程实际绑到的发现端口（同机双开时不是 27777）
var last_error := ""

var _beacon: PacketPeerUDP = null
var _listener: PacketPeerUDP = null
var _beacon_cool := 0.0
var _rooms: Dictionary = {}       # ip -> {"name": String, "players": int, "port": int, "seen": float}
var _elapsed := 0.0


func _ready() -> void:
	host_id = randi()
	# 端口偏移（自检用；正常玩的时候没有这个环境变量，偏移为 0）
	var off := 0
	var s := OS.get_environment("CS_LAN_PORT_OFFSET")
	if s.is_valid_int():
		off = int(s)
	game_port = BASE_GAME_PORT + off
	for p in BASE_DISCOVERY_PORTS:
		discovery_ports.append(p + off)
	# 常驻监听：进大厅就能看到房间，不必等玩家点"刷新"
	start_discovery()


# ------------------------------------------------------------------ 主机

## 创建房间并开始广播。返回是否成功。
func start_host(name: String) -> bool:
	stop_host()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(game_port, MAX_PLAYERS * 2)
	if err != OK:
		last_error = "创建房间失败（端口 %d 被占用？err=%d）" % [game_port, err]
		return false
	multiplayer.multiplayer_peer = peer
	room_name = name
	hosting = true
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", discovery_ports[0])
	_beacon_cool = 0.0      # 立刻发一次，别人马上就能看到
	_refresh_self_room()    # 自己的房间也立刻出现在大厅列表里（不等下一帧 poll）
	last_error = ""
	return true


func stop_host() -> void:
	hosting = false
	room_name = ""
	_rooms.erase(SELF_ROOM_KEY)     # 自己的房间从大厅列表里撤掉
	if _beacon != null:
		_beacon.close()
		_beacon = null
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null


# ------------------------------------------------------------------ 客户端

func start_discovery() -> void:
	if _listener != null:
		return
	# 按顺序找第一个能用的端口（同机双开时第一个进程占 27777，第二个自动落到 27787…）
	for p in discovery_ports:
		var l := PacketPeerUDP.new()
		if l.bind(p) == OK:
			_listener = l
			listen_port = p
			last_error = ""
			return
		l.close()
	last_error = "监听房间广播失败：本机已经开了 %d 份，最多同时开 %d 份（发现端口 %s 都被占用）" % [
			MAX_LOCAL_INSTANCES, MAX_LOCAL_INSTANCES, str(discovery_ports)]
	_listener = null


func stop_discovery() -> void:
	if _listener != null:
		_listener.close()
		_listener = null
	_rooms.clear()


## 加入某个房间（ip 来自房间列表）
func join(ip: String) -> bool:
	stop_host()   # 自己不再是主机
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, game_port)
	if err != OK:
		last_error = "连接 %s 失败（err=%d）" % [ip, err]
		return false
	multiplayer.multiplayer_peer = peer
	last_error = ""
	return true


## 已经连上主机了吗
## ★ 房主**自己**的 ENet 连接状态同样是 CONNECTION_CONNECTED，必须显式排除，
##   否则房主会被判成"已连接到房主"（状态栏显示错乱）。
func is_connected_to_host() -> bool:
	var p := multiplayer.multiplayer_peer
	if p == null or not (p is ENetMultiplayerPeer):
		return false
	if (p as ENetMultiplayerPeer).get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return not multiplayer.is_server()      # 服务器（房主）不算"连接到房主"


func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null


# ------------------------------------------------------------------ 每帧推进

func poll(delta: float) -> void:
	_elapsed += delta
	if hosting and _beacon != null:
		_beacon_cool -= delta
		if _beacon_cool <= 0.0:
			_beacon_cool = BEACON_INTERVAL
			_send_beacon()
		_refresh_self_room()
	if _listener == null:
		return
	# 收信标
	while _listener.get_available_packet_count() > 0:
		var raw := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		_read_beacon(raw, ip)
	# 过期房间清理（自己的房间每帧刷 seen，不会被清掉）
	var dead: Array = []
	for ip in _rooms:
		if _elapsed - float(_rooms[ip]["seen"]) > ROOM_TIMEOUT:
			dead.append(ip)
	for ip in dead:
		_rooms.erase(ip)


## 把自己的房间登记进列表（每帧刷新 seen），这样"创建房间 → 返回上一步"后
## 还能在大厅里看到自己的房间，点进去继续，或者点「解散」关掉。
func _refresh_self_room() -> void:
	var players := 1
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		players = maxi(1, multiplayer.get_peers().size() + 1)
	_rooms[SELF_ROOM_KEY] = {
		"name": room_name,
		"players": players,
		"max": MAX_PLAYERS * 2,
		"port": game_port,
		"seen": _elapsed,
		"mine": true,
	}


func _send_beacon() -> void:
	var players := 1
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		# ★ get_peers() 在 MultiplayerAPI 上，不在 ENetMultiplayerPeer 上。
		#   写在 peer 上会报 "Nonexistent function 'get_peers' in base 'ENetMultiplayerPeer'"。
		#   multiplayer.get_peers() 返回已连接的对端 id（不含自己），+1 就是总人数。
		players = maxi(1, multiplayer.get_peers().size() + 1)
	var msg := {
		"magic": MAGIC,
		"name": room_name,
		"players": players,
		"max": MAX_PLAYERS * 2,
		"port": game_port,
		"id": host_id,
	}
	# ★ 往整组端口各发一遍 ★：同机双开时对方的监听端口不是 27777（见 DISCOVERY_PORTS）
	var buf := JSON.stringify(msg).to_utf8_buffer()
	for p in discovery_ports:
		_beacon.set_dest_address("255.255.255.255", p)
		_beacon.put_packet(buf)


func _read_beacon(raw: PackedByteArray, ip: String) -> void:
	# 先粗筛：不是以 '{' 开头的直接丢掉。局域网里会有各种杂包，
	# 直接喂给 JSON 解析器会让 Godot 刷一堆 "Parse JSON failed" 错误日志。
	if raw.is_empty() or raw[0] != 0x7B:
		return
	var txt := raw.get_string_from_utf8()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	if String(d.get("magic", "")) != MAGIC:
		return
	# 自己发的信标（同一台机器既开房间又开大厅时）不显示成"别人的房间"
	if hosting and int(d.get("id", -1)) == host_id:
		return
	_rooms[ip] = {
		"name": String(d.get("name", "未命名房间")),
		"players": int(d.get("players", 1)),
		"max": int(d.get("max", MAX_PLAYERS * 2)),
		"port": int(d.get("port", game_port)),
		"seen": _elapsed,
	}


## 房间列表（自己的房间永远排最前，其余按房间名排序，方便 UI 稳定显示）
func rooms() -> Array:
	var out: Array = []
	for ip in _rooms:
		var r: Dictionary = _rooms[ip]
		out.append({
			"ip": ip, "name": r["name"], "players": r["players"], "max": r["max"],
			"mine": bool(r.get("mine", false)),
		})
	out.sort_custom(func(a, b):
		if bool(a["mine"]) != bool(b["mine"]):
			return bool(a["mine"])          # 自己的房间置顶
		return String(a["name"]) < String(b["name"]))
	return out


## 单机测试用：直接把一条房间塞进列表（跳过网络）
func debug_add_room(ip: String, name: String, players: int) -> void:
	_rooms[ip] = {"name": name, "players": players, "max": MAX_PLAYERS * 2, "seen": _elapsed}
