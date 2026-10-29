class_name DotReplayFile
extends RefCounted

## Reads a replay: header, chunk list, any chunk's records on demand. Complete (footer, index used),
## truncated (no footer: a success with [member truncated] set) or refused ([code]CODE_INTEGRITY[/code]).
## What each case means: docs/design.md, file layout.

const CHANNEL := "replay"

var path: String = ""
var header: DotReplayHeader = null
var version: int = 0
var keyed: bool = false

## The footer was present and verified.
var complete: bool = false

## The file ends before a footer: it was not finished. Everything in [method chunk_count]
## is whole and verified; anything after it was lost.
var truncated: bool = false

## Bytes of chunk after the last whole one: what a crash mid-chunk lost. A partial index
## or footer is not counted, because it holds no records.
var trailing_bytes: int = 0

## The largest chunk this reader will decompress. See [method DotReplayChunk.decode_records].
var max_chunk_raw_bytes: int = 64 << 20

## The final hash from the footer, hex. Empty for a truncated file.
var final_hash: String = ""

var _key: PackedByteArray = PackedByteArray()
var _header_hash: PackedByteArray = PackedByteArray()
var _chunks: Array[DotReplayChunk] = []
var _offsets: PackedInt64Array = PackedInt64Array()
var _verified: Array[bool] = []
var _cache_index: int = -1
var _cache: Array[DotReplayRecord] = []


## Opens and checks [param p_path]. [param verify] hashes every chunk now; without it a complete
## file is trusted to its footer and [method read_chunk] still refuses an edited chunk when read.
func open(p_path: String, key: PackedByteArray = PackedByteArray(), verify: bool = true) -> DotResult:
	path = p_path
	_key = key
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return DotResult.failure(DotError.from_engine(FileAccess.get_open_error(), "opening %s" % p_path))
	var r := _open(f, verify)
	f.close()
	if r.ok:
		DotLog.debug(CHANNEL, "replay opened", {
			"path": path, "chunks": _chunks.size(), "complete": complete, "truncated": truncated,
		})
	else:
		DotLog.warn(CHANNEL, "replay refused", {"path": path, "code": r.code(), "why": str(r.error)})
	return r


func _open(f: FileAccess, verify: bool) -> DotResult:
	var length := f.get_length()
	if length < DotReplayFormat.PREAMBLE_SIZE:
		return DotResult.fail(DotError.CODE_PARSE, "Too short to be a replay.", path)
	var pre := f.get_buffer(DotReplayFormat.PREAMBLE_SIZE)
	if pre.slice(0, 4).get_string_from_ascii() != DotReplayFormat.MAGIC_FILE:
		return DotResult.fail(DotError.CODE_PARSE, "Not a replay: the magic is wrong.", path)
	var pb := StreamPeerBuffer.new()
	pb.data_array = pre.slice(4)
	version = pb.get_u16()
	var flags := pb.get_u16()
	var header_len := pb.get_u32()
	if version > DotReplayFormat.VERSION or version < 1:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This replay was written by a format version this build does not read.",
			"%s: version %d, this build reads 1 to %d" % [path, version, DotReplayFormat.VERSION]
		)
	keyed = flags & DotReplayFormat.FLAG_KEYED != 0
	if keyed and _key.is_empty():
		return DotResult.fail(
			DotError.CODE_AUTH,
			"This replay was recorded with a key, and it cannot be verified without one.",
			path
		)
	if not keyed and not _key.is_empty():
		# Accepting it would make "verified under the key" mean nothing: anybody can write
		# an unkeyed file.
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"A key was given but this replay was recorded without one.",
			path
		)
	if header_len > DotReplayFormat.MAX_HEADER_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "The replay header is implausibly large.", "%d bytes" % header_len)
	var header_end := DotReplayFormat.PREAMBLE_SIZE + header_len + DotReplayFormat.HASH_SIZE
	if length < header_end:
		return DotResult.fail(DotError.CODE_PARSE, "The file ends inside its header.", path)

	var header_bytes := f.get_buffer(header_len)
	var stored_hash := f.get_buffer(DotReplayFormat.HASH_SIZE)
	_header_hash = DotReplayFormat.digest(_key, [pre, header_bytes])
	if not DotHash.constant_time_equal(_header_hash, stored_hash):
		# Under a key the two causes look identical from here, so the message names both
		# rather than calling a moderator's mistyped key an edited file.
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"The replay header does not match its hash under this key: the key is wrong, or the file was edited."
				if keyed else "The replay header does not match its hash.",
			path
		)
	var hr := DotReplayHeader.from_bytes(header_bytes)
	if not hr.ok:
		return hr.wrap("The replay header could not be read.")
	header = hr.value as DotReplayHeader

	var footer := _read_footer(f, header_end, length)
	if not footer.ok:
		return footer
	if footer.value == true:
		complete = true
		if verify:
			for i in range(_chunks.size()):
				var v := _verify_chunk(f, i)
				if not v.ok:
					return v
		return DotResult.success(self)

	var scanned := _scan(f, header_end, length)
	if not scanned.ok:
		return scanned
	return DotResult.success(self)


## Reads the index through the footer. Success(true) if the file is complete, success(false)
## if there is no footer at all, failure if there is one and it does not add up.
func _read_footer(f: FileAccess, header_end: int, length: int) -> DotResult:
	if length < header_end + DotReplayFormat.FOOTER_SIZE + 8:
		return DotResult.success(false)
	f.seek(length - DotReplayFormat.FOOTER_SIZE)
	var foot := f.get_buffer(DotReplayFormat.FOOTER_SIZE)
	if foot.slice(0, 4).get_string_from_ascii() != DotReplayFormat.MAGIC_FOOTER:
		return DotResult.success(false)
	if foot.slice(DotReplayFormat.FOOTER_SIZE - 4).get_string_from_ascii() != DotReplayFormat.MAGIC_END:
		return DotResult.success(false)

	# From here on a footer is present, so anything inconsistent is an edit rather than a
	# crash: a crash does not write a footer.
	var fb := StreamPeerBuffer.new()
	fb.data_array = foot.slice(4, 24)
	var index_offset := fb.get_u64()
	var n := fb.get_u32()
	var last_tick := fb.get_u64()
	var foot_fields := foot.slice(0, 24)
	var foot_hash := foot.slice(24, 24 + DotReplayFormat.HASH_SIZE)

	var index_len := 8 + n * DotReplayFormat.INDEX_ENTRY_SIZE
	if index_offset < header_end or index_offset + index_len != length - DotReplayFormat.FOOTER_SIZE:
		return DotResult.fail(DotError.CODE_INTEGRITY, "The replay's footer does not describe its index.", path)
	f.seek(index_offset)
	var index := f.get_buffer(index_len)
	if index.slice(0, 4).get_string_from_ascii() != DotReplayFormat.MAGIC_INDEX:
		return DotResult.fail(DotError.CODE_INTEGRITY, "The replay's footer points at something that is not its index.", path)

	var ib := StreamPeerBuffer.new()
	ib.data_array = index.slice(4)
	if ib.get_u32() != n:
		return DotResult.fail(DotError.CODE_INTEGRITY, "The replay's index and footer disagree about its length.", path)
	var chunks: Array[DotReplayChunk] = []
	var offsets := PackedInt64Array()
	var last_hash := _header_hash
	var expected_offset := header_end
	for i in range(n):
		var c := DotReplayChunk.new()
		var offset := ib.get_u64()
		c.seq = i
		c.first_tick = ib.get_u64()
		c.last_tick = ib.get_u64()
		c.count = ib.get_u32()
		c.flags = ib.get_u8()
		c.chain_hash = ib.get_data(DotReplayFormat.HASH_SIZE)[1]
		if offset < expected_offset or offset >= index_offset:
			return DotResult.fail(DotError.CODE_INTEGRITY, "The replay's index points past its chunks.", path)
		chunks.append(c)
		offsets.append(offset)
		last_hash = c.chain_hash
		expected_offset = offset + DotReplayFormat.CHUNK_PREFIX_SIZE + DotReplayFormat.HASH_SIZE

	var expect := DotReplayFormat.digest(_key, [last_hash, index, foot_fields])
	if not DotHash.constant_time_equal(expect, foot_hash):
		return DotResult.fail(DotError.CODE_INTEGRITY, "The replay's footer does not match its contents.", path)

	_chunks = chunks
	_offsets = offsets
	_verified.resize(n)
	_verified.fill(false)
	final_hash = foot_hash.hex_encode()
	if n > 0 and last_tick != chunks[n - 1].last_tick:
		return DotResult.fail(DotError.CODE_INTEGRITY, "The replay's footer and index disagree about where it ends.", path)
	return DotResult.success(true)


## Walks the chunks from the front, keeping every whole one and stopping at the first
## that is not. See the class notes for why a whole chunk with a bad hash is a refusal and
## a partial one is not.
func _scan(f: FileAccess, header_end: int, length: int) -> DotResult:
	truncated = true
	var pos := header_end
	var prev := _header_hash
	while true:
		if length - pos < DotReplayFormat.CHUNK_PREFIX_SIZE:
			trailing_bytes = length - pos
			break
		f.seek(pos)
		var prefix := f.get_buffer(DotReplayFormat.CHUNK_PREFIX_SIZE)
		var magic := prefix.slice(0, 4).get_string_from_ascii()
		if magic == DotReplayFormat.MAGIC_INDEX:
# The index began and the footer never landed: every chunk is whole, so nothing is lost.
			trailing_bytes = 0
			break
		var parsed := DotReplayChunk.parse_prefix(prefix)
		if not parsed.ok:
			return DotResult.fail(
				DotError.CODE_INTEGRITY,
				"The replay has something that is not a chunk where a chunk should be.",
				"%s: offset %d" % [path, pos]
			)
		var c: DotReplayChunk = parsed.value[0]
		var stored_size: int = parsed.value[1]
		var frame_len := DotReplayFormat.CHUNK_PREFIX_SIZE + stored_size + DotReplayFormat.HASH_SIZE
		if length - pos < frame_len:
			# The chunk the crash interrupted.
			trailing_bytes = length - pos
			break
		c.stored = f.get_buffer(stored_size)
		var stored_hash := f.get_buffer(DotReplayFormat.HASH_SIZE)
		c.chain_hash = c.compute_hash(prev, _key)
		if c.seq != _chunks.size() or not DotHash.constant_time_equal(c.chain_hash, stored_hash):
			return DotResult.fail(
				DotError.CODE_INTEGRITY,
				"A replay chunk does not match its hash.",
				"%s: chunk %d at offset %d" % [path, _chunks.size(), pos]
			)
		prev = c.chain_hash
		c.stored = PackedByteArray()  # read again on demand; do not hold the whole file
		_chunks.append(c)
		_offsets.append(pos)
		_verified.append(true)
		pos += frame_len
	DotLog.info(CHANNEL, "replay was not finished; playing what is whole", {
		"path": path, "chunks": _chunks.size(), "lost_bytes": trailing_bytes,
	})
	return DotResult.success(self)


## Reads chunk [param i] from [param f] and checks it against the chain. Returns the chunk
## with its payload loaded.
func _verify_chunk(f: FileAccess, i: int) -> DotResult:
	var info := _chunks[i]
	f.seek(_offsets[i])
	var prefix := f.get_buffer(DotReplayFormat.CHUNK_PREFIX_SIZE)
	var parsed := DotReplayChunk.parse_prefix(prefix)
	if not parsed.ok:
		return DotResult.fail(DotError.CODE_INTEGRITY, "A replay chunk is not where its index says.", "%s: chunk %d" % [path, i])
	var c: DotReplayChunk = parsed.value[0]
	var stored_size: int = parsed.value[1]
	if c.seq != i or c.first_tick != info.first_tick or c.last_tick != info.last_tick \
			or c.count != info.count or c.flags != info.flags:
		return DotResult.fail(DotError.CODE_INTEGRITY, "A replay chunk disagrees with its index.", "%s: chunk %d" % [path, i])
	if _offsets[i] + DotReplayFormat.CHUNK_PREFIX_SIZE + stored_size + DotReplayFormat.HASH_SIZE > f.get_length():
		return DotResult.fail(DotError.CODE_INTEGRITY, "A replay chunk runs past the end of the file.", "%s: chunk %d" % [path, i])
	c.stored = f.get_buffer(stored_size)
	var stored_hash := f.get_buffer(DotReplayFormat.HASH_SIZE)
	var prev := _header_hash if i == 0 else _chunks[i - 1].chain_hash
	c.chain_hash = c.compute_hash(prev, _key)
	if not DotHash.constant_time_equal(c.chain_hash, stored_hash) \
			or not DotHash.constant_time_equal(c.chain_hash, info.chain_hash):
		return DotResult.fail(DotError.CODE_INTEGRITY, "A replay chunk does not match its hash.", "%s: chunk %d" % [path, i])
	_verified[i] = true
	return DotResult.success(c)



func chunk_count() -> int:
	return _chunks.size()


## The chunk's summary — ticks, count, keyframe flag — without its payload.
func chunk_info(i: int) -> DotReplayChunk:
	return _chunks[i]


## Where chunk [param i] begins in the file, in bytes.
func chunk_offset(i: int) -> int:
	return _offsets[i]


func first_tick() -> int:
	return _chunks[0].first_tick if not _chunks.is_empty() else 0


func last_tick() -> int:
	return _chunks[_chunks.size() - 1].last_tick if not _chunks.is_empty() else 0


## The records in chunk [param i], verified against the chain first.
func read_chunk(i: int) -> DotResult:
	if i < 0 or i >= _chunks.size():
		return DotResult.fail(DotError.CODE_INVALID, "No such chunk.", "%d of %d" % [i, _chunks.size()])
	if i == _cache_index:
		return DotResult.success(_cache)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return DotResult.failure(DotError.from_engine(FileAccess.get_open_error(), "opening %s" % path))
	var v := _verify_chunk(f, i)
	f.close()
	if not v.ok:
		DotLog.warn(CHANNEL, "replay chunk refused", {"path": path, "chunk": i, "why": str(v.error)})
		return v
	var decoded := (v.value as DotReplayChunk).decode_records(max_chunk_raw_bytes)
	if not decoded.ok:
		return decoded
	_cache_index = i
	_cache = decoded.value
	return decoded


## The chunk to start from to reach [param tick]: the last one that begins with a keyframe
## at or before it. -1 if there is none, and playback must start from the beginning.
func keyframe_chunk_for(tick: int) -> int:
	for i in range(_chunks.size() - 1, -1, -1):
		var c := _chunks[i]
		if c.starts_with_keyframe() and c.first_tick <= tick:
			return i
	return -1


## Every record in the file, in order. For tests and small files; playback reads chunks.
func read_all() -> DotResult:
	var out: Array[DotReplayRecord] = []
	for i in range(_chunks.size()):
		var r := read_chunk(i)
		if not r.ok:
			return r
		var records: Array[DotReplayRecord] = r.value
		out.append_array(records)
	return DotResult.success(out)


func describe() -> Dictionary:
	return {
		"path": path,
		"version": version,
		"keyed": keyed,
		"complete": complete,
		"truncated": truncated,
		"trailing_bytes": trailing_bytes,
		"chunks": _chunks.size(),
		"ticks": [first_tick(), last_tick()],
		"keyframes": _chunks.filter(func(c: DotReplayChunk) -> bool: return c.starts_with_keyframe()).size(),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	if header != null:
		lines.append_array(header.describe_lines())
	var d := describe()
	lines.append("%s: %d chunk(s), ticks %d-%d, %s%s" % [
		path, d["chunks"], first_tick(), last_tick(),
		"complete" if complete else "NOT FINISHED (%d byte(s) lost)" % trailing_bytes,
		", keyed" if keyed else "",
	])
	return lines
