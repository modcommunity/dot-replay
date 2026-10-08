This is the **replay** asset for TMC's **Dot** collection. It records what a dedicated server decided during a match — snapshots, events, chat, commands — so the match can be played back later: to watch it, to review it, or as evidence when somebody is reported.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## What it does
It records a match to a file and plays it back. A record is a tick, a channel name and a payload: raw bytes, or any plain value such as a Dictionary, an Array, numbers, strings or vectors. The addon never looks inside a payload, so the same format works for a shooter, a racing timer or a lobby.

- **Seeking.** Every few seconds the recorder asks the game for a **keyframe**, a full copy of its state. Playback can then jump to any tick by starting from the nearest keyframe and playing forward, and it ends up in exactly the state that playing from the start would give.
- **Crashes lose at most one chunk.** The file is written in chunks of one second by default, and each one is saved to disk as soon as it is complete. A server that crashes mid-match leaves a file that plays up to its last whole chunk.
- **Edited files are refused.** Each chunk has a hash that also covers the chunk before it, so changing, removing or reordering any part of the file is caught. Give the recorder a key and the hashes become HMACs that only the key's holder can produce.
- **Small files.** Chunks are compressed with zstd, and there is a size limit per file and per record. A file that reaches its limit is finished cleanly.
- **"Save that".** The last minute is kept in memory, and any part of it can be written out as a normal replay, which is how a server can keep evidence without writing every match to disk.

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The easiest way to get this addon and the ones it needs is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons into each one.

To add it to your own project by hand, copy `addons/dot_replay/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into it and enable dot-replay in **Project → Project Settings → Plugins**. dot-core is the only dependency.

## Recording

```gdscript
var config := DotReplayConfig.new()
config.load_layered()                                    # so the settings below can be changed without a rebuild

var rec := DotReplayRecorder.new()
rec.configure(config, 64)                                # 64 ticks per second
rec.keyframe_fn = func(_tick: int) -> Variant: return game.capture_state()
var header := DotReplayHeader.make("arena", "dm_box", 64, players)
rec.start(header, "user://replays/match.dreplay")

# every server tick, before anything of that tick is recorded:
rec.advance(tick)
rec.record_value(tick, &"events", {"kill": [attacker, victim]})
rec.record(tick, &"snapshot", snapshot_bytes)

var evidence: Dictionary = rec.stop().value              # path, final hash, tick range, size
```

To save the last thirty seconds while still recording:

```gdscript
rec.save_clip("user://replays/clip.dreplay", 30.0)
```

A clip starts at the keyframe before the time you asked for, so it can be a little longer than you asked for. It plays, seeks and verifies like any other replay.

## Playing back
`DotReplayPlayer` emits records, and your game applies them:

```gdscript
var player := DotReplayPlayer.new()
add_child(player)
player.state_reset.connect(func(tick, state): game.restore_state(state))   # after a seek
player.record_played.connect(func(record): game.apply(record.channel, record.value()))
player.finished.connect(func(): show_end_screen())

player.open("user://replays/match.dreplay")             # refused if any chunk was changed
player.play()

# every frame:
player.poll()
```

- `set_speed(2.0)` plays at any speed from 0.25x to 8x. `pause()` and `resume()` do what they say.
- `seek(tick)` jumps to any tick.
- `set_channels(["chat", "events"])` plays only the channels you ask for.
- `step_ticks(1)` moves forward exactly one tick, for frame-by-frame viewing.

## Connecting a server
Two small bridges record from other addons without depending on them:

- `DotReplayEventTap` records every event a server's event bus fires, including the ones a hook cancelled. `attach(bus)` and `detach()`.
- `DotReplayNetTap` records the snapshot stream a netcode manager sends to one peer.

## Settings
`DotReplayConfig` is layered like every Dot config: inspector defaults, then a JSON file, then the environment, then the command line. Times are in seconds, and the recorder converts them using the tick rate you give it.

```bash
DOT_REPLAY_COMPRESSION=deflate godot --headless -- --replay-ring-seconds=300
```

| Setting | Default | What it does |
| --- | --- | --- |
| `directory` | `user://replays` | Where finished replays are written |
| `chunk_seconds` | 1.0 | How much one chunk holds, and so the most a crash can lose |
| `chunk_kib` | 256 | A chunk is closed early when it reaches this size |
| `keyframe_seconds` | 10 | How often to ask the game for a keyframe. 0 turns it off |
| `compression` | `zstd` | `zstd`, `deflate`, `gzip`, `fastlz` or `none` |
| `max_file_mib` | 512 | A replay is finished cleanly at this size. 0 is unlimited |
| `max_record_kib` | 1024 | A single record larger than this is refused |
| `ring_seconds` | 60 | How much recent play is kept in memory for clips. 0 turns it off |
| `ring_max_mib` | 32 | The most memory the clip buffer may use |

## Testing

```bash
godot --headless --path . --import
godot --headless --path . res://examples/replay_selftest.tscn
```

## License
MIT. See [LICENSE](LICENSE).
