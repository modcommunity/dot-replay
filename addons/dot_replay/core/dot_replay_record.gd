class_name DotReplayRecord
extends RefCounted

## One thing the server decided, at one tick, on one channel. The payload is opaque on purpose:
## only the game that wrote it can interpret it. A flag says whether the bytes are a
## [code]var_to_bytes[/code] Variant, for small structured events.

## The payload is [code]var_to_bytes[/code] of a Variant rather than raw bytes.
const FLAG_VARIANT := 1 << 0

## The record is a keyframe: the whole state at [member tick], not a change to it.
const FLAG_KEYFRAME := 1 << 1

var tick: int = 0
var channel: StringName = &""
var data: PackedByteArray = PackedByteArray()
var flags: int = 0


func _init(
	p_tick: int = 0,
	p_channel: StringName = &"",
	p_data: PackedByteArray = PackedByteArray(),
	p_flags: int = 0
) -> void:
	tick = p_tick
	channel = p_channel
	data = p_data
	flags = p_flags


func is_keyframe() -> bool:
	return flags & FLAG_KEYFRAME != 0


func is_variant() -> bool:
	return flags & FLAG_VARIANT != 0


## The payload as given: the Variant for a value record, the bytes otherwise. Decoded with
## [code]bytes_to_var[/code], never the with-objects form, since a replay may be untrusted evidence.
func value() -> Variant:
	if not is_variant():
		return data
	if data.is_empty():
		return null
	return bytes_to_var(data)


func size_bytes() -> int:
	return data.size()


func describe() -> Dictionary:
	return {
		"tick": tick,
		"channel": String(channel),
		"bytes": data.size(),
		"keyframe": is_keyframe(),
		"variant": is_variant(),
	}


func _to_string() -> String:
	return "DotReplayRecord(%d %s %dB%s)" % [
		tick, channel, data.size(), " keyframe" if is_keyframe() else ""
	]
