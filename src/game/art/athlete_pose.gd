extends SkeletonModifier3D
## Procedural arm pose layered on top of the playing clip (#244). Godot 4.3 runs
## _process_modification() after the AnimationPlayer has posed the skeleton.
## Ball carry: two-bone IK pulls the right hand to the chest, elbow tucked at the side.
## A passer holding before the throw holds the ball in front of the chest, one hand on
## each side of it (palms in), and the ball sits there instead of in the right palm.
## Head look (#245): neck and head turn toward `look_target`, clamped to human limits.
## Catch (#246): both hands up in a ready stance, reaching to the ball as it closes in.
## Block push: the Push clip's upper body over the leg clip (Push is a standing shove; its
## legs never move, so an engaged pair on the move kept sliding with stiff legs).
## View-only (no sim state). weight 0 leaves the clip pose untouched; player.gd smooths it.

## Hand targets and elbow hints in spine_03 space (rig: +Z forward, +Y up, right = -X).
const TUCK_HAND := Vector3(-0.17, 0.06, 0.13)
const TUCK_POLE := Vector3(-0.6, -1.0, -0.6)
## Two-hand hold: ball center, and each wrist beside it (ball radius 0.13 + palm, fingers forward).
const HOLD_BALL := Vector3(0.0, 0.02, 0.28)
const HOLD_WRIST_R := HOLD_BALL + Vector3(-0.15, 0.0, -0.08)
const HOLD_WRIST_L := HOLD_BALL + Vector3(0.15, 0.0, -0.08)
const HOLD_POLE_R := Vector3(-1.0, -1.0, -0.3)
const HOLD_POLE_L := Vector3(1.0, -1.0, -0.3)
## Hand orientation for the hold, in spine_03 space: fingers forward (bone +Y = +Z) and
## palms in (palm is -X of hand_r and +X of hand_l, so both map bone +X to spine -X).
const HOLD_HAND_BASIS := Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
## Securing the ball going down (tackle_fall.gd): both arms clamp it to the chest, elbows in.
const SECURE_BALL := Vector3(0.0, -0.05, 0.2)
const SECURE_WRIST_R := SECURE_BALL + Vector3(-0.15, -0.02, -0.05)
const SECURE_WRIST_L := SECURE_BALL + Vector3(0.15, 0.02, -0.05)
const SECURE_POLE_R := Vector3(-0.6, -1.0, -0.8)
const SECURE_POLE_L := Vector3(0.6, -1.0, -0.8)

## Catch stance (#246), in the upright catch frame (see _upright): wrists up in front of the
## chest, palms forward. Upright, not the chest's own frame: a sprinting chest leans ~40 deg
## forward, which would put "in front of the chest" at the hips and read overhead balls as behind.
const CATCH_HAND_R := Vector3(-0.14, 0.12, 0.34)
const CATCH_HAND_L := Vector3(0.14, 0.12, 0.34)
const CATCH_POLE_R := Vector3(-1.0, -0.6, -0.2)
const CATCH_POLE_L := Vector3(1.0, -0.6, -0.2)
## Palms forward, fingers up and tipped 35 deg forward so the wrist isn't cocked all the
## way back (palm = -X of hand_r, +X of hand_l).
const PALMS_FWD_R := Basis(Vector3(1, 0, 0), deg_to_rad(35.0)) * Basis(Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0))
const PALMS_FWD_L := Basis(Vector3(1, 0, 0), deg_to_rad(35.0)) * Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0))
## Reaching: each wrist sits this far behind the ball and to its side (ball radius + palm).
const REACH_BACK := 0.13
const REACH_SIDE := 0.11
## Joint limits for the reach, in the (twisted) upright catch frame: the hands never go behind
## REACH_YAW_MAX; past it the reach fades back to the stance by REACH_YAW_MAX + REACH_YAW_FADE.
const REACH_YAW_MAX := deg_to_rad(75.0)
const REACH_YAW_FADE := deg_to_rad(45.0)
const REACH_PITCH_UP := deg_to_rad(75.0)
const REACH_PITCH_DOWN := deg_to_rad(40.0)
## The upper body turns toward the ball up to this (split over spine_02 and spine_03), so
## the arms have less to do. A ball almost straight behind (past TWIST_FADE_FROM) doesn't
## pick a side: the twist fades out over TWIST_FADE.
const TWIST_MAX := deg_to_rad(35.0)
const TWIST_FADE_FROM := deg_to_rad(140.0)
const TWIST_FADE := deg_to_rad(30.0)
## Diving catch (#360): the chest rolls about the spine to face the ball (up to DIVE_ROLL_MAX)
## and the spine bends toward it (up to DIVE_LEAN_MAX), split over spine_02 and spine_03. A
## ball almost along the spine (past DIVE_LEAN_FADE_FROM) bends nothing, as TWIST_FADE_FROM.
const DIVE_ROLL_MAX := deg_to_rad(50.0)
const DIVE_LEAN_MAX := deg_to_rad(30.0)
const DIVE_LEAN_FADE_FROM := deg_to_rad(150.0)
## A ball this far to one side (after the twist) is caught with the near arm only; the far
## arm stays in the stance. Blends between the two angles.
const ONE_ARM_FROM := deg_to_rad(20.0)
const ONE_ARM_TO := deg_to_rad(35.0)
## A ball this high above the chest is reached for with one arm straight up (running under
## it); the other arm keeps the clip's arm pump. Blends between the two angles.
const OVERHEAD_FROM := deg_to_rad(50.0)
const OVERHEAD_TO := deg_to_rad(62.0)
## Two-hand catch: each palm faces the ball's side, turned this much toward its back.
const PALM_TO_BACK := 0.4

## Hands on the ball open from the clip's fist toward the rig's flat rest pose by this
## much, leaving a slight curl so the fingers wrap the ball.
const HAND_OPEN := 0.7
const FINGERS := ["thumb", "index", "middle", "ring", "pinky"]

## Head look limits (rad), in the chest's frame. Past YAW_MAX the look fades back to
## neutral over YAW_FADE, so a target behind you never twists the neck.
const YAW_MAX := deg_to_rad(80.0)
const YAW_FADE := deg_to_rad(40.0)
const PITCH_UP := deg_to_rad(40.0)
const PITCH_DOWN := deg_to_rad(30.0)
const NECK_SHARE := 0.4   # the rest of the turn is the head's

## Bones the block push takes from the Push clip (spine lean, both arms); hips, legs, head
## and fingers stay on the playing clip. Track paths are relative to the AnimationPlayer root.
const PUSH_BONES := ["spine_02", "spine_03", "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
	"clavicle_r", "upperarm_r", "lowerarm_r", "hand_r"]
const PUSH_TRACK_PREFIX := "Armature/Skeleton3D:"

var weight := 0.0      # 0 = clip pose, 1 = full carry pose
var two_hand := false  # passer holding before the throw
var secure := 0.0      # going down: both arms clamp the ball to the chest, 0..1 (tackle_fall.gd)
var look_target := Vector3.ZERO   # skeleton space
var look_weight := 0.0            # 0 = clip's head, 1 = full look
var catch_weight := 0.0           # 0 = no catch pose, 1 = full stance/reach
var catch_target := Vector3.ZERO  # the ball, skeleton space
var catch_reach := 0.0            # 0 = ready stance, 1 = hands on the ball
var catch_dive := 0.0             # 0 = standing catch, 1 = diving catch (player.gd smooths it)
var push_clip: Animation          # the Push clip (player.gd sets it); null: no push layer
var push_weight := 0.0            # 0 = playing clip, 1 = Push clip on the upper body
var push_time := 0.0              # s into push_clip
var _push_tracks := []            # [bone id, rotation track id] per PUSH_BONES entry found
var _push_pelvis := [-1, -1]      # pelvis bone id, Push's pelvis rotation track
var _bones := {}
var _fingers := {}     # "_r"/"_l" -> finger bone ids (joints 01-03)
var _rig_ok := false   # every bone in _bones exists (checked once: no per-frame allocation)
## Maps the clip's chest-side bone poses to the twisted ones for this update. The twist is
## written last, so no bone is ever read after one of its parents was written.
var _pre := Transform3D()
var _twist_q := [Quaternion.IDENTITY, Quaternion.IDENTITY]   # spine_02, spine_03 local rotations

func _process_modification() -> void:
	apply(get_skeleton())

func apply(sk: Skeleton3D) -> void:
	if sk == null or (weight <= 0.0 and look_weight <= 0.0 and catch_weight <= 0.0 and push_weight <= 0.0):
		return
	if _bones.is_empty():
		for n in ["spine_02", "spine_03", "neck_01", "Head", "upperarm_r", "lowerarm_r", "hand_r", "upperarm_l", "lowerarm_l", "hand_l"]:
			_bones[n] = sk.find_bone(n)
		for side in ["_r", "_l"]:
			_fingers[side] = []
			for f in FINGERS:
				for j in ["01", "02", "03"]:
					var b := sk.find_bone("%s_%s%s" % [f, j, side])
					if b >= 0:
						_fingers[side].append(b)
		_rig_ok = not _bones.values().has(-1)
		if push_clip:
			for n in PUSH_BONES:
				var t := push_clip.find_track(NodePath(PUSH_TRACK_PREFIX + n), Animation.TYPE_ROTATION_3D)
				if t >= 0 and sk.find_bone(n) >= 0:
					_push_tracks.append([sk.find_bone(n), t])
			_push_pelvis = [sk.find_bone("pelvis"), push_clip.find_track(NodePath(PUSH_TRACK_PREFIX + "pelvis"), Animation.TYPE_ROTATION_3D)]
	if not _rig_ok:
		return   # rig without these bones: keep the clip
	if push_weight > 0.0:
		_push(sk)
	# The arms do one job: the stronger of catching and carrying (they cross over at the catch).
	var catching := catch_weight > weight
	_pre = Transform3D()
	if catching:
		_plan_twist(sk)
	if look_weight > 0.0:
		_look(sk)
	if catching:
		_catch(sk)
		sk.set_bone_pose_rotation(_bones.spine_02, _twist_q[0])
		sk.set_bone_pose_rotation(_bones.spine_03, _twist_q[1])
		return
	if weight <= 0.0:
		return
	var chest := _g(sk, _bones.spine_03)
	if two_hand:
		var palms_in := chest.basis * HOLD_HAND_BASIS
		_reach(sk, "_r", chest * HOLD_WRIST_R, chest.basis * HOLD_POLE_R, weight, palms_in)
		_reach(sk, "_l", chest * HOLD_WRIST_L, chest.basis * HOLD_POLE_L, weight, palms_in)
		_open_hand(sk, "_l", weight)
	else:
		_reach(sk, "_r", chest * TUCK_HAND, chest.basis * TUCK_POLE, weight)
	if secure > 0.0:   # on top of the hold, so letting go of the hug eases back into it
		var palms := chest.basis * HOLD_HAND_BASIS
		var ws := weight * secure
		_reach(sk, "_r", chest * SECURE_WRIST_R, chest.basis * SECURE_POLE_R, ws, palms)
		_reach(sk, "_l", chest * SECURE_WRIST_L, chest.basis * SECURE_POLE_L, ws, palms)
		_open_hand(sk, "_l", ws)
	_open_hand(sk, "_r", weight)

## Block push: the Push clip's upper-body bone rotations at push_time, blended by push_weight
## over the playing clip (the legs keep running). Runs first, so look, catch and carry layer on it.
## Push leans in from the pelvis, which stays on the leg clip: spine_02 (first in PUSH_BONES)
## also takes the pelvis difference, or the lean is lost and the arms point at the sky.
func _push(sk: Skeleton3D) -> void:
	var lean := Quaternion.IDENTITY
	if _push_pelvis[0] >= 0 and _push_pelvis[1] >= 0:
		lean = sk.get_bone_pose_rotation(_push_pelvis[0]).inverse() * push_clip.rotation_track_interpolate(_push_pelvis[1], push_time)
	for bt in _push_tracks:
		var q: Quaternion = push_clip.rotation_track_interpolate(bt[1], push_time)
		if bt == _push_tracks[0]:
			q = (lean * q).normalized()
		sk.set_bone_pose_rotation(bt[0], sk.get_bone_pose_rotation(bt[0]).slerp(q, push_weight))

## The catch frame: at the chest, facing the chest's heading, with the rig's +Y (world) up.
static func _upright(chest: Transform3D) -> Transform3D:
	var z := Vector3(chest.basis.z.x, 0.0, chest.basis.z.z).normalized()
	return Transform3D(Basis(Vector3.UP.cross(z), Vector3.UP, z), chest.origin)

## The reach frame: _upright standing; diving, the athlete's heading (skeleton +Z), since a
## lying chest's own heading is anywhere (a slide's chest faces the sky).
## Blended as an angle, so a half-dived frame never collapses.
func _catch_frame(chest: Transform3D) -> Transform3D:
	var yaw := atan2(chest.basis.z.x, chest.basis.z.z) if Vector2(chest.basis.z.x, chest.basis.z.z).length() > 1e-4 else 0.0
	yaw = lerp_angle(yaw, 0.0, catch_dive)
	var z := Vector3(sin(yaw), 0.0, cos(yaw))
	return Transform3D(Basis(Vector3.UP.cross(z), Vector3.UP, z), chest.origin)

## A bone's skeleton-space pose with this update's twist applied (see _pre).
func _g(sk: Skeleton3D, bone: int) -> Transform3D:
	return _pre * sk.get_bone_global_pose(bone)

## Turn the upper body toward the ball (#246): standing, up to TWIST_MAX about the vertical;
## diving (#360), the chest rolls and the spine bends toward it (_dive_twist), blended by
## catch_dive. Half on spine_02, half on spine_03. Computes _pre and the two local rotations.
func _plan_twist(sk: Skeleton3D) -> void:
	var s2: int = _bones.spine_02
	var g2 := sk.get_bone_global_pose(s2)
	var g3 := sk.get_bone_global_pose(_bones.spine_03)
	var q := Quaternion.IDENTITY
	if catch_dive < 1.0:
		var d := _upright(g3).affine_inverse() * catch_target
		var yaw := atan2(d.x, d.z)
		var fade := clampf(1.0 - (absf(yaw) - TWIST_FADE_FROM) / TWIST_FADE, 0.0, 1.0)
		# About true vertical: a twist about a sprint-leaning spine would overshoot the heading.
		q = Quaternion(Vector3.UP, clampf(yaw, -TWIST_MAX, TWIST_MAX) * fade * 0.5)
	if catch_dive > 0.0:
		q = q.slerp(_dive_twist(g2, g3, sk.get_bone_global_pose(_bones.neck_01).origin), catch_dive)
	var r := Basis(Quaternion.IDENTITY.slerp(q, catch_weight))
	var t2 := Transform3D(r, g2.origin - r * g2.origin)
	var p3 := t2 * g3.origin
	_pre = Transform3D(r, p3 - r * p3) * t2
	var parent := sk.get_bone_global_pose(sk.get_bone_parent(s2)).basis
	_twist_q[0] = (parent.inverse() * r * g2.basis).orthonormalized().get_rotation_quaternion()
	_twist_q[1] = ((r * g2.basis).inverse() * r * r * g3.basis).orthonormalized().get_rotation_quaternion()

## Half the diving twist (#360), skeleton space: the chest front (spine_03 +Z) rolls about
## the spine (spine_02 to neck) toward the ball, then the spine bends toward it, both clamped.
func _dive_twist(g2: Transform3D, g3: Transform3D, neck: Vector3) -> Quaternion:
	var spine := (neck - g2.origin).normalized()
	var to := catch_target - g2.origin
	if spine.length() < 0.5 or to.length() < 0.01:
		return Quaternion.IDENTITY
	to = to.normalized()
	var front := g3.basis.z - spine * g3.basis.z.dot(spine)
	var side := to - spine * to.dot(spine)
	var roll := 0.0
	if front.length() > 0.1 and side.length() > 0.1:
		roll = front.signed_angle_to(side, spine)
		roll *= clampf(1.0 - (absf(roll) - TWIST_FADE_FROM) / TWIST_FADE, 0.0, 1.0)   # straight behind: no side
		roll = clampf(roll, -DIVE_ROLL_MAX, DIVE_ROLL_MAX)
	var q := Quaternion(spine, roll)
	var bend := spine.angle_to(to)
	var axis := spine.cross(to)
	if axis.length() > 0.01:
		var fade := clampf(1.0 - (bend - DIVE_LEAN_FADE_FROM) / TWIST_FADE, 0.0, 1.0)
		q = Quaternion(axis.normalized(), minf(bend, DIVE_LEAN_MAX) * fade) * q
	return Quaternion.IDENTITY.slerp(q, 0.5)

## Ready stance blended toward hands on the ball by catch_reach, palms toward the ball. The
## reach direction is clamped to what a shoulder can do (never behind); a ball well off to
## one side is caught with the near arm only.
func _catch(sk: Skeleton3D) -> void:
	var chest := _catch_frame(_g(sk, _bones.spine_03))
	var to_ball := catch_target - chest.origin
	var d := chest.basis.inverse() * to_ball
	var yaw := atan2(d.x, d.z)
	var pitch := atan2(d.y, Vector2(d.x, d.z).length())
	var in_cone := clampf(1.0 - (absf(yaw) - REACH_YAW_MAX) / REACH_YAW_FADE, 0.0, 1.0)
	var reach := catch_reach * in_cone
	yaw = clampf(yaw, -REACH_YAW_MAX, REACH_YAW_MAX)
	pitch = clampf(pitch, -REACH_PITCH_DOWN, REACH_PITCH_UP)
	var toward := (chest.basis * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))).normalized()
	var ball := chest.origin + toward * to_ball.length()
	var side := toward.cross(chest.basis.y)   # the athlete's right
	side = side.normalized() if side.length() > 0.2 else -chest.basis.x   # ball straight overhead
	# Fingers run along the reach, tipped up; straight up the reach, they point forward.
	var fingers := toward + chest.basis.y * 0.5
	if absf(fingers.normalized().dot(toward)) > 0.9 and pitch > OVERHEAD_FROM:
		fingers = chest.basis.z
	var overhead := smoothstep(OVERHEAD_FROM, OVERHEAD_TO, pitch) * in_cone   # a ball behind isn't run under
	var one := maxf(smoothstep(ONE_ARM_FROM, ONE_ARM_TO, absf(yaw)), overhead)
	var near_side := "_l" if yaw > deg_to_rad(5.0) else "_r"   # dead overhead: the right arm
	for s in [["_r", CATCH_HAND_R, CATCH_POLE_R, PALMS_FWD_R, 1.0], ["_l", CATCH_HAND_L, CATCH_POLE_L, PALMS_FWD_L, -1.0]]:
		var near: bool = s[0] == near_side
		var r: float = reach if near else reach * (1.0 - one)   # the far arm drops back to the stance
		var wrist: Vector3 = (chest * s[1]).lerp(ball - toward * REACH_BACK + side * (REACH_SIDE * s[4]), r)
		# Palm on the ball's side, fingers along the reach, for one hand or two: a palm facing
		# down the reach would bend the wrist back 90+ deg, like a push.
		var palm: Vector3 = (-side * s[4] + toward * PALM_TO_BACK).normalized()
		var fingers_s := fingers
		if near and overhead > 0.0:
			# Arm straight up: fingers along the arm, palm forward to the ball (wrist straight).
			palm = palm.lerp(chest.basis.z, overhead).normalized()
			fingers_s = fingers.lerp(toward, overhead)
		var stance_q: Quaternion = (chest.basis * s[3]).get_rotation_quaternion()
		var hand := Basis(stance_q.slerp(_palm_basis(s[0] == "_r", palm, fingers_s).get_rotation_quaternion(), r))
		# Running under an overhead ball, the free arm keeps pumping (the clip's arm).
		var w: float = catch_weight if near else catch_weight * (1.0 - overhead)
		_reach(sk, s[0], wrist, chest.basis * s[2], w, hand)
		_open_hand(sk, s[0], w)

## A hand's orientation with its palm facing `palm` and fingers as close to `fingers` as
## possible (palm = -X of hand_r, +X of hand_l).
static func _palm_basis(right: bool, palm: Vector3, fingers: Vector3) -> Basis:
	var x := -palm if right else palm
	var y := (fingers - palm * fingers.dot(palm)).normalized()
	return Basis(x, y, x.cross(y))

## Clamped look angles for a direction in the chest's frame (+Z forward, +X left, +Y up):
## Vector2(yaw, pitch) in radians, yaw + = left, pitch + = up. Beyond YAW_MAX both fade to 0.
static func look_angles(d: Vector3) -> Vector2:
	var yaw := atan2(d.x, d.z)
	var pitch := atan2(d.y, Vector2(d.x, d.z).length())
	var fade := clampf(1.0 - (absf(yaw) - YAW_MAX) / YAW_FADE, 0.0, 1.0)
	return Vector2(clampf(yaw, -YAW_MAX, YAW_MAX), clampf(pitch, -PITCH_DOWN, PITCH_UP)) * fade

## Turn neck and head toward look_target: NECK_SHARE of the clamped turn on the neck,
## the rest on the head, about the chest's up and left axes.
func _look(sk: Skeleton3D) -> void:
	var chest := _g(sk, _bones.spine_03)
	var n: int = _bones.neck_01
	var h: int = _bones.Head
	var gn := _g(sk, n)
	var gh := _g(sk, h)
	var a := look_angles(chest.basis.inverse() * (look_target - gh.origin)) * look_weight
	var up := chest.basis.y.normalized()
	var left := chest.basis.x.normalized()
	var rn := Basis(up, a.x * NECK_SHARE) * Basis(left, -a.y * NECK_SHARE)
	var rh := Basis(up, a.x * (1.0 - NECK_SHARE)) * Basis(left, -a.y * (1.0 - NECK_SHARE))
	var neck := rn * gn.basis
	var parent := _g(sk, sk.get_bone_parent(n)).basis
	sk.set_bone_pose_rotation(n, (parent.inverse() * neck).orthonormalized().get_rotation_quaternion())
	sk.set_bone_pose_rotation(h, (neck.inverse() * rh * rn * gh.basis).orthonormalized().get_rotation_quaternion())

## Uncurl the clip's fist so the fingers spread around the ball.
func _open_hand(sk: Skeleton3D, side: String, w: float) -> void:
	var k := HAND_OPEN * w
	for b in _fingers[side]:
		sk.set_bone_pose_rotation(b, sk.get_bone_pose_rotation(b).slerp(sk.get_bone_rest(b).basis.get_rotation_quaternion(), k))

## Two-bone IK (skeleton space): hand to `target`, elbow bent toward `pole`. The hand takes
## `hand_basis` if given, else keeps the clip's wrist angle. Blended into local rotations by w.
func _reach(sk: Skeleton3D, side: String, target: Vector3, pole: Vector3, w: float, hand_basis = null) -> void:
	var u: int = _bones["upperarm" + side]
	var l: int = _bones["lowerarm" + side]
	var h: int = _bones["hand" + side]
	var gu := _g(sk, u)
	var gl := _g(sk, l)
	var gh := _g(sk, h)
	var a := gu.origin.distance_to(gl.origin)
	var b := gl.origin.distance_to(gh.origin)
	var to := target - gu.origin
	var d := clampf(to.length(), absf(a - b) + 0.001, a + b - 0.001)
	var dir := to.normalized()
	var bend := (pole - dir * pole.dot(dir)).normalized()
	var cos_a := clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var elbow := gu.origin + dir * (a * cos_a) + bend * (a * sqrt(1.0 - cos_a * cos_a))
	var ru := Basis(Quaternion((gl.origin - gu.origin).normalized(), (elbow - gu.origin).normalized()))
	var nu := Transform3D(ru * gu.basis, gu.origin)
	var rl := Basis(Quaternion((ru * (gh.origin - gl.origin)).normalized(), (gu.origin + dir * d - elbow).normalized()))
	var nl := Transform3D(rl * ru * gl.basis, elbow)
	var nh_basis: Basis = hand_basis if hand_basis != null else nl.basis * (gl.basis.inverse() * gh.basis)
	_blend(sk, u, _g(sk, sk.get_bone_parent(u)).basis.inverse() * nu.basis, w)
	_blend(sk, l, nu.basis.inverse() * nl.basis, w)
	_blend(sk, h, nl.basis.inverse() * nh_basis, w)

## Where the held ball sits, in skeleton space: in front of the chest for the two-hand hold,
## else null (the right palm's socket, player.gd). Only valid during the skeleton update.
func hold_ball(sk: Skeleton3D):
	if not two_hand or weight <= 0.0 or not _rig_ok:
		return null
	return sk.get_bone_global_pose(_bones.spine_03) * Transform3D(Basis(), HOLD_BALL)

## Where the ball sits in the going-down hug (skeleton space), or null when not hugging.
func secure_ball(sk: Skeleton3D):
	if secure <= 0.0 or weight <= 0.0 or not _rig_ok:
		return null
	return sk.get_bone_global_pose(_bones.spine_03) * Transform3D(Basis(), SECURE_BALL)

func _blend(sk: Skeleton3D, bone: int, local: Basis, w: float) -> void:
	var q := local.orthonormalized().get_rotation_quaternion()
	sk.set_bone_pose_rotation(bone, sk.get_bone_pose_rotation(bone).slerp(q, w))
