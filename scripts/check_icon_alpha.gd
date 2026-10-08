extends SceneTree

func _init() -> void:
	for p in [
		"D:/cpan/Desktop/cs/cs-godot/models/icons/kill.png",
		"D:/cpan/Desktop/cs/cs-godot/models/icons/headshot.png",
	]:
		var img := Image.load_from_file(p)
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var opaque := 0
		var min_x := w
		var min_y := h
		var max_x := 0
		var max_y := 0
		for y in range(h):
			for x in range(w):
				if img.get_pixel(x, y).a > 0.05:
					opaque += 1
					min_x = min(min_x, x)
					min_y = min(min_y, y)
					max_x = max(max_x, x)
					max_y = max(max_y, y)
		print(p.get_file(), " size=", w, "x", h, " 不透明像素=", opaque,
			" 内容区域=(", min_x, ",", min_y, ")-(", max_x, ",", max_y, ")",
			" 内容尺寸=", max_x - min_x + 1, "x", max_y - min_y + 1)
	quit(0)
