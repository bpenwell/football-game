extends SceneTree
## Call after asserting the behavior. Wait until the viewport has rendered it.
var failures := 0

func _init() -> void:
	# visual_test.sh gives every case a fresh user:// (#236): nothing an earlier case saved,
	# whatever the order, may be here when this one starts.
	var leftovers := unexpected_user_data("user://")
	check(leftovers.is_empty(), "case starts with empty user data %s" % [leftovers])

static func unexpected_user_data(path: String) -> PackedStringArray:
	var leftovers := DirAccess.get_files_at(path)
	for directory in DirAccess.get_directories_at(path):
		if directory not in ["logs", "shader_cache", "vulkan"]:   # Godot's own output directories
			leftovers.append(directory)
	return leftovers

func check(condition: bool, message: String) -> void:
	print(("VISUAL OK " if condition else "VISUAL FAIL ") + message)
	if not condition:
		failures += 1

func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var path := OS.get_environment("VISUAL_CASE_OUTPUT").path_join(name + ".png")
	var image := root.get_texture().get_image()
	check(image != null and not image.is_empty() and image.save_png(path) == OK, "capture " + path)

func finish() -> void:
	quit(0 if failures == 0 else 1)
