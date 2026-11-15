"""A vehicle pack's `vehicle.dynamics` and `vehicle.powertrain`: what moves it in the simulator.

A road car's dynamics follow from what is weighed and measured on it (mass, weight split,
wheelbase, centre of gravity height, driven axle, tyre friction) and from what is typical of
production cars:

- Yaw inertia: 0.9 times mass times the two axle distances, as measured on passenger cars
  (Gillespie, Fundamentals of Vehicle Dynamics, ch. 6; Allen et al., SAE 2003-01-0966).
- Cornering stiffness: each axle's, at its static load, 12.5 (front) and 22 (rear) times that
  load per radian. These are effective axle values: a tyre alone gives 15 to 20, the suspension's
  compliance and roll steer take some away at the front (Milliken, Race Car Vehicle Dynamics,
  ch. 5 and 7). They give an understeer gradient of 2 to 3 degrees per g, ISO 4138's range for
  production cars (1 to 4).
- Tyres: Pacejka's magic formula with C = 1.3 (a slide keeps about 90 % of the peak force) and
  E = -1.5, the peak near 6 degrees of slip at the rear and 10 at the front (where the effective
  stiffness is lower); stiffness grows with the load to the power 0.7 and friction falls by a
  quarter of each tyre's relative overload (Pacejka, Tyre and Vehicle Dynamics, ch. 4: load
  sensitivity pDy2 of -0.1 to -0.3).
- Front roll stiffness share 0.75, the front anti-roll bar of a front-wheel drive car that
  understeers at the limit (Milliken, ch. 18).
- Brakes: 70 % front by design, the rear's share kept 5 % below its share of the load by a
  proportioning valve or EBD, so the front wheels lock first, as UN ECE R13-H's braking
  distribution rules ask.

A powertrain is its motor's (or engine's) published power, torque and rpm limit, its gearbox's
ratios, and what holds the vehicle back, the drag area (drag coefficient times frontal area)
and the rolling resistance coefficient (0.010 to 0.015 for car tyres on asphalt, Gillespie
ch. 4). A manual gearbox and final drive pass on about 90 % of the torque (Gillespie ch. 2).
"""

GRAVITY_M_S2 = 9.81
YAW_INERTIA_PER_MASS_TIMES_AXLE_DISTANCES = 0.9
DRIVELINE_EFFICIENCY = 0.9
FRONT_STIFFNESS_PER_LOAD_PER_RAD = 12.5
REAR_STIFFNESS_PER_LOAD_PER_RAD = 22.0
ROAD_CAR = {
    "brake_bias_front": 0.7,
    "rear_brake_margin": 0.05,
    "front_roll_stiffness_share": 0.75,
    "cornering_stiffness_load_exponent": 0.7,
    "friction_load_sensitivity": 0.25,
    "tyre_shape": 1.3,
    "tyre_curvature": -1.5,
}


def road_car(
    *,
    mass_kg,
    front_weight_share,
    front_axle_x_m,
    rear_axle_x_m,
    centre_of_gravity_height_m,
    driven_axle,
    friction,
    yaw_inertia_per_mass_times_axle_distances=YAW_INERTIA_PER_MASS_TIMES_AXLE_DISTANCES,
):
    """Return `vehicle.dynamics` for a road car weighed and measured as given.

    A car whose heavy parts sit over its axles turns harder than the typical one: give it a
    larger `yaw_inertia_per_mass_times_axle_distances`.
    """
    wheelbase_m = front_axle_x_m - rear_axle_x_m
    ahead_m = (1.0 - front_weight_share) * wheelbase_m
    behind_m = front_weight_share * wheelbase_m
    weight_n = mass_kg * GRAVITY_M_S2
    yaw_inertia = yaw_inertia_per_mass_times_axle_distances * mass_kg * ahead_m * behind_m
    front_stiffness = FRONT_STIFFNESS_PER_LOAD_PER_RAD * weight_n * front_weight_share
    rear_stiffness = REAR_STIFFNESS_PER_LOAD_PER_RAD * weight_n * (1.0 - front_weight_share)
    return {
        "mass_kg": mass_kg,
        "centre_of_gravity_x_m": round(rear_axle_x_m + behind_m, 4),
        "centre_of_gravity_height_m": centre_of_gravity_height_m,
        "yaw_inertia_kg_m2": float(f"{yaw_inertia:.3g}"),
        "driven_axle": driven_axle,
        "friction": friction,
        "front_cornering_stiffness_n_per_rad": float(f"{front_stiffness:.3g}"),
        "rear_cornering_stiffness_n_per_rad": float(f"{rear_stiffness:.3g}"),
        **ROAD_CAR,
    }


def powertrain(
    *,
    max_power_w,
    max_torque_n_m,
    max_rpm,
    gear_ratios,
    final_drive_ratio,
    gear,
    rolling_resistance_coefficient,
    drag_area_m2,
):
    """Return `vehicle.powertrain` for a motor driving through a manual gearbox, as given."""
    return {
        "motor": {
            "max_power_w": max_power_w,
            "max_torque_n_m": max_torque_n_m,
            "max_rpm": max_rpm,
        },
        "gear_ratios": gear_ratios,
        "final_drive_ratio": final_drive_ratio,
        "gear": gear,
        "driveline_efficiency": DRIVELINE_EFFICIENCY,
        "rolling_resistance_coefficient": rolling_resistance_coefficient,
        "drag_area_m2": drag_area_m2,
    }
