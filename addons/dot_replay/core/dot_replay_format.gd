class_name DotReplayFormat
extends RefCounted

## The file format's constants and the few pure functions every piece shares.
## Layout, little-endian choice and what the hash chain does and does not prove:
## docs/design.md, file layout.

const MAGIC_FILE := "DRPL"
const MAGIC_CHUNK := "CHNK"
const MAGIC_INDEX := "INDX"
const MAGIC_FOOTER := "FOOT"
const MAGIC_END := "LPRD"

## The only version this build writes, and the newest it reads; a newer file is refused,
## since a newer writer may have changed what a chunk means.
const VERSION := 1

## File flag: every hash in the file is an HMAC-SHA256 under a key the writer held.
const FLAG_KEYED := 1 << 0

## Chunk flag: the chunk's first record is a keyframe. Seeking starts only at one of these.
const CHUNK_KEYFRAME := 1 << 0

const HASH_SIZE := 32
const PREAMBLE_SIZE := 12
const CHUNK_PREFIX_SIZE := 38
const INDEX_ENTRY_SIZE := 8 + 8 + 8 + 4 + 1 + HASH_SIZE
const FOOTER_SIZE := 4 + 8 + 4 + 8 + HASH_SIZE + 4

## Chunk compression. The values are the engine's own [code]FileAccess.COMPRESSION_*[/code]
## so they go straight to [method PackedByteArray.compress]; NONE is ours.
const COMPRESSION_FASTLZ := 0
const COMPRESSION_DEFLATE := 1
const COMPRESSION_ZSTD := 2
const COMPRESSION_GZIP := 3
const COMPRESSION_NONE := 255

## The channel keyframes are written on. Refused as a record channel, so a keyframe cannot
## be forged by a game that happened to pick the same name.
const KEYFRAME_CHANNEL := &"keyframe"

## A header larger than this is refused before it is read. A real one is a few hundred
## bytes; the bound exists so a crafted length cannot make a reader allocate gigabytes.
const MAX_HEADER_BYTES := 1 << 20


## Parses a compression name ("zstd", "deflate", "gzip", "fastlz", "none"). -1 if unknown.
static func compression_from_name(name: String) -> int:
	match name.strip_edges().to_lower():
		"zstd": return COMPRESSION_ZSTD
		"deflate": return COMPRESSION_DEFLATE
		"gzip": return COMPRESSION_GZIP
		"fastlz": return COMPRESSION_FASTLZ
		"none", "": return COMPRESSION_NONE
	return -1


static func compression_name(mode: int) -> String:
	match mode:
		COMPRESSION_ZSTD: return "zstd"
		COMPRESSION_DEFLATE: return "deflate"
		COMPRESSION_GZIP: return "gzip"
		COMPRESSION_FASTLZ: return "fastlz"
		COMPRESSION_NONE: return "none"
	return "unknown(%d)" % mode


static func is_known_compression(mode: int) -> bool:
	return mode in [
		COMPRESSION_NONE, COMPRESSION_ZSTD, COMPRESSION_DEFLATE,
		COMPRESSION_GZIP, COMPRESSION_FASTLZ,
	]


## SHA-256, or HMAC-SHA256 when [param key] is not empty, over the concatenated parts.
static func digest(key: PackedByteArray, parts: Array[PackedByteArray]) -> PackedByteArray:
	var joined := PackedByteArray()
	for p in parts:
		joined.append_array(p)
	if not key.is_empty():
		return DotHash.hmac_sha256(key, joined)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	# update() errors on an empty buffer; the joined parts are never empty in this
	# format (a preamble alone is twelve bytes), but a guard costs nothing.
	if not joined.is_empty():
		ctx.update(joined)
	return ctx.finish()


static func ascii(s: String) -> PackedByteArray:
	return s.to_ascii_buffer()


## True if [param value] holds, at any depth, an Object, Callable, Signal or RID, which
## [code]var_to_bytes[/code] would write as a meaningless id. Nesting past 64 is refused.
static func contains_object(value: Variant, depth: int = 0) -> bool:
	if depth > 64:
		return true
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return true
		TYPE_ARRAY:
			for v in value as Array:
				if contains_object(v, depth + 1):
					return true
		TYPE_DICTIONARY:
			var d := value as Dictionary
			for k in d.keys():
				if contains_object(k, depth + 1) or contains_object(d[k], depth + 1):
					return true
	return false


## The 12-byte preamble.
static func preamble(version: int, flags: int, header_len: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_data(ascii(MAGIC_FILE))
	b.put_u16(version)
	b.put_u16(flags)
	b.put_u32(header_len)
	return b.data_array


## [param value] with what [method contains_object] objects to replaced: an Object's
## [code]describe()[/code] (one level), else null. Depth-bounded.
static func plain(value: Variant, depth: int = 0) -> Variant:
	if depth > 16:
		return null
	match typeof(value):
		TYPE_OBJECT:
			var o := value as Object
			if o != null and depth < 2 and o.has_method("describe"):
				return plain(o.call("describe"), depth + 1)
			return null
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return null
		TYPE_ARRAY:
			var out: Array = []
			for v in value as Array:
				out.append(plain(v, depth + 1))
			return out
		TYPE_DICTIONARY:
			var d := value as Dictionary
			var out2: Dictionary = {}
			for k in d.keys():
				if contains_object(k):
					continue
				out2[k] = plain(d[k], depth + 1)
			return out2
	return value
