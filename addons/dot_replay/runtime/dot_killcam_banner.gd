class_name DotKillcamBanner
extends CanvasLayer

## What a killcam shows over its replay: letterbox bars, a title, who killed whom and with what,
## a progress line and a skip button. Built in code and anchored, so it fits any viewport.

signal skip_pressed()

## Over the game's HUD.
const DEFAULT_LAYER := 90

## Holds the bars still instead of sliding them in.
@export var reduce_motion: bool = false

@export var accent: Color = Color(0.95, 0.25, 0.2)
@export var bar_colour: Color = Color(0.0, 0.0, 0.0, 0.78)

var title_label: Label = null
var killer_label: Label = null
var detail_label: Label = null
var hint_label: Label = null
var skip_button: Button = null
var progress_bar: ColorRect = null

var _root: Control = null
var _top: Control = null
var _bottom: Control = null
var _tween: Tween = null


func _init() -> void:
	layer = DEFAULT_LAYER
	visible = false


func _ready() -> void:
	_build()


## Shows the banner for {title, killer, victim, weapon, hint}; missing keys get defaults.
func present(info: Dictionary) -> void:
	_build()
	title_label.text = String(info.get("title", "FINAL KILLCAM"))
	killer_label.text = String(info.get("killer", ""))
	var weapon := String(info.get("weapon", ""))
	var victim := String(info.get("victim", ""))
	detail_label.text = "  ".join(PackedStringArray([
		"[%s]" % weapon if weapon != "" else "", "killed %s" % victim if victim != "" else "",
	])).strip_edges()
	hint_label.text = String(info.get("hint", "Space / Esc to skip"))
	set_progress(0.0)
	visible = true
	if _tween != null:
		_tween.kill()
	if reduce_motion or not is_inside_tree():
		_slide(1.0)
		_root.modulate.a = 1.0
		return
	_slide(0.0)
	_root.modulate.a = 0.0
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_root, "modulate:a", 1.0, 0.25)
	_tween.tween_method(_slide, 0.0, 1.0, 0.35)


# The bars in from off-screen; offsets, because a position on an anchored control is absolute.
func _slide(f: float) -> void:
	var tall := get_viewport().get_visible_rect().size.y if is_inside_tree() else 0.0
	var top := -tall * 0.13 * (1.0 - f)
	var bottom := tall * 0.16 * (1.0 - f)
	_top.offset_top = top
	_top.offset_bottom = top
	_bottom.offset_top = bottom
	_bottom.offset_bottom = bottom


func set_progress(value: float) -> void:
	if progress_bar != null:
		progress_bar.anchor_right = clampf(value, 0.0, 1.0)


func dismiss() -> void:
	if _tween != null:
		_tween.kill()
	visible = false


func _build() -> void:
	if _root != null:
		return
	_root = Control.new()
	_root.name = "Killcam"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_top = _bar(Control.PRESET_TOP_WIDE, 0.13)
	title_label = _label(_top, 34, Color.WHITE)
	title_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var stripe := ColorRect.new()
	stripe.color = accent
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stripe.anchor_left = 0.38
	stripe.anchor_right = 0.62
	stripe.anchor_top = 1.0
	stripe.anchor_bottom = 1.0
	stripe.offset_top = -5.0
	_top.add_child(stripe)

	_bottom = _bar(Control.PRESET_BOTTOM_WIDE, 0.16)
	progress_bar = ColorRect.new()
	progress_bar.color = accent
	progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress_bar.anchor_bottom = 0.0
	progress_bar.offset_bottom = 4.0
	_bottom.add_child(progress_bar)

	killer_label = _label(_bottom, 30, Color.WHITE)
	killer_label.anchor_left = 0.04
	killer_label.anchor_right = 0.7
	killer_label.anchor_top = 0.12
	killer_label.anchor_bottom = 0.6
	killer_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	detail_label = _label(_bottom, 18, Color(1, 1, 1, 0.75))
	detail_label.anchor_left = 0.04
	detail_label.anchor_right = 0.7
	detail_label.anchor_top = 0.6
	detail_label.anchor_bottom = 0.92

	hint_label = _label(_bottom, 15, Color(1, 1, 1, 0.6))
	hint_label.anchor_left = 0.6
	hint_label.anchor_right = 0.96
	hint_label.anchor_top = 0.62
	hint_label.anchor_bottom = 0.92
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	skip_button = Button.new()
	skip_button.text = "Skip"
	skip_button.focus_mode = Control.FOCUS_NONE
	skip_button.anchor_left = 0.86
	skip_button.anchor_right = 0.96
	skip_button.anchor_top = 0.16
	skip_button.anchor_bottom = 0.56
	skip_button.pressed.connect(func() -> void: skip_pressed.emit())
	_bottom.add_child(skip_button)


func _bar(preset: Control.LayoutPreset, share: float) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.anchor_right = 1.0
	if preset == Control.PRESET_TOP_WIDE:
		holder.anchor_bottom = share
	else:
		holder.anchor_top = 1.0 - share
		holder.anchor_bottom = 1.0
	_root.add_child(holder)
	var back := ColorRect.new()
	back.color = bar_colour
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(back)
	return holder


func _label(parent: Control, size: int, colour: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l
