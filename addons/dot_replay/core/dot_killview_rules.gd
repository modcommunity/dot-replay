class_name DotKillViewRules
extends RefCounted

## The kill-cam policy: whether a victim is shown their killer's view, for how long, and whether
## they may skip. Decided on the server and replicated as cvars; nothing here records or draws.

const CHANNEL := "replay.killview"

signal changed

const CVAR_ENABLE := "mp_killview"
const CVAR_SECONDS := "mp_killview_seconds"
const CVAR_LEAD := "mp_killview_lead"
const CVAR_POST := "mp_killview_post"
const CVAR_CURSOR := "mp_killview_cursor"
const CVAR_SKIP := "mp_killview_skip"
const CVAR_SKIP_ACTION := "mp_killview_skip_action"
const CVAR_SLOWMO := "mp_killview_slowmo"
const CVAR_HZ := "mp_killview_hz"
const CVAR_CAMERA := "mp_killview_camera"
const CVAR_FINAL := "mp_killview_final"
const CVAR_SKIP_GRACE := "mp_killview_skip_grace"

## Where a killcam's camera sits: the killer's own eye, or behind the killer on a boom.
enum Camera { EYE, BEHIND }

## Off by default: nothing is recorded and no clip is built.
var enabled: bool = false

## The whole replay, wall seconds, waiting included.
var seconds: float = 6.0

## Seconds shown before the kill.
var lead_seconds: float = 3.5

## Seconds shown after the kill.
var post_seconds: float = 0.5

## Whether the killer's crosshair is recorded and drawn.
var include_cursor: bool = true

## Whether the victim may skip.
var skip_allowed: bool = true

## Input action that skips (Space is ui_accept's default key).
var skip_action: String = "ui_accept"

## Playback speed at the kill, 1 is real time.
var slowmo: float = 0.5

## Server view samples per second, per entity.
var record_hz: float = 30.0

## The killer's eye shows neither killer nor shot; behind the killer frames both, so it is the default.
var camera: Camera = Camera.EYE

## Whether the match's last kill is replayed before the summary.
var final_killcam: bool = true

## Seconds a replay ignores skip keys, so the fire or jump that ended the match does not skip it.
var skip_grace: float = 1.0


## Frames kept per entity, from the longest clip asked for plus a second of slack.
func history_seconds() -> float:
	return lead_seconds + post_seconds + 1.0


func cvar_specs() -> Array:
	return [
		{"name": CVAR_ENABLE, "value": "1" if enabled else "0", "min": 0.0, "max": 1.0,
			"description": "1 shows a victim the replay of their killer's view (records views while on)"},
		{"name": CVAR_SECONDS, "value": str(seconds), "min": 1.0, "max": 30.0,
			"description": "Longest the kill replay runs, in seconds"},
		{"name": CVAR_LEAD, "value": str(lead_seconds), "min": 0.0, "max": 10.0,
			"description": "Seconds of the killer's view shown before the kill"},
		{"name": CVAR_POST, "value": str(post_seconds), "min": 0.0, "max": 5.0,
			"description": "Seconds shown after the kill"},
		{"name": CVAR_CURSOR, "value": "1" if include_cursor else "0", "min": 0.0, "max": 1.0,
			"description": "1 includes the killer's crosshair in the replay"},
		{"name": CVAR_SKIP, "value": "1" if skip_allowed else "0", "min": 0.0, "max": 1.0,
			"description": "1 lets the victim skip the replay and respawn at once"},
		{"name": CVAR_SKIP_ACTION, "value": skip_action, "min": 0.0, "max": 0.0,
			"description": "Input action that skips the kill replay"},
		{"name": CVAR_SLOWMO, "value": str(slowmo), "min": 0.05, "max": 1.0,
			"description": "Replay speed around the kill: 1 real time, 0.5 half speed"},
		{"name": CVAR_HZ, "value": str(record_hz), "min": 5.0, "max": 120.0,
			"description": "Killer view samples recorded per second"},
		{"name": CVAR_CAMERA, "value": str(int(camera)), "min": 0.0, "max": 1.0,
			"description": "Killcam camera: 0 the killer's eye, 1 behind the killer"},
		{"name": CVAR_FINAL, "value": "1" if final_killcam else "0", "min": 0.0, "max": 1.0,
			"description": "1 replays the match's last kill before the summary"},
		{"name": CVAR_SKIP_GRACE, "value": str(skip_grace), "min": 0.0, "max": 5.0,
			"description": "Seconds a replay ignores skip keys after it starts"},
	]


## Registers the cvars through [param add] (a server module's `add_cvar`, shaped
## `(name, default, description, flags) -> cvar`; pass FLAG_REPLICATED) and follows them.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var made_cvar: Variant = add.call(cvar_name, String(spec["value"]), String(spec["description"]), flags)
		if not (made_cvar is Object) or made_cvar == null:
			continue
		var cv := made_cvar as Object
		if cv.has_method(&"with_range") and float(spec["max"]) > float(spec["min"]):
			cv.call(&"with_range", float(spec["min"]), float(spec["max"]))
		if cv.has_signal(&"changed"):
			var on_change := func(_old: Variant, new_value: Variant) -> void: set_cvar(cvar_name, str(new_value))
			cv.connect(&"changed", on_change)
		if cv.has_method(&"get_string"):
			var _applied := set_cvar(cvar_name, String(cv.call(&"get_string")))
		made.append(cv)
	return made


## Follows a server's replicated values (dot-server's `DotClientLink`: `replicated_cvar(name,
## fallback)` and `replicated_cvar_changed(name, value)`). False when [param source] cannot.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false
	for spec in cvar_specs():
		var held := String(source.call(&"replicated_cvar", spec["name"], ""))
		if held != "":
			var _applied := set_cvar(spec["name"], held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated):
		source.connect(&"replicated_cvar_changed", _on_replicated)
	return true


## Applies one cvar by name. False for another name or a value out of range.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()
	match cvar_name:
		CVAR_ENABLE:
			return _flag(text, func(v: bool) -> void: enabled = v)
		CVAR_CURSOR:
			return _flag(text, func(v: bool) -> void: include_cursor = v)
		CVAR_SKIP:
			return _flag(text, func(v: bool) -> void: skip_allowed = v)
		CVAR_SKIP_ACTION:
			if text == "":
				return false
			skip_action = text
		CVAR_SECONDS:
			return _number(text, 1.0, 30.0, func(v: float) -> void: seconds = v)
		CVAR_LEAD:
			return _number(text, 0.0, 10.0, func(v: float) -> void: lead_seconds = v)
		CVAR_POST:
			return _number(text, 0.0, 5.0, func(v: float) -> void: post_seconds = v)
		CVAR_SLOWMO:
			return _number(text, 0.05, 1.0, func(v: float) -> void: slowmo = v)
		CVAR_HZ:
			return _number(text, 5.0, 120.0, func(v: float) -> void: record_hz = v)
		CVAR_FINAL:
			return _flag(text, func(v: bool) -> void: final_killcam = v)
		CVAR_SKIP_GRACE:
			return _number(text, 0.0, 5.0, func(v: float) -> void: skip_grace = v)
		CVAR_CAMERA:
			return _flag(text, func(v: bool) -> void: camera = Camera.BEHIND if v else Camera.EYE)
		_:
			return false
	changed.emit()
	return true


func _flag(text: String, apply: Callable) -> bool:
	if text != "0" and text != "1":
		DotLog.debug(CHANNEL, "a killview cvar refused a value", {"value": text})
		return false
	apply.call(text == "1")
	changed.emit()
	return true


func _number(text: String, lo: float, hi: float, apply: Callable) -> bool:
	if not text.is_valid_float() or text.to_float() < lo or text.to_float() > hi:
		DotLog.debug(CHANNEL, "a killview cvar refused a value", {"value": text})
		return false
	apply.call(text.to_float())
	changed.emit()
	return true


func _on_replicated(cvar_name: String, value: String) -> void:
	var _applied := set_cvar(cvar_name, value)


func describe() -> Dictionary:
	return {
		"enabled": enabled, "seconds": seconds, "lead": lead_seconds, "post": post_seconds,
		"cursor": include_cursor, "skip": skip_allowed, "skip_action": skip_action,
		"slowmo": slowmo, "hz": record_hz, "camera": Camera.keys()[camera],
		"final": final_killcam, "skip_grace": skip_grace,
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"killview: %s, %.1f s (%.1f before, %.1f after) at x%.2f, cursor %s, skip %s (%s), %.0f Hz, camera %s" % [
			"on" if enabled else "off", seconds, lead_seconds, post_seconds, slowmo,
			include_cursor, skip_allowed, skip_action, record_hz, Camera.keys()[camera],
		],
	])
