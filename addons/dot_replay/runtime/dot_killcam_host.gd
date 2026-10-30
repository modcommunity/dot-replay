class_name DotKillcamHost
extends Node

## The final killcam a game wraps around [DotKillcamBuffer] and [DotKillcam]: records every drawn frame
## and kill, replays the last kill at the match's end, poses the bodies and places the camera.
## What differs per game is a hook (`state_fn`, `place_body_fn`, `restore_body_fn`, ...); see docs/killcam-host.md.
## Player ids are any Variant (int or StringName) as long as the game uses one kind throughout.

var log_channel := "dot.killcam"

## Skip keys: the keys a player's hands are already on.
var skip_actions: PackedStringArray = ["ui_cancel"]

## Shown under the banner.
var skip_hint := "Jump to skip"

## Optional policy (`mp_killview_final`, `mp_killview_skip_grace`); null shows the final killcam always.
var rules: DotKillViewRules = null

## The id that means "nobody" (0 for int ids, &"" for names).
var no_id: Variant = 0

## Extra camera cull layers while it plays (a layer the local body sits on).
var camera_cull_extra: int = 0

## The killcam is over (or never began); the end-of-match flow goes on from here.
signal over(skipped: bool)

## Every player node to record, this frame.
var players_fn: Callable = Callable()

## Player node for a session id, or null.
var player_for_fn: Callable = Callable()

## Player node -> its id; default reads `player_id`.
var id_of_fn: Callable = func(p: Node) -> Variant: return p.get(&"player_id")

## Player node -> [feet, yaw, pitch, alive, eye height] as drawn; [] skips it. Required.
var state_fn: Callable = Callable()

## (player, feet, yaw, shown, pitch, speed, touched): poses one body. Fill `touched[player]` with what [member restore_body_fn] needs, once, before changing it.
var place_body_fn: Callable = Callable()

## Player node -> its body's pose as drawn (an opaque PackedFloat32Array, e.g. [code]DotHumanoidFigure.pose_record[/code]);
## empty keeps none. Without it a replayed body shows whatever its clip last left.
var pose_fn: Callable = Callable()

## (player, pose a, pose b, alpha): draws a recorded pose on a body [member place_body_fn] showed.
var apply_pose_fn: Callable = Callable()

## (player, row a, row b, alpha, is_victim): called for every body each replayed frame after it is placed, with the
## recorded rows either side of the moment, so a game can play what the rows say happened (a shot, a death).
var event_fn: Callable = Callable()

## Poses kept per second when there are no [member rules] (they say `mp_killview_pose_hz`); 0 keeps none.
var pose_hz: float = 30.0

## (player, touched[player]): puts back what [member place_body_fn] saved.
var restore_body_fn: Callable = Callable()

## (kill data) -> bool: false skips the replay (a suicide, say).
var can_play_fn: Callable = func(_data: Dictionary) -> bool: return true

## Bodies a replay moved, player -> whatever the game saved for [member restore_body_fn].
var touched: Dictionary = {}

## The killcam's length in seconds; 0 disables.
var seconds_fn: Callable = func() -> float: return 7.0

## Seconds, monotonic. Injected by a test.
var now_fn: Callable = func() -> float: return Time.get_ticks_usec() / 1000000.0

## Shown as-is in the banner: the weapon id's words.
var weapon_name_fn: Callable = func(id: String) -> String: return id.capitalize()

## Weapon id -> Texture2D or null: the picture beside the weapon's name in the banner.
var weapon_icon_fn: Callable = Callable()

## Nodes hidden while the replay runs (the HUD, the view model): anything with `visible`.
var hide_while_playing: Array = []

## Where the camera sits ([enum DotKillViewRules.Camera]): the game's `mp_killview_camera`.
var camera_mode_fn: Callable = func() -> int: return DotKillViewRules.Camera.EYE

## (view: Dictionary) -> void, each frame of the replay and once with {} at its end: redraws the killer's
## screen from {camera, aux, fov}. aux is [method state_fn]'s row from index 5, as floats.
var present_fn: Callable = Callable()

## Layers the camera boom stops against (the map's).
var world_mask: int = 1

var buffer := DotKillcamBuffer.new()

## Every body's [member pose_fn] at [member pose_hz], on the same clock as [member buffer].
var poses := DotKillcamBuffer.new()
var killcam: DotKillcam = null
var camera: Camera3D = null

var _previous_camera: Camera3D = null
var _framing: DotKillcamFraming = null
var _base_fov: float = 75.0
var _hidden: Dictionary = {}
var _posed_at: float = -INF
# The last [method pose] call, redrawn by [method frame] over whatever the game's presentation drew since.
var _again: Array = []


func _ready() -> void:
	killcam = DotKillcam.new()
	killcam.name = "Killcam"
	killcam.skip_actions = skip_actions
	killcam.icon_provider = func(id: String) -> Texture2D:
		return weapon_icon_fn.call(id) if weapon_icon_fn.is_valid() else null
	add_child(killcam)
	killcam.started.connect(_on_started)
	killcam.frame_drawn.connect(_apply)
	killcam.finished.connect(_on_finished)
	camera = Camera3D.new()
	camera.name = "KillcamCamera"
	add_child(camera)


func is_playing() -> bool:
	return killcam != null and killcam.is_active()


## Records this frame. Called once a frame after every body is presented; while the replay runs
## it re-applies the replayed frame instead, over what presentation just drew.
func frame() -> void:
	if not _again.is_empty():
		var _posed := pose(_again[0], _again[1], _again[2])
	if is_playing():
		if killcam.state == DotKillcam.State.WAITING:
			_record()
		return
	_record()


## A kill this client was told about.
func note_kill(killer_id: Variant, victim_id: Variant, weapon: String, headshot: bool = false) -> void:
	buffer.note_event(now_fn.call(), &"kill", {
		"killer": killer_id, "victim": victim_id, "weapon": weapon, "headshot": headshot,
	})


## The match ended: replay its last kill if there is one to show. False means [signal over] has
## already been emitted and nothing will play.
func match_ended() -> bool:
	if killcam == null or is_playing():
		return is_playing()
	killcam.max_seconds = maxf(float(seconds_fn.call()), 0.0)
	if rules != null:
		killcam.skip_grace = rules.skip_grace
		if not rules.final_killcam:
			over.emit(false)
			return false
	var kill := buffer.last_event(&"kill")
	var killer_id: Variant = kill["data"].get("killer", no_id) if not kill.is_empty() else no_id
	var killer: Node = _player(killer_id)
	if not killcam.enabled() or killer == null or not bool(can_play_fn.call(kill["data"])):
		over.emit(false)
		return false
	var victim: Node = _player(kill["data"].get("victim", no_id))
	var played := killcam.play(buffer, kill, {
		"killer": String(killer.get(&"display_name")),
		"victim": String(victim.get(&"display_name")) if victim != null else "",
		"weapon": weapon_name_fn.call(String(kill["data"].get("weapon", ""))),
		"weapon_id": String(kill["data"].get("weapon", "")),
		"hint": skip_hint,
	})
	if not played.ok:
		DotLog.debug(log_channel, "no final killcam", {"why": played.error.message})
		over.emit(false)
		return false
	return true


func skip() -> void:
	if killcam != null:
		killcam.skip()


func _player(id: Variant) -> Node:
	if id == no_id or not player_for_fn.is_valid():
		return null
	var p: Variant = player_for_fn.call(id)
	return p as Node if p is Node and is_instance_valid(p) else null


func _record() -> void:
	if not players_fn.is_valid():
		return
	var now: float = now_fn.call()
	var shot := {}
	var players: Array = players_fn.call()
	for p: Node in players:
		var row: Array = state_fn.call(p)
		if not row.is_empty():
			shot[id_of_fn.call(p)] = row
	var _kept := buffer.push_frame(now, shot)
	var hz := rules.pose_hz if rules != null else pose_hz
	if not _again.is_empty() or not pose_fn.is_valid() or hz <= 0.0 or now - _posed_at < 1.0 / hz - 0.001:
		return
	var held := {}
	for p: Node in players:
		var drawn: Variant = pose_fn.call(p)
		if drawn is PackedFloat32Array and not (drawn as PackedFloat32Array).is_empty():
			held[id_of_fn.call(p)] = drawn
	poses.window_seconds = buffer.window_seconds
	if poses.push_frame(now, held):
		_posed_at = now


func _on_started(_kill: Dictionary) -> void:
	_previous_camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _previous_camera != null and _previous_camera != camera:
		camera.fov = _previous_camera.fov
		camera.cull_mask = _previous_camera.cull_mask | camera_cull_extra
	_base_fov = camera.fov
	if _framing != null:
		_framing.reset()
	camera.make_current()
	for n: Variant in hide_while_playing:
		if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
			_hidden[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)
	DotLog.info(log_channel, "final killcam", killcam.describe())


func _apply(s: Dictionary) -> void:
	var data: Dictionary = killcam.kill()["data"]
	var posed := pose(s, data.get("killer", no_id), data.get("victim", no_id))
	if not camera.current:
		camera.make_current()
	if posed.has("eye"):
		var v := place_camera(posed, _base_fov, get_process_delta_time())
		camera.global_transform = v["transform"]
		camera.fov = v["fov"]
		if present_fn.is_valid():
			present_fn.call({"camera": camera, "aux": posed.get("aux", PackedFloat32Array()), "fov": camera.fov, "behind": int(camera_mode_fn.call()) == DotKillViewRules.Camera.BEHIND})


## Poses every recorded body at [param time] on this client's own clock; see [method pose].
func pose_at(time: float, killer_id: Variant, victim_id: Variant) -> Dictionary:
	var s := buffer.sample(time)
	return {} if s.is_empty() else pose(s, killer_id, victim_id)


## Poses every body in sample [param s]; the killer's is drawn only when the camera is behind it.
## Returns {eye: the killer's eye Transform3D, target: the victim's chest} for what was recorded.
func pose(s: Dictionary, killer_id: Variant, victim_id: Variant) -> Dictionary:
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var alpha: float = s["alpha"]
	var behind := int(camera_mode_fn.call()) == DotKillViewRules.Camera.BEHIND
	var drawn := poses.sample(float(s["time"])) if apply_pose_fn.is_valid() and s.has("time") else {}
	_again = [s, killer_id, victim_id]
	var out := {}
	for id: Variant in b:
		var p := _player(id)
		if p == null:
			continue
		var rb: Array = b[id]
		var ra: Array = a.get(id, rb)
		var feet: Vector3 = (ra[0] as Vector3).lerp(rb[0], alpha)
		var yaw := rad_to_deg(lerp_angle(deg_to_rad(ra[1]), deg_to_rad(rb[1]), alpha))
		var pitch := lerpf(ra[2], rb[2], alpha)
		var alive: bool = rb[3] if alpha >= 0.5 else ra[3]
		var speed := (ra[0] as Vector3).distance_to(rb[0]) * 60.0
		if id == killer_id:
			var eye := feet + Vector3(0.0, float(rb[4]), 0.0)
			out["aux"] = PackedFloat32Array(rb.slice(5)) if rb.size() > 5 else PackedFloat32Array()
			out["eye"] = Transform3D(Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)), eye)
			_place(p, feet, yaw, behind, pitch, speed)
			if behind:
				_apply_pose(p, id, drawn)
			_event(p, ra, rb, alpha, false)
		else:
			if id == victim_id:
				out["target"] = feet + Vector3(0.0, 1.2, 0.0)
			_place(p, feet, yaw, alive, pitch, speed)
			if alive:
				_apply_pose(p, id, drawn)
			_event(p, ra, rb, alpha, id == victim_id)
	return out


func _event(p: Node, ra: Array, rb: Array, alpha: float, is_victim: bool) -> void:
	if event_fn.is_valid():
		event_fn.call(p, ra, rb, alpha, is_victim)


func _apply_pose(p: Node, id: Variant, drawn: Dictionary) -> void:
	if drawn.is_empty():
		return
	var pa: Variant = (drawn["a"] as Dictionary).get(id)
	var pb: Variant = (drawn["b"] as Dictionary).get(id)
	if pa == null and pb == null:
		return
	apply_pose_fn.call(p, pb if pa == null else pa, pa if pb == null else pb, float(drawn["alpha"]))


## The camera for a [method pose] result: the killer's eye, or behind the killer looking at the victim.
func place_camera(posed: Dictionary, base_fov: float, delta: float) -> Dictionary:
	if _framing == null:
		_framing = DotKillcamFraming.new(camera.get_world_3d() if is_inside_tree() else null, world_mask)
	_framing.probe.collision_mask = world_mask
	return _framing.place(int(camera_mode_fn.call()), posed["eye"], base_fov, posed.get("target"), delta)


## Puts back every body a replay moved.
func restore_bodies() -> void:
	_again.clear()
	for p: Variant in touched:
		if is_instance_valid(p) and restore_body_fn.is_valid():
			restore_body_fn.call(p, touched[p])
	touched.clear()


func _place(p: Node, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float) -> void:
	if place_body_fn.is_valid():
		place_body_fn.call(p, feet, yaw, shown, pitch, speed, touched)


func _on_finished(skipped: bool) -> void:
	if present_fn.is_valid():
		present_fn.call({})
	restore_bodies()
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


func describe_lines() -> PackedStringArray:
	var out := buffer.describe_lines()
	if killcam != null:
		out.append_array(killcam.describe_lines())
	return out
