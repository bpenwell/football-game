extends "res://tests/test_case.gd"
## #244: ball carry pose. The carrier's right arm tucks the ball to the chest over the
## running clip; a passer holding before the throw uses both hands; the ball sits in the
## palm. Poses are sampled from the real rig and clips (no mixer), then the modifier runs.

const PlayerNode := preload("res://src/game/player.gd")
const Athlete := preload("res://src/sim/athlete.gd")
const SAMPLES := 10
## Tucked: hand at the chest, not swinging at the hip (bone units, about meters).
const MAX_TUCK_DIST := 0.25
## Two-hand hold: each wrist beside the ball (radius 0.15), on opposite sides of it.
const HOLD_WRIST_TO_BALL := [0.12, 0.3]

func test_carry_tucks_right_hand_to_chest_through_the_sprint() -> void:
	var v = _view(Athlete.Role.RB)
	var sk := _skel(v)
	var clip: Animation = v.anim.get_animation("Sprint")
	var worst_clip := 0.0
	var worst_tuck := 0.0
	for i in SAMPLES:
		var t := clip.length * float(i) / SAMPLES
		_pose(sk, clip, t)
		worst_clip = maxf(worst_clip, _hand_to_chest(sk, "hand_r"))
		v.pose.weight = 1.0
		v.pose.apply(sk)
		sk.force_update_all_bone_transforms()
		worst_tuck = maxf(worst_tuck, _hand_to_chest(sk, "hand_r"))
	assert_true(worst_clip > MAX_TUCK_DIST, "the plain sprint swings the hand away from the chest (%.2f)" % worst_clip)
	assert_true(worst_tuck < MAX_TUCK_DIST, "tucked hand stays at the chest: worst %.2f m" % worst_tuck)
	v.free()

func test_no_carry_leaves_the_clip_pose_untouched() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Sprint"), 0.3)
	var before := _arm_rotations(sk)
	v.pose.weight = 0.0
	v.pose.apply(sk)
	assert_eq(_arm_rotations(sk), before, "weight 0: arm bones")
	v.free()

func test_passer_holds_the_ball_with_both_hands() -> void:
	var v = _view(Athlete.Role.QB)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Idle"), 0.5)
	v.pose.weight = 1.0
	v.pose.two_hand = true
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	var ball: Vector3 = v.ball_local(sk).origin
	var r := _bone_pos(sk, "hand_r") - ball
	var l := _bone_pos(sk, "hand_l") - ball
	for d in [r.length(), l.length()]:
		assert_true(d > HOLD_WRIST_TO_BALL[0] and d < HOLD_WRIST_TO_BALL[1], "each hand beside the ball: %.2f m" % d)
	assert_true(r.dot(l) < 0.0, "hands on opposite sides of the ball, not stacked")
	assert_true(r.x < 0.0 and l.x > 0.0, "right hand on the ball's right (-X), left on its left")
	assert_true(ball.distance_to(_bone_pos(sk, "spine_03")) < 0.4, "ball held in front of the chest")
	v.free()

func test_hands_on_the_ball_open_from_the_fist() -> void:
	var v = _view(Athlete.Role.QB)
	var sk := _skel(v)
	var clip: Animation = v.anim.get_animation("Idle")
	_pose(sk, clip, 0.5)
	var fist := _curl(sk, "_r")
	v.pose.weight = 1.0
	v.pose.apply(sk)
	var tuck := _curl(sk, "_r")
	assert_true(fist > 0.5, "the clip holds a fist (finger curl %.2f rad)" % fist)
	assert_true(tuck < fist * 0.5, "carrying hand opens: curl %.2f -> %.2f rad" % [fist, tuck])
	assert_true(tuck > 0.0, "fingers keep a slight curl to wrap the ball")
	assert_true(_curl(sk, "_l") > fist * 0.9, "one-arm tuck leaves the free hand alone")
	_pose(sk, clip, 0.5)
	v.pose.two_hand = true
	v.pose.apply(sk)
	assert_true(_curl(sk, "_l") < fist * 0.5 and _curl(sk, "_r") < fist * 0.5, "two-hand hold opens both hands")
	v.free()

func test_throw_release_drops_the_carry_at_once() -> void:
	var v = _view(Athlete.Role.QB)
	var ball := Node3D.new()
	v.set_carry(ball, true)
	v.pose.weight = 1.0
	v.throw_release()
	assert_eq(v.pose.weight, 0.0, "pose weight right after the release")
	assert_true(v.ball_node == null, "the ball left the hand")
	ball.free()
	v.free()

## Same-frame pinning in the live scene is checked by game_flow.gd (needs the tree).
func test_ball_socket_sits_in_the_tucked_palm() -> void:
	var v = _view(Athlete.Role.RB)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Sprint"), 0.2)
	v.pose.weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	var ball: Transform3D = v.ball_local(sk)
	var wrist := _bone_pos(sk, "hand_r")
	assert_true(ball.origin.distance_to(wrist) < 0.2, "ball in the hand: %.2f m from the wrist" % ball.origin.distance_to(wrist))
	assert_true(_hand_to_chest(sk, "hand_r") < MAX_TUCK_DIST, "held at the chest")
	var forearm := (wrist - _bone_pos(sk, "lowerarm_r")).normalized()
	var along := absf(ball.basis.z.normalized().dot(forearm))
	assert_true(along > 0.9, "long axis along the forearm (|cos| %.2f)" % along)
	v.free()

# --- #245 head look -------------------------------------------------------------

const Pose := preload("res://src/game/art/athlete_pose.gd")

func test_look_angles_clamp_to_neck_limits() -> void:
	var cases := [   # direction in the chest frame (+Z fwd, +X left, +Y up) -> expected (yaw, pitch) deg
		[Vector3(0, 0, 1), Vector2(0, 0), "straight ahead"],
		[Vector3(1, 0, 1), Vector2(45, 0), "45 deg left"],
		[Vector3(-1, 0, 1), Vector2(-45, 0), "45 deg right"],
		[Vector3(1, 0, 0), Vector2(60, 0), "90 deg left: clamped to 80, a quarter faded"],
		[Vector3(0, 0, -1), Vector2(0, 0), "directly behind: neutral, no wrap"],
		[Vector3(0.1, 0, -1), Vector2(0, 0), "behind, slightly left: neutral"],
		[Vector3(0, 5, 1), Vector2(0, 40), "steep up: clamped to 40"],
		[Vector3(0, -5, 1), Vector2(0, -30), "steep down: clamped to -30"],
	]
	for c in cases:
		var a := Pose.look_angles(c[0])
		assert_near(rad_to_deg(a.x), c[1].x, 0.5, "%s yaw" % c[2])
		assert_near(rad_to_deg(a.y), c[1].y, 0.5, "%s pitch" % c[2])

func test_head_turns_toward_the_target() -> void:
	var v = _view(Athlete.Role.CB)
	var sk := _skel(v)
	var clip: Animation = v.anim.get_animation("Idle")
	_pose(sk, clip, 0.5)
	var before := _head_angles(sk)
	var head := _bone_pos(sk, "Head")
	var chest := sk.get_bone_global_pose(sk.find_bone("spine_03")).basis
	v.pose.look_target = head + chest * Vector3(1, 0.3, 1) * 5.0   # 45 deg left, a little up
	v.pose.look_weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	var turn := _head_angles(sk) - before
	assert_near(turn.x, 45.0, 4.0, "head yaw turn toward a target 45 deg left")
	assert_true(turn.y > 5.0 and turn.y < 25.0, "head pitches up toward it: %.1f deg" % turn.y)
	v.free()

func test_head_stays_within_limits_for_every_direction() -> void:
	var v = _view(Athlete.Role.S)
	var sk := _skel(v)
	var clip: Animation = v.anim.get_animation("Idle")
	var worst_yaw := 0.0
	var worst_up := 0.0
	var worst_down := 0.0
	for i in 24:
		for el in [-80.0, -20.0, 0.0, 30.0, 80.0]:
			_pose(sk, clip, 0.5)
			var before := _head_angles(sk)
			var chest := sk.get_bone_global_pose(sk.find_bone("spine_03")).basis
			var az := deg_to_rad(i * 15.0)
			var e := deg_to_rad(el)
			var d := Vector3(sin(az) * cos(e), sin(e), cos(az) * cos(e))
			v.pose.look_target = _bone_pos(sk, "Head") + chest * d * 6.0
			v.pose.look_weight = 1.0
			v.pose.apply(sk)
			sk.force_update_all_bone_transforms()
			var turn := _head_angles(sk) - before
			worst_yaw = maxf(worst_yaw, absf(turn.x))
			worst_up = maxf(worst_up, turn.y)
			worst_down = minf(worst_down, turn.y)
	# +5: measured on the final head, so steep pitch combined with the clip's own head tilt adds a few degrees.
	assert_true(worst_yaw <= 85.0, "head yaw turn never past 80 deg (+5 measurement slack): worst %.1f" % worst_yaw)
	assert_true(worst_up <= 41.0 and worst_down >= -31.0, "pitch within -30..40: %.1f..%.1f" % [worst_down, worst_up])
	v.free()

func test_no_look_weight_leaves_the_head_alone() -> void:
	var v = _view(Athlete.Role.LB)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Idle"), 0.5)
	var q: Quaternion = sk.get_bone_pose_rotation(sk.find_bone("Head"))
	v.pose.look_target = Vector3(5, 1.5, 5)
	v.pose.look_weight = 0.0
	v.pose.apply(sk)
	assert_eq(sk.get_bone_pose_rotation(sk.find_bone("Head")), q, "weight 0: head bone")
	v.free()

func test_heads_far_from_the_camera_do_not_look() -> void:
	assert_true(PlayerNode.head_visible(20.0, 65.0), "follow camera (65 deg): 20 yd away turns")
	assert_true(not PlayerNode.head_visible(30.0, 65.0), "follow camera: 30 yd away is too small to see")
	assert_true(PlayerNode.head_visible(45.0, 34.0), "zoomed broadcast replay (34 deg): 45 yd still turns")
	assert_true(not PlayerNode.head_visible(60.0, 34.0), "broadcast replay: 60 yd doesn't")

func test_only_athletes_who_need_the_ball_watch_it() -> void:
	const HELD := 0
	const FLIGHT := 1
	const LOOSE := 2
	# [offense, lineman, engaged, presnap, ball state, distance, expected, what]
	var cases := [
		[false, false, false, true, HELD, 20.0, true, "defense reads the snap"],
		[false, true, false, false, HELD, 30.0, true, "defensive lineman chases the carrier"],
		[false, false, false, false, FLIGHT, 40.0, true, "defense watches a pass anywhere"],
		[false, true, true, false, HELD, 2.0, false, "defender engaged in a block doesn't"],
		[true, true, false, true, HELD, 1.0, false, "offensive lineman at the snap: eyes ahead"],
		[true, true, false, false, FLIGHT, 5.0, false, "offensive lineman ignores a pass"],
		[true, true, false, false, LOOSE, 5.0, true, "offensive lineman: loose ball nearby"],
		[true, true, false, false, LOOSE, 25.0, false, "offensive lineman: loose ball far away"],
		[true, false, false, true, HELD, 20.0, true, "receiver watches for the snap"],
		[true, false, false, false, HELD, 10.0, false, "receiver runs his route while the QB holds it"],
		[true, false, false, false, FLIGHT, 10.0, true, "receiver tracks a pass near him"],
		[true, false, false, false, FLIGHT, 25.0, false, "receiver ignores a pass far away"],
		[true, false, true, false, FLIGHT, 5.0, false, "blocking back doesn't"],
	]
	for c in cases:
		assert_eq(PlayerNode.watches_ball(c[0], c[1], c[2], c[3], c[4], c[5]), c[6], c[7])

# --- #246 catch stance and reach -------------------------------------------------

func test_catch_point_is_where_the_pass_comes_down_through_chest_height() -> void:
	# z = 2 + 5t - 4.9t^2 reaches 1.4 on the way down at t = 1.1289 -> y = 11.29
	var cp := PlayerNode.catch_point(Vector3(0, 0, 2), Vector3(0, 10, 5), 9.8, 1.4)
	assert_near(cp.y, 11.289, 0.01, "catch point downfield")
	assert_near(cp.x, 0.0, 0.001, "catch point across")
	# A low pass that never climbs to 1.4 uses where it lands: 1 - t - 4.9t^2 = 0 -> t = 0.3611
	var low := PlayerNode.catch_point(Vector3(0, 0, 1), Vector3(0, 10, -1), 9.8, 1.4)
	assert_near(low.y, 3.611, 0.01, "low pass: landing spot")

func test_catch_stance_puts_both_hands_up_in_front() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Sprint"), 0.3)
	var chest: Transform3D = Pose._upright(sk.get_bone_global_pose(sk.find_bone("spine_03")))
	v.pose.catch_target = chest * Vector3(0, 0.5, 8.0)   # pass still far out in front
	v.pose.catch_reach = 0.0
	v.pose.catch_weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	var r := chest.affine_inverse() * _bone_pos(sk, "hand_r")
	var l := chest.affine_inverse() * _bone_pos(sk, "hand_l")
	for p in [r, l]:
		assert_true(p.z > 0.2 and p.y > -0.05, "hand up in front of the chest: %s" % str(p))
	assert_true(r.x < 0.0 and l.x > 0.0, "right hand on the right, left on the left")
	v.free()

func test_reach_closes_both_hands_on_the_ball() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Sprint"), 0.3)
	var chest := sk.get_bone_global_pose(sk.find_bone("spine_03"))
	var ball := chest * Vector3(0.15, 0.25, 0.45)   # high and to the left, within reach
	v.pose.catch_target = ball
	v.pose.catch_reach = 1.0
	v.pose.catch_weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	var r := _bone_pos(sk, "hand_r") - ball
	var l := _bone_pos(sk, "hand_l") - ball
	assert_true(r.length() < 0.22 and l.length() < 0.22, "both hands at the ball: %.2f, %.2f m" % [r.length(), l.length()])
	var toward := (ball - chest.origin).normalized()   # both wrists sit behind the ball: compare sideways
	var rs := r - toward * r.dot(toward)
	var ls := l - toward * l.dot(toward)
	assert_true(rs.dot(ls) < 0.0, "hands on opposite sides of the ball")
	v.free()

func test_diving_reach_keeps_the_slide_torso_and_legs() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("u2/Slide_Start"), 0.26)
	var clip_rotations := {}
	for bone in ["spine_02", "spine_03", "thigh_r", "thigh_l"]:
		clip_rotations[bone] = sk.get_bone_pose_rotation(sk.find_bone(bone))
	var chest := Pose._upright(sk.get_bone_global_pose(sk.find_bone("spine_03")))
	var ball := chest * Vector3(-0.28, 0.15, 0.45)
	var original_distance := _bone_pos(sk, "hand_r").distance_to(ball)
	v.pose.catch_twist = false
	v.pose.catch_target = ball
	v.pose.catch_reach = 1.0
	v.pose.catch_weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()

	assert_true(_bone_pos(sk, "hand_r").distance_to(ball) < original_distance - 0.1, "the near hand reaches for the pass")
	for bone in clip_rotations:
		var rotation := sk.get_bone_pose_rotation(sk.find_bone(bone))
		assert_true(rotation.is_equal_approx(clip_rotations[bone]), bone + " follows the slide")
	v.free()

## #455: the Moon Hop clip never holds the arms straight out (the Jump loop it replaced did).
func test_moon_hop_arms_stay_in() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	var widest := {}
	for clip_name in [PlayerNode.HOP_CLIP, "Jump"]:
		var clip: Animation = v.anim.get_animation(clip_name)
		widest[clip_name] = 0.0
		for i in 12:
			_pose(sk, clip, clip.length * i / 12.0)
			# Both hands far out to the sides at once: the nearer one's sideways distance from the chest.
			var x: float = _bone_pos(sk, "spine_03").x
			var out := minf(absf(_bone_pos(sk, "hand_l").x - x), absf(_bone_pos(sk, "hand_r").x - x))
			widest[clip_name] = maxf(widest[clip_name], out)
	assert_true(widest["Jump"] > 0.5, "the old Jump loop does hold both out (%.2f m)" % widest["Jump"])
	assert_true(widest[PlayerNode.HOP_CLIP] < 0.4, "the hop never holds both out: at most %.2f m" % widest[PlayerNode.HOP_CLIP])
	v.free()

func test_reach_never_stretches_the_arm() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	_pose(sk, v.anim.get_animation("Idle"), 0.5)
	var arm := _bone_pos(sk, "upperarm_r").distance_to(_bone_pos(sk, "lowerarm_r")) + _bone_pos(sk, "lowerarm_r").distance_to(_bone_pos(sk, "hand_r"))
	v.pose.catch_target = sk.get_bone_global_pose(sk.find_bone("spine_03")) * Vector3(0, 0.3, 3.0)   # out of reach
	v.pose.catch_reach = 1.0
	v.pose.catch_weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	var d := _bone_pos(sk, "upperarm_r").distance_to(_bone_pos(sk, "hand_r"))
	assert_true(d <= arm + 0.005, "arm not stretched: %.3f <= %.3f" % [d, arm])
	assert_true(d > arm * 0.95, "arm fully extended toward a ball out of reach: %.3f of %.3f" % [d, arm])
	v.free()

## Puts the ball at (yaw, pitch) degrees and `dist` m from the clip's chest in the upright
## catch frame (yaw + = left), fully reaching, and returns that frame for measuring.
func _catch_at(v, sk: Skeleton3D, clip: Animation, yaw: float, pitch: float, dist: float) -> Transform3D:
	_pose(sk, clip, 0.3)
	var chest: Transform3D = Pose._upright(sk.get_bone_global_pose(sk.find_bone("spine_03")))
	var y := deg_to_rad(yaw)
	var p := deg_to_rad(pitch)
	v.pose.catch_target = chest * (Vector3(sin(y) * cos(p), sin(p), cos(y) * cos(p)) * dist)
	v.pose.catch_reach = 1.0
	v.pose.catch_weight = 1.0
	v.pose.apply(sk)
	sk.force_update_all_bone_transforms()
	return chest

func test_reach_keeps_human_joint_limits_for_every_ball_direction() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	var clip: Animation = v.anim.get_animation("Sprint")
	var worst := {"upper_back": 1.0, "hand_back": 1.0, "wrist": 0.0, "stretch": 0.0, "twist": 0.0}
	var at := {}   # which ball direction and arm gave each worst value
	for i in 24:
		for pitch in [-30.0, 0.0, 30.0, 60.0]:
			var clip_chest := _catch_at(v, sk, clip, i * 15.0, pitch, 1.0)
			var chest: Transform3D = Pose._upright(sk.get_bone_global_pose(sk.find_bone("spine_03")))
			var f := clip_chest.basis.inverse() * chest.basis.z
			worst.twist = maxf(worst.twist, absf(rad_to_deg(atan2(f.x, f.z))))
			# An overhead ball is caught one-handed; the free arm keeps the clip's own arm swing.
			var signed := wrapf(i * 15.0, -180.0, 180.0)
			var free_arm := ("_r" if signed > 5.0 else "_l") if pitch >= 60.0 and absf(signed) < 120.0 else ""
			for s in ["_r", "_l"]:
				if s == free_arm:
					continue
				var u := _bone_pos(sk, "upperarm" + s)
				var l := _bone_pos(sk, "lowerarm" + s)
				var h := sk.get_bone_global_pose(sk.find_bone("hand" + s))
				var up := (chest.basis.inverse() * (l - u)).normalized()
				var where := "yaw %d pitch %d arm %s" % [i * 15, pitch, s]
				if up.z < worst.upper_back:
					at.upper_back = where
				worst.upper_back = minf(worst.upper_back, up.z)
				worst.hand_back = minf(worst.hand_back, (chest.affine_inverse() * h.origin).z)
				var wr := rad_to_deg((h.origin - l).normalized().angle_to(h.basis.y.normalized()))
				if wr > worst.wrist:
					at.wrist = where
				worst.wrist = maxf(worst.wrist, wr)
				var arm := u.distance_to(l) + l.distance_to(h.origin)
				worst.stretch = maxf(worst.stretch, u.distance_to(h.origin) - arm)
	assert_true(worst.upper_back > -0.35, "upper arm never points behind the chest: worst forward %.2f (%s)" % [worst.upper_back, at.get("upper_back", "")])
	assert_true(worst.hand_back > -0.05, "hands stay in front of the chest: worst %.2f m" % worst.hand_back)
	assert_true(worst.wrist < 95.0, "wrist within 95 deg of the forearm: worst %.0f (%s)" % [worst.wrist, at.get("wrist", "")])
	assert_true(worst.stretch < 0.005, "arm never stretched: worst %.3f m over" % worst.stretch)
	assert_true(worst.twist < 36.0, "torso twist at most 35 deg: worst %.1f" % worst.twist)
	v.free()

func test_torso_turns_toward_a_ball_off_to_the_side() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	var clip_chest := _catch_at(v, sk, v.anim.get_animation("Idle"), 60.0, 0.0, 1.0)
	var f := clip_chest.basis.inverse() * Pose._upright(sk.get_bone_global_pose(sk.find_bone("spine_03"))).basis.z
	assert_near(rad_to_deg(atan2(f.x, f.z)), 35.0, 2.0, "chest turns 35 deg toward a ball 60 deg to the left")
	v.free()

func test_palms_face_the_ball_from_each_side() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	_catch_at(v, sk, v.anim.get_animation("Sprint"), 10.0, 5.0, 0.5)
	var ball: Vector3 = v.pose.catch_target
	var hr := sk.get_bone_global_pose(sk.find_bone("hand_r"))
	var hl := sk.get_bone_global_pose(sk.find_bone("hand_l"))
	var palm_r := -hr.basis.x.normalized()   # palm = -X of hand_r, +X of hand_l
	var palm_l := hl.basis.x.normalized()
	var face_r := palm_r.dot((ball - hr.origin).normalized())
	var face_l := palm_l.dot((ball - hl.origin).normalized())
	assert_true(face_r > 0.5 and face_l > 0.5, "each palm faces the ball: %.2f, %.2f" % [face_r, face_l])
	assert_true(palm_r.dot(palm_l) < 0.0, "palms face each other across the ball: %.2f" % palm_r.dot(palm_l))
	v.free()

func test_overhead_ball_one_arm_up_other_arm_pumps() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	var clip: Animation = v.anim.get_animation("Sprint")
	_pose(sk, clip, 0.3)
	var clip_l: Quaternion = sk.get_bone_pose_rotation(sk.find_bone("upperarm_l"))
	_catch_at(v, sk, clip, 0.0, 72.0, 0.9)   # running under a ball dropping from overhead
	var head := _bone_pos(sk, "Head")
	var hand_r := _bone_pos(sk, "hand_r")
	assert_true(hand_r.y > head.y + 0.15, "right arm up above the head: hand %.2f over the head" % (hand_r.y - head.y))
	assert_true(_bone_pos(sk, "hand_l").y < head.y, "left hand stays down")
	var drift := rad_to_deg(sk.get_bone_pose_rotation(sk.find_bone("upperarm_l")).angle_to(clip_l))
	assert_true(drift < 5.0, "left arm keeps the clip's pump: %.1f deg off the clip" % drift)
	v.free()

func test_ball_wide_to_one_side_is_caught_one_handed() -> void:
	var v = _view(Athlete.Role.WR)
	var sk := _skel(v)
	var clip_chest := _catch_at(v, sk, v.anim.get_animation("Idle"), -80.0, 10.0, 0.8)
	var ball: Vector3 = v.pose.catch_target
	var r := _bone_pos(sk, "hand_r").distance_to(ball)
	var l := _bone_pos(sk, "hand_l").distance_to(ball)
	assert_true(r < 0.3, "near (right) hand on the ball: %.2f m" % r)
	assert_true(l > r + 0.25, "far (left) hand stays back in the stance: %.2f m vs %.2f m" % [l, r])
	var chest: Transform3D = Pose._upright(sk.get_bone_global_pose(sk.find_bone("spine_03")))   # twisted
	var stance: Vector3 = chest * v.pose.CATCH_HAND_L
	assert_true(_bone_pos(sk, "hand_l").distance_to(stance) < 0.12, "far hand at its stance spot: %.2f m off" % _bone_pos(sk, "hand_l").distance_to(stance))
	v.free()

# --- helpers ------------------------------------------------------------------

## Head facing (Head bone +Z) as (yaw, pitch) degrees in the chest's frame.
## Block push: the Push clip's arms and spine lean over the leg clip; legs and hips keep running.
func test_block_push_layers_the_push_upper_body_over_the_run() -> void:
	var v = _view(Athlete.Role.OL)
	var sk := _skel(v)
	var push: Animation = v.anim.get_animation("Push")
	assert_true(v.pose.push_clip == push, "the view hands the pose its Push clip")
	_pose(sk, v.anim.get_animation("Jog_Fwd"), 0.3)
	var legs := []
	for b in ["pelvis", "thigh_l", "calf_l", "thigh_r", "calf_r"]:
		legs.append(sk.get_bone_pose_rotation(sk.find_bone(b)))
	v.pose.push_weight = 1.0
	v.pose.push_time = 0.8
	v.pose.apply(sk)
	for b in ["spine_03", "upperarm_r", "lowerarm_r", "upperarm_l", "lowerarm_l"]:
		var tr := push.find_track(NodePath("Armature/Skeleton3D:" + b), Animation.TYPE_ROTATION_3D)
		var want: Quaternion = push.rotation_track_interpolate(tr, 0.8)
		var got := sk.get_bone_pose_rotation(sk.find_bone(b)).angle_to(want)
		assert_true(got < 0.01, "%s takes the Push clip: %.4f rad off" % [b, got])   # acos noise is ~0.002
	var after := []
	for b in ["pelvis", "thigh_l", "calf_l", "thigh_r", "calf_r"]:
		after.append(sk.get_bone_pose_rotation(sk.find_bone(b)))
	assert_eq(after, legs, "hips and legs stay on the run clip")
	v.free()

func _head_angles(sk: Skeleton3D) -> Vector2:
	var chest := sk.get_bone_global_pose(sk.find_bone("spine_03")).basis
	var f := chest.inverse() * sk.get_bone_global_pose(sk.find_bone("Head")).basis.z
	return Vector2(rad_to_deg(atan2(f.x, f.z)), rad_to_deg(atan2(f.y, Vector2(f.x, f.z).length())))

func _view(role: int):
	var a = Athlete.new()
	a.role = role
	var v = PlayerNode.new()
	v.setup(a, Color(0.8, 0.2, 0.2))
	v._ready()   # unit tests run before the tree processes; build the rig directly
	return v

func _skel(v) -> Skeleton3D:
	return v.mesh_i.get_parent()

func _bone_pos(sk: Skeleton3D, bone: String) -> Vector3:
	return sk.get_bone_global_pose(sk.find_bone(bone)).origin

func _hand_to_chest(sk: Skeleton3D, hand: String) -> float:
	return _bone_pos(sk, hand).distance_to(_bone_pos(sk, "spine_03") + Vector3(0, 0, 0.12))

## Mean angle (rad) of the middle finger's joints away from the open rest pose.
func _curl(sk: Skeleton3D, side: String) -> float:
	var total := 0.0
	for j in ["01", "02", "03"]:
		var b := sk.find_bone("middle_%s%s" % [j, side])
		total += sk.get_bone_pose_rotation(b).angle_to(sk.get_bone_rest(b).basis.get_rotation_quaternion())
	return total / 3.0

func _arm_rotations(sk: Skeleton3D) -> Array:
	var out := []
	for b in ["upperarm_r", "lowerarm_r", "hand_r", "upperarm_l", "lowerarm_l", "hand_l"]:
		out.append(sk.get_bone_pose_rotation(sk.find_bone(b)))
	return out

## Set the skeleton to `anim` at time t from the clip's own tracks (as test_helmet_fit.gd).
func _pose(sk: Skeleton3D, anim: Animation, t: float) -> void:
	sk.reset_bone_poses()
	for tr in anim.get_track_count():
		var bone := sk.find_bone(anim.track_get_path(tr).get_concatenated_subnames())
		if bone < 0:
			continue
		match anim.track_get_type(tr):
			Animation.TYPE_POSITION_3D:
				sk.set_bone_pose_position(bone, anim.position_track_interpolate(tr, t))
			Animation.TYPE_ROTATION_3D:
				sk.set_bone_pose_rotation(bone, anim.rotation_track_interpolate(tr, t))
			Animation.TYPE_SCALE_3D:
				sk.set_bone_pose_scale(bone, anim.scale_track_interpolate(tr, t))
	sk.force_update_all_bone_transforms()
