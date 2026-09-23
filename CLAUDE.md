# dot-replay

Match demos: what a dedicated server authoritatively decided, recorded as tick-stamped opaque records on named channels, in a chunked, compressed, hash-chained file that seeks by keyframe, survives a crash and refuses an edit.

**The distributable is `addons/dot_replay/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this exists

**Nothing in the family could replay a match.** dot-timer's `DotTimerReplay` records one player's run: position and view, quantised and delta-encoded for a single body against the clock. That is the right format for a record run and the wrong one for a match, which has many bodies, events and chat, and whose state only the game can describe. dot-spectate's broadcast delay holds a few seconds of live poses in memory for a spectator and never writes anything. dot-moderation's `DotPunishment.evidence` has been a free-form Dictionary "for a link to a demo" with no demo to link to. dot-net's snapshots are deltas per peer, meaningful only to the one client that acknowledged them.

This addon is the game-agnostic layer under all of those: a record is `(tick, channel, bytes)`, and the file format, integrity, seeking, clipping and playback timing are the same whatever the bytes mean.

## The pieces

| | |
| --- | --- |
| `DotReplayRecord` | One tick, one channel, one payload, plus two flags: the payload is a `var_to_bytes` Variant, and it is a keyframe. `value()` decodes with `bytes_to_var` and **never** `_with_objects`. |
| `DotReplayHeader` | Game, map, tick rate, start time, the players present at the start, and free-form `meta`. Plain data only: an object is refused. |
| `DotReplayFormat` | Magic numbers, sizes, compression modes, `digest` (SHA-256 or HMAC), `contains_object`, `plain`. The whole format is drawn in its doc comment. |
| `DotReplayChunk` | A run of records compressed together: the unit of loss, of seeking and of verification. Self-contained, because its channel table travels inside it. |
| `DotReplayWriter` | Streams chunks to a file, flushing (and syncing IndexedDB on the web) after every one; `finish()` writes the index and footer; `evidence()` is a Dictionary for a punishment record. |
| `DotReplayFile` | The reader. Complete (footer verified, index used), truncated (scanned, plays up to the last whole chunk) or refused (`CODE_INTEGRITY`, naming the part). Chunks are read and verified on demand. |
| `DotReplayRecorder` | The front door: `advance` / `record` / `record_value` / `keyframe` / `stop` / `save_clip`. Seals chunks on span or size, asks `keyframe_fn` for state on an interval, feeds a file, a ring or both. |
| `DotReplayRing` | The last N seconds in memory, kept back to a keyframe and capped in bytes; `save()` writes a normal, complete replay. |
| `DotReplayPlayer` | A `Node` that emits `state_reset` / `record_played` / `seeked` / `finished`. 0.25x to 8x, pause, `seek`, `step_ticks`, a channel filter, an injectable `now_fn`. |
| `DotReplayConfig` | Directory, chunk seconds and KiB, keyframe seconds, compression, file and record caps, ring seconds and MiB. Layered: `--replay-ring-seconds 300`. |
| `DotReplayEventTap` | Records a dot-server event bus's `event_fired`, cancelled events included, with objects replaced by their `describe()`. Duck-typed. |
| `DotReplayNetTap` | Wraps a dot-net manager's `send_fn` and records one peer's outgoing stream. Duck-typed. |

## Decisions

### The payload is opaque

A replay format that understood snapshots would be a copy of dot-net's wire format, and one that understood kills would be a copy of every game's rules. The only party that can interpret a record is the game that wrote it, so the addon moves bytes and the game folds them. That is also why the player emits and applies nothing.

### A keyframe always begins a chunk

So "the nearest keyframe at or before T" is a walk over the index and one decompression, never a scan of the stream. A keyframe means **the state after every record written before it**, and the recorder asks for one in `advance(tick)`, which the host calls at the top of the tick before anything of that tick is recorded. That is the one moment at which the game's live state and the stream agree without the game knowing about the recorder; a keyframe taken halfway through a tick would include changes the stream has not seen yet, and a seek there would apply them twice.

### The hashes are a chain

A hash per chunk detects an edited chunk. It does not detect one taken from another recording and put in the same position, which is still a chunk with a correct hash and a correct sequence number. Each chunk's hash covers the previous one, and the footer's covers the last hash, the index and itself, so the footer vouches for the whole file.

**What that does not buy, stated in `DotReplayFormat` so nobody claims it.** An unkeyed SHA-256 chain is tamper-*evident* against an accident or a careless edit, not against somebody who recomputes it. The answers are a key (`FLAG_KEYED`, HMAC-SHA256 throughout) or the final hash from `evidence()` stored somewhere the file's holder cannot write — a punishment's evidence field is exactly that. Neither can tell a file cut short and stripped of its footer from a crash, which is the case the format exists to survive; the final hash stored elsewhere is what tells them apart.

### Truncated is a success, edited is a failure

A crash leaves a whole prefix and a partial tail; it cannot produce a *complete* chunk with a wrong hash. So the reader keeps every whole chunk and reports `truncated`, and refuses anything complete that does not verify, including an edit in a file that is also truncated. A partial index at the end is not counted as lost bytes: the index is derived from the chunks.

### A chunk is stored raw when compression does not help

A few small, noisy records come out of zstd larger than they went in. One byte of mode per chunk is cheaper than paying zstd's framing on every such chunk.

### Bounded in every direction a file can make a reader allocate

Header length (1 MiB), each chunk's declared unpacked size (64 MiB by default, checked **before** `decompress`, because a forty-byte chunk can declare four gigabytes and its hash is valid if it was written that way), record size on the recording side, and the file itself, which is finished cleanly at its cap rather than cut off.

### Ticks only move forward, and late records are refused

Every chunk boundary and every seek assumes it. A record that arrives for an earlier tick is a bug in the caller's clock, and sorting it in would hide that.

### The header is who was there at the start

A streaming file cannot rewrite its header. Joins and leaves are records on a channel the game chooses.

### The recorder is not a Node, the player is

A server drives the recorder from its own tick and a suite drives it with no tree. The player has per-frame work, and an inspector type is useful to somebody building a review tool.

### The web

Every flushed chunk is followed by `DotWeb.sync_filesystem()` when the path is under `user://`, because a browser tab closed before the engine's own sync loses what was written, and "a crash loses one chunk" has to hold there too. Nothing here needs threads.

### The net tap records one peer, and does not solve seeking

dot-net deltas each peer's snapshots against what that peer acknowledged and culls them by what it can see, so one peer's stream is a complete account of that peer's view and a mixture of two decodes as neither. Record a single observer peer. Those payloads are still deltas: a demo made from them seeks only as well as the full-state keyframes the game provides through `keyframe_fn`. Playing a recorded stream into a client `DotNetManager` is the game's code, and **this suite does not run it** — there is no dot-net here.

### Why the magic is `DRPL`

dot-timer's run replays begin `DRP1`. The suite writes that magic into a demo and checks it is refused as not-a-demo.

## What building it found

**The CHECKS total caught a miscount in the suite itself.** The first run said 100 checks ran against 107 expected. Counting the `_check` calls gave 100, so nothing had aborted and the estimate was wrong — but that is exactly the message an aborted section produces, and it is why the count is taken from the file rather than written from memory.

**Two checks were wrong and the code was right.** zstd *does* shrink three random 20-byte records (100 → 97 bytes), because the per-record framing repeats; the "stored raw" check now uses one record (38 raw, 47 compressed). And the random match had no record on its last tick, so "the index ends at tick 399" was asserting the recording's length rather than the file's content.

**With the chain taken out, all 100 checks still passed.** Arming it — hashing each chunk without the one before — showed that the splice check (chunks 4 and 5 cut out, footer stripped) is caught by the sequence number alone, so nothing tested the chain at all. The transplant check (chunk 3 of another recording, at position 3) is the one that fails without it, and it does.

**The other two armings fired.** Stopping a seek one tick short failed four checks in three sections; raising CHECKS by one exited 1.

**A run at DEBUG found three things no assertion was looking at.** The ring logged a line on every chunk once it reached its byte ceiling (231 lines in one section; now once, then counted in `describe_lines`). A file missing one byte of its footer reported 1,592 bytes lost — the index's bytes, no records (now 0, and the truncation check asserts it). And a wrong key was refused as "the header does not match its hash", which reads as tampering to a moderator who mistyped the key (the message now names both causes).

**Nothing here has been run against a real server.** Both taps are checked against stand-ins of the right shape, which proves the duck typing and the recording, not that dot-server's events or dot-net's payloads replay into anything useful. The first game to wire this in is where that gets found out.

## Things deliberately not here

- **A replacement for `DotTimerReplay`.** A record run wants quantised movement for one body and a 250 KB file a browser can fetch before the map loads; a match demo wants opaque channels. Both stay.
- **Decoding netcode.** No snapshot is ever parsed here. See the net tap above.
- **A broadcast delay.** That is dot-spectate's, live and in memory. A ring is for saving, not for delaying a feed.
- **Where a demo is uploaded or kept.** A punishment store, dot-cloud or a website stores the file; `evidence()` is the Dictionary they want.
- **Asymmetric signing.** HMAC with a key the server holds. A signature a third party can verify without the key is a real want for public tournament demos and needs key distribution this family does not have yet.
- **Reverse playback.** Seeking backwards works; playing backwards would mean inverting records the addon cannot interpret.
- **A timeline UI.** dot-ui ships no art and this ships no screens; `describe()` and the signals are what one would be built on.
- **Reading an older format version.** There is only one. `VERSION` is refused above, and the reader is where a v1 path would go when v2 exists.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/replay_selftest.tscn
```

11 sections, 102 checks, stderr empty, files only under `user://dot_replay_selftest` (emptied at the start of each run). **Section 4 is the one to keep**: 47 seeks and 1,000 ticks of linear playback compared against the state the match actually had at each tick.
