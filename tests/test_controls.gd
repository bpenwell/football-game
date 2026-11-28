extends "res://tests/test_case.gd"
## #138: Gridiron default keys (R dash, T timeout, C taunt, Q/E spin, F dive, WASD) and the
## migration of bindings saved under the old layout (C dash, U timeout, T taunt, R next).
## #298: every mapped controller input is listed in the in-game help.

const Controls := preload("res://src/ui/controls.gd")
const Settings := preload("res://src/ui/settings_store.gd")

const TMP := "user://test_controls_settings.cfg"

func test_default_keys_match_gridiron() -> void:
	var want := {
		"move_up": KEY_W, "move_down": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"sprint": KEY_SHIFT, "snap": KEY_SPACE, "throw": KEY_J, "lob": KEY_CTRL,
		"tackle": KEY_F, "spin_left": KEY_Q, "spin_right": KEY_E,
		"dash": KEY_R, "handoff": KEY_G, "timeout": KEY_T, "taunt": KEY_C,
		"scoreboard": KEY_TAB, "next": KEY_ENTER, "replay": KEY_V, "try1": KEY_1, "try2": KEY_2,
	}
	for action in want:
		assert_eq(Controls.default_key(action), want[action], "%s default" % action)
	assert_eq(Controls.ACTIONS.size(), want.size(), "no action added or removed")

func test_no_two_actions_share_a_default_key() -> void:
	var seen := {}
	for a in Controls.ACTIONS:
		assert_true(not seen.has(a[2]), "%s shares %s with %s" % [a[0], Controls.key_name(a[2]), seen.get(a[2], "")])
		seen[a[2]] = a[0]
	assert_true(not seen.has(KEY_U), "U is free (timeout moved to T)")
	assert_eq(Controls.action_for_key(KEY_R, {}), "dash", "R dashes")
	assert_eq(Controls.action_for_key(KEY_T, {}), "timeout", "T calls timeout")
	assert_eq(Controls.action_for_key(KEY_C, {}), "taunt", "C taunts")
	assert_eq(Controls.action_for_key(KEY_ENTER, {}), "next", "Enter = next play")

func test_gamepad_follows_new_defaults() -> void:
	assert_eq(Controls.default_key(Controls.PAD_BUTTONS[JOY_BUTTON_DPAD_DOWN]), KEY_R, "d-pad down dashes (R)")
	assert_eq(Controls.default_key(Controls.PAD_BUTTONS[JOY_BUTTON_DPAD_UP]), KEY_ENTER, "d-pad up = next play (Enter)")
	assert_eq(Controls.default_key(Controls.PAD_BUTTONS[JOY_BUTTON_B]), KEY_F, "B dives (F)")
	assert_eq(Controls.default_key(Controls.PAD_BUTTONS[JOY_BUTTON_X]), KEY_Q, "X spins left (Q)")

func test_hint_copy_names_new_keys() -> void:
	var help := Controls.help_text({})
	assert_true(help.find("hold C") >= 0 and help.find("T performs") < 0, "taunt hint says hold C")
	assert_true(help.find("wheel: pick taunt") < 0, "the mouse wheel no longer picks taunts (#139)")

func test_gamepad_help_lists_all_bindings() -> void:
	var help := Controls.help_text({})
	var entries := help.split("\n")[-1].split(" · ")
	for button in Controls.PAD_BUTTONS:
		var action: String = Controls.PAD_BUTTONS[button]
		_assert_pad_hint(entries, Controls.PAD_BUTTON_NAMES[button], Controls.label(action))
	for axis in Controls.PAD_TRIGGERS:
		var action: String = Controls.PAD_TRIGGERS[axis]
		_assert_pad_hint(entries, Controls.PAD_TRIGGER_NAMES[axis], Controls.label(action))
	for hint in ["Left stick  Move", "Right stick  QB aim", "Start  Pause menu"]:
		assert_true(help.contains(hint), "gamepad help includes " + hint)

func _assert_pad_hint(entries: PackedStringArray, input: String, label: String) -> void:
	var suffix := "  " + label
	for entry in entries:
		if entry.ends_with(suffix) and entry.trim_suffix(suffix).split(" / ").has(input):
			return
	assert_true(false, "gamepad help includes %s for %s" % [input, label])

func test_migration_untouched_player_gets_new_defaults() -> void:
	assert_eq(Controls.migrate_bindings({}, 1), {}, "never rebound: empty overrides = new defaults")
	var b := Controls.migrate_bindings({"snap": KEY_K}, 1)
	assert_eq(b, {"snap": KEY_K}, "unrelated rebind kept")
	assert_eq([Controls.key_for("dash", b), Controls.key_for("timeout", b), Controls.key_for("taunt", b), Controls.key_for("next", b)],
		[KEY_R, KEY_T, KEY_C, KEY_ENTER], "untouched actions take the new keys")

func test_migration_keeps_custom_bindings() -> void:
	var b := Controls.migrate_bindings({"dash": KEY_X, "timeout": KEY_P}, 1)
	assert_eq([Controls.key_for("dash", b), Controls.key_for("timeout", b)], [KEY_X, KEY_P], "custom keys mean the same action")
	assert_eq([Controls.key_for("taunt", b), Controls.key_for("next", b)], [KEY_C, KEY_ENTER], "rest move to new defaults")
	# A custom key that is the new default collapses to "no override".
	assert_eq(Controls.migrate_bindings({"timeout": KEY_T, "taunt": KEY_Y}, 1), {"taunt": KEY_Y}, "T timeout is now the default")
	# Already-migrated files are left alone.
	assert_eq(Controls.migrate_bindings({"dash": KEY_C}, Controls.BINDINGS_VERSION), {"dash": KEY_C}, "v2 untouched")

func test_migration_clash_keeps_the_old_layout() -> void:
	# Old layout: rebinding dash to R swapped next play onto C. C is now taunt's default,
	# so the moved actions keep their old keys: the player's layout is exactly as before.
	var v1 := {"dash": KEY_R, "next": KEY_C}
	var b := Controls.migrate_bindings(v1, 1)
	var keys := {}
	for a in Controls.ACTIONS:
		var k := Controls.key_for(a[0], b)
		assert_true(not keys.has(k), "migrated layout has no duplicate on %s" % Controls.key_name(k))
		keys[k] = a[0]
	assert_eq([Controls.key_for("dash", b), Controls.key_for("next", b), Controls.key_for("taunt", b), Controls.key_for("timeout", b)],
		[KEY_R, KEY_C, KEY_T, KEY_U], "old layout preserved")
	# A player who put spin on Enter keeps it; next play falls back to its old key.
	var s := Controls.migrate_bindings({"spin_left": KEY_ENTER}, 1)
	assert_eq([Controls.key_for("spin_left", s), Controls.key_for("next", s)], [KEY_ENTER, KEY_R], "Enter stays on spin")
	assert_eq(Controls.key_for("dash", s), KEY_C, "dash keeps C so R isn't shared")

func test_settings_file_migrates_once() -> void:
	var cf := ConfigFile.new()
	cf.set_value("controls", "bindings", {"dash": KEY_R, "next": KEY_C})   # v1 file: no version key
	cf.save(TMP)
	var s := Settings.new()
	s.load_file(TMP)
	assert_eq(Controls.key_for("taunt", s.bindings), KEY_T, "v1 file loads with its old layout")
	assert_true(s.save(TMP), "saved")
	var check := ConfigFile.new()
	check.load(TMP)
	assert_eq(int(check.get_value("controls", "bindings_version", 0)), Controls.BINDINGS_VERSION, "version written")
	var t := Settings.new()
	t.load_file(TMP)
	assert_eq(t.bindings, s.bindings, "reload is stable")
	cf = ConfigFile.new()
	cf.set_value("player", "name", "Ace")   # v1 file, never rebound
	cf.save(TMP)
	var u := Settings.new()
	u.load_file(TMP)
	assert_eq(u.bindings, {}, "never rebound: new defaults")
	DirAccess.remove_absolute(TMP)
