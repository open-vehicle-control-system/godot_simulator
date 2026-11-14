extends TestCase
## --record, run twice as simulate.sh runs it, on a generated track and vehicle: both
## recordings hold the same poses and the same ground truth.

const RECORDED_S := 0.5
const GROUND_TRUTH := ["depth", "disparity", "segmentation"]


func test_two_runs_record_the_same_poses_and_the_same_ground_truth() -> void:
	var directory := PackFixtures.fresh_directory("record_twice")
	PackFixtures.write_flat_world(
		PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat")), 200.0
	)
	var vehicle := PackFixtures.vehicle_manifest("small_car")
	vehicle["vehicle"]["stereo"]["distortion"] = {
		"k1": -0.15, "k2": 0.02, "p1": 0.0, "p2": 0.0, "k3": 0.0
	}
	vehicle["vehicle"]["stereo"]["noise"] = {"read": 0.01, "shot": 0.01}
	PackFixtures.write_pack(directory, vehicle)

	var runs := [directory.path_join("first"), directory.path_join("second")]
	for run: String in runs:
		assert_eq(_record(directory, run), 0, "the simulator's exit code")

	var poses := FileAccess.get_file_as_string(runs[0].path_join("poses.csv"))
	assert_eq(poses.strip_edges().split("\n").size(), 1 + 5, "10 Hz for 0.5 s")
	assert_eq(FileAccess.get_file_as_string(runs[1].path_join("poses.csv")), poses)
	assert_true(poses.split("\n")[5].split(",")[1].to_float() > 0.4, "the last frame's time")
	for kind: String in GROUND_TRUTH:
		var files := DirAccess.get_files_at(runs[0].path_join(kind))
		assert_eq(files.size(), 5, kind)
		for file in files:
			assert_eq(
				FileAccess.get_file_as_bytes(runs[1].path_join(kind).path_join(file)),
				FileAccess.get_file_as_bytes(runs[0].path_join(kind).path_join(file)),
				"%s/%s" % [kind, file]
			)
	# The images are the same but for a pixel's last bit, which the renderer does not promise.
	for file in DirAccess.get_files_at(runs[0].path_join("left")):
		var first := Image.load_from_file(runs[0].path_join("left").path_join(file))
		var second := Image.load_from_file(runs[1].path_join("left").path_join(file))
		assert_true(first.compute_image_metrics(second, false)["max"] <= 1.0, "left/%s" % file)


func _record(packs: String, recording: String) -> int:
	DirAccess.make_dir_recursive_absolute(recording)
	var arguments := [
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--write-movie",
		recording.path_join("window.avi"),
		"--fixed-fps",
		"60",
		"--resolution",
		"320x180",
		"--",
		"--track=flat",
		"--vehicle=small_car",
		"--packs=" + packs,
		"--hold=20,5",
		"--record=" + recording,
		"--record-seconds=%s" % RECORDED_S,
	]
	return OS.execute(OS.get_executable_path(), arguments)
