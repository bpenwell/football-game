extends "res://tests/visual/harness.gd"
## #402: an engine pipeline cache can coexist with a clean first-run menu.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var cache_path := "user://vulkan"
	var has_engine_cache := DirAccess.dir_exists_absolute(cache_path)
	if not has_engine_cache:
		check(DirAccess.make_dir_absolute(cache_path) == OK, "created a Vulkan cache fixture")
	check(unexpected_user_data("user://").is_empty(), "the Vulkan cache is allowed in fresh user data")
	var menu = preload("res://scenes/menu.tscn").instantiate()
	menu.set_meta("force_menu", true)
	root.add_child(menu)
	current_scene = menu
	await process_frame
	check(menu.current == "welcome" and menu.panel.is_visible_in_tree(), "fresh profile shows first-run name prompt")
	await capture("first-run-name-prompt")
	if not has_engine_cache:
		DirAccess.remove_absolute(cache_path)
	finish()
