extends SceneTree

func _init() -> void:
	for p in [
		"D:/cpan/Desktop/cs/cs-godot/models/icons/kill.png",
	]:
		var img := Image.load_from_file(p)
		var fmt := img.get_format()
		print(p.get_file(), " format=", fmt, " (0=RGBA8? ", fmt == Image.FORMAT_RGBA8, ")")
		# 不看 convert！直接读原始
		var w := img.get_width()
		var h := img.get_height()
		var a0 := 0
		var a_mid := 0
		var a_max := 0
		for y in range(h):
			for x in range(w):
				var a: float = img.get_pixel(x, y).a
				if a < 0.01: a0 += 1
				elif a < 0.5: a_mid += 1
				else: a_max += 1
		print("  alpha<0.01:", a0, "  0.01~0.5:", a_mid, "  >0.5:", a_max)
	quit(0)