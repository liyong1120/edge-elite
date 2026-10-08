class_name WeaponDatabase
extends RefCounted

# 武器数值数据库（对照 GDD 第二章）
# 数值字段：damage, rpm(每分钟射速), mag(弹匣), reserve(备弹), armor_ratio(对甲衰减倍率),
#          speed(相对移动速度 250=默认), price, team, slot, kill_reward, head_mult,
#          recoil(每发累积的**散布半角，弧度**；第一发不吃后坐力，越大越难压枪)
#
# recoil 手感标尺（弧度 → 角度）：
#   0.010 ≈ 0.57°（极稳）   0.020 ≈ 1.15°（可控）   0.032 ≈ 1.83°（难压）
#   连发平衡点 = fire_rate/60 * recoil - 0.10(衰减)；> 0 才会越打越散，
#   达到上限 0.14（≈8° 散布锥）所需时间 = 0.14 / 平衡点。

static func weapons() -> Dictionary:
	return {
		# --- 近战 ---
		"Knife": {
			"name": "匕首", "slot": 3, "team": "any", "price": 0,
			"light": 15, "heavy": 65, "backstab": 9999,
			"light_rate": 2.0, "heavy_rate": 1.0, "kill": 1500, "class": "knife",
			"can_auto": false, "first_person_ip": "models/knife.glb"
		},
		# --- 手枪 ---
		"Glock": {
			"name": "Glock-18", "slot": 2, "team": "T", "price": 0,
			"damage": 25, "fire_rate": 400, "mag": 20, "reserve": 120,
			"armor_ratio": 0.5, "head_mult": 4.0, "kill": 300, "class": "pistol",
			"recoil": 0.018, "can_auto": false
		},
		"USP": {
			"name": "USP", "slot": 2, "team": "CT", "price": 0,
			"damage": 34, "fire_rate": 400, "mag": 12, "reserve": 100,
			"armor_ratio": 0.62, "head_mult": 4.0, "kill": 300, "class": "pistol",
			"recoil": 0.016, "can_auto": false, "suppressor": true
		},
		"Deagle": {
			"name": "沙漠之鹰", "slot": 2, "team": "any", "price": 650,
			"damage": 54, "fire_rate": 267, "mag": 7, "reserve": 35,
			"armor_ratio": 0.9, "head_mult": 4.0, "kill": 300, "class": "pistol",
			"recoil": 0.040, "can_auto": false, "high_pen": true
		},
		# --- 冲锋枪 ---
		"MP5": {
			"name": "MP5", "slot": 1, "team": "any", "price": 1500,
			"damage": 26, "fire_rate": 800, "mag": 30, "reserve": 120,
			"armor_ratio": 0.5, "head_mult": 4.0, "kill": 600, "class": "smg",
			"recoil": 0.011, "can_auto": true, "move_penalty": 0.3
		},
		"P90": {
			"name": "P90", "slot": 1, "team": "any", "price": 2350,
			"damage": 21, "fire_rate": 857, "mag": 50, "reserve": 100,
			"armor_ratio": 0.5, "head_mult": 4.0, "kill": 600, "class": "smg",
			"recoil": 0.010, "can_auto": true, "move_penalty": 0.3
		},
		# --- 霰弹枪 ---
		"XM1014": {
			"name": "XM1014", "slot": 1, "team": "any", "price": 3000,
			"damage": 26, "fire_rate": 171, "mag": 7, "reserve": 32,
			"armor_ratio": 0.6, "head_mult": 4.0, "kill": 900, "class": "shotgun",
			"recoil": 0.035, "can_auto": false, "pellets": 6, "spread": 0.055, "move_penalty": 0.6
		},
		# --- 步枪 ---
		"AK47": {
			"name": "AK-47", "slot": 1, "team": "T", "price": 2500,
			"damage": 36, "fire_rate": 600, "mag": 30, "reserve": 90,
			"armor_ratio": 0.92, "head_mult": 4.0, "kill": 300, "class": "rifle",
			"recoil": 0.022, "can_auto": true, "recoil_pattern": "AK", "move_penalty": 1.0
		},
		"M4A1": {
			"name": "M4A1", "slot": 1, "team": "CT", "price": 3100,
			"damage": 32, "fire_rate": 685, "mag": 30, "reserve": 90,
			"armor_ratio": 0.92, "head_mult": 4.0, "kill": 300, "class": "rifle",
			"recoil": 0.017, "can_auto": true, "suppressor": true, "move_penalty": 1.0
		},
		"Galil": {
			"name": "Galil", "slot": 1, "team": "T", "price": 2000,
			"damage": 30, "fire_rate": 666, "mag": 35, "reserve": 90,
			"armor_ratio": 0.85, "head_mult": 4.0, "kill": 300, "class": "rifle",
			"recoil": 0.024, "can_auto": true, "move_penalty": 1.0
		},
		"FAMAS": {
			"name": "FAMAS", "slot": 1, "team": "CT", "price": 2250,
			"damage": 30, "fire_rate": 1000, "mag": 25, "reserve": 90,
			"armor_ratio": 0.85, "head_mult": 4.0, "kill": 300, "class": "rifle",
			"recoil": 0.020, "can_auto": true, "move_penalty": 1.0
		},
		"SG552": {
			"name": "SG-552", "slot": 1, "team": "T", "price": 3500,
			"damage": 33, "fire_rate": 727, "mag": 30, "reserve": 90,
			"armor_ratio": 0.92, "head_mult": 4.0, "kill": 300, "class": "rifle",
			"recoil": 0.021, "can_auto": true, "zoom": true, "move_penalty": 1.0
		},
		"AUG": {
			"name": "AUG", "slot": 1, "team": "CT", "price": 3500,
			"damage": 32, "fire_rate": 680, "mag": 30, "reserve": 90,
			"armor_ratio": 0.92, "head_mult": 4.0, "kill": 300, "class": "rifle",
			"recoil": 0.019, "can_auto": true, "zoom": true, "move_penalty": 1.0
		},
		# --- 狙击枪 ---
		# 栓动狙（Scout/AWP）有 1.4s 拉栓，后坐力早已回落到 0 → 每一发都是首发精准；
		# 这里的 recoil 只决定"单发镜头后坐感"，所以数值压得比步枪略高一点即可。
		"Scout": {
			"name": "Scout", "slot": 1, "team": "any", "price": 2750,
			"damage": 75, "fire_rate": 40, "mag": 10, "reserve": 90, "auto": false,
			"armor_ratio": 0.85, "head_mult": 4.0, "kill": 300, "class": "sniper",
			"recoil": 0.022, "can_auto": false, "zoom": true, "bolt": true, "move_penalty": 0.4, "speed_bonus": true
		},
		"AWP": {
			"name": "AWP", "slot": 1, "team": "any", "price": 4750,
			"damage": 115, "fire_rate": 41, "mag": 10, "reserve": 30, "auto": false,
			"armor_ratio": 0.98, "head_mult": 4.0, "kill": 300, "class": "sniper",
			"recoil": 0.028, "can_auto": false, "zoom": true, "bolt": true, "move_penalty": 0.25, "one_shot": true
		},
		"SG550": {
			"name": "SG-550", "slot": 1, "team": "CT", "price": 4200,
			"damage": 40, "fire_rate": 240, "mag": 30, "reserve": 90,
			"armor_ratio": 0.85, "head_mult": 4.0, "kill": 300, "class": "sniper",
			"recoil": 0.026, "can_auto": false, "zoom": true, "move_penalty": 0.4
		},
		"G3SG1": {
			"name": "G3SG1", "slot": 1, "team": "T", "price": 5000,
			"damage": 45, "fire_rate": 240, "mag": 20, "reserve": 90,
			"armor_ratio": 0.85, "head_mult": 4.0, "kill": 300, "class": "sniper",
			"recoil": 0.028, "can_auto": false, "zoom": true, "move_penalty": 0.4
		},
		# --- 机枪 ---
		# 100 发弹链 + 750 RPM：连发时散布爬升最快（约 0.5s 就顶到 8° 上限），
		# 是全场最难压的自动武器 —— 这才对得起它的定位与价格。
		"M249": {
			"name": "M249", "slot": 1, "team": "any", "price": 5750,
			"damage": 32, "fire_rate": 750, "mag": 100, "reserve": 200,
			"armor_ratio": 0.85, "head_mult": 4.0, "kill": 300, "class": "lmg",
			"recoil": 0.032, "can_auto": true, "move_penalty": 0.5
		}
	}
