class_name DotReplayEventTap
extends RefCounted

## Records every game event a bus fires, with its data and whether a hook cancelled it.
## Duck-typed on an [code]event_fired(event)[/code] signal so dot-server is not required.
## Cancelled events are kept by default (what somebody tried matters for moderation); sessions in data become their [code]describe()[/code].

const CHANNEL := "replay"

var recorder: DotReplayRecorder = null

## [code]func() -> int[/code]: the server's current tick. Required — a bus knows nothing
## about ticks.
var tick_fn: Callable = Callable()

## The replay channel events are recorded on.
var channel: StringName = &"events"

## Only these event names. Empty records every event.
var names: PackedStringArray = PackedStringArray()

var include_cancelled: bool = true

var _bus: Object = null
var _recorded: int = 0
var _failed: int = 0


func attach(bus: Object) -> DotResult:
	if bus == null or not bus.has_signal("event_fired"):
		return DotResult.fail(DotError.CODE_INVALID, "That has no event_fired signal to record.")
	if not tick_fn.is_valid():
		return DotResult.fail(DotError.CODE_INVALID, "An event tap needs tick_fn: the bus does not know the tick.")
	detach()
	_bus = bus
	bus.connect("event_fired", _on_event)
	return DotResult.success(self)


func detach() -> void:
	if _bus != null and is_instance_valid(_bus) and _bus.is_connected("event_fired", _on_event):
		_bus.disconnect("event_fired", _on_event)
	_bus = null


func _on_event(event: Object) -> void:
	if recorder == null or not recorder.is_recording() or event == null:
		return
	var event_name := str(event.get("name"))
	if not names.is_empty() and not names.has(event_name):
		return
	var cancelled := bool(event.get("cancelled"))
	if cancelled and not include_cancelled:
		return
	var entry := {
		"name": event_name,
		"data": DotReplayFormat.plain(event.get("data")),
	}
	if cancelled:
		entry["cancelled"] = true
		entry["cancel_reason"] = str(event.get("cancel_reason"))
	var r := recorder.record_value(int(tick_fn.call()), channel, entry)
	if r.ok:
		_recorded += 1
	else:
		_failed += 1
		DotLog.debug(CHANNEL, "event not recorded", {"event": event_name, "why": str(r.error)})


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"replay event tap: %s, %d recorded, %d refused, on '%s'%s" % [
			"attached" if _bus != null else "detached", _recorded, _failed, channel,
			"" if names.is_empty() else " (%s)" % ", ".join(names),
		],
	])
