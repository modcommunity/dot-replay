class_name DotKillViewClient
extends Node

## The client half of the kill view: plays the clip the server sent on this player's death from behind
## the killer (or at the killer's eye and crosshair, `mp_killview_camera` 0) on its own camera, hides
## what [member hide_fn] names meanwhile, and hands the screen back when it ends or is skipped.

const CHANNEL := "replay.killview.client"

## The replay is over; [param skipped] when the victim cut it short.
signal over(skipped: bool)

## The victim skipped: ask the server to respawn.
signal respawn_requested

var kv: DotKillViewPlayer = null
var camera: Camera3D = null

## The killer's crosshair overlay, drawn only at the eye.
var crosshair: Crosshair = null

## () -> Array: the nodes to hide while a replay runs (the HUD, the view model).
var hide_fn: Callable = Callable()

## Optional final-killcam recorder that poses the bodies around the kill, duck-typed: `buffer`
## ([DotKillcamBuffer] with "kill" events {killer, victim}), `pose_at(time, killer, victim) -> {target}`,
## `restore_bodies()`, `world_mask`. Null leaves the world as it is.
var stage: Object = null

var _framing: DotKillcamFraming = null
var _kill_at: float = NAN
var _killer: int = 0
var _victim: int = 0
var _posed: Dictionary = {}
var _previous_camera: Camera3D = null
var _hidden: Dictionary = {}


## Builds the player, camera and crosshair under this node.
func setup(rules: DotKillViewRules) -> void:
	kv = DotKillViewPlayer.new(rules)
	kv.name = "KillView"
	add_child(kv)
	kv.moment.connect(_on_moment)
	kv.view.connect(_on_view)
	kv.finished.connect(_on_finished)
	kv.respawn_requested.connect(func() -> void: respawn_requested.emit())
	camera = Camera3D.new()
	camera.name = "KillViewCamera"
	add_child(camera)
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	crosshair = Crosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.visible = false
	layer.add_child(crosshair)


func is_active() -> bool:
	return kv != null and kv.is_active()


## Starts the replay of a server clip; [param info] may carry `killer`, `weapon`, `victim_id`.
## False when it did not start (off, already running, a bad clip).
func play(clip: Dictionary, info: Dictionary) -> bool:
	if kv == null:
		return false
	# Before play_clip: its first frame can already make the replay camera current.
	var before := get_viewport().get_camera_3d()
	_killer = int(clip.get("killer", 0))
	_victim = int(info.get("victim_id", 0))
	_kill_at = _kill_time(_killer, _victim)
	_posed = {}
	if _framing != null:
		_framing.reset()
	var res := kv.play_clip(clip, info)
	if not res.ok:
		DotLog.debug(CHANNEL, "no kill view", {"why": res.error.message})
		return false
	_previous_camera = before if before != camera else null
	if _previous_camera != null:
		camera.cull_mask = _previous_camera.cull_mask
	camera.make_current()
	DotLog.info(CHANNEL, "kill view started", {"killer": info.get("killer", ""), "weapon": info.get("weapon", "")})
	if hide_fn.is_valid():
		for n: Variant in hide_fn.call():
			if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
				_hidden[n] = bool((n as Object).get(&"visible"))
				(n as Object).set(&"visible", false)
	return true


## When the stage saw [param killer] kill [param victim], on its clock; NAN if it did not.
func _kill_time(killer: int, victim: int) -> float:
	if stage == null or killer == 0:
		return NAN
	var buffer: DotKillcamBuffer = stage.get(&"buffer")
	if buffer == null:
		return NAN
	var kills: Array[Dictionary] = buffer.events_between(-INF, INF, &"kill")
	for i in range(kills.size() - 1, -1, -1):
		var d: Dictionary = kills[i]["data"]
		if int(d.get("killer", 0)) == killer and (victim == 0 or int(d.get("victim", 0)) == victim):
			return float(kills[i]["time"])
	return NAN


func _on_moment(seconds_from_kill: float) -> void:
	_posed = {}
	if stage != null and not is_nan(_kill_at):
		_posed = stage.call(&"pose_at", _kill_at + seconds_from_kill, _killer, _victim)


func _on_view(xform: Transform3D, fov: float, cursor: Vector2, has_cursor: bool) -> void:
	if not camera.current:
		camera.make_current()
	var behind := kv.rules.camera == DotKillViewRules.Camera.BEHIND
	if behind:
		if _framing == null:
			_framing = DotKillcamFraming.new(camera.get_world_3d(), int(stage.get(&"world_mask")) if stage != null else 1)
		var v := _framing.place(DotKillViewRules.Camera.BEHIND, xform, fov, _posed.get("target"), get_process_delta_time())
		xform = v["transform"]
		fov = v["fov"]
	camera.global_transform = xform
	camera.fov = clampf(fov, 20.0, 150.0)
	# The killer's crosshair belongs to the killer's screen, not one behind them.
	crosshair.visible = has_cursor and not behind
	crosshair.at = cursor


func _on_finished(skipped: bool) -> void:
	DotLog.info(CHANNEL, "kill view ended", {"skipped": skipped})
	crosshair.visible = false
	if stage != null:
		stage.call(&"restore_bodies")
	_posed = {}
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


func describe() -> Dictionary:
	return {"active": is_active(), "killer": _killer, "victim": _victim, "hidden": _hidden.size()}


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["kill view: %s, killer %d, victim %d" % ["playing" if is_active() else "idle", _killer, _victim]])


## The killer's crosshair: four ticks round a gap, at the recorded point of the screen (0..1).
class Crosshair extends Control:
	var at := Vector2(0.5, 0.5):
		set(v):
			at = v
			queue_redraw()

	func _draw() -> void:
		var c := Vector2(size.x * at.x, size.y * at.y)
		var col := Color(1.0, 0.25, 0.2)
		for d: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * 4.0, c + d * 11.0, col, 2.0)
