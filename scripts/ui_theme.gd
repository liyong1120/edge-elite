class_name UITheme
extends RefCounted

## ============================================================ 全局主题配色
##
## ★★★ 想换整套 UI 的配色，只改这一个文件 ★★★
##
## 所有界面的颜色都从这里取：大厅 / 房间 / 购买 / 暂停 / 整场结束 / 计分板 /
## HUD / 击杀信息流 / 小地图。改完不用再去别的文件里翻颜色。
##
## 这里**没有**的（属于"语义色"，跟主题无关，别为了换主题去动它们）：
##   · 阵营色（磐垒蓝 / 锐刃红）  → main.gd 的 `TEAMS` 表
##   · 准星绿                     → crosshair.gd 的 `CROSS_*`
##   · 血雾 / 爆炸 / 曳光 / 枪口火光 → player.gd
##   · 地图材质（雪地 / 石块 / 砖墙 / 木箱）→ main.gd 的 `_make_*_texture`
##
## 2026-09-30：整体由「金色暖调」改成「科技蓝」（用户要求，参考星际争霸 1 那种统一色调）。

# ---------------------------------------------------------------- 底色 / 面板
const BG := Color(0.03, 0.045, 0.07, 1.0)            # 没有主视觉图时的兜底底色
const CARD := Color(0.04, 0.06, 0.10, 0.90)          # 卡片底
const CARD_EDGE := Color(0.24, 0.48, 0.72, 0.50)     # 卡片描边
const PANEL := Color(0.05, 0.07, 0.11, 0.90)         # HUD 条 / 浮层底
const PANEL_EDGE := Color(0.30, 0.55, 0.90, 0.45)    # HUD 条描边
const MODAL := Color(0.045, 0.06, 0.10, 0.96)        # 全屏大面板底（计分板 / 地图弹层）
const MODAL_DIM := Color(0.02, 0.02, 0.04, 0.85)     # 计分板背后的压暗层

# ---------------------------------------------------------------- 强调色（整套 UI 的主色）
const ACCENT := Color(0.36, 0.82, 1.0)               # 主强调（亮青蓝）
const ACCENT_DIM := Color(0.20, 0.56, 0.86)          # 次级强调（细线 / 竖条 / 描边）
const ACCENT_HOVER := Color(0.42, 0.80, 1.0)         # 强调色悬停
const CTA := Color(0.20, 0.62, 0.96)                 # 主按钮底
const CTA_HOVER := Color(0.36, 0.76, 1.0)
const CTA_DOWN := Color(0.10, 0.42, 0.70)
const CTA_EDGE := Color(0.70, 0.92, 1.0, 0.90)       # 主按钮描边
const CTA_GLOW := Color(0.20, 0.62, 1.0, 0.34)       # 主按钮外发光
const SEG_ON := Color(0.24, 0.66, 0.98)              # 分段控件「选中」底
const SEG_EDGE := Color(0.76, 0.94, 1.0, 0.95)       # 分段控件「选中」描边
const ON_ACCENT := Color(0.02, 0.07, 0.14)           # 压在强调色上的深色字
const ON_ACCENT_DIM := Color(0.01, 0.04, 0.09)       # 压在强调色上的深色字（按下）

# ---------------------------------------------------------------- 文字
const TEXT := Color(0.90, 0.95, 1.0)                 # 主文字
const TEXT_DIM := Color(0.62, 0.74, 0.88)            # 次要文字
const TEXT_SOFT := Color(0.75, 0.90, 1.0)            # 表头
const TEXT_FAINT := Color(0.60, 0.62, 0.72)          # 底部说明 / 弱化文字
const TEXT_MUTED := Color(0.55, 0.58, 0.65)          # 更弱的说明
const TEXT_HUD := Color(0.90, 0.95, 1.0, 0.85)       # HUD 剩余时间那行
const OUTLINE := Color(0.02, 0.06, 0.12, 0.95)       # 大字描边（深海军蓝）
const OUTLINE_SOFT := Color(0.02, 0.06, 0.12, 0.90)
const OUTLINE_HUD := Color(0.02, 0.05, 0.10, 0.95)   # HUD 小字描边
const OUTLINE_MID := Color(0.04, 0.05, 0.08)         # 屏幕中央提示的描边
const OUTLINE_SCORE := Color(0.05, 0.06, 0.10, 1.0)  # 比分数字描边
const OUTLINE_ACCENT := Color(0.06, 0.04, 0.01, 1.0) # 强调色大字描边（比分条中间那个数）

# 阵营文字色（比阵营本色亮一档，压在深色面板上更清楚）
const TEAM_CT_TEXT := Color(0.45, 0.72, 1.0)
const TEAM_T_TEXT := Color(1.0, 0.55, 0.35)

# ---------------------------------------------------------------- 组件
const FRAME := Color(0.30, 0.68, 0.95, 0.40)         # 屏幕内框
const GHOST_BG := Color(0.10, 0.14, 0.20, 0.85)      # 幽灵按钮悬停底
const GHOST_EDGE := Color(0.36, 0.45, 0.60, 0.70)    # 幽灵按钮常态描边
const TRACK_BG := Color(0.05, 0.07, 0.11, 0.85)      # 难度分段控件轨道底
const TRACK_EDGE := Color(0.30, 0.38, 0.52, 0.70)
const TRACK_HOVER := Color(0.20, 0.26, 0.36, 0.70)   # 未选中段悬停底
const SEP_LINE := Color(0.30, 0.55, 0.90, 0.50)      # 计分板分割线
const BAR_BG := Color(0.05, 0.06, 0.10, 0.85)        # 换弹/安包进度条底
const BAR_EDGE := Color(1.0, 1.0, 1.0, 0.25)
const SHADOW := Color(0, 0, 0, 0.60)                 # 面板投影

# 名册行
const ROW_BG := Color(0.10, 0.13, 0.19, 0.88)        # 真人行底
const ROW_BG_FAINT := Color(0.07, 0.09, 0.13, 0.55)  # 电脑/空位行底
const ROW_EDGE := Color(0.30, 0.38, 0.52, 0.40)
const AVATAR_BOT := Color(0.32, 0.36, 0.44, 0.75)    # 电脑头像底
const AVATAR_TEXT := Color(0.80, 0.85, 0.92)         # 电脑头像里的字
const TAG_PLAYER := Color(0.42, 0.68, 1.0)           # 「玩家」身份胶囊

# 计分板
const RANK_1 := Color(0.42, 0.86, 1.0)
const RANK_2 := Color(0.76, 0.88, 1.0)
const RANK_3 := Color(0.56, 0.72, 0.92)
const RANK_OTHER := Color(0.62, 0.68, 0.78)
const ALIVE_DOT := Color(0.40, 0.92, 0.50)           # 存活（绿=活，语义色）
const DEAD_DOT := Color(0.42, 0.45, 0.52)
const DEAD_TEXT := Color(0.55, 0.55, 0.55)
const SELF_ROW_BG := Color(0.36, 0.82, 1.0, 0.14)    # 自己那一行的淡色底

# 购买菜单
const BUY_BG := Color(0.09, 0.12, 0.17, 0.95)
const BUY_EDGE := Color(0.36, 0.45, 0.60, 0.70)
const BUY_HOVER_BG := Color(0.15, 0.18, 0.24, 0.98)
const BUY_DOWN_BG := Color(0.06, 0.08, 0.12, 1.0)
const MONEY_TEXT := Color(0.90, 0.90, 0.50)
const OK_TEXT := Color(0.60, 0.90, 0.65)
const HINT_TEXT := Color(0.70, 0.70, 0.80)
const LOCKED_MODULATE := Color(0.80, 0.80, 0.80)

# 踢人按钮（红=语义色，但按钮形态属于组件）
const KICK_BG := Color(0.52, 0.15, 0.12, 0.35)
const KICK_EDGE := Color(0.95, 0.42, 0.34, 0.70)
const KICK_HOVER_BG := Color(0.78, 0.22, 0.16, 0.65)
const KICK_TEXT := Color(1.0, 0.58, 0.48)
const KICK_TEXT_HOVER := Color(1.0, 0.88, 0.84)

# 告警（时间告急等，语义红）
const WARN_TEXT := Color(1.0, 0.20, 0.20)

# ---------------------------------------------------------------- 主视觉遮罩
const SCRIM_TOP := Color(0.02, 0.03, 0.06, 0.22)     # 背景图上边缘
const SCRIM_BOTTOM := Color(0.01, 0.015, 0.03, 0.72) # 背景图下边缘
const SCRIM_LEFT := Color(0.01, 0.015, 0.03, 0.80)   # 背景图左边缘
const SCRIM_RIGHT := Color(0.01, 0.015, 0.03, 0.05)  # 背景图右边缘（几乎不压，露出主视觉）

# ---------------------------------------------------------------- 阵营色
# 名字在 ui_text.gd 的 TEAM_NAME / TEAM_NAME_FULL
const TEAM_COLOR := {
	"CT": Color(0.30, 0.62, 0.95),
	"T": Color(0.92, 0.42, 0.32),
}

# ---------------------------------------------------------------- 准星
# 绿色（用户指定）：在雪地 / 米黄石材上辨识度最高，别随便换成主题蓝
const CROSSHAIR := Color(0.25, 1.0, 0.25, 0.95)

# ---------------------------------------------------------------- 小地图（雷达）
const RADAR_BG := Color(0.03, 0.06, 0.10, 0.82)
const RADAR_RING := Color(0.50, 0.80, 1.00, 0.60)
const RADAR_WALL_FILL := Color(0.55, 0.75, 0.95, 0.26)
const RADAR_WALL_LINE := Color(0.72, 0.90, 1.00, 0.80)
const RADAR_ALLY := Color(0.35, 0.95, 0.40, 0.95)    # 友军（绿，语义色）
const RADAR_ENEMY := Color(1.00, 0.30, 0.28, 0.95)   # 敌军（红，语义色）
