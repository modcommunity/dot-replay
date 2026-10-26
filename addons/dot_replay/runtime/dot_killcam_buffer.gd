class_name DotKillcamBuffer
extends RefCounted

## The last few seconds of what a client drew, in memory, for a killcam: timed frames and events.
## Opaque Dictionaries, ordered and bounded here; uncompressed so any instant samples cheaply.

const CHANNEL := "replay"

## How far back frames and events are kept, seconds.
var window_seconds: float = 8.0

## The most frames held, whatever their spacing (a 240 Hz display would otherwise fill it).
var max_frames: int = 1024

## The most events held.
var max_events: int = 64

var _times := PackedFloat64Array()
var _frames: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _refused: int = 0


## Adds what was drawn at [param time]. A time not after the last frame's is refused (false).
func push_frame(time: float, frame: Dictionary) -> bool:
	if not _times.is_empty() and time <= _times[_times.size() - 1]:
		_refused += 1
		return false
	_times.append(time)
	_frames.append(frame)
	_evict(time)
	return true


## Remembers that [param kind] happened at [param time] (a kill, a shot), with its data.
func note_event(time: float, kind: StringName, data: Dictionary = {}) -> void:
	_events.append({"time": time, "kind": kind, "data": data})
	_evict(maxf(time, newest_time()))


## The newest event of [param kind] as {time, kind, data}, or {} if none is held.
func last_event(kind: StringName) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if _events[i]["kind"] == kind:
			return _events[i]
	return {}


## Events from [param from] to [param to], inclusive, oldest first.
func events_between(from: float, to: float, kind: StringName = &"") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _events:
		var t: float = e["time"]
		if t >= from and t <= to and (kind == &"" or e["kind"] == kind):
			out.append(e)
	return out


## Frames from [param from] to [param to], inclusive, as {time, frame}, oldest first.
func frames_between(from: float, to: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(_times.bsearch(from, true), _times.size()):
		if _times[i] > to:
			break
		out.append({"time": _times[i], "frame": _frames[i]})
	return out


## The two frames around [param time] and how far between them it is:
## {time, a, b, alpha}. Before the first frame or after the last it clamps; {} when empty.
func sample(time: float) -> Dictionary:
	if _times.is_empty():
		return {}
	var i := _times.bsearch(time, false)
	if i <= 0:
		return {"time": time, "a": _frames[0], "b": _frames[0], "alpha": 0.0}
	if i >= _times.size():
		var last := _frames[_frames.size() - 1]
		return {"time": time, "a": last, "b": last, "alpha": 1.0}
	var ta := _times[i - 1]
	var tb := _times[i]
	return {
		"time": time, "a": _frames[i - 1], "b": _frames[i],
		"alpha": clampf((time - ta) / maxf(tb - ta, 0.000001), 0.0, 1.0),
	}


func oldest_time() -> float:
	return _times[0] if not _times.is_empty() else 0.0


func newest_time() -> float:
	return _times[_times.size() - 1] if not _times.is_empty() else 0.0


## Whether frames are held from [param from] to [param to].
func covers(from: float, to: float) -> bool:
	return not _times.is_empty() and oldest_time() <= from and newest_time() >= to


func frame_count() -> int:
	return _frames.size()


func event_count() -> int:
	return _events.size()


func clear() -> void:
	_times.clear()
	_frames.clear()
	_events.clear()


# One frame at or before the window's start is kept, so its first instant can still be sampled.
func _evict(now: float) -> void:
	var cut := now - window_seconds
	var drop := 0
	while drop + 1 < _times.size() and _times[drop + 1] <= cut:
		drop += 1
	drop = maxi(drop, _times.size() - max_frames)
	if drop > 0:
		_times = _times.slice(drop)
		_frames = _frames.slice(drop)
	while not _events.is_empty() and (float(_events[0]["time"]) < cut or _events.size() > max_events):
		_events.pop_front()


func describe() -> Dictionary:
	return {
		"frames": _frames.size(), "events": _events.size(), "refused": _refused,
		"from": oldest_time(), "to": newest_time(), "window_seconds": window_seconds,
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"killcam buffer: %d frame(s) %.2f-%.2f s, %d event(s), window %.1f s, %d refused" % [
			_frames.size(), oldest_time(), newest_time(), _events.size(), window_seconds, _refused,
		],
	])
