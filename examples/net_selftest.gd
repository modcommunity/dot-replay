extends Node

## Runs DotReplayNetTap against a real dot-net server and clients in one process, records a
## short session, plays it back into a fresh client and compares it with what was sent.
## Needs dot-net linked (see .gitignore); every other suite here runs without it.
##
## [codeblock]
## godot --headless --path . res://examples/net_selftest.tscn
## [/codeblock]

const SECTIONS := 1
const CHECKS := 16
const PATH := "user://dot_replay_net_selftest.dotreplay"
const TICKS := 60
const JOIN_AT := 30
const OBSERVER := 2
const LATE := 3

var _passed := 0
var _failed := 0
var _finished := 0


class Mover extends DotNetBehaviour:
	var position: Vector3 = Vector3.ZERO
	var health: int = 100

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION)
		replicate(&"health", DotNetVar.Type.UINT).bits(8)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("dot-replay net tap self-test")
	_test_real_stream()
	print("\n1 sections, %d passed, %d failed" % [_passed, _failed])
	if _finished != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections finished, %d checks ran, %d expected." % [_finished, _passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _manager(server: bool, peer: int, scope: String) -> DotNetManager:
	var m := DotNetManager.new()
	m.name = scope
	m.is_server = server
	m.service_scope = StringName(scope)
	m.local_peer_id = peer
	m.auto_tick = false
	m.config_file = ""
	m.config = DotNetConfig.new()
	m.config.tick_rate = 60
	m.config.snapshot_rate = 60
	add_child(m)
	var _s := m.setup()
	var _t := m.start()
	m.spawner.register_factory(&"mover", _build)
	return m


func _build(_ctx: Dictionary) -> Node:
	var body := Node3D.new()
	var identity := DotNetIdentity.new()
	identity.name = "NetIdentity"
	identity.prefab_id = &"mover"
	identity.authority = DotNetIdentity.Authority.SHARED
	body.add_child(identity)
	var mover := Mover.new()
	mover.name = "Mover"
	body.add_child(mover)
	identity.entity = body
	identity.behaviours = [mover]
	mover.identity = identity
	mover._bind(DotNetConfig.new())
	return body


func _mover(m: DotNetManager, net_id: int) -> Mover:
	return m.registry.get_identity(net_id).behaviours[0] as Mover


func _digest(payloads: Array) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for p: PackedByteArray in payloads:
		ctx.update(p)
	return ctx.finish().hex_encode()


func _player(f: DotReplayFile) -> DotReplayPlayer:
	var p := DotReplayPlayer.new()
	p.auto_process = false
	p.now_fn = func() -> float: return 0.0
	add_child(p)
	var _l := p.load_file(f)
	return p


func _test_real_stream() -> void:
	var server := _manager(true, 1, "nt_server")
	var seen := _manager(false, OBSERVER, "nt_observer")
	var late := _manager(false, LATE, "nt_late")
	server.add_peer(OBSERVER)

	var entity: DotNetIdentity = server.spawner.spawn(&"mover", 0, Transform3D.IDENTITY, 0).value
	var moved := entity.behaviours[0] as Mover
	var _r := seen.spawner.spawn_remote(&"mover", entity.net_id, 0, Transform3D.IDENTITY, 0)

	var now := [0]
	# What the network really carried: [tick, peer, payload, delivery], before any tap.
	var wire: Array = []
	var queue: Array = []
	server.send_fn = func(peer: int, payload: PackedByteArray, d: int) -> void:
		wire.append([now[0], peer, payload, d])
		queue.append([peer, payload, d])

	var rec := DotReplayRecorder.new()
	var _c := rec.configure(DotReplayConfig.new(), 60)
	var path := ProjectSettings.globalize_path(PATH)
	var started := rec.start(DotReplayHeader.make("nettest", "box", 60, [], {}), path)
	_check(started.ok, "a recorder starts")
	var tap := DotReplayNetTap.new()
	tap.recorder = rec
	tap.peer_id = OBSERVER
	_check(tap.attach(server).ok, "the tap wraps a real DotNetManager's send_fn")

	for s in range(1, TICKS + 1):
		now[0] = s
		if s == JOIN_AT:
			server.add_peer(LATE)
			var _l := late.spawner.spawn_remote(&"mover", entity.net_id, 0, Transform3D.IDENTITY, 0)
		moved.position += Vector3(0.5, 0.0, 0.25 * float(s % 5))
		moved.health = 100 - s
		var _a := rec.advance(s)
		server.server_tick(s)
		for q: Array in queue:
			if q[2] != DotNetMessage.Delivery.UNRELIABLE:
				continue
			if q[0] == OBSERVER:
				var _x := seen.receive_snapshot(q[1])
			elif q[0] == LATE:
				var _y := late.receive_snapshot(q[1])
		queue.clear()
		var _o := server.receive_ack_payload(OBSERVER, seen.encode_ack())
		if s >= JOIN_AT:
			var _p := server.receive_ack_payload(LATE, late.encode_ack())
	var _n := rec.stop()
	tap.detach()

	var expected: Array = wire.filter(func(w: Array) -> bool: return w[1] == OBSERVER or w[1] == 0)
	var others: Array = wire.filter(func(w: Array) -> bool: return w[1] != OBSERVER and w[1] != 0)
	_check(expected.size() >= TICKS, "the real server sent the observer a payload every tick (%d)" % expected.size())
	_check(not others.is_empty(), "and the late peer its own stream, which the tap must skip (%d)" % others.size())
	_check(_mover(late, entity.net_id).position != Vector3.ZERO, "the late peer really joined mid-stream")

	var f := DotReplayFile.new()
	_check(f.open(path).ok, "the recording opens")
	var records: Array = f.read_all().value
	var nets: Array = records.filter(func(r: DotReplayRecord) -> bool: return r.channel == &"net")
	_check(nets.size() == expected.size(), "as many records as payloads sent to the observer (%d of %d)" % [nets.size(), expected.size()])

	var same := nets.size() == expected.size()
	var got: Array = []
	var want: Array = []
	for i in range(mini(nets.size(), expected.size())):
		var v: Dictionary = (nets[i] as DotReplayRecord).value()
		var e: Array = expected[i]
		got.append(v["payload"])
		want.append(e[2])
		if int(v["peer"]) != int(e[1]) or int(v["delivery"]) != int(e[3]) or (nets[i] as DotReplayRecord).tick != int(e[0]):
			same = false
	_check(same, "peer, delivery and tick of every record match the send, in order")
	_check(not got.is_empty() and _digest(got) == _digest(want), "the recorded payload hash equals the hash of what was sent")

	# Replay from the first record into a fresh client that has the entity.
	var fresh := _manager(false, OBSERVER, "nt_replayed")
	var _f := fresh.spawner.spawn_remote(&"mover", entity.net_id, 0, Transform3D.IDENTITY, 0)
	var replayed: Array = []
	var applied := [0]
	var player := _player(f)
	player.record_played.connect(func(r: DotReplayRecord) -> void:
		if r.channel != &"net":
			return
		var v: Dictionary = r.value()
		replayed.append(v["payload"])
		if v["delivery"] == DotNetMessage.Delivery.UNRELIABLE and fresh.receive_snapshot(v["payload"]).ok:
			applied[0] += 1)
	var _p := player.play()
	var _e := player.step_ticks(TICKS + 5)
	_check(player.is_finished(), "playback finishes")
	_check(replayed.size() == expected.size(), "the replay emits every payload (%d)" % replayed.size())
	_check(_digest(replayed) == _digest(want), "and the replayed payload hash equals the sent one, in order")
	var final := _mover(fresh, entity.net_id)
	var original := _mover(seen, entity.net_id)
	_check(applied[0] > 0 and final.position.is_equal_approx(original.position) and final.health == original.health,
		"a fresh client fed the replay ends where the live observer did (%s, health %d)" % [final.position, final.health])
	_check(final.position.distance_to(moved.position) < 0.05, "and where the server was")

	# A client joining the playback mid-stream sees only the tail, which must be the sent tail.
	var tail: Array = []
	var joiner := _manager(false, OBSERVER, "nt_joiner")
	var _j := joiner.spawner.spawn_remote(&"mover", entity.net_id, 0, Transform3D.IDENTITY, 0)
	var tail_applied := [0]
	var late_player := _player(f)
	var _lp := late_player.play()
	var _s1 := late_player.step_ticks(JOIN_AT)
	var joined_at := late_player.position_tick()
	late_player.record_played.connect(func(r: DotReplayRecord) -> void:
		if r.channel != &"net":
			return
		var v: Dictionary = r.value()
		tail.append(v["payload"])
		if joiner.receive_snapshot(v["payload"]).ok:
			tail_applied[0] += 1)
	var _s2 := late_player.step_ticks(TICKS)
	var want_tail: Array = []
	for e: Array in expected:
		if int(e[0]) > joined_at:
			want_tail.append(e[2])
	_check(tail.size() == want_tail.size() and _digest(tail) == _digest(want_tail),
		"a client joining at tick %d gets exactly the sent tail, in order (%d payloads)" % [joined_at, tail.size()])
	var joined := _mover(joiner, entity.net_id)
	print("   info  mid-stream joiner applied %d snapshots, ends at %s (server %s)" % [tail_applied[0], joined.position, moved.position])
	_check(tail_applied[0] > 0 and joined.position.distance_to(moved.position) < 0.05,
		"and it decodes to the live state (the server acks deltas from the observer's baseline)")
	_finished += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
