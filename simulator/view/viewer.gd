class_name Viewer
extends Node
## What the person at the screen sees: the vehicle from the chosen view, a HUD, and the stereo
## pair on demand. Its keys only change what is shown: C cycles the views, V shows the stereo
## pair, F11 toggles full screen, Esc quits. The arrow keys drive only under --keyboard
## (KeyboardDriver).

const HEADING_SMOOTHING_PER_S := 5.0
const COCKPIT_NEAR_M := 0.02
const OUTSIDE_NEAR_M := 0.05
const FAR_M := 6000.0
const FIELD_OF_VIEW_DEG := 65.0
const PANEL_GAP_PX := 4.0
const PANEL_MAX_HEIGHT := 0.45  # of the window

var view := "chase"
var keyboard_driving := false  ## the arrow keys drive (--keyboard)
var holding_drive := false  ## a set speed and steering are held (--hold)
var following_route := false  ## the track's centre line is driven (--follow-route)
var mirrors: Mirrors = null  ## the vehicle's mirrors, live only in the views that see them
var lighting: Environment = null  ## what lights the window's view, when not the world's own

var _vehicle: Vehicle
var _link: SimulatorLink
var _stereo: StereoCamera
var _title := ""
var _camera := Camera3D.new()
var _hud := Label.new()
var _stereo_panel := Control.new()
var _chase_heading := Vector3.ZERO
var _looks_from_fixed_eye := false
var _fixed_eye := Vector3.ZERO


func setup(
	vehicle: Vehicle, link: SimulatorLink, stereo: StereoCamera, title: String, first_view: String
) -> void:
	## Shows `vehicle` from `first_view`; `link` may be null when the simulator runs unlinked.
	_vehicle = vehicle
	_link = link
	_stereo = stereo
	_title = title
	view = first_view
	name = "Viewer"
	_camera.fov = FIELD_OF_VIEW_DEG
	_camera.far = FAR_M
	_camera.environment = lighting
	add_child(_camera)
	_camera.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud.position = Vector2(24, 18)
	_hud.add_theme_font_size_override("font_size", 24)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)
	_build_stereo_panel(layer)


func show_stereo(visible: bool) -> void:
	## Shows or hides the stereo pair along the bottom of the window.
	_stereo_panel.visible = visible


func look_from(eye: Vector3) -> void:
	## Looks at the vehicle from `eye`, a fixed point of the world, whatever the view.
	_looks_from_fixed_eye = true
	_fixed_eye = eye


func _process(delta: float) -> void:
	var placed := _vehicle.global_transform
	var heading := Vector3(placed.basis.z.x, 0.0, placed.basis.z.z).normalized()
	if _chase_heading == Vector3.ZERO:
		_chase_heading = heading
	var weight := clampf(delta * HEADING_SMOOTHING_PER_S, 0.0, 1.0)
	_chase_heading = _chase_heading.slerp(heading, weight).normalized()
	_camera.near = COCKPIT_NEAR_M if view == "cockpit" else OUTSIDE_NEAR_M
	if _looks_from_fixed_eye:
		_camera.global_transform = Transform3D(
			Basis.looking_at(placed.origin - _fixed_eye, Vector3.UP), _fixed_eye
		)
	else:
		_camera.global_transform = ViewPoses.pose(view, placed, _vehicle.spec, _chase_heading)
	if mirrors != null:
		mirrors.live = ViewPoses.sees_mirrors(view) and not _looks_from_fixed_eye
	_hud.text = hud_text(
		_vehicle.speed_m_s, _link_status(), _title, view, Engine.get_frames_per_second()
	)


static func hud_text(
	speed_m_s: float, link_status: String, title: String, view_name: String, frames_per_s: float
) -> String:
	## The HUD's lines: speed and frame rate, how the vehicle is driven, what is shown.
	return (
		"%3d km/h   %d fps\n%s\n%s  |  %s view"
		% [roundi(absf(speed_m_s) * 3.6), roundi(frames_per_s), link_status, title, view_name]
	)


func _link_status() -> String:
	if keyboard_driving:
		return "keyboard: arrows drive"
	if holding_drive:
		return "holding a set speed and steering"
	if following_route:
		return "following the track's centre line"
	if _link == null:
		return "no link: standing still"
	return "driven by OVCS" if _link.connected else "waiting for the OVCS link"


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.physical_keycode:
		KEY_C:
			view = ViewPoses.next_view(view)
		KEY_V:
			show_stereo(not _stereo_panel.visible)
		KEY_F11:
			var window := get_window()
			window.mode = (
				Window.MODE_WINDOWED
				if window.mode == Window.MODE_FULLSCREEN
				else Window.MODE_FULLSCREEN
			)
		KEY_ESCAPE:
			get_tree().quit()


func _build_stereo_panel(layer: CanvasLayer) -> void:
	_stereo_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stereo_panel.visible = false
	layer.add_child(_stereo_panel)
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color(0.03, 0.03, 0.035)
	_stereo_panel.add_child(background)
	for index in 2:
		var image := TextureRect.new()
		image.name = "Image%d" % index
		image.texture = _stereo.viewports[index].get_texture()
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_SCALE
		_stereo_panel.add_child(image)
	get_viewport().size_changed.connect(_lay_out_stereo_panel)
	_lay_out_stereo_panel()


func _lay_out_stereo_panel() -> void:
	## Left and right images side by side along the bottom, each up to half the window wide.
	var window := get_viewport().get_visible_rect().size
	var aspect := float(_stereo.optics.height_px) / float(_stereo.optics.width_px)
	var width := (window.x - 3.0 * PANEL_GAP_PX) * 0.5
	var height := width * aspect
	if height > window.y * PANEL_MAX_HEIGHT:
		height = window.y * PANEL_MAX_HEIGHT
		width = height / aspect
	var top := window.y - height - PANEL_GAP_PX
	var left := (window.x - 2.0 * width - PANEL_GAP_PX) * 0.5
	var background := _stereo_panel.get_node("Background") as ColorRect
	background.position = Vector2(0.0, top - PANEL_GAP_PX)
	background.size = Vector2(window.x, height + 2.0 * PANEL_GAP_PX)
	for index in 2:
		var image := _stereo_panel.get_node("Image%d" % index) as TextureRect
		image.position = Vector2(left + index * (width + PANEL_GAP_PX), top)
		image.size = Vector2(width, height)
