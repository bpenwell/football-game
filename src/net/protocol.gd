extends RefCounted
## Wire protocol: snapshot codec, input sanitizing, authoritative action routing. Pure.

const T := preload("res://src/sim/tuning.gd")
const Routes := preload("res://src/sim/routes.gd")
const Tick := preload("res://src/sim/tick.gd")
const World := preload("res://src/sim/world.gd")
const DefensivePlaybook := preload("res://src/sim/defensive_playbook.gd")
const DIVE_FLAG := 1
const GROUND_FLAG := 2
const LOCK_FLAG := 4
const BLOCK_FLAG := 8
const SPIN_FLAG := 16
const SPIN_LEFT_FLAG := 32   # spin turned left (visual side)
const JUMP_SHIFT := 8          # flags bits 8-17: jump time left in ms (0 = on the ground, #379)
const JUMP_MASK := 1023
const GROUND_SHIFT := 18        # flags bits 18-23: ground time left in ticks (#397)
const GROUND_MASK := 63
const DIVE_SHIFT := 24          # flags bits 24-28: dive time left in ticks (#397)
const DIVE_MASK := 31
const PASS_THROWN_FLAG := 1   # pass flags, separate from athlete flags
const CROSSED_LOS_FLAG := 2
const Emotes := preload("res://src/sim/emotes.gd")

static func encode_snapshot(m, tick: int, acks: Dictionary = {}) -> Dictionary:
	var w = m.world
	var a := PackedFloat32Array()
	var r := PackedInt32Array()
	var moves := PackedFloat32Array()
	for ath in w.athletes:
		a.append_array([ath.position.x, ath.position.y, ath.velocity.x, ath.velocity.y, ath.facing.x, ath.facing.y, ath.stamina])
		var flags := (DIVE_FLAG if ath.is_diving() else 0) | (GROUND_FLAG if ath.is_grounded() else 0) | (LOCK_FLAG if ath.set_lock else 0)
		flags |= (BLOCK_FLAG if ath.blocking else 0) | (SPIN_FLAG if ath.is_spinning() else 0)
		if ath.is_spinning() and ath.spin_dir < 0:
			flags |= SPIN_LEFT_FLAG
		flags |= clampi(roundi(ath.jump_t * 1000.0), 0, JUMP_MASK) << JUMP_SHIFT
		flags |= _ticks(ath.recover_t, GROUND_MASK) << GROUND_SHIFT | _ticks(ath.dive_t, DIVE_MASK) << DIVE_SHIFT
		r.append_array([ath.role, flags, ath.team])
		moves.append_array([ath.move_charge, ath.move_t])
	var b = w.ball
	var pass_flags := (PASS_THROWN_FLAG if w.forward_pass_thrown else 0) | (CROSSED_LOS_FLAG if w.ball_crossed_los else 0)
	var snap := {
		"k": "snap", "t": tick, "ph": w.phase, "off": w.offense_team, "los": w.los_y, "pf": pass_flags, "pt": w.last_possession,
		"a": a, "r": r, "moves": moves,
		"b": PackedFloat32Array([b.state, b.holder_id, b.position.x, b.position.y, b.position.z, b.velocity.x, b.velocity.y, b.velocity.z]),
		"d": PackedFloat32Array([m.downs.offense_team, m.downs.down, m.downs.los, m.downs.first_down_y]),
		"s": PackedInt32Array(m.score),
		"c": PackedFloat32Array([m.clock.half, m.clock.remaining, m.clock.play_clock,
			1.0 if m.clock.final else 0.0, m.clock.quarter, m.clock.quarter_length]),
		"to": PackedInt32Array(m.clock.timeouts),
		"ms": m.state, "tp": m.try_points, "ack": acks, "pl": w.play_name, "rt": _routes_array(w),
		"dc": w.defensive_call, "rf": w.run_flipped, "hc": w.handoff_cooldown,
		"kp": w.kick_play, "kk": w.kicked, "tw": m.toss_winner,
		"cs": PackedFloat32Array([w.streak, w.hold_t]),
	}
	if w.fair_catch_id >= 0:
		snap["fc"] = w.fair_catch_id   # only while signaled: snapshots sit near the 1400-byte budget
	return snap

static func _routes_array(w) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(w.athletes.size())
	for i in w.athletes.size():
		out[i] = Routes.route_index(w.route_of.get(i, "")) if w.route_of.has(i) else -1
	return out

## Validate the entire snapshot before it can advance the client tick or write game state.
static func valid_snapshot(s: Dictionary, athletes: int) -> bool:
	for key in ["ph", "off", "ms", "tp"]:
		if not (s.get(key) is int):
			return false
	if s["ph"] not in [0, 1, 2] or s["off"] not in [0, 1] or s["ms"] not in [0, 1, 2, 3]:
		return false
	var pass_flags = s.get("pf")
	if not _finite_number(s.get("los")) or not (pass_flags is int):
		return false
	if pass_flags & ~(PASS_THROWN_FLAG | CROSSED_LOS_FLAG):
		return false
	if not _float_fields(s.get("a"), athletes * 7) or not _float_fields(s.get("b"), 8):
		return false
	if not _float_fields(s.get("d"), 4) or not _float_fields(s.get("c"), 4, 6):
		return false
	if not _int_fields(s.get("r"), athletes * 3) or not _int_fields(s.get("s"), 2):
		return false
	if s.has("moves") and not _float_fields(s["moves"], athletes * 2):
		return false
	if s.has("cs") and not _float_fields(s["cs"], 2):
		return false
	if s.has("rt") and not _int_fields(s["rt"], athletes):
		return false
	if s.has("to") and not _int_fields(s["to"], 2):
		return false
	if s["b"][0] not in [0.0, 1.0, 2.0, 3.0] or s["b"][1] < -1 or s["b"][1] >= athletes:
		return false
	if s["d"][0] not in [0.0, 1.0] or s["d"][1] < 1 or s["d"][1] > 4:
		return false
	for i in athletes:
		if s["r"][i * 3] < 0 or s["r"][i * 3] > 8:
			return false
	for key in ["pl", "dc", "kp"]:
		if not (s.get(key, "") is String):
			return false
	for key in ["rf", "kk"]:
		if not (s.get(key, false) is bool):
			return false
	var possession = s.get("pt", s["off"])
	var toss = s.get("tw", -1)
	if not (possession is int and possession in [0, 1] and toss is int and toss in [-1, 0, 1]):
		return false
	if not _finite_number(s.get("hc", 0.0)):
		return false
	var fc = s.get("fc", -1)
	if not (fc is int and fc >= -1 and fc < athletes):
		return false
	var acks = s.get("ack", {})
	if not (acks is Dictionary) or acks.size() > athletes:
		return false
	for aid in acks:
		if not (aid is int and aid >= 0 and aid < athletes and acks[aid] is int and acks[aid] >= 0):
			return false
	return true

static func _float_fields(values, count: int, max_count := -1) -> bool:
	if not (values is PackedFloat32Array) or values.size() < count or values.size() > maxi(count, max_count):
		return false
	for value in values:
		if not is_finite(value):
			return false
	return true

static func _int_fields(values, count: int) -> bool:
	return values is PackedInt32Array and values.size() == count

static func _finite_number(value) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func apply_snapshot(m, s: Dictionary) -> void:
	var w = m.world
	w.phase = s["ph"]
	w.offense_team = s["off"]
	w.los_y = s["los"]
	var pass_flags: int = s["pf"]
	w.forward_pass_thrown = (pass_flags & PASS_THROWN_FLAG) != 0
	w.ball_crossed_los = (pass_flags & CROSSED_LOS_FLAG) != 0
	w.last_possession = s.get("pt", w.offense_team)
	var a: PackedFloat32Array = s["a"]
	var r: PackedInt32Array = s["r"]
	var moves: PackedFloat32Array = s.get("moves", PackedFloat32Array())
	for i in mini(w.athletes.size(), r.size() / 3):
		var ath = w.athletes[i]
		var o := i * 7
		ath.position = Vector2(a[o], a[o + 1])
		ath.velocity = Vector2(a[o + 2], a[o + 3])
		ath.facing = Vector2(a[o + 4], a[o + 5])
		ath.stamina = a[o + 6]
		ath.role = r[i * 3]
		var flags := r[i * 3 + 1]
		ath.dive_t = maxi(1, flags >> DIVE_SHIFT & DIVE_MASK) / Tick.HZ if flags & DIVE_FLAG else 0.0
		ath.recover_t = maxi(1, flags >> GROUND_SHIFT & GROUND_MASK) / Tick.HZ if flags & GROUND_FLAG else 0.0
		ath.set_lock = (flags & LOCK_FLAG) != 0
		ath.blocking = (flags & BLOCK_FLAG) != 0
		ath.spin_move = (flags & SPIN_FLAG) != 0
		if moves.size() >= i * 2 + 2:
			ath.move_charge = moves[i * 2]
			ath.move_t = moves[i * 2 + 1]
		ath.spin_dir = -1 if flags & SPIN_LEFT_FLAG else 1
		ath.jump_t = minf(float(flags >> JUMP_SHIFT & JUMP_MASK) / 1000.0, T.JUMP_TIME)
	var b: PackedFloat32Array = s["b"]
	w.ball.state = int(b[0])
	w.ball.holder_id = int(b[1])
	w.ball.position = Vector3(b[2], b[3], b[4])
	w.ball.velocity = Vector3(b[5], b[6], b[7])
	var d: PackedFloat32Array = s["d"]
	m.downs.offense_team = int(d[0])
	m.downs.down = int(d[1])
	m.downs.los = d[2]
	m.downs.first_down_y = d[3]
	var sc: PackedInt32Array = s["s"]
	m.score = [sc[0], sc[1]]
	var c: PackedFloat32Array = s["c"]
	m.clock.remaining = c[1]
	m.clock.play_clock = c[2]
	m.clock.final = c[3] > 0.5
	# #130: quarters only. A pre-quarters snapshot has no quarter: its half maps to Q1/Q3,
	# and a missing or zero (halves-format) length falls back to the default quarter.
	if c.size() > 4:
		m.clock.quarter = int(c[4])
	else:
		m.clock.half = int(c[0])
	m.clock.quarter_length = c[5] if c.size() > 5 else 0.0
	if s.has("to"):
		m.clock.timeouts = Array(s["to"])
	m.state = s["ms"]
	m.try_points = s["tp"]
	w.play_name = str(s.get("pl", w.play_name))
	w.defensive_call = s.get("dc", "")
	w.run_flipped = s.get("rf", false)
	w.handoff_cooldown = s.get("hc", 0.0)
	w.kick_play = str(s.get("kp", ""))
	w.kicked = s.get("kk", false) == true
	w.fair_catch_id = int(s.get("fc", -1))
	m.toss_winner = int(s.get("tw", -1))
	var cs: PackedFloat32Array = s.get("cs", PackedFloat32Array([0, 0]))
	w.streak = int(cs[0])
	w.hold_t = cs[1]
	var rt: PackedInt32Array = s.get("rt", PackedInt32Array())
	w.route_of = {}
	for i in rt.size():
		if rt[i] >= 0 and rt[i] < Routes.ROUTE_NAMES.size():
			w.route_of[i] = Routes.ROUTE_NAMES[rt[i]]

## Seconds left on a timer as whole ticks for the wire: at least 1 while it runs, capped to the field.
static func _ticks(t: float, cap: int) -> int:
	return clampi(roundi(t * Tick.HZ), 1, cap) if t > 0.0 else 0

static func _finite_v(v) -> bool:
	return v is Vector2 and is_finite(v.x) and is_finite(v.y)

## Client input -> safe dict, or {} if malformed.
static func sanitize_input(msg) -> Dictionary:
	if not (msg is Dictionary):
		return {}
	var dir = msg.get("dir", Vector2.ZERO)
	if not _finite_v(dir):
		dir = Vector2.ZERO
	var seq = msg.get("seq", 0)
	if not (seq is int) or seq < 0:
		seq = 0
	return {"dir": (dir as Vector2).limit_length(1.0), "sprint": _flag(msg, "spr"), "seq": seq, "block": _flag(msg, "block")}

## True only for a real bool `true`. `v == true` raises a script error when a peer sends a
## String/int there, so wire flags are type-checked first.
static func _flag(d: Dictionary, key: String) -> bool:
	var v = d.get(key, false)
	return v is bool and v

## Shape gate for anything entering the host's action queue (#77): a Dictionary whose
## "a" is a String. Field-level checks stay in sanitize_action; this only guarantees
## the dispatcher can read act["a"] without a script error (comparing an int, Array...
## to a String with == aborts the host tick in Godot 4).
static func is_action(act) -> bool:
	return act is Dictionary and (act.get("a") is String or act.get("a") is StringName)

static func sanitize_action(act) -> Dictionary:
	if not is_action(act):
		return {}
	match act.get("a", ""):
		"snap", "tackle", "recall_call", "flip_play", "handoff", "timeout":
			return {"a": act["a"]}
		"dash", "spin":
			if act["a"] == "spin" and act.has("s"):   # Q / E: spin left (-1) / right (+1) of facing
				var side = act["s"]
				return {"a": "spin", "s": side} if side is int and (side == -1 or side == 1) else {}
			var dir = act.get("dir", Vector2.ZERO)
			return {"a": act["a"], "dir": dir.limit_length(1.0)} if _finite_v(dir) else {}
		"throw":
			var p = act.get("p", 0.0)
			if not (p is float or p is int) or not is_finite(float(p)):
				return {}
			if act.has("d"):   # POV throw: view direction + launch angle
				var d = act["d"]
				var ang = act.get("ang", 0.0)
				if not _finite_v(d) or (d as Vector2).length_squared() < 0.0001 or not (ang is float or ang is int) or not is_finite(float(ang)):
					return {}
				return {"a": "throw", "d": (d as Vector2).normalized(), "ang": clampf(float(ang), T.POV_ANGLE_MIN, T.POV_ANGLE_MAX),
					"p": clampf(float(p), 0.0, 1.0)}
			var t = act.get("t", Vector2.ZERO)
			if not _finite_v(t):
				return {}
			return {"a": act["a"], "t": t, "p": clampf(float(p), 0.0, 1.0), "lob": _flag(act, "lob")}
		"emote":
			var e = act.get("e", "")
			return {"a": "emote", "e": e} if e is String and Emotes.has(e) else {}
		"kick":
			var kt = act.get("t", Vector2.ZERO)
			var kp = act.get("p", 0.0)
			if not _finite_v(kt) or not (kp is float or kp is int) or not is_finite(float(kp)):
				return {}
			return {"a": "kick", "t": kt, "p": clampf(float(kp), 0.0, 1.0)}
		"kick_call":
			var k = act.get("k", "")
			return {"a": "kick_call", "k": k} if k is String and k in ["", "punt", "fg"] else {}
		"toss":
			var ch = act.get("c", "")
			return {"a": "toss", "c": ch} if ch is String and ch in ["receive", "kick"] else {}
		"try":
			var n = act.get("n", 1)
			return {"a": "try", "n": n} if n is int and (n == 1 or n == 2) else {}
		"play":
			var p = act.get("p", "")
			return {"a": "play", "p": p} if p is String and (Routes.PLAYBOOK.has(p) or Routes.RUN_PLAYS.has(p)) else {}
		"formation":
			var f = act.get("f")
			return {"a": "formation", "f": f} if World.valid_formation(f) else {}
		"defense":
			var id = act.get("p", "")
			return {"a": "defense", "p": id} if id is String and DefensivePlaybook.CALLS.has(id) else {}
		"route":
			var r = act.get("r", "")
			return {"a": "route", "r": r} if r is String and Routes.ROUTES.has(r) else {}
	return {}

## Authoritative: perform `action` on behalf of `athlete_id`. Returns success.
## `action` is untyped on purpose: a non-Dictionary is rejected here instead of aborting the caller.
static func apply_action(m, athlete_id: int, action) -> bool:
	var act := sanitize_action(action)
	if act.is_empty():
		return false
	var w = m.world
	var ath = w.get_athlete(athlete_id)
	if ath == null:
		return false
	match act["a"]:
		"snap":
			# One key, routed by side: offense hikes, defense breaks stance, and a
			# returner under a punt/kickoff in the air signals a fair catch (#189).
			# In live play everyone else jumps (#379).
			if w.can_signal_fair_catch(athlete_id):
				return w.signal_fair_catch(athlete_id)
			if w.phase == w.Phase.LIVE:
				return w.jump(athlete_id)
			if ath.team == w.offense_team:
				return w.snap()
			return w.break_stance(athlete_id)
		"tackle":
			return w.tackle(athlete_id)
		"dash", "spin":
			if act.has("s"):
				return w.spin(athlete_id, act["s"])
			return w.evade(athlete_id, act["a"] == "spin", act["dir"])
		"throw":
			if act.has("d"):   # POV throw: charge = power
				return w.throw_dir(athlete_id, act["d"], act["ang"], act["p"])
			return w.throw(athlete_id, act["t"], T.PLAYER_PASS_POWER, act["lob"], false)
		"emote":
			return w.emote(athlete_id, act["e"])
		"handoff":
			return w.handoff(athlete_id)
		"timeout":
			return m.call_timeout(ath.team)
		"try":
			return ath.team == w.offense_team and m.choose_try(act["n"])
		"kick":
			return w.kick(athlete_id, act["t"], act["p"])
		"kick_call":
			return ath.team == w.offense_team and m.call_kick(act["k"])
		"toss":
			return m.choose_toss(ath.team, act["c"])
		"play":
			return ath.team == w.offense_team and w.phase == w.Phase.PRESNAP and w.call_play(act["p"])
		"formation":
			return w.choose_formation(ath, act["f"])
		"recall_call":
			return w.recall_call(ath.team)
		"flip_play":
			return ath.team == w.offense_team and w.flip_play()
		"defense":
			return ath.team != w.offense_team and w.call_defense(act["p"])
		"route":
			return w.phase == w.Phase.PRESNAP and w.set_route(athlete_id, act["r"])
	return false

# ---- version handshake (#165) ----
## Wire/sim compatibility version. Bump it in the same PR as any change to the wire format
## (message keys or fields, snapshot layout, action shapes) or to sim rules a host and client
## must agree on (src/sim). Rule and reasons: docs/design/netcode.md "Version handshake".
const VERSION := 13
const VERSION_FILE := "res://VERSION"
const VERSION_FLAG := "--protocol-version="   # debug: pretend to be another version (net_test.sh)

## This process's protocol version: VERSION, or the `--protocol-version=N` debug override.
static func local_version() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(VERSION_FLAG) and a.trim_prefix(VERSION_FLAG).is_valid_int():
			return int(a.trim_prefix(VERSION_FLAG))
	return VERSION

## Human build label from the VERSION file (informational, logged; compatibility is `v`).
static func build() -> String:
	var b := FileAccess.get_file_as_string(VERSION_FILE).strip_edges() if FileAccess.file_exists(VERSION_FILE) else ""
	return b if b != "" else "dev"

## First message a client sends to a game host (`k:"hello"`); the matchmaker reads `v` off `enq`.
static func hello(v: int = local_version()) -> Dictionary:
	return {"k": "hello", "v": v, "build": build()}

## Why a peer announcing version `theirs` can't play with this one (`ours`); "" = compatible.
## `theirs` comes off the wire: anything but an int means a build from before the handshake.
static func version_refusal(theirs, ours: int = local_version()) -> String:
	if theirs is int and theirs == ours:
		return ""
	if not (theirs is int):
		return "Update Crater Bowl to play online (server is v%d, you have an older build)" % ours
	if theirs < ours:
		return "Update Crater Bowl to play online (server is v%d, you have v%d)" % [ours, theirs]
	return "This server runs an older Crater Bowl (server is v%d, you have v%d)" % [ours, theirs]

## Client side of the same check (#224): why we (`ours`) can't play on a host whose `welcome`
## announced `theirs`; "" = compatible. No int `v` means a host from before the handshake.
static func host_version_refusal(theirs, ours: int = local_version()) -> String:
	if theirs is int and theirs == ours:
		return ""
	if not (theirs is int):
		return "This server runs an older Crater Bowl (server is an older build, you have v%d)" % ours
	if theirs < ours:
		return "This server runs an older Crater Bowl (server is v%d, you have v%d)" % [theirs, ours]
	return "Update Crater Bowl to play online (server is v%d, you have v%d)" % [theirs, ours]
