extends Node

## DotKillcamBuffer and DotKillcam: the rewind picks the right frames, the kill is kept, the
## replay is slowed at the kill and bounded, a skip or a disabled killcam ends it at once.

const SECTIONS := 6
const CHECKS := 56
const STEP := 1.0 / 60.0

var _passed := 0
var _failed := 0
var _section_count := 0
var _sections_finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_test_buffer()
	_test_playback()
	_test_budget_and_stall()
	_test_skip_and_disabled()
	_test_icon()
	_test_host()

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


## Frames at 60 Hz from [param from] to [param to] seconds; frame["x"] is its own time.
func _fill(buffer: DotKillcamBuffer, from: float, to: float) -> void:
	var t := from
	while t <= to + 0.0001:
		var _ok := buffer.push_frame(t, {"x": t})
		t += STEP


func _test_buffer() -> void:
	_section("The buffer keeps a bounded window and rewinds to the right frames")
	var b := DotKillcamBuffer.new()
	b.window_seconds = 5.0
	_fill(b, 0.0, 20.0)
	_check(b.oldest_time() <= 15.0 and b.oldest_time() > 15.0 - 2.0 * STEP,
		"only the last 5 s are held, from one frame at or before the window (%.3f)" % b.oldest_time())
	_check(b.frame_count() <= int(5.0 / STEP) + 3, "and memory is bounded by it (%d frames)" % b.frame_count())
	_check(not b.push_frame(b.newest_time(), {}), "a frame not after the last is refused")

	var picked := b.frames_between(16.5, 19.5)
	_check(not picked.is_empty() and float(picked[0]["time"]) >= 16.5 and float(picked[0]["time"]) < 16.5 + STEP,
		"a rewind to 16.5 s starts at the first frame at or after it")
	_check(float(picked[picked.size() - 1]["time"]) <= 19.5 and float(picked[picked.size() - 1]["time"]) > 19.5 - STEP,
		"and ends at the last frame at or before 19.5 s")
	_check(picked.size() == int(round(3.0 / STEP)) or picked.size() == int(round(3.0 / STEP)) + 1,
		"and holds every frame between (%d)" % picked.size())

	var s := b.sample(17.0 + STEP * 0.25)
	var a_t: float = s["a"]["x"]
	var b_t: float = s["b"]["x"]
	_check(a_t <= 17.0 + STEP * 0.25 and b_t >= 17.0 + STEP * 0.25 and b_t - a_t < STEP * 1.5,
		"a sample sits between the two frames around it")
	_check(absf(lerpf(a_t, b_t, float(s["alpha"])) - (17.0 + STEP * 0.25)) < 0.0005,
		"and its alpha puts it at the instant asked for")
	_check(b.sample(0.0)["a"] == b.frames_between(0.0, 100.0)[0]["frame"] and float(b.sample(99.0)["alpha"]) == 1.0,
		"before the first frame or after the last it clamps")

	b.note_event(18.0, &"kill", {"killer": 3, "victim": 9})
	b.note_event(18.5, &"shot", {"by": 3})
	b.note_event(19.0, &"kill", {"killer": 4, "victim": 3})
	var last := b.last_event(&"kill")
	_check(not last.is_empty() and int(last["data"]["killer"]) == 4 and float(last["time"]) == 19.0,
		"the last kill is the newest one noted")
	_check(b.events_between(17.5, 18.7).size() == 2 and b.events_between(17.5, 20.0, &"kill").size() == 2,
		"events are found by time and by kind")
	_fill(b, 20.0 + STEP, 23.5)
	_check(b.last_event(&"kill")["data"]["killer"] == 4 and b.events_between(0.0, 100.0, &"kill").size() == 1,
		"an event falls out with the window")
	b.max_events = 2
	for i in range(5):
		b.note_event(23.5, &"shot")
	_check(b.event_count() == 2, "and the event count is capped (%d)" % b.event_count())
	b.max_frames = 10
	_fill(b, 23.5 + STEP, 24.0)
	_check(b.frame_count() == 10, "as is the frame count (%d)" % b.frame_count())
	_done()


func _killcam(b: DotKillcamBuffer) -> DotKillcam:
	var k := DotKillcam.new()
	k.auto_process = false
	k.show_banner = true
	k.max_seconds = 7.0
	add_child(k)
	return k


func _test_playback() -> void:
	_section("A kill at the end of the match plays from before it, slowed at it, past it")
	var b := DotKillcamBuffer.new()
	_fill(b, 0.0, 10.0)
	b.note_event(10.0, &"kill", {"killer": 3})
	var k := _killcam(b)
	var seen: Array[float] = []
	var ended: Array = []
	k.frame_drawn.connect(func(s: Dictionary) -> void: seen.append(float(s["time"])))
	k.finished.connect(func(skipped: bool) -> void: ended.append(skipped))

	_check(k.play(b, b.last_event(&"kill"), {"killer": "Three", "weapon": "rifle"}).ok, "play is accepted")
	_check(k.state == DotKillcam.State.WAITING and seen.is_empty(),
		"and waits: the second after the kill has not been drawn yet")
	_check(k.banner != null and k.banner.visible and k.banner.killer_label.text == "Three"
		and k.banner.title_label.text == "FINAL KILLCAM" and k.banner.detail_label.text.contains("rifle"),
		"the banner is up with the title, the killer and the weapon")

	var t := 10.0
	while k.state == DotKillcam.State.WAITING and t < 13.0:
		t += STEP
		var _ok := b.push_frame(t, {"x": t})
		k.advance(STEP)
	_check(k.state == DotKillcam.State.PLAYING, "it starts once the buffer covers a second past the kill")
	_check(absf(k.window().x - 6.5) < 0.001 and absf(k.window().y - 11.0) < 0.001,
		"rewound 3.5 s before the kill, to 1 s after (%s)" % str(k.window()))
	_check(not seen.is_empty() and absf(seen[0] - 6.5) < 0.001, "the first frame drawn is the rewind's start")
	_check(k.speed_at(10.2) == k.slow_scale and k.speed_at(8.0) == 1.0, "slowed at the kill, full speed away from it")
	_check(absf(k.wall_seconds(6.5, 11.0, 10.0) - 5.5) < 0.001,
		"which makes 4.5 s of match take 5.5 s (%.2f)" % k.wall_seconds(6.5, 11.0, 10.0))

	var steps := 0
	while k.state == DotKillcam.State.PLAYING and steps < 2000:
		k.advance(STEP)
		steps += 1
	var ordered := true
	for i in range(1, seen.size()):
		ordered = ordered and seen[i] >= seen[i - 1]
	_check(ordered and absf(seen[seen.size() - 1] - 11.0) < 0.001, "frames run forward and end at 11 s")
	_check(absf(steps * STEP - 5.5) < 0.1, "in about 5.5 s of real time (%.2f)" % (steps * STEP))
	_check(ended == [false] and not k.banner.visible, "finished, not skipped, and the banner is down")
	k.free()
	_done()


func _test_budget_and_stall() -> void:
	_section("The budget shortens the rewind, never the kill; a stalled stream does not hold it")
	var b := DotKillcamBuffer.new()
	_fill(b, 0.0, 12.0)
	b.note_event(10.0, &"kill")
	var k := _killcam(b)
	k.max_seconds = 4.0
	var _r := k.play(b, b.last_event(&"kill"))
	_check(k.state == DotKillcam.State.PLAYING, "a buffer already past the kill plays at once")
	_check(k.window().x > 6.5 and k.window().x < 10.0 and absf(k.window().y - 11.0) < 0.001,
		"a 4 s budget starts later (%.2f) and still ends after the kill" % k.window().x)
	_check(k.wall_seconds(k.window().x, k.window().y, 10.0) <= 4.0, "and fits the budget")
	k.skip()

	var stalled := DotKillcamBuffer.new()
	_fill(stalled, 0.0, 10.0)
	stalled.note_event(10.0, &"kill")
	var _r2 := k.play(stalled, stalled.last_event(&"kill"))
	var waited := 0
	while k.state == DotKillcam.State.WAITING and waited < 1000:
		k.advance(STEP)
		waited += 1
	_check(k.state == DotKillcam.State.PLAYING and waited * STEP < 1.6,
		"with no frames after the kill it plays what it has after %.2f s" % (waited * STEP))
	_check(absf(k.window().y - 10.0) < 0.001, "and ends where the buffer ends")

	var ended: Array = []
	k.finished.connect(func(skipped: bool) -> void: ended.append(skipped))
	var total := waited * STEP
	while k.state != DotKillcam.State.IDLE and total < 30.0:
		k.advance(STEP)
		total += STEP
	_check(ended.size() == 1 and total <= k.max_seconds + STEP, "the whole thing stays inside max_seconds (%.2f)" % total)
	k.free()
	_done()


func _test_skip_and_disabled() -> void:
	_section("A skip ends it at once; a disabled killcam never starts")
	var b := DotKillcamBuffer.new()
	_fill(b, 0.0, 12.0)
	b.note_event(10.0, &"kill")
	var k := _killcam(b)
	var ended: Array = []
	var drawn: Array = []
	k.finished.connect(func(skipped: bool) -> void: ended.append(skipped))
	k.frame_drawn.connect(func(_s: Dictionary) -> void: drawn.append(1))
	var _r := k.play(b, b.last_event(&"kill"))
	k.advance(0.5)

	var press := InputEventAction.new()
	press.action = &"ui_cancel"
	press.pressed = true
	k._unhandled_input(press)
	_check(ended.is_empty() and k.state != DotKillcam.State.IDLE, "a skip key inside the grace second is ignored")
	k.advance(0.6)
	k._unhandled_input(press)
	_check(ended == [true] and k.state == DotKillcam.State.IDLE, "the skip action ends it, skipped")
	_check(not k.banner.visible, "and takes the banner down")

	var again := k.play(b, b.last_event(&"kill"))
	k.banner.skip_pressed.emit()
	_check(again.ok and ended == [true, true], "the banner's skip button does the same")
	_check(not k.banner.skip_pressed.is_connected(k.skip), "and lets go of the button after")

	ended.clear()
	drawn.clear()
	k.max_seconds = 0.0
	var off := k.play(b, b.last_event(&"kill"))
	k.advance(1.0)
	_check(not off.ok and off.error.code == DotError.CODE_STATE and not k.enabled(), "max_seconds 0 refuses to play")
	_check(ended.is_empty() and drawn.is_empty() and k.state == DotKillcam.State.IDLE and not k.banner.visible,
		"and nothing is drawn, shown or finished")

	k.max_seconds = 7.0
	var early := DotKillcamBuffer.new()
	_fill(early, 11.0, 12.0)
	_check(not k.play(early, {"time": 10.0}).ok, "a kill from before the buffer is refused")
	_check(not k.play(b, {}).ok, "as is no kill at all")
	k.free()
	_done()


func _test_icon() -> void:
	_section("A weapon icon sits beside the weapon name when a provider gives one")
	var b := DotKillcamBuffer.new()
	_fill(b, 0.0, 10.0)
	b.note_event(10.0, &"kill", {"killer": 3})
	var kill := b.last_event(&"kill")
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var asked: Array = []
	var plain := _killcam(b)
	var _p := plain.play(b, kill, {"killer": "A", "weapon": "Rifle"})
	_check(not plain.banner.icon_rect.visible and plain.banner.detail_label.text.contains("Rifle"),
		"no provider: text only, as before")
	var k := DotKillcam.new()
	k.auto_process = false
	k.icon_provider = func(id: String) -> Texture2D:
		asked.append(id)
		return tex if id == "rifle" else null
	add_child(k)
	var _r := k.play(b, kill, {"killer": "A", "weapon": "Rifle", "weapon_id": "rifle"})
	_check(k.banner.icon_rect.visible and k.banner.icon_rect.texture == tex and asked == ["rifle"],
		"the provider is asked the weapon id and its texture is shown")
	_check(k.banner.detail_label.text.contains("Rifle"), "the name stays beside it")
	k.banner.present({"killer": "A", "weapon": "Sword", "weapon_id": "sword"})
	_check(not k.banner.icon_rect.visible and k.banner.icon_rect.texture == null, "a null from the provider hides the icon")
	k.banner.present({"killer": "A", "weapon": "rifle"})
	_check(k.banner.icon_rect.visible and asked.back() == "rifle", "without weapon_id the weapon is the id")
	_done()


class FakeBody extends Node3D:
	var display_name := "Fake"


func _test_host() -> void:
	_section("DotKillcamHost records through the game's hooks, replays the last kill and puts the bodies back")
	var killer := FakeBody.new()
	var victim := FakeBody.new()
	add_child(killer)
	add_child(victim)
	victim.position = Vector3(5.0, 0.0, 0.0)
	var clock := [0.0]
	var by_id := {&"k": killer, &"v": victim}
	var h := DotKillcamHost.new()
	h.no_id = &""
	h.players_fn = func() -> Array: return [killer, victim]
	h.player_for_fn = func(id: StringName) -> Variant: return by_id.get(id)
	h.id_of_fn = func(p: Node) -> Variant: return &"k" if p == killer else &"v"
	h.state_fn = func(p: Node) -> Array: return [(p as Node3D).position, 0.0, 0.0, true, 1.6]
	h.place_body_fn = func(p: Node3D, feet: Vector3, _y: float, shown: bool, _pi: float, _sp: float, touched: Dictionary) -> void:
		if not touched.has(p):
			touched[p] = [p.position, p.visible]
		p.visible = shown
		p.position = feet
	h.restore_body_fn = func(p: Node3D, saved: Array) -> void:
		p.position = saved[0]
		p.visible = saved[1]
	h.now_fn = func() -> float: return clock[0]
	h.seconds_fn = func() -> float: return 7.0
	h.camera_mode_fn = func() -> int: return DotKillViewRules.Camera.EYE
	h.can_play_fn = func(d: Dictionary) -> bool: return d["killer"] != d["victim"]
	h.pose_fn = func(_p: Node) -> PackedFloat32Array: return PackedFloat32Array([clock[0]])
	var drawn := {}
	h.apply_pose_fn = func(p: Node, a: PackedFloat32Array, b: PackedFloat32Array, t: float) -> void:
		drawn[p] = lerpf(a[0], b[0], t)
	var seen := {}
	h.event_fn = func(p: Node, ra: Array, rb: Array, _t: float, is_victim: bool) -> void:
		seen[p] = [ra.size(), rb.size(), is_victim]
	add_child(h)
	h.killcam.auto_process = false
	var ended: Array = []
	h.over.connect(func(skipped: bool) -> void: ended.append(skipped))
	while clock[0] < 9.5:
		clock[0] += STEP
		killer.position = Vector3(clock[0], 0.0, 0.0)
		h.frame()
		if absf(clock[0] - 8.0) < STEP * 0.5:
			h.note_kill(&"k", &"v", "rifle")
	_check(h.buffer.frame_count() > 400 and h.buffer.last_event(&"kill")["data"]["killer"] == &"k",
		"frames and the kill (with StringName ids) went into the buffer")
	_check(h.match_ended() and h.is_playing(), "the match's end starts the replay")
	h.killcam.advance(STEP)
	_check(h.camera.current and h.camera.global_position.y > 1.0, "the host's camera takes over at the killer's eye")
	_check(not killer.visible and victim.visible, "the killer's body is hidden in the eye view, the victim's shown")
	_check(drawn.has(victim) and not drawn.has(killer), "a shown body is drawn in its recorded pose, the hidden killer's is not")
	var shown_at := [0.0]
	h.killcam.frame_drawn.connect(func(s: Dictionary) -> void: shown_at[0] = s["time"])
	var worst := 0.0
	var n := 0
	while h.is_playing() and n < 1000:
		h.killcam.advance(STEP)
		if h.is_playing():
			worst = maxf(worst, absf(float(drawn.get(victim, -1.0)) - shown_at[0]))
		n += 1
	_check(worst < 0.001, "every replayed frame's pose is the one recorded at its moment (worst %.4f s off)" % worst)
	_check(h.poses.frame_count() < h.buffer.frame_count() * 0.6 and h.poses.frame_count() > 200,
		"poses are kept at pose_hz (%d), not every frame (%d)" % [h.poses.frame_count(), h.buffer.frame_count()])
	_check(seen.get(victim, []) == [5, 5, true] and seen.get(killer, []) == [5, 5, false],
		"event_fn is called for every body with the rows either side, and says which is the victim")
	_check(ended == [false] and h.touched.is_empty(), "it ends inside the budget and clears the moved bodies")
	_check(is_equal_approx(killer.position.x, 9.5) and killer.visible, "and restore_body_fn put the killer back")
	ended.clear()
	h.note_kill(&"k", &"k", "rifle")
	_check(not h.match_ended() and ended == [false], "can_play_fn refusing (a suicide) goes straight on")
	h.queue_free()
	killer.queue_free()
	victim.queue_free()
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
