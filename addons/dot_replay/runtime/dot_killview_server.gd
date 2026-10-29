class_name DotKillViewServer
extends RefCounted

## The server half of the kill view: samples every eye each tick into a [DotKillViewRing], cuts the
## killer's clip on a death, and holds the victim's respawn until the clip has played (or is skipped).
## The game assigns [member eyes_fn] and the respawn hooks; nothing here knows a player type.

const CHANNEL := "replay.killview"

## Field of view (degrees) recorded for an eye that does not give its own.
var default_fov: float = 83.6

## Ticks per second of the game's clock, for the respawn hold.
var tick_rate: int = 60

## Wall seconds the slow motion around the kill adds to a clip's span, held on top of it.
var slowmo_margin: float = 1.0

## () -> Array of {id, transform: Transform3D, fov?: float, cursor?: Vector2}: every living eye now.
var eyes_fn: Callable = Callable()

## (victim, until_tick) -> int: delays a waiting victim's respawn to at least [param until_tick]
## and returns the tick it is now held to, or -1 when the victim is not waiting to respawn.
var hold_fn: Callable = Callable()

## (victim) -> bool: respawns a victim now if still waiting; true when it did.
var release_fn: Callable = Callable()

var rules: DotKillViewRules = null
var ring: DotKillViewRing = null

## victim -> tick the respawn is held to.
var _held: Dictionary = {}


func _init(p_rules: DotKillViewRules = null) -> void:
	rules = p_rules if p_rules != null else DotKillViewRules.new()
	ring = DotKillViewRing.new(rules)


## Sets [member hold_fn] and [member release_fn] over a dot-match DotRespawnQueue (keyed by
## [code]str(id)[/code]); [param queue_fn] returns it or null, [param respawn_fn] (id) -> DotResult.
func use_respawn_queue(queue_fn: Callable, respawn_fn: Callable) -> void:
	hold_fn = func(victim: Variant, until: int) -> int:
		var q: Object = queue_fn.call()
		if q == null or not q.call(&"is_waiting", str(victim)):
			return -1
		var target := maxi(int(q.call(&"ready_tick", str(victim))), until)
		q.call(&"enqueue_at", str(victim), target)
		return target
	release_fn = func(victim: Variant) -> bool:
		var q: Object = queue_fn.call()
		if q == null or not q.call(&"is_waiting", str(victim)):
			return false
		var res: DotResult = respawn_fn.call(victim)
		return res != null and res.ok


## Notes where every eye from [member eyes_fn] looks at [param time] (seconds). Nothing while off.
func record(time: float) -> void:
	if not rules.enabled or not eyes_fn.is_valid():
		return
	for e: Dictionary in eyes_fn.call():
		var _noted := ring.record(e["id"], time, e["transform"], float(e.get("fov", default_fov)), e.get("cursor", Vector2(0.5, 0.5)))


## A death: the killer's clip is cut once [member DotKillViewRules.post_seconds] have passed.
func note_kill(killer: Variant, victim: Variant, time: float, info: Dictionary = {}) -> DotResult:
	return ring.note_kill(killer, victim, time, info)


## The clips ready at [param time]: [{victim, clip, info}]. Holds each victim's respawn to the clip's end.
func collect(time: float, tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c: Dictionary in ring.collect(time):
		var clip: Dictionary = c["clip"]
		var flat: PackedFloat32Array = clip.get("f", PackedFloat32Array())
		if flat.is_empty():
			continue
		var span := flat[flat.size() - DotKillViewRing.STRIDE] - flat[0]
		var hold := minf(rules.seconds, span + slowmo_margin)
		var victim: Variant = c["victim"]
		_hold(victim, tick + int(ceil(hold * float(tick_rate))))
		DotLog.debug(CHANNEL, "a kill view clip is ready", {"victim": victim, "hold": hold})
		out.append({"victim": victim, "clip": clip, "info": clip.get("info", {})})
	return out


## The victim skipped: respawn now, if held and still waiting. False otherwise.
func skip(victim: Variant, tick: int) -> bool:
	if not rules.skip_allowed or not _held.has(victim) or tick >= int(_held[victim]):
		return false
	_held.erase(victim)
	return release_fn.is_valid() and bool(release_fn.call(victim))


## Whether [param victim]'s respawn is held for a clip.
func is_held(victim: Variant) -> bool:
	return _held.has(victim)


func forget(id: Variant) -> void:
	ring.forget(id)
	_held.erase(id)


func _hold(victim: Variant, until: int) -> void:
	if not hold_fn.is_valid():
		return
	var target := int(hold_fn.call(victim, until))
	if target >= 0:
		_held[victim] = target


func describe() -> Dictionary:
	var d := ring.describe()
	d["held"] = _held.size()
	return d


func describe_lines() -> PackedStringArray:
	var lines := ring.describe_lines()
	lines.append("held respawns: %d" % _held.size())
	return lines
