extends "res://tests/visual/harness.gd"
## #298: Start opens the pause menu and Controls shows the button and trigger reference.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var game = preload("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.auto_next = false
	game.opening_kickoff = false
	game.series.start(0, 30.0)
	game.set_controlled(game.my_id)
	game.set_physics_process(false)
	game.set_process(false)
	game._render()
	game.camera.look_at_from_position(Vector3(0, 14, 12), Vector3.ZERO, Vector3.UP)
	var launch = root.get_node("/root/Launch")
	var start := InputEventJoypadButton.new()
	start.button_index = JOY_BUTTON_START
	start.pressed = true
	root.push_input(start)
	check(launch.overlay_open(), "Start opens the pause menu")
	if not launch.overlay_open():
		finish()
		return
	for i in 3:
		await process_frame
	await capture("pause-menu")

	var button: Button = launch._overlay.find_child("ControlsButton", true, false)
	button.pressed.emit()
	for i in 3:
		await process_frame
	var notes: Label = launch._overlay.find_child("ControlsNotes", true, false)
	for hint in ["LB  Show scoreboard", "RB  Lob modifier", "L3 / LT  Sprint",
			"Back  Instant replay", "D-pad up  Next play", "D-pad down  Dash",
			"D-pad left  Extra point", "D-pad right  Two-point try", "Start  Pause menu"]:
		check(notes.text.contains(hint), "Controls shows " + hint)
	check(root.get_visible_rect().encloses(notes.get_global_rect()), "gamepad help fits on screen")
	var controls_help: VBoxContainer = notes.get_parent()
	check(root.get_visible_rect().encloses(controls_help.get_global_rect()), "keyboard and gamepad help both fit")
	await capture("pause-gamepad-help")
	finish()
