# The kill view

When a player dies they see the replay of their killer's view (camera, fov and crosshair), then the respawn flow resumes. Reuses `DotKillcam` (clock, slow-motion, banner, skip) and `DotKillcamBuffer`; the new parts only record and carry the killer's view. It is a different thing from the killcam of what a client already drew: the victim never drew the killer's eyes, so the server records them.

## The hook a game wires in

Server (no autoloads; the game owns the objects):

1. `var rules := DotKillViewRules.new()`, `rules.bind_cvars(module.add_cvar, DotConVar.FLAG_REPLICATED)` (cvars below). A client calls `rules.follow_cvars(client_link)`.
2. `var kv := DotKillViewServer.new(rules)`, `kv.tick_rate = ...`, and assign `kv.eyes_fn`: `() -> [{id, transform, fov?, cursor?}]`, every living player's and bot's eye (`crosshair` 0..1 in the killer's viewport). With dot-match, `kv.use_respawn_queue(func(): return match.respawns, func(id): return game.respawn(id))` holds and releases respawns; otherwise assign `hold_fn` and `release_fn`.
3. Each tick: `kv.record(time)`, then `for c in kv.collect(time, tick): send(c["victim"], DotKillViewClip.pack(c["clip"], c["info"], max_bytes))`. Costs nothing while `mp_killview` is 0. A clip is about 11 floats per sample, a few KiB; `pack` thins it to fit the event body.
4. On a kill: `kv.note_kill(killer_id, victim_id, time, {"killer": name, "weapon": weapon})`. On the victim's respawn request: `kv.skip(victim_id, tick)`. On leave: `kv.forget(id)`.

Client:

1. `var view := DotKillViewClient.new()`, add it to the tree, `view.setup(rules)`; `view.hide_fn = func(): return [hud, view_model]`.
2. On the event: `var got := DotKillViewClip.unpack(body)`, then `view.play(got["clip"], {"killer": name, "weapon": shown_name, "victim_id": me})`. Hide the normal death screen while `view.is_active()`.
3. `view.respawn_requested` fires only on a skip: send the respawn request there. `view.over(skipped)` resumes the flow.
4. Optional `view.stage`: a final-killcam recorder with `buffer` (a `DotKillcamBuffer` holding `kill` events), `pose_at(time, killer, victim) -> {target}`, `restore_bodies()` and `world_mask`, so the bodies stand where they were and the behind camera frames the victim.

The lower pieces (`DotKillViewRing`, `DotKillViewPlayer`) stay public for a game that draws its own camera.

## Cvars

| Cvar | Default | |
| --- | --- | --- |
| `mp_killview` | 0 | enable; off records and sends nothing |
| `mp_killview_seconds` | 6 | longest replay, wall seconds |
| `mp_killview_lead` | 3.5 | seconds shown before the kill |
| `mp_killview_post` | 0.5 | seconds shown after |
| `mp_killview_cursor` | 1 | include the killer's crosshair (not even sent when 0) |
| `mp_killview_skip` | 1 | the victim may skip |
| `mp_killview_skip_action` | `ui_accept` | input action that skips (Space by default) |
| `mp_killview_slowmo` | 0.5 | speed around the kill |
| `mp_killview_hz` | 30 | view samples per second per entity |
| `mp_killview_camera` | 1 | 0 the killer's eye, 1 behind the killer |
| `mp_killview_final` | 1 | the match's last kill is replayed before the summary (`DotKillcamHost.rules`) |
| `mp_killview_skip_grace` | 1 | seconds a replay ignores skip keys, so the click or jump that ended the match does not skip it |

The ring holds `lead + post + 1` seconds per entity (about 40 samples), at most `max_entities` entities.
