# Design

Why dot-replay is shaped the way it is, and why the obvious alternative is wrong in each case. The file format itself is drawn in `DotReplayFormat`'s doc comment.

## Why this exists

Nothing else in the family replays a match. dot-timer's `DotTimerReplay` records one player's run: position and view, quantised and delta-encoded for a single body against the clock. That is the right format for a record run and the wrong one for a match, which has many bodies, events and chat, and whose state only the game can describe. dot-spectate's broadcast delay holds a few seconds of live poses in memory for a spectator and never writes anything. dot-net's snapshots are deltas per peer, meaningful only to the one client that acknowledged them. dot-moderation's `DotPunishment.evidence` is a free-form Dictionary meant to carry a demo's `evidence()`.

This addon is the game-agnostic layer under all of those: a record is `(tick, channel, bytes)`, and the file format, integrity, seeking, clipping and playback timing are the same whatever the bytes mean.

## The payload is opaque

A replay format that understood snapshots would be a copy of dot-net's wire format, and one that understood kills would be a copy of every game's rules. The only party that can interpret a record is the game that wrote it, so the addon moves bytes and the game folds them. That is also why the player emits and applies nothing. A payload is a `var_to_bytes` Variant decoded with `bytes_to_var`, **never** `_with_objects`, and the header and records refuse objects (`contains_object`).

## A keyframe always begins a chunk

So "the nearest keyframe at or before T" is a walk over the index and one decompression, never a scan of the stream. A keyframe means **the state after every record written before it**, and the recorder asks for one in `advance(tick)`, which the host calls at the top of the tick before anything of that tick is recorded. That is the one moment at which the game's live state and the stream agree without the game knowing about the recorder; a keyframe taken halfway through a tick would include changes the stream has not seen yet, and a seek there would apply them twice.

## The hashes are a chain

A hash per chunk detects an edited chunk. It does not detect one taken from another recording and put in the same position, which is still a chunk with a correct hash and a correct sequence number. Each chunk's hash covers the previous one, and the footer's covers the last hash, the index and itself, so the footer vouches for the whole file.

**What that does not buy, stated in `DotReplayFormat` so nobody claims it.** An unkeyed SHA-256 chain is tamper-*evident* against an accident or a careless edit, not against somebody who recomputes it. The answers are a key (`FLAG_KEYED`, HMAC-SHA256 throughout) or the final hash from `evidence()` stored somewhere the file's holder cannot write; a punishment's evidence field is exactly that. Neither can tell a file cut short and stripped of its footer from a crash, which is the case the format exists to survive; the final hash stored elsewhere is what tells them apart.

## Truncated is a success, edited is a failure

A crash leaves a whole prefix and a partial tail; it cannot produce a *complete* chunk with a wrong hash. So the reader keeps every whole chunk and reports `truncated`, and refuses anything complete that does not verify (`CODE_INTEGRITY`, naming the part), including an edit in a file that is also truncated. A partial index at the end is not counted as lost bytes: the index is derived from the chunks.

## A chunk is stored raw when compression does not help

A few small, noisy records come out of zstd larger than they went in. One byte of mode per chunk is cheaper than paying zstd's framing on every such chunk.

## Bounded in every direction a file can make a reader allocate

Header length (`MAX_HEADER_BYTES`, 1 MiB), each chunk's declared unpacked size (64 MiB by default, checked **before** `decompress`, because a forty-byte chunk can declare four gigabytes and its hash is valid if it was written that way), record size on the recording side, and the file itself, which is finished cleanly at its cap rather than cut off.

## Ticks only move forward, and late records are refused

Every chunk boundary and every seek assumes it. A record that arrives for an earlier tick is a bug in the caller's clock, and sorting it in would hide that.

## Smaller decisions

- **The header is who was there at the start.** A streaming file cannot rewrite its header. Joins and leaves are records on a channel the game chooses.
- **The recorder is not a Node, the player is.** A server drives the recorder from its own tick and a suite drives it with no tree. The player has per-frame work, and an inspector type is useful to somebody building a review tool.
- **The web.** Every flushed chunk is followed by `DotWeb.sync_filesystem()` when the path is under `user://`, because a browser tab closed before the engine's own sync loses what was written, and "a crash loses one chunk" has to hold there too. Nothing here needs threads.
- **The magic is `DRPL`.** dot-timer's run replays begin `DRP1`. The suite writes that magic into a demo and checks it is refused as not-a-demo.

## The net tap records one peer, and does not solve seeking

dot-net deltas each peer's snapshots against what that peer acknowledged and culls them by what it can see, so one peer's stream is a complete account of that peer's view and a mixture of two decodes as neither. Record a single observer peer. Those payloads are still deltas: a demo made from them seeks only as well as the full-state keyframes the game provides through `keyframe_fn`. Playing a recorded stream into a client `DotNetManager` is the game's code, and **this suite does not run it**: there is no dot-net here.

## Where it runs for real

dot-server-deploy's host (`TmcReplay`) keeps a ring of every server's event bus through `DotReplayEventTap`, with a roster keyframe, and saves it for an admin or a punishment. `DotReplayNetTap` is checked against a real dot-net server by `examples/net_selftest` (record, replay into a fresh client, same count, order and payload hash, a client joining mid-stream); no game records through it yet.

## The killcam is a separate buffer

A final killcam replays a client's last few seconds, so it needs decoded frames it can interpolate between and step through slowly, not the opaque, tick-stamped and compressed records `DotReplayRing` keeps for evidence. `DotKillcamBuffer` holds Dictionaries the game builds from what it already drew (no new traffic, no threads, nothing written), bounded by seconds, a frame count and an event count, and keeps one frame at or before the window's start so a rewind to the start can still interpolate. `DotKillcam` never knows what a frame contains: it emits `frame_drawn` with the two frames around the instant and an alpha, and the game places its bodies and camera. It waits up to `post_seconds + 0.5` for the second after the kill to arrive, then plays what it has, and shortens the rewind, never the kill, to fit `max_seconds`, so a server that adds the killcam to its end-of-match wait never waits on a client.

## Deliberately not here

- **A replacement for `DotTimerReplay`.** A record run wants quantised movement for one body and a small file a browser can fetch before the map loads; a match demo wants opaque channels. Both stay.
- **Decoding netcode.** No snapshot is ever parsed here.
- **A broadcast delay.** That is dot-spectate's, live and in memory. A ring is for saving, not for delaying a feed.
- **Where a demo is uploaded or kept.** A punishment store, dot-cloud or a website stores the file; `evidence()` is the Dictionary they want.
- **Asymmetric signing.** HMAC with a key the server holds. A signature a third party can verify without the key is a real want for public tournament demos and needs key distribution this family does not have yet.
- **Reverse playback.** Seeking backwards works; playing backwards would mean inverting records the addon cannot interpret.
- **A timeline UI.** This ships no screens; `describe()` and the signals are what one would be built on.
- **Reading an older format version.** There is only one. A newer `VERSION` is refused, and the reader is where a v1 path would go when v2 exists.
