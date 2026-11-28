extends "res://tests/test_case.gd"
## The rendered harness accepts engine output directories and catches leaked fixture data.

const Harness := preload("res://tests/visual/harness.gd")

func test_visual_guard_skips_only_engine_directories() -> void:
	var fixture := "user://test_visual_guard"
	var vulkan := fixture.path_join("vulkan")
	var engine_dirs := ["logs", "shader_cache", "vulkan"]
	for directory in engine_dirs:
		assert_eq(DirAccess.make_dir_recursive_absolute(fixture.path_join(directory)), OK, "create " + directory)
	assert_true(Harness.unexpected_user_data(fixture).is_empty(), "all three engine directories are allowed")

	var settings := fixture.path_join("settings.cfg")
	var replays := fixture.path_join("replays")
	assert_eq(DirAccess.remove_absolute(vulkan), OK, "remove the empty cache directory")
	assert_true(FileAccess.open(vulkan, FileAccess.WRITE) != null, "plant a file named vulkan")
	assert_true(FileAccess.open(settings, FileAccess.WRITE) != null, "plant a settings file")
	assert_eq(DirAccess.make_dir_absolute(replays), OK, "plant a replay directory")
	assert_eq(Harness.unexpected_user_data(fixture), PackedStringArray(["settings.cfg", "vulkan", "replays"]),
		"stray files and directories, including a file with a reserved name, are reported")

	for path in [settings, vulkan, replays, fixture.path_join("logs"), fixture.path_join("shader_cache"), fixture]:
		DirAccess.remove_absolute(path)

func test_harness_runs() -> void:
	assert_eq(1 + 1, 2, "math")
