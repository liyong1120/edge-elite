extends RefCounted
class_name ConfigManager

const CONFIG_PATH_PROJECT := "res://config.toml"
const CONFIG_PATH_USER := "user://config.toml"

var config: Dictionary = {}

static var instance: ConfigManager = null

func _init() -> void:
	instance = self
	_load()

## 轻量 TOML 解析：只支持 [section]、key = value、# 注释行、空行。
## Godot 自带 ConfigFile 无法解析注释中含 '=' 的行（如 "# ===="、"# true = ..."），
## 因此这里自写解析器，保证带中文注释的 config.toml 能正常读取。
func _parse_toml_text(text: String) -> Dictionary:
	var out: Dictionary = {}
	var section := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with(";"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).strip_edges()
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		if key.is_empty():
			continue
		var parsed: Variant = _parse_toml_value(value)
		if section.is_empty():
			out[key] = parsed
		else:
			var sec: Dictionary = out.get(section, {})
			sec[key] = parsed
			out[section] = sec
	return out

func _parse_toml_value(v: String) -> Variant:
	if v.begins_with("\"") and v.ends_with("\"") and v.length() >= 2:
		return v.substr(1, v.length() - 2)
	if v.begins_with("'") and v.ends_with("'") and v.length() >= 2:
		return v.substr(1, v.length() - 2)
	# 数组 [a, b, c] → Array（弹孔颜色等）
	if v.begins_with("[") and v.ends_with("]") and v.length() >= 2:
		var inner := v.substr(1, v.length() - 2)
		var arr: Array = []
		for item in inner.split(","):
			var iv := item.strip_edges()
			if iv.is_empty(): continue
			if iv.is_valid_float():
				arr.append(iv.to_float())
			elif iv.is_valid_int():
				arr.append(iv.to_int())
			else:
				arr.append(_parse_toml_value(iv))
		return arr
	var low := v.to_lower()
	if low == "true": return true
	if low == "false": return false
	if v.is_valid_int(): return v.to_int()
	if v.is_valid_float(): return v.to_float()
	return v

func _load() -> void:
	# 优先读取项目目录 config.toml（开发时直接改这个文件，保留中文注释）
	# 发布后 res:// 只读，则读取 user://config.toml（运行时保存的配置）
	if FileAccess.file_exists(CONFIG_PATH_PROJECT):
		config = _parse_toml_text(FileAccess.get_file_as_string(CONFIG_PATH_PROJECT))
	elif FileAccess.file_exists(CONFIG_PATH_USER):
		config = _parse_toml_text(FileAccess.get_file_as_string(CONFIG_PATH_USER))
	else:
		_load_defaults()
		# 首次运行保存到 user://
		_save()

func _load_defaults() -> void:
	config = {
		"bot": {"can_attack": true, "difficulty": 1},
		"gameplay": {"round_time": 180, "buy_time": 10, "bomb_timer": 40},
		"graphics": {"fov": 90, "mouse_sensitivity": 2.2},
		"audio": {"master_volume": 1.0, "sfx_volume": 1.0, "music_volume": 0.5},
	}
	_save()

## 仅运行时记忆写入 user://，绝不动 res://config.toml（避免抹掉中文注释）
func _save() -> void:
	var cfg := ConfigFile.new()
	for sec in config:
		var sec_dict: Variant = config[sec]
		if sec_dict is Dictionary:
			for k in sec_dict:
				cfg.set_value(sec, k, config[sec][k])
		else:
			cfg.set_value("", sec, config[sec])
	if cfg.save(CONFIG_PATH_USER) != OK:
		push_error("保存配置失败: %s" % CONFIG_PATH_USER)

## 机器人是否允许攻击（枪/刀/手雷等所有攻击方式）
## 实时读取磁盘：游戏运行中改 config.toml 保存后立即生效，无需重启
func get_bot_can_attack() -> bool:
	var target := CONFIG_PATH_PROJECT
	if not FileAccess.file_exists(target):
		target = CONFIG_PATH_USER
	if not FileAccess.file_exists(target):
		return true
	var cfg := _parse_toml_text(FileAccess.get_file_as_string(target))
	var sec: Variant = cfg.get("bot", {})
	if sec is Dictionary and sec.has("can_attack"):
		return sec["can_attack"]
	return true

func set_bot_can_attack(value: bool) -> void:
	var sec: Dictionary = config.get("bot", {})
	sec["can_attack"] = value
	config["bot"] = sec
	_save()

## 人机难度：0=简单 1=普通 2=困难（从内存 config 读，避免被 res:// 里的旧值盖掉）
func get_bot_difficulty() -> int:
	var sec: Variant = config.get("bot", {})
	if sec is Dictionary and sec.has("difficulty"):
		return clampi(int(sec["difficulty"]), 0, 2)
	return 1

func set_bot_difficulty(value: int) -> void:
	var sec: Dictionary = config.get("bot", {})
	sec["difficulty"] = clampi(value, 0, 2)
	config["bot"] = sec
	_save()

func get_gameplay(key: String) -> Variant:
	return _get_value("gameplay", key, null)

func get_graphics(key: String) -> Variant:
	return _get_value("graphics", key, null)

func get_audio(key: String) -> Variant:
	return _get_value("audio", key, null)

## 弹道特效参数
func get_effects() -> Dictionary:
	return {"tracer_radius": get_effect("tracer_radius", 0.035),
		"tracer_lifetime": get_effect("tracer_lifetime", 0.10),
		"tracer_color": get_effect("tracer_color", [1.0, 0.85, 0.4]),
		"tracer_brightness": get_effect("tracer_brightness", 4.5),
		"hitmarker_radius": get_effect("hitmarker_radius", 0.05),
		"hitmarker_height": get_effect("hitmarker_height", 0.01),
		"hitmarker_color": get_effect("hitmarker_color", Color(0.06, 0.06, 0.07))}

func get_effect(key: String, default: Variant) -> Variant:
	return _get_value("effects", key, default)

## UI 界面参数（计分板隔行色等）
func get_ui(key: String, default: Variant) -> Variant:
	return _get_value("ui", key, default)

## 读取 [weapons] 节的全局配置项（如 recoil_multiplier）
func get_weapon_global(key: String, default: Variant) -> Variant:
	return _get_value("weapons", key, default)

## 枪械属性覆盖：config.toml [weapons] 中 wid_key 值，未配置返回 default
func get_weapon_override(wid: String, key: String, default: Variant) -> Variant:
	var v: Variant = _get_value("weapons", "%s_%s" % [wid, key], null)
	if v == null:
		return default
	return v

func _get_value(section: String, key: String, default: Variant) -> Variant:
	var sec: Variant = config.get(section, {})
	if sec is Dictionary and sec.has(key):
		return sec[key]
	return default