extends RefCounted

## dot-replay's API level. The rule for bumping it is on [DotAddonApi].

# 1: before this file existed (absent reads as 1). 2: the killcam (DotKillcamBuffer, DotKillcam, DotKillcamBanner).
# 3: the kill view: DotKillViewRules (mp_killview*), DotKillViewRing, DotKillViewClip, DotKillViewPlayer.
# 4: DotKillcamFraming, mp_killview_camera (DotKillViewRules.camera), DotKillViewPlayer.moment.
# 5: DotKillViewServer, DotKillViewClient, DotKillViewClip.pack / unpack.
# 6: DotKillcamHost, the final-killcam wrapper a game configures with hooks.
# 7: DotKillcamHost.pose_fn / apply_pose_fn / poses, mp_killview_pose_hz; kill view clip v3 (AUX 12).
# 8: DotKillcamHost.event_fn.
const LEVEL := 8
const OLDEST := 1
