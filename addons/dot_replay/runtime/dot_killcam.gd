class_name DotKillcam
extends Node

## A killcam: replays a [DotKillcamBuffer] around one kill, slowed at the moment, skippable.
##
## The node owns the clock and the banner; it draws nothing in the world. Every frame it emits
## [signal frame_drawn] with the buffer's sample for the replayed instant, and the game places
## its bodies and camera from that (it alone knows what a frame holds). [method play] may come
## before the frames after the kill exist: it waits, up to [member post_seconds] and a margin,
## for the buffer to catch up, so a match that ends on the kill still shows what followed.

const CHANNEL := "replay"

enum State { IDLE, WAITING, PLAYING }

## Playback began; [param kill] is the buffer's event {time, kind, data}.
signal started(kill: Dictionary)

## One replayed instant: {time, a, b, alpha} from [method DotKillcamBuffer.sample], plus
## "kill_time" and "progress" (0 to 1).
signal frame_drawn(sample: Dictionary)

## Over, by its end, a skip, or a buffer that never covered the kill.
signal finished(skipped: bool)

## Seconds replayed before the kill.
@export_range(0.0, 10.0, 0.1) var pre_seconds: float = 3.5

## Seconds replayed after the kill.
@export_range(0.0, 5.0, 0.1) var post_seconds: float = 1.0

## Seconds each side of the kill played at [member slow_scale].
@export_range(0.0, 3.0, 0.05) var slow_seconds: float = 0.5

## Playback speed around the kill.
@export_range(0.05, 1.0, 0.05) var slow_scale: float = 0.5

## The whole killcam, waiting included, never runs longer than this; 0 disables it.
@export_range(0.0, 30.0, 0.5) var max_seconds: float = 7.0

## Input actions that skip it; any one pressed skips.
@export var skip_actions: PackedStringArray = PackedStringArray(["ui_cancel", "ui_accept"])

## Advance in [method _process]; off for a test that calls [method advance] itself.
@export var auto_process: bool = true

## Build and show a [DotKillcamBanner] when none is assigned.
@export var show_banner: bool = true

## What is shown over the replay. Assign one of your own before [method play] to restyle it.
var banner: DotKillcamBanner = null

var buffer: DotKillcamBuffer = null
var state: State = State.IDLE

var _kill: Dictionary = {}
var _kill_time: float = 0.0
var _from: float = 0.0
var _to: float = 0.0
var _pos: float = 0.0
var _waited: float = 0.0
var _elapsed: float = 0.0


func _process(delta: float) -> void:
	if auto_process and state != State.IDLE:
		advance(delta)


func _unhandled_input(event: InputEvent) -> void:
	if state == State.IDLE or event.is_echo():
		return
	for action in skip_actions:
		if InputMap.has_action(action) and event.is_action_pressed(action):
			get_viewport().set_input_as_handled()
			skip()
			return


func enabled() -> bool:
	return max_seconds > 0.0


func is_active() -> bool:
	return state != State.IDLE


## Starts the killcam for [param kill] (an event from [param p_buffer]); [param info] goes to the
## banner (title, killer, victim, weapon, hint). Fails with CODE_STATE when disabled, already
## running, or the buffer holds nothing from before the kill.
func play(p_buffer: DotKillcamBuffer, kill: Dictionary, info: Dictionary = {}) -> DotResult:
	if not enabled():
		return DotResult.fail(DotError.CODE_STATE, "The killcam is disabled (max_seconds 0).")
	if state != State.IDLE:
		return DotResult.fail(DotError.CODE_STATE, "A killcam is already running.")
	if p_buffer == null or kill.is_empty() or not kill.has("time"):
		return DotResult.fail(DotError.CODE_STATE, "No kill to replay.")
	var kill_time := float(kill["time"])
	if p_buffer.frame_count() == 0 or p_buffer.oldest_time() > kill_time:
		return DotResult.fail(DotError.CODE_STATE, "The buffer holds nothing from before the kill.")

	buffer = p_buffer
	_kill = kill
	_kill_time = kill_time
	_waited = 0.0
	_elapsed = 0.0
	state = State.WAITING
	if show_banner:
		if banner == null:
			banner = DotKillcamBanner.new()
			add_child(banner)
		banner.skip_pressed.connect(skip, CONNECT_ONE_SHOT)
	if banner != null:
		banner.present(info)
	DotLog.debug(CHANNEL, "killcam waiting for the frames after the kill", {"kill_time": kill_time})
	_try_start()
	return DotResult.success()


## Moves the replay on by [param delta] real seconds.
func advance(delta: float) -> void:
	_elapsed += delta
	if state == State.WAITING:
		_waited += delta
		_try_start()
		return
	if state != State.PLAYING:
		return
	_pos = minf(_pos + delta * speed_at(_pos), _to)
	_emit_frame()
	if _pos >= _to or _elapsed >= max_seconds:
		_finish(false)


func skip() -> void:
	if state != State.IDLE:
		_finish(true)


## The playback speed at replayed instant [param t].
func speed_at(t: float) -> float:
	return slow_scale if absf(t - _kill_time) <= slow_seconds else 1.0


## Real seconds it takes to replay from [param from] to [param to] around [param kill_time].
func wall_seconds(from: float, to: float, kill_time: float) -> float:
	var slow_from := maxf(from, kill_time - slow_seconds)
	var slow_to := minf(to, kill_time + slow_seconds)
	var slowed := maxf(slow_to - slow_from, 0.0)
	return (to - from - slowed) + slowed / slow_scale


## The replayed span, [from, to], once playing.
func window() -> Vector2:
	return Vector2(_from, _to)


func kill_time() -> float:
	return _kill_time


func kill() -> Dictionary:
	return _kill


func progress() -> float:
	return 0.0 if _to <= _from else clampf((_pos - _from) / (_to - _from), 0.0, 1.0)


func _try_start() -> void:
	var wanted_end := _kill_time + post_seconds
	var budget_left := max_seconds - _elapsed
	# Waits past post_seconds only by a margin: a stalled stream must not hold the match's end.
	if buffer.newest_time() < wanted_end and _waited < post_seconds + 0.5 and budget_left > 0.5:
		return
	_to = minf(wanted_end, buffer.newest_time())
	_from = maxf(_kill_time - pre_seconds, buffer.oldest_time())
	# Over budget, start later rather than cut the kill off.
	while _from < _kill_time and wall_seconds(_from, _to, _kill_time) > budget_left:
		_from = minf(_from + 0.1, _kill_time)
	if _to <= _from or budget_left <= 0.0:
		_finish(true)
		return
	_pos = _from
	state = State.PLAYING
	DotLog.debug(CHANNEL, "killcam playing", {
		"from": _from, "to": _to, "kill_time": _kill_time,
		"wall_seconds": wall_seconds(_from, _to, _kill_time),
	})
	started.emit(_kill)
	_emit_frame()


func _emit_frame() -> void:
	var s := buffer.sample(_pos)
	s["kill_time"] = _kill_time
	s["progress"] = progress()
	if banner != null:
		banner.set_progress(s["progress"])
	frame_drawn.emit(s)


func _finish(skipped: bool) -> void:
	state = State.IDLE
	if banner != null:
		if banner.skip_pressed.is_connected(skip):
			banner.skip_pressed.disconnect(skip)
		banner.dismiss()
	DotLog.debug(CHANNEL, "killcam over", {"skipped": skipped})
	finished.emit(skipped)


func describe() -> Dictionary:
	return {
		"state": State.keys()[state], "kill_time": _kill_time, "from": _from, "to": _to,
		"at": _pos, "max_seconds": max_seconds,
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"killcam: %s, kill at %.2f, window %.2f-%.2f, at %.2f, budget %.1f s" % [
			State.keys()[state], _kill_time, _from, _to, _pos, max_seconds,
		],
	])
