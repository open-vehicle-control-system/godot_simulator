"""Write the default vehicle pack: a mid-size front-wheel drive sedan.

Its model is "Generic Sedan Car" by Márcio Meireles (MMC Works), CC BY 4.0, built by
default_car_model.py from the source the builder is given; its dimensions are the model's
and its dynamics those of a 1350 kg sedan with 60 % of its weight on the front axle
(vehicle_dynamics.py).

Its powertrain is a Volkswagen Bora 2.0's: the 2.0 l 8-valve petrol engine (85 kW at 5,200 rpm,
170 Nm at 2,400 rpm: Wikipedia, "List of Volkswagen Group petrol engines"; its 6,200 rpm limit
is an estimate) and the 02T five-speed gearbox, code letters GKM, as VW's workshop manual gives
its ratios ("5-speed manual gearbox 02T: code letters, transmission ratios"). Its gear is
automatic: no single gear takes a petrol car from standstill to its top speed. Its drag area is a
mid-size sedan's Cd of 0.31 on 2.2 m2, estimated.

Needs numpy and Pillow, and the source model (default_car_model.SOURCE).
"""

import default_car_model
import vehicle_dynamics

VEHICLE_ID = "default_car"
MODEL = "vehicle.glb"
LICENCE = (
    "The model in vehicle.glb is\n"
    f"  {default_car_model.CREDIT}.\n"
    f"Modified: {default_car_model.MODIFICATIONS}.\n"
    "\n"
    "This pack (the model as modified and pack.json) is licensed under CC BY 4.0:\n"
    "https://creativecommons.org/licenses/by/4.0/ ; credit the model as above.\n"
    "pack.json was written by tools/default_packs.py.\n"
)
ATTRIBUTION = f"""# Attribution

`vehicle.glb` is built from **"Generic Sedan Car"** by **Márcio Meireles (MMC Works)**:

- Source: {default_car_model.SOURCE_URL}
- Licence: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
- Modified: {default_car_model.MODIFICATIONS}, by `tools/default_car_model.py`.

The pack is released under CC BY 4.0 as well; credit the model as above.
"""
MASS_KG = 1350.0
FRONT_WEIGHT_SHARE = 0.6
CENTRE_OF_GRAVITY_HEIGHT_M = 0.55
FRICTION = 1.0
DRIVER_PITCH_DEG = -4.0
POWERTRAIN = vehicle_dynamics.powertrain(
    max_power_w=85000.0,
    max_torque_n_m=170.0,
    max_rpm=6200.0,
    gear_ratios=[3.454, 1.954, 1.387, 1.025, 0.812],
    final_drive_ratio=3.933,
    gear="automatic",
    rolling_resistance_coefficient=0.012,
    drag_area_m2=0.68,
)
STEERING_RATIO = 15.0
STEERING_LOCK_DEG = 520.0


def millimetres(value_m):
    """Return a length rounded to the millimetre."""
    return round(float(value_m), 3) + 0.0  # never -0.0


def manifest(measured):
    """Return the default vehicle's pack.json from what the model measures."""
    front_axle_x_m = millimetres(measured["front_axle_x_m"])
    rear_axle_x_m = millimetres(measured["rear_axle_x_m"])
    track_m = millimetres(measured["track_m"])
    return {
        "format": 1,
        "kind": "vehicle",
        "id": VEHICLE_ID,
        "name": "Generic sedan",
        "version": "1.0.0",
        "licence": "CC-BY-4.0",
        "attribution": [
            f"Model: {default_car_model.CREDIT}. Modified: {default_car_model.MODIFICATIONS}"
        ],
        "vehicle": {
            "model": MODEL,
            "front_axle_x_m": front_axle_x_m,
            "rear_axle_x_m": rear_axle_x_m,
            "front_track_m": track_m,
            "rear_track_m": track_m,
            "wheel_radius_m": millimetres(measured["wheel_radius_m"]),
            "wheel_width_m": millimetres(measured["wheel_width_m"]),
            "dynamics": vehicle_dynamics.road_car(
                mass_kg=MASS_KG,
                front_weight_share=FRONT_WEIGHT_SHARE,
                front_axle_x_m=front_axle_x_m,
                rear_axle_x_m=rear_axle_x_m,
                centre_of_gravity_height_m=CENTRE_OF_GRAVITY_HEIGHT_M,
                driven_axle="front",
                friction=FRICTION,
            ),
            "powertrain": POWERTRAIN,
            "body": {
                "size_m": [millimetres(along) for along in measured["body_size_m"]],
                "centre_m": [millimetres(along) for along in measured["body_centre_m"]],
            },
            "driver_eye_m": [millimetres(along) for along in measured["driver_eye_m"]],
            "driver_pitch_deg": DRIVER_PITCH_DEG,
            "stereo": {
                "mount_m": [millimetres(along) for along in measured["stereo_mount_m"]],
                "width_px": 1280,
                "height_px": 720,
                "hfov_deg": 90.0,
                "baseline_m": 0.12,
                "pitch_deg": 0.0,
                "rate_hz": 15.0,
            },
            "instruments": {
                "steering_wheel": {
                    "node": "Cockpit_Steer",
                    "axis": [round(along, 4) for along in measured["steering_axis"]],
                    "ratio": STEERING_RATIO,
                    "lock_deg": STEERING_LOCK_DEG,
                }
            },
            "mirrors": {
                "material": default_car_model.MIRROR_MATERIAL["name"],
                "interior_hfov_deg": 45.0,
                "door_hfov_deg": 30.0,
            },
        },
    }


def write(directory, source=default_car_model.SOURCE):
    """Write the default vehicle pack's model and attribution; return its manifest."""
    directory.mkdir(parents=True, exist_ok=True)
    measured = default_car_model.write(directory / MODEL, source)
    (directory / "ATTRIBUTION.md").write_text(ATTRIBUTION)
    return manifest(measured)
