class_name DotKillViewPlayer
extends Node

## Client side of the kill-cam: plays a killer-view clip through a [DotKillcam], slowed at the kill,
## and tells the game where to put its camera and crosshair. Draws no camera; the game does.

const CHANNEL := "replay.killview"

## Place the replay camera: transform, fov (degrees), cursor in 0..1 screen space, whether to draw it.
signal view(transform: Transform3D, fov: float, cursor: Vector2, has_cursor: bool)

## Over; [param skipped] when the victim (or a short clip) ended it early. The respawn flow resumes here.
signal finished(skipped: bool)

## The victim skipped: respawn now.
signal respawn_requested

var rules: DotKillViewRules = null

## Called on a skip, in addition to [signal respawn_requested]: the game's respawn request.
var respawn_fn: Callable = Callable()

## Advance in [method Node._process]; off for a test that calls [method advance].
var auto_process: bool = true

var killcam: DotKillcam = null


func _init(p_rules: DotKillViewRules = null) -> void:
	rules = p_rules if p_rules != null else DotKillViewRules.new()


func is_active() -> bool:
	return killcam != null and killcam.is_active()


## Starts the replay of [param clip]. Fails with CODE_STATE when off or running, CODE_PARSE for a bad clip.
func play_clip(clip: Dictionary, info: Dictionary = {}) -> DotResult:
	if not rules.enabled:
		return DotResult.fail(DotError.CODE_STATE, "The kill view is off.")
	var made := DotKillViewClip.to_buffer(clip)
	if not made.ok:
		return made.wrap("The kill view clip is unusable.")
	if killcam == null:
		killcam = DotKillcam.new()
		killcam.frame_drawn.connect(_on_frame)
		killcam.finished.connect(_on_finished)
		add_child(killcam)
	killcam.auto_process = auto_process
	killcam.max_seconds = rules.seconds
	killcam.pre_seconds = rules.lead_seconds
	killcam.post_seconds = rules.post_seconds
	killcam.slow_scale = rules.slowmo
	killcam.skip_allowed = rules.skip_allowed
	killcam.skip_actions = PackedStringArray([rules.skip_action])
	var shown := info.duplicate()
	shown["title"] = shown.get("title", "KILL VIEW")
	if not rules.skip_allowed:
		shown["hint"] = ""
	var buffer: DotKillcamBuffer = made.value
	return killcam.play(buffer, buffer.last_event(DotKillViewClip.KIND_KILL), shown)


func advance(delta: float) -> void:
	if killcam != null:
		killcam.advance(delta)


func _on_frame(sample: Dictionary) -> void:
	var v := DotKillViewClip.view_at(sample)
	view.emit(v["transform"], v["fov"], v["cursor"], v["has_cursor"])


func _on_finished(skipped: bool) -> void:
	DotLog.debug(CHANNEL, "kill view over", {"skipped": skipped})
	finished.emit(skipped)
	if skipped:
		respawn_requested.emit()
		if respawn_fn.is_valid():
			respawn_fn.call()
