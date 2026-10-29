class_name DotReplayChunk
extends RefCounted

## A run of records, compressed together: the unit of loss (a crash costs one chunk) and of seeking
## (a keyframe starts a chunk). Self-contained: channel names travel inside, since a streamed
## header cannot be rewritten when a new channel appears.

var seq: int = 0
var first_tick: int = 0
var last_tick: int = 0
var count: int = 0
var flags: int = 0
var compression: int = DotReplayFormat.COMPRESSION_NONE
var raw_size: int = 0
var stored: PackedByteArray = PackedByteArray()

## This chunk's link in the hash chain, once it has been framed or verified.
var chain_hash: PackedByteArray = PackedByteArray()


func starts_with_keyframe() -> bool:
	return flags & DotReplayFormat.CHUNK_KEYFRAME != 0


## Encodes and compresses [param records] (tick order, non-empty) into a chunk.
## Stored raw when compression does not shrink it (tiny random payloads can grow).
static func build(records: Array[DotReplayRecord], compression_mode: int) -> DotReplayChunk:
	var c := DotReplayChunk.new()
	c.first_tick = records[0].tick
	c.last_tick = records[records.size() - 1].tick
	c.count = records.size()
	if records[0].is_keyframe():
		c.flags |= DotReplayFormat.CHUNK_KEYFRAME

	var names: Array[StringName] = []
	var index_of: Dictionary = {}
	for r in records:
		if not index_of.has(r.channel):
			index_of[r.channel] = names.size()
			names.append(r.channel)

	var b := StreamPeerBuffer.new()
	b.put_u16(names.size())
	for n in names:
		b.put_utf8_string(String(n))
	for r in records:
		b.put_u32(r.tick - c.first_tick)
		b.put_u16(int(index_of[r.channel]))
		b.put_u8(r.flags)
		b.put_u32(r.data.size())
		if not r.data.is_empty():
			b.put_data(r.data)

	var raw := b.data_array
	c.raw_size = raw.size()
	c.compression = DotReplayFormat.COMPRESSION_NONE
	c.stored = raw
	if compression_mode != DotReplayFormat.COMPRESSION_NONE and not raw.is_empty():
		var packed := raw.compress(compression_mode)
		if not packed.is_empty() and packed.size() < raw.size():
			c.compression = compression_mode
			c.stored = packed
	return c


## The 38 bytes that precede the stored payload.
func prefix_bytes() -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_data(DotReplayFormat.ascii(DotReplayFormat.MAGIC_CHUNK))
	b.put_u32(seq)
	b.put_u64(first_tick)
	b.put_u64(last_tick)
	b.put_u32(count)
	b.put_u8(flags)
	b.put_u8(compression)
	b.put_u32(raw_size)
	b.put_u32(stored.size())
	return b.data_array


## What [member chain_hash] must be, given the link before this one.
func compute_hash(previous: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	return DotReplayFormat.digest(key, [previous, prefix_bytes(), stored])


## The whole frame as it goes into a file: prefix, payload, hash. Sets [member seq] and
## [member chain_hash], because both depend on where in which file the chunk lands — the
## same chunk saved into a clip gets a different sequence number and a different link.
func frame(p_seq: int, previous: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	seq = p_seq
	chain_hash = compute_hash(previous, key)
	var out := prefix_bytes()
	out.append_array(stored)
	out.append_array(chain_hash)
	return out


## Parses a 38-byte prefix. The stored payload and the hash are the caller's to read,
## because only the caller knows whether they are all there.
static func parse_prefix(bytes: PackedByteArray) -> DotResult:
	if bytes.size() < DotReplayFormat.CHUNK_PREFIX_SIZE:
		return DotResult.fail(DotError.CODE_PARSE, "A chunk header is shorter than 38 bytes.")
	if bytes.slice(0, 4).get_string_from_ascii() != DotReplayFormat.MAGIC_CHUNK:
		return DotResult.fail(DotError.CODE_PARSE, "Not a chunk: the magic is wrong.")
	var b := StreamPeerBuffer.new()
	b.data_array = bytes.slice(4, DotReplayFormat.CHUNK_PREFIX_SIZE)
	var c := DotReplayChunk.new()
	c.seq = b.get_u32()
	c.first_tick = b.get_u64()
	c.last_tick = b.get_u64()
	c.count = b.get_u32()
	c.flags = b.get_u8()
	c.compression = b.get_u8()
	c.raw_size = b.get_u32()
	var stored_size := b.get_u32()
	# The payload is not read here; stash its declared size in the meantime.
	c.stored.resize(0)
	return DotResult.success([c, stored_size])


## Decompresses and decodes the records. [param max_raw_bytes] bounds the allocation before
## decompressing, because the declared raw size is attacker-controlled in an unkeyed file.
func decode_records(max_raw_bytes: int) -> DotResult:
	if raw_size > max_raw_bytes:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"A chunk declares more data than this reader will unpack.",
			"chunk %d: %d bytes, limit %d" % [seq, raw_size, max_raw_bytes]
		)
	if not DotReplayFormat.is_known_compression(compression):
		return DotResult.fail(
			DotError.CODE_VERSION,
			"A chunk uses a compression this build does not know.",
			"chunk %d: mode %d" % [seq, compression]
		)

	var raw := stored
	if compression != DotReplayFormat.COMPRESSION_NONE:
		raw = stored.decompress(raw_size, compression)
	if raw.size() != raw_size:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"A chunk did not decompress to the size it declared.",
			"chunk %d: %d of %d bytes" % [seq, raw.size(), raw_size]
		)

	var b := StreamPeerBuffer.new()
	b.data_array = raw
	if b.get_available_bytes() < 2:
		return _malformed("no channel table")
	var name_count := b.get_u16()
	var names: Array[StringName] = []
	for i in range(name_count):
		if b.get_available_bytes() < 4:
			return _malformed("channel table cut short")
		var length := b.get_u32()
		if length > b.get_available_bytes():
			return _malformed("channel name longer than the chunk")
		var name_bytes: PackedByteArray = b.get_data(length)[1]
		names.append(StringName(name_bytes.get_string_from_utf8()))

	var out: Array[DotReplayRecord] = []
	for i in range(count):
		if b.get_available_bytes() < 11:
			return _malformed("record %d cut short" % i)
		var delta := b.get_u32()
		var channel_index := b.get_u16()
		var record_flags := b.get_u8()
		var size := b.get_u32()
		if channel_index >= names.size():
			return _malformed("record %d names channel %d of %d" % [i, channel_index, names.size()])
		if size > b.get_available_bytes():
			return _malformed("record %d is longer than the chunk" % i)
		var data := PackedByteArray()
		if size > 0:
			data = b.get_data(size)[1]
		out.append(DotReplayRecord.new(first_tick + delta, names[channel_index], data, record_flags))
	return DotResult.success(out)


func _malformed(what: String) -> DotResult:
	return DotResult.fail(DotError.CODE_PARSE, "A chunk's records are malformed.", "chunk %d: %s" % [seq, what])


## Bytes this chunk occupies in a file or in memory.
func frame_size() -> int:
	return DotReplayFormat.CHUNK_PREFIX_SIZE + stored.size() + DotReplayFormat.HASH_SIZE


func describe() -> Dictionary:
	return {
		"seq": seq, "ticks": [first_tick, last_tick], "records": count,
		"keyframe": starts_with_keyframe(),
		"compression": DotReplayFormat.compression_name(compression),
		"raw": raw_size, "stored": stored.size(),
	}
