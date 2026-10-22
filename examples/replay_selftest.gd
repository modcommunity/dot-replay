extends Node

## Exercises dot-replay end to end: record, write, read, seek, cut short, tamper, play.
##
## [b]The seeking section is the one to keep.[/b] It records a match whose state is a
## Dictionary folded from the records, keeps the true state at every tick while recording,
## and then asks the player for dozens of ticks — keyframe boundaries, the tick before one,
## the first, the last, past the end, backwards — and compares the state a seek reaches with
## the state the match actually had. A seek that is off by one record reads correctly on
## every check that does not look at a boundary.
##
## Files go under [code]user://dot_replay_selftest[/code], which the suite empties first, so
## no run depends on the last one.
##
## [codeblock]
## godot --headless --path . res://examples/replay_selftest.tscn
## [/codeblock]

const SECTIONS := 12
const CHECKS := 111

const DIR := "user://dot_replay_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0
var _sections_finished := 0


# Stand-ins for the addons the taps duck-type against. Neither is installed here, and that
# is the point: the taps must work against anything of the right shape.

class FakeEvent extends RefCounted:
	var name: String = ""
	var data: Dictionary = {}
	var cancelled: bool = false
	var cancel_reason: String = ""


class FakeBus extends RefCounted:
	signal event_fired(event: Object)

	func fire(n: String, d: Dictionary, cancel: bool = false) -> void:
		var e := FakeEvent.new()
		e.name = n
		e.data = d
		e.cancelled = cancel
		e.cancel_reason = "filtered" if cancel else ""
		event_fired.emit(e)


class FakeSession extends RefCounted:
	func describe() -> Dictionary:
		return {"user_id": 7, "name": "seven"}


class FakeClock extends RefCounted:
	var tick: int = 0


class FakeManager extends RefCounted:
	var send_fn: Callable = Callable()
	var clock := FakeClock.new()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-replay self-test")
	_line("")
	_clean_dir()

	_test_config_and_header()
	_test_round_trip()
	_test_compression()
	_test_seeking()
	_test_truncation()
	_test_tamper()
	_test_version_and_bounds()
	_test_ring()
	_test_timing()
	_test_taps_and_filter()
	_test_limits()
	_test_user_cfg()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS or _sections_finished != SECTIONS:
		_line("ERROR: %d of %d sections ran, %d to their end." % [_section_count, SECTIONS, _sections_finished])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- The match every section records ----------------------------------------

## Folds one record into a state. The "game" whose correctness the seek checks measure.
static func _apply(state: Dictionary, r: DotReplayRecord) -> void:
	match String(r.channel):
		"ops":
			var op: Dictionary = r.value()
			var k := str(op["k"])
			if op.has("set"):
				state[k] = int(op["set"])
			else:
				state[k] = int(state.get(k, 0)) + int(op["add"])
		"blob":
			var sum := 0
			for b in r.data:
				sum += b
			state["blob_n"] = int(state.get("blob_n", 0)) + 1
			state["blob_sum"] = int(state.get("blob_sum", 0)) + sum
		_:
			state["other"] = int(state.get("other", 0)) + 1


## Records [param ticks] ticks of a deterministic match. Returns the true state after every
## tick, and appends every record it made to [param made].
func _record_match(
	rec: DotReplayRecorder, ticks: int, made: Array, seed_value: int = 7
) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var live: Dictionary = {}
	var truth: Array[Dictionary] = []
	rec.keyframe_fn = func(_t: int) -> Variant: return live.duplicate(true)
	for t in range(ticks):
		rec.advance(t)
		var n := rng.randi_range(0, 3)
		for i in range(n):
			var r: DotReplayRecord
			if rng.randf() < 0.7:
				var op := {"k": "k%d" % rng.randi_range(0, 5)}
				if rng.randf() < 0.3:
					op["set"] = rng.randi_range(-50, 50)
				else:
					op["add"] = rng.randi_range(1, 9)
				rec.record_value(t, &"ops", op)
				r = DotReplayRecord.new(t, &"ops", var_to_bytes(op), DotReplayRecord.FLAG_VARIANT)
			else:
				var blob := PackedByteArray()
				for j in range(rng.randi_range(0, 12)):
					blob.append(rng.randi_range(0, 255))
				rec.record(t, &"blob", blob)
				r = DotReplayRecord.new(t, &"blob", blob, 0)
			_apply(live, r)
			made.append(r)
		truth.append(live.duplicate(true))
	return truth


func _new_recorder(chunk_ticks: int = 16, keyframe_every: int = 64) -> DotReplayRecorder:
	var rec := DotReplayRecorder.new()
	rec.chunk_ticks = chunk_ticks
	rec.keyframe_interval_ticks = keyframe_every
	return rec


func _header(tick_rate: int = 64) -> DotReplayHeader:
	return DotReplayHeader.make(
		"selftest", "dm_box", tick_rate,
		[{"id": 1, "name": "one"}, {"id": 2, "name": "two"}],
		{"server": "local", "round": 3}
	)


## Records a match to [param path] and finishes it. Returns [truth, made records].
func _write_match(
	path: String, ticks: int, key := PackedByteArray(), keyframe_every: int = 64, seed_value: int = 7
) -> Array:
	var rec := _new_recorder(16, keyframe_every)
	var started := rec.start(_header(), path, key)
	if not started.ok:
		_line("  (could not start %s: %s)" % [path, started.error])
	var made: Array = []
	var truth := _record_match(rec, ticks, made, seed_value)
	rec.stop()
	return [truth, made]


# --- 1 ----------------------------------------------------------------------

func _test_config_and_header() -> void:
	_section("Configuration and header")

	var c := DotReplayConfig.new()
	_check(c.validate().ok, "a default configuration validates")
	c.compression = "lzma"
	_check(not c.validate().ok, "an unknown compression is refused by name")
	c.compression = "zstd"
	c.keyframe_seconds = 0.5
	_check(not c.validate().ok, "keyframes more often than chunks are refused, not guessed at")
	c.keyframe_seconds = 10.0

	var rec := DotReplayRecorder.new()
	_check(rec.configure(c, 64).ok and rec.chunk_ticks == 64 and rec.keyframe_interval_ticks == 640,
		"seconds become ticks at the game's rate: 1 s chunks and 10 s keyframes at 64 Hz")
	_check(rec.ring != null and rec.ring.window_ticks == 3840, "and the ring's 60 s is 3840 ticks")

	var h := _header()
	var back := DotReplayHeader.from_bytes(h.to_bytes())
	_check(back.ok and DotValue.same_dictionary((back.value as DotReplayHeader).to_dictionary(), h.to_dictionary()),
		"a header survives its own encoding")
	h.meta["session"] = FakeSession.new()
	_check(not h.validate().ok, "a header carrying an object is refused")
	_check(c.path_for(_header()).ends_with(".dreplay") and c.path_for(_header()).contains("selftest_dm_box_"),
		"a demo's file name says the game and the map")
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_round_trip() -> void:
	_section("Round trip: what was recorded is what is read")

	var path := DIR.path_join("round_trip.dreplay")
	var rec := _new_recorder()
	var started := rec.start(_header(), path)
	_check(started.ok, "recording starts")
	var made: Array = []
	var truth := _record_match(rec, 400, made)
	var stopped := rec.stop()
	_check(stopped.ok, "and stops")
	var evidence: Dictionary = stopped.value if stopped.ok else {}
	_check(str(evidence.get("final_hash", "")).length() == 64, "stopping returns evidence with a final hash")

	var f := DotReplayFile.new()
	var opened := f.open(path)
	_check(opened.ok and f.complete and not f.truncated, "the file opens complete")
	_check(f.final_hash == str(evidence.get("final_hash", "")), "and its footer hash is the one the evidence recorded")
	_check(f.header != null and f.header.game == "selftest" and f.header.map == "dm_box"
		and f.header.tick_rate == 64 and f.header.players.size() == 2 and int(f.header.meta.get("round", 0)) == 3,
		"the header says the game, the map, the rate, the players and the meta")

	var all := f.read_all()
	var records: Array = []
	if all.ok:
		for r in all.value:
			if not (r as DotReplayRecord).is_keyframe():
				records.append(r)
	_check(records.size() == made.size(), "every record comes back (%d of %d)" % [records.size(), made.size()])
	var same := records.size() == made.size()
	for i in range(mini(records.size(), made.size())):
		var a: DotReplayRecord = records[i]
		var b: DotReplayRecord = made[i]
		if a.tick != b.tick or a.channel != b.channel or a.data != b.data or a.flags != b.flags:
			same = false
			break
	_check(same, "in order, each with its tick, channel, bytes and flags")

	var state: Dictionary = {}
	for r in records:
		_apply(state, r)
	_check(DotValue.same_dictionary(state, truth[truth.size() - 1]), "and folding them gives the match's final state")

	var keyframes := 0
	for i in range(f.chunk_count()):
		if f.chunk_info(i).starts_with_keyframe():
			keyframes += 1
	_check(keyframes == 7, "a keyframe every 64 ticks over 400 is seven, each starting a chunk (%d)" % keyframes)
	# The last tick with a record, not the last tick recorded: the match is random, and a
	# tick with nothing in it leaves nothing in the file.
	var last_made: int = (made[made.size() - 1] as DotReplayRecord).tick if not made.is_empty() else -1
	_check(f.first_tick() == 0 and f.last_tick() == last_made,
		"the index knows the first and last tick (%d-%d, last record at %d)" % [f.first_tick(), f.last_tick(), last_made])
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_compression() -> void:
	_section("Compression shrinks a repetitive stream, and only when it helps")

	var raw_total := 0
	var paths := {}
	for mode in [DotReplayFormat.COMPRESSION_NONE, DotReplayFormat.COMPRESSION_ZSTD, DotReplayFormat.COMPRESSION_DEFLATE]:
		var path := DIR.path_join("compress_%d.dreplay" % mode)
		var rec := _new_recorder(64, 0)
		rec.compression = mode
		rec.start(_header(), path)
		raw_total = 0
		for t in range(1000):
			var snap := {"tick": t % 4, "players": [{"x": 10, "y": 20, "hp": 100}, {"x": 11, "y": 20, "hp": 100}]}
			rec.record_value(t, &"snapshot", snap)
			raw_total += var_to_bytes(snap).size()
		rec.stop()
		paths[mode] = FileAccess.get_file_as_bytes(path).size()

	var none: int = paths[DotReplayFormat.COMPRESSION_NONE]
	var zstd: int = paths[DotReplayFormat.COMPRESSION_ZSTD]
	var deflate: int = paths[DotReplayFormat.COMPRESSION_DEFLATE]
	_check(none >= raw_total, "uncompressed, the file is at least the payloads (%d >= %d)" % [none, raw_total])
	_check(zstd * 10 < none, "zstd makes a repetitive stream at least ten times smaller (%d vs %d)" % [zstd, none])
	_check(deflate * 5 < none, "deflate at least five times (%d vs %d)" % [deflate, none])

	var noisy: Array[DotReplayRecord] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	# One record: three already give zstd enough repeated framing to win by three bytes.
	for i in range(1):
		var b := PackedByteArray()
		for j in range(20):
			b.append(rng.randi_range(0, 255))
		noisy.append(DotReplayRecord.new(i, &"n", b, 0))
	var chunk := DotReplayChunk.build(noisy, DotReplayFormat.COMPRESSION_ZSTD)
	_check(chunk.compression == DotReplayFormat.COMPRESSION_NONE and chunk.stored.size() == chunk.raw_size,
		"a small random chunk that zstd would grow is stored raw")
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_seeking() -> void:
	_section("Seeking reaches exactly the state linear playback does")

	var path := DIR.path_join("seek.dreplay")
	var written := _write_match(path, 1000)
	var truth: Array[Dictionary] = written[0]

	var f := DotReplayFile.new()
	_check(f.open(path).ok, "the match opens")
	var player := _player()
	_check(player.load_file(f).ok, "and loads into a player")
	var state: Array = [{}]
	var resets: Array = []
	player.state_reset.connect(func(t: int, s: Variant) -> void:
		state[0] = (s as Dictionary).duplicate(true) if s is Dictionary else {}
		resets.append(t))
	player.record_played.connect(func(r: DotReplayRecord) -> void: _apply(state[0], r))

	# Linear first, all the way, checking every tick against the truth.
	player.play()
	var linear_ok := true
	for t in range(1000):
		if t > 0:
			player.step_ticks(1)
		else:
			player.poll()
		if not DotValue.same_dictionary(state[0], truth[t]):
			linear_ok = false
			_line("   linear diverged at tick %d" % t)
			break
	_check(linear_ok, "linear playback matches the match at every one of 1000 ticks")

	var targets: Array[int] = [0, 1, 63, 64, 65, 127, 128, 500, 511, 512, 513, 999, 5000, 640, 3, 960, 959]
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in range(30):
		targets.append(rng.randi_range(0, 999))
	var wrong: Array[int] = []
	for t in targets:
		player.seek(t)
		var expect: Dictionary = truth[clampi(t, 0, 999)]
		if not DotValue.same_dictionary(state[0], expect):
			wrong.append(t)
	_check(wrong.is_empty(), "%d seeks — boundaries, the ends, past the end, backwards — all match (wrong: %s)" % [targets.size(), wrong])
	_check(player.position_tick() == clampi(targets[targets.size() - 1], 0, 999), "the position is where the last seek put it")

	player.seek(600)
	var resets_before := resets.size()
	player.step_ticks(150)
	_check(DotValue.same_dictionary(state[0], truth[750]), "playing on 150 ticks after a seek lands on the right state")
	_check(resets.size() == resets_before, "and linear playback across keyframes does not reset the state")

	player.seek(700)
	_check(resets[resets.size() - 1] == 640, "a seek to 700 starts from the keyframe at 640, not the beginning")

	# The same match with no keyframes at all still seeks correctly, from the start.
	var bare := DIR.path_join("seek_bare.dreplay")
	var bare_written := _write_match(bare, 300, PackedByteArray(), 0)
	var bare_truth: Array[Dictionary] = bare_written[0]
	var bf := DotReplayFile.new()
	bf.open(bare)
	player.load_file(bf)
	var bare_wrong: Array[int] = []
	for t in [299, 5, 150, 0]:
		player.seek(t)
		if not DotValue.same_dictionary(state[0], bare_truth[t]):
			bare_wrong.append(t)
	_check(bare_wrong.is_empty() and resets[resets.size() - 1] == 0,
		"without keyframes a seek replays from the first record, and is still right")
	player.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_truncation() -> void:
	_section("A file cut short plays up to its last whole chunk")

	var path := DIR.path_join("whole.dreplay")
	var written := _write_match(path, 400)
	var made: Array = written[1]
	var full := DotReplayFile.new()
	full.open(path)
	var bytes := FileAccess.get_file_as_bytes(path)
	var n := full.chunk_count()

	# Cut in the middle of chunk 9: chunks 0-8 must survive, chunk 9 is gone.
	var cut_mid := full.chunk_offset(9) + 20
	var t1 := _write_bytes("cut_mid.dreplay", bytes.slice(0, cut_mid))
	var f1 := DotReplayFile.new()
	var r1 := f1.open(t1)
	_check(r1.ok and f1.truncated and not f1.complete, "a file cut inside a chunk opens, marked truncated")
	_check(f1.chunk_count() == 9 and f1.trailing_bytes == 20, "with the nine whole chunks before the cut, and 20 bytes lost")
	var recovered := f1.read_all()
	var expect := 0
	for r in made:
		if (r as DotReplayRecord).tick <= full.chunk_info(8).last_tick:
			expect += 1
	var got := 0
	if recovered.ok:
		for r in recovered.value:
			if not (r as DotReplayRecord).is_keyframe():
				got += 1
	_check(recovered.ok and got == expect, "and every record in them reads back (%d of %d)" % [got, expect])

	# Cut exactly on a chunk boundary: nothing partial, nothing lost beyond it.
	var t2 := _write_bytes("cut_edge.dreplay", bytes.slice(0, full.chunk_offset(5)))
	var f2 := DotReplayFile.new()
	_check(f2.open(t2).ok and f2.chunk_count() == 5 and f2.trailing_bytes == 0, "a cut on a chunk boundary keeps exactly the chunks before it")

	# The footer is the last thing written; lose one byte of it and every chunk is still whole.
	var t3 := _write_bytes("cut_footer.dreplay", bytes.slice(0, bytes.size() - 1))
	var f3 := DotReplayFile.new()
	_check(f3.open(t3).ok and f3.truncated and f3.chunk_count() == n and f3.trailing_bytes == 0,
		"a file missing one byte of its footer keeps all %d chunks, and lost no records" % n)

	# Only the header survived.
	var header_only := full.chunk_offset(0)
	var t4 := _write_bytes("cut_header.dreplay", bytes.slice(0, header_only))
	var f4 := DotReplayFile.new()
	_check(f4.open(t4).ok and f4.chunk_count() == 0 and f4.header.game == "selftest", "a file with only its header still says what it was")
	var t5 := _write_bytes("cut_inside_header.dreplay", bytes.slice(0, header_only - 5))
	_check(not DotReplayFile.new().open(t5).ok, "and one cut inside the header is refused")

	# A real crash: the recorder never reaches stop(). What was sealed is on disk.
	var crash := DIR.path_join("crash.dreplay")
	var rec := _new_recorder(16, 64)
	rec.start(_header(), crash)
	var crash_made: Array = []
	_record_match(rec, 250, crash_made)
	var last_sealed := -1
	rec.writer.abandon()
	var cf := DotReplayFile.new()
	var cr := cf.open(crash)
	if cr.ok and cf.chunk_count() > 0:
		last_sealed = cf.last_tick()
	_check(cr.ok and cf.truncated, "a recorder that never stopped leaves a file that opens")
	_check(last_sealed >= 249 - 16, "and it loses at most one chunk's worth of ticks (has up to %d of 249)" % last_sealed)
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_tamper() -> void:
	_section("An edited file is refused, and says where")

	var path := DIR.path_join("tamper.dreplay")
	_write_match(path, 300)
	var full := DotReplayFile.new()
	full.open(path)
	var bytes := FileAccess.get_file_as_bytes(path)

	# One byte inside chunk 3's payload.
	var flipped := bytes.duplicate()
	var at := full.chunk_offset(3) + DotReplayFormat.CHUNK_PREFIX_SIZE + 2
	flipped[at] = flipped[at] ^ 0x01
	var p1 := _write_bytes("t_chunk.dreplay", flipped)
	var r1 := DotReplayFile.new().open(p1)
	_check(not r1.ok and r1.code() == DotError.CODE_INTEGRITY, "one flipped bit in a chunk is an integrity failure")
	_check(not r1.ok and str(r1.error).contains("chunk 3"), "naming the chunk")

	var lazy := DotReplayFile.new()
	var lr := lazy.open(p1, PackedByteArray(), false)
	_check(lr.ok and lazy.read_chunk(2).ok, "opened without verifying, the chunks before it still read")
	var bad := lazy.read_chunk(3)
	_check(not bad.ok and bad.code() == DotError.CODE_INTEGRITY, "and the edited one is refused when it is read")

	# The header.
	var h := bytes.duplicate()
	h[DotReplayFormat.PREAMBLE_SIZE + 3] = h[DotReplayFormat.PREAMBLE_SIZE + 3] ^ 0x20
	var r2 := DotReplayFile.new().open(_write_bytes("t_header.dreplay", h))
	_check(not r2.ok and r2.code() == DotError.CODE_INTEGRITY, "an edited header is refused")

	# The index: a chunk's tick range rewritten.
	var ix := bytes.duplicate()
	var index_at := bytes.size() - DotReplayFormat.FOOTER_SIZE - (8 + full.chunk_count() * DotReplayFormat.INDEX_ENTRY_SIZE)
	ix[index_at + 8 + 8] = ix[index_at + 8 + 8] ^ 0x01
	var r3 := DotReplayFile.new().open(_write_bytes("t_index.dreplay", ix))
	_check(not r3.ok and r3.code() == DotError.CODE_INTEGRITY, "an edited index is refused")

	# Thirty seconds cut out of the middle, footer stripped so it looks like a crash.
	var spliced := bytes.slice(0, full.chunk_offset(4))
	spliced.append_array(bytes.slice(full.chunk_offset(6), full.chunk_offset(9)))
	var r4 := DotReplayFile.new().open(_write_bytes("t_splice.dreplay", spliced))
	_check(not r4.ok and r4.code() == DotError.CODE_INTEGRITY,
		"chunks removed from the middle are refused, even disguised as a crash — the chain notices")

	# A chunk transplanted from ANOTHER recording, at the same position, footer stripped. Its
	# own hash is right and its sequence number is right; only the chain can see that it
	# follows a chunk it was never written after. This is the check that fails with the
	# chain taken out — the splice above is caught by the sequence number alone.
	var other_path := DIR.path_join("tamper_other.dreplay")
	_write_match(other_path, 300, PackedByteArray(), 64, 99)
	var other := DotReplayFile.new()
	other.open(other_path)
	var other_bytes := FileAccess.get_file_as_bytes(other_path)
	var transplant := bytes.slice(0, full.chunk_offset(3))
	transplant.append_array(other_bytes.slice(other.chunk_offset(3), other.chunk_offset(4)))
	transplant.append_array(bytes.slice(full.chunk_offset(4), full.chunk_offset(8)))
	var r6 := DotReplayFile.new().open(_write_bytes("t_transplant.dreplay", transplant))
	_check(not r6.ok and r6.code() == DotError.CODE_INTEGRITY,
		"a chunk moved in from another recording at the same position is refused")

	# A crash and an edit together: the edit is not excused by the crash.
	var both := bytes.slice(0, full.chunk_offset(8) + 10)
	both[full.chunk_offset(1) + DotReplayFormat.CHUNK_PREFIX_SIZE] ^= 0x04
	var r5 := DotReplayFile.new().open(_write_bytes("t_both.dreplay", both))
	_check(not r5.ok and r5.code() == DotError.CODE_INTEGRITY, "a truncated file with an edited chunk is refused, not recovered")

	# Keyed.
	var key := "moderation-secret".to_utf8_buffer()
	var kpath := DIR.path_join("keyed.dreplay")
	_write_match(kpath, 120, key)
	_check(DotReplayFile.new().open(kpath, key).ok, "a keyed file opens with its key")
	var nokey := DotReplayFile.new().open(kpath)
	_check(not nokey.ok and nokey.code() == DotError.CODE_AUTH, "and is refused without one")
	var wrong := DotReplayFile.new().open(kpath, "guess".to_utf8_buffer())
	_check(not wrong.ok and wrong.code() == DotError.CODE_INTEGRITY, "and with the wrong one")
	var unkeyed := DotReplayFile.new().open(path, key)
	_check(not unkeyed.ok and unkeyed.code() == DotError.CODE_INTEGRITY,
		"an unkeyed file is not accepted as verified under a key")
	_done()


# --- 7 ----------------------------------------------------------------------

func _test_version_and_bounds() -> void:
	_section("A newer version, a wrong file and a decompression bomb are refused")

	var path := DIR.path_join("version.dreplay")
	_write_match(path, 50)
	var bytes := FileAccess.get_file_as_bytes(path)

	var newer := bytes.duplicate()
	newer.encode_u16(4, DotReplayFormat.VERSION + 1)
	var r1 := DotReplayFile.new().open(_write_bytes("v_newer.dreplay", newer))
	_check(not r1.ok and r1.code() == DotError.CODE_VERSION, "a file from a newer format version is refused as a version problem")
	_check(not r1.ok and str(r1.error).contains("version 2"), "saying which version it was")

	var zero := bytes.duplicate()
	zero.encode_u16(4, 0)
	_check(DotReplayFile.new().open(_write_bytes("v_zero.dreplay", zero)).code() == DotError.CODE_VERSION, "and so is version 0")

	var other := bytes.duplicate()
	other[0] = 0x44
	other[1] = 0x52
	other[2] = 0x50
	other[3] = 0x31  # dot-timer's run replays start "DRP1"
	var r2 := DotReplayFile.new().open(_write_bytes("v_magic.dreplay", other))
	_check(not r2.ok and r2.code() == DotError.CODE_PARSE, "a file that is not a match demo is refused as one")

	# A chunk that declares a huge unpacked size. Its hash is valid — it was written that way —
	# so only the reader's bound stands between it and a four-gigabyte allocation.
	var bomb_path := DIR.path_join("bomb.dreplay")
	var w := DotReplayWriter.new()
	w.open(bomb_path, _header())
	var recs: Array[DotReplayRecord] = [DotReplayRecord.new(0, &"x", PackedByteArray([1, 2, 3]), 0)]
	var chunk := DotReplayChunk.build(recs, DotReplayFormat.COMPRESSION_NONE)
	chunk.raw_size = 0x7FFFFFFF
	w.write_chunk(chunk)
	w.finish()
	var bf := DotReplayFile.new()
	var opened := bf.open(bomb_path)
	var read := bf.read_chunk(0)
	_check(opened.ok and not read.ok and read.code() == DotError.CODE_QUOTA,
		"a chunk declaring 2 GB unpacked is refused before anything is allocated")
	_done()


# --- 8 ----------------------------------------------------------------------

func _test_ring() -> void:
	_section("The ring keeps the last N seconds, from a keyframe, within its bytes")

	var rec := _new_recorder(16, 64)
	rec.ring = DotReplayRing.new()
	rec.ring.window_ticks = 128
	var path := DIR.path_join("ring_full.dreplay")
	rec.start(_header(), path)
	var made: Array = []
	var truth := _record_match(rec, 1000, made)
	rec.flush()
	var ring := rec.ring
	var span := ring.last_tick() - ring.first_tick()
	_check(ring.starts_with_keyframe(), "what the ring holds begins with a keyframe")
	_check(ring.last_tick() == 999, "and runs to the last tick recorded")
	_check(span >= 128, "it holds at least the window (%d ticks >= 128)" % span)
	_check(span <= 128 + 64 + 16, "and at most a keyframe interval and a chunk more (%d <= 208)" % span)
	_check(ring.bytes_held() <= ring.max_bytes, "inside its byte ceiling")

	var clip_path := DIR.path_join("clip.dreplay")
	var saved := rec.save_clip(clip_path, 1.0)
	_check(saved.ok, "save_clip writes a file")
	var clip := DotReplayFile.new()
	_check(clip.open(clip_path).ok and clip.complete, "which opens complete")
	_check(clip.chunk_info(0).starts_with_keyframe() and clip.first_tick() <= 999 - 64,
		"starting at a keyframe at least one second back (from %d)" % clip.first_tick())
	var meta_clip: Variant = clip.header.meta.get("clip", {})
	_check(meta_clip is Dictionary and bool((meta_clip as Dictionary).get("starts_at_keyframe", false))
		and clip.header.game == "selftest", "and its header says it is a clip of the match")

	var player := _player()
	player.load_file(clip)
	var state: Array = [{}]
	player.state_reset.connect(func(_t: int, s: Variant) -> void:
		state[0] = (s as Dictionary).duplicate(true) if s is Dictionary else {})
	player.record_played.connect(func(r: DotReplayRecord) -> void: _apply(state[0], r))
	player.seek(999)
	_check(DotValue.same_dictionary(state[0], truth[999]), "the clip plays to the same final state as the match")
	player.seek(clip.first_tick() + 10)
	_check(DotValue.same_dictionary(state[0], truth[clip.first_tick() + 10]), "and seeks within itself correctly")
	player.queue_free()
	rec.stop()

	# The byte ceiling beats the keyframe rule.
	var tight := DotReplayRing.new()
	tight.window_ticks = 100000
	tight.max_bytes = 3000
	var rec2 := _new_recorder(8, 0)
	rec2.ring = tight
	rec2.start(_header())
	for t in range(2000):
		rec2.advance(t)
		rec2.record(t, &"blob", PackedByteArray([t % 256, 1, 2, 3, 4, 5, 6, 7]))
	rec2.flush()
	_check(tight.bytes_held() <= 3000 and tight.chunk_count() >= 1, "a ring over its bytes drops the oldest (%d bytes held)" % tight.bytes_held())
	_check(tight.last_tick() == 1999, "and keeps the newest")
	_done()


# --- 9 ----------------------------------------------------------------------

func _test_timing() -> void:
	_section("Speed and pause, against an injected clock")

	var path := DIR.path_join("timing.dreplay")
	var rec := _new_recorder(16, 0)
	rec.start(_header(64), path)
	for t in range(640):
		rec.advance(t)
		rec.record_value(t, &"tick", t)
	rec.stop()

	var f := DotReplayFile.new()
	f.open(path)
	var clock: Array = [0.0]
	var player := _player()
	player.now_fn = func() -> float: return float(clock[0])
	player.load_file(f)
	var got: Array = []
	var done: Array = []
	player.record_played.connect(func(r: DotReplayRecord) -> void: got.append(int(r.value())))
	player.finished.connect(func() -> void: done.append(true))

	player.play()
	player.poll()
	_check(player.position_tick() == 0 and got.size() == 1, "playing emits the first tick at once")
	clock[0] = 0.5
	player.poll()
	_check(player.position_tick() == 32 and got.size() == 33, "half a second at 1x is 32 ticks at 64 Hz")
	player.set_speed(2.0)
	clock[0] = 1.0
	player.poll()
	_check(player.position_tick() == 96, "half a second more at 2x is 64 more (%d)" % player.position_tick())

	player.pause()
	clock[0] = 3.0
	var during := player.poll()
	_check(during == 0 and player.position_tick() == 96, "paused, two seconds pass and nothing plays")
	player.resume()
	clock[0] = 3.25
	player.poll()
	_check(player.position_tick() == 128, "resumed, time counts from the resume, not from the pause (%d)" % player.position_tick())

	player.set_speed(100.0)
	_check(is_equal_approx(player.speed(), 8.0), "speed is clamped to 8x")
	player.set_speed(0.01)
	_check(is_equal_approx(player.speed(), 0.25), "and to 0.25x")
	clock[0] = 4.25
	player.poll()
	_check(player.position_tick() == 144, "a second at 0.25x is 16 ticks (%d)" % player.position_tick())

	var in_order := true
	for i in range(got.size()):
		if int(got[i]) != i:
			in_order = false
	_check(in_order and got.size() == 145, "every tick emitted once, in order, none skipped (%d)" % got.size())

	player.set_speed(8.0)
	clock[0] = 20.0
	player.poll()
	_check(done.size() == 1 and player.is_finished() and got.size() == 640, "at 8x it runs out, emits finished once, and every record played")
	clock[0] = 30.0
	player.poll()
	_check(done.size() == 1 and got.size() == 640, "and polling afterwards plays nothing more")
	player.queue_free()
	_done()


# --- 10 ---------------------------------------------------------------------

func _test_taps_and_filter() -> void:
	_section("The taps record through duck typing; the player filters by channel")

	var path := DIR.path_join("taps.dreplay")
	var rec := _new_recorder(16, 0)
	rec.start(_header(), path)
	var now: Array = [0]

	var bus := FakeBus.new()
	var tap := DotReplayEventTap.new()
	tap.recorder = rec
	_check(not tap.attach(bus).ok, "an event tap without a tick source is refused")
	tap.tick_fn = func() -> int: return int(now[0])
	_check(tap.attach(bus).ok, "and attaches to anything with event_fired")
	var cb := func() -> void: pass
	bus.fire("client_spawn", {"userid": 3, "session": FakeSession.new(), "cb": cb})
	now[0] = 2
	bus.fire("player_chat", {"text": "hello"}, true)

	var manager := FakeManager.new()
	var sent: Array = []
	var original := func(peer: int, payload: PackedByteArray, _delivery: int) -> void: sent.append([peer, payload.size()])
	manager.send_fn = original
	var net := DotReplayNetTap.new()
	net.recorder = rec
	net.peer_id = 2
	_check(net.attach(manager).ok and manager.send_fn != original, "a net tap wraps a manager's send_fn")
	manager.clock.tick = 3
	now[0] = 3
	manager.send_fn.call(2, PackedByteArray([1, 2, 3]), 1)
	manager.send_fn.call(5, PackedByteArray([9]), 1)
	manager.send_fn.call(0, PackedByteArray([7, 7]), 2)
	_check(sent.size() == 3, "every send still reaches the network")
	net.detach()
	_check(manager.send_fn == original, "and detaching puts the original back")
	now[0] = 4
	rec.record_value(4, &"chat", "gg")
	tap.detach()
	bus.fire("client_spawn", {"userid": 4})
	rec.stop()

	var f := DotReplayFile.new()
	f.open(path)
	var all: Array = f.read_all().value
	var events: Array = all.filter(func(r: DotReplayRecord) -> bool: return r.channel == &"events")
	var nets: Array = all.filter(func(r: DotReplayRecord) -> bool: return r.channel == &"net")
	_check(events.size() == 2, "two events recorded, none after detaching (%d)" % events.size())
	var spawn: Dictionary = (events[0] as DotReplayRecord).value() if events.size() > 0 else {}
	var data: Dictionary = spawn.get("data", {})
	_check(data.get("session", {}) is Dictionary and int((data.get("session", {}) as Dictionary).get("user_id", 0)) == 7
		and data.has("cb") and data["cb"] == null,
		"a session object is recorded as its describe(), a callable as nothing")
	var chat: Dictionary = (events[1] as DotReplayRecord).value() if events.size() > 1 else {}
	_check(bool(chat.get("cancelled", false)) and (events[1] as DotReplayRecord).tick == 2,
		"a cancelled event is recorded as cancelled, at the tick it was fired")
	_check(nets.size() == 2, "the net tap kept peer 2's payload and the broadcast, not peer 5's (%d)" % nets.size())
	var first_net: Dictionary = (nets[0] as DotReplayRecord).value() if nets.size() > 0 else {}
	_check(first_net.get("payload", PackedByteArray()) == PackedByteArray([1, 2, 3]) and (nets[0] as DotReplayRecord).tick == 3,
		"with its bytes intact, at the manager's own tick")

	var player := _player()
	player.load_file(f)
	var seen: Array = []
	player.record_played.connect(func(r: DotReplayRecord) -> void: seen.append(String(r.channel)))
	player.set_channels(["chat", "net"])
	player.seek(f.last_tick())
	_check(seen == ["net", "net", "chat"], "a channel filter plays only those channels, seeks included (%s)" % [seen])

	# Nothing else calls these, and a format string with the wrong arity aborts at runtime.
	var described := PackedStringArray()
	for thing: Object in [rec, rec.writer, f, player, tap, net, f.header, DotReplayConfig.new(), DotReplayRing.new()]:
		var lines: PackedStringArray = thing.call("describe_lines")
		if lines.is_empty() or lines[0] == "":
			described.append(thing.get_class())
		else:
			_line("        %s" % lines[0])
	_check(described.is_empty(), "every piece describes itself in a line (silent: %s)" % [described])
	player.queue_free()
	_done()


# --- 11 ---------------------------------------------------------------------

func _test_limits() -> void:
	_section("Size limits, refusals, and a file that stops cleanly")

	var rec := _new_recorder(4, 0)
	rec.max_record_bytes = 64
	var path := DIR.path_join("limits.dreplay")
	rec.max_file_bytes = 4096
	rec.start(_header(), path)
	var stopped: Array = []
	rec.file_stopped.connect(func(r: DotResult) -> void: stopped.append(r.code()))

	var big := PackedByteArray()
	big.resize(65)
	var r1 := rec.record(0, &"x", big)
	_check(not r1.ok and r1.code() == DotError.CODE_QUOTA, "a record over the size limit is refused")
	_check(rec.record_value(0, &"x", {"o": FakeSession.new()}).code() == DotError.CODE_INVALID, "an object in a record is refused")
	_check(rec.record(0, DotReplayFormat.KEYFRAME_CHANNEL, PackedByteArray()).code() == DotError.CODE_INVALID,
		"a record cannot pretend to be a keyframe")
	rec.record(10, &"x", PackedByteArray([1]))
	_check(rec.record(9, &"x", PackedByteArray([1])).code() == DotError.CODE_INVALID, "ticks only move forward")

	var quota_seen := false
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for t in range(11, 2000):
		var noise := PackedByteArray()
		for j in range(40):
			noise.append(rng.randi_range(0, 255))
		var r := rec.record(t, &"x", noise)
		if not r.ok and r.code() == DotError.CODE_QUOTA:
			quota_seen = true
	_check(quota_seen and stopped.size() == 1, "the file limit stops the file once, and says so")
	_check(not rec.is_recording_to_file(), "after which it is no longer being written")
	rec.stop()
	var size := FileAccess.get_file_as_bytes(path).size()
	var f := DotReplayFile.new()
	_check(f.open(path).ok and f.complete and size <= 4096, "and what is on disk is complete, verified and inside the limit (%d bytes)" % size)
	_done()


# --- Harness ---------------------------------------------------------------

func _player() -> DotReplayPlayer:
	var p := DotReplayPlayer.new()
	p.auto_process = false
	# A clock that never moves unless a section moves it: step_ticks and seek are then the
	# only things that advance playback, and no check depends on how fast this machine is.
	p.now_fn = func() -> float: return 0.0
	add_child(p)
	return p


func _write_bytes(file_name: String, bytes: PackedByteArray) -> String:
	var p := DIR.path_join(file_name)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	return p


func _clean_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var d := DirAccess.open(DIR)
	if d == null:
		return
	for file_name in d.get_files():
		d.remove(file_name)


# --- 12 ---------------------------------------------------------------------

func _test_user_cfg() -> void:
	_section("replay.yml: defaults, file, user tier, schema")
	var base := "user://cfg/addons/dot_replay"
	var user := "user://cfg/user/addons/dot_replay"
	DotPaths.remove_tree(base)
	DotPaths.remove_tree(user)
	DotAddonConfig.set_user_tier(false)

	var c := DotReplayConfig.new()
	_check(c.load_cfg("replay.yml", "").ok and c.ring_seconds == 60.0 and c.keyframe_seconds == 10.0 and c.compression == "zstd", "no file: the exported defaults")

	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base.path_join("replay.yml"), FileAccess.WRITE)
	f.store_string("replay_ring_seconds: 120.0\nreplay_compression: gzip\n")
	f.close()
	c = DotReplayConfig.new()
	_check(c.load_cfg("replay.yml", "").ok and c.ring_seconds == 120.0 and c.compression == "gzip", "the file overrides the defaults")

	var entry := DotReplayConfig.user_cfg_entry()
	DotAddonConfig.set_user_tier(true)
	var saved := DotAddonConfig.save_user("dot-replay", "replay.yml", {"replay_ring_seconds": 200.0}, entry["schema"])
	_check(saved.ok, "a player's value inside the range is saved")
	c = DotReplayConfig.new()
	_check(c.load_cfg("replay.yml", "").ok and c.ring_seconds == 200.0 and c.compression == "gzip", "the user tier wins over the file, other keys stay")

	DotAddonConfig.set_user_tier(false)
	c = DotReplayConfig.new()
	_check(c.load_cfg("replay.yml", "").ok and c.ring_seconds == 120.0, "with the tier off the player's file is ignored")

	DotAddonConfig.set_user_tier(true)
	var bad := DotAddonConfig.save_user("dot-replay", "replay.yml", {"replay_ring_seconds": 99999.0}, entry["schema"])
	_check(not bad.ok and bad.code() == DotError.CODE_INVALID, "the schema refuses an out-of-range value")
	var bad2 := DotAddonConfig.save_user("dot-replay", "replay.yml", {"replay_compression": "lzma"}, entry["schema"])
	_check(not bad2.ok, "and an unknown compression")

	var names := []
	for e in entry["schema"]:
		names.append(e["name"])
	_check(entry["addon"] == "dot-replay" and entry["file"] == "replay.yml" and entry["label"] != "" and names == ["replay_ring_seconds", "replay_keyframe_seconds", "replay_compression"], "the entry has addon, file, label and the three fields")
	_check(entry["schema"][0]["max"] == 3600.0 and entry["schema"][1]["max"] == 600.0, "ranges come from the exports")

	DotAddonConfig.set_user_tier(false)
	DotPaths.remove_tree(base)
	DotPaths.remove_tree(user)
	_done()


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_sections_finished += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
