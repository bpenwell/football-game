extends "res://tests/visual/harness.gd"
## #455: the Moon Hop celebration bounces with a fist pump. It used to loop the Jump clip,
## which holds both arms straight out to the sides (a T-pose at the top of each hop).
## One athlete in its own world, the clip paused at a fixed time: no frame-count dependence.

const PlayerView := preload("res://src/game/player.gd")
const Athlete := preload("res://src/sim/athlete.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var box := SubViewportContainer.new()
	box.custom_minimum_size = Vector2i(640, 640)
	box.stretch = true
	root.add_child(box)
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(640, 640)
	box.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.11, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.75)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 35, 0)
	vp.add_child(sun)
	var a := Athlete.new()
	a.role = Athlete.Role.WR
	var v := PlayerView.new()
	v.setup(a, Color(0.8, 0.2, 0.2))
	vp.add_child(v)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0.6, 1.4, -3.4), Vector3(0, 1.1, 0))
	v.set_process(false)   # no sim here: drive the clip choice directly, then hold a frame
	v.celebrate("hop")
	v._choose_anim(0.0, false)
	check(v._cur == v.HOP_CLIP, "the hop plays the fist pump (%s)" % v._cur)   # arms measured in test_athlete_pose.gd
	v.anim.advance(0.3)   # past the cross-fade: pausing mid-blend would freeze it on the old clip
	v.anim.seek(0.6, true)
	v.anim.pause()
	for i in 3:
		await process_frame
	await capture("moon-hop")
	finish()
