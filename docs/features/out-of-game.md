# Crater Bowl: out-of-game experience

This covers everything outside a match: name, brand, menus, settings, finding games, internet play and distribution.
Feature-level doc: how this works **today** on `main`. The in-match game is in the other `docs/features/` docs, the vision in `../vision.md`. Networking internals: `../design/netcode.md`. Open work: GitHub issues labelled `area:ui`, `area:infra` and `area:accessibility` (listed below).

## Identity
- **Name: Crater Bowl.** The stadium is built inside a lunar crater, which matches the graphics pass (lunar dome stadium, HELIOS vs NEBULA).
  No video game with this name was found (2026-11-25 search). The low-gravity football space is crowded (Gridiron's Chaosball, G-Ball, Zero-G), so the name leans on *crater/bowl*, not *gravity*.
- **Mark:** a gold football launching out of a cyan-rimmed crater. Wordmark: "CRATER" in cream + "BOWL" in cyan, set in Graduate (OFL, collegiate block), converted to paths.
  - Sources: `tools/brand/build_logo.py` → `assets/brand/*.svg`; `tools/brand/rasterize.gd` → PNGs (icon 64/256/512, wide and stacked logos).
  - Type (#125): three roles, all OFL. **Graduate** (collegiate block) for the wordmark, PLAY, nameplates and jersey/yard numbers; **Teko** (broadcast scorebug style) for nav, buttons, headings and the HUD (the default); **Barlow Semi Condensed** for paragraphs. Helpers: `UITheme.display_font()`, `font()`/`ui_font()`, `body_font()`. Teko and Barlow are rescaled by `tools/brand/scale_fonts.py` so their capitals match the sizes the layouts were tuned for. Credits are listed in Settings and `ASSETS.md`.
  - Palette (shared with art direction): space `#07080F`, navy `#0E1424`, cream `#FFF4E0`, cyan `#5CE1FF`, orange `#FF6A1F`, gold `#F2BF26`. Constants are in `src/ui/ui_theme.gd`.
- **User data** lives in a fixed dir, `crater-bowl` (`config/use_custom_user_dir`), so a future rename can't orphan profiles. On first windowed launch, `Launch.migrate()` copies data from the old `Fourth & Long` dir. It never overwrites, skips `test_*`, and runs once (`.migrated` marker).

## Architecture (how the menu drives the game)
- `scenes/menu.tscn` is the main scene. It forwards straight to `main.tscn` when headless or when any CLI flag is given, so tests, dedicated hosts and the matchmaker behave exactly as before.
- **Autoload `Launch`** (`src/ui/launch.gd`):
  - `start_game(opts)` stores options that `main._cli_args()` merges in. **A menu choice is the same thing as a CLI launch** (`{"host": true}` == `--host`), so every menu path runs code the test suite already covers.
  - Owns the in-match **Esc overlay** (resume / controls / leave match / quit). Offline play pauses; online play keeps running.
  - **Rebinding and gamepad** work as a translation layer: the player's key, or a gamepad button/stick/trigger, is re-injected as the default key that `main.gd` reads (`src/ui/controls.gd`). Match code never needs to know about bindings.
- Settings live in `user://settings.cfg` (`src/ui/settings_store.gd`): name, fullscreen, vsync, 3D resolution, frame cap, master volume, matchmaker address, UPnP, key bindings, camera zoom (set in-match with the mouse wheel, #140). Headless runs ignore the player's file.

## Menu map
| Screen | What it does |
|---|---|
| Welcome (first run) | Pick a name (2–16 chars, not You/Bot/Host) |
| Play online | Rules (classic/Chaosball) + size + party (Chaosball locks size to a dimmed 3v3; Classic restores the earlier pick, #83), Quick match / Ranked, host a match (optionally listed publicly), join by invite code/IP, live browser of open matches |
| Play vs bots | Offline full match, any size/rules (same Chaosball size lock) |
| Practice | Passing / catching / tackling / scrimmage drills |
| Locker | Level/XP, equip unlocked cosmetics + number |
| Leaderboards | Ranked rating + per-position career tables |
| Last game | Reopen the postgame overview. Team stats keep both columns clear of the scrollbar. |
| Replays | Saved match replays, newest first |
| Settings | Player, video, audio, online, controls (click to rebind; conflicts swap) |

### Design decisions

- The pause menu's gamepad reference uses the live button and trigger maps, so changing a binding also updates its help. It lists the sticks and Start in the same section (#298).
- The postgame box score leaves a 12 px inset before the scrollbar so both teams' right-aligned values stay readable when the overview scrolls (#115).
- **Menu statuses get their own tab on top of the footer** (#221). A status is any one-line message the menu shows: why a match ended (a refusal, "Host disconnected", "Couldn't reach the matchmaker"), an invite-code or name error, the UPnP result. It shows in orange in a small tab centered on the footer's top edge, sized to the text, and hidden when there is no status. It wraps only past the window width, so every status is shown in full. Why: statuses used to sit in the footer row between the links and the build label, a slot only about 190 px wide (about 22 characters) once the music player joined the footer, and they were clipped there ("Update Crater Bowl to pl"). Rejected: wrapping inside that slot (a 60-character reason needs three lines; the footer has room for two), a tooltip with the full text (mouse-only, and the part that gets cut is the instruction the player needs), and a timed toast (a player who looks away misses the reason). The tab overlaps the 22 px gap between the footer and the Play button or panel above it, and click-through is on so it never blocks them. Covered by `tests/visual/menu_long_status_test.gd` (captures `menu-long-status-refusal`, `menu-long-status-invite`).

## Finding games + internet play
- **Matchmaker** (`--matchmaker`) does queues (casual/competitive, parties, Chaosball) and now also the **server browser**: hosts `register` their lobby every 5 s (`src/net/lobby_advertiser.gd`); entries expire after 20 s (`src/net/lobby_registry.gd`).
- **UPnP** (`src/net/port_mapper.gd`): before hosting or queueing, the menu asks the router to forward the UDP port (24565 for hosting, 24566 for queue hosts). It puts the router's **public IP in the invite code**, so friends on other networks can join without manual port forwarding. If UPnP fails, including when the router reports a carrier-grade NAT address, the code falls back to the LAN address. The host sees the failure and the UDP port to forward alongside the invite code in the match lobby. The mapping is removed when hosting ends or the game closes ([online.md](online.md)).

## Distribution
- `./scripts/export.sh [Linux|Windows|macOS]` builds `build/dist/CraterBowl-<VERSION>-{windows,linux,macos}.zip` (~30/24/50 MB). It syncs `VERSION` into `project.godot` + presets, then boot-checks the exported Linux binary (headless practice drill, version line).
  - Needs Godot 4.3 export templates in `~/.local/share/godot/export_templates/4.3.stable/`, from the official `Godot_v4.3-stable_export_templates.tpz` release asset.
- Version: bump `VERSION` (semver). The menu shows it, and the game prints `Crater Bowl vX (OS)` at startup for bug reports.
- `deploy/README-player.txt` ships inside each zip (how to host/join, ports, controls, data location).
- **Matchmaker hosting:** `deploy/Dockerfile.matchmaker` (Docker) or `deploy/crater-bowl-mm.service` (systemd). Either runs the exported Linux binary with `--headless -- --matchmaker --port=24600` on UDP 24600.
- **itch.io:** `ITCH_TARGET=<user>/crater-bowl ./scripts/publish_itch.sh` pushes all three zips with butler (channels windows/linux/macos). It never runs implicitly.

### Store copy (draft)
> **Crater Bowl.** Arcade football under a dome on the Moon. 3v3 to 7v7 online with friends, bots in every empty slot, precision passing, live play calling and routes, plus Chaosball: low gravity, anyone can throw, walls are in play, and pass streaks raise your touchdown value. Quick match, ranked seasons, private lobbies with invite codes, practice drills, replays and earnable cosmetics with no pay-to-win.

## Open issues
Open owner decisions and known gaps moved to GitHub issues on 2026-11-25 (#1):
- #48 Decide: host the public matchmaker (VPS/AWS + DNS)?
- #49 Decide: storefront (itch.io first vs Steam)
- #50 Decide: code signing / notarization
- #32 B07 NAT relay for CGNAT/strict routers + hosted public matchmaker
- #33 Gamepad: right-stick aiming
- #46 Windows exe icon (rcedit)
- #24 C18 Guided tutorial
- #25 C19 Accessibility & camera options
- #22 C16 Audio foundation + live play feed (no in-match audio yet; the menu soundtrack exists)
