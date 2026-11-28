# Performance: best practices for Crater Bowl

Read this before you touch anything that runs every frame or adds things to the 3D scene.
`docs/optimization/LOG.md` has the measurements behind every rule here. Add to it when you
measure something.

**Targets:** 60 fps steady on a mid-range GPU. Frame-time **p99** matters more than mean
FPS: a game at 70 fps that drops a 100 ms frame every few seconds feels worse than a steady 50.
The sim ticks at 60 Hz (`physics_ticks_per_second`) and the screen may run at any rate.

## 1. The frame model (know which loop you're in)

| Loop | Rate | What belongs here | Where |
|---|---|---|---|
| Sim tick | 60 Hz, fixed | rules, AI, physics, net snapshots: **deterministic** | `src/sim/*`, `main._step_authoritative` |
| View tick | 60 Hz, after the sim | copy sim state into view *targets*; change-driven work (markers, route art) | `main._render()`, `player.sync()` |
| Render frame | display rate (60/144/30…) | interpolate, camera, aim, animation, HUD animation | `main._render_frame()`, `_process` |

Rules:
- **Never move something visible only in `_physics_process`.** It updates at 60 Hz, so on a
  144 Hz screen (or after a slow frame that ran 2 ticks) it judders. Record a target per tick
  and draw between the last two in `_process`: `place()` / `interpolate(f)` with
  `f = Engine.get_physics_interpolation_fraction()`. See `src/game/player.gd` and `main._place_ball`.
  Never feed the drawn (interpolated) value back in as the next target: with f near 0 it
  flips sign every tick and never settles (#422). Smooth turns on the targets, per tick (#423).
  (Godot 4.3 has no built-in 3D physics interpolation; that arrived in 4.4.)
- Big jumps (new formation, replay seek, position swap) must **snap**, not glide: `TELEPORT_DIST`.
- Smoothing must be frame-rate independent: `lerp(a, b, 1.0 - exp(-k * delta))`, never
  `lerp(a, b, delta * k)`.
- Order: `main._process` runs before its children's `_process` (Godot processes parent first),
  so views are already interpolated when `player._process` derives animation from position
  deltas and when `presentation._process` pins the ball to a carrier's hand.

## 2. Rendering rules

The renderer's cost is roughly **draw calls x passes** plus **skinned vertices** plus
**pixels x effects**. Triangles are cheap on a GPU and expensive on a software rasterizer.

1. **No default-tessellation primitives.** `SphereMesh.new()` is 64x32 (about 4,000 triangles),
   and `TorusMesh` and `CapsuleMesh` are similar. Use `src/game/render_cache.gd` (`RC.sphere/capsule/
   cylinder/box/torus/ground_quad`), which is low-poly and shared. Pass more segments only for
   big, glossy, close-up shapes (the helmet uses 20x12). `scripts/lint.sh` enforces this in
   `player.gd`, which is instantiated once per athlete.
2. **Share resources.** The same mesh or material for the same look means one GPU resource and fewer
   state changes. `RC.mat(color)` caches by color. A material you *mutate per entity* (team
   colors) must be unique, but prefer shader `instance uniform`s if the renderer supports them.
3. **Shadow casters are expensive.** Each caster is drawn again per shadow split (up to 4).
   Turn `cast_shadow` off for: anything flat on the ground (field, lines, markers, decals),
   small parts inside a bigger caster's shadow (gear, numbers, trims), UI-ish 3D (reticle,
   arcs, rings), and transparent things. Today only athlete bodies, helmets, goalposts and big
   stadium pieces cast.
4. **Batch static geometry.** Many boxes with one material → one mesh (`SurfaceTool.append_from`
   or arrays). Many copies of one mesh → `MultiMeshInstance3D` (crowd: about 8k people in 2 draws).
5. **Rebuild dynamic meshes only on change.** `ImmediateMesh.clear_surfaces()` + rebuild
   re-uploads to the GPU. Key it on the inputs (`main._draw_routes` hashes route state) and
   skip when nothing changed or when it's already empty (`presentation` ball trail).
6. **Don't push unchanged shader parameters every frame.** `set_shader_parameter` dirties
   the material even when the value is equal (`stadium.set_excitement`, the ring color).
7. **Skinned meshes are the most expensive thing we draw.** Each rigged athlete is about
   13.7k triangles and is skinned every frame. On Godot 4.3's Compatibility renderer that's
   transform feedback, which Mesa's d3d12 layer (WSL) emulates very slowly: about 8 ms of
   render-thread CPU per athlete. Don't add skinned meshes casually, and don't add bones
   or vertices to the athlete without measuring. The render budget caps their count.
8. **Quality presets** live in `src/game/art/quality.gd` (`--gfx=low|medium|high`, auto `low`
   on software rasterizers). New expensive effects (shadow splits, MSAA, SSAO, glow, fog,
   crowd density) must be gated there, not always-on.

## 3. CPU rules (GDScript)

- Per-tick sim cost is about 0.15–0.3 ms for 7v7 with all bots. Keep `src/sim` engine-free and
  deterministic (lint rule 2): no nodes, no time, no randomness. `tests/test_determinism.gd`
  checks bit-identical state across two runs.
- **Throttle text.** Rebuilding label strings and layouts every frame is surprisingly costly
  (about 1 ms/frame for the scorebug before `overlay.gd` moved to `TEXT_HZ = 20`). Animate per
  frame, re-text at 10–20 Hz. `Label.text = same_string` is already a no-op, but the string
  formatting that builds it is not.
- No allocation churn per frame: no `.new()` of nodes, meshes or materials in `_process`, and no
  `duplicate()` of big arrays per tick. `perf.sh` fails on object growth that repeats across two
  600-frame windows (after a 1200-frame warm-up; see the budget table).
- No `print()` in per-frame paths (stdout is flushed on every print: `run/flush_stdout_on_print`).
- Avoid O(n²) over athletes in per-tick code unless n ≤ 14 and it's measured. AI is the
  usual suspect; `tools/bench.gd` times each stage.

## 4. Budgets (enforced by `./scripts/perf.sh`)

| Budget | Limit | Measured (2026-11-25) | Where |
|---|---|---|---|
| Scene triangles (7v7) | 320k | about 255k (14 athletes = 192k) | `tests/render_budget.gd` |
| Visible geometry instances | 300 | about 248 | same |
| Shadow casters | 106 | 85 (was 162 before gear shadows went off; 125 after the chain crew landed) | same |
| Distinct materials | 170 | about 137 | same |
| Skinned meshes | 14 | 14 | same |
| Sim tick p50 (7v7 bots) | 800 µs | 130–320 µs | `tools/bench.gd` |
| Scene tick p50 (headless, whole frame) | 8 ms | 2.5–4 ms | same |
| Object growth (min of two 600-frame windows after a 1200-frame warm-up, coin toss pinned; first-use allocations excluded) | 50 | 5 (a planted per-frame leak reads 605, a planted 30-node-per-snap leak 69) | same |

The object-growth scenario is fixed: `tools/bench.gd` pins the opening coin toss (`--toss`,
default 1), so the same plays and the same first-use allocations happen on every run. The
first half of the run is warm-up because the game builds some UI lazily and keeps it: the replay
hint bar (about 107 objects, first replay) and the play-picker buttons (about 52, first time the
picker shows). Those are bounded; an 8000-frame run plateaus at the same object count. When the
gate fails it prints both windows and the node classes that grew in each.

The render budgets are counts, not timings. They're identical on every machine, so they never
flake. That holds only for a fixed scene: `tests/render_budget.gd` pins the coin toss
(`toss_seed = 1`), as `tools/bench.gd` does, because the two outcomes differ by one instance and
one material (#180). The CPU budgets use medians at about 3–5x the measured cost, so a busy machine doesn't
fail them but an order-of-magnitude regression does.

**Ratchet rule:** when you make something cheaper, lower the budget to about 1.25x the new
number in the same commit. Raise a budget only with a LOG.md entry saying what got more
expensive and why it's worth it.

## 5. Measuring

| Question | Tool |
|---|---|
| Did I regress anything? | `./scripts/perf.sh` (headless, about 30 s, also in `check.sh --fast` and the pre-commit hook) |
| How fast is it really drawing? | `./scripts/render_bench.sh` (Xvfb, real renderer, prints FPS, p50/p99 frame time, draw calls, triangles, render CPU/GPU ms) |
| ...on the real GPU (WSL) | `GPU=1 ./scripts/render_bench.sh` (Mesa d3d12 → the NVIDIA GPU) |
| ...with the Vulkan Forward+ path | `RENDERER=forward_plus ./scripts/render_bench.sh` |
| What does each part of the scene cost to draw? | `./scripts/render_bench.sh --exp=chars` (hides a category: `chars,gear,labels,crowd,stadium,anim`) and compare |
| Where are the triangles and shadow casters? | `tools/render_breakdown.gd` (command in its header) |
| What does each subsystem cost on the CPU? | `tools/cpu_breakdown.gd --exp=anim|views|pres|skel|stadium` |
| Sim stage timings | `godot --headless --fixed-fps 60 --path . -s res://tools/bench.gd -- --only=sim` |

**Before/after protocol** (anything you claim as a perf win):
1. Make a detached worktree of the base: `git worktree add --detach /tmp/base origin/main`
   and copy any new bench tools into it.
2. Run base and change **back to back, same mode, 3 runs each, interleaved**. Report the
   median, plus p99 frame time.
3. Check `uptime`. Five sessions share this machine. At load average above about 4, CPU timings
   inflate 2x and swing ±30%. Interleaving cancels most of it; absolute numbers don't.
4. Write the table into `docs/optimization/LOG.md`.

Never open a game window to "see if it's smoother" (see `docs/TESTING.md`). Only the user can
judge feel on real hardware. Ask them, and tell them exactly what to run.

## 6. The machine we develop on (WSL2) is not where players play

| How it runs | Renderer actually used | 7v7 FPS (2026-11-25, rigged-athlete art) |
|---|---|---|
| `godot --path .` in WSL (default Forward+) | Vulkan on **llvmpipe** (CPU) | about 2–5 |
| `GALLIUM_DRIVER=d3d12 godot --path . --rendering-driver opengl3` | GL Compatibility → D3D12 → RTX 3080 | about 10 (skinning-bound), 61 before rigged athletes |
| Native Windows build (`scripts/export.sh`) | Vulkan on the real GPU | not measured yet. Ask the user to run it |

WSL has no Vulkan driver for the real GPU (no `dzn` ICD), so Vulkan falls back to the CPU.
Numbers from this box show **relative** wins and regressions, not player experience. For
"does it feel smooth", the user runs a native Windows build.
