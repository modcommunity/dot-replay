extends RefCounted

## dot-replay's API level. The rule for bumping it is on [DotAddonApi].

# 1: before this file (absent reads as 1). 2: killcam (DotKillcamBuffer, DotKillcam, DotKillcamBanner). 3: kill view (DotKillViewRules, Ring, Clip, Player).
# 4: DotKillcamFraming, mp_killview_camera. 5: DotKillViewServer/Client, Clip.pack/unpack. 6: DotKillcamHost.
# 7: Host pose_fn/apply_pose_fn/poses, mp_killview_pose_hz, clip v3 (AUX 12). 8: DotKillcamHost.event_fn. 9: DotKillcam.wait_for_frames (a kill view clip starts at once).
const LEVEL := 9
const OLDEST := 1
