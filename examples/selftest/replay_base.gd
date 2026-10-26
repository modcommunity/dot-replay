extends Node

## The harness and fixtures every replay self-test section runs on.

const DIR := "user://dot_replay_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0
var _sections_finished := 0


# Stand-ins for the addons the taps duck-type against. Neither is installed here, and that
# is the point: the taps must work against anything of the right shape.

class FakeEvent extends RefCounted:
	var name: String = ""
	var data: Dictionary = {}
	var cancelled: bool = false
	var cancel_reason: String = ""


class FakeBus extends RefCounted:
	signal event_fired(event: Object)

	func fire(n: String, d: Dictionary, cancel: bool = false) -> void:
		var e := FakeEvent.new()
		e.name = n
		e.data = d
		e.cancelled = cancel
		e.cancel_reason = "filtered" if cancel else ""
		event_fired.emit(e)


class FakeSession extends RefCounted:
	func describe() -> Dictionary:
		return {"user_id": 7, "name": "seven"}


class FakeClock extends RefCounted:
	var tick: int = 0


class FakeManager extends RefCounted:
	var send_fn: Callable = Callable()
	var clock := FakeClock.new()



## Folds one record into a state. The "game" whose correctness the seek checks measure.
static func _apply(state: Dictionary, r: DotReplayRecord) -> void:
	match String(r.channel):
		"ops":
			var op: Dictionary = r.value()
			var k := str(op["k"])
			if op.has("set"):
				state[k] = int(op["set"])
			else:
				state[k] = int(state.get(k, 0)) + int(op["add"])
		"blob":
			var sum := 0
			for b in r.data:
				sum += b
			state["blob_n"] = int(state.get("blob_n", 0)) + 1
			state["blob_sum"] = int(state.get("blob_sum", 0)) + sum
		_:
			state["other"] = int(state.get("other", 0)) + 1


## Records [param ticks] ticks of a deterministic match. Returns the true state after every
## tick, and appends every record it made to [param made].
func _record_match(
	rec: DotReplayRecorder, ticks: int, made: Array, seed_value: int = 7
) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var live: Dictionary = {}
	var truth: Array[Dictionary] = []
	rec.keyframe_fn = func(_t: int) -> Variant: return live.duplicate(true)
	for t in range(ticks):
		rec.advance(t)
		var n := rng.randi_range(0, 3)
		for i in range(n):
			var r: DotReplayRecord
			if rng.randf() < 0.7:
				var op := {"k": "k%d" % rng.randi_range(0, 5)}
				if rng.randf() < 0.3:
					op["set"] = rng.randi_range(-50, 50)
				else:
					op["add"] = rng.randi_range(1, 9)
				rec.record_value(t, &"ops", op)
				r = DotReplayRecord.new(t, &"ops", var_to_bytes(op), DotReplayRecord.FLAG_VARIANT)
			else:
				var blob := PackedByteArray()
				for j in range(rng.randi_range(0, 12)):
					blob.append(rng.randi_range(0, 255))
				rec.record(t, &"blob", blob)
				r = DotReplayRecord.new(t, &"blob", blob, 0)
			_apply(live, r)
			made.append(r)
		truth.append(live.duplicate(true))
	return truth


func _new_recorder(chunk_ticks: int = 16, keyframe_every: int = 64) -> DotReplayRecorder:
	var rec := DotReplayRecorder.new()
	rec.chunk_ticks = chunk_ticks
	rec.keyframe_interval_ticks = keyframe_every
	return rec


func _header(tick_rate: int = 64) -> DotReplayHeader:
	return DotReplayHeader.make(
		"selftest", "dm_box", tick_rate,
		[{"id": 1, "name": "one"}, {"id": 2, "name": "two"}],
		{"server": "local", "round": 3}
	)


## Records a match to [param path] and finishes it. Returns [truth, made records].
func _write_match(
	path: String, ticks: int, key := PackedByteArray(), keyframe_every: int = 64, seed_value: int = 7
) -> Array:
	var rec := _new_recorder(16, keyframe_every)
	var started := rec.start(_header(), path, key)
	if not started.ok:
		_line("  (could not start %s: %s)" % [path, started.error])
	var made: Array = []
	var truth := _record_match(rec, ticks, made, seed_value)
	rec.stop()
	return [truth, made]


func _player() -> DotReplayPlayer:
	var p := DotReplayPlayer.new()
	p.auto_process = false
	# A clock that never moves unless a section moves it: step_ticks and seek are then the
	# only things that advance playback, and no check depends on how fast this machine is.
	p.now_fn = func() -> float: return 0.0
	add_child(p)
	return p


func _write_bytes(file_name: String, bytes: PackedByteArray) -> String:
	var p := DIR.path_join(file_name)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	return p


func _clean_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var d := DirAccess.open(DIR)
	if d == null:
		return
	for file_name in d.get_files():
		d.remove(file_name)


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_sections_finished += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
