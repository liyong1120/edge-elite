# 棱锋精英 / EDGE ELITE

基于 **Godot 4.7** 的 5v5 战术射击游戏（磐垒 CT vs 锐刃 T），支持**局域网对战**。

---

## 快速开始

1. 用 **Godot 4.7+** 打开本目录（`project.godot`）
2. 按 `F5` 运行 —— 首次打开时 Godot 会自动导入 `models/` 与 `sounds/` 下的资源，稍等片刻
3. 进入游戏后停在**局域网大厅**：
   - 自己玩：点左下「创建房间」→ 选地图 → 点「进入游戏」（会按配平公式补电脑）
   - 联机：一台机器「创建房间」，其余机器在左边列表里点「加入」

> 没有独立的开始菜单了，打开就是局域网大厅。

---

## 联机说明

- **房主就是服务器**（没有独立服务端进程），两端都跑同一份代码：
  - 电脑（bot）：**只有房主跑 AI**，客户端只显示同步过来的位置
  - 每个真人：**移动由本人那台机器算**（客户端权威，手感不吃延迟）
  - 伤害 / 死亡 / 回合 / 炸弹 / 地面武器：**全部由房主结算**，客户端只上报"谁打了谁"
- **房间发现**：UDP 广播（`27777`，同机第二份自动落到 `27787`）+ ENet 连接（`27778`）
- **同机双开**：可以开两份互相发现房间，但**键盘鼠标只会给有焦点的那个窗口**，
  所以同一台机器只能操作一个窗口（要真正两个人打得用两台电脑）

---

## 目录结构

```
cs-godot/
├── project.godot          项目配置：游戏名、输入映射、窗口尺寸、autoload
├── config.toml            运行时可调参数（机器人、玩法、画面、音效、特效、枪械数值）
├── icon.svg               应用图标
├── build.bat              一键打包：导出 exe/pck + 塞入 packaging/ + 压成 zip
├── export_presets.cfg     导出预设（本仓库的 .gitignore 忽略了它，换机器需在编辑器里重新配一次）
├── Godot版_v1.md          设计文档（GDD），玩法与数值的原始依据
├── 特别鸣谢.txt            素材授权与作者署名（游戏内大厅右下角「特别鸣谢」按钮读它）
│
├── scenes/                场景文件
│   └── main.tscn          唯一场景：游戏入口，其余内容全部由 main.gd 动态构建
│
├── scripts/               游戏逻辑（GDScript）
│   ├── main.gd            【核心】自动加载为 GM。菜单 / 建地图 / 生成玩家与电脑 / 回合流程 /
│   │                      C4 / HUD / 购买菜单 / 计分板 / 暂停 / 结算 / 联机同步
│   ├── player.gd          【核心】CSPlayer 类。移动 / 射击 / 换弹 / 后坐力 / 开镜 /
│   │                      第一人称视模型 / 弹道特效 / 小刀 / 受伤与死亡 / 网络同步
│   ├── bot.gd             电脑 AI：寻路、索敌、掩体与 peek、开火决策
│   ├── lan.gd             局域网：UDP 广播房间发现 + ENet 连接
│   ├── config_manager.gd  读取 config.toml（自动加载为 ConfigManager）
│   ├── soundfx.gd         程序化合成音效（枪声分层、机械声、受伤等）
│   ├── minimap.gd         左上角小地图绘制
│   ├── map_thumb.gd       房间界面的地图缩略图（按障碍物现画俯视图）
│   ├── crosshair.gd       准星绘制与动态扩散
│   ├── tracer2d.gd        屏幕空间曳光
│   ├── ui_theme.gd        配色唯一入口（想整体换色只改这里）
│   ├── ui_text.gd         文案唯一入口（所有按钮/标题/提示/toast/HUD 文本）
│   ├── weapon_icons.gd    武器图标离屏渲染工具
│   ├── dump_mech_sounds.gd 机械音试听工具（导出到 user://）
│   └── check_icon_alpha*.gd / fix_icon_transparency.gd
│                          一次性工具脚本：检查/修复图标透明度（开发期用过，可忽略）
│
├── weapons/               武器数值
│   └── database.gd        WeaponDatabase：17 把武器的伤害/射速/弹匣/价格/后坐力等
│
├── models/                3D 模型与相关文档
│   ├── fpv/               第一人称武器模型（17 把 .glb，文件名 = 武器 ID）
│   ├── characters/        角色模型：player.glb（磐垒）、t_player.glb（锐刃），带骨骼与动画
│   ├── icons/             HUD 图标（击杀、爆头等）
│   ├── 素材规格清单.md      模型规格与 AI 生成提示词
│   └── 素材生成操作手册.md  素材生成 / 归一化 / 验收的完整流程
│
├── sounds/                音效（.wav）
│   ├── shoot / step / jump / land / explode.wav        基础音效
│   ├── knife_swing / knife_hit / knife_wall.wav        小刀：挥空 / 刺中 / 划墙
│   ├── mech_reload / mech_reload_done / mech_bolt / mech_switch.wav   机械声真实录音
│   └── LICENSE.md         素材授权说明
│
├── resources/             运行时资源
│   └── menu_bg.png        菜单背景图
│
├── packaging/             打包时一起塞进发布包的文件
│   └── 使用说明.txt        给玩家的说明（双击 build.bat 会拷进 zip）
│
├── tools/                 开发辅助脚本（不参与游戏运行）
│   ├── glb_check.py       素材自检：面数/尺寸/朝向/材质/贴图
│   ├── build_weapons.py   参数化建模器：用 Blender 脚本生成 17 把低模武器
│   ├── render_weapons.py  预览渲染器：把武器排成目录图渲染 PNG
│   ├── normalize_glb.py   尺寸归一化 + 减面：把任意来源的 GLB 校正到规格尺寸
│   ├── gen_assets.py      AI 文生 3D 批量生成器（需云端凭据）
│   └── gen_knife_sounds.py 程序化合成小刀音效
│
└── tests/                 测试脚本目录（当前为空）
```

---

## 操作

| 按键 | 功能 | | 按键 | 功能 |
|------|------|-|------|------|
| `WASD` | 移动 | | `1`-`5` | 切枪 |
| `Shift` | 静步（无声） | | `G` | 丢枪 |
| `Ctrl` | 蹲下 | | `B` | 购买菜单 |
| `空格` | 跳跃 | | `Tab` | 计分板 |
| 鼠标左键 | 射击 | | `ESC` | 暂停 / 返回 |
| 鼠标右键 | 开镜 | | `P` | 截图 |
| `R` | 换弹 | | `+` / `-` | 增减电脑（**只有房主能用**） |

---

## 常用配置

改 `config.toml` 后重启游戏生效（注释写得很详细，逐项都有说明）：

| 段 | 作用 |
|----|------|
| `[bot]` | `can_attack = false` 可让电脑只移动不开火，方便观察地图和模型 |
| `[gameplay]` | 回合时长、购买时长、C4 倒计时 |
| `[graphics]` | FOV、鼠标灵敏度、是否显示自己的身体模型 |
| `[audio]` | 主音量 / 音效 / 音乐 |
| `[effects]` | 曳光粗细亮度、弹孔、血溅参数 |
| `[weapons]` | 覆盖武器数值，如 `AK47_damage = 45` |

---

## 打包成 exe

双击 **`build.bat`** 即可（需要先装 Godot 4.7.1 的导出模板）。
产物：`build/EdgeElite_win64.zip`，解压后 `EdgeElite.exe` 与 `EdgeElite.pck` 必须放在同一目录。

---

## 素材说明

武器模型是**参数化建模**生成的（`tools/build_weapons.py`），每把 88~380 三角面，
枪口朝 −Z、原点在握把、材质按 `mat_{型号}_{部位}` 命名。

想换成更精细的模型（例如用 AI 图生 3D 出的带贴图高模）：

1. 按 `models/素材规格清单.md` 生成参考图与 GLB
2. 用 `tools/normalize_glb.py` 把尺寸校正到规格值
3. 按 `models/fpv/{武器ID}.glb` 命名覆盖
4. 跑 `python tools/glb_check.py` 验收

游戏代码按文件名加载模型（`player.gd` 的 `_load_fpv_model`），
**放入即生效，无需改代码**；朝向、缩放、原点都会由 `_fit_viewmodel()` 自动适配。

角色模型、机械声录音等第三方素材的作者与许可见 **`特别鸣谢.txt`**（也在游戏内可查看）。

---

## 开发工具用法

```bash
# 素材自检
python tools/glb_check.py

# 重新生成 17 把武器（约 30 秒，零依赖）
blender --background --factory-startup --python tools/build_weapons.py -- \
  --all --out "models/fpv"

# 渲染武器目录图
blender --background --factory-startup --python tools/render_weapons.py -- \
  --both --out "screenshots/武器总览.png"

# 把外部 GLB 归一化到规格尺寸
blender --background --factory-startup --python tools/normalize_glb.py -- \
  --in-dir "下载目录" --out-dir "models/fpv" --decimate 600

# 重新合成小刀音效
python tools/gen_knife_sounds.py
```

---

## 技术要点

- **第一人称视模型自动适配**：`player.gd:_fit_viewmodel()` 会忽略模型自带变换、
  测包围盒、判断枪口朝向并转到相机前方 −Z、缩放到 0.73m、居中。
  因此任意来源的模型放入即可用，不需要在 Blender 里手工校正。
- **程序化动作**：武器模型没有骨骼，换弹 / 挥刀动作是用「对视模型根节点叠加位移与旋转」
  实现的（`_reload_pose()` / `_knife_pose()`）。
- **程序化音效**：`soundfx.gd` 与 `tools/gen_knife_sounds.py` 直接合成波形；
  机械声若在 `sounds/` 下放了同名录音会优先用录音。
- **弹道特效**：
  - 曳光用**屏幕空间画线**（`scripts/tracer2d.gd`），从枪口屏幕位置沿真实弹道飞向命中点。
    不用 3D 物体是因为第一人称下弹道几乎与视线平行，3D 短棒投影到屏幕上只剩几个像素。
  - 枪口火焰用星形加性面片 + 短时点光。
  - 联机时开火会广播，别的机器在**世界空间**重放火光 / 曳光 / 血雾。
- **局域网同步**：房主广播开局名单，两端按同一份名单建同名同路径的角色节点，
  再用 `MultiplayerSynchronizer` 同步位置 / 朝向 / 血量 / 生死 / 动画状态；
  伤害走房主结算（只信"谁打谁 + 什么枪 + 是否爆头"）。

---

## 开源协议

本项目代码采用 **MIT 协议**，详见 [LICENSE](LICENSE)。

⚠️ `models/` 与 `sounds/` 下的**第三方素材**（角色模型、机械声录音等）**不在 MIT 范围内**，
各自遵循原作者的授权（CC-BY / CC0 等），作者与来源见 [`特别鸣谢.txt`](特别鸣谢.txt)
（游戏内大厅右下角「特别鸣谢」按钮也能查看）。
