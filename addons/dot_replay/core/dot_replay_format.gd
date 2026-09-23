class_name DotReplayFormat
extends RefCounted

## The file format's constants and the few pure functions every piece shares.
##
## [codeblock]
## file    := preamble header header_hash chunk* [index footer]
## preamble:= "DRPL" u16 version  u16 flags  u32 header_len          (12 bytes)
## header  := var_to_bytes(Dictionary)                              (header_len bytes)
## header_hash := H(preamble || header)                             (32)  -- h0
##
## chunk   := "CHNK" u32 seq  u64 first_tick  u64 last_tick  u32 count
##            u8 chunk_flags  u8 compression  u32 raw_size  u32 stored_size   (38)
##            stored[stored_size]
##            h_i := H(h_{i-1} || the 38 bytes || stored)          (32)
##
## index   := "INDX" u32 n  { u64 offset u64 first u64 last u32 count u8 flags h_i }*n
## footer  := "FOOT" u64 index_offset  u32 n  u64 last_tick
##            H(h_n || index || the 24 bytes before this hash)    (32)  "LPRD"   (60)
## [/codeblock]
##
## Little-endian throughout, because [FileAccess] and [StreamPeerBuffer] both default to
## it and a mismatch between the two would be a bug only a big-endian reader could find.
##
## [b]Why the hashes are a chain rather than one per chunk.[/b] A hash per chunk detects a
## chunk that was edited. It does not detect one that was removed, duplicated or moved,
## because each of those is still a chunk with a correct hash — and cutting thirty seconds
## out of the middle of a demo is exactly the tamper that matters for moderation evidence.
## Each hash covers the one before it, so every chunk vouches for its whole prefix and the
## footer vouches for the whole file.
##
## [b]What the chain cannot do, said here so nobody claims it.[/b] An unkeyed SHA-256 is
## tamper-EVIDENT against an accident or a careless edit, not against somebody who
## recomputes the chain after editing. Two answers, and a moderation workflow should use
## at least one: record [method DotReplayWriter.evidence]'s final hash somewhere the
## file's holder cannot write (a punishment record's evidence), or record with a key
## ([constant FLAG_KEYED]), which makes the chain an HMAC that only the key's holder can
## produce. Neither detects a file cut short AND stripped of its footer — that is
## indistinguishable from a crash, which is the case this format exists to survive. The
## final hash recorded elsewhere is what tells the two apart.

const MAGIC_FILE := "DRPL"
const MAGIC_CHUNK := "CHNK"
const MAGIC_INDEX := "INDX"
const MAGIC_FOOTER := "FOOT"
const MAGIC_END := "LPRD"

## The only version this build writes, and the newest it reads.
##
## A reader refuses a newer file rather than guessing, because a newer writer may have
## changed what a chunk means and a replay played wrongly is worse than one refused with a
## reason. Older versions will be read here when there are any.
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


## True if [param value] is, or contains at any depth, something [code]var_to_bytes[/code]
## cannot put in a file honestly: an Object, a Callable, a Signal or an RID.
##
## [code]var_to_bytes[/code] does not refuse an object — it writes an id that means
## nothing in any other process — so the refusal has to be ours. A structure nested
## deeper than 64 is refused as well: it is a Dictionary containing itself, or near enough.
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


## [param value] with everything [method contains_object] objects to replaced, so an
## event carrying a session object can still be recorded. An object with a [code]
## describe()[/code] becomes what that returns (one level, then plain), anything else of
## the four becomes null. Bounded in depth, because a Dictionary can contain itself.
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
