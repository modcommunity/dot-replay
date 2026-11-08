class_name DotKillViewSolo
extends RefCounted

## The kill view for a standalone (offline) game, where the server half and the client are one process
## and there is no KILLVIEW message: wraps a [DotKillViewServer], runs its per-tick record and delivery,
## and hands the local player's clip straight to [member deliver_fn]. Other players' clips are dropped
## (nobody watches them). A game builds the server as it would for a dedicated one and gives it here.

## (clip: Dictionary, info: Dictionary) -> void: plays the local victim's clip.
var deliver_fn: Callable = Callable()

## () -> Variant: the local player's id as the server knows it (the same key as the eyes' ids); null when none yet.
var local_id_fn: Callable = Callable()

## () -> int: the game's current tick.
var tick_fn: Callable = Callable()

var server: DotKillViewServer = null


func _init(p_server: DotKillViewServer = null) -> void:
	server = p_server if p_server != null else DotKillViewServer.new()


## Whether the kill view is on; nothing records or delivers while it is not.
func enabled() -> bool:
	return server != null and server.rules.enabled


## Records this tick and delivers the local player's ready clip. Call once per game tick.
func tick(tick_number: int) -> void:
	if not enabled():
		return
	var now := float(tick_number) / float(server.tick_rate)
	server.record(now)
	var me: Variant = local_id_fn.call() if local_id_fn.is_valid() else null
	for ready: Dictionary in server.collect(now, tick_number):
		if me != null and ready["victim"] == me and deliver_fn.is_valid():
			deliver_fn.call(ready["clip"], ready["info"])


## A death, stamped with the current tick ([member tick_fn]) unless [param time] is given.
func note_kill(killer: Variant, victim: Variant, info: Dictionary = {}, time: float = -1.0) -> DotResult:
	if time < 0.0:
		time = float(tick_fn.call() if tick_fn.is_valid() else 0) / float(server.tick_rate)
	return server.note_kill(killer, victim, time, info)


## The local player skipped the replay: respawn now if held. False otherwise.
func skip() -> bool:
	var me: Variant = local_id_fn.call() if local_id_fn.is_valid() else null
	if me == null:
		return false
	return server.skip(me, int(tick_fn.call()) if tick_fn.is_valid() else 0)


func forget(id: Variant) -> void:
	server.forget(id)
