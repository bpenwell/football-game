extends "res://tests/flow/segment.gd"
## #298: open Controls through the real Start input and check the controller help.

func steps() -> Array:
	return [[2, _check_gamepad_controls]]

func _check_gamepad_controls() -> void:
	var previous_scene: Node = flow.current_scene
	flow.current_scene = main
	var launch: Node = flow.root.get_node("Launch")
	var start := InputEventJoypadButton.new()
	start.button_index = JOY_BUTTON_START
	start.pressed = true
	flow.root.push_input(start)
	check(launch.overlay_open(), "Start opens the in-match menu")
	if launch.overlay_open():
		var button: Button = launch._overlay.find_child("ControlsButton", true, false)
		button.pressed.emit()
		var notes: Label = launch._overlay.find_child("ControlsNotes", true, false)
		check(notes != null and notes.text.contains("D-pad down  Dash"), "Controls shows the controller dash button")
		flow.root.push_input(start)
		check(not launch.overlay_open(), "Start closes the in-match menu")
	flow.current_scene = previous_scene
