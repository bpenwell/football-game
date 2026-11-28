extends Node3D
## View of one sim athlete with two uniforms driven by the Quaternius rig.
## The local team wears the CC0 mannequin and Innerscene helmet. Opponents
## wear a custom Blender uniform, including its own helmet and facemask.
## Mirrors sim state; owns no rules. Cosmetics are view-only.
##
## Animation is chosen from how the node actually moves (works for live sim,
## network interpolation and replays alike) plus a few sim flags.

const T := preload("res://src/sim/tuning.gd")
const Tick := preload("res://src/sim/tick.gd")
const Cos := preload("res://src/sim/cosmetics.gd")
const Mats := preload("res://src/game/art/materials.gd")
const CharacterArt := preload("res://src/game/art/character_art.gd")
const Emotes := preload("res://src/sim/emotes.gd")
const Uniforms := preload("res://src/game/art/football_uniforms.gd")
const RC := preload("res://src/game/render_cache.gd")
const Pose := preload("res://src/game/art/athlete_pose.gd")
const Ball := preload("res://src/sim/ball.gd")
const TackleFall := preload("res://src/game/art/tackle_fall.gd")
const Replay := preload("res://src/sim/replay.gd")
## A view that moves more than this (yards) in one tick teleported (new play, replay
## seek, swap): snap instead of gliding across the field.
const TELEPORT_DIST := 2.0

const SKIN_TONES := [Color(0.98, 0.80, 0.66), Color(0.87, 0.65, 0.48), Color(0.72, 0.50, 0.34),
	Color(0.55, 0.36, 0.23), Color(0.40, 0.26, 0.17), Color(0.30, 0.20, 0.13)]
## Role -> [width, height] build. Linemen are wide, skill players lean.
const BUILDS := {"OL": [1.2, 1.0], "DL": [1.18, 1.0], "C": [1.18, 0.99], "LB": [1.08, 1.0],
	"QB": [1.0, 1.02], "RB": [1.03, 0.97], "WR": [0.94, 1.03], "CB": [0.94, 1.0], "S": [0.97, 1.0]}
const ROLE_NAMES := ["QB", "C", "WR", "RB", "LB", "CB", "S", "OL", "DL"]
const LINEMEN := ["OL", "DL", "C"]
const MODEL_SCALE := 1.08
const BLEND := 0.18
## Carry pose blend rate (1/s): about 0.2 s to tuck the ball in or out.
const CARRY_K := 14.0
const HOP_CLIP := "u2/Yes"   # Moon Hop: a fist pump as he bounces; the Jump loop held both arms straight out (#455)
## Head look smoothing (1/s): the look point trails a fast ball a little, like eyes do.
const LOOK_K := 10.0
## Heads only turn when the athlete is big enough on screen to see it: the camera view's
## half-height (yd) at the athlete's distance must be under this. About 25 yd away for the
## 65 deg follow camera, further for zoomed replay cameras. Saves the look math (#245).
const LOOK_VIEW_SIZE := 16.0
## Offensive players only watch a pass or loose ball this close (yd).
const WATCH_RANGE := 15.0
## "Near the camera" and "watches the ball" rarely change frame to frame: decide them this
## often (staggered by athlete id) instead of every frame (#245, LOG.md perf-08).
const LOOK_DECIDE_HZ := 10.0
## Catch pose (#246): athletes who watch a pass and are this close (yd) to where it comes
## down through chest height get ready to catch it.
const CATCH_RANGE := 6.0
const CATCH_HEIGHT := 1.4   # yd: about chest height
## They raise their hands only for the last CATCH_LEAD s of the flight (ball distance / ball
## speed). Without it, everyone near the landing spot ran with hands up for the whole flight,
## a second or more on a deep pass. The weight blend (CARRY_K) is ~99% in by the catch.
const CATCH_LEAD := 0.45
## An engaged block pushes (athlete_pose.gd: the Push clip's upper body over the leg clip)
## only below this speed (yd/s, the jog/sprint split): a blocker and defender moving faster
## than this together run with their arms pumping instead of sprinting with both hands out.
const PUSH_MAX_SPEED := 5.0
## Push clip playback rate (the block's shove cycle).
const PUSH_RATE := 1.3
## Hands go from the ready stance to the ball as it closes from REACH_FAR to REACH_NEAR (yd).
## The sim catches inside a 1.2 yd ground radius, which puts the ball about 2 yd from the
## chest at the catch (game_flow A04): REACH_NEAR is that, so the arms are fully out as it snaps in.
const REACH_FAR := 4.5
const REACH_NEAR := 2.0
## Ball seat in hand_r bone space: in the palm, long axis along the forearm (#244).
const BALL_SOCKET := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(-0.13, 0.08, 0.0))

var athlete  # sim athlete
var color := Color(0.9, 0.75, 0.2)
var pants_color := Color(0.15, 0.15, 0.2)
var world = null           # optional: sim world (stances)
var block_shield: MeshInstance3D

# Public cosmetics
var body: Node3D           # model root; celebrations spin/flip it
var number_front: Label3D
var number_back: Label3D
var number_text := ""
var trim_color := Color.WHITE
var look := {}
var celebrate_kind := "none"
var celebrate_t := 0.0
var emote_id := ""
var emote_t := 0.0
var spin_vis_t := 0.0      # view-side spin animation (works for net + local)
var spin_vis_side := 0
var jump_pose := preload("res://src/game/jump_pose.gd").new()   # view-side jump (#379)
var bubble: Label3D
var fair_catch_label: Label3D   # "FAIR CATCH" over a signaling returner (#189), built on first use
var fair_catch_shown := false

var model: Node3D
var mesh_i: MeshInstance3D
var anim: AnimationPlayer
var hand_r: Node3D
var pose: Node              # athlete_pose.gd (null without a rig)
var ball_node: Node3D       # the ball while this athlete carries it (presentation.gd sets it)
var look_node: Node3D       # the ball view: heads track it (#245; main.gd sets it)
var _look_point := Vector3.ZERO   # smoothed world-space look target
var _look_decide_t := 0.0         # time to the next look decision
var _look_wanted := false         # last decision: near the camera and watches the ball
var _catch_wanted := false        # last decision: a pass is coming down near this athlete
## Replay flags (replay.gd F_* bits: dive, lying, block, catch, fair catch) while a replay drives this view
## (main._render_replay), else -1 (sync() resets it). A replay moves the view along recorded
## positions; the live athlete's state (a block still engaged at the whistle, lying on the
## turf, a celebration) is not what's on screen, so it must not pick clips or arm poses.
var replay_flags := -1
var _skel: Skeleton3D
var _ball_xf := Transform3D()   # palm socket (world), cached at each skeleton update
var _ball_xf_ok := false
var trim_mat: StandardMaterial3D
var is_opponent := false

var _open_gear: Node3D
var _open_helmet: MeshInstance3D
var _opponent_mesh: MeshInstance3D
var _skin_color: Color

var _last_pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _role := ""
var _hit_t := 0.0
var fall    # tackle_fall.gd, built on the first tackle
var _shadow: MeshInstance3D
var chase_sim := false   # up after a tackle away from the sim spot: jogging back to it (interpolate)
## Catch-up speed over the sim's own (yd/s) for chase_sim.
const CHASE_SPEED := 4.0
var _shadow_moved := false   # following a fallen body instead of sitting under the root
var _release_t := 0.0
var _cur := ""
var _was_down := false
var _push := false   # this frame: an engaged block at a pushing pace (see _choose_anim)
# Render interpolation (docs/optimization/README.md): sync()/place() record the last two
# sim poses once per physics tick; interpolate(f) draws between them every frame.
var _prev_pos := Vector3.ZERO
var _cur_pos := Vector3.ZERO
var _prev_yaw := 0.0
var _cur_yaw := 0.0
var _has_pose := false

func setup(a, c: Color, w = null, opponent := false) -> void:
	athlete = a
	color = c
	world = w
	is_opponent = opponent
	pants_color = Color(0.16, 0.17, 0.22) if a.team == 0 else Color(0.92, 0.92, 0.94)

func _ready() -> void:
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	model = CharacterArt.instance()
	model.rotation.y = PI          # glTF faces +Z; our forward is -Z
	model.scale = Vector3.ONE * MODEL_SCALE
	body.add_child(model)
	mesh_i = CharacterArt.find_mesh(model)
	anim = CharacterArt.find_anim(model)
	var skel: Skeleton3D = mesh_i.get_parent() if mesh_i else null
	CharacterArt.dress_mesh(mesh_i)
	_skin_color = SKIN_TONES[(athlete.id * 7 + athlete.team * 3) % SKIN_TONES.size()]
	if mesh_i:
		_set_uniform("jersey", color)
		_set_uniform("pants", pants_color)
		_set_uniform("sock", color.darkened(0.3))
		_set_uniform("skin", _skin_color)

	trim_mat = Mats.cloth(Color.WHITE)
	var chest := _attach(skel, "spine_03")
	var head_bone := _bone(skel, "Head")
	hand_r = _attach(skel, "hand_r")
	_skel = skel
	_look_decide_t = float(athlete.id % 6) / Tick.HZ   # stagger: the 14 views don't all decide on the same frame
	if skel:
		pose = Pose.new()
		pose.push_clip = anim.get_animation("Push") if anim and anim.has_animation("Push") else null
		skel.add_child(pose)
		# Pin the ball after the clip and pose modifier have run, so it never trails the hand.
		skel.skeleton_updated.connect(_pin_ball)
	_open_gear = Node3D.new()
	chest.add_child(_open_gear)
	var pads := _part(_open_gear, RC.sphere(0.5, 1.0), Mats.cloth(color), Vector3(0, 0.1, -0.01))
	pads.scale = Vector3(0.46, 0.15, 0.27)
	_part(_open_gear, _cyl(0.085, 0.05), trim_mat, Vector3(0, 0.2, 0.0))
	_open_helmet = Uniforms.open_helmet(head_bone)
	_opponent_mesh = Uniforms.opponent_mesh(mesh_i)
	number_front = _number_label(chest, 0.205)
	number_back = _number_label(chest, -0.205)
	set_opponent(is_opponent)
	_shadow = _blob_shadow()
	add_child(_shadow)
	var shield_mesh := RC.sphere(0.5, 1.0)
	var shield_mat := Mats.emissive(Color(0.3, 0.8, 1.0, 0.35), 0.9)
	shield_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	block_shield = _part(self, shield_mesh, shield_mat, Vector3(0, 0.95, -0.66))
	block_shield.scale = Vector3(1.4, 1.65, 0.24)
	block_shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	block_shield.hide()
	apply_look(Cos.DEFAULT_LOOK.merged({"number": (athlete.id % 90) + 10}, true))
	_last_pos = Vector3(athlete.position.x, 0, -athlete.position.y)
	_play("Idle", 0.0)
	if anim:
		anim.seek(randf() * 1.5, true)
	sync()

# --- helpers ----------------------------------------------------------------

func _set_uniform(n: String, v) -> void:
	if mesh_i and mesh_i.material_override is ShaderMaterial:
		(mesh_i.material_override as ShaderMaterial).set_shader_parameter(n, v)

## Gear sized in yards: a child of the bone that undoes the model scale.
func _attach(skel: Skeleton3D, bone: String) -> Node3D:
	var ba := _bone(skel, bone)
	if not ba is BoneAttachment3D:
		return ba
	var holder := Node3D.new()
	holder.scale = Vector3.ONE / MODEL_SCALE
	ba.add_child(holder)
	return holder

## A node that follows `bone`, in the rig's own (bone-space) units.
func _bone(skel: Skeleton3D, bone: String) -> Node3D:
	if skel == null or skel.find_bone(bone) < 0:
		var n := Node3D.new()
		n.position.y = {"Head": 1.7, "spine_03": 1.35, "hand_r": 1.0}.get(bone, 1.0)
		body.add_child(n)
		return n
	var ba := BoneAttachment3D.new()
	ba.name = bone + "Bone"
	ba.bone_name = bone
	skel.add_child(ba)
	return ba

func _part(parent: Node3D, mesh: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	# Small gear sits inside the body's shadow; each caster is redrawn once per shadow
	# split, so only the body (and the helmet, set below) cast. docs/optimization/README.md
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

static func _cyl(r: float, h: float) -> CylinderMesh:
	return RC.cylinder(r, h)

func _blob_shadow() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "BlobShadow"
	mi.mesh = RC.ground_quad(Vector2(1.3, 1.3))
	mi.material_override = Mats.blob_shadow()
	mi.position.y = 0.02
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _number_label(parent: Node3D, z: float) -> Label3D:
	var l := Label3D.new()
	l.font_size = 72
	l.outline_size = 14
	l.pixel_size = 0.0034
	l.font = Mats.number_font()
	l.position = Vector3(0, -0.08, z)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if z < 0.0:
		l.rotation.y = PI
	parent.add_child(l)
	return l

func set_opponent(opponent: bool) -> void:
	is_opponent = opponent
	mesh_i.visible = not opponent
	_open_gear.visible = not opponent
	_open_helmet.visible = not opponent
	_opponent_mesh.visible = opponent

## Apply a (sanitized) look. Purely visual.
func apply_look(lk: Dictionary) -> void:
	look = Cos.sanitize_look(lk)
	trim_color = Cos.color_of("trim", look["trim"])
	trim_mat.albedo_color = trim_color
	if mesh_i:
		_set_uniform("trim", trim_color)
	var hc: Color = Cos.color_of("helmet", look["helmet"])
	var helmet_stripe := Mats.metal(hc) if look["helmet"] == "chrome" else Mats.glossy(hc)
	Uniforms.recolor(_open_helmet, color, _skin_color, trim_mat, helmet_stripe)
	Uniforms.recolor(_opponent_mesh, color, _skin_color, trim_mat, helmet_stripe)
	number_text = str(int(look["number"]))
	for l in [number_front, number_back]:
		l.text = number_text
		l.modulate = trim_color
		l.outline_modulate = color.darkened(0.55) if trim_color.get_luminance() > 0.5 else Color(0.95, 0.95, 0.95)

func celebrate(kind: String) -> void:
	if kind != "none":
		celebrate_kind = kind
		celebrate_t = 1.5

## Taunt: plays the clip (when not running) and a speech bubble overhead.
func emote(id: String) -> void:
	if not Emotes.has(id):
		return
	emote_id = id
	emote_t = Emotes.DURATION
	if bubble == null:
		bubble = Label3D.new()
		bubble.name = "TauntBubble"
		bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		bubble.no_depth_test = true
		bubble.fixed_size = false
		bubble.pixel_size = 0.0032
		bubble.font_size = 64
		bubble.outline_size = 16
		bubble.modulate = Color(1.0, 0.9, 0.35)
		bubble.position = Vector3(0, 2.4, 0)
		add_child(bubble)
	bubble.text = Emotes.bubble(id)
	bubble.visible = true

## Fair-catch signal (#189): a raised arm plus a label everyone can read, while the
## kick is in the air. Change-driven: toggled only when the signal flips.
func _show_fair_catch(on: bool) -> void:
	fair_catch_shown = on
	if on and fair_catch_label == null:
		fair_catch_label = Label3D.new()
		fair_catch_label.name = "FairCatchSignal"
		fair_catch_label.text = "FAIR CATCH"
		fair_catch_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		fair_catch_label.no_depth_test = true
		fair_catch_label.pixel_size = 0.0032
		fair_catch_label.font_size = 64
		fair_catch_label.outline_size = 16
		fair_catch_label.modulate = Color(1.0, 1.0, 1.0)
		fair_catch_label.outline_modulate = Color(0.05, 0.05, 0.1)
		fair_catch_label.position = Vector3(0, 2.7, 0)
		add_child(fair_catch_label)
	if fair_catch_label:
		fair_catch_label.visible = on

func is_celebrating() -> bool:
	return celebrate_t > 0.0

## Tackle impact reaction.
func hit() -> void:
	_hit_t = 0.6

## Tackled while carrying: go down hugging the ball (tackle_fall.gd). run = this athlete's
## velocity, contact = the velocity the hit drives the contact point to (yd/s, world),
## contact_h = the hit's height (yd). fumble: the ball came out, so he scrambles up sooner.
func tackled(run: Vector3, impulse: Vector3, point: Vector3, fumble := false) -> void:
	if pose == null or _skel == null:
		hit()
		return
	if fall == null:
		fall = TackleFall.new(self)
	fall.start(run, impulse, point, fumble)

func is_falling() -> bool:
	return fall != null and fall.active

## Where this athlete is on the ground: under the body while he's down (ring, blob shadow).
func ground_position() -> Vector3:
	return fall.ground_position() if is_falling() else Vector3(global_position.x, 0.0, global_position.z)

## Follow-through after the ball leaves the hand.
func throw_release() -> void:
	_release_t = 0.55
	set_carry(null)
	if pose:
		pose.weight = 0.0   # the throw clip plays untouched from its first frame
	_play("u2/OverhandThrow", 0.05, 1.4)
	if anim and anim.has_animation("u2/OverhandThrow"):
		anim.seek(anim.get_animation("u2/OverhandThrow").length * 0.42, true)

## Where the ball sits when this athlete carries it (world space).
func hand_position() -> Vector3:
	return hand_r.global_position if hand_r and hand_r.is_inside_tree() else global_position + Vector3(0, 1.1, 0)

## Carry the ball (`ball` = the ball view) or stop (null). two_hand: passer holding before the throw.
func set_carry(ball: Node3D, two_hand := false) -> void:
	ball_node = ball
	if pose:
		pose.two_hand = two_hand

## The held ball's world transform: seated in the right palm (unit scale), as of the
## last skeleton update. Godot 4.3 applies the pose modifier only during that update;
## read the bones at any other time and you get the plain clip pose.
func ball_transform() -> Transform3D:
	if _ball_xf_ok:
		return _ball_xf
	return Transform3D(global_basis.orthonormalized(), hand_position() - global_basis.z.normalized() * 0.15)

## The held ball in skeleton space: between both hands for a passer's hold, else the right palm.
func ball_local(sk: Skeleton3D) -> Transform3D:
	var held = pose.hold_ball(sk) if pose else null
	var at: Transform3D = held if held != null else sk.get_bone_global_pose(sk.find_bone("hand_r")) * BALL_SOCKET
	var hug = pose.secure_ball(sk) if pose else null
	return at.interpolate_with(hug, pose.secure) if hug != null else at

## True when an athlete `dist` yd from a camera with vertical FOV `fov_deg` is close
## enough on screen for a head turn to be seen.
static func head_visible(dist: float, fov_deg: float) -> bool:
	return dist * tan(deg_to_rad(fov_deg) * 0.5) < LOOK_VIEW_SIZE

## Does an athlete watch the ball right now (#245)? Nobody engaged in a block. The defense
## reads it: the snap, the carrier, a pass. Offensive linemen only on a loose ball near them.
## Other offensive players watch for the snap, then only a pass or loose ball near them
## (they're running routes or blocking while it's held).
static func watches_ball(offense: bool, lineman: bool, engaged: bool, presnap: bool, ball_state: int, dist: float) -> bool:
	if engaged:
		return false
	if not offense:
		return true
	var near := dist < WATCH_RANGE
	if ball_state == Ball.State.LOOSE:
		return near
	return not lineman and (presnap or (ball_state == Ball.State.IN_FLIGHT and near))

## This view's athlete, right now (see watches_ball).
func watches_now() -> bool:
	if world == null or look_node == null:
		return false
	return watches_ball(athlete.team == world.offense_team, _role in LINEMEN, athlete.engaged_with >= 0 or athlete.blocking,
		int(world.phase) == 0, int(world.ball.state), global_position.distance_to(look_node.global_position))

## Heads track the ball (not the carrier's own; not while down, celebrating, too far from
## the camera to see, or when the athlete has no reason to watch it).
func _update_look(delta: float, down: bool, diving: bool) -> void:
	_look_decide_t -= delta
	if _look_decide_t <= 0.0:
		_look_decide_t = 1.0 / LOOK_DECIDE_HZ
		var cam := get_viewport().get_camera_3d()
		_look_wanted = cam != null and head_visible(global_position.distance_to(cam.global_position), cam.fov) and watches_now()
		_catch_wanted = _look_wanted and _near_catch_point()
	var watching := _look_wanted and look_node != null and ball_node == null and celebrate_t <= 0.0
	var looking := watching and not down
	var k := 1.0 - exp(-LOOK_K * delta)
	if look_node != null and (looking or pose.look_weight > 0.0):   # also while fading out, so a fading head never points at an old spot
		var target := look_node.global_position
		# Snap after a teleport (new spot, replay seek) so every head doesn't sweep the field.
		var snap: bool = pose.look_weight <= 0.0 or target.distance_to(_look_point) > TELEPORT_DIST * 2.0
		_look_point = target if snap else _look_point.lerp(target, k)
		pose.look_target = _skel.global_transform.affine_inverse() * _look_point
	pose.look_weight = lerpf(pose.look_weight, 1.0 if looking else 0.0, k)
	if pose.look_weight < 0.01 and not looking:
		pose.look_weight = 0.0
	# A Classic receiver can catch while diving. The arms reach over the existing slide.
	var dive_reach: bool = watching and diving and not athlete.is_grounded() \
		and world != null and not world.is_chaos() and not world.kicked
	_update_catch(delta, looking or dive_reach, dive_reach)

## Where a pass in flight comes down through height h (field x, y), on its way down. A
## pass that never climbs to h (a low line drive) uses where it lands. Same flight math as
## presentation.gd's landing marker.
static func catch_point(pos: Vector3, vel: Vector3, g: float, h: float) -> Vector2:
	var disc := vel.z * vel.z + 2.0 * g * (pos.z - h)
	if disc < 0.0:
		h = 0.0
		disc = vel.z * vel.z + 2.0 * g * pos.z
	var t := (vel.z + sqrt(maxf(disc, 0.0))) / g if g > 0.0 else 0.0
	return Vector2(pos.x, pos.y) + Vector2(vel.x, vel.y) * maxf(t, 0.0)

## A pass (not the snap) is in the air.
func _pass_in_air() -> bool:
	return int(world.ball.state) == Ball.State.IN_FLIGHT and not world.snap_in_flight()

func _near_catch_point() -> bool:
	var b = world.ball
	if not _pass_in_air():
		return false
	var cp := catch_point(b.position, b.velocity, world.gravity(), CATCH_HEIGHT)
	return athlete.position.distance_to(cp) < CATCH_RANGE

## Catch pose (#246): ready stance as the pass comes in, hands to the ball as it closes.
func _update_catch(delta: float, can_reach: bool, dive_reach: bool) -> void:
	var chest := global_position + Vector3.UP * CATCH_HEIGHT
	var catching: bool = (replay_flags & Replay.F_CATCH) != 0 and look_node != null if replay_flags >= 0 \
		else _catch_wanted and can_reach and _pass_in_air() \
		and look_node.global_position.distance_to(chest) < CATCH_LEAD * world.ball.velocity.length()
	if catching:
		pose.catch_twist = not (dive_reach if replay_flags < 0 else (replay_flags & Replay.F_DIVING) != 0)
		var ball := look_node.global_position
		pose.catch_target = _skel.global_transform.affine_inverse() * ball
		pose.catch_reach = clampf((REACH_FAR - ball.distance_to(chest)) / (REACH_FAR - REACH_NEAR), 0.0, 1.0)
	elif pose.catch_weight <= 0.0:
		return
	pose.catch_weight = lerpf(pose.catch_weight, 1.0 if catching else 0.0, 1.0 - exp(-CARRY_K * delta))
	if pose.catch_weight < 0.01 and not catching:
		pose.catch_weight = 0.0

func _pin_ball() -> void:
	if ball_node == null or not is_instance_valid(ball_node):
		return   # only the carrier pays for this (per-frame work is change-driven)
	var xf := _skel.global_transform * ball_local(_skel)
	_ball_xf = Transform3D(xf.basis.orthonormalized(), xf.origin)
	_ball_xf_ok = true
	ball_node.global_transform = _ball_xf

func _role_name() -> String:
	var r := int(athlete.role)
	return ROLE_NAMES[r] if r >= 0 and r < ROLE_NAMES.size() else "WR"

## Mirror the sim position/facing. Animation runs in _process.
func sync() -> void:
	replay_flags = -1
	block_shield.visible = athlete.blocking
	var yaw := rotation.y
	var to_foe := _to_foe()
	if athlete.blocking:
		yaw = atan2(-athlete.facing.x, athlete.facing.y)
	elif _push and to_foe != Vector2.ZERO:
		yaw = atan2(-to_foe.x, to_foe.y)   # a block faces its opponent, even while driven back
	elif athlete.speed() > 0.1:
		yaw = atan2(-athlete.velocity.x, athlete.velocity.y)
	elif athlete.facing.length() > 0.1 and world != null and int(world.phase) == 0:
		yaw = atan2(-athlete.facing.x, athlete.facing.y)
	place(Vector3(athlete.position.x, 0, -athlete.position.y), yaw)
	var rn := _role_name()
	if rn != _role:
		_role = rn
		var b: Array = BUILDS.get(rn, [1.0, 1.0])
		scale = Vector3(b[0], b[1], (b[0] + 1.0) * 0.5)
	if celebrate_t > 0.0:
		celebrate_t = maxf(0.0, celebrate_t - Tick.DT)

func _play(name: String, blend: float = BLEND, speed: float = 1.0) -> void:
	if anim == null or not anim.has_animation(name):
		return
	anim.speed_scale = speed
	if _cur != name:
		_cur = name
		anim.play(name, blend)

func _process(delta: float) -> void:
	if delta <= 0.0 or body == null:
		return
	var v := (position - _last_pos) / delta
	_last_pos = position
	if v.length() > 30.0:   # teleport (new play / replay seek)
		v = Vector3.ZERO
	_vel = _vel.lerp(v, clampf(delta * 12.0, 0.0, 1.0))
	var spd := Vector2(_vel.x, _vel.z).length()
	var live := replay_flags < 0
	var diving: bool = athlete.is_diving() if live else (replay_flags & Replay.F_DIVING) != 0
	var down: bool = diving or (athlete.is_grounded() or is_falling() if live else (replay_flags & Replay.F_GROUNDED) != 0)
	if spd > 0.4 and not down and not ((live and athlete.blocking) or _push):
		rotation.y = lerp_angle(rotation.y, atan2(-_vel.x, -_vel.z), clampf(delta * 14.0, 0.0, 1.0))
	_hit_t = maxf(0.0, _hit_t - delta)
	emote_t = maxf(0.0, emote_t - delta)
	if bubble:
		bubble.visible = emote_t > 0.0
		bubble.modulate.a = clampf(emote_t / 0.3, 0.0, 1.0)
	# Menu/POTG stub athletes have no spin state.
	if live and athlete.has_method("is_spinning") and athlete.is_spinning() and spin_vis_t <= 0.0:
		spin_vis_t = T.SPIN_TIME
		spin_vis_side = athlete.spin_dir
	spin_vis_t = maxf(0.0, spin_vis_t - delta)
	jump_pose.update(athlete if live else null, delta)   # replays: no jump in the recording yet (#380)
	_release_t = maxf(0.0, _release_t - delta)
	var fc: bool = (live and world != null and world.get("fair_catch_id") == athlete.id and int(world.phase) == 1) \
		or (not live and (replay_flags & Replay.F_FAIR_CATCH) != 0)
	if fc != fair_catch_shown:
		_show_fair_catch(fc)
	_push = false
	if live:
		_choose_anim(spd, down)
	else:
		_choose_replay_anim(spd)
	_was_down = down
	if pose:
		var target := 1.0 if ball_node != null else 0.0
		pose.weight = lerpf(pose.weight, target, 1.0 - exp(-CARRY_K * delta))
		if absf(pose.weight - target) < 0.01:
			pose.weight = target
		pose.push_weight = lerpf(pose.push_weight, 1.0 if _push else 0.0, 1.0 - exp(-CARRY_K * delta))
		if pose.push_weight < 0.01 and not _push:
			pose.push_weight = 0.0
		if pose.push_clip and pose.push_weight > 0.0:
			pose.push_time = fmod(pose.push_time + delta * PUSH_RATE, pose.push_clip.length)
		_update_look(delta, down, diving)
	# Celebration flourishes on top of the dance.
	body.rotation = Vector3.ZERO
	body.position = Vector3(0.0, jump_pose.lift(), 0.0)
	if live and athlete.is_spinning():
		body.rotation.y = TAU * (1.0 - athlete.move_t / T.SPIN_TIME)
	if live and celebrate_t > 0.0:
		var t := 1.5 - celebrate_t
		match celebrate_kind:
			"spin": body.rotation.y = t * TAU * 2.0
			"hop": body.position.y = absf(sin(t * 6.0)) * 0.9
			"flip":
				body.rotation.x = t * TAU / 1.5
				body.position.y = sin(t / 1.5 * PI) * 1.4
	elif spin_vis_t > 0.0:
		# Spin move: one full turn toward the spin side (left = counter-clockwise from above).
		var k := 1.0 - spin_vis_t / T.SPIN_TIME
		body.rotation.y = -float(spin_vis_side) * TAU * ease(k, -1.6)
	if is_falling():
		fall.update(delta)
	if _shadow and (_shadow_moved or is_falling()):
		_shadow_moved = is_falling()
		_shadow.global_position = ground_position() + Vector3(0, 0.02, 0) if _shadow_moved else global_position + Vector3(0, 0.02, 0)

func _choose_anim(spd: float, down: bool) -> void:
	if celebrate_t > 0.0:
		_play({"hop": HOP_CLIP, "flip": "Roll"}.get(celebrate_kind, "Dance"))
		return
	if is_falling():
		if not fall.holding() and not fall.rising():   # hit-stop: keep the contact frame; getting up: tackle_fall plays it
			_play("Idle", 0.1)   # under the ragdoll: only the neck and clavicles still follow a clip
		return
	if athlete.is_diving():
		_play("u2/Slide_Start", 0.08, 1.6)
		return
	if athlete.is_grounded():
		# Lie on the turf, then pop back up as the recovery ends.
		if not _was_down or _cur == "u2/Slide_Start":
			_play("u2/Slide", 0.12)
		if athlete.recover_t < 0.7:
			_play("u2/LayToIdle", 0.15, 1.6)
		return
	if jump_pose.play(self):
		return
	if _hit_t > 0.0:
		_play("u2/Hit_Knockback", 0.08, 1.3)
		return
	if _release_t > 0.0:
		return
	if emote_t > 0.0 and spd < 1.5:
		_play(Emotes.clip(emote_id), 0.12)
		return
	if fair_catch_shown and spd < 1.5:
		_play("Pistol_Aim_Up", 0.12)   # arm straight up: the fair-catch wave
		return
	if athlete.blocking:
		_play("u2/Idle_Shield")
		return
	# A little hysteresis on the speed: no flicker at the edge.
	_push = athlete.engaged_with >= 0 and spd < PUSH_MAX_SPEED + (0.5 if pose and pose.push_weight > 0.5 else 0.0)
	var presnap: bool = world != null and int(world.phase) == 0
	# Driven back while facing the blocker: the jog runs in reverse, a backpedal.
	_locomotion(spd, presnap, _push and athlete.velocity.dot(_to_foe()) < 0.0)

## A replayed view: the recorded dive / lying / fair-catch flags, else running by its recorded
## motion, pushing while the recording has it engaged in a block (#374, #198).
func _choose_replay_anim(spd: float) -> void:
	if replay_flags & Replay.F_DIVING:
		_play("u2/Slide_Start", 0.08, 1.6)
	elif replay_flags & Replay.F_GROUNDED:
		_play("u2/Slide", 0.12)
	elif fair_catch_shown and spd < 1.5:
		_play("Pistol_Aim_Up", 0.12)
	else:
		_push = (replay_flags & Replay.F_PUSH) != 0   # recorded with the sim speed: replay rate can't change it
		# Driven back while pushing: backpedal, as live (facing isn't recorded; the view keeps its own).
		_locomotion(spd, false, _push and _vel.dot(Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))) < 0.0)

## Replay view bits per athlete (#374), from the sim as the live view decides them:
## F_PUSH, an engaged block below PUSH_MAX_SPEED (_choose_anim, sim speed, no hysteresis);
## F_CATCH, the catch window of a pass in the air (watches_ball + _near_catch_point +
## CATCH_LEAD, without the camera gate). Empty when nobody has either.
static func replay_bits(world) -> PackedByteArray:
	var out := PackedByteArray()
	var b = world.ball
	var flying: bool = int(b.state) == Ball.State.IN_FLIGHT and not world.snap_in_flight()
	var cp := catch_point(b.position, b.velocity, world.gravity(), CATCH_HEIGHT) if flying else Vector2.ZERO
	for i in world.athletes.size():
		var a = world.athletes[i]
		var bits := 0
		if a.engaged_with >= 0 and a.velocity.length() < PUSH_MAX_SPEED:
			bits = Replay.F_PUSH
		elif flying:
			var r := int(a.role)
			var chest := Vector3(a.position.x, a.position.y, CATCH_HEIGHT)
			if a.position.distance_to(cp) < CATCH_RANGE and chest.distance_to(b.position) < CATCH_LEAD * b.velocity.length() \
					and watches_ball(a.team == world.offense_team, r >= 0 and r < ROLE_NAMES.size() and ROLE_NAMES[r] in LINEMEN,
						a.engaged_with >= 0 or a.blocking, false, Ball.State.IN_FLIGHT, chest.distance_to(b.position)):
				bits = Replay.F_CATCH
		if bits != 0:
			if out.is_empty():
				out.resize(world.athletes.size())   # zero-filled
			out[i] = bits
	return out

## The sim direction (unit) to the athlete this one is engaged with, or zero.
func _to_foe() -> Vector2:
	var foe = world.get_athlete(athlete.engaged_with) if world != null and athlete.engaged_with >= 0 else null
	return (foe.position - athlete.position).normalized() if foe != null else Vector2.ZERO

func _locomotion(spd: float, presnap: bool, backward := false) -> void:
	if spd < 0.5:
		if presnap and _role in LINEMEN:
			_play("Crouch_Idle")
		elif presnap and _role in ["LB", "CB", "S"] and athlete.set_lock:
			_play("u2/Idle_Shield")
		else:
			_play("Idle")
	elif spd < 5.0:
		_play("Jog_Fwd", BLEND, clampf(spd / 3.6, 0.6, 1.6) * (-1.0 if backward else 1.0))
	else:
		_play("Sprint", BLEND, clampf(spd / 6.8, 0.8, 1.7))

## Record a new sim (or replay) pose, once per physics tick. Big jumps snap.
func place(p: Vector3, yaw: float) -> void:
	if not _has_pose or p.distance_to(_cur_pos) > TELEPORT_DIST:
		if is_falling():
			fall.stop()   # next play: back on his feet
		chase_sim = false
		_prev_pos = p
		_prev_yaw = yaw
		_has_pose = true
	else:
		_prev_pos = _cur_pos
		_prev_yaw = _cur_yaw
	_cur_pos = p
	_cur_yaw = yaw
	if is_falling() or chase_sim:
		return   # the fallen body owns where it lies (moving the node would drag the physics bones)
	position = p
	rotation.y = yaw

## Per render frame (main._render_frame, before this node's _process):
## f = Engine.get_physics_interpolation_fraction() in [0, 1].
func interpolate(f: float) -> void:
	if is_falling():
		return
	if chase_sim:
		# Back on his feet where he fell: run to where the sim has him, a bit faster than the
		# sim moves. _process turns him to face the way he goes and picks the run clip from it.
		var to := _prev_pos.lerp(_cur_pos, f)
		var spd := _prev_pos.distance_to(_cur_pos) * Tick.HZ + CHASE_SPEED
		position = position.move_toward(to, spd * get_process_delta_time())
		chase_sim = position.distance_to(to) > 0.01
		return
	position = _prev_pos.lerp(_cur_pos, f)
	rotation.y = lerp_angle(_prev_yaw, _cur_yaw, f)

## Latest sim (or replay) pose this view is heading to; `position` may lag it by < 1 tick.
func target_position() -> Vector3:
	return _cur_pos
