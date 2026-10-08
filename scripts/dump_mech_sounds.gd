extends SceneTree

## 调试工具：把合成的机械声导出成 wav，方便直接在播放器里试听（不用开游戏）。
##
## 跑法：
##   godot --headless --path <项目> --script scripts/dump_mech_sounds.gd
## 输出目录会打印出来；每个名字出 3 个变体（_0/_1/_2），对应代码里的 3 份随机种子。

const OUT_DIR := "user://mech_sounds"
const NAMES := {
	"reload": "换弹",
	"reload_done": "上膛",
	"bolt": "拉栓",
	"switch": "切枪",
}


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	for k in NAMES:
		for i in 3:
			var s: AudioStreamWAV = SoundFX._mech(k)
			var p := "%s/%s_%s_%d.wav" % [OUT_DIR, NAMES[k], k, i]
			var e := s.save_to_wav(p)
			print("%s err=%d  %.2fs  %s" % [
					p, e, float(s.data.size()) / 2.0 / float(s.mix_rate),
					ProjectSettings.globalize_path(p)])
	quit()
