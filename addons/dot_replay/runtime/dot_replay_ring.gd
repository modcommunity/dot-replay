class_name DotReplayRing
extends RefCounted

## The last N seconds of a match in memory, for "save that". Kept back to the keyframe at or before
## the window start so a clip begins with a whole state; [member max_bytes] wins over that and the
## clip's meta says so.

const CHANNEL := "replay"

## How much match to keep, in ticks. Set from seconds by [method DotReplayRecorder.configure].
var window_ticks: int = 3840

## The most memory the ring may hold, in stored (compressed) bytes.
var max_bytes: int = 32 << 20

var _chunks: Array[DotReplayChunk] = []
var _bytes: int = 0
var _dropped_for_bytes: int = 0


func push(chunk: DotReplayChunk) -> void:
	_chunks.append(chunk)
	_bytes += chunk.frame_size()
	_evict()


func _evict() -> void:
	if _chunks.size() < 2:
		return
	var window_start := _chunks[_chunks.size() - 1].last_tick - window_ticks

	var keep_from := -1
	for i in range(_chunks.size()):
		var c := _chunks[i]
		if c.first_tick > window_start:
			break
		if c.starts_with_keyframe():
			keep_from = i
	if keep_from > 0:
		for i in range(keep_from):
			_drop_front()
	elif keep_from < 0:
		# No keyframe covers the window's start; keep only what the window needs.
		while _chunks.size() > 1 and _chunks[1].first_tick <= window_start:
			_drop_front()

	while _bytes > max_bytes and _chunks.size() > 1:
		_drop_front()
		# Said once, then counted: a ring that has reached its ceiling stays there, and a
		# line per chunk from then on is a line per second forever. describe_lines has the count.
		if _dropped_for_bytes == 0:
			DotLog.debug(CHANNEL, "ring reached its byte ceiling; the oldest chunks now go first", {
				"max_bytes": max_bytes, "window_ticks": window_ticks,
			})
		_dropped_for_bytes += 1


func _drop_front() -> void:
	var c: DotReplayChunk = _chunks.pop_front()
	_bytes -= c.frame_size()


func clear() -> void:
	_chunks.clear()
	_bytes = 0


func bytes_held() -> int:
	return _bytes


func chunk_count() -> int:
	return _chunks.size()


func first_tick() -> int:
	return _chunks[0].first_tick if not _chunks.is_empty() else 0


func last_tick() -> int:
	return _chunks[_chunks.size() - 1].last_tick if not _chunks.is_empty() else 0


func starts_with_keyframe() -> bool:
	return not _chunks.is_empty() and _chunks[0].starts_with_keyframe()


## Writes the last [param seconds] held (0: all) to [param path] as a complete replay; returns the
## writer's evidence. It starts at the keyframe at or before that moment, so it may run longer.
func save(
	path: String,
	header: DotReplayHeader,
	seconds: float = 0.0,
	key: PackedByteArray = PackedByteArray()
) -> DotResult:
	if _chunks.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "The ring holds nothing to save yet.")

	var start := 0
	if seconds > 0.0:
		var from_tick := last_tick() - int(ceil(seconds * header.tick_rate))
		for i in range(_chunks.size()):
			if _chunks[i].first_tick > from_tick:
				break
			if _chunks[i].starts_with_keyframe() or i == 0:
				start = i

	var clip_header := header.clone()
	clip_header.meta["clip"] = {
		"from_tick": _chunks[start].first_tick,
		"to_tick": last_tick(),
		"starts_at_keyframe": _chunks[start].starts_with_keyframe(),
	}
	var w := DotReplayWriter.new()
	var opened := w.open(path, clip_header, key)
	if not opened.ok:
		return opened
	for i in range(start, _chunks.size()):
		var wrote := w.write_chunk(_chunks[i])
		if not wrote.ok:
			w.abandon()
			return wrote
	var done := w.finish()
	if done.ok:
		DotLog.info(CHANNEL, "clip saved", {
			"path": path, "ticks": [_chunks[start].first_tick, last_tick()],
			"chunks": _chunks.size() - start,
		})
	return done


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"replay ring: %d chunk(s), ticks %d-%d, %d of %d bytes, window %d ticks%s%s" % [
			_chunks.size(), first_tick(), last_tick(), _bytes, max_bytes, window_ticks,
			"" if starts_with_keyframe() or _chunks.is_empty() else ", NOT starting at a keyframe",
			", %d chunk(s) dropped for bytes" % _dropped_for_bytes if _dropped_for_bytes > 0 else "",
		],
	])
