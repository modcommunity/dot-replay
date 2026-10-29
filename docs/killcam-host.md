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

## Hooks

| Hook | Default | For |
| --- | --- | --- |
| `players_fn`, `player_for_fn` | none | the players to record, a player for an id |
| `id_of_fn` | `p.player_id` | the id a row is stored under (int or StringName; set `no_id` to `&""` for names) |
| `state_fn` | none | the drawn state of a body |
| `place_body_fn`, `restore_body_fn` | none | pose a body, put it back; `touched` is the dictionary to save into, once, before the first change |
| `can_play_fn` | always | refuse a replay (a suicide) |
| `camera_mode_fn`, `world_mask` | behind, layer 1 | `DotKillViewRules.Camera` and the boom's mask |
| `camera_cull_extra` | 0 | layers the camera also draws (a local body's layer) |
| `weapon_name_fn`, `weapon_icon_fn`, `hide_while_playing`, `seconds_fn`, `now_fn` | see the script | banner, HUD hiding, length, a test clock |

`pose_at`, `restore_bodies`, `world_mask` and `buffer` are also what `DotKillViewClient.stage` expects, so the host is the kill view's stage as it stands.
