extends TestCase
## The HUD's text: speed and frame rate, link status, title and view.


func test_shows_the_speed_and_the_frame_rate_on_the_first_line() -> void:
	var text := Viewer.hud_text(25.0, "driven by OVCS", "OVCS1  |  Spa", "chase", 59.6)

	var lines := text.split("\n")
	assert_eq(lines[0], " 90 km/h   60 fps")
	assert_eq(lines[1], "driven by OVCS")
	assert_eq(lines[2], "OVCS1  |  Spa  |  chase view")


func test_shows_reversing_as_a_positive_speed() -> void:
	var text := Viewer.hud_text(-5.0, "", "t", "cockpit", 30.0)

	assert_true(text.begins_with(" 18 km/h"), text)
