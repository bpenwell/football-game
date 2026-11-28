extends "res://tests/test_case.gd"
## View-layer perf contracts that can be checked without a GPU.
## Scene-wide budgets (triangles, draw objects, shadow casters) live in tests/render_budget.gd.

const RC := preload("res://src/game/render_cache.gd")
const PlayerNode := preload("res://src/game/player.gd")
const CharacterArt := preload("res://src/game/art/character_art.gd")
const Uniforms := preload("res://src/game/art/football_uniforms.gd")
const Athlete := preload("res://src/sim/athlete.gd")
const Tick := preload("res://src/sim/tick.gd")

func test_cache_shares_meshes_and_materials() -> void:
	assert_true(RC.sphere(0.3) == RC.sphere(0.3), "same sphere key -> same mesh")
	assert_true(RC.capsule(0.4, 1.9) == RC.capsule(0.4, 1.9), "same capsule key -> same mesh")
	assert_true(RC.mat(Color.RED) == RC.mat(Color.RED), "same color -> same material")
	assert_true(RC.mat(Color.RED) != RC.mat(Color.RED, true), "unshaded is a different material")

func test_cached_primitives_are_low_poly() -> void:
	# Godot defaults: SphereMesh ~4k tris, CapsuleMesh ~2.3k. Low-poly art keeps these tiny.
	assert_true(RC.triangles(RC.sphere(0.28, 0.5)) <= 200, "sphere tris %d" % RC.triangles(RC.sphere(0.28, 0.5)))
	assert_true(RC.triangles(RC.capsule(0.4, 1.9)) <= 250, "capsule tris %d" % RC.triangles(RC.capsule(0.4, 1.9)))
	assert_true(RC.triangles(RC.torus(0.6, 0.8)) <= 300, "torus tris %d" % RC.triangles(RC.torus(0.6, 0.8)))

func test_skinned_uniforms_share_animation_cull_margin() -> void:
	var model := CharacterArt.instance()
	var local_mesh := CharacterArt.find_mesh(model)
	CharacterArt.dress_mesh(local_mesh)
	var opponent_mesh := Uniforms.opponent_mesh(local_mesh)
	assert_true(local_mesh.extra_cull_margin > 0.0, "animated home body expands its rest bounds")
	assert_eq(opponent_mesh.extra_cull_margin, local_mesh.extra_cull_margin,
		"both uniforms on the shared rig use the animation margin")
	model.free()

func test_view_interpolates_between_ticks() -> void:
	var v := PlayerNode.new()
	v.place(Vector3(10, 0, -20), 0.0)
	v.place(Vector3(10.2, 0, -20), 0.0)
	v.interpolate(0.5)
	assert_near(v.position.x, 10.1, 0.0001, "halfway between ticks")
	v.interpolate(1.0)
	assert_near(v.position.x, 10.2, 0.0001, "f=1 -> latest tick")
	assert_eq(v.target_position(), Vector3(10.2, 0, -20), "target is the latest sim pose")
	v.free()

func test_view_snaps_on_teleport() -> void:
	var v := PlayerNode.new()
	v.place(Vector3(10, 0, -20), 0.0)
	v.place(Vector3(30, 0, -60), 0.0)   # new formation: must not glide across the field
	v.interpolate(0.0)
	assert_near(v.position.x, 30.0, 0.0001, "teleport snaps")
	v.free()

func test_yaw_interpolates_the_short_way() -> void:
	var v := PlayerNode.new()
	v.place(Vector3.ZERO, PI - 0.1)
	v.place(Vector3(0.1, 0, 0), -PI + 0.1)
	v.interpolate(0.5)
	# The second target is already turned TURN_K's share of the way (#423), across PI.
	var target := PI - 0.1 + 0.2 * (1.0 - exp(-PlayerNode.TURN_K * Tick.DT))
	assert_true(absf(angle_difference(v.rotation.y, PI - 0.1 + (target - (PI - 0.1)) * 0.5)) < 0.01,
		"wraps through PI, not through 0 (%.2f)" % v.rotation.y)
	v.place(Vector3.ZERO, 0.0, false)
	v.place(Vector3(0.1, 0, 0), PI - 0.1, false)
	v.interpolate(0.5)
	assert_near(v.rotation.y, (PI - 0.1) * 0.5, 0.01, "unsmoothed (replay) targets interpolate as given")
	v.free()

## #422: a view whose athlete has stopped holds its facing. sync() used to read the drawn
## (interpolated) rotation back as the next target, so a standing player flipped every frame.
func test_standing_view_holds_its_facing() -> void:
	var v = _synced_view()
	v.athlete.velocity = Vector2(4.0, 0.0)   # a turn to the side, then stop
	_tick(v, 0.0)
	v.athlete.velocity = Vector2.ZERO
	var worst := 0.0
	var last: float = v.rotation.y
	for i in 40:
		_tick(v, 0.0)   # worst case: drawn right at the tick (f = 0)
		if i >= 20:
			worst = maxf(worst, absf(angle_difference(last, v.rotation.y)))
		last = v.rotation.y
	assert_true(worst < 0.002, "standing still, the facing settles: worst %.4f rad per frame" % worst)
	assert_near(v.rotation.y, atan2(-4.0, 0.0), 0.02, "and finishes the turn it started")
	v.free()

## #423: a reversal turns the drawn facing over several ticks, not in one frame. The sim turns at once.
func test_view_turns_smoothly_on_a_reversal() -> void:
	var v = _synced_view()
	v.athlete.velocity = Vector2(0.0, 6.0)
	for i in 30:
		_tick(v, 1.0)
	v.athlete.velocity = Vector2(0.0, -6.0)
	var worst := 0.0
	var last: float = v.rotation.y
	for i in 20:
		_tick(v, 1.0)
		worst = maxf(worst, absf(angle_difference(last, v.rotation.y)))
		last = v.rotation.y
	assert_true(worst < deg_to_rad(45.0), "at most 45 deg per tick: worst %.0f" % rad_to_deg(worst))
	assert_true(absf(angle_difference(v.rotation.y, atan2(0.0, -6.0))) < deg_to_rad(10.0), "faces the new way within 20 ticks (%.0f deg)" % rad_to_deg(v.rotation.y))
	v.place(Vector3(40, 0, -40), 1.0)   # teleport: no turn
	v.interpolate(0.0)
	assert_near(v.rotation.y, 1.0, 0.0001, "a teleport snaps the facing")
	v.free()

func _synced_view():
	var a = Athlete.new()
	a.role = Athlete.Role.WR
	var v = PlayerNode.new()
	v.setup(a, Color(0.8, 0.2, 0.2))
	v._ready()
	v.sync()
	return v

## One sim tick (sync) and one drawn frame at interpolation fraction f.
func _tick(v, f: float) -> void:
	v.sync()
	v.interpolate(f)
