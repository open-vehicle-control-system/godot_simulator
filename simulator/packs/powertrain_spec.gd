class_name PowertrainSpec
extends RefCounted
## A vehicle pack's `powertrain`: the motor (or engine), the gearbox and the gear in use, and
## what holds the vehicle back. Which axle it drives is `dynamics.driven_axle`.

## `gear` when the gearbox picks the gear itself.
const AUTOMATIC := 0

var max_power_w: float
var max_torque_n_m: float  ## from standstill up to where `max_power_w` takes over
var max_rpm: float
var gear_ratios: Array[float] = []  ## motor turns per gearbox output turn, first gear first
var final_drive_ratio: float
var gear: int  ## the gear in use, from 1, or AUTOMATIC
var driveline_efficiency: float  ## the share of the motor's torque the wheels get
var rolling_resistance_coefficient: float  ## the rolling resistance per unit of weight
var drag_area_m2: float  ## the drag coefficient times the frontal area


static func parse(reader: ManifestReader) -> PowertrainSpec:
	## The powertrain at `powertrain` in `reader`; `reader.error` tells what is wrong with it.
	var powertrain := PowertrainSpec.new()
	var at := "powertrain."
	powertrain.max_power_w = reader.positive(at + "motor.max_power_w")
	powertrain.max_torque_n_m = reader.positive(at + "motor.max_torque_n_m")
	powertrain.max_rpm = reader.positive(at + "motor.max_rpm")
	var ratios := reader.list(at + "gear_ratios")
	for index in ratios.size():
		powertrain.gear_ratios.append(reader.positive("%sgear_ratios.%d" % [at, index]))
	reader.check(not ratios.is_empty(), at + "gear_ratios")
	powertrain.final_drive_ratio = reader.positive(at + "final_drive_ratio")
	powertrain.gear = _gear(reader, at + "gear", ratios.size())
	powertrain.driveline_efficiency = reader.number(at + "driveline_efficiency")
	reader.check(
		powertrain.driveline_efficiency > 0.0 and powertrain.driveline_efficiency <= 1.0,
		at + "driveline_efficiency"
	)
	powertrain.rolling_resistance_coefficient = reader.positive(
		at + "rolling_resistance_coefficient", 1.0
	)
	powertrain.drag_area_m2 = reader.positive(at + "drag_area_m2")
	return powertrain


static func _gear(reader: ManifestReader, path: String, gears: int) -> int:
	## A gear number the gearbox has, or AUTOMATIC for "automatic".
	if reader.is_text(path):
		reader.one_of(path, ["automatic"])
		return AUTOMATIC
	var number := reader.number(path)
	reader.check(number == roundf(number) and number >= 1.0 and number <= gears, path)
	return int(number)
