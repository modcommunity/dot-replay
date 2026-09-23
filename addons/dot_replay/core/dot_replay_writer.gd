class_name DotReplayWriter
extends RefCounted

## Streams chunks to a file, one flushed chunk at a time, and finishes it with an index.
##
## [b]Every chunk is flushed as it is written[/b], so what is on disk is always a valid
## prefix of the file: a header and some whole chunks, plus at worst part of the next one.
## [DotReplayFile] reads that back up to the last whole chunk. The index and footer are
## written only by [method finish], so their absence is how a reader knows the recorder
## never got there.
##
## [b]In a browser[/b], [code]user://[/code] is a mirror of IndexedDB that the engine
## persists on its own schedule, and a tab closed before it does loses what was written.
## So every flushed chunk is followed by [method DotWeb.sync_filesystem] — the same
## promise, one chunk lost at most, has to hold there too.

const CHANNEL := "replay"

var path: String = ""

## Refuse a chunk that would take the file past this many bytes. 0 is unbounded.
##
## A recorder left running on a server that nobody restarts for a month is a disk that
## fills; this is where it stops, cleanly, with a file that still plays.
var max_file_bytes: int = 0

var _file: FileAccess = null
var _key: PackedByteArray = PackedByteArray()
var _flags: int = 0
var _prev_hash: PackedByteArray = PackedByteArray()
var _header_hash: PackedByteArray = PackedByteArray()
var _entries: Array[Dictionary] = []
var _bytes_written: int = 0
var _last_tick: int = 0
var _first_tick: int = -1
var _final_hash: PackedByteArray = PackedByteArray()
var _finished: bool = false
var _web_sync: bool = false


## Creates [param p_path] and writes the header. [param key], if given, makes every hash
## in the file an HMAC; the reader then needs the same key.
func open(p_path: String, header: DotReplayHeader, key: PackedByteArray = PackedByteArray()) -> DotResult:
	if _file != null:
		return DotResult.fail(DotError.CODE_STATE, "This writer already has a file open.", path)
	var valid := header.validate()
	if not valid.ok:
		return valid

	var dir := p_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return DotResult.failure(DotError.from_engine(made, "creating %s" % dir))

	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return DotResult.failure(DotError.from_engine(FileAccess.get_open_error(), "opening %s" % p_path))

	path = p_path
	_file = f
	_key = key
	_flags = DotReplayFormat.FLAG_KEYED if not key.is_empty() else 0
	_web_sync = p_path.begins_with("user://")

	var header_bytes := header.to_bytes()
	var pre := DotReplayFormat.preamble(DotReplayFormat.VERSION, _flags, header_bytes.size())
	_header_hash = DotReplayFormat.digest(_key, [pre, header_bytes])
	_prev_hash = _header_hash

	var out := pre
	out.append_array(header_bytes)
	out.append_array(_header_hash)
	var wrote := _store(out)
	if not wrote.ok:
		return wrote
	DotLog.debug(CHANNEL, "replay file opened", {"path": path, "keyed": not key.is_empty()})
	return DotResult.success(self)


func is_open() -> bool:
	return _file != null and not _finished


## Appends one sealed chunk and flushes it.
func write_chunk(chunk: DotReplayChunk) -> DotResult:
	if not is_open():
		return DotResult.fail(DotError.CODE_STATE, "No replay file is open.")
	if max_file_bytes > 0:
		var after := _bytes_written + chunk.frame_size() + _tail_size(_entries.size() + 1)
		if after > max_file_bytes:
			return DotResult.fail(
				DotError.CODE_QUOTA,
				"The replay reached its size limit; the file is finished rather than grown.",
				"%s: %d bytes of %d" % [path, _bytes_written, max_file_bytes]
			)

	var offset := _bytes_written
	var framed := chunk.frame(_entries.size(), _prev_hash, _key)
	var wrote := _store(framed)
	if not wrote.ok:
		return wrote
	_prev_hash = chunk.chain_hash
	_entries.append({
		"offset": offset, "first": chunk.first_tick, "last": chunk.last_tick,
		"count": chunk.count, "flags": chunk.flags, "hash": chunk.chain_hash,
	})
	if _first_tick < 0:
		_first_tick = chunk.first_tick
	_last_tick = chunk.last_tick
	return DotResult.success(offset)


## Writes the index and footer and closes the file. Idempotent.
func finish() -> DotResult:
	if _finished:
		return DotResult.success(evidence())
	if _file == null:
		return DotResult.fail(DotError.CODE_STATE, "No replay file is open.")

	var index_offset := _bytes_written
	var index := StreamPeerBuffer.new()
	index.put_data(DotReplayFormat.ascii(DotReplayFormat.MAGIC_INDEX))
	index.put_u32(_entries.size())
	for e in _entries:
		index.put_u64(int(e["offset"]))
		index.put_u64(int(e["first"]))
		index.put_u64(int(e["last"]))
		index.put_u32(int(e["count"]))
		index.put_u8(int(e["flags"]))
		index.put_data(e["hash"] as PackedByteArray)

	var foot := StreamPeerBuffer.new()
	foot.put_data(DotReplayFormat.ascii(DotReplayFormat.MAGIC_FOOTER))
	foot.put_u64(index_offset)
	foot.put_u32(_entries.size())
	foot.put_u64(_last_tick)
	_final_hash = DotReplayFormat.digest(_key, [_prev_hash, index.data_array, foot.data_array])

	var tail := index.data_array
	tail.append_array(foot.data_array)
	tail.append_array(_final_hash)
	tail.append_array(DotReplayFormat.ascii(DotReplayFormat.MAGIC_END))
	var wrote := _store(tail)
	_file.close()
	_file = null
	_finished = true
	if not wrote.ok:
		return wrote
	DotLog.info(CHANNEL, "replay finished", {
		"path": path, "chunks": _entries.size(), "bytes": _bytes_written,
		"ticks": [maxi(_first_tick, 0), _last_tick],
	})
	return DotResult.success(evidence())


## Closes the file WITHOUT an index or footer — what a crash leaves behind. For tests and
## for a host that is being torn down and has no time to finish; a reader recovers it.
func abandon() -> void:
	if _file != null:
		_file.close()
		_file = null


## What a moderation record should keep about this file, once it is finished.
##
## The final hash is the part that matters. The file can be copied, moved and renamed; if
## the hash recorded at the time of the punishment still matches, nobody edited it since.
## It is a plain Dictionary so it drops straight into a punishment's evidence field
## without this addon knowing what a punishment is.
func evidence() -> Dictionary:
	return {
		"replay": path,
		"final_hash": _final_hash.hex_encode(),
		"keyed": _flags & DotReplayFormat.FLAG_KEYED != 0,
		"chunks": _entries.size(),
		"first_tick": maxi(_first_tick, 0),
		"last_tick": _last_tick,
		"bytes": _bytes_written,
	}


func bytes_written() -> int:
	return _bytes_written


func chunk_count() -> int:
	return _entries.size()


func _tail_size(entries: int) -> int:
	return 8 + entries * DotReplayFormat.INDEX_ENTRY_SIZE + DotReplayFormat.FOOTER_SIZE


func _store(bytes: PackedByteArray) -> DotResult:
	if not _file.store_buffer(bytes):
		return DotResult.fail(DotError.CODE_IO, "The replay file could not be written.", path)
	_file.flush()
	_bytes_written += bytes.size()
	if _web_sync:
		DotWeb.sync_filesystem()
	return DotResult.success(bytes.size())


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"replay writer: %s, %d chunk(s), %d bytes%s%s" % [
			path if path != "" else "(nothing open)", _entries.size(), _bytes_written,
			", finished" if _finished else "",
			", limit %d" % max_file_bytes if max_file_bytes > 0 else "",
		],
	])
