class_name DotKillViewRing
extends RefCounted

## Server side of the kill-cam: a small ring of recent view samples per entity (player or bot),
## and the clip of a killer's view cut when somebody dies. Records nothing while the rules are off.

const CHANNEL := "replay.killview"

## Floats per sample: time, position 3, rotation 4, fov, cursor 2, then [constant AUX] game-defined.
## 23 floats at 30 Hz (`mp_killview_hz`) is 2760 bytes a second of view; a 4 s clip about 11 KB.
const STRIDE := 23

## Game-defined floats per sample (held weapon, aim, ammo, spread, the last shot's recoil...) a presenter redraws the killer's screen from.
const AUX := 12

## The clip format: 3 has [constant AUX] 12; a 2 (8 aux) still reads, padded.
const VERSION := 3

## Most entities tracked; a view of each costs a few KiB.
var max_entities: int = 256

var rules: DotKillViewRules = null

var _tracks: Dictionary = {}
var _pending: Array[Dictionary] = []


func _init(p_rules: DotKillViewRules = null) -> void:
	rules = p_rules if p_rules != null else DotKillViewRules.new()


## Notes where [param id] looked at [param time]; [param cursor] is its crosshair in 0..1 screen
## space. False when off, too soon after the last sample (rate), or the entity table is full.
func record(id: Variant, time: float, xform: Transform3D, fov: float, cursor: Vector2 = Vector2(0.5, 0.5), aux: PackedFloat32Array = PackedFloat32Array()) -> bool:
	if not rules.enabled:
		return false
	var track: _Track = _tracks.get(id)
	if track == null:
		if _tracks.size() >= max_entities:
			return false
		track = _Track.new(maxi(int(ceil(rules.history_seconds() * rules.record_hz)) + 2, 4))
		_tracks[id] = track
	if track.count > 0 and time - track.newest() < 1.0 / rules.record_hz - 0.0001:
		return false
	var q := xform.basis.orthonormalized().get_rotation_quaternion()
	var c := cursor if rules.include_cursor else Vector2.ZERO
	var row := PackedFloat32Array([
		0.0, xform.origin.x, xform.origin.y, xform.origin.z, q.x, q.y, q.z, q.w, fov, c.x, c.y,
	])
	for k in AUX:
		row.append(aux[k] if k < aux.size() else 0.0)
	track.push(time, row)
	return true


## Remembers a death so [method collect] can send the clip once [member DotKillViewRules.post_seconds]
## have passed. Fails with CODE_STATE when off, a suicide, or the killer has no recorded view.
func note_kill(killer: Variant, victim: Variant, time: float, info: Dictionary = {}) -> DotResult:
	if not rules.enabled:
		return DotResult.fail(DotError.CODE_STATE, "The kill view is off.")
	if (typeof(killer) == typeof(victim) and killer == victim) or not _tracks.has(killer):
		return DotResult.fail(DotError.CODE_STATE, "No recorded view for the killer.", str(killer))
	_pending.append({"killer": killer, "victim": victim, "time": time, "info": info})
	return DotResult.success()


## The ready clips at [param now]: [{victim, killer, clip}]. A clip that cannot be cut is dropped.
func collect(now: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var keep: Array[Dictionary] = []
	for p in _pending:
		if now < float(p["time"]) + rules.post_seconds:
			keep.append(p)
			continue
		var res := clip_for(p["killer"], float(p["time"]), p["info"])
		if res.ok:
			out.append({"victim": p["victim"], "killer": p["killer"], "clip": res.value})
		else:
			DotLog.debug(CHANNEL, "kill clip dropped", {"killer": str(p["killer"]), "why": res.message})
	_pending = keep
	return out


## The wire form of [param killer]'s view around [param kill_time]: plain Variants (no objects),
## times relative to the kill, ready for [method DotKillViewClip.to_buffer].
func clip_for(killer: Variant, kill_time: float, info: Dictionary = {}) -> DotResult:
	var track: _Track = _tracks.get(killer)
	if track == null or track.count == 0:
		return DotResult.fail(DotError.CODE_STATE, "No recorded view for the killer.", str(killer))
	var from := kill_time - rules.lead_seconds
	var to := kill_time + rules.post_seconds
	var flat := PackedFloat32Array()
	var prev := -1
	for i in track.count:
		var t := track.time_at(i)
		if t < from:
			prev = i
			continue
		if prev >= 0:
			_append(flat, track, prev, kill_time)
			prev = -1
		if t > to:
			break
		_append(flat, track, i, kill_time)
	if prev >= 0:
		_append(flat, track, prev, kill_time)
	if flat.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "The killer's view does not cover the kill.", str(killer))
	return DotResult.success({
		"v": VERSION, "killer": killer, "cursor": rules.include_cursor, "f": flat, "info": info,
	})


func forget(id: Variant) -> void:
	_tracks.erase(id)


func clear() -> void:
	_tracks.clear()
	_pending.clear()


func entity_count() -> int:
	return _tracks.size()


func sample_count(id: Variant) -> int:
	var track: _Track = _tracks.get(id)
	return 0 if track == null else track.count


func pending_count() -> int:
	return _pending.size()


func _append(flat: PackedFloat32Array, track: _Track, index: int, kill_time: float) -> void:
	var row := track.row_at(index)
	row[0] = track.time_at(index) - kill_time
	flat.append_array(row)


func describe() -> Dictionary:
	return {"enabled": rules.enabled, "entities": _tracks.size(), "pending": _pending.size()}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"killview ring: %s, %d entit(ies), %d pending kill(s)" % [
			"on" if rules.enabled else "off", _tracks.size(), _pending.size(),
		],
	])


## One entity's samples in a fixed-size ring, oldest overwritten.
class _Track:
	var count: int = 0
	var _cap: int
	var _start: int = 0
	var _times := PackedFloat64Array()
	var _data := PackedFloat32Array()

	func _init(cap: int) -> void:
		_cap = cap
		_times.resize(cap)
		_data.resize(cap * STRIDE)

	func push(time: float, row: PackedFloat32Array) -> void:
		var slot := (_start + count) % _cap
		if count == _cap:
			slot = _start
			_start = (_start + 1) % _cap
		else:
			count += 1
		_times[slot] = time
		for k in STRIDE:
			_data[slot * STRIDE + k] = row[k]

	func newest() -> float:
		return _times[(_start + count - 1) % _cap]

	func time_at(i: int) -> float:
		return _times[(_start + i) % _cap]

	func row_at(i: int) -> PackedFloat32Array:
		var slot := (_start + i) % _cap
		return _data.slice(slot * STRIDE, slot * STRIDE + STRIDE)
