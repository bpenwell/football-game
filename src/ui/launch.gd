extends Node
## Autoload "Launch": the out-of-game layer.
## - Holds the options the menu picked; main.gd's _cli_args() merges them, so every
##   menu choice is exactly equivalent to a CLI launch (same code paths the tests use).
## - Migrates data from the old "Fourth & Long" user dir on first run.
## - Loads/applies settings; owns the in-match Esc overlay (resume / leave / quit).

const SettingsStore := preload("res://src/ui/settings_store.gd")
const UITheme := preload("res://src/ui/ui_theme.gd")
const Controls := preload("res://src/ui/controls.gd")
const Advertiser := preload("res://src/net/lobby_advertiser.gd")
const HeadlessMeshGuard := preload("res://src/game/headless_mesh_guard.gd")
const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_SCENE := "res://scenes/main.tscn"
const LEGACY_DIRS := ["godot/app_userdata/Fourth & Long"]   # relative to OS.get_data_dir()
const MIGRATED_MARK := ".migrated"
const VERSION_FILE := "res://VERSION"

var options := {}                 # menu launch options (merged into main._cli_args)
var settings := SettingsStore.new()
var settings_path := SettingsStore.DEFAULT_PATH
var menu_visited := false        # the boot-time "skip menu" rule applies only once
var last_status := ""             # message shown on the menu after returning (e.g. "Disconnected")
var from_menu := false            # the current match was started from the menu (post-game returns to it)
var last_match := {}              # post-game overview handed to the lobby (main.gd _finish_postgame)
var _overlay: CanvasLayer
var _xlate := {}             # pressed key -> default key (rebinding)
var _pad_held := {}          # synthesized key -> held (gamepad)
var _stick := Vector2.ZERO

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("Crater Bowl v%s (%s)" % [version(), OS.get_name()])
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--settings-file="):
			settings_path = a.get_slice("=", 1)
	# Headless = tests/dedicated servers: never touch the player's real data dir.
	if DisplayServer.get_name() != "headless" and not args.has("--no-migrate"):
		for rel in LEGACY_DIRS:
			var copied := migrate(OS.get_data_dir().path_join(rel), OS.get_user_data_dir())
			if not copied.is_empty():
				print("MIGRATED %d files from %s" % [copied.size(), rel])
	# Headless runs (tests, servers) ignore the player's settings unless given a file.
	if DisplayServer.get_name() != "headless" or settings_path != SettingsStore.DEFAULT_PATH:
		settings.load_file(settings_path)
	settings.apply(get_window())
	_xlate = Controls.translation(settings.bindings)
	get_tree().node_added.connect(_on_node_added)
	if HeadlessMeshGuard.needed():   # dummy renderer only: silences mesh_storage.h:120 spam (#92)
		add_child(HeadlessMeshGuard.new())

static func version() -> String:
	var v := FileAccess.get_file_as_string(VERSION_FILE).strip_edges()
	return v if v != "" else "dev"

## True when the process was launched to do something specific (CLI flags) or headless
## (tests, dedicated hosts, matchmaker): skip the menu and go straight to the game scene.
static func should_skip_menu(args: PackedStringArray, display: String) -> bool:
	if display == "headless":
		return true
	for a in args:
		if not (a.begins_with("--settings-file=") or a == "--no-migrate" or a == "--menu"):
			return true
	return false

## Copy every file under old_dir into new_dir (recursive), never overwriting, skipping
## test artifacts (test_* files, test_flow_replays/). Runs once per new_dir (marker file).
static func migrate(old_dir: String, new_dir: String) -> Array:
	var copied := []
	if not DirAccess.dir_exists_absolute(old_dir) or FileAccess.file_exists(new_dir.path_join(MIGRATED_MARK)):
		return copied
	DirAccess.make_dir_recursive_absolute(new_dir)
	_copy_tree(old_dir, new_dir, copied)
	var f := FileAccess.open(new_dir.path_join(MIGRATED_MARK), FileAccess.WRITE)
	if f:
		f.store_string("migrated from %s\n%s\n" % [old_dir, "\n".join(copied)])
	return copied

static func _copy_tree(src: String, dst: String, copied: Array) -> void:
	var d := DirAccess.open(src)
	if d == null:
		return
	for f in d.get_files():
		if f.begins_with("test_") or f.begins_with("."):
			continue
		var to := dst.path_join(f)
		if not FileAccess.file_exists(to) and DirAccess.copy_absolute(src.path_join(f), to) == OK:
			copied.append(to)
	for sub in d.get_directories():
		if sub.begins_with("test_") or sub.begins_with("."):
			continue
		DirAccess.make_dir_recursive_absolute(dst.path_join(sub))
		_copy_tree(src.path_join(sub), dst.path_join(sub), copied)

## Start the game scene with these options (same keys as CLI flags, e.g. {"host": true}).
func start_game(opts: Dictionary) -> void:
	options = opts.duplicate()
	from_menu = true
	last_match = {}
	if settings.player_name != "" and not options.has("name"):
		options["name"] = settings.player_name
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(GAME_SCENE)

func go_to_menu(status: String = "", overview: Dictionary = {}) -> void:
	menu_visited = true
	last_status = status
	last_match = overview
	from_menu = false
	options = {}
	_close_overlay()
	_close_game_network()
	preload("res://src/net/port_mapper.gd").release_all_async()   # hosting ended: unmap (#57)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(MENU_SCENE)

func save_settings() -> void:
	settings.save(settings_path)
	settings.apply(get_window())
	_xlate = Controls.translation(settings.bindings)

func in_game() -> bool:
	var s := get_tree().current_scene
	return s != null and s.scene_file_path == GAME_SCENE

func _close_game_network() -> void:
	var s := get_tree().current_scene
	if s == null:
		return
	for n in ["net", "mm_client"]:
		var node = s.get(n) if n in s else null
		if node != null and node.get("peer") != null:
			node.peer.close()

func _on_node_added(n: Node) -> void:
	# Add the small "ESC MENU" hint whenever a game scene becomes current (not in tests).
	if n.scene_file_path == GAME_SCENE and n.get_parent() == get_tree().root:
		if options.get("public", false):
			_advertise.call_deferred(n)

func _advertise(game: Node) -> void:
	if not is_instance_valid(game):
		return
	var a := Advertiser.new()
	a.name = "Advertiser"
	game.add_child(a)
	var who := settings.player_name if settings.player_name != "" else "Someone"
	print("ADVERTISE via %s: %s" % [settings.matchmaker, error_string(a.setup(game, settings.matchmaker, "%s's match" % who))])

func _input(e: InputEvent) -> void:
	if e.device == Controls.SYNTH_DEVICE or not in_game():
		return
	var esc: bool = (e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE) \
		or (e is InputEventJoypadButton and e.pressed and e.button_index == Controls.PAD_PAUSE)
	if esc:
		get_viewport().set_input_as_handled()
		if _overlay:
			_close_overlay()
		else:
			open_overlay()
		return
	if _overlay:
		return   # menu open: let the GUI have everything
	if e is InputEventKey and _xlate.has(e.keycode):
		get_viewport().set_input_as_handled()
		if _xlate[e.keycode] != KEY_NONE:
			synth_key(_xlate[e.keycode], e.pressed, e.echo)
	elif e is InputEventJoypadButton and Controls.PAD_BUTTONS.has(e.button_index):
		_pad(Controls.default_key(Controls.PAD_BUTTONS[e.button_index]), e.pressed)
	elif e is InputEventJoypadMotion:
		if e.axis == JOY_AXIS_LEFT_X or e.axis == JOY_AXIS_LEFT_Y:
			if e.axis == JOY_AXIS_LEFT_X:
				_stick.x = e.axis_value
			else:
				_stick.y = e.axis_value
			var want := Controls.stick_keys(_stick)
			for k in want:
				_pad(k, want[k])
		elif Controls.PAD_TRIGGERS.has(e.axis):
			_pad(Controls.default_key(Controls.PAD_TRIGGERS[e.axis]), e.axis_value > Controls.TRIGGER_ON)

## Gamepad: emit a key event only on state change.
func _pad(key: int, down: bool) -> void:
	if _pad_held.get(key, false) == down:
		return
	_pad_held[key] = down
	synth_key(key, down)

## Inject a key event the match code understands (default keys).
static func synth_key(key: int, pressed: bool, echo: bool = false) -> void:
	var k := InputEventKey.new()
	k.keycode = key
	k.physical_keycode = key
	k.pressed = pressed
	k.echo = echo
	k.device = Controls.SYNTH_DEVICE
	Input.parse_input_event(k)

func overlay_open() -> bool:
	return _overlay != null

## In-match menu. The match keeps running (online play can't pause); offline we pause.
func menu_open() -> bool:
	return is_instance_valid(_overlay)

func open_overlay() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # POV aim captures it; the menu needs it back
	var game := get_tree().current_scene
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_overlay = CanvasLayer.new()
	_overlay.layer = 90
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UITheme.build()
	root.gui_input.connect(func(ev): if ev is InputEventKey: root.accept_event())
	var dim := ColorRect.new()
	dim.color = Color(UITheme.SPACE, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(320, 0)
	box.add_child(UITheme.heading("Paused" if _offline(game) else "Menu", 30, UITheme.CYAN))
	var resume := _btn(box, "Resume", _close_overlay)
	var controls_button := _btn(box, "Controls", func(): _show_controls(box))
	controls_button.name = "ControlsButton"
	_btn(box, "Leave match", func(): go_to_menu())
	_btn(box, "Quit to desktop", func(): get_tree().quit())
	panel.add_child(box)
	_overlay.add_child(root)
	game.add_child(_overlay)
	resume.grab_focus.call_deferred()
	if _offline(game):
		get_tree().paused = true

func _offline(game) -> bool:
	return game != null and game.get("net") == null and game.get("mm_client") == null

func _show_controls(box: VBoxContainer) -> void:
	var existing := box.get_node_or_null("ControlsHelp")
	if existing != null:
		existing.visible = not existing.visible
		return
	var help := VBoxContainer.new()
	help.name = "ControlsHelp"
	help.add_theme_constant_override("separation", 8)
	box.add_child(help)
	var bindings := GridContainer.new()
	bindings.name = "ControlsBindings"
	bindings.columns = 4
	bindings.add_theme_constant_override("h_separation", 16)
	help.add_child(bindings)
	for action in Controls.ACTIONS:
		var title := Label.new()
		title.text = action[1]
		title.add_theme_font_size_override("font_size", 15)
		bindings.add_child(title)
		var key := Label.new()
		key.text = Controls.key_name(Controls.key_for(action[0], settings.bindings))
		key.add_theme_font_size_override("font_size", 15)
		key.add_theme_color_override("font_color", UITheme.CYAN)
		bindings.add_child(key)
	var notes := Label.new()
	notes.name = "ControlsNotes"
	notes.text = Controls.notes_text()
	notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notes.add_theme_font_size_override("font_size", 14)
	notes.add_theme_constant_override("line_spacing", 0)
	help.add_child(notes)

func _close_overlay() -> void:
	if _overlay and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	get_tree().paused = false

func _btn(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.pressed.connect(cb)
	parent.add_child(b)
	return b
