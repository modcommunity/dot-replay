# The kill view

When a player dies they see the replay of their killer's view (camera, fov and crosshair), then the respawn flow resumes. Reuses `DotKillcam` (clock, slow-motion, banner, skip) and `DotKillcamBuffer`; the new parts only record and carry the killer's view. It is a different thing from the killcam of what a client already drew: the victim never drew the killer's eyes, so the server records them.

## The hook a game wires in

Server (no autoloads; the game owns the nodes):

1. `var rules := DotKillViewRules.new()`, `rules.bind_cvars(module.add_cvar, DotServer.FLAG_REPLICATED)` (cvars below), `var ring := DotKillViewRing.new(rules)`.
2. Each tick, for every player and bot with a camera: `ring.record(id, time, camera_transform, fov, crosshair_uv)`. Costs nothing while `mp_killview` is 0. `crosshair_uv` is 0..1 in the killer's viewport.
3. On a kill: `ring.note_kill(killer_id, victim_id, time, {"killer": name, "weapon": weapon})`.
4. Each tick: `for c in ring.collect(time): send(c["victim"], c["clip"])`. A clip is plain Variants, a `PackedFloat32Array` of about 11 floats per sample, a few KiB.
5. On leave: `ring.forget(id)`.

Client:

1. `var rules := DotKillViewRules.new()`, `rules.follow_cvars(client_link)`; `var kv := DotKillViewPlayer.new(rules)`; add it to the tree.
2. `kv.view.connect(func(transform, fov, cursor, has_cursor): ...)` puts the replay camera and crosshair.
3. On the clip: `kv.play_clip(clip, {"killer": name, "weapon": weapon})`. Hide the normal death screen while `kv.is_active()`.
4. `kv.finished(skipped)` resumes the respawn flow; `kv.respawn_requested` (or `kv.respawn_fn`) fires only on a skip: send the respawn request there.

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

The ring holds `lead + post + 1` seconds per entity (about 40 samples), at most `max_entities` entities.
