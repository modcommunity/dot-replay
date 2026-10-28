extends RefCounted

## dot-replay's API level. The rule for bumping it is on [DotAddonApi].

# 1: everything before this file existed (an absent file reads as 1).
# 2: the killcam: DotKillcamBuffer, DotKillcam, DotKillcamBanner.
# 3: the kill view: DotKillViewRules (mp_killview*), DotKillViewRing, DotKillViewClip, DotKillViewPlayer.
const LEVEL := 3
const OLDEST := 1
