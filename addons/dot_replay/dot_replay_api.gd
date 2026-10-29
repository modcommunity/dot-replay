extends RefCounted

## dot-replay's API level. The rule for bumping it is on [DotAddonApi].

# 1: before this file existed (absent reads as 1). 2: the killcam (DotKillcamBuffer, DotKillcam, DotKillcamBanner).
# 3: the kill view: DotKillViewRules (mp_killview*), DotKillViewRing, DotKillViewClip, DotKillViewPlayer.
# 4: DotKillcamFraming, mp_killview_camera (DotKillViewRules.camera), DotKillViewPlayer.moment.
# 5: DotKillViewServer, DotKillViewClient, DotKillViewClip.pack / unpack.
# 6: DotKillcamHost, the final-killcam wrapper a game configures with hooks.
const LEVEL := 6
const OLDEST := 1
