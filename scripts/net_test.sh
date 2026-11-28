#!/usr/bin/env bash
# Two-process network test: headless host (5v5) + headless client (default 7v7, must adopt host size).
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
PORT="${PORT:-$((24000 + RANDOM % 1000))}"
# A prior run can cross the tenth-game achievement threshold and alter the XP assertion (#419).
profile_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "$profile_dir"' EXIT
godot_profile_dir="$profile_dir"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) godot_profile_dir="$(cygpath -m "$profile_dir")" || exit 1 ;;
esac
host_profile="$godot_profile_dir/host.json"
client_profile="$godot_profile_dir/client.json"
. scripts/wait_lib.sh   # wait_for / log_has / show_logs: deadline polls, never fixed counts (#283)
# host_up PID PORT LOG: wait for the host's "NET host on PORT: ..." line; true only if it says OK.
host_up() { wait_for "$WAIT_SECS" "$1" log_has "NET host on $2: " "$3" && log_has "NET host on $2: OK" "$3"; }
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
timeout $((40 + WAIT_SECS)) "$GODOT" --headless --path . -s res://tests/net_host.gd -- --host --port="$PORT" --playclock=4 --no-kickoff --size=5 --start-when-ready --advertise=127.0.0.1 --name=Ann --profile-file="$host_profile" --leaderboard-file=user://test_net_lb.json --ranked-file=user://test_net_ranked.json --replay-dir=user://test_flow_replays > .net-host.log 2>&1 &
HOST=$!
# Join the private lobby by its invite code (printed by the host).
CODE_RE="invite code: [0-9A-Z]{5}-[0-9A-Z]{5}"
if ! host_up "$HOST" "$PORT" .net-host.log; then
  kill "$HOST" 2>/dev/null; wait "$HOST" 2>/dev/null
  echo "NET TEST FAIL: host never listened on $PORT after ${WAITED}s"; show_logs .net-host.log; exit 1
fi
if ! wait_for "$WAIT_SECS" "$HOST" log_has "$CODE_RE" .net-host.log; then
  kill "$HOST" 2>/dev/null; wait "$HOST" 2>/dev/null
  echo "NET TEST FAIL: host never printed its invite code after ${WAITED}s"; show_logs .net-host.log; exit 1
fi
CODE=$(grep -oE "$CODE_RE" .net-host.log | head -1 | awk '{print $3}')
echo "invite code: $CODE"
timeout $((35 + WAIT_SECS)) "$GODOT" --headless --path . -s res://tests/net_client.gd -- --join="$CODE" --name=Ann --equip=number:88 --profile-file="$client_profile" > .net-client.log 2>&1
status=$?
kill "$HOST" 2>/dev/null; wait "$HOST" 2>/dev/null
grep -E "NET " .net-client.log
if [ $status -ne 0 ] || grep -E "SCRIPT ERROR|Parse Error" .net-client.log .net-host.log | grep -q .; then
  grep -E "SCRIPT ERROR|Parse Error|at: " .net-client.log .net-host.log | head; show_logs .net-client.log .net-host.log; echo "NET TEST FAIL"; exit 1
fi
# #102: the host keys ranked records by the joiner's install id, sent as a lobby action.
CID=$(grep -oE "NET client install id [0-9a-f]{16,32}" .net-client.log | awk '{print $5}')
if [ -z "$CID" ] || ! grep -q "NET host got install id $CID" .net-host.log; then
  echo "NET TEST FAIL: host didn't receive the client's install id (client '${CID:-<none>}', host: $(grep 'NET host got install id' .net-host.log | head -1))"; exit 1
fi
echo "NET install id reached the host: $CID"
# Host loss (#56): a client in the match whose host dies (SIGKILL: no goodbye packet)
# must return to the menu with "Host disconnected". #86: the client's silence watchdog, not
# ENet's 5-30 s peer timeout, must do it: within DROP_AFTER (+ slack, asserted in net_client.gd).
PORT2=$((PORT + 1000))
timeout $((80 + WAIT_SECS)) "$GODOT" --headless --path . -- --host --port="$PORT2" --no-lobby --no-kickoff --profile-file="$host_profile" --leaderboard-file=user://test_net_lb.json --ranked-file=user://test_net_ranked.json > .net-host2.log 2>&1 &
HOST=$!
if ! host_up "$HOST" "$PORT2" .net-host2.log; then
  pkill -9 -P "$HOST" 2>/dev/null; wait "$HOST" 2>/dev/null
  echo "NET TEST FAIL (host loss): host never listened on $PORT2 after ${WAITED}s"; show_logs .net-host2.log; exit 1
fi
ARMED="$(mktemp -u)"
timeout $((70 + WAIT_SECS)) "$GODOT" --headless --path . -s res://tests/net_client.gd -- --join=127.0.0.1 --port="$PORT2" --host-loss --armed-file="$ARMED" --settings-file=user://test_net_hostloss_settings.cfg --profile-file="$client_profile" > .net-hostloss.log 2>&1 &
CLIENT=$!
wait_for "$WAIT_SECS" "$CLIENT" test -f "$ARMED" || echo "NET client never armed for the host loss after ${WAITED}s; killing the host anyway"
pkill -9 -P "$HOST" 2>/dev/null   # the godot under `timeout` (SIGKILL on timeout itself would orphan it)
wait "$HOST" 2>/dev/null
wait "$CLIENT"; status=$?
rm -f "$ARMED"
grep -E "NET " .net-hostloss.log
if [ $status -ne 0 ] || grep -E "SCRIPT ERROR|Parse Error" .net-hostloss.log | grep -q .; then
  grep -E "SCRIPT ERROR|Parse Error|at: " .net-hostloss.log | head; show_logs .net-hostloss.log .net-host2.log; echo "NET TEST FAIL (host loss)"; exit 1
fi
if ! grep -q "NET host lost (silent" .net-hostloss.log; then
  echo "NET TEST FAIL (host loss): the silence watchdog didn't fire ($(grep 'NET host lost' .net-hostloss.log))"; exit 1
fi
# Version handshake (#165): a client forced to protocol v0 must be refused by a current
# host with the readable reason on its join screen, via the existing refuse() path.
PORT3=$((PORT + 2000))
timeout $((40 + WAIT_SECS)) "$GODOT" --headless --path . -- --host --port="$PORT3" --no-kickoff --advertise=127.0.0.1 --profile-file="$host_profile" --leaderboard-file=user://test_net_lb.json --ranked-file=user://test_net_ranked.json > .net-host3.log 2>&1 &
HOST=$!
if ! host_up "$HOST" "$PORT3" .net-host3.log; then
  kill "$HOST" 2>/dev/null; wait "$HOST" 2>/dev/null
  echo "NET TEST FAIL (version mismatch): host never listened on $PORT3 after ${WAITED}s"; show_logs .net-host3.log; exit 1
fi
timeout $((30 + WAIT_SECS)) "$GODOT" --headless --path . -s res://tests/net_version_client.gd -- --join=127.0.0.1 --port="$PORT3" --protocol-version=0 --profile-file="$client_profile" > .net-version.log 2>&1
status=$?
kill "$HOST" 2>/dev/null; wait "$HOST" 2>/dev/null
grep -E "NET " .net-version.log
if [ $status -ne 0 ] || grep -E "SCRIPT ERROR|Parse Error" .net-version.log .net-host3.log | grep -q . || ! grep -q "NET refused peer .*Update Crater Bowl" .net-host3.log; then
  grep -E "SCRIPT ERROR|Parse Error|at: |NET refused" .net-version.log .net-host3.log | head; show_logs .net-version.log .net-host3.log; echo "NET TEST FAIL (version mismatch)"; exit 1
fi
echo "NET TEST PASS"
