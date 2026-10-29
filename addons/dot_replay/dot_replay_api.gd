extends RefCounted

## dot-replay's API level. The rule for bumping it is on [DotAddonApi].

# 1: before this file existed (absent reads as 1). 2: the killcam (DotKillcamBuffer, DotKillcam, DotKillcamBanner).
# 3: the kill view: DotKillViewRules (mp_killview*), DotKillViewRing, DotKillViewClip, DotKillViewPlayer.
# 4: DotKillcamFraming, mp_killview_camera (DotKillViewRules.camera), DotKillViewPlayer.moment.
const LEVEL := 4
const OLDEST := 1
