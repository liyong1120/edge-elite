class_name UIText
extends RefCounted

## ============================================================ 界面文案
##
## ★★★ 想改界面上显示的字，只改这一个文件 ★★★
##
## 配色在 `scripts/ui_theme.gd`；这里只管"文字"。
## 带 `%s` / `%d` / `%.1f` 的是格式化模板 —— 改词的时候别把占位符弄丢。
##
## 这里**没有**的：调试自检的输出（`print("[OK] ...")`）—— 那是给开发者看的，
## 不是界面文案，留在各自的自检函数里。

# ---------------------------------------------------------------- 游戏名
const TITLE := "棱锋精英"
const TITLE_EN := "EDGE ELITE"

# ---------------------------------------------------------------- 阵营
# 名字在这里改；阵营**颜色**在 ui_theme.gd 的 TEAM_COLOR
const TEAM_NAME := {"CT": "磐垒", "T": "锐刃"}             # 短名（顶部比分条）
const TEAM_NAME_FULL := {"CT": "磐垒军团", "T": "锐刃军团"}  # 全名（计分板 / 房间名册）
const TEAM_WIN := "%s 阵营胜利"
const TEAM_DRAW := "平局"
const TEAM_SCORE := "%s  %d   :   %d  %s"
const TEAM_SCORE_TIGHT := "%s %d  :  %d %s"
const TEAM_WINS := "%d 胜"

# ---------------------------------------------------------------- 阵营身份标签
const TAG_HOST := "房主"
const TAG_PLAYER := "玩家"
const TAG_LOCAL := "本机"
const TAG_BOT := "电脑"
const BOT_AVATAR_CHAR := "电"        # 电脑头像里的那个字（取昵称首字，电脑用这个）
const BOT_NAME_FALLBACK := "电脑"

# ---------------------------------------------------------------- 通用按钮
const BTN_CREATE_ROOM := "创建房间"
const BTN_JOIN := "加入"
const BTN_DISMISS := "解散"
const BTN_BACK_ROOM := "返回房间"
const BTN_BACK_PREV := "返回上一步"
const BTN_START := "进入游戏"
const BTN_RESUME := "继续游戏"
const BTN_LEAVE_TO_ROOM := "回到房间"
const BTN_KICK := "踢"
const BTN_JOIN_TEAM := "加入"      # 队头的选阵营按钮（CF 那种：点哪队进哪队）
const TEAM_CURRENT := "当前队伍"
const TEAM_FULL := "已满"
const BTN_CLOSE := "关闭"
const BTN_CREDITS := "特别鸣谢"

# ---------------------------------------------------------------- 地图
const MAP_NAME := {"iceworld": "石阵广场"}
const MAP_DESC := {"iceworld": "经典方块对枪小图\n中央石块群 · 砖石掩体 · 满地捡枪"}
const MAP_PICKED := "已选：%s（%s）"
const MAP_LEGEND := "灰 = 围墙 / 大石块 · 棕 = 齐胸矮墙 · 蓝红点 = 双方出生点 · A / B = 包点"

# ---------------------------------------------------------------- 大厅（界面1）
const LOBBY_LIST_TITLE := "局域网房间"
const LOBBY_LIST_HINT := "每秒自动刷新 · 同一 WiFi / 交换机下可见"
const LOBBY_NICK_LABEL := "昵称"
# 默认昵称 = 玩家 + 3 位随机数字（同机双开 / 多台机器同时进来不会重名）
const LOBBY_NICK_FMT := "玩家%d"
const LOBBY_EMPTY := "没找到房间。\n在下面「创建房间」自己开一局（电脑会补满人数）"
const LOBBY_MINE_SUFFIX := "%s（你的房间）"
const LOBBY_ROW_META := "%d / %d 人 · %s"
const LOBBY_ROW_META_MINE := "本机 · 你是房主"
const LOBBY_STATUS_IDLE := "监听 UDP %d · 没看到房间？确认大家连的是同一个 WiFi / 交换机"
# 特别鸣谢（界面1 右下角按钮 → 大窗口，正文读 res://特别鸣谢.txt）
const CREDITS_TITLE := "特别鸣谢"
const CREDITS_MISSING := "没能读到「%s」，把文件放回项目根目录即可。"
# 文件不是 UTF-8 时 Godot 读出来会是乱码（U+FFFD），给一句能自己修好的提示
const CREDITS_BAD_ENCODING := "⚠ 这个文件不是 UTF-8 编码，部分字显示成了乱码。用记事本打开 → 另存为 → 编码选 UTF-8 即可。"
const LOBBY_STATUS_HOSTING := "你正在开房「%s」· 房间已列在上方，点「返回房间」继续，点「解散」关闭"
const LOBBY_STATUS_CLIENT := "已连接到房主 · 等待房主开始对局"
const ROOM_NAME_FMT := "%s的房间"        # 房间名 = 昵称 + 这个后缀

const HELP_LAN_TITLE := "怎么联机"
const HELP_LAN_BODY := "1. 所有机器连同一个 WiFi / 交换机。\n" \
		+ "2. 一台机器点左下「创建房间」，其余机器在左边列表点「加入」。\n" \
		+ "3. 两队真人数量不一样时，人少的一方自动补电脑。\n" \
		+ "4. 房主选好地图点「进入游戏」即可开打。"
const HELP_KEY_TITLE := "操作"
# 每项 = [按键, 说明]，渲染时按键一列、说明一列，两列各自左对齐（见 main.gd _help_key_grid）。
# 左列 7 条 / 右列 6 条；改动条数时注意两边行数尽量接近。
const HELP_KEY_LEFT := [
	["WASD", "移动"], ["Shift", "静步"], ["Ctrl", "蹲下"], ["空格", "跳跃"],
	["左键", "射击"], ["右键", "开镜"], ["R", "换弹"],
]
const HELP_KEY_RIGHT := [
	["1-5", "切枪"], ["G", "丢枪"], ["B", "购买"],
	["Tab", "计分板"], ["ESC", "暂停"], ["P", "截图"],
]

# ---------------------------------------------------------------- 房间（界面2）
const ROOM_MEMBERS_TITLE := "房间成员"
const ROOM_MEMBERS_HINT := "在线真人 %d 人 · 点队头右边的「加入」选择自己的阵营 · 两队真人不一样时，人少的一方补电脑（每队上限 %d 人）"
const ROOM_TEAM_COUNT := "真人 %d · 电脑 %d"
const ROOM_DIFF_TITLE := "人机难度"
const ROOM_DIFF_HINT := "影响电脑的命中率 / 反应速度 / 移速"
const ROOM_MAP_TITLE := "地图"
const ROOM_STATUS_NO_LAN := "局域网未初始化"
const ROOM_STATUS_HOST := "你是房主 · 正在广播「%s」（端口 %d）· 等其他人从房间列表点「加入」"
const ROOM_STATUS_CLIENT := "已连接到房主 · 等待房主点「进入游戏」"
const ROOM_STATUS_LOCAL := "本机模式（未创建 / 未加入房间）· 直接「进入游戏」也能和电脑打"
const TOAST_WAIT_HOST := "已连接房主，等待房主点「进入游戏」"
const TOAST_KICKED := "已踢出玩家 %d"
const PEER_NAME_FMT := "玩家 %d"          # 对端还没上报昵称时的占位名

# ---------------------------------------------------------------- 暂停 / 整场结束
const PAUSE_TITLE := "游戏暂停"
const GAME_OVER_TITLE := "整场结束"
const GAME_OVER_COUNTDOWN := "%d 秒后自动回到房间（也可以直接点下面的按钮）"

# ---------------------------------------------------------------- 计分板
const SCORE_TITLE := "战 绩 统 计"
const SCORE_COL_RANK := "#"
const SCORE_COL_NAME := "昵称"
const SCORE_COL_KILLS := "击杀"
const SCORE_COL_DEATHS := "死亡"
const SCORE_HINT := "按住 Tab 查看战绩  •  松开 Tab 隐藏"

# ---------------------------------------------------------------- 购买菜单
const BUY_ITEMS := [
	["[1] AK-47 ($2500) T", "AK47"],
	["[2] M4A1 ($3100) CT", "M4A1"],
	["[3] 沙漠之鹰 ($650)", "Deagle"],
	["[4] MP5 ($1500)", "MP5"],
	["[5] AWP ($4750)", "AWP"],
	["[6] 防弹衣+头盔 ($1000)", "ARMOR"],
	["[7] 拆弹器 (CT $200)", "KIT"],
	["[8] 补充弹药 ($200)", "AMMO"],
]
const BUY_HOTKEY_TIP := "[1]AK47 [2]M4A1 [3]Deagle [4]MP5 [5]AWP [6]护甲 [7]拆弹器 [8]子弹"
const BUY_PACK_TITLE := "背包（当前装备）"
const BUY_SLOT_NAMES := {1: "主武器1", 4: "主武器2", 2: "手枪", 3: "近战"}
const BUY_SLOT_EMPTY := "%s：空"
const BUY_ARMOR := "防弹衣：%s（%d%%）"
const BUY_DEFUSER := "拆弹器：%s"
const BUY_YES := "有"
const BUY_NO := "无"
const BUY_SWITCH_HINT := "按 1 键在主武器间切换"
const BUY_MONEY := "金钱 $%d"
const BUY_MONEY_INIT := "金钱 $10000"
const BUY_TIP_IDLE := "已购买：-"
const BUY_FOOTER := "B 关闭菜单   + / - 增减电脑"
const BUY_TIME_LEFT := "购买时间 %d 秒"
const BUY_TIME_UP := "购买已结束（仅可查看背包）"
const BUY_OK_ARMOR := "已购买 防弹衣+头盔"
const BUY_OK_DEFUSER := "已购买 拆弹器"
const BUY_OK_AMMO := "已补充弹药"
const BUY_OK_ITEM := "已购买 "          # 后面拼武器 id
const BUY_FAIL_HOLD := "金钱不足或已持有"
const BUY_FAIL_MONEY := "金钱不足"
const BUY_FAIL_LIMIT := "无法购买（阵营限制或金钱不足）"

# ---------------------------------------------------------------- HUD
const HUD_STATUS := "HP %d  护甲 %s   金钱 $%d   阵营 %s"
const HUD_TIME := "剩余 %d:%02d   敌方 %d 人"
const HUD_TIME_SIMPLE := "剩余 %d:%02d"
const HUD_MELEE := "%s   近战武器"
const HUD_AMMO := "%s   弹药 %d / %d"
const HUD_RELOADING := "换弹中..."
const HUD_BOLTING := "拉栓中..."
const HUD_PLANTING := "正在安装 C4..."
const HUD_DEFUSING := "正在拆除 C4..."
const HUD_C4_CLEARED := "敌人已清空！快去拆除 C4（%.1f s）"
const HUD_C4_TIMER := "炸弹倒计时 %.1f s"
const TOAST_DIFFICULTY := "人机难度：%s（按 +/- 增减电脑）"
const TOAST_TEAM_FULL := "%s 已达上限（%d 人）"
const TOAST_TEAM_SWITCHED := "已加入 %s"
const TOAST_BOT_HOST_ONLY := "只有房主能增减电脑"
const TOAST_ALL_FULL := "人数已达上限（每队最多 %d 人）"
const DIFFICULTY_NAMES: Array[String] = ["简单", "普通", "困难"]

# ---------------------------------------------------------------- 其它提示
const TOAST_DROP_WEAPON := "已丢弃 %s（走到枪上可捡回）"
const TOAST_NEW_PLAYER := "有新玩家加入，踢出一个电脑腾位置"
const TOAST_NO_BUY := "本模式不能购买武器，请去出生点捡枪"
const TOAST_SHOT_FAIL := "截图失败：无法捕获画面"
const TOAST_SHOT_SAVE_FAIL := "截图失败：保存出错"
const TOAST_SHOT_SAVED := "已保存截图: %s"
const KILL_HEADSHOT := "爆头！"
const KILL_NORMAL := "击杀！"
const KILL_NOTICE_BADGE := " 击杀 "

# ---------------------------------------------------------------- 电脑（bot）昵称池
const BOT_NICKS: Array[String] = [
	"Ghost", "Viper", "Raptor", "Reaper", "Phoenix", "Falcon",
	"Cobra", "Tiger", "Wolf", "Eagle", "Onyx", "Vortex",
	"Blaze", "Shadow", "Raven", "Scorpion", "Panther", "Nova",
]
