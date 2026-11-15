# ruff: noqa: D102
"""Tests of a vehicle pack's dynamics, from what is weighed and textbook values."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import vehicle_dynamics

SEDAN = {
    "mass_kg": 1350.0,
    "front_weight_share": 0.6,
    "front_axle_x_m": 1.5,
    "rear_axle_x_m": -1.5,
    "centre_of_gravity_height_m": 0.55,
    "driven_axle": "front",
    "friction": 1.0,
}
# What the simulator's VehicleSpec requires under vehicle.dynamics.
REQUIRED = {
    "mass_kg",
    "centre_of_gravity_x_m",
    "centre_of_gravity_height_m",
    "yaw_inertia_kg_m2",
    "driven_axle",
    "brake_bias_front",
    "rear_brake_margin",
    "front_roll_stiffness_share",
    "friction",
    "front_cornering_stiffness_n_per_rad",
    "rear_cornering_stiffness_n_per_rad",
    "cornering_stiffness_load_exponent",
    "friction_load_sensitivity",
    "tyre_shape",
    "tyre_curvature",
}


class RoadCarTest(unittest.TestCase):
    """A road car's dynamics."""

    def test_has_every_field_a_pack_requires(self):
        self.assertEqual(set(vehicle_dynamics.road_car(**SEDAN)), REQUIRED)

    def test_centre_of_gravity_sits_where_the_weight_split_puts_it(self):
        fields = vehicle_dynamics.road_car(**SEDAN)

        # 60 % of the weight on the front axle: 60 % of the wheelbase ahead of the rear one.
        self.assertAlmostEqual(fields["centre_of_gravity_x_m"], -1.5 + 0.6 * 3.0)

    def test_yaw_inertia_is_near_mass_times_the_axle_distances(self):
        fields = vehicle_dynamics.road_car(**SEDAN)

        self.assertAlmostEqual(fields["yaw_inertia_kg_m2"], 0.9 * 1350.0 * 1.2 * 1.8, delta=5.0)

    def test_understeers_by_about_two_degrees_per_g(self):
        fields = vehicle_dynamics.road_car(**SEDAN)
        weight_n = 1350.0 * vehicle_dynamics.GRAVITY_M_S2

        # Gillespie's understeer gradient: axle loads over axle cornering stiffnesses.
        gradient_rad = (
            0.6 * weight_n / fields["front_cornering_stiffness_n_per_rad"]
            - 0.4 * weight_n / fields["rear_cornering_stiffness_n_per_rad"]
        )
        self.assertGreater(gradient_rad, 0.0175)
        self.assertLess(gradient_rad, 0.07)

    def test_the_brakes_favour_the_front(self):
        self.assertGreater(vehicle_dynamics.road_car(**SEDAN)["brake_bias_front"], 0.6)


if __name__ == "__main__":
    unittest.main()
