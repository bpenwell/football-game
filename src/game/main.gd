extends Node3D
## Builds the field, spawns the local player and camera. Presentation only:
## rules live in src/sim. Sim (x, y) yards maps to 3D (x, 0, -y).

const World := preload("res://src/sim/world.gd")
const Athlete := preload("res://src/sim/athlete.gd")
const PlayerNode := preload("res://src/game/player.gd")
const Passing := preload("res://src/sim/passing.gd")
const AI := preload("res://src/sim/ai.gd")
const Match := preload("res://src/sim/match.gd")
const NEXT_PLAY_DELAY := 2.0
const NetSession := preload("res://src/net/net_session.gd")
const Protocol := preload("res://src/net/protocol.gd")
const SNAPSHOT_EVERY := 2   # physics ticks (Tick.RATE 60 Hz -> 30 Hz snapshots); clients convert via Interp.TICK_RATE
const REMOTE_IDLE_INPUT := {World.HUMAN: true}
const Predictor := preload("res://src/net/client_predictor.gd")
const Interp := preload("res://src/net/interpolator.gd")
const INTERP_DELAY := 0.1   # seconds others render in the past
const Roster := preload("res://src/sim/roster.gd")
const LOCAL_PLAYER := 1      # the local human's player id (= host peer id online)
const Routes := preload("res://src/sim/routes.gd")
const Controls := preload("res://src/ui/controls.gd")
const MatchConfig := preload("res://src/sim/match_config.gd")
const Lobby := preload("res://src/net/lobby.gd")
const Drills := preload("res://src/sim/drills.gd")
const Stats := preload("res://src/sim/stats.gd")
const Leaderboard := preload("res://src/sim/leaderboard.gd")
const Ranked := preload("res://src/sim/ranked.gd")
const Cosmetics := preload("res://src/sim/cosmetics.gd")
const Replay := preload("res://src/sim/replay.gd")
const ReplayOverlay := preload("res://src/game/replay_overlay.gd")
const Achievements := preload("res://src/sim/achievements.gd")
const MMServer := preload("res://src/net/mm_server.gd")
const MMClient := preload("res://src/net/mm_client.gd")
const Matchmaker := preload("res://src/net/matchmaker.gd")
const InviteCode := preload("res://src/net/invite_code.gd")
const T := preload("res://src/sim/tuning.gd")
const Presentation := preload("res://src/game/presentation.gd")
const Potg := preload("res://src/sim/potg.gd")
const PotgStage := preload("res://src/ui/potg_stage.gd")
const POSTGAME_HOLD := 3.0      # seconds on the FINAL scoreboard before players of the game
const FieldArt := preload("res://src/game/art/field_art.gd")
const StadiumArt := preload("res://src/game/art/stadium.gd")
const ArtMats := preload("res://src/game/art/materials.gd")
const ArtQuality := preload("res://src/game/art/quality.gd")
const TauntWheel := preload("res://src/game/taunt_wheel.gd")
const CameraZoom := preload("res://src/game/camera_zoom.gd")
const TrainingArt := preload("res://src/game/art/training_art.gd")
const CoinToss := preload("res://src/game/coin_toss.gd")
const ARC_DOTS := 24

const TEAM_COLORS := [Color(0.95, 0.75, 0.15), Color(0.3, 0.8, 0.95)]

var world := World.new()
const Field := preload("res://src/sim/field.gd")
var field: Field = world.field
var controlled_id := -1
var views: Array = []
var player: Node3D  # view of the controlled athlete
var ball_view: MeshInstance3D
var reticle: MeshInstance3D
var arc_dots: Array = []
var charging := false   # POV passer holding the throw
var charge := 0.0       # 0..1 throw power (distance)
# Render interpolation for the ball (views interpolate themselves; see player.gd).
var _ball_prev := Vector3.ZERO
var _ball_cur := Vector3.ZERO
var aim_point := Vector2(26, 45)
## POV passing (Gridiron-style): while you're the passer the mouse is captured and
## steers your view. Throws go where you look; view pitch = launch angle (height),
## charge = speed (distance). WASD is relative to the view.
const POV_SENS := 0.0025            # radians per mouse pixel
const POV_PITCH_MIN := deg_to_rad(-25.0)
const POV_PITCH_MAX := deg_to_rad(60.0)
const POV_PITCH_START := deg_to_rad(10.0)
const POV_ANGLE_OFFSET := 10.0      # launch angle = view pitch + this (deg): level view = a line drive
## Aim-zoom (#109, Gridiron 1.0.4.24): holding the throw narrows the FOV with the
## charge (charge = distance), so a long throw zooms in furthest; eases back on release.
const CAMERA_FOV := 65.0
const AIM_ZOOM_FOV := 45.0          # FOV at full charge
const AIM_ZOOM_RATE := 8.0          # 1/s easing rate (frame-rate independent)
## Camera framing (#128). Offsets are (right, up, back) from the controlled player. The
## follow look is clamped (_framed_look) so the player's ring never drops below
## FRAME_FEET_MAX of the screen height, whatever the offset, FOV or aim range, so the
## mouse-wheel zoom (#140, camera_zoom.gd) only scales the follow offset.
const FOLLOW_CAM_OFFSET := Vector3(0, 6, 9)
const FOLLOW_CAM_OFFSET_BLOCKING := Vector3(0, 10, 13)   # blocking drill: both lines in view
const POV_CAM_OFFSET := Vector3(0.9, 2.8, 5.4)           # over the passer's right shoulder
const FRAME_RING_R := 1.1      # PlayerRing outer edge (presentation.gd quad half-size)
const FRAME_FEET_MAX := 0.8    # lowest screen row (fraction) for the ring; scorebug top ≈ 0.865
var pov_enabled := true             # tests/bots that aim at a field point turn this off
var aim_yaw := 0.0                  # 0 = straight downfield (+y), + = right
var aim_pitch := POV_PITCH_START
var pov_w := 0.0                    # 0 follow cam .. 1 POV cam
var _last_phase := -1
var crosshair: Control
var taunt_wheel: TauntWheel
var ai := AI.new()
var last_whistle := ""
var banner := ""
var banner_t := 0.0
var series: Match
var roster := Roster.new()
var match_size := 7
var match_mode := "classic"     # classic | chaosball
var lobby := Lobby.new()      # server: authoritative; client: mirror
var debug_playclock := -1.0
var drill: Drills = null        # offline practice drill (null = normal match)
var training_path := Drills.DEFAULT_BESTS_PATH   # personal bests (tests pass --training-file)
var queue_started_ms := 0       # matchmaking: when we queued (warm-up HUD timer)
var stats: Stats
var summary_lines: Array = []   # end-of-match summary (server computes; clients receive)
var my_summary: Array = []      # your own lines by match identity, not display name (#200; clients receive)
var leaderboard_path := Leaderboard.DEFAULT_PATH
var ranked_path := Ranked.DEFAULT_PATH
var ranked_match := false       # competitive queue or --ranked: ratings change at FINAL
var pending_teams := {}         # name -> team (matchmaker's split; fallback for seat-less clients)
var pending_seats := {}         # seat token -> team (matchmaker's rating-balanced split, #59)
var seat_token := ""            # our random per-queue id; the host seats us by it, not by name
var peer_seats := {}            # host: peer id -> seat token the joiner sent
var peer_installs := {}         # host: peer id -> install id the joiner sent; keys ranked records (#102), never broadcast
var install_id_unsaved := false # minted this session, not yet written to the profile
var ranked_line := ""
var player_name := "You"
var profile := Cosmetics.new()
var profile_path := Cosmetics.DEFAULT_PATH
var looks := {}            # athlete_id -> look (view-only)
var peer_looks := {}       # server: peer_id -> sanitized look
var xp_line := ""
var achievement_line := ""
var replay := Replay.new()
var replay_active := false      # views show replay frames instead of the live sim
var replay_viewer := false      # --replay=FILE standalone viewer
var replay_dir := "user://replays"
var saved_replay := ""
## B04 highlights: offline, big plays (TD, turnover, sack, 20+ yd) replay on their own
## shortly after the whistle. V/Enter skips. --auto-replay=0 turns it off.
const AUTO_REPLAY_DELAY := 1.0
const REPLAY_CAMS := ["Broadcast", "End zone", "Sky", "Player"]
var auto_replay := true
var replay_auto := false        # the clip on screen is an automatic highlight
var replay_reel := false        # the highlight reel (V at FINAL) is playing
var replay_shown := -1          # last play index already replayed (manual or auto)
var replay_cam := 0             # index into REPLAY_CAMS
var replay_overlay: CanvasLayer
var _replay_cam_cut := true     # next replay camera frame cuts instead of easing
var _was_replaying := false
var whistle_t := 0.0            # seconds since the ball went dead (offline auto replay)
var my_ranks := ""
var potg: Array = []            # players of the game (server picks; clients receive)
var team_totals: Array = []     # per-team box score for the lobby's game overview
var postgame_t := -1.0          # >= 0: counting down to the players-of-the-game presentation
var postgame: Control           # the presentation while it plays
var postgame_done := false
var field_root: Node3D
var athlete_root: Node3D
var my_id := -1          # the human's athlete (QB on offense, LB on defense)
var dead_t := 0.0
var auto_next := true
var los_marker: MeshInstance3D
var fd_marker: MeshInstance3D
## Components (src/game/component.gd): behavior that lives in its own file. They read game
## state through `ctx` and get main's per-tick, per-frame, configure and event hooks.
const GameContext := preload("res://src/game/game_context.gd")
const RouteArt := preload("res://src/game/components/route_art.gd")
var ctx = GameContext.new(self)
var components: Array = []
var route_art: RouteArt
var route_mesh: ImmediateMesh:   # tests read the route art's mesh
	get: return route_art.mesh
var input_override = null   # tests/bots: Vector2 replaces keyboard movement
var sprint_override = null  # tests/bots: bool replaces the Shift key
var net: NetSession
var net_tick := 0
var predictor := Predictor.new()
var interp := Interp.new()
var latest_snap_tick := 0
var latest_snap_at := 0.0
var camera: Camera3D
var cam_yaw := 0.0
var camera_follow := Vector3.ZERO
var camera_orbit := 0.0
var aim_distance := 22.0
## Mouse-wheel zoom (#140): cam_zoom is the target (persisted in settings), cam_zoom_shown
## eases toward it. Scales the follow-camera boom only: POV aim, replays and cutscenes ignore it.
var cam_zoom := CameraZoom.DEFAULT
var cam_zoom_shown := CameraZoom.DEFAULT
var _mid_drag := 0.0          # mouse travel while the middle button is held (click vs orbit-drag)
const MID_CLICK_SLOP := 6.0   # px: a middle press that moves less than this is a click (reset zoom)
var scoreboard_held := false
var play_picker_open := true
var hud: Label
var pres: Presentation   # visuals-only layer (ball model, rings, FX, overlay)

static func to_world(p: Vector2, h: float = 0.0) -> Vector3:
	return Vector3(p.x, h, -p.y)

## Register a component: it reads state through ctx and joins main's hook loops.
func add_component(c: Node) -> Node:
	c.ctx = ctx
	add_child(c)
	components.append(c)
	return c

func _ready() -> void:
	pres = Presentation.new()
	add_child(pres)
	_build_environment()
	_build_ball_view()
	_build_aim_visuals()
	var args := _cli_args()
	if args.has("leaderboard-file"):
		leaderboard_path = str(args["leaderboard-file"])
	if args.has("ranked-file"):
		ranked_path = str(args["ranked-file"])
	if args.has("name"):
		player_name = str(args["name"]).strip_edges().left(16)
	ranked_match = args.has("ranked")
	if args.has("training-file"):
		training_path = str(args["training-file"])
	if args.has("replay-dir"):
		replay_dir = str(args["replay-dir"])
	if args.has("auto-replay"):
		auto_replay = str(args["auto-replay"]) not in ["0", "false", "off"]
	if args.has("profile-file"):
		profile_path = str(args["profile-file"])
	profile.load_file(profile_path)
	if args.has("equip"):
		for pair in str(args["equip"]).split(","):
			var kv := pair.split(":")
			if kv.size() == 2:
				var v = int(kv[1]) if kv[0] == "number" else kv[1]
				print("EQUIP %s=%s: %s" % [kv[0], kv[1], profile.equip(kv[0], v)])
		profile.save(profile_path)
	if args.has("leaderboard"):
		_print_leaderboards(str(args["leaderboard"]) if args["leaderboard"] is String else "")
		get_tree().quit()
		return
	configure(MatchConfig.normalize(args.get("size", 7)), str(args.get("practice", "")) if args.has("practice") else "",
		str(args.get("mode", "classic")))
	var quarter_minutes := str(args.get("quarter-minutes", "0")).to_float()
	if drill == null and Lobby.valid_quarter_minutes(quarter_minutes):
		series.clock.quarter_length = quarter_minutes * 60.0
		series.clock.reset()
	_setup_net()
	if args.has("replay"):
		open_replay(str(args["replay"]))
	route_art = add_component(RouteArt.new())
	for v in views:
		v.sync()
	camera = Camera3D.new()
	camera.name = "FollowCamera"
	camera.fov = CAMERA_FOV
	add_child(camera)
	var zl := get_node_or_null("/root/Launch")
	if zl != null:
		cam_zoom = CameraZoom.clamp_zoom(zl.settings.camera_zoom)
		cam_zoom_shown = cam_zoom
	camera.make_current()
	hud = Label.new()
	hud.name = "HUD"
	hud.position = Vector2(16, 16)
	var layer := CanvasLayer.new()
	layer.add_child(hud)
	crosshair = Control.new()
	crosshair.name = "Crosshair"
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.visible = false
	crosshair.draw.connect(_draw_crosshair)
	layer.add_child(crosshair)
	taunt_wheel = TauntWheel.new()
	layer.add_child(taunt_wheel)
	add_child(layer)
	replay_overlay = ReplayOverlay.new(self)
	add_child(replay_overlay)

## (Re)build the whole match for a size: field, roster, sim, views. Used at start,
## and on clients when the host's size differs.
func configure(size: int, practice: String = "", mode: String = "classic") -> void:
	if coin_toss != null:
		coin_toss.close_now()   # the old match's toss; the new one plays its own
	_toss_cut_done = false
	play_picker_open = true
	scoreboard_held = false
	camera_orbit = 0.0
	match_mode = "chaosball" if mode == "chaosball" else "classic"
	match_size = 3 if match_mode == "chaosball" else MatchConfig.normalize(size)
	drill = null
	if practice != "":
		drill = Drills.new()
		drill.load_bests(training_path)
		match_size = 7
	for r in [field_root, athlete_root]:
		if r:
			remove_child(r)
			r.queue_free()
	field_root = Node3D.new()
	field_root.name = "FieldRoot"
	add_child(field_root)
	athlete_root = Node3D.new()
	athlete_root.name = "AthleteRoot"
	add_child(athlete_root)
	world = World.new()
	field = world.field
	roster = Roster.new()
	ai = AI.new()
	predictor = Predictor.new()
	interp = Interp.new()
	views = []
	world.set_ruleset(match_mode)
	_spawn_teams()
	_build_field()
	if drill != null:
		TrainingArt.build(field_root, drill, field)
	series = Match.new(world)
	if debug_playclock > 0.0:
		series.clock.play_clock_length = debug_playclock
	_start_series()
	world.event.connect(_on_world_event)
	stats = Stats.new()
	stats.attach(world, owner_name, series, _player_on_athlete)
	replay = Replay.new()
	replay.attach(world)
	replay.meta = {"size": match_size, "mode": match_mode}
	replay_active = false
	replay_auto = false
	replay_shown = -1
	summary_lines = []
	my_summary = []
	if postgame != null:
		postgame.get_parent().queue_free()
		postgame = null
	potg = []
	team_totals = []
	postgame_t = -1.0
	postgame_done = false
	series.match_event.connect(_on_match_event)
	if drill != null:
		world.event.connect(drill.on_event)
		if drill.kind != "scrimmage":
			drill.start_rep(world)
	los_marker = _marker(Color(0.2, 0.5, 1.0), "LOSMarker")
	fd_marker = _marker(Color(1.0, 0.85, 0.1), "FirstDownMarker")
	looks = {}
	if not is_client():
		_sync_looks()
	for v in views:
		v.sync()
	for c in components:
		c.on_configure()

## Host/offline: rebuild athlete looks (yours + peers'), apply to views, broadcast.
func _sync_looks() -> void:
	looks = {}
	looks[my_id] = profile.equipped.duplicate()
	if is_server():
		for peer in net.peer_athlete:
			if peer_looks.has(peer):
				looks[net.peer_athlete[peer]] = peer_looks[peer]
	_apply_looks()
	if is_server():
		net.broadcast_event("looks", {"looks": looks})

func _apply_looks() -> void:
	for aid in looks:
		var i := int(aid)
		if i >= 0 and i < views.size() and views[i].is_inside_tree():
			views[i].apply_look(looks[aid])

func _spawn_teams() -> void:
	var drill_me := -1
	if drill != null:
		MatchConfig.apply_field(world.field, 7)
		drill_me = drill.build(world, _practice_kind())
	if drill_me < 0:
		roster.build(world, match_size)
	my_id = drill_me if drill_me >= 0 else roster.auto_assign(LOCAL_PLAYER)
	var local_team: int = world.get_athlete(my_id).team
	for a in world.athletes:
		var v := PlayerNode.new()
		v.name = "Athlete%d" % a.id
		v.setup(a, TEAM_COLORS[a.team], world, a.team != local_team)
		v.look_node = ball_view   # heads track the ball (#245)
		athlete_root.add_child(v)
		views.append(v)
	controlled_id = my_id
	player = views[controlled_id]
	camera_follow = Vector3(player.athlete.position.x, 0, -player.athlete.position.y)

func _build_ball_view() -> void:
	ball_view = Presentation.make_ball()
	add_child(ball_view)

func _build_aim_visuals() -> void:
	reticle = MeshInstance3D.new()
	reticle.name = "Reticle"
	var q := QuadMesh.new()
	q.size = Vector2(2.2, 2.2)
	q.orientation = PlaneMesh.FACE_Y
	reticle.mesh = q
	var rm := ArtMats.shader("res://src/game/art/ring.gdshader")
	rm.set_shader_parameter("color", Color(1.0, 1.0, 1.0, 0.9))
	rm.set_shader_parameter("dashes", 4.0)
	rm.set_shader_parameter("pulse", 1.0)
	reticle.material_override = rm
	reticle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(reticle)
	for i in ARC_DOTS:
		var d := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r := lerpf(0.05, 0.11, float(i) / ARC_DOTS)
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 8
		sm.rings = 4
		d.mesh = sm
		d.material_override = ArtMats.emissive(Color(1.0, 0.9, 0.3).lerp(Color(1.0, 0.55, 0.15), float(i) / ARC_DOTS), 3.0)
		d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		d.visible = false
		add_child(d)
		arc_dots.append(d)

func _draw_crosshair() -> void:
	var c := crosshair.size * 0.5
	var col := Color(1.0, 0.9, 0.35)
	var shade := Color(0, 0, 0, 0.7)
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		crosshair.draw_line(c + d * 6.0, c + d * 18.0, shade, 5.0)
		crosshair.draw_line(c + d * 6.0, c + d * 18.0, col, 2.5)
	crosshair.draw_circle(c, 3.5, shade)
	crosshair.draw_circle(c, 2.0, col)
	if charging:   # power bar = distance
		var bar := Rect2(c + Vector2(-50, 44), Vector2(100, 8))
		crosshair.draw_rect(bar.grow(2.0), shade)
		crosshair.draw_rect(Rect2(bar.position, Vector2(bar.size.x * charge, bar.size.y)), col.lerp(Color(1.0, 0.45, 0.15), charge))
	# No LOFT N° readout (#131): the view pitch is the loft; the arc dots show the throw.

## True while the human is the passer: QB before the forward pass (Chaosball: any holder).
func pov_active() -> bool:
	if not pov_enabled or replay_active or in_lobby() or world.phase == World.Phase.DEAD or kicking():
		return false   # kicks aim with the camera + aim distance (kick_ball)
	var a = world.get_athlete(controlled_id)
	if a == null:
		return false
	if world.is_chaos():
		return world.ball.is_held_by(controlled_id)
	if a.role != Athlete.Role.QB or a.team != world.offense_team or world.forward_pass_thrown:
		return false
	if world.phase == World.Phase.PRESNAP:
		return true   # the center holds it; you're lining up the throw
	if world.ball_crossed_los:
		return false
	var c = world.carrier()
	return (c == null or c.id == controlled_id) and a.position.y <= world.los_y + 1.0

func aim_dir() -> Vector2:
	return Vector2(sin(aim_yaw), cos(aim_yaw))

func launch_angle() -> float:
	return clampf(rad_to_deg(aim_pitch) + POV_ANGLE_OFFSET, T.POV_ANGLE_MIN, T.POV_ANGLE_MAX)

func reset_aim() -> void:
	aim_yaw = 0.0
	aim_pitch = POV_PITCH_START

## Sim velocity the ball would leave with right now (POV aim, current charge).
func _pov_velocity(qb) -> Vector3:
	return Passing.velocity_for(aim_dir(), launch_angle(), charge) + Vector3(qb.velocity.x, qb.velocity.y, 0) * T.THROW_INHERIT

## Aim point: POV = predicted landing spot; otherwise camera heading + mouse-set range.
func _update_aim() -> void:
	if pov_active():
		var qb = world.get_athlete(controlled_id)
		var from := Vector3(qb.position.x, qb.position.y, T.RELEASE_HEIGHT)
		var v := _pov_velocity(qb)
		var tf := Passing.time_to_height(v, from.z, T.CATCH_HEIGHT, world.gravity())
		aim_point = Vector2(from.x + v.x * tf, from.y + v.y * tf)
		return
	if camera == null or not is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var forward := Vector2.DOWN.rotated(cam_yaw)
	aim_point = player.athlete.position + forward * aim_distance

func _update_arc() -> void:
	var qb = world.get_athlete(controlled_id)
	var show := can_pass() or can_kick()
	reticle.visible = show
	reticle.position = Vector3(aim_point.x, 0.05, -aim_point.y)
	if not show:
		for d in arc_dots:
			d.visible = false
		return
	var from := Vector3(qb.position.x, qb.position.y, T.RELEASE_HEIGHT)
	var v: Vector3
	if pov_active():
		v = _pov_velocity(qb)
	else:
		v = Passing.solve_velocity(from, aim_point, T.PLAYER_PASS_POWER, world.gravity(), lob_held())
	if can_kick():
		from = Vector3(qb.position.x, qb.position.y, T.KICK_HEIGHT)
		v = World.kick_velocity(world.kick_play, qb.position, aim_point, kick_power())
	var tf := Passing.time_to_height(v, from.z, 0.0, world.gravity())
	for i in ARC_DOTS:
		var t := tf * float(i + 1) / ARC_DOTS
		var p := from + v * t + Vector3(0, 0, -0.5 * world.gravity() * t * t)
		arc_dots[i].position = Vector3(p.x, p.z, -p.y)
		arc_dots[i].visible = true

func _set_charging(on: bool) -> void:
	if on and can_kick():
		kick_ball()   # kicks fire on press; passes charge
		return
	if on and world.ball.is_held_by(controlled_id) and not charging:
		charging = true
		charge = 0.0
	elif not on and charging:
		charging = false
		if pov_active():
			do_action({"a": "throw", "d": aim_dir(), "ang": launch_angle(), "p": charge})
		else:
			do_action({"a": "throw", "t": aim_point, "p": charge, "lob": lob_held()})

## Kicks use the same aim as passes (camera direction + aim distance): punts and
## kickoffs land on the reticle; field goals clear the crossbar at it.
func kicking() -> bool:
	return world.kick_play != "" and not world.kicked

func can_kick() -> bool:
	var k = world.get_athlete(controlled_id)
	if not kicking() or k == null or not world.ball.is_held_by(controlled_id) or k.team != world.offense_team:
		return false
	return world.phase == (World.Phase.PRESNAP if world.kick_play == "kickoff" else World.Phase.LIVE)

func kick_power() -> float:
	var k = world.get_athlete(controlled_id)
	var dist: float = k.position.distance_to(aim_point)
	var h := T.CROSSBAR_HEIGHT + 1.5 if world.kick_play == "fg" else 0.0
	return clampf(World.kick_power_for(world.kick_play, dist, h, world.gravity()), 0.0, 1.0)

func kick_ball() -> void:
	if can_kick():
		do_action({"a": "kick", "t": aim_point, "p": kick_power()})

## Coin-toss seed: `--toss=N` for a fixed result, else random.
var toss_seed := -1
var opening_kickoff := true   # false = start on a scrimmage snap (scripted tests)
var toss_cutscene := true     # false = no coin-toss cutscene (budget/HUD tests)
var coin_toss: CoinToss       # the #129 cutscene while it plays
var _toss_cut_done := false   # watched (or skipped) this toss: don't replay it

## #129: the coin-toss cutscene plays whenever the match sits in its TOSS state (opening
## kickoff; overtime reuses it). Presentation only: it follows series.state, never drives it.
func _update_coin_toss() -> void:
	var tossing := series.state == Match.State.TOSS and drill == null and not in_lobby() and not replay_active
	if not tossing:
		_toss_cut_done = false
	elif coin_toss == null and toss_cutscene and not _toss_cut_done:
		_toss_cut_done = true
		coin_toss = CoinToss.new()
		coin_toss.setup(self)
		coin_toss.closed.connect(func(): coin_toss = null)
		add_child(coin_toss)

func _start_series() -> void:
	if drill != null or match_mode == "chaosball" or not opening_kickoff or _cli_args().has("no-kickoff"):
		series.start(0, Drills.LOS if drill != null else -1.0)
		return
	var s := toss_seed if toss_seed >= 0 else int(_cli_args().get("toss", randi() % 2))
	var winner_humans := false
	for id in [my_id] + roster.humans():
		var a = world.get_athlete(id)
		if a and a.team == posmod(s, 2):
			winner_humans = true
	series.start_match(s, winner_humans)

func _player_on_athlete(aid: int) -> int:
	var slot := roster.slot_of_athlete(aid)
	return roster.slots[slot]["owner"] if slot >= 0 else (LOCAL_PLAYER if aid == my_id else -1)

## Display name of whoever controls athlete `aid` right now ("Bot" for AI).
func owner_name(aid: int) -> String:
	var owner := _player_on_athlete(aid)
	if owner < 0:
		return "Bot"
	if lobby.players.has(owner):
		return str(lobby.players[owner]["name"])
	return player_name if owner == LOCAL_PLAYER else "P%d" % owner

func _print_leaderboards(pos: String) -> void:
	var lb := Leaderboard.new()
	lb.load_file(leaderboard_path)
	for p in ([pos] if pos != "" else lb.positions()):
		print(lb.table_text(p, Leaderboard.MAX_ROWS))

## Host/offline: fold this match into the persistent leaderboard; return your ranks.
func _record_leaderboard() -> String:
	var lb := Leaderboard.new()
	lb.load_file(leaderboard_path)
	lb.record_match(stats.to_dict())
	lb.save(leaderboard_path)
	var me := owner_name(my_id)
	var ranks := []
	for k in stats.lines:
		if k.get_slice("|", 0) == me:
			var pos: String = k.get_slice("|", 1)
			ranks.append("%s #%d" % [pos, lb.rank_of(me, pos)])
	return ", ".join(ranks)

## This install's stable id (#102): minted once, saved with the profile when a ranked result lands.
func install_id() -> String:
	if profile.install_id == "":
		profile.install_id = Crypto.new().generate_random_bytes(8).hex_encode()
		install_id_unsaved = true
	return profile.install_id

func _persist_install_id() -> void:
	if install_id_unsaved:
		install_id_unsaved = false
		profile.save(profile_path)

## Ranked record key for player `owner` (seated on athlete `aid`): their install id, or, for a peer that
## never sent one (older build), their display name as before #102.
func ranked_key(owner: int, aid: int) -> String:
	if owner == LOCAL_PLAYER:
		return Ranked.id_key(install_id())
	if peer_installs.has(owner):
		return Ranked.id_key(peer_installs[owner])
	return owner_name(aid)

## Host: Elo update for every human by final team. Returns {"deltas", "labels", "ratings"}, each keyed by
## athlete id: every machine finds its own line by my_id, and nobody's install id leaves the host.
func _record_ranked() -> Dictionary:
	var rk := Ranked.new()
	rk.load_file(ranked_path)
	rk.ensure_season(Ranked.season_id(Time.get_unix_time_from_system()))
	var teams := [[], []]
	var names := {}
	var key_of := {}   # athlete id -> record key
	for s in roster.slots:
		if s["owner"] >= 0:
			var key := ranked_key(s["owner"], s["athlete_id"])
			var nm := owner_name(s["athlete_id"])
			rk.claim(key, nm)
			key_of[s["athlete_id"]] = key
			names[key] = nm
			if not teams[s["team"]].has(key):
				teams[s["team"]].append(key)
	var w := series.winner()
	var deltas := rk.record_match(teams[0], teams[1], 0.5 if w < 0 else (1.0 if w == 0 else 0.0), names)
	rk.save(ranked_path)
	_persist_install_id()
	var out := {"deltas": {}, "labels": {}, "ratings": {}}
	for aid in key_of:
		if deltas.has(key_of[aid]):
			out["deltas"][aid] = deltas[key_of[aid]]
			out["labels"][aid] = rk.label(key_of[aid])
			out["ratings"][aid] = rk.rating(key_of[aid])
	return out

func _ranked_text(r: Dictionary) -> String:
	var deltas = r.get("deltas", {})
	var labels = r.get("labels", {})
	if not (deltas is Dictionary and labels is Dictionary and deltas.has(my_id) and labels.has(my_id)):
		return ""
	return "RATING %s (%+d)" % [str(labels[my_id]), int(round(float(deltas[my_id])))]

## XP and achievement context per human, addressed to their athlete at final.
func _match_awards(ratings: Dictionary) -> Dictionary:
	var xp := {}
	var ctx := {}
	var recipients := roster.humans() if not roster.slots.is_empty() else [my_id]
	var winner: int = series.winner()
	for aid in recipients:
		var team: int = world.get_athlete(aid).team
		var line: Dictionary = stats.award_stats.get(_player_on_athlete(aid), {})
		var won := winner == team
		xp[aid] = Cosmetics.award_xp(line, won)
		ctx[aid] = {"line": line, "won": won, "deficit": series.max_deficit[team],
			"rating": ratings.get(aid, 0.0), "mode": match_mode}
	return {"xp": xp, "ctx": ctx}

## Older clients read the award by name. Include aliases only for unique names.
func _broadcast_match_awards(awards: Dictionary) -> void:
	var athlete_by_name := {}
	for aid in awards["xp"]:
		var display_name := owner_name(aid)
		athlete_by_name[display_name] = -1 if athlete_by_name.has(display_name) else aid
	for display_name in athlete_by_name:
		var aid: int = athlete_by_name[display_name]
		if aid >= 0:
			awards["xp"][display_name] = awards["xp"][aid]
			awards["ctx"][display_name] = awards["ctx"][aid]
	net.broadcast_event("awards", awards)

## Every machine credits only its own player's local profile (XP + achievements).
func _apply_award(xp: Dictionary, ctx: Dictionary = {}) -> void:
	var me: Variant = my_id
	if not xp.has(me):
		me = player_name if is_client() else owner_name(my_id)
	var amount = xp.get(me)
	if not (amount is int and amount >= 0 and amount <= Cosmetics.MAX_MATCH_XP):
		return
	var context = ctx.get(me)
	if ctx.has(me) and not Achievements.valid_match_context(context):
		return
	var total: int = amount
	profile.games += 1
	var unlocked := []
	if context is Dictionary:
		var c: Dictionary = context.duplicate()
		c["games"] = profile.games
		for a in Achievements.evaluate(c, profile.achievements):
			profile.achievements.append(a["id"])
			unlocked.append(a["name"])
			total += int(a["xp"])
	var gained := profile.add_xp(total)
	profile.save(profile_path)
	xp_line = "XP +%d (Level %d%s)" % [total, profile.level(), " - LEVEL UP!" if gained > 0 else ""]
	achievement_line = ("ACHIEVEMENTS: " + ", ".join(unlocked)) if not unlocked.is_empty() else ""

func _on_match_event(n: String, data: Dictionary) -> void:
	for c in components:
		c.on_match_event(n, data)
	if n in ["timeout", "clock_warning", "penalty"]:   # #253: penalty rulings reach the HUD and clients
		_on_world_event(n, data)
	if n in ["quarter", "halftime"]:
		ai.reset_presnap()
	if n == "final" and drill == null:
		saved_replay = _save_replay()
		print("REPLAY saved: %s" % saved_replay)
	if n == "final":
		if not is_client() and drill == null:
			my_ranks = _record_leaderboard()
			var ratings := {}
			if ranked_match:
				var r := _record_ranked()
				var rk := Ranked.new()
				rk.load_file(ranked_path)
				profile.season_rewards = rk.rewards.get(ranked_key(LOCAL_PLAYER, my_id), [])
				ratings = r["ratings"]
				ranked_line = _ranked_text(r)
				print("RANKED: %s" % str(r))
				if is_server():
					net.broadcast_event("ranked", r)
			var awards := _match_awards(ratings)
			_apply_award(awards["xp"], awards["ctx"])
			if is_server():
				_broadcast_match_awards(awards)
		summary_lines = stats.summary_lines()
		print("MATCH SUMMARY:\n  " + "\n  ".join(summary_lines))
		if replay_auto and not replay_viewer:   # the final whistle beats a highlight (V replays it in the reel)
			stop_replay()
		if drill == null and not is_client():
			potg = _decorate_potg(Potg.pick(stats.athletes, series.winner()))
			team_totals = Potg.team_totals(stats.athletes)
			print("PLAYERS OF THE GAME: %s" % ", ".join(potg.map(func(e): return "%s (%s %s)" % [e["name"], e["pos"], e["score"]])))
			_queue_postgame()
		if is_server():
			# Each client picks its own lines by athlete id (#200), as with "awards".
			net.broadcast_event("summary", {"lines": summary_lines, "potg": potg, "teams": team_totals,
				"mine": stats.summaries_for(roster.humans())})

## Display name, jersey number and cosmetics for each pick (sent to clients as-is).
func _decorate_potg(picks: Array) -> Array:
	for e in picks:
		var aid: int = e["id"]
		var lk: Dictionary = looks.get(aid, {})
		e["name"] = "CPU" if e["owner"] == "Bot" else e["owner"]
		e["number"] = int(lk.get("number", (aid % 90) + 10))
		e["look"] = lk.duplicate()
	return picks

# --- post-game: FINAL hold -> players of the game -> lobby ------------------

func _queue_postgame() -> void:
	if replay_viewer or postgame_done or postgame_t >= 0.0:
		return
	postgame_t = 0.0

func _tick_postgame(delta: float) -> void:
	if postgame_t < 0.0 or postgame != null:
		return
	postgame_t += delta
	if postgame_t >= POSTGAME_HOLD:
		start_postgame()

## Show the players-of-the-game presentation (skipped when nobody recorded a stat).
func start_postgame() -> void:
	if postgame != null or postgame_done:
		return
	if replay_active and not replay_viewer:
		stop_replay()
	if potg.is_empty():
		finish_postgame()
		return
	var layer := CanvasLayer.new()
	layer.name = "Postgame"
	layer.layer = 60     # over the match HUD, under the Esc menu (90)
	postgame = PotgStage.new()
	postgame.setup(potg, {"score": series.score.duplicate(), "winner": series.winner(),
		"team_colors": TEAM_COLORS, "team_names": Potg.TEAM_NAMES,
		"local_team": world.get_athlete(my_id).team})
	postgame.finished.connect(finish_postgame)
	layer.add_child(postgame)
	add_child(layer)

## Everything the lobby's game overview shows, as plain data.
func match_overview() -> Dictionary:
	var me := player_name if is_client() else owner_name(my_id)
	var mine := my_summary if is_client() else stats.player_summary(_player_on_athlete(my_id))
	var my_team: int = world.get_athlete(my_id).team if world.get_athlete(my_id) else 0
	return {"score": series.score.duplicate(), "winner": series.winner(), "my_team": my_team,
		"team_names": Potg.TEAM_NAMES, "mode": match_mode, "size": match_size, "ranked": ranked_match,
		"online": net != null, "me": me, "potg": potg, "teams": team_totals,
		"my_lines": mine,
		"xp": xp_line, "achievements": achievement_line, "rating": ranked_line, "ranks": my_ranks,
		"replay": saved_replay, "when": Time.get_datetime_string_from_system(false, true)}

## Presentation over: back to the lobby (menu launches) with the game overview.
func finish_postgame() -> void:
	if postgame_done:
		return
	postgame_done = true
	var ov := match_overview()
	print("POSTGAME done -> lobby overview: %s" % str(ov["score"]))
	if postgame != null:
		postgame.get_parent().queue_free()
		postgame = null
	var launch := get_node_or_null("/root/Launch")
	if launch and launch.from_menu:
		launch.go_to_menu("", ov)

## Ctrl held on release = lob (high arc; catch your own pass in Chaosball).
var lob_override = null
func lob_held() -> bool:
	return lob_override if lob_override != null else Input.is_key_pressed(KEY_CTRL)

## All human actions go through here: local authority offline/host, sent to server as client.
func do_action(action: Dictionary) -> bool:
	if is_client():
		net.send_action(action)
		return true
	return Protocol.apply_action(series, controlled_id, action)

func is_client() -> bool:
	return net != null and net.mode == NetSession.Mode.CLIENT

func is_server() -> bool:
	return net != null and net.mode == NetSession.Mode.SERVER

func _cli_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else true
	var launch := get_node_or_null("/root/Launch")   # main menu choices (src/ui/launch.gd)
	if launch:
		out.merge(launch.options, true)
	return out

var port_mapping_notice := ""

func _setup_net() -> void:
	var args := _cli_args()
	port_mapping_notice = str(args.get("port-mapping-notice", ""))
	if args.has("matchmaker"):
		var mms := MMServer.new()
		mms.name = "Matchmaker"
		add_child(mms)
		var p := int(args.get("port", MMServer.DEFAULT_PORT))
		print("MM server on %d: %s" % [p, error_string(mms.start(p))])
		return
	if args.has("queue"):
		_queue_up(args)
		return
	if not (args.has("host") or args.has("join")):
		return
	var port := int(args.get("port", NetSession.DEFAULT_PORT))
	if args.has("host"):
		_host_game(port, host_options(args))
	else:
		_join_game(str(args["join"]), port, {})

## _host_game opts from launch args (CLI flags or the menu's Launch.options). The rules
## (--mode=chaosball) travel as "game", the key _host_game and matchmade hosts use (#74).
func host_options(args: Dictionary) -> Dictionary:
	return {"playclock": float(args.get("playclock", -1.0)), "no_lobby": args.has("no-lobby"),
		"start_when_ready": args.has("start-when-ready"), "advertise": str(args.get("advertise", _local_ipv4())),
		"game": "chaosball" if str(args.get("mode", "")) == "chaosball" else "classic"}

func _ensure_net() -> void:
	if net == null:
		net = NetSession.new()
		net.name = "Net"
		add_child(net)

## Open a hosted match (lobby by default). opts: playclock, no_lobby, start_when_ready, advertise, expected, size, mode
func _host_game(port: int, opts: Dictionary) -> String:
	_ensure_net()
	var playclock: float = opts.get("playclock", -1.0)
	if playclock > 0.0 and is_finite(playclock):
		debug_playclock = playclock
		series.clock.play_clock_length = playclock
		series.clock.new_play()
	net.match_size = match_size
	var err := net.host(port, func(peer): return roster.auto_assign(peer), func(peer): roster.release(peer))
	print("NET host on %d: %s" % [port, error_string(err)])
	if err != OK:   # #299: no lobby and no invite code for a port we don't hold
		net.queue_free()
		net = null
		_host_failed.call_deferred(port)
		return ""
	if opts.get("no_lobby", false):
		return ""
	lobby = Lobby.new()
	lobby.host_id = LOCAL_PLAYER
	lobby.add(LOCAL_PLAYER, player_name if player_name != "You" else "Host")
	lobby.settings["size"] = MatchConfig.normalize(opts.get("size", match_size))
	var quarter_minutes := series.clock.quarter_length / 60.0   # e.g. from --quarter-minutes
	if Lobby.valid_quarter_minutes(quarter_minutes):
		lobby.settings["quarter_minutes"] = quarter_minutes
	if opts.get("game", "classic") == "chaosball":
		lobby.settings["mode"] = "chaosball"
		lobby.settings["size"] = 3
	lobby.expected = int(opts.get("expected", 0))
	lobby.code = InviteCode.encode(str(opts.get("advertise", _local_ipv4())), port)
	if opts.get("start_when_ready", false):
		lobby.set_ready(LOCAL_PLAYER, true)
	net.lobby = lobby
	net.lobby_mode = true
	net.lobby_changed.connect(func(): net.broadcast_lobby(lobby.to_dict()))
	print("NET invite code: %s" % lobby.code)
	return lobby.code

## Join a match by invite code or address. opts: auto_ready
func _join_game(target: String, port: int, opts: Dictionary) -> void:
	_ensure_net()
	if InviteCode.looks_like_code(target):
		var d := InviteCode.decode(target)
		target = d["ip"]
		port = d["port"]
	var err := net.join(target, port)
	print("NET join %s:%d: %s" % [target, port, error_string(err)])
	if err != OK:
		_show_connection_failure.call_deferred(HOST_UNREACHABLE_STATUS)
		return
	net.connection_failed.connect(_show_connection_failure.bind(HOST_UNREACHABLE_STATUS), CONNECT_DEFERRED)
	auto_next = false
	net.welcomed.connect(_on_assigned)
	var auto_ready: bool = opts.get("auto_ready", false)
	var readied := [false]
	net.lobby_received.connect(func(st):
		lobby.from_dict(st)
		if not readied[0] and lobby.phase == Lobby.Phase.LOBBY:
			readied[0] = true
			if player_name != "You":
				net.send_lobby_action({"a": "name", "n": player_name})
			net.send_lobby_action({"a": "id", "i": install_id()})
			if seat_token != "":
				net.send_lobby_action({"a": "seat", "s": seat_token})
			if auto_ready:
				net.send_lobby_action({"a": "ready"}))
	net.snapshot_received.connect(_on_snapshot)
	net.event_received.connect(func(n, data):
		if n == "snap":
			replay.context = "%s, %s" % [series.clock.label(), series.downs.label()]
		replay.record_event(n, data)
		_on_world_event(n, data))
	net.host_lost.connect(_on_host_lost)
	add_child(preload("res://src/game/link_banner.gd").new(net))   # #86: "Connection to host lost…"

const HOST_LOST_STATUS := "Host disconnected"
const HOST_UNREACHABLE_STATUS := "Couldn't reach the host"
const MATCHMAKER_UNREACHABLE_STATUS := "Couldn't reach the matchmaker"
const HOST_BIND_FAILED_STATUS := "Couldn't host on port %d. Is another game using it?"

## #299: hosting couldn't bind its UDP port (another process holds it). A menu launch goes
## back to the menu saying so; a CLI/headless host exits non-zero.
func _host_failed(port: int) -> void:
	var launch := get_node_or_null("/root/Launch")
	if launch != null and launch.from_menu:
		_show_connection_failure(HOST_BIND_FAILED_STATUS % port)
	else:
		get_tree().quit(1)

func _show_connection_failure(status: String) -> void:
	if not is_inside_tree() or get_tree().current_scene != self:
		return
	var launch := get_node_or_null("/root/Launch")
	if launch != null:
		launch.go_to_menu(status)

## #56: the host quit or dropped. Back to the menu saying why; a finished match keeps
## its game overview (the host leaving after the final whistle is normal).
func _on_host_lost() -> void:
	var launch := get_node_or_null("/root/Launch")
	if launch == null:
		return
	var over: bool = postgame != null or postgame_t >= 0.0
	launch.go_to_menu(HOST_LOST_STATUS, match_overview() if over and not postgame_done else {})

## Queued for matchmaking and not yet hosting/joining a match.
func searching() -> bool:
	return mm_client != null and net == null

## Matchmaking: queue, then host or join as the matchmaker decides.
var mm_client: MMClient
func _queue_up(args: Dictionary) -> void:
	mm_client = MMClient.new()
	mm_client.name = "Queue"
	add_child(mm_client)
	var addr := str(args.get("mm", "127.0.0.1"))
	var mm_port := MMServer.DEFAULT_PORT
	if addr.find(":") > 0:
		mm_port = int(addr.get_slice(":", 1))
		addr = addr.get_slice(":", 0)
	var mode := str(args["queue"])
	seat_token = Crypto.new().generate_random_bytes(8).hex_encode()   # independent of any seed()
	var advertise := str(args.get("advertise", _local_ipv4()))
	mm_client.host_match.connect(func(m):
		_end_warmup(args)
		ranked_match = m.get("mode", "") == "competitive"
		pending_teams = m.get("teams", {}) if m.get("teams") is Dictionary else {}
		pending_seats = m.get("seats", {}) if m.get("seats") is Dictionary else {}
		var port := int(args.get("host-port", 25000 + randi() % 5000))
		var code := _host_game(port, {"start_when_ready": true, "expected": int(m.get("expected", 2)),
			"size": int(m.get("size", 7)), "advertise": advertise, "game": str(m.get("game", "classic"))})
		if code == "":   # couldn't bind (#299); the waiting joiners are #303
			return
		lobby.settings["quarter_minutes"] = Lobby.DEFAULT_QUARTER_MINUTES
		print("QUEUE matched (%s): hosting %s" % [m.get("mode", "?"), code])
		mm_client.send_hosting(code))
	mm_client.host_cancelled.connect(_retry_after_host_timeout.bind(args), CONNECT_DEFERRED)
	mm_client.join_match.connect(func(code):
		_end_warmup(args)
		print("QUEUE matched: joining %s" % code)
		_join_game(code, 0, {"auto_ready": true}))
	var rk := Ranked.new()
	rk.load_file(ranked_path)
	var my_key := Ranked.id_key(install_id())
	rk.claim(my_key, player_name)
	var err := mm_client.queue_up(addr, mm_port, mode, MatchConfig.normalize(args.get("size", 7)),
		float(args.get("rating", rk.rating(my_key))), player_name,
		str(args.get("party", "")).get_slice(":", 0), int(str(args.get("party", "x:1")).get_slice(":", 1)) if str(args.get("party", "")).find(":") > 0 else 1,
		"chaosball" if str(args.get("mode", "")) == "chaosball" else "classic", seat_token)
	print("QUEUE %s via %s:%d: %s" % [mode, addr, mm_port, error_string(err)])
	if err != OK:
		_show_connection_failure.call_deferred(MATCHMAKER_UNREACHABLE_STATUS)
		return
	mm_client.failed.connect(_show_connection_failure.bind(MATCHMAKER_UNREACHABLE_STATUS), CONNECT_DEFERRED)
	mm_client.refused.connect(_show_connection_failure, CONNECT_DEFERRED)   # #165: version mismatch -> menu says why
	_begin_queue_wait(args)

## #308: abandon the empty game lobby while keeping the separate matchmaker connection.
func _retry_after_host_timeout(args: Dictionary) -> void:
	if not is_server() or not in_lobby():
		return
	net.peer.close()
	net.queue_free()
	net = null
	lobby = Lobby.new()
	pending_teams.clear()
	pending_seats.clear()
	peer_seats.clear()
	peer_installs.clear()
	ranked_match = false
	if not mm_client.is_open():
		_show_connection_failure(MATCHMAKER_UNREACHABLE_STATUS)
		return
	print("QUEUE host order timed out. Searching again.")
	_begin_queue_wait(args)
	mm_client.retry_as_solo()

func _begin_queue_wait(args: Dictionary) -> void:
	queue_started_ms = Time.get_ticks_msec()
	# Waiting lobby: warm up on the training ground until the match is found.
	if not args.has("no-warmup"):
		start_practice("hub")
		print("QUEUE warm-up: training ground")

## Match found: leave the training ground and rebuild the queued match's world.
func _end_warmup(args: Dictionary) -> void:
	if drill == null:
		return
	configure(MatchConfig.normalize(args.get("size", 7)), "", str(args.get("mode", "classic")))
	print("QUEUE warm-up over: match found")

## "SEARCHING FOR A CASUAL MATCH  0:42" while queued.
func queue_text() -> String:
	var secs := int((Time.get_ticks_msec() - queue_started_ms) / 1000)
	return "SEARCHING FOR A %s MATCH  %d:%02d" % [str(_cli_args().get("queue", "")).to_upper(), secs / 60, secs % 60]

func _practice_kind() -> String:
	if _pending_practice != "":
		return _pending_practice
	var k := str(_cli_args().get("practice", ""))
	return k if Drills.valid(k) else "passing"

var _pending_practice := ""

## Start an offline practice session (also used by tests).
func start_practice(kind: String) -> void:
	_pending_practice = kind
	configure(7, kind)
	_pending_practice = ""

func _local_ipv4() -> String:
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			return a
	return "127.0.0.1"

## True while the private lobby is open (server) / we haven't been placed yet (client).
func in_lobby() -> bool:
	if searching():
		return drill == null   # queued + warming up on the training ground = playable
	if is_server():
		return net.lobby_mode and lobby.phase == Lobby.Phase.LOBBY
	if is_client():
		return net.my_athlete < 0
	return false

## Lobby input: Enter = ready. The host can select size, mode and quarter length (#130: always quarters).
func lobby_key(keycode: int) -> void:
	if is_client():
		if keycode == KEY_ENTER:
			net.send_lobby_action({"a": "ready"})
		return
	var changed := false
	match keycode:
		KEY_ENTER: changed = lobby.toggle_ready(LOCAL_PLAYER)
		KEY_3: changed = lobby.set_setting(LOCAL_PLAYER, "size", 3)
		KEY_5: changed = lobby.set_setting(LOCAL_PLAYER, "size", 5)
		KEY_7: changed = lobby.set_setting(LOCAL_PLAYER, "size", 7)
		KEY_M:
			changed = lobby.set_setting(LOCAL_PLAYER, "mode", "chaosball" if lobby.settings.get("mode", "classic") == "classic" else "classic")
		KEY_I:
			changed = lobby.set_setting(LOCAL_PLAYER, "pass_marker", not lobby.settings["pass_marker"])
		KEY_H:
			var choices := Lobby.QUARTER_MINUTES
			var i := (choices.find(lobby.settings["quarter_minutes"]) + 1) % choices.size()
			changed = lobby.set_setting(LOCAL_PLAYER, "quarter_minutes", choices[i])
	if changed:
		net.broadcast_lobby(lobby.to_dict())

## Server: lobby tick — apply client lobby actions, start when everyone is ready.
func _step_lobby() -> void:
	var changed := false
	for la in net.take_lobby_actions():
		match la[1].get("a", ""):
			"ready": changed = lobby.toggle_ready(la[0]) or changed
			"name": changed = lobby.set_name(la[0], str(la[1].get("n", ""))) or changed
			"seat": peer_seats[la[0]] = str(la[1].get("s", "")).left(32)
			"id":
				if Cosmetics.valid_install_id(la[1].get("i")):
					peer_installs[la[0]] = la[1]["i"]
	if changed:
		net.broadcast_lobby(lobby.to_dict())
	if lobby.all_ready():
		_start_from_lobby()

func _start_from_lobby() -> void:
	if not lobby.start():
		return
	configure(lobby.settings["size"], "", lobby.settings.get("mode", "classic"))
	series.clock.quarter_length = lobby.settings["quarter_minutes"] * 60.0
	series.clock.reset()
	net.match_size = match_size
	net.match_mode = match_mode
	# Queue match: seat everyone on the matchmaker's team, by seat token (name only for
	# older clients that sent none). Two players can share a display name (#59).
	var host_team := Matchmaker.drafted_team(seat_token, lobby.players[LOCAL_PLAYER]["name"], pending_seats, pending_teams)
	if host_team >= 0 and world.get_athlete(my_id).team != host_team:
		my_id = roster.swap_team(LOCAL_PLAYER)
		set_controlled(my_id)
	for id in lobby.players:
		if id == LOCAL_PLAYER:
			continue
		var t := Matchmaker.drafted_team(str(peer_seats.get(id, "")), lobby.players[id]["name"], pending_seats, pending_teams)
		var aid := roster.auto_assign_team(id, t) if t >= 0 else roster.auto_assign(id)
		if aid >= 0:
			net.set_assignment(id, aid)
	net.broadcast_lobby(lobby.to_dict())
	_sync_looks()
	var seats := []
	for s in roster.slots:
		if s["owner"] >= 0:
			seats.append("%s->%d" % [owner_name(s["athlete_id"]), s["team"]])
	print("NET match started: %s" % lobby.summary())
	print("NET seats: %s (ranked=%s, teams=%s, seats=%d)" % [", ".join(seats), ranked_match, str(pending_teams), pending_seats.size()])

## Client: server (re)assigned our athlete (join, position change, team swap).
func _on_assigned(aid: int) -> void:
	if net.host_size != match_size or net.host_mode != match_mode:
		configure(net.host_size, "", net.host_mode)
	my_id = aid
	predictor = Predictor.new()
	set_controlled(aid)
	print("NET assigned athlete %d" % aid)
	# Our look goes to the host; we only show it once the host echoes it back.
	net.send_action({"a": "look", "look": profile.equipped})

## Client: authoritative state in, then re-predict own athlete on top of it.
func _on_snapshot(snap: Dictionary) -> void:
	var old_phase := world.phase
	Protocol.apply_snapshot(series, snap)
	if old_phase != world.phase and world.phase == World.Phase.PRESNAP:
		play_picker_open = true
		camera_orbit = 0.0
	interp.push(int(snap["t"]), Interp.xy_from_snapshot(snap), Interp.ball_from_snapshot(snap))
	latest_snap_tick = int(snap["t"])
	latest_snap_at = Time.get_ticks_msec() / 1000.0
	var me = world.get_athlete(my_id)
	if me:
		predictor.reconcile(me, int(snap.get("ack", {}).get(my_id, 0)), world)

## Client: draw others ~100 ms in the past, interpolated between snapshots.
func _apply_interpolation() -> void:
	if interp.buf.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var t := latest_snap_tick / Interp.TICK_RATE + (now - latest_snap_at) - INTERP_DELAY
	var smp := interp.sample(t)
	var xy: PackedFloat32Array = smp["xy"]
	for i in mini(world.athletes.size(), xy.size() / 2):
		if i != my_id:
			world.athletes[i].position = Vector2(xy[i * 2], xy[i * 2 + 1])
	if not world.ball.is_held_by(my_id):
		world.ball.position = smp["ball"]

func _unhandled_input(e: InputEvent) -> void:
	var launch := get_node_or_null("/root/Launch")
	if in_lobby() or replay_active or (launch != null and launch.menu_open()):
		return
	if e is InputEventMouseMotion and taunt_wheel.open:
		taunt_wheel.drag(e.relative)   # #139: the mouse picks a taunt; camera and aim hold still
		return
	if e is InputEventMouseMotion and pov_active() and mouse_captured():
		look(e.relative)   # passer: mouse X = direction, mouse Y = loft
	elif e is InputEventMouseMotion and (mouse_captured()
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)):
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			_mid_drag += e.relative.length()
		camera_orbit = wrapf(camera_orbit - e.relative.x * 0.004, -PI, PI)
		cam_yaw = _camera_target_yaw()
		aim_distance = clampf(aim_distance - e.relative.y * 0.22, 2.0, 65.0)
		_update_aim()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if pov_active():
			_set_charging(e.pressed)   # hold = power (distance), release = throw
		elif e.pressed:
			throw_pass()
	elif e is InputEventMouseButton and e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var notches: float = e.factor if e.factor > 0.0 else 1.0   # trackpads send fractions
		zoom_camera(notches if e.button_index == MOUSE_BUTTON_WHEEL_UP else -notches)
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_MIDDLE:
		if e.pressed:
			_mid_drag = 0.0
		elif _mid_drag < MID_CLICK_SLOP:
			reset_camera_zoom()   # a middle click (not an orbit drag) resets the zoom

## Wheel zoom (#140): + notches = wheel up = closer. Ignored (returns false) in the passer's
## POV aim (the wheel must never move a throw), while the taunt wheel is open, in replays and
## during the coin-toss cutscene (#129 poses the camera itself).
func zoom_camera(notches: float) -> bool:
	if not _zoom_input_ok():
		return false
	set_camera_zoom(CameraZoom.step(cam_zoom, notches))
	return true

func reset_camera_zoom() -> bool:
	if not _zoom_input_ok():
		return false
	set_camera_zoom(CameraZoom.DEFAULT)
	return true

func _zoom_input_ok() -> bool:
	return not (pov_active() or taunt_wheel.open or replay_active or in_lobby() or coin_toss != null)

## Sets the target zoom (clamped) and saves it with the player's settings. Headless runs
## save only to an explicit --settings-file, like Launch loads (tests never touch real saves).
func set_camera_zoom(z: float) -> void:
	z = CameraZoom.clamp_zoom(z)
	if z == cam_zoom:
		return
	cam_zoom = z
	var launch := get_node_or_null("/root/Launch")
	if launch == null:
		return
	launch.settings.camera_zoom = cam_zoom
	if DisplayServer.get_name() != "headless" or launch.settings_path != launch.SettingsStore.DEFAULT_PATH:
		launch.settings.save(launch.settings_path)

## Tests set this: headless can't capture the mouse, so mouse-look would never run.
var mouse_captured_override = null

func mouse_captured() -> bool:
	return mouse_captured_override if mouse_captured_override != null else Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

## POV mouse look (pixels of mouse motion). aim_yaw: + = right of downfield.
func look(rel: Vector2) -> void:
	aim_yaw = wrapf(aim_yaw + rel.x * POV_SENS, -PI, PI)
	aim_pitch = clampf(aim_pitch - rel.y * POV_SENS, POV_PITCH_MIN, POV_PITCH_MAX)

## Hold C: open the taunt wheel (#139). Release picks; see taunt_wheel.gd.
func open_taunt_wheel() -> bool:
	if in_lobby() or replay_active:
		return false
	taunt_wheel.open_wheel()
	return true

## Perform a taunt. Only its id goes over the wire ("emote" action).
func taunt(id: String) -> bool:
	if id == "" or in_lobby() or replay_active:
		return false
	return do_action({"a": "emote", "e": id})


func _on_world_event(n: String, d: Dictionary) -> void:
	if pres:
		pres.on_event(n, d)
	for c in components:
		c.on_world_event(n, d)
	if n == "incomplete" and last_whistle == "":
		last_whistle = "INCOMPLETE"
	if n in ["tackle", "out_of_bounds", "breakup", "touchdown", "explode", "touchback", "kick_out_of_bounds", "kick_downed", "fair_catch"]:
		last_whistle = n.replace("kick_", "").replace("_", " ").to_upper()
	if n == "field_goal":
		last_whistle = "FIELD GOAL GOOD" if d.get("good", false) else "FIELD GOAL NO GOOD"
		banner = "IT'S GOOD!" if d.get("good", false) else "NO GOOD!"
		banner_t = 2.0
	if n == "kick_blocked":
		banner = "BLOCKED!"
		banner_t = 2.0
	if n == "ranked":
		ranked_line = _ranked_text(d)
		_persist_install_id()
	if n == "looks" and d.get("looks") is Dictionary:
		looks = d["looks"]
		_apply_looks()
	if n == "awards" and d.get("xp") is Dictionary:
		_apply_award(d["xp"], d.get("ctx", {}) if d.get("ctx") is Dictionary else {})
	if n == "emote":
		var eid: int = d.get("by", -1)
		if eid >= 0 and eid < views.size():
			views[eid].emote(str(d.get("e", "")))
	if n == "touchdown":
		var cid: int = d.get("carrier", -1)
		if cid >= 0 and cid < views.size():
			views[cid].celebrate(str(looks.get(cid, {}).get("celebration", "none")))
	if n == "summary":
		summary_lines = d.get("lines", []) if d.get("lines") is Array else []
		potg = d.get("potg", []) if d.get("potg") is Array else []
		team_totals = d.get("teams", []) if d.get("teams") is Array else []
		var mine = d.get("mine", {}).get(my_id, []) if d.get("mine") is Dictionary else []
		my_summary = mine.map(func(l): return str(l)) if mine is Array else []
		if is_client():
			_queue_postgame()
	if n == "snap":
		last_whistle = ""
	if n in ["interception", "fumble", "recovery"]:
		banner = {"interception": "INTERCEPTION!", "fumble": "FUMBLE!", "recovery": "RECOVERED!"}[n]
		banner_t = 2.0
	if is_server():
		net.broadcast_event(n, d)
func _marker(c: Color, n: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(field.width, 0.55)
	q.orientation = PlaneMesh.FACE_Y
	mi.mesh = q
	var m := ArtMats.shader("res://src/game/art/line_marker.gdshader")
	m.set_shader_parameter("color", c)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = n
	field_root.add_child(mi)
	return mi

## Defense pre-snap HUD: stance state for the local athlete. `roam_key` (from
## roam_hint_key) adds the first-time "<key> ×2 TO ROAM" hint to a set defender (#183).
static func presnap_defense_prompt(a, roam_key := "") -> String:
	if a == null:
		return "PRE-SNAP"
	if a.role == Athlete.Role.DL:
		return "PRE-SNAP (hold your stance)"
	if not a.set_lock:
		return "PRE-SNAP: ROAMING"
	return "PRE-SNAP: SET" if roam_key == "" else "PRE-SNAP: SET  ·  %s ×2 TO ROAM" % roam_key

## #183: true once the player has broken stance this session (static: survives the
## scene reload between matches, resets on relaunch; nothing is saved).
static var roamed_once := false

## The bound snap key's name while the local defender is set and hasn't roamed yet this
## session, else "". Keyboard name only: pads aren't tracked yet (#309).
func roam_hint_key() -> String:
	if roamed_once or not world.can_break_stance(world.get_athlete(my_id)):
		return ""
	var launch := get_node_or_null("/root/Launch")
	return Controls.key_name(Controls.key_for("snap", launch.settings.bindings if launch else {})).to_upper()

func next_play() -> void:
	series.next_play()
	dead_t = 0.0
	last_whistle = ""
	play_picker_open = true
	camera_orbit = 0.0
	set_controlled(my_id)

func set_controlled(id: int) -> void:
	controlled_id = id
	player = views[id]
	var local_team: int = world.get_athlete(my_id).team
	for view in views:
		var opponent: bool = view.athlete.team != local_team
		if view.is_opponent != opponent:
			view.set_opponent(opponent)

func read_input() -> Vector2:
	if input_override != null:
		return input_override
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): v.y += 1
	if Input.is_key_pressed(KEY_S): v.y -= 1
	if Input.is_key_pressed(KEY_D): v.x += 1
	if Input.is_key_pressed(KEY_A): v.x -= 1
	return screen_to_field(v)

## Keyboard/stick input is screen-relative: W is "up the screen", so turn it with
## the camera (on defense the camera faces the other way down the field).
func screen_to_field(v: Vector2) -> Vector2:
	return v.rotated(cam_yaw)

## Yaw of the follow camera around the player (sim/3D Y axis). 0 = behind the
## offense looking downfield (sim +y / 3D -Z); PI = on defense, looking back at
## the offense so the ball is in front of you.
func _camera_target_yaw() -> float:
	if world == null or my_id < 0 or player == null:
		return 0.0
	return camera_orbit + (PI if player.athlete.team != world.offense_team else 0.0)

func _update_camera(delta: float) -> void:
	# Passer: camera (and WASD) follow the POV aim. cam_yaw + = left, aim_yaw + = right.
	var want_yaw := -aim_yaw if pov_active() else _camera_target_yaw()
	cam_yaw = lerp_angle(cam_yaw, want_yaw, clampf(delta * (20.0 if pov_w > 0.5 else 4.0), 0.0, 1.0))
	if absf(angle_difference(cam_yaw, want_yaw)) < 0.001:
		cam_yaw = want_yaw
	var rot := Basis(Vector3.UP, cam_yaw)
	var target := player.global_position
	if camera_follow.distance_to(target) > 12.0:
		camera_follow = target
	camera_follow = camera_follow.lerp(target, 1.0 - exp(-10.0 * delta))
	var offset := FOLLOW_CAM_OFFSET_BLOCKING if drill != null and drill.kind == "blocking" else FOLLOW_CAM_OFFSET
	cam_zoom_shown = CameraZoom.ease_toward(cam_zoom_shown, cam_zoom, delta)
	var follow_pos := camera_follow + rot * offset * (1.0 if replay_active else cam_zoom_shown)   # replays: default framing
	var follow_look := _framed_look(follow_pos, target + rot * Vector3(0, 0, -aim_distance), target, camera.fov)
	if pov_w <= 0.0:
		camera.global_position = follow_pos
		camera.look_at(follow_look)
		return
	# POV: over the passer's right shoulder, pitched with the aim.
	var fwd := rot * Vector3(0, 0, -1)
	var cam_pitch := aim_pitch * 0.55 - deg_to_rad(8.0)
	var pov_pos := target + rot * POV_CAM_OFFSET
	var pov_look := pov_pos + (fwd * cos(cam_pitch) + Vector3.UP * sin(cam_pitch)) * 10.0
	camera.global_position = follow_pos.lerp(pov_pos, pov_w)
	camera.look_at(follow_look.lerp(pov_look, pov_w))

## Follow look-at point, pitched down just enough that the ring around `feet` sits no lower
## than FRAME_FEET_MAX of the screen (#128). Exact on the camera's vertical plane (no roll),
## so it holds for any offset, FOV, aim range or follow lag; unchanged when already framed.
func _framed_look(cam_pos: Vector3, look: Vector3, feet: Vector3, fov_deg: float) -> Vector3:
	var flat := Vector3(look.x - cam_pos.x, 0.0, look.z - cam_pos.z)
	var d := flat.length()
	if d < 0.001:
		return look
	var dir := flat / d
	var near := Vector3(feet.x - cam_pos.x, 0.0, feet.z - cam_pos.z).dot(dir) - FRAME_RING_R
	if near <= 0.05:
		return look   # camera over the ring (never in follow): nothing to frame
	var min_dip := atan2(cam_pos.y - feet.y, near) - atan((2.0 * FRAME_FEET_MAX - 1.0) * tan(deg_to_rad(fov_deg) * 0.5))
	if atan2(cam_pos.y - look.y, d) >= min_dip:
		return look
	return cam_pos + (dir * cos(min_dip) + Vector3.DOWN * sin(min_dip)) * d

## Target FOV for the follow/POV camera: narrows with the charge while the passer winds up.
func aim_zoom_fov() -> float:
	return lerpf(CAMERA_FOV, AIM_ZOOM_FOV, charge) if charging and pov_active() else CAMERA_FOV

func _update_fov(delta: float) -> void:
	var k := 1.0 if _replay_cam_cut else 1.0 - exp(-AIM_ZOOM_RATE * delta)   # cut out of replays
	_replay_cam_cut = false
	camera.fov = lerpf(camera.fov, aim_zoom_fov(), k)

func can_pass() -> bool:
	return world.can_throw(my_id)

func throw_pass() -> void:
	if can_kick():
		kick_ball()
	elif can_pass():
		do_action({"a": "throw", "t": aim_point, "lob": lob_held()})

func _input(e: InputEvent) -> void:
	if e is InputEventKey and not e.pressed and e.keycode == KEY_J:
		_set_charging(false)
	if e is InputEventKey and e.keycode == KEY_TAB and not in_lobby():
		scoreboard_held = e.pressed
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		scoreboard_held = false
		if taunt_wheel:
			taunt_wheel.close()   # the C release would be lost

## Space on a set defender (#142): one press does nothing, a double-tap breaks stance.
var stance_tap := preload("res://src/sim/double_tap.gd").new()

func _unhandled_key_input(e: InputEvent) -> void:
	var launch := get_node_or_null("/root/Launch")
	if launch != null and launch.menu_open():
		return
	if e is InputEventKey and not e.pressed and e.keycode == KEY_C and taunt_wheel.open:
		taunt(taunt_wheel.release())   # #139: release performs the highlighted taunt
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if in_lobby():
		if not searching():
			lobby_key(e.keycode)
		return
	if coin_toss != null and coin_toss.key(e.keycode):
		return   # the toss cutscene owns the keys; only 1 / 2 fall through
	if e.keycode == KEY_V:
		toggle_replay()
		return
	if replay_active:
		replay_key(e.keycode)
		return
	match e.keycode:
		KEY_SPACE:
			# Offense snaps on one press. A set defender needs a double-tap to roam (#142).
			var breaking := world.can_break_stance(world.get_athlete(controlled_id))
			if breaking and not stance_tap.press(Time.get_ticks_msec() / 1000.0):
				return
			roamed_once = roamed_once or breaking   # #183: the roam hint has done its job
			do_action({"a": "snap"})
		KEY_1:
			do_action({"a": "toss", "c": "receive"} if series.state == Match.State.TOSS else {"a": "try", "n": 1})
		KEY_2:
			do_action({"a": "toss", "c": "kick"} if series.state == Match.State.TOSS else {"a": "try", "n": 2})
		# Live play: Q/E spin, F dive, R dash. Before the snap: Q play picker, F cycle route.
		KEY_F:
			if world.phase == World.Phase.LIVE:
				do_action({"a": "tackle"})      # dive: tackle on defense, dive for yards with the ball
			elif world.route_of.has(my_id):
				var j := (Routes.ROUTE_NAMES.find(world.route_of[my_id]) + 1) % Routes.ROUTE_NAMES.size()
				do_action({"a": "route", "r": Routes.ROUTE_NAMES[j]})
		KEY_Q:
			if world.phase == World.Phase.LIVE:
				do_action({"a": "spin", "s": -1})
			elif world.phase == World.Phase.PRESNAP:
				play_picker_open = not play_picker_open
		KEY_K:
			var ki := (World.KICK_CALLS.find(world.kick_play) + 1) % World.KICK_CALLS.size()
			do_action({"a": "kick_call", "k": World.KICK_CALLS[ki]})
		KEY_E:
			do_action({"a": "spin", "s": 1})
		KEY_G:
			do_action({"a": "handoff"})
		KEY_C:
			open_taunt_wheel()
		KEY_T:
			if drill == null:
				do_action({"a": "timeout"})
		KEY_J:
			if pov_active():
				_set_charging(true)
			else:
				throw_pass()
		KEY_R:
			do_action({"a": "dash", "dir": read_input()})   # no-op unless live with a charge (HUD circles)
		KEY_ENTER, KEY_KP_ENTER:
			if world.phase == World.Phase.DEAD and not is_client():
				next_play()
		KEY_BACKSPACE:
			if drill != null and net == null:
				start_practice("hub")   # back to the training ground

func _physics_process(delta: float) -> void:
	if charging:
		charge = minf(1.0, charge + delta / T.THROW_CHARGE_TIME)
		if not pov_active():
			charging = false   # sacked / crossed the line: the wind-up is lost
	var launch := get_node_or_null("/root/Launch")
	var local_input_blocked: bool = replay_active or (launch != null and launch.menu_open())
	var my_input := {
		"dir": Vector2.ZERO if local_input_blocked else read_input(),
		"sprint": not local_input_blocked and (sprint_override if sprint_override != null else Input.is_key_pressed(KEY_SHIFT)),
		"block": not local_input_blocked and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT),
		World.HUMAN: true,
	}
	if in_lobby():
		if is_server():
			_step_lobby()
		_render()
		return
	if replay_active:
		replay.advance(delta)
		if replay.ended() and not replay_viewer and not replay.paused and not replay.next_in_reel():
			stop_replay()
		elif is_server() and not replay_viewer:
			_step_authoritative(delta, my_input)   # host keeps simulating and recording
		_render_replay()
		if replay_active and is_client() and not replay_viewer:
			_apply_interpolation()
			_record_replay()
		return
	if is_client():
		# Predict own athlete now; server stays authoritative and reconciles via acks.
		var seq := predictor.record(my_input["dir"], my_input["sprint"], delta, my_input["block"])
		net.send_input(my_input["dir"], my_input["sprint"], seq, my_input["block"])
		var me = world.get_athlete(my_id)
		if me and net.my_athlete >= 0:
			world.predict_step(me, my_input["dir"], my_input["sprint"], delta, my_input["block"])
			if world.ball.is_held_by(my_id):
				world.ball.position = Vector3(me.position.x, me.position.y, T.BALL_CARRY_HEIGHT)
		_apply_interpolation()
		_record_replay()
	else:
		_step_authoritative(delta, my_input)
	_render()

## One replay tick, with the view's push / catch bits on frame ticks (#374).
func _record_replay() -> void:
	replay.capture(world, PlayerNode.replay_bits(world) if replay.frame_due() else PackedByteArray())

func _step_authoritative(delta: float, my_input: Dictionary) -> void:
	whistle_t = whistle_t + delta if world.phase == World.Phase.DEAD else 0.0
	if maybe_auto_replay():
		return
	if drill == null:
		series.tick(delta, _clock_snap)   # practice never runs the clocks
	if drill != null and drill.kind != "scrimmage":
		if drill.tick(world, delta):
			drill.start_rep(world)
			last_whistle = ""
			set_controlled(my_id)
		if drill.portal != "":
			start_practice(drill.portal)   # walked into a training-ground portal
			return
	elif world.phase == World.Phase.DEAD and auto_next and not series.is_final():
		dead_t += delta
		if dead_t >= NEXT_PLAY_DELAY:
			next_play()
	var humans: Array = [controlled_id] + roster.humans()
	if is_server():
		for pa in net.take_actions():
			var act = pa[2]
			if act is Dictionary and act.get("a", "") == "look":
				peer_looks[pa[0]] = Cosmetics.sanitize_look(act.get("look", {}))
				_sync_looks()
			else:
				Protocol.apply_action(series, pa[1], act)
	if world.phase == World.Phase.PRESNAP:
		replay.context = "%s, %s" % [series.clock.label(), series.downs.label()]
	var snap_delay := T.AI_SNAP_DELAY
	if drill == null and not world.is_chaos() and not humans.is_empty():
		snap_delay = T.HUDDLE_SECONDS
	# #136: in a match the play clock is the bots' snap timer too (one shown countdown).
	ai.snaps_on_clock = drill == null
	if drill == null and AI.offense_is_bot(world, humans):
		series.huddle(AI.huddle_seconds(world, snap_delay))
	ai.presnap_tick(world, humans, delta, series.downs.down, series.downs.distance(), snap_delay)
	var inputs := ai.think(world, humans)
	if drill != null:
		drill.override_inputs(world, inputs)
	inputs[controlled_id] = my_input
	if is_server():
		for aid in net.human_athletes():
			var inp := net.take_input(aid)
			if inp.is_empty():
				inputs[aid] = REMOTE_IDLE_INPUT
			else:
				inp[World.HUMAN] = true   # the host decides who is human, never the wire
				inputs[aid] = inp
	world.step(inputs, delta)
	_record_replay()
	if is_server():
		net_tick += 1
		if net_tick % SNAPSHOT_EVERY == 0:
			net.broadcast_snapshot(Protocol.encode_snapshot(series, net_tick, net.acks()))

## Play clock ran out: a bot offense snaps its own way (kickoff depth), a human one gets
## the default snap / kick.
func _clock_snap() -> bool:
	if AI.offense_is_bot(world, [controlled_id] + roster.humans()):
		return ai.snap(world)
	return world.snap()

## Instant replay of the last play at half speed (V). At FINAL, V plays the highlight
## reel instead. Offline the match pauses; online only your view changes.
func toggle_replay() -> bool:
	if replay_active:
		stop_replay()
		return true
	if world.phase == World.Phase.LIVE:
		return false
	if series.is_final() and replay.start_reel(replay.highlights()):
		replay_active = true
		replay_reel = true
		return true
	var i := replay.last_play_index()
	if i < 0:
		return false
	replay.clip_play(i, 0.5)
	replay_shown = i
	replay_active = true
	return true

## Offline: a highlight play replays itself once, AUTO_REPLAY_DELAY after the whistle.
func maybe_auto_replay() -> bool:
	if not auto_replay or net != null or drill != null or replay_active or series.is_final():
		return false
	if world.phase != World.Phase.DEAD or whistle_t < AUTO_REPLAY_DELAY:
		return false
	var i := replay.last_play_index()
	if i < 0 or i == replay_shown or not replay.plays[i].get("highlight", false):
		return false
	replay_shown = i
	replay.clip_play(i, 1.0, true)
	replay_active = true
	replay_auto = true
	return true

## Replay transport keys (in-match instant replay and the saved-replay viewer).
func replay_key(code: int) -> void:
	match code:
		KEY_ENTER, KEY_KP_ENTER:
			if not replay_viewer:
				stop_replay()
		KEY_SPACE:
			replay.paused = not replay.paused
		KEY_RIGHT, KEY_LEFT:
			var to := replay.current_play() + (1 if code == KEY_RIGHT else -1)
			if replay_viewer:
				replay.seek_play(to)
			elif replay.clip_play(to, -1.0):
				replay.reel = []
				replay_auto = false
				replay_reel = false
		KEY_H:
			var h := replay.next_highlight()
			if h >= 0:
				if replay_viewer:
					replay.seek_play(h)
				else:
					replay.clip_play(h, -1.0)
					replay_auto = false
		KEY_PERIOD:
			replay.paused = true
			replay.step_frames(1)
		KEY_COMMA:
			replay.paused = true
			replay.step_frames(-1)
		KEY_HOME:
			replay.step_frames(-1_000_000)
		KEY_BRACKETRIGHT:
			replay.speed = minf(2.0, replay.speed * 2.0)
		KEY_BRACKETLEFT:
			replay.speed = maxf(0.25, replay.speed / 2.0)
		KEY_C:
			replay_cam = (replay_cam + 1) % REPLAY_CAMS.size()
			_replay_cam_cut = true

func stop_replay() -> void:
	replay_active = false
	replay_viewer = false
	replay_auto = false
	replay_reel = false
	replay.reel = []
	replay.paused = false

## Standalone viewer for a saved replay file.
func open_replay(path: String) -> bool:
	var r := Replay.new()
	if not r.load_file(path):
		print("REPLAY load failed: %s" % path)
		return false
	configure(int(r.meta.get("size", 7)), "", str(r.meta.get("mode", "classic")))
	replay = r
	replay.time = 0.0
	replay_viewer = true
	replay_active = true
	print("REPLAY opened %s: %d frames, %d plays" % [path, r.frames.size(), r.plays.size()])
	return true

func _save_replay() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(replay_dir))
	var path := "%s/%s.replay" % [replay_dir, Time.get_datetime_string_from_system().replace(":", "-")]
	return path if replay.save(path) else ""

## Ball-tracking replay cameras. Field (x, y) maps to view (x, 0, -y); offense attacks -z.
## Returns [position, look-at target, fov]; the zoom keeps cameras off the field.
func replay_camera_pose() -> Array:
	var t := ball_view.position
	t.y = maxf(t.y, 0.5)
	match REPLAY_CAMS[replay_cam]:
		"End zone":
			return [Vector3(field.width / 2.0 + (t.x - field.width / 2.0) * 0.4, 8.0, t.z + 20.0), t, 48.0]
		"Sky":
			return [Vector3(t.x, 30.0, t.z + 7.0), t, 55.0]
		_:   # Broadcast: high on the near sideline, zoomed, panning with the ball
			return [Vector3(-12.0, 10.0, t.z + 2.0), t, 34.0]

func _replay_camera(delta: float) -> void:
	var pose := replay_camera_pose()
	var k := 1.0 if _replay_cam_cut else 1.0 - exp(-4.0 * delta)
	_replay_cam_cut = false
	camera.global_position = camera.global_position.lerp(pose[0], k)
	camera.look_at(pose[1])
	camera.fov = lerpf(camera.fov, pose[2], k)

func replay_hud_text() -> String:
	var p: int = replay.current_play()
	var lbl: String = str(replay.plays[p].get("label", "")) if p < replay.plays.size() else ""
	var bar := ""
	for k in 20:
		bar += "#" if float(k) < replay.progress() * 20.0 else "-"
	var title := "HIGHLIGHT REEL" if replay_reel else ("HIGHLIGHT" if replay_auto else "REPLAY")
	var slow := "  SLOW-MO" if replay.effective_speed() < replay.speed else ""
	var hs := replay.highlights().size()
	return "%s %sx%s  %s%s\n[%s]  cam: %s\n[V/Enter %s  Space pause  , . frame  Left/Right play  H highlight (%d)  [ ] speed  C camera]" % [
		title, str(replay.speed), slow, lbl, "  (paused)" if replay.paused else "", bar, REPLAY_CAMS[replay_cam],
		"exit" if replay_viewer else ("skip" if replay_auto else "back to game"), hs]

## Views read replay frames (view-only; the sim is untouched).
func _render_replay() -> void:
	var smp := replay.sample()
	if smp.is_empty():
		return
	var pos: Array = smp["pos"]
	var flags: Array = smp["flags"]
	for i in mini(pos.size(), views.size()):
		views[i].place(Vector3(pos[i].x, 0, -pos[i].y), views[i].rotation.y, false)
		views[i].replay_flags = flags[i]   # clips from the recording, not the live athlete
	var b: Vector3 = smp["ball"]
	_place_ball(Vector3(b.x, b.z, -b.y))

## Per physics tick: copy sim state into view targets. Cheap, change-driven work only.
## Anything that moves on screen is drawn per frame in _render_frame (interpolated).
func _render() -> void:
	for v in views:
		v.sync()
	var b = world.ball.position
	_place_ball(Vector3(b.x, b.z, -b.y))
	los_marker.position = Vector3(field.width / 2.0, 0.03, -series.downs.los)
	fd_marker.position = Vector3(field.width / 2.0, 0.03, -series.downs.first_down_y)
	fd_marker.visible = not series.downs.is_goal_to_go()
	for c in components:
		c.on_render()

## True while the throw-arc preview is visible (tests).
func arc_shown() -> bool:
	return not arc_dots.is_empty() and arc_dots[0].visible

## Ball interpolation target (same teleport rule as athlete views).
func _place_ball(p: Vector3) -> void:
	_ball_prev = p if p.distance_to(_ball_cur) > PlayerNode.TELEPORT_DIST * 2.0 else _ball_cur
	_ball_cur = p
	ball_view.position = p

## Per display frame: draw between the last two sim ticks, so motion is smooth at any
## refresh rate (60 Hz sim on a 144 Hz screen, or a slow frame that ran 2 ticks).
## Runs before presentation.gd's _process (parent first), which then pins a held ball
## to the (interpolated) carrier's hand.
func _render_frame() -> void:
	var f := Engine.get_physics_interpolation_fraction()
	for v in views:
		v.interpolate(f)
	ball_view.position = _ball_prev.lerp(_ball_cur, f)
	_update_aim()
	_update_arc()

func _process(delta: float) -> void:
	_render_frame()
	for c in components:
		c.on_frame(delta)
	_update_coin_toss()
	if not replay_active:   # the postgame show waits for the highlight reel
		_tick_postgame(delta)
	var launch := get_node_or_null("/root/Launch")
	var menu_open: bool = launch != null and launch.menu_open()
	if int(world.phase) != _last_phase:
		if world.phase == World.Phase.PRESNAP:
			reset_aim()   # every play starts looking downfield
		_last_phase = int(world.phase)
	var pov := pov_active()
	if DisplayServer.get_name() != "headless":
		var capture: bool = (world.phase == World.Phase.LIVE or pov or taunt_wheel.open) and not menu_open and not in_lobby() and not replay_active
		var mode := Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE
		if Input.mouse_mode != mode:
			Input.mouse_mode = mode
	if menu_open:
		scoreboard_held = false
	if taunt_wheel.open and (menu_open or replay_active or in_lobby()):
		taunt_wheel.close()
	if pov and not taunt_wheel.open and not Input.get_connected_joypads().is_empty():
		var rs := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
		if rs.length() > 0.2:
			look(rs * delta * 900.0)   # right stick = POV look
	pov_w = move_toward(pov_w, 1.0 if pov else 0.0, delta * 3.0)
	if crosshair:
		crosshair.visible = pov and not replay_active
		if crosshair.visible:
			crosshair.queue_redraw()
	if replay_active != _was_replaying:   # TV-style cut into and out of replays
		_was_replaying = replay_active
		_replay_cam_cut = true
	if replay_active and replay_cam != REPLAY_CAMS.find("Player"):
		_replay_camera(delta)
	else:
		_update_camera(delta)
		_update_fov(delta)
	var m = player.athlete
	var my_team: int = m.team
	var side := "OFFENSE | PLAY: %s" % world.play_name if world.offense_team == my_team else "DEFENSE"
	if world.offense_team != my_team and not world.defensive_call.is_empty():
		side += " | CALL: %s" % World.DefensivePlaybook.CALLS[world.defensive_call].name
	var phase_name: String = ["PRE-SNAP", "LIVE", "DEAD"][world.phase]
	if world.offense_team != my_team and world.phase == World.Phase.PRESNAP:
		phase_name = presnap_defense_prompt(world.get_athlete(my_id), roam_hint_key())
	if world.phase == World.Phase.DEAD and last_whistle != "":
		phase_name = "%s at %.1f" % [last_whistle, world.dead_ball_spot.y]
	var situation: String = series.downs.label()
	if series.state == Match.State.TRY:
		situation = "TRY for %d" % series.try_points
	elif series.state == Match.State.KICKOFF:
		situation = "KICKOFF"
	elif series.state == Match.State.TOSS:
		situation = "COIN TOSS: %s wins" % ("HOME" if series.toss_winner == 0 else "AWAY")   # no key hints (#129)
	if world.offense_team == my_team and series.state == Match.State.SCRIMMAGE and not world.is_chaos():
		side += " | KICK: %s [K]" % {"": "none", "punt": "PUNT", "fg": "FIELD GOAL"}.get(world.kick_play, world.kick_play)
	banner_t = maxf(0.0, banner_t - delta)
	if banner_t > 0.0:
		phase_name = banner + "  " + phase_name
	if drill != null and pres and pres.overlay:
		for b in drill.banners:
			pres.overlay.show_drill_banner(b)
		drill.banners.clear()
	if searching() and drill == null:
		hud.text = queue_text() + "..."
		return
	if replay_active:
		hud.text = replay_hud_text()
		return
	if in_lobby():
		if is_client() and net.refused_reason != "":
			hud.text = "COULDN'T JOIN THE MATCH\n%s%s" % [net.refused_reason, "" if net.version_refused else "\n\nAsk the host for a bigger match, or try again later."]
			return
		var host_keys := "\nHost: [3/5/7] size   [M] mode   [H] quarter length   [I] pass marker" if is_server() else ""
		var lobby_text := "PRIVATE MATCH LOBBY   Invite code: %s\n%s\n[Enter] ready. Starts when everyone is ready.%s" % [lobby.code, lobby.summary(), host_keys]
		if is_server() and lobby.notice != "":
			lobby_text += "\n" + lobby.notice
		if is_server() and port_mapping_notice != "":
			lobby_text += "\n\n" + port_mapping_notice
		hud.text = lobby_text
		return
	var clock_txt: String = "%s%dv%d %s" % ["CHAOSBALL " if match_mode == "chaosball" else "", match_size, match_size, series.clock.label()]
	if world.is_chaos():
		clock_txt += " | STREAK %d -> TD %d | BALL %.1fs" % [world.streak, world.streak_points(), maxf(0.0, T.PASS_CLOCK - world.hold_t)]
	if drill != null:
		clock_txt = drill.label()
	if series.play_clock_shown() >= 0 and drill == null:
		clock_txt += " | PLAY %d" % series.play_clock_shown()
	if series.is_final():
		var w := series.winner()
		phase_name = "FINAL: HOME %d - AWAY %d  %s\n%s" % [series.score[0], series.score[1], "TIE" if w < 0 else ("HOME WINS" if w == 0 else "AWAY WINS"),
			"\n".join(summary_lines) if not summary_lines.is_empty() else "(no stats)"]
		if my_ranks != "":
			phase_name += "\nYOUR RANKS: " + my_ranks
		if ranked_line != "":
			phase_name += "\n" + ranked_line
		if xp_line != "":
			phase_name += "\n" + xp_line
		if achievement_line != "":
			phase_name += "\n" + achievement_line
	else:
		phase_name = "HOME %d - AWAY %d | %s | %s | %s | %s" % [series.score[0], series.score[1], clock_txt, situation, side, phase_name]
	hud.text = "%s   Yard: %.1f  Speed: %.1f yd/s  Stamina: %d%%%s" % [
		phase_name, m.position.y, m.speed(), int(m.stamina * 100), "  (WINDED)" if m.sprint_locked else ""]

func _build_environment() -> void:
	StadiumArt.build_environment(self)
	var q := ArtQuality.level()
	get_viewport().msaa_3d = Viewport.MSAA_4X if q == "high" else (Viewport.MSAA_2X if q == "medium" else Viewport.MSAA_DISABLED)

func _box(size: Vector3, center: Vector3, color: Color, n: String) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	bm.material = mat
	mi.mesh = bm
	mi.position = center
	mi.name = n
	field_root.add_child(mi)

func _build_field() -> void:
	FieldArt.build(field_root, field, TEAM_COLORS)
	if pres:
		pres.rebuild(field_root)
