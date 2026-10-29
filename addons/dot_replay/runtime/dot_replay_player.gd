class_name DotReplayPlayer
extends Node

## Plays a replay back: records emitted in tick order, at a speed, with pause and seek. It applies
## nothing; the game connects [signal state_reset], [signal record_played] and [signal finished].
## Seek = nearest keyframe plus fast-forward with [member is_seeking] set; time comes from [member now_fn].

const CHANNEL := "replay"

const MIN_SPEED := 0.25
const MAX_SPEED := 8.0

## Apply this record.
signal record_played(record: DotReplayRecord)

## Discard the current state and take [param state] as the state at [param tick]. [param
## state] is null when playback starts from the first record with no keyframe before it.
signal state_reset(tick: int, state: Variant)

## A seek finished; the next records played are after [param tick].
signal seeked(tick: int)

## Every record has been played.
signal finished()

## Poll from [method Node._process]. Off, the host calls [method poll] itself.
@export var auto_process: bool = true

## [code]func() -> float[/code], seconds. Empty uses the engine's monotonic clock.
var now_fn: Callable = Callable()

var file: DotReplayFile = null

## True while [method seek] is fast-forwarding. A game can skip effects while it is.
var is_seeking: bool = false

var _speed: float = 1.0
var _paused: bool = false
var _playing: bool = false
var _started: bool = false
var _done: bool = false
var _pos: float = 0.0
var _last_now: float = 0.0
var _chunk_i: int = 0
var _rec_i: int = 0
var _records: Array[DotReplayRecord] = []
var _channels: Dictionary = {}
var _played: int = 0


func _process(_delta: float) -> void:
	if auto_process:
		poll()


## Plays [param p_file]. Nothing is emitted until [method play].
func load_file(p_file: DotReplayFile) -> DotResult:
	if p_file == null or p_file.header == null:
		return DotResult.fail(DotError.CODE_INVALID, "That is not an open replay.")
	file = p_file
	_playing = false
	_started = false
	_done = false
	_paused = false
	_records = []
	_chunk_i = 0
	_rec_i = 0
	_played = 0
	return DotResult.success(self)


## Opens and loads [param path].
func open(path: String, key: PackedByteArray = PackedByteArray()) -> DotResult:
	var f := DotReplayFile.new()
	var r := f.open(path, key)
	if not r.ok:
		return r
	return load_file(f)



func play() -> DotResult:
	if file == null:
		return DotResult.fail(DotError.CODE_STATE, "No replay loaded.")
	if file.chunk_count() == 0:
		return DotResult.fail(DotError.CODE_STATE, "The replay has no records to play.")
	if not _started:
		var begun := _begin()
		if not begun.ok:
			return begun
	_playing = true
	_paused = false
	_done = false
	_last_now = _now()
	return DotResult.success(self)


func pause() -> void:
	poll()
	_paused = true


func resume() -> void:
	_last_now = _now()
	_paused = false


func stop() -> void:
	_playing = false
	_paused = false


func is_playing() -> bool:
	return _playing and not _paused


func is_paused() -> bool:
	return _paused


func is_finished() -> bool:
	return _done


## Clamped to 0.25x-8x. Time already elapsed is accounted at the old speed first, so a
## change mid-play does not jump.
func set_speed(value: float) -> void:
	if _playing and not _paused:
		poll()
	_speed = clampf(value, MIN_SPEED, MAX_SPEED)


func speed() -> float:
	return _speed


## Only records on these channels are emitted, during playback and seeks alike. Empty
## emits everything.
func set_channels(channels: Array) -> void:
	_channels.clear()
	for c in channels:
		_channels[StringName(str(c))] = true


## The tick playback has reached: every record at or before it has been emitted.
func position_tick() -> int:
	return floori(_pos)


func played_count() -> int:
	return _played



## Advances by the time since the last poll and emits what falls due. Returns how many
## records were emitted.
func poll() -> int:
	var now := _now()
	var dt := now - _last_now
	_last_now = now
	if not _playing or _paused or _done or file == null:
		return 0
	_pos += maxf(dt, 0.0) * float(file.header.tick_rate) * _speed
	return _emit_through(floori(_pos))


## Advances by exactly [param ticks] regardless of the clock. Frame stepping.
func step_ticks(ticks: int) -> int:
	if file == null:
		return 0
	if not _started:
		var begun := _begin()
		if not begun.ok:
			return 0
	_pos += float(ticks)
	return _emit_through(floori(_pos))



## Brings playback to [param tick]: the state after every record at or before it.
func seek(tick: int) -> DotResult:
	if file == null:
		return DotResult.fail(DotError.CODE_STATE, "No replay loaded.")
	if file.chunk_count() == 0:
		return DotResult.fail(DotError.CODE_STATE, "The replay has no records.")
	var target := clampi(tick, file.first_tick(), file.last_tick())

	var k := file.keyframe_chunk_for(target)
	var loaded := _load_chunk(maxi(k, 0))
	if not loaded.ok:
		return loaded
	if k >= 0:
		var kf := _records[0]
		state_reset.emit(kf.tick, kf.value())
		_rec_i = 1
	else:
		state_reset.emit(file.first_tick(), null)
		_rec_i = 0
	_started = true
	_done = false

	is_seeking = true
	_emit_through(target)
	is_seeking = false

	_pos = float(target)
	_last_now = _now()
	DotLog.debug(CHANNEL, "seeked", {"tick": target, "from_keyframe_chunk": k})
	seeked.emit(target)
	return DotResult.success(target)


func _begin() -> DotResult:
	var loaded := _load_chunk(0)
	if not loaded.ok:
		return loaded
	_started = true
	if not _records.is_empty() and _records[0].is_keyframe():
		state_reset.emit(_records[0].tick, _records[0].value())
		_rec_i = 1
	else:
		state_reset.emit(file.first_tick(), null)
		_rec_i = 0
	_pos = float(file.first_tick())
	return DotResult.success(null)


func _load_chunk(i: int) -> DotResult:
	var r := file.read_chunk(i)
	if not r.ok:
		DotLog.warn(CHANNEL, "playback stopped: a chunk could not be read", {"chunk": i, "why": str(r.error)})
		_playing = false
		return r
	_records = r.value
	_chunk_i = i
	_rec_i = 0
	return r


func _emit_through(target: int) -> int:
	var n := 0
	while true:
		if _rec_i >= _records.size():
			if _chunk_i + 1 >= file.chunk_count():
				if not is_seeking and not _done:
					_done = true
					_playing = false
					finished.emit()
				break
			if not _load_chunk(_chunk_i + 1).ok:
				break
			continue
		var r := _records[_rec_i]
		if r.tick > target:
			break
		_rec_i += 1
		if r.is_keyframe():
			# Linear playback already holds this state; a keyframe only matters to a seek.
			continue
		if _channels.is_empty() or _channels.has(r.channel):
			n += 1
			_played += 1
			record_played.emit(r)
	return n


func _now() -> float:
	if now_fn.is_valid():
		return float(now_fn.call())
	return Time.get_ticks_usec() / 1000000.0


func describe() -> Dictionary:
	return {
		"file": file.path if file != null else "",
		"playing": _playing,
		"paused": _paused,
		"finished": _done,
		"speed": _speed,
		"tick": position_tick(),
		"ticks": [file.first_tick(), file.last_tick()] if file != null else [0, 0],
		"channels": _channels.keys(),
		"played": _played,
	}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray([
		"replay player: %s at tick %d, %sx%s%s, %d record(s) played" % [
			d["file"] if d["file"] != "" else "(nothing loaded)", d["tick"], _speed,
			", paused" if _paused else "", ", finished" if _done else "", _played,
		],
	])
