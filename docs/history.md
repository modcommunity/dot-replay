# History

What building and arming the suite found. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## The suite's own count

**The `CHECKS` total caught a miscount in the suite itself.** The first run reported fewer checks than expected. Counting the `_check` calls showed nothing had aborted and the estimate was wrong, but that is exactly the message an aborted section produces, which is why the expected count is taken from the file rather than written from memory.

**Two checks were wrong and the code was right.** zstd *does* shrink three random 20-byte records, because the per-record framing repeats; the "stored raw" check now uses one record. And the random match had no record on its last tick, so "the index ends at tick 399" was asserting the recording's length rather than the file's content.

## A chain nothing tested

**With the chain taken out, every check still passed.** Arming it (hashing each chunk without the one before) showed that the splice check (two chunks cut out, footer stripped) is caught by the sequence number alone, so nothing tested the chain at all. The transplant check (a chunk of another recording, at the same position) is the one that fails without it, and it does. An integrity feature needs a check that only it can pass.

The other armings fired: stopping a seek one tick short failed checks in several sections, and raising `CHECKS` by one exited 1.

## What a run at DEBUG showed

Three things no assertion was looking at:

- The ring logged a line on every chunk once it reached its byte ceiling. Now once, then counted in `describe_lines`.
- A file missing one byte of its footer reported the index's bytes as lost, with no records lost. Now 0, and the truncation check asserts it.
- A wrong key was refused as "the header does not match its hash", which reads as tampering to a moderator who mistyped the key. The message now names both causes.

## Built and wired into nothing

dot-replay had a ring, an event tap and `evidence()` shaped for a punishment, and for a while no server built one. dot-server-deploy's `TmcReplay` is what closed that ([design](design.md#where-it-runs-for-real)).
