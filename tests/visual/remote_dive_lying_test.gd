extends "res://tests/visual/harness.gd"
## #397: a real loopback joiner shows a remote diver lying on the turf before the get-up,
## with the same dive and ground timing as the host.

const NetSession := preload("res://src/net/net_session.gd")
const Protocol := preload("res://src/net/protocol.gd")
const Replay := preload("res://src/sim/replay.gd")
const Tick := preload("res://src/sim/tick.gd")
const T := preload("res://src/sim/tuning.gd")
const DIVER := 1   # a remote athlete: the joiner is seat 3

var game
var hosted_match
var host := NetSession.new()
var tick := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	game = preload("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_physics_process(false)
	game.opening_kickoff = false
	game.configure(3)
	game.pov_enabled = false
	var world = game.World.new()
	game.Roster.new().build(world, 3)
	hosted_match = game.Match.new(world)
	hosted_match.start(0, 25.0)
	root.add_child(host)
	host.match_size = 3
	var port := 30000 + randi() % 20000
	var result := host.host(port, func(_peer): return 3, func(_peer): pass)
	check(result == OK, "loopback host bound its port")
	if result != OK:
		finish()
		return
	world.event.connect(host.broadcast_event)
	game._join_game("127.0.0.1", port, {})
	for frame in 120:
		if game.net.my_athlete >= 0:
			break
		await process_frame
	check(game.net.my_athlete == 3, "real client joined the host")
	if game.net.my_athlete != 3:
		finish()
		return
	await _advance(4)
	check(world.snap(), "down snapped")
	await _advance(4)

	# The diver lands beside the joiner's athlete, so the joiner's camera frames it.
	var diver = world.athletes[DIVER]
	diver.position = world.athletes[3].position + Vector2(-4.0, 1.0)
	diver.facing = Vector2.RIGHT
	check(diver.start_dive(), "host starts the remote dive")
	var seen = game.world.athletes[DIVER]
	var view = game.views[DIVER]
	var saw_dive := false
	var host_down := -1
	var host_up := -1
	var client_down := -1
	var client_up := -1
	var lay_at := -1
	var first_recover := 0.0
	var captured := false
	for i in 150:
		await _advance(1)
		if host_down < 0 and diver.is_grounded():
			host_down = tick
		if host_down >= 0 and host_up < 0 and not diver.is_grounded():
			host_up = tick
		saw_dive = saw_dive or seen.is_diving()
		if client_down < 0 and seen.is_grounded():
			client_down = tick
			first_recover = seen.recover_t
		if client_down >= 0 and client_up < 0 and not seen.is_grounded():
			client_up = tick
		if client_down >= 0 and lay_at < 0 and view._cur == "u2/LayToIdle":
			lay_at = tick
		# 0.15 s into the host's ground time (decoded, so not tied to packet timing): still lying down.
		if client_down >= 0 and not captured and seen.recover_t <= T.DIVE_RECOVER - 0.15:
			captured = true
			check(view._cur == "u2/Slide", "joiner shows the lying clip 0.15 s after landing (got %s)" % view._cur)
			await capture("remote-dive-lying")
		if client_up >= 0 and host_up >= 0:
			break
	print("DIVE397 host_down=%d host_up=%d client_down=%d client_up=%d lay_at=%d first_recover=%.3f" % [
		host_down, host_up, client_down, client_up, lay_at, first_recover])
	check(saw_dive, "joiner sees the dive flag")
	check(host_down >= 0 and client_down >= 0, "host and joiner both see the diver grounded")
	check(first_recover >= T.DIVE_RECOVER - 0.1, "joiner decodes the remaining ground time (%.3f s)" % first_recover)
	var host_ticks := host_up - host_down
	var client_ticks := client_up - client_down
	check(client_up >= 0 and absi(client_ticks - host_ticks) <= Replay.FRAME_EVERY + 1,
		"joiner's ground time matches the host's (%d vs %d ticks)" % [client_ticks, host_ticks])
	var lie_ticks := lay_at - client_down
	var expect_lie := roundi((T.DIVE_RECOVER - 0.7) * Tick.RATE)
	check(lay_at >= 0 and lie_ticks >= expect_lie - Replay.FRAME_EVERY - 1,
		"joiner lies ~%d ticks before the get-up clip (got %d)" % [expect_lie, lie_ticks])
	finish()

func _advance(count: int) -> void:
	for i in count:
		tick += 1
		hosted_match.world.step({}, Tick.DT)
		if tick % Replay.FRAME_EVERY == 0:
			host.broadcast_snapshot(Protocol.encode_snapshot(hosted_match, tick))
		await process_frame
		game._physics_process(Tick.DT)
