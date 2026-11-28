# Offense

Feature-level doc: how this works for players **today** on `main`. Design/implementation detail: [architecture](../design/architecture.md). Open work: GitHub issues labelled `area:offense` (listed below).

## Summary
The offense calls one of six pass plays (plus two runs when a running back is on the field) from a pre-snap
picker, snaps with Space, and either throws to a mouse-aimed spot on the turf or hands off to the back.
Passes fly on a solved ballistic arc. Catches are automatic within a reach volume and are contested by
defenders. Line play is in [line-play.md](line-play.md); scoring, tries and turnovers are in [rules.md](rules.md).

## How it plays

### Play calling (pre-snap)
- The picker opens at the start of every play. **Q** toggles it; the mouse is free pre-snap, so you click a call.
- Offense buttons: Verticals, Slants, Mesh, Curls, Flood, Deep Shot, plus Inside Zone and Outside Sweep when the
  formation has an RB and the mode is classic (5v5 and 7v7). Also **Repeat last** (recall your team's previous call)
  and **Flip play** (swap the two WRs' routes; on a run, mirror the lane).
- The offense's QB can choose **Balanced** or **Twins Right** before a Classic scrimmage snap in 3v3, 5v5 and
  7v7. Twins Right puts both wideouts on the right and updates team route art while the called routes stay with
  their players. Each down begins Balanced. The formation picker is hidden on kick plays and in Chaosball.
- To audible, select another play before the snap. The highlighted card and the offense's route art
  follow the new call. Teammates see the same assignments, and the call locks when the ball is
  snapped (#346).
- An eligible receiver (WR or RB, not QB) gets a route dropdown to override their own route on a pass play.
- Each new formation pre-selects a default: Slants on 3 or fewer yards to go, Deep Shot on 15+ to go with 25+ yards to
  the goal, otherwise Mesh (`match.gd _setup_formation`).
- **Space** (gamepad A) snaps. The 20 s play clock (`Clock.PLAY_CLOCK`) auto-snaps if nobody does.
- Bot-only offenses pick their own call (`ai.choose_play`, about one run in three on early downs when an RB exists) and
  snap after `AI_SNAP_DELAY` (2.5 s), or `HUDDLE_SECONDS` (5.0 s) when any human is in a classic match. The scorebug's
  play clock counts that huddle down and the snap comes at 0 (#136).
- Your team's pre-snap turf art shows every route, the RB's run path and each lineman's target; yours is highlighted.
  The defense never sees it.

| Play | Left WR | Right WR | RB |
|---|---|---|---|
| Verticals | GO | GO | WHEEL |
| Slants | SLANT | SLANT | FLAT |
| Mesh | IN | IN | CURL |
| Curls | CURL | CURL | FLAT |
| Flood | CORNER | OUT | FLAT |
| Deep Shot | POST | GO | CURL |

Routes are waypoint offsets mirrored toward the field center (`routes.gd ROUTES`). Bot receivers follow them, then keep
the last segment's direction; comeback routes (CURL) settle instead of backpedaling.

### Snap
- With a center, the ball flies C to QB in `SNAP_TIME` (0.35 s). In 3v3 there is no center: the QB starts with the
  ball and the snap is instant.

### Passing
- **QB (POV aim):** while you're the passer the camera goes over your shoulder and the mouse (gamepad right stick)
  aims. Where you look is the direction, looking up or down sets the launch angle, and holding the throw
  (left click / **J**, gamepad RT) charges the speed from `THROW_SPEED_MIN` to `THROW_SPEED_MAX` (12 to 30 yd/s) over
  `THROW_CHARGE_TIME` (0.9 s). Release throws. Keys and numbers: [CONTROLS.md "QB POV aiming"](../CONTROLS.md#qb-pov-aiming).
- **Aim-zoom (#109):** while you hold the throw the camera FOV narrows with the charge, from 65° to 45° at full power,
  so the longest throws zoom in furthest. It eases (`1 - exp(-8·dt)`) and returns to 65° on release
  (`main.gd aim_zoom_fov`, `AIM_ZOOM_FOV`).
- A ground reticle and a 24-dot arc preview show where the ball will come down while you can throw.
- Once a pass is in flight, eligible receivers and defenders see a ground marker at the predicted landing point
  (#108). The thrower sees the pre-throw preview. A private-lobby host can toggle the in-flight pass marker.
- **Other carriers** (an RB behind the line after a handoff) use the orbit camera: mouse X orbits, mouse Y sets the aim
  distance (2 to 65 yd). Left click / **J** throws on press at a fixed `PLAYER_PASS_POWER` (0.68, about 24 yd/s); the
  solver picks the flattest angle that crosses the aim point at `CATCH_HEIGHT` (1.1 yd). Hold **Ctrl** (gamepad RB) for
  a lob: a fixed `LOB_ANGLE` (65°) arc with the speed solved to land on the target.
- In Classic, you can throw while you hold the ball in live play, at or behind the line of scrimmage, before the ball
  has been carried across the line or a forward pass has been thrown. Diving, being grounded, jumping, or a dash or
  spin in progress also prevents the throw. An RB can throw after a handoff while those conditions hold.
- A ball that hits the ground is incomplete.

### Catching
- Automatic. Candidates are eligible players within `CATCH_RADIUS` (1.2 yd) while the ball is between
  `CATCH_MIN_HEIGHT` and `CATCH_MAX_HEIGHT` (0.3 to 2.6 yd). C and OL are ineligible; the thrower can't catch his own pass.
- The ball can't be caught or touched for its first `MIN_PASS_TRAVEL` (2.5 yd).
- Defenders can contest from `CONTEST_MARGIN` (0.35 yd) further away. Beyond the short-tip window, a contested
  ball keeps flying while it closes on the nearer athlete. A receiver who beats the
  defender by more than the margin completes the catch. A defender who wins by that margin and gets inside
  `INT_RADIUS` can intercept. A tight contest or a defensive touch outside interception reach is a breakup (#339).
- In Classic, when a defender wins the contact within `BATTED_PASS_MAX_TRAVEL` (5 yd horizontally from release),
  the pass is batted incomplete. The offense spends the down at the original line of scrimmage.
- Beyond that window, a lone defender intercepts only within `INT_RADIUS` (0.6 yd) at the ball's closest approach;
  otherwise it is a breakup.
- Sideline catches use the receiver's ground position at contact (#338). The ball can be beyond the line
  while an in-bounds receiver completes the catch. A receiver standing outside the boundary is incomplete.
  A defender standing outside cannot complete an interception.
- During an active Classic dive, an athlete reaching for a nearby pass keeps the dive clip's legs.
  The chest rolls about the spine to face the ball (up to 50°) and the spine bends toward it (up to
  30°), and the near arm reaches for the ball where it is, measured from the athlete's heading (a
  lying chest faces anywhere). The arms use the standing reach's shoulder and elbow limits. A
  standing reach that becomes a dive blends between the two, and the arms blend into the carry
  after the catch (#360). Replays use the recorded dive and catch flags, so they show the same.
- Control stays on your own athlete after a catch or handoff. Bots run with the ball when they have it.

### Run game
- **G** (gamepad R3) hands off. Requires: live play, you are the QB holding the ball at or behind the LOS, no forward
  pass yet, and the RB is standing within `HANDOFF_REACH` (1.6 yd) and behind the LOS. `HANDOFF_COOLDOWN` is 0.8 s.
  The handoff itself works on any call, not only run plays.
- On a run call the status line shows **MEET THE BACK** while you hold the ball and the RB is out of reach.
- A bot QB hands off within `AI_HANDOFF_WINDOW` (1.5 s); a bot RB comes to the QB, then follows the called lane.
- Inside Zone hits an interior gap; Outside Sweep goes wide. Bots flip the sweep automatically.

## Design decisions
- The formation picker changes receiver alignment independently of the play call (#345). Balanced reuses the
  original home spots. Twins Right scales both receiver marks to field width and keeps their depth and role.
  Online players see the host's alignment through the existing athlete positions.

- **Crossing the line commits to the run (#312).** The same down-level flag lifts the blocking zone and closes the
  first-person passing view and aim preview. Retreating behind the line keeps the play live as a run. Disabling the
  throw at the input and sim gates gives the runner immediate feedback and avoids a separate penalty ruling.
- The snap is a short visible flight, not a teleport, so its timing is readable.
- Aim point plus solved arc over homing passes or golf-style angle/power. The aim arc previews the throw. The
  in-flight marker calls the same ballistic time-to-height helper with the live ball's position and velocity.
- Charged power was removed in the live-controls rework, then came back for the QB with Gridiron-style POV aiming:
  look sets direction and height, the hold sets distance. Non-QB carriers still throw on press at fixed power.
  POV throws add `THROW_INHERIT` (30%) of the QB's velocity (`world.gd throw_dir`); target-aimed player and bot
  throws pass `inherit_motion = false`, so they don't drift.
- Aim-zoom follows the charge rather than a separate zoom button (Gridiron zooms on right click; right click is
  block here). Charge is distance, so the zoom is tightest exactly when the target is far away. A fixed zoom on any
  hold would have hidden the near field on short, quick throws.
- Reach-volume catching over physics collision: deterministic and server friendly. A catch button is #9.
- The contest waits for the nearest athlete's best contact sample. That gives a receiver or defender who lined
  up with the pass a chance to beat the contest margin before an ordinary-reach breakup is called (#339).
- The first 2.5 yd give the passer room to release in traffic. From there through 5 yd a reachable defensive
  touch can end the down as a breakup (#337). A clean defensive catch farther downfield can still be picked off.
- Linear receiver lead threw curls and outs to empty grass; bots lead along the route path.
- Route art is shown to your own team only, so the QB can read a human receiver's route override without voice chat.
- Proximity handoff key over an automatic exchange (takes the timing choice away from a human QB) or a timing meter
  (a second timing task on a quick snap).
- Older key bindings (Q cycles plays, F cycles routes, L/X/Y for recall/flip/default) were replaced by the
  clickable picker; F is now spin.

## Code and tests
- `src/sim/routes.gd` — route library, playbook, run lanes.
- `src/sim/passing.gd` — ballistic solver, lob solver, lead prediction.
- `src/sim/world.gd` — `call_play`, `set_route`, `flip_play`, `recall_call`, `snap`, `throw`, `handoff`, `_try_catch`.
- `src/sim/match.gd` — default call per formation. `src/sim/ai.gd` — bot QB reads, routes, play choice, handoffs.
- `src/game/main.gd` — aim, reticle and arc, route art, key handling. `src/game/overlay.gd` — picker, route dropdown, status.
- `src/net/protocol.gd` — host-validated `play`, `route`, `flip_play`, `recall_call`, `throw`, `handoff` actions.
- Tests: `tests/test_passing.gd`, `tests/test_catching.gd`, `tests/test_routes.gd`, `tests/test_run_game.gd`,
  `tests/test_turnovers.gd` (interceptions), `tests/test_bots.gd`, `tests/game_flow.gd` (real J/Q/G/Space keys).

## Open issues
- #9 C07 Catch rules: reach input (#247) and jump catches (#361)
- #10 C09 Offense depth: formations, audibles, hot routes, pre-snap motion
- #11 C10 Throw readability: landing marker, aim-zoom (aim-zoom shipped as #109)
