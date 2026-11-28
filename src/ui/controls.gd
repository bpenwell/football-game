extends RefCounted
## Controls: action table, rebinding and gamepad support as a translation layer.
## The match code reads fixed default keys (main.gd); the Launch autoload turns the
## player's bound key / gamepad input into those default key events. Pure + testable.

## [action id, label, default key]. Gridiron layout (#138): WASD, Q/E spin, F dive,
## R dash, T timeout, C taunt; next play moved off R to Enter.
const ACTIONS := [
	["move_up", "Move up", KEY_W], ["move_down", "Move down", KEY_S],
	["move_left", "Move left", KEY_A], ["move_right", "Move right", KEY_D],
	["sprint", "Sprint", KEY_SHIFT], ["snap", "Snap / break stance (defense: double-tap) / fair catch / jump (live)", KEY_SPACE],
	["throw", "Throw (QB: hold to charge)", KEY_J], ["lob", "Lob modifier", KEY_CTRL],
	["tackle", "Dive / tackle (pre-snap: cycle route)", KEY_F],
	["spin_left", "Spin left (pre-snap: play picker)", KEY_Q], ["spin_right", "Spin right", KEY_E],
	["dash", "Dash (when charged)", KEY_R], ["handoff", "Handoff", KEY_G], ["timeout", "Team timeout", KEY_T],
	["taunt", "Taunt wheel (hold, drag, release)", KEY_C],
	["scoreboard", "Show scoreboard (hold)", KEY_TAB],
	["next", "Next play", KEY_ENTER], ["replay", "Instant replay", KEY_V],
	["try1", "Extra point / toss: receive", KEY_1], ["try2", "Two-point try / toss: kick", KEY_2],
]
const OTHER_CONTROLS := [
	"Mouse: look live · middle drag: look pre-snap · hold C: drag to a taunt, release (tap: last taunt)",
	"QB / passer: mouse aims your view (look higher to throw higher) · hold left click to charge distance, release to throw",
	"Hold right click: block",
	"Replay viewer: Space pause · Left / Right seek · [ / ] speed",
]
const SYNTH_DEVICE := -42     # marks events we injected (never re-translated)
const STICK_DEADZONE := 0.4
const TRIGGER_ON := 0.5
## Gamepad (SDL/Xbox layout) button -> action
const PAD_BUTTONS := {
	JOY_BUTTON_A: "snap", JOY_BUTTON_B: "tackle", JOY_BUTTON_X: "spin_left", JOY_BUTTON_Y: "spin_right",
	JOY_BUTTON_LEFT_SHOULDER: "scoreboard", JOY_BUTTON_RIGHT_SHOULDER: "lob",
	JOY_BUTTON_LEFT_STICK: "sprint", JOY_BUTTON_RIGHT_STICK: "handoff", JOY_BUTTON_BACK: "replay", JOY_BUTTON_DPAD_UP: "next",
	JOY_BUTTON_DPAD_LEFT: "try1", JOY_BUTTON_DPAD_RIGHT: "try2", JOY_BUTTON_DPAD_DOWN: "dash",
}
## Gamepad trigger axis -> action (held while past TRIGGER_ON)
const PAD_TRIGGERS := {JOY_AXIS_TRIGGER_RIGHT: "throw", JOY_AXIS_TRIGGER_LEFT: "sprint"}
const PAD_PAUSE := JOY_BUTTON_START
const PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", JOY_BUTTON_BACK: "Back",
	JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_LEFT: "D-pad left",
	JOY_BUTTON_DPAD_RIGHT: "D-pad right", JOY_BUTTON_DPAD_DOWN: "D-pad down", JOY_BUTTON_START: "Start",
}
const PAD_TRIGGER_NAMES := {JOY_AXIS_TRIGGER_RIGHT: "RT", JOY_AXIS_TRIGGER_LEFT: "LT"}

## Saved bindings are stored as overrides of the default keys, so a default change
## needs a migration. Version 1 = before #138 (C dash, U timeout, T taunt, R next).
const BINDINGS_VERSION := 2
const V1_DEFAULTS := {"dash": KEY_C, "timeout": KEY_U, "taunt": KEY_T, "next": KEY_R}

static func default_key(action: String) -> int:
	for a in ACTIONS:
		if a[0] == action:
			return a[2]
	return KEY_NONE

static func label(action: String) -> String:
	for a in ACTIONS:
		if a[0] == action:
			return a[1]
	return action

static func key_for(action: String, bindings: Dictionary) -> int:
	return int(bindings.get(action, default_key(action)))

## Map of pressed key -> default key it should act as. Only rebound actions appear.
## A default key that was rebound away from its action and not reused maps to KEY_NONE
## (disabled), so rebinding moves an action instead of duplicating it.
static func translation(bindings: Dictionary) -> Dictionary:
	var out := {}
	for a in ACTIONS:
		var k := key_for(a[0], bindings)
		if k != a[2]:
			out[k] = a[2]
	for a in ACTIONS:
		var k := key_for(a[0], bindings)
		if k != a[2] and not out.has(a[2]):
			out[a[2]] = KEY_NONE
	return out

## Which action (if any) a key is bound to.
static func action_for_key(key: int, bindings: Dictionary) -> String:
	for a in ACTIONS:
		if key_for(a[0], bindings) == key:
			return a[0]
	return ""

## Rebind; if another action already uses the key, the two swap keys.
static func rebind(bindings: Dictionary, action: String, key: int) -> Dictionary:
	var b := bindings.duplicate()
	var other := action_for_key(key, b)
	if other != "" and other != action:
		var mine := key_for(action, b)
		if mine == default_key(other):
			b.erase(other)
		else:
			b[other] = mine
	if key == default_key(action):
		b.erase(action)
	else:
		b[action] = key
	return b

## Bring bindings saved under an older default layout up to BINDINGS_VERSION.
## Actions the player never rebound take the new defaults; rebound actions keep their key.
## If a rebound key sits on one of the new defaults (e.g. the player moved dash to R,
## which swapped next play onto C), the moved actions keep their old keys instead, so
## the player's layout stays exactly as it was and no two actions share a key.
static func migrate_bindings(bindings: Dictionary, from_version: int) -> Dictionary:
	if from_version >= BINDINGS_VERSION:
		return bindings
	var out := {}
	for a in bindings:
		out[a] = int(bindings[a])
	var taken := {}
	for a in out:
		taken[out[a]] = true
	var clash := false
	for a in V1_DEFAULTS:
		if not out.has(a) and taken.has(default_key(a)):
			clash = true
	if clash:
		for a in V1_DEFAULTS:
			if not out.has(a):
				out[a] = V1_DEFAULTS[a]
	for a in out.keys():
		if out[a] == default_key(a):
			out.erase(a)
	return out

## Movement keys the left stick holds down for a given stick vector.
static func stick_keys(v: Vector2) -> Dictionary:
	return {KEY_W: v.y < -STICK_DEADZONE, KEY_S: v.y > STICK_DEADZONE,
		KEY_A: v.x < -STICK_DEADZONE, KEY_D: v.x > STICK_DEADZONE}

static func key_name(k: int) -> String:
	return "None" if k == KEY_NONE else OS.get_keycode_string(k)

static func notes_text() -> String:
	var inputs_by_action := {}
	for button in PAD_BUTTONS:
		var action: String = PAD_BUTTONS[button]
		var name: String = PAD_BUTTON_NAMES.get(button, "Button %d" % button)
		inputs_by_action[action] = inputs_by_action.get(action, []) + [name]
	for axis in PAD_TRIGGERS:
		var action: String = PAD_TRIGGERS[axis]
		var name: String = PAD_TRIGGER_NAMES.get(axis, "Axis %d" % axis)
		inputs_by_action[action] = inputs_by_action.get(action, []) + [name]
	var pad_bindings := PackedStringArray()
	for action in inputs_by_action:
		pad_bindings.append("%s  %s" % [" / ".join(inputs_by_action[action]), label(action)])
	var sticks_and_pause := "Left stick  Move · Right stick  QB aim · %s  Pause menu" % PAD_BUTTON_NAMES[PAD_PAUSE]
	return "\n".join(OTHER_CONTROLS) + "\nGamepad — " + sticks_and_pause + " · " + " · ".join(pad_bindings)

static func help_text(bindings: Dictionary) -> String:
	var lines := []
	for a in ACTIONS:
		lines.append("%-24s %s" % [a[1], key_name(key_for(a[0], bindings))])
	lines.append(notes_text())
	return "\n".join(lines)
