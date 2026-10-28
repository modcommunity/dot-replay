extends Node

## The kill view: nothing is recorded while off, a killer's view (a bot's too) is cut into a clip the
## victim plays slowed at the kill, Space skips and respawns, and the cvars drive all of it.

const SECTIONS := 5
const CHECKS := 48
const STEP := 1.0 / 60.0

var _passed := 0
var _failed := 0
var _section_count := 0
var _sections_finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_test_off()
	_test_record_and_deliver()
	_test_playback()
	_test_skip()
	_test_cvars()

	print("")
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _sections_finished != SECTIONS:
		print("ERROR: %d of %d sections ran, %d to their end." % [_section_count, SECTIONS, _sections_finished])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _rules(on: bool) -> DotKillViewRules:
	var r := DotKillViewRules.new()
	r.enabled = on
	return r


## Two entities for [param seconds] at 60 Hz: the killer walks along x (x = time), the victim stands.
func _simulate(ring: DotKillViewRing, killer: Variant, victim: Variant, seconds: float) -> void:
	var t := 0.0
	while t <= seconds + 0.0001:
		var _a := ring.record(killer, t, Transform3D(Basis(), Vector3(t, 1.6, 0.0)), 75.0, Vector2(0.5 + 0.01 * t, 0.5))
		var _b := ring.record(victim, t, Transform3D(Basis(), Vector3(0.0, 1.6, 5.0)), 90.0)
		t += STEP


func _test_off() -> void:
	_section("With the kill view off nothing is recorded or played")
	var ring := DotKillViewRing.new(_rules(false))
	_simulate(ring, "bot_7", 1, 5.0)
	_check(ring.entity_count() == 0 and ring.sample_count("bot_7") == 0, "no view of anybody is kept")
	var res := ring.note_kill("bot_7", 1, 5.0)
	_check(not res.ok and res.error.code == DotError.CODE_STATE, "a kill is refused with CODE_STATE")
	_check(ring.collect(99.0).is_empty() and ring.pending_count() == 0, "and no clip is ever ready")
	var player := DotKillViewPlayer.new(_rules(false))
	add_child(player)
	_check(not player.play_clip({"v": 1}).ok and not player.is_active(), "and the player refuses to play")
	player.queue_free()
	_done()


func _test_record_and_deliver() -> void:
	_section("A kill by a bot is cut into a clip the victim receives")
	var rules := _rules(true)
	var ring := DotKillViewRing.new(rules)
	_simulate(ring, "bot_7", 1, 10.6)
	_check(ring.entity_count() == 2, "both entities have a view")
	var cap := int(ceil(rules.history_seconds() * rules.record_hz)) + 2
	_check(ring.sample_count("bot_7") == cap, "the ring is bounded by seconds and rate (%d)" % ring.sample_count("bot_7"))
	_check(not ring.record("bot_7", 10.6 + 0.001, Transform3D(), 75.0), "samples faster than the rate are dropped")
	_check(not ring.note_kill(1, 1, 10.0).ok, "a suicide has no killer view to show")
	_check(not ring.note_kill("ghost", 1, 10.0).ok, "nor does a killer nobody recorded")
	_check(ring.note_kill("bot_7", 1, 10.0, {"killer": "Bot Seven", "weapon": "rifle"}).ok, "the kill is noted")
	_check(ring.collect(10.2).is_empty() and ring.pending_count() == 1, "its clip waits for the seconds after the kill")
	var ready := ring.collect(10.6)
	_check(ready.size() == 1 and ready[0]["victim"] == 1 and ring.pending_count() == 0, "then goes to the victim")
	var wire: Dictionary = ready[0]["clip"]
	var over_the_wire: Dictionary = bytes_to_var(var_to_bytes(wire))
	var made := DotKillViewClip.to_buffer(over_the_wire)
	_check(made.ok, "and survives the wire as plain data")
	var buffer: DotKillcamBuffer = made.value
	_check(buffer.oldest_time() <= -rules.lead_seconds and buffer.oldest_time() > -rules.lead_seconds - 0.2,
		"it starts the lead-in before the kill (%.2f)" % buffer.oldest_time())
	_check(buffer.newest_time() >= rules.post_seconds - 0.05, "and runs the post seconds past it (%.2f)" % buffer.newest_time())
	_check(buffer.frame_count() <= 4 * rules.record_hz + 3, "and is small (%d frames)" % buffer.frame_count())
	var at_kill := DotKillViewClip.view_at(buffer.sample(0.0))
	_check(absf((at_kill["transform"] as Transform3D).origin.x - 10.0) < 0.1, "the camera is the killer's at the kill")
	_check(is_equal_approx(at_kill["fov"], 75.0) and at_kill["has_cursor"], "with their fov and crosshair")
	_check(not DotKillViewClip.to_buffer({"v": 1, "f": PackedFloat32Array([1.0, 2.0])}).ok, "a malformed clip is refused")
	var nan_clip := wire.duplicate()
	var bad: PackedFloat32Array = nan_clip["f"]
	bad[1] = NAN
	nan_clip["f"] = bad
	_check(not DotKillViewClip.to_buffer(nan_clip).ok, "as is one holding NaN")
	ring.forget("bot_7")
	_check(ring.entity_count() == 1, "a leaver's view is forgotten")
	_done()


func _clip(rules: DotKillViewRules) -> Dictionary:
	var ring := DotKillViewRing.new(rules)
	_simulate(ring, 2, 1, 11.0)
	var _n := ring.note_kill(2, 1, 10.0)
	return ring.collect(11.0)[0]["clip"]


func _player(rules: DotKillViewRules) -> DotKillViewPlayer:
	var p := DotKillViewPlayer.new(rules)
	p.auto_process = false
	add_child(p)
	return p


func _test_playback() -> void:
	_section("The victim sees the killer's view, slowed at the kill, then the flow resumes")
	var rules := _rules(true)
	var player := _player(rules)
	var xs: Array[float] = []
	var cursors: Array[bool] = []
	var ends: Array = []
	var respawns: Array = []
	player.view.connect(func(t: Transform3D, _f: float, _c: Vector2, has: bool) -> void:
		xs.append(t.origin.x)
		cursors.append(has))
	player.finished.connect(func(skipped: bool) -> void: ends.append(skipped))
	player.respawn_requested.connect(func() -> void: respawns.append(1))
	_check(player.play_clip(_clip(rules), {"killer": "Two"}).ok, "the clip is accepted")
	var wall := 0.0
	while player.is_active() and wall < 20.0:
		player.advance(STEP)
		wall += STEP
	_check(ends == [false], "it runs to its end by itself")
	_check(wall <= rules.seconds + 0.1, "inside the configured length (%.2f s)" % wall)
	_check(wall > rules.lead_seconds + rules.post_seconds, "and slower than real time around the kill (%.2f s)" % wall)
	_check(xs.size() > 10 and xs[0] < 7.0 and xs[xs.size() - 1] > 10.2, "the camera follows the killer across the kill (%d, %.2f to %.2f)" % [xs.size(), xs[0], xs[xs.size() - 1]])
	_check(not cursors.has(false), "with their crosshair")
	_check(respawns.is_empty(), "and no respawn is requested when nobody skipped")
	player.queue_free()
	_done()


func _skip_event(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func _test_skip() -> void:
	_section("The skip action ends the replay and requests a respawn, unless skipping is off")
	var rules := _rules(true)
	var player := _player(rules)
	var asked: Array = []
	player.respawn_fn = func() -> void: asked.append(1)
	var ends: Array = []
	player.finished.connect(func(skipped: bool) -> void: ends.append(skipped))
	var _r := player.play_clip(_clip(rules))
	for i in 30:
		player.advance(STEP)
	player.killcam._unhandled_input(_skip_event("ui_cancel"))
	_check(player.is_active(), "a key that is not the skip action does nothing")
	player.killcam._unhandled_input(_skip_event("ui_accept"))
	_check(not player.is_active() and ends == [true], "the skip action ends it at once")
	_check(asked.size() == 1, "and requests the respawn")

	InputMap.add_action("kv_test_skip")
	rules.skip_action = "kv_test_skip"
	var _r2 := player.play_clip(_clip(rules))
	player.killcam._unhandled_input(_skip_event("ui_accept"))
	_check(player.is_active(), "the action is configurable: the old one no longer skips")
	player.killcam._unhandled_input(_skip_event("kv_test_skip"))
	_check(not player.is_active() and asked.size() == 2, "the configured one does")
	InputMap.erase_action("kv_test_skip")

	rules.skip_action = "ui_accept"
	rules.skip_allowed = false
	var _r3 := player.play_clip(_clip(rules))
	player.killcam._unhandled_input(_skip_event("ui_accept"))
	_check(player.is_active() and asked.size() == 2, "with skipping off the action is ignored")
	while player.is_active():
		player.advance(STEP)
	_check(ends.back() == false and asked.size() == 2, "and the replay plays out without a respawn request")
	player.queue_free()
	_done()


class _FakeCvar extends RefCounted:
	signal changed(old: Variant, new_value: Variant)
	var value := ""

	func get_string() -> String:
		return value

	func with_range(_lo: float, _hi: float) -> void:
		pass


func _test_cvars() -> void:
	_section("Every setting is a cvar and the cursor can be left out")
	var rules := DotKillViewRules.new()
	_check(not rules.enabled, "it is off by default")
	_check(rules.set_cvar("mp_killview", "1") and rules.enabled, "mp_killview turns it on")
	_check(rules.set_cvar("mp_killview_seconds", "8") and rules.seconds == 8.0, "mp_killview_seconds sets the length")
	_check(rules.set_cvar("mp_killview_lead", "2") and rules.lead_seconds == 2.0, "mp_killview_lead the lead-in")
	_check(rules.set_cvar("mp_killview_slowmo", "0.25") and rules.slowmo == 0.25, "mp_killview_slowmo the slow factor")
	_check(not rules.set_cvar("mp_killview_slowmo", "0") and rules.slowmo == 0.25, "a value out of range is refused")
	_check(not rules.set_cvar("mp_killview", "yes") and rules.enabled, "as is one that is not a flag")
	_check(not rules.set_cvar("mp_other", "1"), "and another name")
	var made := rules.bind_cvars(func(n: String, d: String, _desc: String, _fl: int) -> Object:
		var c := _FakeCvar.new()
		c.value = "0" if n == "mp_killview" else d
		return c)
	_check(made.size() == rules.cvar_specs().size() and not rules.enabled, "bound cvars are read back after registering")
	(made[0] as _FakeCvar).value = "1"
	(made[0] as _FakeCvar).changed.emit("0", "1")
	_check(rules.enabled, "and a cvar change reaches the rules")

	rules.include_cursor = false
	rules.skip_allowed = true
	var clip := _clip(rules)
	_check(clip["cursor"] == false, "with the cursor off the clip says so")
	var buffer: DotKillcamBuffer = DotKillViewClip.to_buffer(clip).value
	_check(not DotKillViewClip.view_at(buffer.sample(0.0))["has_cursor"], "and the replay draws no crosshair")
	var flat: PackedFloat32Array = clip["f"]
	_check(flat[9] == 0.0 and flat[10] == 0.0, "because the server never sent it")
	_done()


func _section(title: String) -> void:
	_section_count += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_sections_finished += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
