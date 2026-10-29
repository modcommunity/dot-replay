class_name DotKillcamFraming
extends RefCounted
## Where a killcam's camera goes, given the killer's eye: the eye itself, or behind the killer on a
## [DotCameraProbe] boom, looking down the aim and zoomed toward a distant victim so both read.
##
## [codeblock]
## var framing := DotKillcamFraming.new(get_world_3d(), world_mask)
## # each replayed frame
## var v := framing.place(rules.camera, eye, 75.0, victim_chest, delta)
## camera.global_transform = v["transform"]; camera.fov = v["fov"]
## [/codeblock]

## Metres behind the killer's eye, at the base field of view.
var back: float = 2.6
## Metres to the right of it (over the shoulder away from a left-handed gun).
var side: float = 0.6
## Metres above it.
var lift: float = 0.5
## The narrowest field of view the zoom toward a far victim reaches, degrees.
var min_fov: float = 40.0
## Share of the screen's height a victim far down the aim should fill; 0 never zooms.
var victim_share: float = 0.15
## Distance looked down the aim when no victim is known, metres.
var aim_distance: float = 12.0

var probe: DotCameraProbe = null


func _init(world: World3D = null, mask: int = 1) -> void:
	probe = DotCameraProbe.new(world, mask)


## Forget the boom's eased length: the next frame is a cut.
func reset() -> void:
	probe.reset()


## {transform, fov} for [param mode] ([enum DotKillViewRules.Camera]) from the killer's [param eye]
## (-Z the aim) and [param base_fov]. [param target] is the victim's chest (Vector3) or null.
func place(mode: int, eye: Transform3D, base_fov: float, target: Variant = null, delta: float = 0.0) -> Dictionary:
	if mode != DotKillViewRules.Camera.BEHIND:
		return {"transform": eye, "fov": base_fov}
	var fwd := -eye.basis.z.normalized()
	var reach := aim_distance
	if target is Vector3:
		reach = maxf(eye.origin.distance_to(target), 1.0)
	var fov := base_fov
	if victim_share > 0.0:
		# The victim's 1.8 m at victim_share of the height, seen from behind the killer.
		var wanted_height := 1.8 / victim_share
		var narrow := rad_to_deg(2.0 * atan(wanted_height * 0.5 / (reach + back)))
		fov = clampf(narrow, minf(min_fov, base_fov), base_fov)
	# Dolly out as the lens narrows, so the killer stays the same size on screen.
	var dolly := tan(deg_to_rad(base_fov) * 0.5) / maxf(tan(deg_to_rad(fov) * 0.5), 0.01)
	var flat_right := Vector3(-fwd.z, 0.0, fwd.x).normalized() if Vector2(fwd.x, fwd.z).length() > 0.001 else eye.basis.x
	var wanted := eye.origin + (-fwd * back + flat_right * side + Vector3.UP * lift) * dolly
	var at := probe.resolve(eye.origin, wanted, delta)
	var look := eye.origin + fwd * reach
	if target is Vector3:
		look = target
	var dir := look - at
	var basis := eye.basis
	if dir.length() > 0.01 and absf(dir.normalized().dot(Vector3.UP)) < 0.995:
		basis = Basis.looking_at(dir, Vector3.UP)
	return {"transform": Transform3D(basis, at), "fov": fov}
