# Testing Crater Bowl without opening the game

**Never launch a windowed game (`godot --path .`, `godot -e`) to check your work.** In WSL it opens a
real window on the user's desktop, and several sessions doing it at once is disruptive. Use the tools
below instead. Every check here runs offscreen and in parallel with other sessions.

**The one command:** `./scripts/check.sh` (full, about 3–4 min) or `./scripts/check.sh --fast` (about 45 s).
Run the full one before every commit that touches code. The pre-commit hook runs `--fast`.

| What you want to know | Command | Time |
|---|---|---|
| Everything below in order, fail-fast | `./scripts/check.sh [--fast]` | 45s / 3–4 min |
| Every script compiles + perf/purity lint rules | `./scripts/lint.sh` | ~5s |
| Rules/sim logic is right | `./scripts/test.sh` | ~10s |
| Nothing got slower (render budget + CPU medians) | `./scripts/perf.sh` | ~30s |
| Scene boots clean + scripted play works | `./scripts/smoke.sh` (also runs net + mm) | ~2–3 min |
| Networked behavior | `./scripts/net_test.sh` (host + client flow, then a host-loss phase that SIGKILLs a second host, #56, then a client forced to `--protocol-version=0` that must be refused with the version reason, #165), `./scripts/mm_test.sh`; lobby seat cap: `godot --headless --path . -s res://tests/net_capacity.gd` (one process, host + 8 joiners; run by smoke.sh) | ~15s each |
| **What it looks like** (visuals, HUD, camera, art) | `./scripts/shot.sh ...` then view the PNGs | ~30s |
| **What changed visually** (PR evidence) | `./scripts/before_after.sh ...` then `./scripts/pr_evidence.sh <PR#> <out>` | ~1–4 min |

## The gate tiers (`scripts/check.sh`)

The gate checks that Godot is available before running lint. Set `GODOT=/path/to/godot` when using
a binary outside `PATH`. The Ubuntu 24.04 PR workflow installs renderer packages from the Ubuntu
archives and runs `bash tests/ci_setup_test.sh` to check setup and headless boot failure reporting without
changing system APT state. Smoke reports a boot timeout, nonzero exit or logged engine error before
starting gameplay flow (#444).

| Tier | Steps | Catches |
|---|---|---|
| `lint` | `tools/lint.gd` compiles every `.gd` (src, tests, tools); grep rules: no default-tessellation primitive meshes in `player.gd`, no engine/time/random calls in `src/sim` | parse errors in files no test loads; perf anti-patterns; sim purity breaks (determinism, server safety) |
| `unit` | `tests/test_*.gd` via `tests/run_tests.gd` | rule/sim regressions. Includes `test_determinism.gd` (two 7v7 and Chaosball bot games stay bit-identical) and `test_render_perf.gd` (view interpolation, cache sharing, low-poly primitives) |
| `perf` | `tests/render_budget.gd` (triangles, instances, shadow casters, materials, skinned meshes in the real scene: counts, so they never flake) plus `tools/bench.gd` (median per-tick CPU, object growth) | order-of-magnitude slowdowns, per-frame allocation leaks. Budgets: `docs/optimization/README.md` §4 |
| `smoke` | boot 300 frames, `tests/game_flow.gd`, `tests/menu_flow.gd`, net, matchmaking (casual and competitive), user-data guard | anything player-facing end to end |

**User data is isolated.** `check.sh` points `XDG_DATA_HOME` at a fresh temp dir, so `user://`
for every test process is throwaway. Tests can't touch the player's saves or settings, and the user
(or another session) changing settings mid-run can't fail the guard. Running `smoke.sh` alone still
uses the real dir plus its before/after guard, so prefer `check.sh`.

**Pre-commit hook (opt-in).** Nothing enables it on clone. `./scripts/install-hooks.sh` sets
`core.hooksPath=scripts/githooks` in the clone's git config, so it applies to every worktree at once,
including other sessions' (a branch without `scripts/githooks` simply has no hook). Once installed,
`scripts/githooks/pre-commit` exits immediately unless the staged files include a `.gd`, `.tscn`, `.tres`,
`.sh` or `.godot` path (docs-only commits stay instant). Otherwise it runs `./scripts/check.sh --fast`
against the worktree as it sits on disk, unstaged edits included, and blocks the commit if that fails.
Bypass with `git commit --no-verify` and say why in the commit message. To turn it off again:
`git config --unset core.hooksPath`. Hook or not, **run `./scripts/check.sh` yourself before committing
your change**, and stage only your own paths (`AGENTS.md` "Shipping").

**Writing tests that catch real bugs:**
- Test through the real entry point the player uses (`_key()` / `--press`), not internals.
- Assert the property, not the implementation. Example: "views show replay frames" asserts the view's
  *target* equals the replay sample exactly, plus that the drawn position is within one interpolation step.
- When an end-to-end check covers several rules (e.g. the net flow's rejected seat requests), also assert each
  rule in a unit test, so a failure names the rule that changed.
- A new gate must fail when you plant the bug it's meant to catch. Plant it once, see it go red, then revert.
- Never weaken or delete an older test to go green. If a test encodes old behavior on purpose,
  change it in the same commit as the behavior and say so in the message.
- Anything that binds a port picks a random one per run (`net_test.sh`, `mm_test.sh`, `menu_flow.gd`):
  several sessions run `smoke.sh` at once, and a fixed port made `menu_flow` fail whenever two overlapped.
- Never wait for a process to start with a fixed `sleep` or a fixed-count poll: on a loaded machine (load
  average 20-60 on WSL) Godot boots many times slower, and the old 50 x 0.1 s invite-code poll gave up and
  cascaded into a dozen unrelated NET failures (#283). Use `scripts/wait_lib.sh`: `wait_for` polls until a
  generous deadline (`WAIT_SECS`, default 90 s) and stops early when the awaited process exits; on failure
  name the step that never happened and `show_logs` the relevant logs. `timeout` caps are hang guards and
  get the same headroom. This never loosens an assertion: a passing run waits only as long as it needs.
- Timing checks use medians and generous budgets. Count-based checks (triangles, nodes, events) are preferred
  because they're identical on every machine.
- A wall-clock bound on a frame-driven timer must discount time the code under test deliberately doesn't
  count. The net_test.sh host-loss check subtracts the client's own frame gaps beyond
  `SILENCE_STEP_MAX`, because the watchdog caps each frame at that. Without it, a starved test
  process failed the bound under load while the watchdog fired on time (#279).

## Two ways to run Godot offscreen

1. **`--headless`** (test.sh, smoke.sh, net/mm tests). Dummy renderer and dummy audio, no display.
   Fast, but **it draws no pixels**: `get_viewport().get_texture().get_image()` comes back empty.
   Use it for logic, scene flow and anything you can assert in code. Godot 4.3's dummy renderer
   prints `Parameter "m" is null` (`mesh_storage.h`) when a freed MeshInstance3D held the last
   reference to its mesh. `src/game/headless_mesh_guard.gd` (added by Launch only under
   `--headless`) holds such meshes until the node is gone, so headless runs are clean. smoke.sh
   fails the boot, game_flow and menu_flow steps if that line reappears (#92). Freeing a mesh node
   outside the tree skips the guard: keep its mesh referenced until after `free()`
   (see `CharacterArt.instance()`). A Label3D frees its own mesh, so a test that builds and
   frees Label3Ds outside the tree frees them with `HeadlessMeshGuard.free_node()` (#179); in-tree
   Label3Ds are covered by the guard, which flushes when one leaves the tree (#217).
   test.sh fails on any `ERROR:` line in the unit run and names the test that printed it.
2. **Xvfb + Mesa software GL** (`scripts/shot.sh`). Real Compatibility (OpenGL 3) renderer on
   `llvmpipe` (CPU) inside a private virtual X display. You get real lighting, shadows, materials
   and HUD, and nothing appears on screen. It is slower (~6–7 fps), so capture a few frames rather
   than playing whole drives. Needs `xvfb-run` (`sudo apt install xvfb`; already installed here).

`--write-movie` and other in-engine capture need a real renderer too, so they also need mode 2.
3. **Native Windows (Git Bash)**: `shot.sh` detects MINGW/MSYS and skips Xvfb. It renders on the real
   GPU (OpenGL 3) in a window parked at `-20000,-20000`, so nothing shows except a brief taskbar button.
   Set `GODOT` to the Windows `*_console.exe` so stdout reaches the log. Display scaling enlarges
   PNGs (1280x720 comes out about 2558x1438 at 200%).

## Automated screenshots for pull requests

Run `./scripts/visual_test.sh` to execute rendered integration tests on a private Xvfb display.
It prints the output directory, and `VISUAL_OUTPUT=/absolute/path` lets you choose the directory.
Each case gets `VISUAL_CASE_TIMEOUT` seconds (default 180); a case that runs out prints
`VISUAL FAIL: <case> timed out after Ns` and stops the run (#281).
Each test gets its own output subdirectory and its own fresh, empty Godot user data
(`XDG_DATA_HOME` and `XDG_CONFIG_HOME`; only the `XDG_CACHE_HOME` shader cache is shared), so a case
that saves settings, a profile or replays to the default `user://` paths can't leak them into a later
case, whatever the order (#236).
`harness.gd` asserts that every case starts with nothing in `user://` but Godot's own logs and shader
cache, and `cross_case_save_test.gd` deliberately saves a name to the default `settings.cfg` early in
the run so later first-run cases (`menu_boot_test`, `lobby_real_render_test`) prove it. Per-test
`launch.settings_path = "user://test_<case>_settings.cfg"` lines are optional now; existing ones can stay.

Add a `tests/visual/<scenario>_test.gd` script extending `tests/visual/harness.gd`. Exercise the
production scene, assert the relevant behavior with `check()`, then `await capture("state-name")`
while that state is visible. Finish with `finish()` so failed checks fail the run. Inspect the PNG
before opening the PR. The PR tests workflow uploads the captures and test logs as
`visual-test-evidence`; link that Actions artifact in the PR for the full set of captures and logs.
The images you embed in the PR are **before/after pairs** (next section).

## Before/after screenshots (required for visual PRs)

A reviewer can't judge a visual change from an "after" picture alone. Every PR that changes what
the player sees embeds **matched pairs**: the same screen, frame and arguments on `origin/main`
and on your branch, side by side. Two commands produce and publish them:

```bash
# 1. Capture: runs the same capture on origin/main (temp worktree) and on your working tree.
./scripts/before_after.sh menu                                    # all main-menu screens
./scripts/before_after.sh potg                                    # post-game flow
./scripts/before_after.sh shot presnap --no-kickoff --frames=60,260 --snap=120   # any shot.sh args
./scripts/before_after.sh visual scorebug                         # tests/visual/scorebug_test.gd
#    --base=REF picks another base, --out=DIR the output dir. Runs into one --out accumulate.

# 2. Look at OUT/compare/*.png (before left with a grey bar, after right with a green bar).
#    Write OUT/captions.txt, one "name: what the reviewer should notice" per pair you'll publish.

# 3. Publish after opening the PR (pushes orphan branch pr-evidence/<PR#>, prints the table):
./scripts/pr_evidence.sh 123 "$OUT" menu_online presnap_0060      # names or globs; default all
```

Paste the printed `| What changed | Before | After |` table under `### Testing`, then open the PR
page and check that every image displays.

**Rules**
- **Same capture on both sides.** Never pair a fresh "after" with an old screenshot from a
  different run, frame or resolution. `before_after.sh` guarantees this; hand-made pairs don't.
- **Show the change, not everything.** Publish the pairs that show the change (usually 2–6). Also include
  one screen your change should *not* affect, to show nothing else broke.
- **Captions say what to look at, in plain words** ("panel is opaque: no lobby player or INVITE pin
  behind the text"), not the file name or jargon. They become the alt text and the first column.
- **New screen or new test?** `before_after.sh` copies a capture script or `tests/visual` case that
  only exists on your branch into the base tree, so the base is photographed with the same test.
  Its `check()`s may fail on the base. The script reports that failure and compares any captures it
  produced. A failed branch run exits nonzero even if it saved PNGs. Its raw captures stay in
  `OUT/after` for inspection. A screen that exists on only one side shows as `_(new screen)_` /
  `_(removed)_` in the table. `bash tests/before_after_test.sh` exercises both exit paths (#324).
- **Read `changed=` as a hint.** A pair reports `0.0%` and `UNCHANGED` when no sampled pixel
  differs beyond the comparison tolerance. A positive difference that rounds to zero displays
  as `<0.1%` (#357). Menu animation can move a few percent of pixels. Look at the paired images
  to verify what changed. `bash tests/before_after_test.sh` exercises an identical pair and a
  single-pixel change.
- **Sides run one after the other** (about 3–4 min for `menu`). `PARALLEL=1` halves that, but two
  llvmpipe renders at once load the CPU enough that time-driven motion drifts: an untouched
  `scorebug` frame measured 39% changed in parallel and 0.4% serial (2026-11-25, WSL, 1280x720).
- **Comparison write errors fail the command.** The error names the output directory or PNG that failed, and the
  raw captures stay in `OUT/before` and `OUT/after`. Run `bash tests/before_after_compare_test.sh` to exercise a
  blocked comparison destination with real offscreen captures (#329).
- User data is throwaway on both sides, and the base worktree is removed when the script exits.
- **Linux/WSL only** (needs Xvfb, like `shot.sh`). On macOS or Windows, use the CI
  `visual-test-evidence` artifact as described in AGENTS.md "Regressions" until `remote_shots.sh` (#121) lands.
- Re-running `pr_evidence.sh` adds a commit on top of the branch, so earlier image links keep working.

**Captures are regression baselines.** CI will diff every capture against the same capture rendered
from main (`docs/design/regression-baselines.md`, #121), so:

- Set exact state, and settle camera easing and animations before `capture()`. A capture must not
  depend on wall-clock time or on how many frames have run. On 2026-11-25 (WSL, llvmpipe), 20 of 23
  captures differed on more than 0.1 % of pixels between two identical runs, mostly from the camera
  still easing (#124).
- Capture names are the comparison keys. Don't rename or delete one to hide a diff.
- Every player-visible state a PR adds or changes gets a capture. A bug fix for something visible
  adds the capture that would have shown it.
- On macOS or Windows (no Xvfb), push a draft PR and read the captures from the run's
  `visual-test-evidence` artifact: `gh run download <run-id> -n visual-test-evidence`.

## Screenshots: `scripts/shot.sh`

```bash
./scripts/shot.sh --frames=60,200 --snap=100            # pre-snap and mid-play
./scripts/shot.sh --frames=160 --press=40:Tab --snap=100  # switch position, then snap
./scripts/shot.sh --every=30 --snap=60 --frames=300     # strip of frames: 30, 60, ... 300
./scripts/shot.sh --frames=30 --size=5 --practice=routes  # any other arg goes to main.gd
./scripts/shot.sh --out=/tmp/hud/before --frames=30     # choose the output prefix
```

It prints `SHOT <absolute path> (OK)` per image. **Open the PNGs with your Read/image tool and
look at them.** A file existing is not a visual check. Compare before/after shots for visual changes.

Flags (all optional; implemented in `tools/capture.gd`):

| Flag | Effect |
|---|---|
| `--frames=F1,F2` | capture at these physics frames (60 = 1s). Default 120 |
| `--every=N` | also capture every N frames |
| `--snap=F` | snap the ball at frame F |
| `--do=F:ACTION,...` | `main.do_action({"a": ACTION})`, e.g. `snap`, `tackle`, `throw`, `cycle`, `team` |
| `--press=F:KEY[:HOLD],...` | real key event through `Input.parse_input_event` (so `_unhandled_key_input` and `Input.is_key_pressed` both see it), held HOLD frames (default 1). Key names: `Space`, `Tab`, `V`, `W`, `Shift`, `Enter`... |
| `--call=F:METHOD,...` | `main.call(METHOD)`, e.g. `next_play` |
| `--out=PREFIX` | writes `PREFIX_0060.png`. Default `$CLAUDE_JOB_DIR/tmp/shots/shot`, else `/tmp/crater-bowl-shots/shot` |

Env: `RES=1920x1080` (default 1280x720), `TIMEOUT=240`, `GODOT=/path/to/godot`.

Notes:
- Frames run at `--fixed-fps 60`, so frame N is the same game moment as frame N in
  `tests/game_flow.gd`. Shots are deterministic up to AI randomness.
- shot.sh passes `test_shot_*` profile/leaderboard/ranked/replay paths unless you override them,
  so screenshots never touch the player's real save data.
- `xvfb-run -a` picks a free display, so parallel sessions don't collide.
- llvmpipe is a software rasterizer. Use it to check *what is drawn*, not frame rate or GPU-only
  effects. Perf numbers have to come from the user's real GPU, so ask them.
- Don't put screenshots in the repo. Write them to the job tmp dir; if one belongs in a doc,
  describe it in words.

## Driving gameplay from scripts

When a fixture manually updates the scene after a play call, use `main._render()` to refresh
the route art and other render components through the normal hooks.

For anything you can assert (positions, phase, HUD text, whistle reason), add a game_flow segment
(`tests/flow/segments/<name>.gd`, contract in `tests/flow/segment.gd`) rather than eyeballing screenshots.
Each segment starts from a fresh match with main's test knobs reset and relative frames, so parallel PRs
don't edit the same lines of `tests/game_flow.gd`. `godot --headless --path . --fixed-fps 60 -s
res://tests/game_flow.gd -- --segment=<name>` runs one segment on its own in seconds. It runs headless in smoke.sh. Use shot.sh
when the question is visual: does it look right, is it visible, is the camera framing it, is the HUD
legible, does the new art read.

Input rule (from LOOP.md): player-facing input must be exercised through the real key handler.
In game_flow that's `_key()`; in shot.sh that's `--press`. Mouse motion goes through `_mouse(rel)`
(`main._unhandled_input`). Headless can't capture the mouse, so a step that needs mouse-look sets
`main.mouse_captured_override = true` and clears it after (the #139 taunt-wheel step does).
Mouse clicks on GUI controls are another exception: a headless viewport doesn't hit-test
`root.push_input` mouse events (#251), so game_flow emits the control's own `gui_input` (the #129
toss cards, `_click()`), and the hit-tested click lives in a `tests/visual` test under Xvfb
(`coin_toss_test.gd`).

Scripted contact: to make one body push another, place the pusher at a fixed overlap each frame
(e.g. 0.75 yd). Moving it a fixed step per frame lets it pass through the other body on the software-GL
path, so the push never happens (`tests/visual/forward_progress_test.gd`).

## When the user has to look

Only for things software rendering can't show: real-GPU frame rate, feel and timing, audio. In
that case say exactly what to run (`godot --path .`) and what to look for. Don't launch it yourself.
