class_name DotKillViewClip
extends RefCounted

## Reads a killer-view clip (from [method DotKillViewRing.clip_for]) as a [DotKillcamBuffer]
## whose frames are {p, q, fov, cur}, and turns a [DotKillcam] sample back into a view.

## Kill event kind in the buffer; the kill is at time 0.
const KIND_KILL := &"kill"

## A clip longer than this is refused: the sender is not ours.
const MAX_SAMPLES := 4096


## The buffer for [param clip], failing with CODE_PARSE for anything that is not a clip.
static func to_buffer(clip: Dictionary) -> DotResult:
	if int(clip.get("v", 0)) != 1 or not (clip.get("f") is PackedFloat32Array):
		return DotResult.fail(DotError.CODE_PARSE, "Not a kill view clip.")
	var flat: PackedFloat32Array = clip["f"]
	var n := flat.size() / DotKillViewRing.STRIDE
	if flat.size() % DotKillViewRing.STRIDE != 0 or n == 0 or n > MAX_SAMPLES:
		return DotResult.fail(DotError.CODE_PARSE, "A kill view clip of the wrong size.", str(flat.size()))
	var buffer := DotKillcamBuffer.new()
	buffer.window_seconds = 120.0
	buffer.max_frames = MAX_SAMPLES
	var use_cursor := bool(clip.get("cursor", false))
	for i in n:
		var o := i * DotKillViewRing.STRIDE
		for k in DotKillViewRing.STRIDE:
			if not is_finite(flat[o + k]):
				return DotResult.fail(DotError.CODE_PARSE, "A kill view clip holds a non-finite number.")
		var q := Quaternion(flat[o + 4], flat[o + 5], flat[o + 6], flat[o + 7])
		if q.length_squared() < 0.0001:
			return DotResult.fail(DotError.CODE_PARSE, "A kill view clip holds a null rotation.")
		var cur := Vector2(flat[o + 9], flat[o + 10]) if use_cursor else Vector2(-1.0, -1.0)
		var accepted := buffer.push_frame(flat[o], {
			"p": Vector3(flat[o + 1], flat[o + 2], flat[o + 3]), "q": q.normalized(),
			"fov": flat[o + 8], "cur": cur,
		})
		if not accepted:
			return DotResult.fail(DotError.CODE_PARSE, "A kill view clip out of time order.")
	buffer.note_event(0.0, KIND_KILL, {"killer": clip.get("killer"), "info": clip.get("info", {})})
	return DotResult.success(buffer)


## The view at a [DotKillcam] sample: {transform, fov, cursor, has_cursor}; cursor is in 0..1.
static func view_at(sample: Dictionary) -> Dictionary:
	var a: Dictionary = sample["a"]
	var b: Dictionary = sample["b"]
	var t := float(sample["alpha"])
	var q: Quaternion = (a["q"] as Quaternion).slerp(b["q"], t)
	var cursor: Vector2 = (a["cur"] as Vector2).lerp(b["cur"], t)
	return {
		"transform": Transform3D(Basis(q), (a["p"] as Vector3).lerp(b["p"], t)),
		"fov": lerpf(a["fov"], b["fov"], t),
		"cursor": cursor,
		"has_cursor": (a["cur"] as Vector2).x >= 0.0,
	}


## A clip and its info as one event body of at most [param max_bytes]; a long clip is thinned
## (every other sample, again) rather than refused.
static func pack(clip: Dictionary, info: Dictionary, max_bytes: int = 15000) -> PackedByteArray:
	var thin := clip.duplicate()
	var flat: PackedFloat32Array = thin.get("f", PackedFloat32Array())
	var stride := DotKillViewRing.STRIDE
	var bytes := var_to_bytes({"clip": thin, "info": info})
	while bytes.size() > max_bytes and flat.size() / stride > 4:
		var kept := PackedFloat32Array()
		for row in range(0, flat.size() / stride, 2):
			kept.append_array(flat.slice(row * stride, (row + 1) * stride))
		flat = kept
		thin["f"] = flat
		bytes = var_to_bytes({"clip": thin, "info": info})
	return bytes


## Reads a [method pack] body: {ok, clip, info}. Never decodes objects.
static func unpack(body: PackedByteArray) -> Dictionary:
	var out := {"ok": false, "clip": {}, "info": {}}
	var value: Variant = bytes_to_var(body) if not body.is_empty() else null
	if value is Dictionary and (value as Dictionary).get("clip") is Dictionary:
		out["clip"] = (value as Dictionary)["clip"]
		var info: Variant = (value as Dictionary).get("info", {})
		out["info"] = info if info is Dictionary else {}
		out["ok"] = true
	return out
