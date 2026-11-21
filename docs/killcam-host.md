# DotKillcamHost

The final killcam a game plays at the match's end, from what the client already drew (no new traffic). It wraps `DotKillcamBuffer` and `DotKillcam`, and was a ~250-line fork in each game; what differs between games is a hook.

## Wiring

```gdscript
var host := DotKillcamHost.new()
host.skip_actions = ["dot_fps_jump", "ui_cancel"]
host.skip_hint = "Jump to skip"
host.players_fn = func() -> Array: return game.players()
host.player_for_fn = func(id: Variant) -> Variant: return game.player_for(id)
host.state_fn = _state_of          # player -> [feet, yaw, pitch, alive, eye height] as drawn
host.place_body_fn = _place_body   # (player, feet, yaw, shown, pitch, speed, touched)
host.restore_body_fn = _restore    # (player, touched[player])
host.seconds_fn = func() -> float: return game.rule("killcam")
host.over.connect(_go_to_scoreboard)
add_child(host)
```

Call `host.frame()` once a frame after the bodies are presented, `host.note_kill(killer, victim, weapon)` for every kill, `host.match_ended()` at the end (false means `over` has already fired).

While a replay runs, `frame()` (or `repose()` on a frame that does not record) redraws the last pose over what presentation drew. When the replay's own `frame_drawn` posed the bodies after that call on the previous frame (the host's killcam, or a kill view whose `stage` is this host, processing after the caller), the redraw is skipped: it would be drawn over again in the same frame.

## Hooks

| Hook | Default | For |
| --- | --- | --- |
| `players_fn`, `player_for_fn` | none | the players to record, a player for an id |
| `id_of_fn` | `p.player_id` | the id a row is stored under (int or StringName; set `no_id` to `&""` for names) |
| `state_fn` | none | the drawn state of a body |
| `place_body_fn`, `restore_body_fn` | none | pose a body, put it back; `touched` is the dictionary to save into, once, before the first change |
| `pose_fn`, `apply_pose_fn` | unset | record each body's skeleton pose (`DotHumanoidFigure.pose_record`) and draw it back (`pose_apply(a, b, alpha)`) on every shown body; see below |
| `pose_unchanged_fn` | unset | `(player) -> bool`: true when the body has changed no bone since `pose_fn` last read it, so that pose is kept again without a read; see below |
| `event_fn` | unset | `(player, row a, row b, alpha, is_victim)` for every body each replayed frame after it is placed: the recorded rows either side of the moment (state_fn's `[feet, yaw, pitch, alive, eye height] + aux`), so a game can play what they say happened, a shot by the aux's fire counter or a death by `alive` turning false (API level 8) |
| `can_play_fn` | always | refuse a replay (a suicide) |
| `camera_mode_fn`, `world_mask` | the killer's eye, layer 1 | `DotKillViewRules.Camera` and the boom's mask |
| `present_fn` | unset | `(view: Dictionary)` each frame with `{camera, aux, fov, behind}` and `{}` at the end: draw the killer's viewmodel and HUD |
| `camera_cull_extra` | 0 | layers the camera also draws (a local body's layer) |
| `weapon_name_fn`, `weapon_icon_fn`, `hide_while_playing`, `seconds_fn`, `now_fn` | see the script | banner, HUD hiding, length, a test clock |
| `rules` | null | a `DotKillViewRules`: `mp_killview_final` 0 skips the final killcam, `mp_killview_skip_grace` ignores skip keys for the first seconds |

## Bodies in their recorded pose

`place_body_fn` alone gets a position, a yaw, a pitch and a speed, and a figure animated from those inside a replay frame plays a clip that has had no time to blend in: the rest pose (a T-pose). With `pose_fn` set the host keeps every body's pose in `poses`, a second buffer on the same clock, at `mp_killview_pose_hz` (`rules.pose_hz`, or `pose_hz` without rules; default 30, 0 keeps none), and calls `apply_pose_fn` after `place_body_fn` for each shown body with the two poses around the replayed moment. A GameSpice Player Char person is 812 bytes a pose: 24 KB a second per body at 30 Hz, 8 s of 16 players about 3 MB, held on the client only and never sent.

Reading a pose is one engine call per bone (Godot has no bulk getter), about 43 a person, and that is most of what recording costs. A figure under an animation LOD step (dot-player-char's `anim_step`: 2, 4 or 8 for a far, offscreen or unseen body) changes no bone on the frames it skips, so a game can set `pose_unchanged_fn` to say so and the host keeps the pose it read last (a PackedFloat32Array is shared, not copied). The host never decides this itself: without the hook every body is read at every pose. `poses_read` and `poses_kept` count both, and `describe_lines` reports them while the hook is set.

`pose_at`, `restore_bodies`, `world_mask` and `buffer` are also what `DotKillViewClient.stage` expects, so the host is the kill view's stage as it stands.
