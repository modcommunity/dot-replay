class_name DotReplayHeader
extends RefCounted

## What a replay is of: the game, the map, the tick rate, when, who, and anything else.
##
## Written once, at the front of the file, before a single record — so a replay browser
## can list a directory of demos by reading a few hundred bytes of each, and so a file cut
## short by a crash still says what it was a recording of.
##
## [b]The player list is who was there at the start, and only that.[/b] A header cannot be
## rewritten without rewriting the file, and a streaming recorder has already written it by
## the time anybody joins. Joins and leaves are records like everything else; a game that
## wants a roster in playback records one on a channel of its own.

## The game's id, as the server resolved it.
var game: String = ""

## The map, as the server named it.
var map: String = ""

## Simulation ticks per second. Every tick in the file is in these units, and playback
## speed is measured against it.
var tick_rate: int = 64

## Wall-clock start, seconds since the Unix epoch, UTC.
var started_unix: int = 0

## Who was connected when recording began: one Dictionary each, whatever the game puts
## there (an id, a name, a team). Values must be plain data — see [method validate].
var players: Array = []

## Anything else: the server's name, a match id, a build, a round number.
var meta: Dictionary = {}

## Which recorder wrote it, so a bug report about a bad file names the version.
var recorder: String = "dot-replay/1"


static func make(
	p_game: String,
	p_map: String,
	p_tick_rate: int,
	p_players: Array = [],
	p_meta: Dictionary = {}
) -> DotReplayHeader:
	var h := DotReplayHeader.new()
	h.game = p_game
	h.map = p_map
	h.tick_rate = p_tick_rate
	h.started_unix = int(Time.get_unix_time_from_system())
	h.players = p_players.duplicate(true)
	h.meta = p_meta.duplicate(true)
	return h


func validate() -> DotResult:
	if tick_rate < 1 or tick_rate > 1000:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A replay needs a tick rate between 1 and 1000.",
			"tick_rate=%d" % tick_rate
		)
	if DotReplayFormat.contains_object(players) or DotReplayFormat.contains_object(meta):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A replay header holds plain data only: an object cannot be written to a file somebody else will open.",
		)
	return DotResult.success(self)


func to_dictionary() -> Dictionary:
	return {
		"game": game,
		"map": map,
		"tick_rate": tick_rate,
		"started_unix": started_unix,
		"players": players.duplicate(true),
		"meta": meta.duplicate(true),
		"recorder": recorder,
	}


static func from_dictionary(d: Dictionary) -> DotResult:
	var h := DotReplayHeader.new()
	h.game = str(d.get("game", ""))
	h.map = str(d.get("map", ""))
	h.tick_rate = int(d.get("tick_rate", 0))
	h.started_unix = int(d.get("started_unix", 0))
	var p: Variant = d.get("players", [])
	h.players = (p as Array).duplicate(true) if p is Array else []
	var m: Variant = d.get("meta", {})
	h.meta = (m as Dictionary).duplicate(true) if m is Dictionary else {}
	h.recorder = str(d.get("recorder", ""))
	return h.validate()


func to_bytes() -> PackedByteArray:
	return var_to_bytes(to_dictionary())


static func from_bytes(bytes: PackedByteArray) -> DotResult:
	var decoded: Variant = bytes_to_var(bytes) if not bytes.is_empty() else null
	if not (decoded is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "The replay header is not a dictionary.")
	return from_dictionary(decoded as Dictionary)


func clone() -> DotReplayHeader:
	var r: DotResult = from_dictionary(to_dictionary())
	return r.value as DotReplayHeader if r.ok else DotReplayHeader.new()


func duration_text(ticks: int) -> String:
	var seconds := float(ticks) / float(maxi(tick_rate, 1))
	return "%d:%02d" % [floori(seconds / 60.0), int(seconds) % 60]


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"replay of %s on %s at %d Hz, %d player(s) at the start, by %s" % [
			game if game != "" else "(no game)", map if map != "" else "(no map)",
			tick_rate, players.size(), recorder,
		],
	])
