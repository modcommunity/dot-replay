This is the **replay** asset for TMC's **Dot** collection. It records what a dedicated server decided during a match — snapshots, events, chat, commands — so the match can be played back later: to watch it, to review it, or as evidence when somebody is reported.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## Recording

A record is a tick, a channel name and a payload. The payload is yours: raw bytes, or any plain value (a Dictionary, an Array, numbers, strings, vectors). dot-replay never interprets it, so the same format holds a shooter, a racing timer and a lobby.

```gdscript
var rec := DotReplayRecorder.new()
rec.configure(DotReplayConfig.new(), 64)                 # 64 ticks per second
rec.keyframe_fn = func(_tick: int) -> Variant: return game.capture_state()
var header := DotReplayHeader.make("arena", "dm_box", 64, players)
rec.start(header, "user://replays/match.dreplay")

# every server tick, before anything of that tick is recorded:
rec.advance(tick)
rec.record_value(tick, &"events", {"kill": [attacker, victim]})
rec.record(tick, &"snapshot", snapshot_bytes)

var evidence: Dictionary = rec.stop().value              # path, final hash, tick range
```

Every few seconds the recorder asks the game for a **keyframe**, a whole copy of its state, which is what lets playback jump to any point without replaying the match from the start.

## Playing back

`DotReplayPlayer` is a node that emits records rather than applying them. The game connects three signals: `state_reset` (replace your state with this keyframe), `record_played` (apply this record) and `finished`.

- Any speed from 0.25x to 8x, pause and resume.
- `seek(tick)` jumps to the nearest keyframe at or before `tick`, then fast-forwards to it. It reaches exactly the state that playing from the start would have. The suite checks that at dozens of ticks, including every keyframe boundary.
- `set_channels(["chat", "events"])` plays only the channels you ask for.

## Crashes, edits and size

- **A crash loses at most one chunk.** The file is written in chunks, one second each by default, and each chunk is flushed to disk as soon as it is complete. A server that dies mid-match leaves a file that plays up to its last whole chunk.
- **An edited file is refused.** Every chunk carries a hash that also covers the chunk before it, so changing, removing or moving any part of the file is detected. Give the recorder a key and the hashes become HMACs that only the key's holder can produce.
- **Files stay small, and have a size limit.** Each chunk is compressed with zstd, which makes a repetitive snapshot stream more than ten times smaller. There is a limit per file and per record, and a file that reaches its limit is finished cleanly rather than cut off.

## "Save that"

`DotReplayRing` keeps the last minute (or however long you configure) in memory. `rec.save_clip(path, 30.0)` writes the last thirty seconds as an ordinary replay, starting from a keyframe, that plays, seeks and verifies like any other. A server can keep evidence of every match without writing every match to disk.

## Connecting a server

Two small bridges record from other addons without depending on them:

- `DotReplayEventTap` records every event a server's event bus fires, including the ones a hook cancelled.
- `DotReplayNetTap` records the snapshot stream a netcode manager sends to one peer.

## Installing

Copy `addons/dot_replay/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable it in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else.

## Licence

MIT. See [LICENSE](LICENSE).
