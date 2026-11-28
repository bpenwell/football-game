# Progression

Feature-level doc: how this works for players **today** on `main`. Open work: GitHub issues labelled `area:progression` (listed below).

## Summary
Finished matches feed local career leaderboards, XP, levels and achievements. Competitive-queue matches also count toward team Elo ratings with tiers and quarterly seasons.
Progress is stored in JSON files on each player's own machine. Ratings use a random per-install ID, career tables use display names, and match awards follow each player's own participation.

## How it plays

### Where it shows
| Place | What |
|---|---|
| Final whistle (text HUD) | match summary lines, `YOUR RANKS: QB #1, …`, `RATING 1024 Silver (1-0) (+24)`, `XP +182 (Level 1 - LEVEL UP!)`, `ACHIEVEMENTS: …` |
| Menu after a match ("overview") | result, players of the game, team box score, your line, XP/rating/ranks, Watch replay |
| Top bar profile chip + home level ring | `LV n · <rating label>`, XP progress to next level |
| Locker room tab | level, XP, equip cosmetics and jersey number |
| Leaderboard tab | your ranked label, per-position career table (top 20 shown, 100 kept) |
| Home news card | `RANKED SEASON <year> · Q<n>` |

### Stats (`src/sim/stats.gd`)
- Career lines are keyed `name|POSITION`. When a player fills multiple positions, each position gets its own career line. Bots are recorded as `Bot` and excluded from leaderboards and XP.
- Fields: passing att/comp/yds/TD/INT thrown, receptions/yds/TD, carries/rush yds/TD, tackles, sacks, INTs, PBUs, forced and recovered fumbles, INT return yards, fumble return yards, points, block engagements, defensive TDs, best Chaosball TD value, kick/punt return TDs, and kicking (#67): field goals made/attempted and long, PATs made/attempted (XP), punts and gross punt yards, kick returns and yards, punt returns and yards.
- A sack is a QB tackled behind the LOS before he throws. Kickoff and punt return touchdowns go in the return TD field (`ret_td`) and appear as **RET TD** on Players of the Game cards. Scrimmage takeaway touchdowns go in `def_td`.
- Scrimmage yards are measured from the snap LOS. Takeaway return yards (#100) run from the takeaway spot (the interception's catch point, or where the recovering player stood) to the dead-ball spot, measured toward the returner's scoring end zone, so a returner driven back gets negative yards. A return touchdown is credited to the goal line, not to where he stopped in the end zone. A return ends at a fumble or a throw (Chaosball swings), and a re-recovery by the other team starts its own return. Own-team recoveries aren't takeaways and get no return yards. Kick and punt returns (#67) use the same return rules from the spot the returner fields the ball (`kr`/`kr_yds` on kickoffs, `pr`/`pr_yds` on punts); a ball fielded in the end zone is a touchback, not a return.
- A receiver's fumble records passing and receiving yards from the snap line to the fumble spot (#355). The thrower and catcher keep those yards through either team's recovery, and a later whistle cannot add them again.
- Kicking (#67): every field-goal kick counts an attempt when it leaves the foot, so a blocked kick is a miss. A make adds `fg_made` and, if longer, sets `fg_long` (kick spot to the posts, rounded, the NFL convention). A kick on a 1-point try is a PAT (`xp_made`/`xp_att`), not a field goal; Stats tells them apart from the Match it is attached with. Punt yards are gross: LOS to where the punt is fielded, rolls dead or goes out, to the goal line on a touchback, and 0 for a blocked punt. The kicker is whoever kicked, usually the QB (`world.kicker()`), so kicking stats live on that position line.
- `fg_long` and `max_td_pts` are best-of fields (`Stats.MAX_FIELDS`): match lines, achievement contexts and career leaderboard lines keep the max instead of summing (#171).
- Return yards show in the post-game stat lines: the FINAL screen and the overview's "Your game" (`34yd int ret`, `12yd fum ret`) and the players-of-the-game cards (`34 INT RET YDS`, `12 FUM RET YDS`). A zero-yard return shows nothing.
- "Your game" lists only your own lines (#200). They're keyed by your player id, not your display name, so two players both named Ann never see each other's lines, and two Anns at one position each keep a separate line. The FINAL screen's summary and the career table stay keyed by name.
- Kicking shows the same way (#67): "Your game" gets `2/3 FG long 47, 1/1 XP, 4 punt 43.5 avg, 2 kick ret 51yd, 1 punt ret 8yd` (parts only when non-zero), and the cards show `2/3 FG  LONG 47`, `51 KR YDS`, `8 PR YDS`. The team stats grid is unchanged.

### Leaderboard (`src/sim/leaderboard.gd`)
| Position | Score |
|---|---|
| QB | pass yds + 20·pass TD − 25·INT thrown + rush yds + 20·rush TD |
| WR | rec yds + 20·rec TD + 2·rec |
| RB | rush yds + rec yds + 20·(rush TD + rec TD) |
| C / OL | 2·blocks + 5·games |
| defense (LB/CB/S/DL) | 10·tkl + 25·sack + 40·INT + 10·PBU + 25·FF + 25·FR |

- Ties rank the player with fewer games first. Linemen rank on block engagements so they get a real leaderboard.
- Only the host (or the offline player) records the match. Online clients never update their own leaderboard file.

### Ranked (`src/sim/ranked.gd`)
- Rated matches: competitive queue only (menu **Ranked**, any size, classic or Chaosball; one shared rating). Private and casual matches are unrated.
- Team Elo on average team rating; start 1000; K = 48 for your first 10 games of a season, then 32; ties count 0.5.
- Tiers: Bronze < 1100 ≤ Silver < 1300 ≤ Gold < 1500 ≤ Platinum < 1700 ≤ Diamond < 1900 ≤ Legend.
- Seasons are calendar quarters (id = year·4 + quarter). On the first ranked result of a new season, each player who played gets badge `S<id>-<peak tier>`, ratings soft-reset halfway to 1000, and games/wins reset.
- The host computes and saves every player's new rating in **its own** `ranked.json` and broadcasts the deltas. Clients see their delta but don't save it, so their locker label and queue rating stay at their own file's value.
- Ratings are keyed by **install id** (`id:<hex>`), not display name (#102), so two players both named Ann each keep their own rating, games and wins. Each record also stores the last display name it played under. A rating saved before #102 (keyed by name) moves to the first install id that plays a ranked match under that name; a second same-named player starts at 1000. A peer from an older build that sends no install id is still keyed by its name.

### XP and levels (`src/sim/cosmetics.gd`)
- Per match: 100 + 50 for a win + 25 per TD + 1 per 10 yards (pass + rec + rush) + 10/tackle + 30/INT + 20/sack, plus achievement bonus XP.
- 500 XP per level; you start at level 0. Offline vs-bots matches count; practice and training don't.
- The host sends XP and achievement context for each occupied seat. Two players with the same display name earn awards based on their own plays and team result (#156).

### Cosmetics (Locker room)
| Slot | Unlocks (level) |
|---|---|
| Trim | Chalk 0, Ink 0, Ember 1, Tide 2, Volt 4, Aurora 8 |
| Helmet | Plain 0, Gold Stripe 2, Crimson Stripe 3, Chrome 6 |
| Celebration (plays on your TD; Moon Hop bounces with a fist pump, #455) | None 0, Spin 1, Moon Hop 3, Flip 5 |
| Number | 0–99 |
| Badge | season rewards from ranked |
- Locked items are listed as `Name (level N)`, disabled. The host sanitizes each look and echoes it to everyone. Looks never enter the sim.
- Trim colours the jersey band and numbers; helmet sets the stripe. Badges can be equipped but are not drawn on the athlete.

### Achievements (`src/sim/achievements.gd`)
| Achievement | Condition (one match unless noted) | XP |
|---|---|---|
| First Touchdown | any TD, including kickoff and punt returns | 100 |
| First Win | win | 100 |
| Gunslinger | 300+ pass yds | 250 |
| Sure Hands | 8+ catches | 200 |
| Workhorse | 100+ rush yds | 200 |
| Sack Artist | 3+ sacks | 200 |
| Lockdown | 2+ INTs | 250 |
| Pick Six | defensive TD | 300 |
| Perfect Chaos | 7-point Chaosball TD | 300 |
| Comeback Kids | win after trailing by 14+ | 300 |
| Going for Gold | ranked rating ≥ 1300 after a ranked match | 300 |
| Iron Man | 10 matches played (career) | 200 |

### Where data lives
User data dir `crater-bowl` (see [out-of-game.md](out-of-game.md)). Tests pass the `--*-file` flags so they never touch real files.
| File | Contents | Flag |
|---|---|---|
| `user://profile.json` | XP, equipped look, season badges, achievements, games played, install id | `--profile-file` |
| `user://leaderboard.json` | career lines per `name|POS` | `--leaderboard-file` |
| `user://ranked.json` | season, per-player (install id) rating/peak/games/wins/name, rewards | `--ranked-file` |
| `user://replays/*.replay` | every finished match | `--replay-dir` |
| `user://training.json` | training personal bests ([training.md](training.md)) | `--training-file` |

## Design decisions
- **Pure rules, JSON stores.** Stats, scoring, Elo, XP and achievements are pure `src/sim` code with unit tests. Persistence is a plain file per concern.
- **Local files over an online service.** A service needs accounts and anti-cheat; for a friend group the host is the league office.
- **Host is the authority for the match result.** Clients trust the host's XP and achievement context. That's fine among friends but not tamper-proof, and names aren't authenticated (#28).
- **Match awards follow the player in the seat (#156).** Stats for awards are credited to the player who controls the athlete when the play event occurs. Pass completions, yards, touchdowns and interceptions are credited to the player who threw the ball (#202). The same rule covers every result that lands after the action that earned it (#276): a field goal or PAT make, `fg_long` and punt yards go to whoever kicked; receiving yards, the receiving TD and its points go to whoever caught the ball; kick, punt, interception and fumble return yards, and a return TD with its points, go to whoever fielded the kick or made the takeaway. A rushing carry, its yards and any touchdown with its points go to the QB's owner at the snap for a keeper or to the back's owner at the handoff (#293). A fumbled handoff or a keeper fumbled beyond the line of scrimmage counts once, with yards measured to the fumble even if the defense recovers (#323). Crediting the fumble spot preserves the runner’s gain when possession changes before the whistle. Stats records the owner's line key and player ID when each action starts and uses those values when the result arrives. A carry, run after the catch or return has one yardage total, so the player who started it keeps the whole result. A replacement earns credit on the next action they start. A player who takes over a seat starts with their own totals. At the final whistle, the host uses each player's seated athlete ID to deliver the award.
- **"Your game" follows match identity, not the display name (#200).** It used to pick the shared `name POS: …` summary lines that began with your name. Two Anns then saw each other's lines, and two Anns at one position shared one merged line. `Stats` now also keeps lines by player id and position (`player_lines`, credited like the #156 award stats). The host reads its own lines by player id. Clients get theirs from the `summary` event's `mine` map, keyed by athlete id like `awards`. The career table keeps the `name|POS` key. Moving it to identity is a format change that loses every saved table, and the leaderboard is meant to show names. Rejected: making names unique in the lobby (`Ann (2)`). That changes what players typed and doesn't help an older build's career table.
- **Ratings keyed by install id, kept on the host (#102).** Display names aren't unique, so the host keys each rating by a 16-hex-char id the player's install mints once (`main.gd:install_id()`, saved in `profile.json` with the first ranked result). The host keeps peers' ids in a private map and never broadcasts them: the `ranked` event is keyed by athlete id, so nobody can read another player's id and claim their rating. It isn't authentication. A tampered client can still send any id it likes (#28).
- **No pay-to-win:** cosmetics are view-only and checked by a determinism test (identical worlds regardless of looks).
- **Original achievement set** (12 milestones), not copied from any other game.
- **Kick return touchdowns have their own category (#172).** A return TD counts once in the team's touchdown total and carries the same player-card weight as a defensive TD. It can earn **SPECIAL TEAMS STANDOUT** and qualifies for First Touchdown.
- **Return yards are their own fields** (`int_ret_yds`, `fr_ret_yds`), not added to rush yards. Folding them into rushing would inflate RB/QB rushing lines and the scrimmage-yard totals that players-of-the-game and the box score compare. Players of the game weight them like scrimmage yards (0.1 per yard) under DEFENSIVE STANDOUT. The leaderboard score and team box score leave them out for now, so career tables from before #100 stay comparable.
- **Kicking in players of the game (#67):** a made field goal weighs 3.0 (its points, on the same scale as a TD at ~6), kick and punt return yards 0.04 per yard (fantasy return-yard scoring, a fraction of scrimmage yards because a kickoff return of 20+ yards is routine), under the SPECIAL TEAMS STANDOUT category (shared with return TDs, #172). Punts and PATs carry no weight: a punter or a PAT shouldn't outrank a scorer. Rejected: folding kicking into the QB's passing category (the card would call a kicker a TOP PASSER). Kicking stays out of the leaderboard score, XP and the team grid (#115 owns that grid).
- Not done: cross-machine ratings and leaderboards. Each machine's tables only contain matches it hosted or played offline.

## Code and tests
- `src/sim/stats.gd`: stat lines; `src/sim/potg.gd`: players of the game and team totals.
- `src/sim/leaderboard.gd`, `src/sim/ranked.gd`, `src/sim/cosmetics.gd`, `src/sim/achievements.gd`.
- `src/game/main.gd` (`_on_match_event` "final", `_record_leaderboard`, `_record_ranked`, `_match_awards`, `_apply_award`).
- `src/ui/main_menu.gd` (`_screen_locker`, `_screen_leaders`, profile chip), `src/ui/game_overview.gd`.
- Tests: `tests/test_stats.gd`, `tests/test_leaderboard.gd`, `tests/test_ranked.gd`, `tests/test_cosmetics.gd`, `tests/test_achievements.gd`, `tests/test_potg.gd`, `tests/game_flow.gd` (final records files, HUD rank/rating/XP lines), `tests/net_client.gd` (looks, same-name awards and "Your game"), `tests/visual/same_name_overview_test.gd` (#200), `scripts/mm_test.sh` `MODE=competitive`.

## Open issues
- #8 C06 Spotting: forward progress, return yards, fumble variety
- #28 C22 Trustworthy progression
- #29 C23 New-player protection
- #30 C24 Match history and profile
- #37 B05 Friend-group seasons + persistent stats
- #41 C26 Archetypes (one passive each)
- #172 Kick and punt return touchdowns are credited as defensive TDs
