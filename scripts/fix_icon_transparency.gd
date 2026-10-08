extends SceneTree

func _is_bg(c: Color) -> bool:
	if c.a < 0.5:
		return true
	var is_black: bool = c.r < 12.0 / 255.0 and c.g < 12.0 / 255.0 and c.b < 12.0 / 255.0
	var is_gray: bool = absf(c.r - c.g) < 8.0 / 255.0 and absf(c.g - c.b) < 8.0 / 255.0 and c.r > 80.0 / 255.0 and c.r < 155.0 / 255.0
	return is_black or is_gray

func _init2() -> void:
	for p in [
		"D:/cpan/Desktop/cs/cs-godot/models/icons/kill.png",
		"D:/cpan/Desktop/cs/cs-godot/models/icons/headshot.png",
	]:
		var img := Image.load_from_file(p)
		if img.is_empty():
			printerr(p, " load fail")
			continue
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var cleared := 0
		var kept := 0
		for y in range(h):
			for x in range(w):
				var c := img.get_pixel(x, y)
				if _is_bg(c):
					img.set_pixel(x, y, Color(0, 0, 0, 0))
					cleared += 1
				else:
					kept += 1
		var err := img.save_png(p)
		print(p.get_file(), " cleared=", cleared, " kept=", kept, " err=", err)
	quit(0)