extends "res://tests/visual/harness.gd"
## #360: a diving receiver reaches for the ball where it is. The near arm points at the
## ball and the chest rolls toward it, for a pass to the left, to the right and high, live
## and in a replay.

const CASES := [
	# name, ball offset from the receiver (field x, y, height), near hand
	["dive-reach-left", Vector3(-0.8, 0.9, 0.6), "hand_l"],
	["dive-reach-right", Vector3(0.8, 0.9, 0.6), "hand_r"],
	["dive-reach-high", Vector3(0.0, 0.8, 1.5), "hand_r"],
	# A replay drives the view from the recorded dive and catch bits (#393), not the live sim.
	["dive-reach-replay", Vector3(0.8, 0.9, 0.6), "hand_r"],
]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var game = preload("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.opening_kickoff = false
	game.configure(3)
	game.auto_next = false
	game.pov_enabled = false
	game.set_physics_process(false)
	game.set_process(false)
	game.series.start(0, 25.0)
	game.set_controlled(game.my_id)
	_key(game, KEY_SPACE)
	var world = game.world
	var qb = world.carrier()
	check(qb != null, "Space snaps to the QB")
	if qb == null:
		finish()
		return
	var receiver = world.find_role(0, game.Athlete.Role.WR)
	for athlete in world.athletes:
		athlete.position = Vector2(25.0, 60.0 + athlete.id * 2.0)
	qb.position = Vector2(10, 20)
	receiver.position = Vector2(10, 36)
	receiver.facing = Vector2(0, 1)
	game.aim_point = receiver.position
	_key(game, KEY_J)
	check(world.forward_pass_thrown, "J releases a live pass")
	game.set_controlled(receiver.id)
	_key(game, KEY_F)
	check(receiver.is_diving(), "F starts the receiver dive")
	var player = game.views[receiver.id]
	var sk: Skeleton3D = player._skel
	for c in CASES:
		# Frozen at a descending pass coming back to the receiver, inside the catch lead window.
		world.ball.position = Vector3(10.0, 36.0, 0.0) + c[1]
		world.ball.velocity = Vector3(0.0, -12.0, -3.0)
		game._render()
		for view in game.views:
			view.interpolate(1.0)
		if c[0] == "dive-reach-replay":   # after _render: sync() clears the replay bits
			receiver.dive_t = 0.0
			player.replay_flags = game.Replay.F_DIVING | game.Replay.F_CATCH
		game.camera.global_position = player.global_position + Vector3(3.5, 1.9, -2.3)
		game.camera.look_at(player.global_position + Vector3(0, 0.6, -0.4))
		player.anim.play()
		for frame in 30:
			await process_frame
		player.anim.seek(0.26, true)
		player.anim.pause()
		# Godot restores the clip pose after the modifiers run: read the bones as the pose layer leaves them.
		var got := {}
		var grab := func() -> void:
			for b in ["upperarm" + c[2].substr(4), c[2], "spine_02", "spine_03", "neck_01"]:
				got[b] = sk.get_bone_global_pose(sk.find_bone(b))
		player.pose.modification_processed.connect(grab, CONNECT_ONE_SHOT)
		await process_frame
		await process_frame
		check(player.pose.catch_weight > 0.9 and player.pose.catch_dive > 0.9 and not got.is_empty(), "%s: diving reach is on" % c[0])
		if got.is_empty():
			continue
		var ball: Vector3 = sk.global_transform.affine_inverse() * game.ball_view.global_position
		var u: Vector3 = got["upperarm" + c[2].substr(4)].origin
		var h: Vector3 = got[c[2]].origin
		var aim := (h - u).normalized().dot((ball - u).normalized())
		check(aim > 0.8, "%s: near arm points at the ball (cos %.2f)" % [c[0], aim])
		# The chest's front, seen down the spine, within 45 deg of the ball (the clip's slide faces the sky).
		var spine: Vector3 = (got.neck_01.origin - got.spine_02.origin).normalized()
		var front: Vector3 = got.spine_03.basis.z
		var to: Vector3 = ball - got.spine_02.origin
		var off := rad_to_deg((front - spine * front.dot(spine)).angle_to(to - spine * to.dot(spine)))
		check(off < 45.0, "%s: chest rolls toward the ball (%.0f deg off)" % [c[0], off])
		await capture(c[0])
	finish()

func _key(game, code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	game._unhandled_key_input(event)
