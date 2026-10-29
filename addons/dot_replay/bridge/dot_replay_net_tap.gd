class_name DotReplayNetTap
extends RefCounted

## Records the payloads a netcode manager sends through its [code]send_fn[/code], for one [member peer_id] (-1: all).
## One peer only: each peer's deltas decode against its own acks, so mixed streams decode as neither.
## The payloads are deltas, so seeking needs the game's [member DotReplayRecorder.keyframe_fn].

const CHANNEL := "replay"

var recorder: DotReplayRecorder = null

## [code]func() -> int[/code]. Empty reads [code]manager.clock.tick[/code] if there is one.
var tick_fn: Callable = Callable()

var channel: StringName = &"net"

## The peer whose stream is recorded. 0 (broadcast) sends are always recorded, since they
## reach it too. -1 records every peer.
var peer_id: int = -1

var _manager: Object = null
var _original: Callable = Callable()
var _wrapper: Callable = Callable()
var _recorded: int = 0
var _bytes: int = 0


func attach(manager: Object) -> DotResult:
	if manager == null or not ("send_fn" in manager):
		return DotResult.fail(DotError.CODE_INVALID, "That has no send_fn to record.")
	detach()
	_manager = manager
	var current: Variant = manager.get("send_fn")
	_original = current if current is Callable else Callable()
	_wrapper = _on_send
	manager.set("send_fn", _wrapper)
	return DotResult.success(self)


## Puts the original send_fn back — but only if the manager still holds this tap's, so a
## host that replaced it since is not undone.
func detach() -> void:
	if _manager != null and is_instance_valid(_manager):
		var current: Variant = _manager.get("send_fn")
		if current is Callable and current == _wrapper:
			_manager.set("send_fn", _original)
	_manager = null
	_original = Callable()


func _on_send(to_peer: int, payload: PackedByteArray, delivery: int) -> void:
	if _original.is_valid():
		_original.call(to_peer, payload, delivery)
	if recorder == null or not recorder.is_recording():
		return
	if peer_id >= 0 and to_peer != peer_id and to_peer != 0:
		return
	var r := recorder.record_value(_tick(), channel, {
		"peer": to_peer, "delivery": delivery, "payload": payload,
	})
	if r.ok:
		_recorded += 1
		_bytes += payload.size()
	else:
		DotLog.debug(CHANNEL, "net payload not recorded", {"why": str(r.error)})


func _tick() -> int:
	if tick_fn.is_valid():
		return int(tick_fn.call())
	if _manager != null and "clock" in _manager:
		var clock: Variant = _manager.get("clock")
		if clock is Object and "tick" in (clock as Object):
			return int((clock as Object).get("tick"))
	return 0


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"replay net tap: %s, peer %s, %d payload(s), %d bytes" % [
			"attached" if _manager != null else "detached",
			"all" if peer_id < 0 else str(peer_id), _recorded, _bytes,
		],
	])
