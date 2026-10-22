# dot-replay

Match demos: what a dedicated server authoritatively decided, recorded as tick-stamped opaque records on named channels, in a chunked, compressed, hash-chained file that seeks by keyframe, survives a crash and refuses an edit.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to replays.

**The distributable is `addons/dot_replay/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). dot-server and dot-net are reached by duck typing.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: why it exists, opaque payloads, keyframes, the hash chain and what it does not buy, truncation, bounds, the net tap, where it runs, what is not here |
| [docs/history.md](docs/history.md) | what arming the suite and a DEBUG run found |

## Layout

| Path | What |
| --- | --- |
| `core/dot_replay_record.gd` | `DotReplayRecord`: one tick, one channel, one payload, keyframe flag; `value()` |
| `core/dot_replay_header.gd` | `DotReplayHeader`: game, map, tick rate, start time, players at the start, `meta`. Plain data only |
| `core/dot_replay_format.gd` | `DotReplayFormat`: magic, sizes, compression modes, `digest`, `contains_object`, `plain`. The format is drawn in its doc comment |
| `core/dot_replay_chunk.gd` | `DotReplayChunk`: the unit of loss, seeking and verification; carries its own channel table |
| `core/dot_replay_writer.gd` | `DotReplayWriter`: streams and flushes chunks, `finish()` writes index and footer, `evidence()` |
| `core/dot_replay_file.gd` | `DotReplayFile`: the reader. Complete, truncated, or refused with `CODE_INTEGRITY` |
| `runtime/dot_replay_recorder.gd` | `DotReplayRecorder`: `advance` / `record` / `record_value` / `keyframe` / `stop` / `save_clip`; asks `keyframe_fn` |
| `runtime/dot_replay_ring.gd` | `DotReplayRing`: the last N seconds, from a keyframe, capped in bytes; `save()` |
| `runtime/dot_replay_player.gd` | `DotReplayPlayer`: a `Node`; `state_reset` / `record_played` / `seeked` / `finished`, 0.25x to 8x, `seek`, `step_ticks`, a channel filter, `now_fn` |
| `dot_replay_config.gd` | `DotReplayConfig`: directory, chunk and keyframe sizes, compression, caps, ring; layered (`--replay-ring-seconds 300`) |
| `bridge/dot_replay_event_tap.gd` | `DotReplayEventTap`: a dot-server event bus's `event_fired`, objects replaced by `describe()` |
| `bridge/dot_replay_net_tap.gd` | `DotReplayNetTap`: wraps a dot-net manager's `send_fn` for one peer |
| `examples/replay_selftest.tscn` | the suite; files only under `user://dot_replay_selftest`, emptied first |
| `examples/cfg_selftest.tscn` | `replay.yml` through `DotReplayConfig.load_cfg`: `cfg/addons/dot_replay/`, `cfg/server/addons/dot_replay/` over it, the flat `cfg/replay.yml` shim (WARN once, removed 2026-12-31) |

Paths except `examples/` are in `addons/dot_replay/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/replay_selftest.tscn`; stderr should be empty. The section to keep above all is "Seeking reaches exactly the state linear playback does": seeks and linear playback compared against the state the match actually had at each tick. `CHECKS` is counted from the file; update it when you add a check.

## Rules that bite

- Payloads stay opaque: the addon never parses a snapshot or a game event, and the player applies nothing. [design](docs/design.md#the-payload-is-opaque)
- Decode with `bytes_to_var`, never `_with_objects`; headers and records refuse objects. [design](docs/design.md#the-payload-is-opaque)
- A keyframe begins a chunk and is taken in `advance(tick)`, at the top of the tick, before anything of that tick is recorded. [design](docs/design.md#a-keyframe-always-begins-a-chunk)
- Each chunk's hash covers the previous one; an unkeyed chain is tamper-evident, not tamper-proof. Do not claim more. [design](docs/design.md#the-hashes-are-a-chain)
- Truncated is a success, an edited complete chunk is a refusal. [design](docs/design.md#truncated-is-a-success-edited-is-a-failure)
- Check a chunk's declared unpacked size before `decompress`; every size a file can declare is bounded. [design](docs/design.md#bounded-in-every-direction-a-file-can-make-a-reader-allocate)
- Ticks only move forward; a late record is refused, never sorted in. [design](docs/design.md#ticks-only-move-forward-and-late-records-are-refused)
- Every flushed chunk under `user://` calls `DotWeb.sync_filesystem()`. [design](docs/design.md#smaller-decisions)
- The net tap records one observer peer; seeking its stream depends on the game's `keyframe_fn`. [design](docs/design.md#the-net-tap-records-one-peer-and-does-not-solve-seeking)
- An integrity check needs a case only it can catch: the transplant check is what fails without the chain. [history](docs/history.md#a-chain-nothing-tested)

## Open items

- **`DotReplayNetTap` has never recorded a real dot-net stream**, and nothing plays one back into a client. Only a stand-in checks it. [design](docs/design.md#where-it-runs-for-real)

Deliberately not here: replacing `DotTimerReplay`, decoding netcode, a broadcast delay, storage, asymmetric signing, reverse playback, a timeline UI, older format versions. [design](docs/design.md#deliberately-not-here)
