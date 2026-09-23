@tool
extends EditorPlugin

## Editor entry point for dot-replay. Registers inspector types only.
##
## No autoloads: a server records one match while a moderator's tool plays back another,
## and a clip being saved from the ring must not share state with either. Every piece is
## an object the host builds and owns.

const _ICON := "res://addons/dot_replay/icon_placeholder.svg"

const _TYPES := [
	[
		"DotReplayPlayer",
		"Node",
		"res://addons/dot_replay/runtime/dot_replay_player.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
