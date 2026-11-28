extends SceneTree
## Two-process net test (client side). Run with: -- --join=127.0.0.1 --port=N
## against a host started with: -- --host --port=N --playclock=4
## --host-loss (#56): join, print "NET HOSTLOSS ARMED" once in the match, then expect the
## host to be killed (net_test.sh does it) and assert we land on the menu with
## "Host disconnected". #86: within NetSession.DROP_AFTER (+ slack) of the host's last
## packet, after the "Connection to host lost…" banner (ENet alone took 5.8-9.7 s).
## #279: measured like the watchdog measures it: wall time from the last packet minus our own
## frame hitches beyond SILENCE_STEP_MAX, which the watchdog deliberately doesn't count.

var main
var f := 0
var ok := true
var aid := -1
var snaps := 0
var echoed_input_seq := 0
var input_acks_valid := true
var start_x := INF
var max_dx := 0.0
var replay_start_frame := -1
var replay_frame_count := 0
var replay_input_seq := 0
var got_snap_event := false
var got_opening_tip := false
var opening_dead_snapshots := 0
var got_opening_interception := false
var saw_live := false
var opening_play_clock := -1.0
var next_play_clock := -1.0
var bad_snap_sent_at := -1
var bad_snap_rejected := false
var last_server_x := INF
var aid_before_swap := -1
var aid_before_pick := -1
var team_swap_rejected := false
var pick_rejected := false
var equipped_number := ""
var first_team := -1
var saw_lobby := false
var lobby_size := 0
var quarter_lobby_seen := false
var quarter_clock_seen := false
var pass_marker_off_in_lobby := false
var lobby_code := ""
var lead_samples := 0
var was_locked := false     # C08d: joiner (defense) started in stance per host snapshot
var broke_stance := false   # host snapshot shows the lock cleared after our Space
var crossed_line := false   # predicted defender ever past the neutral zone
var defense_call_seen := false
var defense_recall_seen := false
var sent_timeout := false
var got_timeout_event := false
var timeout_confirmed := false
var requested_twins := false
var saw_twins := false
var requested_slants := false
var called_run := false
var snapped_run := false
var sent_handoff := false
var handoff_to := -1
var remote_handoff_confirmed := false
var sent_grounding_throw := false
var got_grounding_flag := false
var checked_retreated_keeper := false
var xp_before := 0
var games_before := 0
var had_first_td := false
var had_first_win := false
var got_awards := false
var got_summary := false
var got_contested_interception := false
var sideline_catch := false
var sideline_incomplete := false
var saw_grounded_breakup := false
var shared_td_line := false   # the host Ann's touchdown sits in the name-keyed summary (#200)
var host_loss := false      # #56 mode
var armed_at := -1
var armed_us := -1          # wall clock at arming (physics frames lag it under load, #279)
var last_host_us := -1      # #86: wall clock of the last packet from the host (what resets the watchdog)
var stall_banner_seen := false
var lost_after := -1.0      # s (wall) from the last packet to host_lost
var own_hitch := 0.0        # #279: s of our own frame gaps past SILENCE_STEP_MAX since that packet
var lost_hitch := -1.0      # own_hitch when host_lost fired
var lost_silence := -1.0    # the watchdog's own clock (host_silence) when host_lost fired
var _frame_us := -1         # wall clock of the previous process frame
const NetSession := preload("res://src/net/net_session.gd")
const HOST_LOSS_SLACK := 0.75   # s over DROP_AFTER: frame granularity + the kill landing mid-gap

func check(cond: bool, msg: String) -> void:
	print(("  NET OK   " if cond else "  NET FAIL ") + msg)
	if not cond:
		ok = false

func _on_snap(s: Dictionary) -> void:
	snaps += 1
	if aid >= 0:
		last_server_x = (s["a"] as PackedFloat32Array)[aid * 7]
		var seq: int = s.get("ack", {}).get(aid, 0)
		input_acks_valid = input_acks_valid and seq >= echoed_input_seq and seq <= main.predictor.seq
		echoed_input_seq = seq
	if s.get("dc") == "edge_blitz" and main.world.defensive_call == "edge_blitz":
		defense_call_seen = true
	if main.series.clock.label() == "Q1 3:00" and main.series.clock.quarter_length == 180.0:
		quarter_clock_seen = true
	if got_opening_tip and bad_snap_sent_at < 0 and s["ph"] == main.World.Phase.DEAD:
		opening_dead_snapshots += 1
	if s["ph"] == 1:
		saw_live = true
	elif s["ph"] == 0:
		if not saw_live and opening_play_clock < 0.0:
			opening_play_clock = s["c"][2]
		elif saw_live and next_play_clock < 0.0:
			next_play_clock = s["c"][2]

func _on_lobby(st: Dictionary) -> void:
	if not saw_lobby and st.get("phase", 1) == 0:
		saw_lobby = true
		var settings: Dictionary = st.get("settings", {})
		lobby_size = int(settings.get("size", 0))
		quarter_lobby_seen = settings.get("quarters") == true and settings.get("quarter_minutes") == 3
		pass_marker_off_in_lobby = st.get("settings", {}).get("pass_marker") == false
		lobby_code = str(st.get("code", ""))
		main.lobby_key(KEY_ENTER)   # ready up through the real lobby key path

func _on_welcome(id: int) -> void:
	aid = id
	if first_team < 0 and main.profile.install_id != "":   # once: net_test.sh matches this against what the host received (#102)
		print("NET client install id %s" % main.profile.install_id)
	if first_team < 0:
		first_team = main.world.get_athlete(id).team

func _on_event(n: String, _d: Dictionary) -> void:
	if n == "snap":
		got_snap_event = true
	if got_snap_event and bad_snap_sent_at < 0:
		if n == "incomplete" and _d.get("reason") == "breakup":
			got_opening_tip = true
		if n == "interception":
			got_opening_interception = true
	if n == "timeout" and _d.get("team") == 1 and _d.get("remaining") == 2:
		got_timeout_event = true
	if n == "handoff" and _d.get("by") == aid:
		handoff_to = int(_d["to"])
	if n == "interception" and _d.get("team") == 1 and (_d.get("at", Vector2.ZERO) as Vector2).y > 38.0:
		got_contested_interception = true
	if n == "catch" and (_d.get("at", Vector2.ZERO) as Vector2).x < 0.0:
		sideline_catch = true
	if n == "incomplete" and _d.get("reason") == "caught_out_of_bounds":
		sideline_incomplete = true
	if n == "flag" and _d.get("type") == "intentional_grounding":
		got_grounding_flag = true
	if n == "awards":
		got_awards = true
		check(main.player_name == "Ann" and not _d["xp"].has("Ann"),
			"same-named players receive seat awards without a shared name entry")
		var line: Dictionary = _d["ctx"].get(aid, {}).get("line", {})
		check(line.get("comp", 0.0) == 0.0 and line.get("pass_yds", 0.0) == 0.0,
			"replacement QB's network award excludes the previous player's completion and passing yards")
		check(line.get("car", 0.0) == 1.0 and line.get("rush_yds", 0.0) == 7.0,
			"QB's network award includes the fumbled keeper and excludes the previous player's run")
	if n == "summary":
		got_summary = _d.get("mine") is Dictionary and _d["mine"].has(aid)
		shared_td_line = _d.get("lines", []).any(func(l): return str(l).begins_with("Ann ") and str(l).contains("1TD"))
		check(_d.get("lines", []).any(func(l): return str(l).begins_with("P99 QB: 1/1 20yd 0TD 0INT")),
			"network match summary credits the original thrower's 20 yards on the fumbled completion")

func _initialize() -> void:
	host_loss = OS.get_cmdline_user_args().has("--host-loss")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	if host_loss:
		current_scene = main   # like a real launch, so Launch.go_to_menu swaps it out

func _physics_process(_dt: float) -> bool:
	f += 1
	if host_loss:
		return _host_loss_step()
	if f == 2:
		xp_before = main.profile.xp
		games_before = main.profile.games
		check(xp_before == 0 and games_before == 0 and main.profile.achievements.is_empty(),
			"the network award test starts with a fresh client profile")
		had_first_td = main.profile.achievements.has("first_td")
		had_first_win = main.profile.achievements.has("first_win")
		main.net.lobby_received.connect(_on_lobby)
		main.net.welcomed.connect(_on_welcome)
		main.net.snapshot_received.connect(_on_snap)
		main.net.event_received.connect(_on_event)
	if aid >= 0 and snaps > 3:
		var x: float = main.world.get_athlete(aid).position.x
		if start_x == INF:
			start_x = x
			main.do_action({"a": "defense", "p": "edge_blitz"})
			var me = main.world.get_athlete(aid)
			was_locked = me.set_lock or me.role == main.Athlete.Role.DL
			_key(KEY_SPACE)   # #142: one press alone does nothing on a set defender...
			_key(KEY_SPACE)   # ...the double-tap sends one snap action: break stance over the wire
			main.input_override = Vector2(1, 0)  # strafe right (legal presnap once roaming)
		if not broke_stance and not saw_live and main.world.phase == 0 and not main.world.get_athlete(aid).set_lock:
			broke_stance = true
		var a = main.world.get_athlete(aid)
		if main.world.phase == 0 and a.team != main.world.offense_team and a.position.y < main.world.los_y + 0.5 - 0.001:
			crossed_line = true

		max_dx = maxf(max_dx, x - start_x)
	# With prediction, the locally shown position leads the last raw server state while moving.
	if aid >= 0 and main.input_override == Vector2(1, 0) and last_server_x != INF and main.world.phase == 0:
		if main.world.get_athlete(aid).position.x - last_server_x > 0.02:
			lead_samples += 1
	if got_opening_tip and replay_start_frame < 0 and main.world.phase == main.World.Phase.DEAD:
		_key(KEY_V)
		check(main.replay_active and not main.replay.last_play().is_empty(), "V opens the host's first finished down")
		if main.replay_active:
			_key(KEY_SPACE)
		replay_start_frame = f
		replay_frame_count = main.replay.frames.size()
		replay_input_seq = main.predictor.seq
	if replay_start_frame >= 0 and f == replay_start_frame + 12:
		check(main.replay_active and main.replay.paused and main.predictor.seq == replay_input_seq,
			"joiner paused the clip and stopped sending movement")
		check(main.replay.frames.size() == replay_frame_count + 12 / main.Replay.FRAME_EVERY,
			"joiner continued recording during twelve ticks of replay")
		if main.replay_active:
			_key(KEY_V)
	# After the first play ends and the next presnap begins, try an illegal defense snap.
	if saw_live and bad_snap_sent_at < 0 and main.world.phase == 0:
		main.input_override = Vector2.ZERO
		main.do_action({"a": "snap"})
		main.do_action({"a": "recall_call"})
		bad_snap_sent_at = f
	if bad_snap_sent_at > 0 and f == bad_snap_sent_at + 30:
		bad_snap_rejected = main.world.phase == 0
		defense_recall_seen = main.world.defensive_call == "edge_blitz"
		aid_before_swap = aid
		main.do_action({"a": "team"})
	if bad_snap_sent_at > 0 and f == bad_snap_sent_at + 60:
		team_swap_rejected = aid == aid_before_swap and main.world.get_athlete(aid).team == first_team
		aid_before_pick = aid
		main.do_action({"a": "pick", "slot": 0})
	if bad_snap_sent_at > 0 and f == bad_snap_sent_at + 90:
		pick_rejected = aid == aid_before_pick and main.world.get_athlete(aid).team == first_team
		equipped_number = main.views[aid].number_text
	if bad_snap_sent_at > 0 and f > bad_snap_sent_at + 90:
		_test_remote_handoff()
	if main.last_whistle == "BREAKUP" and main.world.phase == main.World.Phase.DEAD:
		var b = main.world.ball
		if b.holder_id < 0 and b.position.z > 0.3:
			saw_grounded_breakup = saw_grounded_breakup or is_equal_approx(main.ball_view.position.y, main.pres.Football.RADIUS)
	if remote_handoff_confirmed and not sent_grounding_throw and main.world.los_y == 42.0 and main.world.ball.is_held_by(aid):
		main.pov_enabled = false
		main.aim_point = Vector2(4.0, 22.0)
		sent_grounding_throw = true
		_key(KEY_J)
	if remote_handoff_confirmed and not checked_retreated_keeper:
		_check_retreated_keeper()
	if f == 1500 or (remote_handoff_confirmed and got_awards and got_summary):
		check(saw_grounded_breakup, "the client's elevated dead ball falls to turf after a breakup")
		check(saw_lobby and lobby_size == 5 and lobby_code.length() == 11, "joined by code into the private lobby (5v5, code %s)" % lobby_code)
		check(quarter_lobby_seen and quarter_clock_seen, "host lobby Q and H select three-minute quarters on both machines")
		check(pass_marker_off_in_lobby and not main.lobby.settings["pass_marker"], "host I disables the pass marker on the client through match start")
		check(aid >= 0, "readied up -> match started -> welcomed with athlete %d" % aid)
		check(first_team == 1, "joiner initially placed on the opponent team")
		check(main.match_size == 5 and main.world.athletes.size() == 10, "client adopted host's 5v5 (%d athletes)" % main.world.athletes.size())
		check(snaps > 20, "receiving snapshots (%d)" % snaps)
		check(input_acks_valid and echoed_input_seq > 0, "host acknowledges movement inputs in sequence")
		check(max_dx > 2.0, "own input moved own athlete on server (dx %.1f)" % max_dx)
		check(was_locked, "joiner on defense starts in stance")
		check(broke_stance, "defense Space broke stance via the host (snapshot lock cleared)")
		check(not crossed_line, "predicted defender never past the neutral zone")
		check(lead_samples > 10, "own athlete predicted ahead of server state (%d frames)" % lead_samples)
		check(replay_start_frame >= 0 and f > replay_start_frame + 12, "instant replay exercised on the connected joiner")
		check(saw_live and got_snap_event, "host auto-snap reached client (snapshot LIVE + reliable event)")
		check(got_opening_tip and not got_opening_interception, "host's opening short pass reaches the client as a breakup")
		check(opening_dead_snapshots >= 4, "snapshots continue through the host's instant replay (%d)" % opening_dead_snapshots)
		check(opening_play_clock > 0.0 and opening_play_clock <= 4.0,
			"lobby match opens with the host's short play clock (%.2f s)" % opening_play_clock)
		check(next_play_clock >= 3.0 and next_play_clock <= 4.0,
			"client sees the short play clock reset on the next down (%.2f s)" % next_play_clock)
		check(defense_recall_seen, "remote defender recalled the previous snap's call")
		check(defense_call_seen, "defensive selection reached host and returned in a snapshot")
		check(bad_snap_rejected, "defense snap rejected by server")
		check(team_swap_rejected, "legacy team request preserves the host assignment")
		check(equipped_number == "88", "my equipped #88 round-tripped through the host (%s)" % equipped_number)
		check(pick_rejected, "legacy slot request preserves the host assignment")
		check(timeout_confirmed and got_timeout_event, "remote T decrements only its team's timeouts and broadcasts the event")
		check(got_contested_interception, "the client receives the host's contested interception")
		check(sideline_catch and sideline_incomplete, "client receives both sideline catch rulings from the host")
		check(saw_twins, "remote QB's Twins Right choice returns in the host lineup")
		check(requested_slants and called_run, "remote QB audibles from Slants to Inside Zone in the play picker")
		check(remote_handoff_confirmed, "client QB hands off through G and sees the host's RB possession")
		check(remote_handoff_confirmed and main.controlled_id == aid, "online QB keeps the same athlete after the handoff")
		check(sent_grounding_throw and got_grounding_flag, "online J throw receives the host's grounding flag")
		check(checked_retreated_keeper, "received the host's retreated keeper snapshot")
		var xp_delta: int = main.profile.xp - xp_before
		var games_delta: int = main.profile.games - games_before
		check(got_awards and xp_delta == 100 and games_delta == 1,
			"same-named losing client receives only its own 100 XP (award received: %s, XP: %+d, games: %+d)"
			% [got_awards, xp_delta, games_delta])
		check(main.profile.achievements.has("first_td") == had_first_td
			and main.profile.achievements.has("first_win") == had_first_win,
			"host's touchdown and win leave the client's achievements as they were")
		var mine: Array = main.match_overview()["my_lines"]
		check(got_summary and shared_td_line and not mine.any(func(l): return str(l).contains("1TD")),
			"same-named client's Your game leaves out the host Ann's touchdown line (%s)" % str(mine))
		# The earlier grounding fixture also records the local QB’s incomplete pass.
		check(mine.filter(func(l): return str(l).contains(" car ")) == ["QB: 0/1 0yd 0TD 0INT | 1 car 7yd 0TD"],
			"QB's Your game shows only the local player's fumbled keeper (%s)" % str(mine))
		print("NET FLOW " + ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
	return false

func _check_retreated_keeper() -> void:
	var world = main.world
	if world.los_y != 37.0 or not world.ball.is_held_by(aid) or world.get_athlete(aid).position.y > world.los_y:
		return
	checked_retreated_keeper = true
	check(world.ball_crossed_los and not main.can_pass() and not main.pov_active(),
		"snapshot closes the passing preview behind the line after a keeper crosses")
	_key(KEY_J)
	check(not main.charging and world.ball.is_held_by(aid), "retreated online keeper presses J without starting a throw")

func _test_remote_handoff() -> void:
	var w = main.world
	var me = w.get_athlete(aid)
	if me == null or me.team != 1:
		return
	if w.offense_team != 1 or me.role != main.Athlete.Role.QB:
		return
	if not sent_timeout and w.phase == w.Phase.PRESNAP:
		_key(KEY_T)
		sent_timeout = true
	if sent_timeout and main.series.clock.timeouts == [3, 2]:
		timeout_confirmed = true
	if timeout_confirmed and w.phase == w.Phase.PRESNAP and not requested_twins:
		main.do_action({"a": "formation", "f": w.Formation.TWINS_RIGHT})
		requested_twins = true
	if requested_twins and w.phase == w.Phase.PRESNAP and w.offensive_formation() == w.Formation.TWINS_RIGHT:
		saw_twins = true
	if saw_twins and w.phase == w.Phase.PRESNAP:
		if not requested_slants:
			requested_slants = _press_play_card("Slants")
		elif not called_run and w.play_name == "Slants" and w.route_of.values().has("SLANT"):
			called_run = _press_play_card("Inside Zone")
	if not snapped_run and w.phase == w.Phase.PRESNAP and w.play_name == "Inside Zone":
		_key(KEY_SPACE)
		snapped_run = true
	if snapped_run and not sent_handoff and w.handoff_receiver(aid) != null:
		_key(KEY_G)
		sent_handoff = true
	var back = w.find_role(1, main.Athlete.Role.RB)
	remote_handoff_confirmed = remote_handoff_confirmed or (
		sent_handoff and back != null and back.id == handoff_to and w.ball.is_held_by(back.id))

func _press_play_card(name: String) -> bool:
	var overlay = main.pres.overlay
	if overlay.picker.visible:
		for button in overlay.picker_grid.get_children():
			if button.visible and button.text == name:
				button.pressed.emit()
				return true
	return false

## #56: in the match, then the host dies -> back on the menu saying why.
func _host_loss_step() -> bool:
	if f == 2:
		main.net.welcomed.connect(_on_welcome)
		main.net.snapshot_received.connect(_on_snap)
		main.net.api.peer_packet.connect(_on_host_packet)
		process_frame.connect(_count_own_hitch)
		main.net.host_stalled.connect(func():
			var b = main.get_node_or_null("LinkBanner")
			stall_banner_seen = b != null and b.visible, CONNECT_DEFERRED)
		main.net.host_lost.connect(func():
			lost_after = (Time.get_ticks_usec() - last_host_us) / 1000000.0
			lost_hitch = own_hitch
			lost_silence = main.net.host_silence)
	if armed_at < 0 and aid >= 0 and snaps > 5:
		armed_at = f
		armed_us = Time.get_ticks_usec()
		print("NET HOSTLOSS ARMED")
		for a in OS.get_cmdline_user_args():   # stdout is buffered: tell net_test.sh via a file
			if a.begins_with("--armed-file="):
				FileAccess.open(a.get_slice("=", 1), FileAccess.WRITE).store_string("armed\n")
	var scene = current_scene
	var on_menu: bool = scene != null and scene.scene_file_path == "res://scenes/menu.tscn" and scene.get("status_label") != null
	if on_menu or f == 3000:
		var silent := (Time.get_ticks_usec() - last_host_us) / 1000000.0
		print("NET HOSTLOSS detected %.2fs after the host's last packet, %.2fs of it our own hitches past %.2fs/frame; watchdog clock %.2fs (menu up after %.2fs)" % [lost_after, lost_hitch, NetSession.SILENCE_STEP_MAX, lost_silence, silent])
		check(armed_at > 0, "in the match (athlete %d, %d snapshots) before the host died" % [aid, snaps])
		check(on_menu, "client left the frozen match for the menu after losing the host (%.1fs after arming)" % ((Time.get_ticks_usec() - armed_us) / 1000000.0))
		var status: String = scene.status_label.text if on_menu else ""
		check(status == "Host disconnected", "menu status says why: '%s'" % status)
		var bound: float = NetSession.DROP_AFTER + HOST_LOSS_SLACK
		var detect := lost_after - lost_hitch   # #279: the host's silence, not our scheduler's
		check(lost_after > 0.0 and detect <= bound, "host loss detected within %.2fs of the last packet, own hitches excluded (%.2fs)" % [bound, detect])
		check(stall_banner_seen, "'Connection to host lost…' showed before the drop")
		print("NET HOSTLOSS " + ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
	return false

## Any packet from the host resets the watchdog (NetSession._heard_host), so it's the reference.
func _on_host_packet(from: int, _bytes: PackedByteArray) -> void:
	if from == 1:
		last_host_us = Time.get_ticks_usec()
		own_hitch = 0.0

## #279: the watchdog counts each frame as at most SILENCE_STEP_MAX, so when this process is
## starved (CI load) its clock runs behind the wall. Count that excess, only the part after the
## last packet, so the wall-clock bound checks the host's silence and not our scheduler.
func _count_own_hitch() -> void:
	var now := Time.get_ticks_usec()
	if _frame_us >= 0 and last_host_us >= 0:
		var gap := (now - maxi(_frame_us, last_host_us)) / 1000000.0   # this frame's wall time since the packet
		own_hitch += maxf(0.0, gap - NetSession.SILENCE_STEP_MAX)
	_frame_us = now

func _key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	main._unhandled_key_input(event)
