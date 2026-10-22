@tool
class_name DotReplayConfig
extends DotConfig

## Where demos go, how they are cut up, and how much of them is kept.
##
## Layered like every config here, so an operator can turn a server's ring up for one
## tournament with [code]--replay-ring-seconds 300[/code] without editing a file. Times are
## in seconds rather than ticks because the operator does not know the tick rate a game
## chose; [method DotReplayRecorder.configure] converts with the header's.

## Where finished demos are written.
@export var directory: String = "user://replays"

## How much match one chunk holds, at most. This is also the most a crash can lose.
@export_range(0.1, 30.0, 0.1) var chunk_seconds: float = 1.0

## A chunk is sealed early once its records reach this size, whatever its duration.
@export_range(4, 16384, 1) var chunk_kib: int = 256

## How often the recorder asks the game for a keyframe. Seeking replays at most this much
## from the nearest one. 0 turns automatic keyframes off.
@export_range(0.0, 600.0, 0.5) var keyframe_seconds: float = 10.0

## "zstd", "deflate", "gzip", "fastlz" or "none".
@export var compression: String = "zstd"

## A demo stops growing here and is finished cleanly. 0 is unbounded.
@export_range(0, 1048576, 1) var max_file_mib: int = 512

## A single record larger than this is refused. A payload that big is a bug in the game
## recording it, and one would otherwise make a chunk of its own the size of a map.
@export_range(1, 65536, 1) var max_record_kib: int = 1024

## How much recent match the in-memory ring keeps for "save that". 0 turns it off.
@export_range(0.0, 3600.0, 1.0) var ring_seconds: float = 60.0

## The ring's hard ceiling, whatever [member ring_seconds] asks for.
@export_range(1, 4096, 1) var ring_max_mib: int = 32


func env_prefix() -> String:
	return "DOT_REPLAY_"


func cli_prefix() -> String:
	return "--replay-"


## The addon name [DotAddonConfig] turns into the folder `dot_replay`.
const CFG_ADDON := "dot-replay"


## Applies [param file_name] from `cfg/addons/dot_replay/`, then the operator's `cfg/server/addons/dot_replay/`.
## A flat [param legacy_dir]/[param file_name] is still read (one WARN) while no new copy exists.
## Keys not starting `replay_` belong to the deployment and are skipped; secrets stay file-only.
func apply_cfg_file(file_name: String = "replay.yml", legacy_dir: String = "res://cfg") -> DotResult:
	return DotAddonConfig.apply_file(CFG_ADDON, file_name, legacy_dir, _apply_cfg_values)


## The tunables a player may change, as the `user_cfg_files` entry a game appends
## (`platform.user_cfg_files.append(DotReplayConfig.user_cfg_entry())`). Keys carry the `replay_`
## prefix the file uses; ranges come from the exports so the editor and the config never disagree.
static func user_cfg_entry() -> Dictionary:
	var probe := DotReplayConfig.new()
	var schema: Array = []
	for prop in ["ring_seconds", "keyframe_seconds"]:
		var opts := {}
		for info in probe.get_property_list():
			if info["name"] == prop and info["hint"] == PROPERTY_HINT_RANGE:
				var parts := String(info["hint_string"]).split(",")
				opts = {"min": float(parts[0]), "max": float(parts[1])}
		schema.append(DotProfileSet.field("replay_" + prop, "float", probe.get(prop), opts))
	schema.append(DotProfileSet.field(
		"replay_compression", "string", probe.compression, {"enum": ["zstd", "deflate", "gzip", "fastlz", "none"]}
	))
	return {"addon": CFG_ADDON, "file": "replay.yml", "schema": schema, "label": "Replays"}


func _apply_cfg_values(values: Dictionary, path: String) -> PackedStringArray:
	var own := {}
	var keys := config_keys()
	for raw in values:
		var name := String(raw)
		if not name.begins_with("replay_"):
			continue
		var prop := name.trim_prefix("replay_")
		if keys.has(prop):
			own[prop] = values[raw]
	return apply_dictionary(own, path)


## [method apply_cfg_file], then the environment, the command line and validation.
func load_cfg(file_name: String = "replay.yml", legacy_dir: String = "res://cfg") -> DotResult:
	unknown_keys = PackedStringArray()
	var file_res := apply_cfg_file(file_name, legacy_dir)
	if not file_res.ok:
		return file_res
	apply_env()
	apply_cli()
	var valid := validate()
	if not valid.ok:
		return valid.wrap("Configuration is invalid.")
	return DotResult.success(self)


func validate() -> DotResult:
	if DotReplayFormat.compression_from_name(compression) < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Unknown replay compression.",
			"%s: use zstd, deflate, gzip, fastlz or none" % compression
		)
	if chunk_seconds <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A chunk must hold some time: it is the unit a crash loses.")
	if keyframe_seconds > 0.0 and keyframe_seconds < chunk_seconds:
		# A keyframe seals the chunk before it, so keyframing faster than chunking makes
		# every chunk shorter than configured and every seek cheaper than it needs to be,
		# at the cost of a full game state per keyframe. Refused rather than guessed at.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Keyframes more often than chunks would make every chunk a keyframe.",
			"keyframe_seconds=%s chunk_seconds=%s" % [keyframe_seconds, chunk_seconds]
		)
	return DotResult.success(self)


## A file name for a demo of [param header]: game, map and start time, and nothing a
## file system could object to.
func path_for(header: DotReplayHeader) -> String:
	var stamp := Time.get_datetime_string_from_unix_time(header.started_unix).replace(":", "").replace("-", "")
	var name := "%s_%s_%s" % [_safe(header.game), _safe(header.map), stamp]
	return directory.path_join(name + ".dreplay")


static func _safe(s: String) -> String:
	var out := ""
	for ch in s:
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-") else "_"
	return out if out != "" else "unnamed"


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	return PackedStringArray([
		"replay: to %s, %ss chunks (%d KiB max), keyframe every %ss, %s, file cap %s, ring %ss (%d MiB max)" % [
			directory, chunk_seconds, chunk_kib, keyframe_seconds, compression,
			"%d MiB" % max_file_mib if max_file_mib > 0 else "none",
			ring_seconds, ring_max_mib,
		],
	])
