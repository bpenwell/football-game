#!/usr/bin/env bash
# Boot the main scene headless for N frames; fail on any script/engine error.
set -uo pipefail
cd "$(dirname "$0")/.."
# Guard the same user data directory Godot uses, including isolated XDG runs.
USERDATA="${XDG_DATA_HOME:-$HOME/.local/share}/crater-bowl"   # project.godot custom_user_dir_name
before=$(ls -l --time-style=+%s "$USERDATA"/{profile,leaderboard,ranked}.json "$USERDATA"/settings.cfg "$USERDATA"/replays 2>/dev/null)
GODOT="${GODOT:-godot}"
FRAMES="${FRAMES:-300}"
BOOT_TIMEOUT=60
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
timeout "$BOOT_TIMEOUT" "$GODOT" --headless --path . --quit-after "$FRAMES" > .smoke-output.log 2>&1
boot=$?
cat .smoke-output.log
case "$boot" in
  0) ;;
  124) echo "SMOKE FAIL: boot timed out after ${BOOT_TIMEOUT}s (log: .smoke-output.log)"; exit 1 ;;
  *) echo "SMOKE FAIL: boot exited with status $boot (log: .smoke-output.log)"; exit 1 ;;
esac
# Dummy-renderer mesh spam (`Parameter "m" is null`, mesh_storage.h) used to be allowed
# here; src/game/headless_mesh_guard.gd removes it (#92), so every run below fails on it.
MESH_NULL='Parameter "m" is null'
if grep -E "SCRIPT ERROR|Parse Error|ERROR:|at: " .smoke-output.log | grep -q .; then
  echo "SMOKE FAIL: errors during boot"; exit 1
fi
echo "SMOKE PASS ($FRAMES frames)"
# Scripted gameplay flow through the real scene
timeout 150 "$GODOT" --headless --path . --fixed-fps 60 -s res://tests/game_flow.gd > .flow-output.log 2>&1
flow=$?
grep -E "FLOW|GAME FLOW" .flow-output.log
if [ $flow -ne 0 ] || grep -E "SCRIPT ERROR|Parse Error|$MESH_NULL" .flow-output.log | grep -q .; then
  grep -E "SCRIPT ERROR|Parse Error|$MESH_NULL|at: " .flow-output.log | head; echo "GAME FLOW FAIL"; exit 1
fi
# Out-of-game flow: real menu scene + Launch autoload + in-process matchmaker
timeout 90 "$GODOT" --headless --path . --fixed-fps 60 -s res://tests/menu_flow.gd -- --settings-file=user://test_menu_settings.cfg > .menu-flow.log 2>&1
menu=$?
grep -E "MENU (OK|FAIL|FLOW)" .menu-flow.log | grep -vE "MENU OK" ; echo "menu checks ok: $(grep -c 'MENU OK' .menu-flow.log)"
if [ $menu -ne 0 ] || grep -E "SCRIPT ERROR|Parse Error|$MESH_NULL" .menu-flow.log | grep -q .; then
  grep -E "SCRIPT ERROR|Parse Error|$MESH_NULL|at: " .menu-flow.log | head; echo "MENU FLOW FAIL"; exit 1
fi
# Two-process online test (host + client over localhost)
./scripts/net_test.sh || exit 1
# Lobby seat cap (#54): in-process host + 8 joiners over localhost, random port
timeout 60 "$GODOT" --headless --path . -s res://tests/net_capacity.gd -- --port=$((27000 + RANDOM % 2000)) > .net-capacity.log 2>&1
cap=$?
grep -E "CAP FAIL|NET CAPACITY" .net-capacity.log
if [ $cap -ne 0 ] || grep -E "SCRIPT ERROR|Parse Error" .net-capacity.log | grep -q .; then
  grep -E "SCRIPT ERROR|Parse Error|at: " .net-capacity.log | head; echo "NET CAPACITY FAIL"; exit 1
fi
# Matchmaking: matchmaker + 2 queued clients
# A failing run prints its whole output (what never happened + log tails), not just the verdict (#283).
for mode in casual competitive party chaos dupname; do
  MODE=$mode ./scripts/mm_test.sh > .mm-test.log 2>&1
  tail -1 .mm-test.log | grep -q "MM TEST PASS" || { cat .mm-test.log; echo "MM TEST FAIL ($mode)"; exit 1; }
done
echo "MM TEST PASS"
after=$(ls -l --time-style=+%s "$USERDATA"/{profile,leaderboard,ranked}.json "$USERDATA"/settings.cfg "$USERDATA"/replays 2>/dev/null)
if [ "$before" != "$after" ]; then echo "USER DATA TOUCHED BY TESTS: $after"; exit 1; fi
echo "USER DATA UNTOUCHED"
rm -f "$USERDATA"/test_*.json
rm -rf "$USERDATA"/test_flow_replays
