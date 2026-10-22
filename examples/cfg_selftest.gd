extends Node

## The yml layout of dot-replay's settings: new path, flat shim, operator layer.
##
## [codeblock]
## timeout 120 godot --headless --path . res://examples/cfg_selftest.tscn
## [/codeblock]

const FOLDER := "dot_replay"
const FILE := "replay.yml"
const LEGACY := "user://dot_replay_cfg_selftest_legacy"

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-replay cfg self-test")
	var addon_dir := "user://cfg/addons/" + FOLDER
	var server_dir := "user://cfg/server/addons/" + FOLDER
	_clean(addon_dir, server_dir)
	DotCfgLegacy.reset()

	_write(LEGACY.path_join(FILE), "replay_ring_seconds: 30.0\n")
	var config := DotReplayConfig.new()
	var res := config.load_cfg(FILE, LEGACY)
	_check(res.ok and config.ring_seconds == 30.0, "only the flat file: it is still read")
	_check(DotCfgLegacy.warned_count() == 1, "and warned once")
	DotReplayConfig.new().load_cfg(FILE, LEGACY)
	_check(DotCfgLegacy.warned_count() == 1, "a second load does not warn again")

	_write(addon_dir.path_join(FILE), "replay_ring_seconds: 90.0\nsome_deployment_key: 1\n")
	config = DotReplayConfig.new()
	res = config.load_cfg(FILE, LEGACY)
	_check(res.ok and config.ring_seconds == 90.0, "the new path wins over the flat file")
	_check(config.unknown_keys.is_empty(), "and a key of the deployment's is skipped, not reported")

	_write(server_dir.path_join(FILE), "replay_ring_seconds: 120.0\n")
	config = DotReplayConfig.new()
	res = config.load_cfg(FILE, LEGACY)
	_check(res.ok and config.ring_seconds == 120.0, "the operator's server layer wins")

	_write(server_dir.path_join(FILE), "replay_ring_seconds: [broken\n")
	_check(not DotReplayConfig.new().load_cfg(FILE, LEGACY).ok, "a bad file fails")

	_clean(addon_dir, server_dir)
	DotCfgLegacy.reset()
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _clean(addon_dir: String, server_dir: String) -> void:
	DotPaths.remove_tree(addon_dir)
	DotPaths.remove_tree(server_dir)
	DotPaths.remove_tree(LEGACY)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   ", what)
	else:
		_failed += 1
		print("  FAIL  ", what)
