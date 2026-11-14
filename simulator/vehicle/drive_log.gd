class_name DriveLog
extends RefCounted
## The speed and steering commanded over time, read from a CSV whose header names the columns
## `time_s`, `speed_m_s` and `steering_rad` among any others: the `poses.csv` of a recording
## is one. A drive holds until the next row's time.

const COLUMNS := ["time_s", "speed_m_s", "steering_rad"]

var _times_s := PackedFloat64Array()
var _drives: Array[Array] = []  # [speed_m_s, steering_rad] per row


static func parse(text: String) -> Dictionary:
	## `{"log": DriveLog}` from the CSV `text`, or `{"error": reason}`.
	var lines := Array(text.strip_edges().split("\n")).filter(func(line): return line != "")
	if lines.size() < 2:
		return {"error": "no row"}
	var header: PackedStringArray = lines[0].strip_edges().split(",")
	var indices := []
	for column in COLUMNS:
		if not column in header:
			return {"error": "no %s column" % column}
		indices.append(header.find(column))
	var log := DriveLog.new()
	for row in range(1, lines.size()):
		var fields: PackedStringArray = lines[row].strip_edges().split(",")
		var numbers := []
		for index in indices:
			if index < fields.size() and fields[index].is_valid_float():
				numbers.append(fields[index].to_float())
		if numbers.size() != COLUMNS.size():
			return {"error": "row %d is not three numbers" % row}
		if not log._times_s.is_empty() and numbers[0] < log._times_s[-1]:
			return {"error": "row %d is earlier than the row before" % row}
		log._times_s.append(numbers[0])
		log._drives.append([numbers[1], numbers[2]])
	return {"log": log}


func duration_s() -> float:
	## The time of its last row.
	return _times_s[-1]


func drive_at(time_s: float) -> Array:
	## `[speed_m_s, steering_rad]` commanded at `time_s`: the last row at or before it, the
	## first row before the log starts.
	var after := _times_s.bsearch(time_s, false)
	return _drives[maxi(after - 1, 0)]
