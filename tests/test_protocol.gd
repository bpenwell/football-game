extends "res://tests/test_case.gd"

const World := preload("res://src/sim/world.gd")
const Match := preload("res://src/sim/match.gd")
const Athlete := preload("res://src/sim/athlete.gd")
const P := preload("res://src/net/protocol.gd")
const DT := 1.0 / 60.0
const R := Athlete.Role

func _match() -> Match:
	var w := World.new()
	var cx := w.field.width / 2.0
	var pairs := [[R.C, 0.0, R.DL, -1.5], [R.QB, 0.0, R.LB, 0.0], [R.WR, -18.0, R.CB, -18.0], [R.WR, 18.0, R.CB, 18.0], [R.RB, 4.0, R.S, -8.0], [R.OL, -2.5, R.DL, 1.5], [R.OL, 2.5, R.S, 8.0]]
	for t in 2:
		for p in pairs:
			w.add_two_way(t, p[0], cx + p[1], p[2], cx + p[3])
	var m := Match.new(w)
	m.start(0, 25.0)
	return m

func test_snapshot_round_trip() -> void:
	var a := _match()
	a.world.snap()
	for i in 40:
		a.world.step({a.world.find_role(0, R.QB).id: {"dir": Vector2(1, 0.3), "sprint": true}}, DT)
	a.world.athletes[9].recover_t = 0.5
	a.world.athletes[5].blocking = true
	a.world.athletes[8].move_charge = 0.6
	a.world.athletes[8].spin_move = true
	a.world.athletes[8].move_t = 0.2
	a.score = [7, 3]
	a.clock.remaining = 123.5
	a.downs.down = 3
	a.world.forward_pass_thrown = true
	var snap := P.encode_snapshot(a, 42)
	var bytes := var_to_bytes(snap)
	var decoded = bytes_to_var(bytes)
	var b := _match()
	P.apply_snapshot(b, decoded)
	for i in a.world.athletes.size():
		assert_true(a.world.athletes[i].position.distance_to(b.world.athletes[i].position) < 0.001, "pos %d" % i)
		assert_true(a.world.athletes[i].velocity.distance_to(b.world.athletes[i].velocity) < 0.001, "vel %d" % i)
		assert_eq(a.world.athletes[i].role, b.world.athletes[i].role, "role %d" % i)
	assert_true(b.world.athletes[9].is_grounded(), "grounded flag")
	assert_true(b.world.athletes[5].blocking, "blocking shield flag")
	assert_true(b.world.athletes[8].is_spinning(), "spin flag and timing")
	assert_near(b.world.athletes[8].move_charge, 0.6, 0.001, "move charge")
	assert_eq(b.world.phase, a.world.phase, "phase")
	assert_true(b.world.forward_pass_thrown, "the forward-pass flag survives serialization")
	assert_eq(b.world.ball.state, a.world.ball.state, "ball state")
	assert_eq(b.world.ball.holder_id, a.world.ball.holder_id, "holder")
	assert_true(b.world.ball.position.distance_to(a.world.ball.position) < 0.001, "ball pos")
	assert_eq(b.score, [7, 3], "score")
	assert_near(b.clock.remaining, 123.5, 0.01, "clock")
	assert_eq(b.downs.down, 3, "down")
	assert_true(bytes.size() < 1400, "fits one MTU-ish packet (%d bytes)" % bytes.size())

## #397: the remaining dive and ground time cross the wire to the tick, next to a jump, so a
## client's view lies down as long as the host's (it used to decode a 0.01 s token timer).
func test_snapshot_carries_dive_and_ground_time() -> void:
	var a := _match()
	a.world.athletes[1].dive_t = 0.2
	a.world.athletes[2].recover_t = 1.0
	a.world.athletes[2].jump_t = 0.6   # not a real combo: proves the bit fields stay apart
	a.world.athletes[3].recover_t = 0.004   # under half a tick still reads as grounded
	a.world.athletes[4].recover_t = 5.0     # longer than the field holds: saturates, stays grounded
	var b := _match()
	P.apply_snapshot(b, bytes_to_var(var_to_bytes(P.encode_snapshot(a, 7))))
	assert_near(b.world.athletes[1].dive_t, 0.2, DT / 2.0, "dive time left")
	assert_near(b.world.athletes[2].recover_t, 1.0, DT / 2.0, "ground time left")
	assert_near(b.world.athletes[2].jump_t, 0.6, 0.001, "jump time beside the ground time")
	assert_true(b.world.athletes[3].is_grounded(), "a sliver of ground time stays grounded")
	assert_near(b.world.athletes[4].recover_t, P.GROUND_MASK * DT, 0.001, "ground time saturates")
	assert_eq(b.world.athletes[0].recover_t + b.world.athletes[0].dive_t, 0.0, "standing athlete has no timers")
	# The fields must hold the real timers: grow a tuning value past one and widen its field.
	var T := preload("res://src/sim/tuning.gd")
	assert_true(roundi(T.JUMP_TIME * 1000.0) <= P.JUMP_MASK, "JUMP_TIME fits the jump field")
	assert_true(roundi(maxf(T.DIVE_RECOVER, T.FUMBLE_KNOCKDOWN) / DT) <= P.GROUND_MASK, "ground timers fit the ground field")
	assert_true(roundi(T.DIVE_TIME / DT) <= P.DIVE_MASK, "DIVE_TIME fits the dive field")

func test_snapshot_carries_and_clears_the_crossing_flag() -> void:
	var host := _match()
	var remote := _match()
	var qb := host.world.find_role(0, R.QB)
	host.world.start_live_with(qb.id)
	qb.position = Vector2(6.0, host.world.los_y + 2.0)
	host.world.step({}, DT)
	qb.position.y = host.world.los_y - 3.0
	host.world.step({}, DT)
	var snap = bytes_to_var(var_to_bytes(P.encode_snapshot(host, 1)))
	assert_true(P.valid_snapshot(snap, remote.world.athletes.size()))
	P.apply_snapshot(remote, snap)
	assert_true(remote.world.ball_crossed_los and not remote.world.forward_pass_thrown)
	assert_true(not remote.world.can_throw(qb.id), "remote agrees that the keeper cannot pass")
	snap["pf"] = 4
	assert_true(not P.valid_snapshot(snap, remote.world.athletes.size()), "unassigned pass bit rejected")

	host.start(0, 36.0)
	host.world.start_live_with(qb.id)
	P.apply_snapshot(remote, P.encode_snapshot(host, 2))
	assert_true(not remote.world.ball_crossed_los and remote.world.can_throw(qb.id),
		"the next snap clears the client's crossing flag")

## #130: a pre-quarters host never makes a client show H1/H2.
func test_legacy_snapshot_shows_quarters() -> void:
	var m := _match()
	var snapshot := P.encode_snapshot(m, 1)
	snapshot["c"] = PackedFloat32Array([2.0, 57.0, 12.0, 0.0])   # no quarter fields: 2nd half
	m.clock.quarter_length = 120.0
	m.clock.quarter = 2
	P.apply_snapshot(m, snapshot)
	assert_eq(m.clock.label(), "Q3 0:57", "2nd half reads as Q3")
	assert_near(m.clock.quarter_length, 150.0, 0.001)
	snapshot["c"] = PackedFloat32Array([1.0, 240.0, 12.0, 0.0, 1.0, 0.0])   # halves-format host
	P.apply_snapshot(m, snapshot)
	assert_eq(m.clock.label(), "Q1 4:00")
	assert_near(m.clock.quarter_length, 150.0, 0.001, "zero length falls back to quarters")

func test_sanitize_input() -> void:
	assert_eq(P.sanitize_input("garbage"), {}, "non-dict rejected")
	var i := P.sanitize_input({"dir": Vector2(10, 0), "spr": true, "block": true})
	assert_near(i["dir"].length(), 1.0, 0.0001, "clamped")
	assert_true(i["sprint"], "sprint")
	assert_true(i["block"], "block")
	var bad := P.sanitize_input({"dir": Vector2(INF, NAN)})
	assert_eq(bad["dir"], Vector2.ZERO, "non-finite zeroed")
	assert_eq(P.sanitize_action({"a": "teleport"}), {}, "unknown action dropped")
	assert_near(P.sanitize_action({"a": "throw", "t": Vector2(1, 2), "p": 9.0})["p"], 1.0, 0.0001, "power clamped")
	assert_eq(P.sanitize_action({"a": "try", "n": 5}), {}, "bad try value")

func test_protocol_rejects_client_roster_changes() -> void:
	var m := _match()
	var athlete_id := m.world.find_role(1, R.LB).id
	for action in [{"a": "team"}, {"a": "pick", "slot": 0}]:
		assert_eq(P.sanitize_action(action), {}, "match protocol rejects %s" % action["a"])
		assert_true(not P.apply_action(m, athlete_id, action), "authority rejects %s" % action["a"])

func test_apply_action_authority() -> void:
	var m := _match()
	var w := m.world
	var their_qb := w.find_role(1, R.LB)  # defender
	assert_true(P.apply_action(m, their_qb.id, {"a": "snap"}), "defense snap key breaks stance")
	assert_eq(w.phase, w.Phase.PRESNAP, "defense can't snap the ball")
	assert_true(not their_qb.set_lock, "defender unlocked")
	assert_true(not P.apply_action(m, their_qb.id, {"a": "snap"}), "second press is a no-op")
	var my_wr := w.find_role(0, R.WR)
	assert_true(P.apply_action(m, my_wr.id, {"a": "snap"}), "offense snaps")
	for i in 30: w.step({}, DT)
	assert_true(not P.apply_action(m, my_wr.id, {"a": "throw", "t": Vector2(26, 50), "p": 0.8}), "non-holder can't throw")
	var qb := w.find_role(0, R.QB)
	assert_true(P.apply_action(m, qb.id, {"a": "throw", "t": Vector2(26, 50), "p": 0.8}), "holder throws")
	var lb := w.find_role(1, R.LB)
	assert_true(P.apply_action(m, lb.id, {"a": "tackle"}), "tackle")
	assert_true(lb.is_diving(), "sender's athlete dives")
	assert_true(not w.find_role(1, R.CB).is_diving(), "others don't")
