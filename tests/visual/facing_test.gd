extends "res://tests/visual/harness.gd"
## #423: a receiver who reverses turns his body over several frames, not in one.
## #422: once he stops, his facing holds still (it used to flip every frame).
## The render loop runs one physics tick per frame, the worst case for #422.

const RUN_TICKS := 40       # running across the field
const TURN_TICKS := 3       # into the reversal: capture mid-turn
const STAND_TICKS := 60     # stopped
const STILL_FROM := 40      # the turn he stopped in has finished by then (TURN_K)

var game
var cam: Camera3D

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	game = preload("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.opening_kickoff = false
	game.auto_next = false
	game.auto_replay = false
	game.pov_enabled = false
	game.ai.defense_enabled = false
	game.ai.offense_enabled = false
	game.series.start(0)
	game.set_controlled(game.my_id)
	game.input_override = Vector2.ZERO
	await physics_frame
	_key(KEY_SPACE)
	var world = game.world
	check(world.phase == game.World.Phase.LIVE, "Space snaps")
	var wr = world.find_role(0, game.Athlete.Role.WR)
	game.set_controlled(wr.id)
	var view = game.views[wr.id]
	cam = Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	game.input_override = Vector2(1, 0)
	for i in RUN_TICKS:
		await _frame(view)
	var before: float = view.rotation.y
	check(absf(angle_difference(before, atan2(-1.0, 0.0))) < deg_to_rad(10.0), "running +x, he faces +x (%.0f deg)" % rad_to_deg(before))
	game.input_override = Vector2(-1, 0)
	var worst := 0.0
	var last := before
	for i in TURN_TICKS:
		await _frame(view)
		worst = maxf(worst, absf(angle_difference(last, view.rotation.y)))
		last = view.rotation.y
	var turned := absf(angle_difference(before, view.rotation.y))
	check(turned > deg_to_rad(20.0) and turned < deg_to_rad(160.0), "mid-reversal the body is part way round: %.0f deg" % rad_to_deg(turned))
	check(worst < deg_to_rad(45.0), "no frame turns more than 45 deg: worst %.0f" % rad_to_deg(worst))
	await capture("facing-mid-turn")
	# Stop one tick into another reversal: the drawn facing is between two targets there,
	# which is what used to feed back into itself.
	game.input_override = Vector2(1, 0)
	for i in RUN_TICKS:
		await _frame(view)
	game.input_override = Vector2(-1, 0)
	await _frame(view)
	game.input_override = Vector2.ZERO
	last = view.rotation.y
	var shake := 0.0
	for i in STAND_TICKS:
		await _frame(view)
		if i >= STILL_FROM:
			shake = maxf(shake, absf(angle_difference(last, view.rotation.y)))
		last = view.rotation.y
	check(shake < 0.002, "standing, the facing holds still: worst %.4f rad per frame" % shake)
	await capture("facing-standing")
	finish()

## One physics tick and its frame, the camera beside the receiver.
func _frame(view) -> void:
	await physics_frame
	cam.global_position = view.global_position + Vector3(0.0, 1.8, 4.5)
	cam.look_at(view.global_position + Vector3.UP * 0.9)
	cam.make_current()
	await process_frame

func _key(code: int) -> void:
	var input := InputEventKey.new()
	input.keycode = code
	input.pressed = true
	game._unhandled_key_input(input)
