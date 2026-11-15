# ruff: noqa: D102
"""Tests of the vehicle packs written from the experiment's car profiles."""

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pack_experiment
from PIL import Image

PROFILE_INSTRUMENTS = {
    "speed": {
        "node": "Cockpit_Speed",
        "axis": [0.1, -0.3, 0.9],
        "kmh_to_deg": [[0, 0.0], [100, 135.0]],
    },
    "rpm": {"node": "Cockpit_Rpm", "axis": [0.0, -0.3, 0.9], "deg_per_unit": 0.05, "max": 6000},
    "steering_wheel": {
        "node": "Cockpit_Steer",
        "axis": [0.0, -0.25, 0.95],
        "ratio": 16.0,
        "lock_deg": 500.0,
    },
    "motor_to_wheel_ratio": 8.0,
}


def write_glb(path, materials):
    """Write a binary glTF holding only materials of these names."""
    document = json.dumps(
        {"asset": {"version": "2.0"}, "materials": [{"name": m} for m in materials]}
    )
    chunk = document.encode() + b" " * (-len(document) % 4)
    path.write_bytes(
        struct.pack("<4sII", b"glTF", 2, 20 + len(chunk))
        + struct.pack("<I4s", len(chunk), b"JSON")
        + chunk
    )


class InstrumentsTest(unittest.TestCase):
    """The experiment's instruments as a pack's."""

    def test_axes_are_in_the_ros_frame_and_scales_keep_their_values(self):
        instruments = pack_experiment.instruments(PROFILE_INSTRUMENTS)

        self.assertEqual(
            instruments["speedometer"],
            {
                "node": "Cockpit_Speed",
                "axis": [0.9, 0.1, -0.3],
                "km_h_to_deg": [[0, 0.0], [100, 135.0]],
            },
        )
        self.assertEqual(
            instruments["rev_counter"],
            {
                "node": "Cockpit_Rpm",
                "axis": [0.9, 0.0, -0.3],
                "deg_per_rpm": 0.05,
                "max_rpm": 6000,
                "motor_to_wheel_ratio": 8.0,
            },
        )

    def test_steering_wheel_axis_is_the_one_it_turns_about_steering_left(self):
        steering_wheel = pack_experiment.instruments(PROFILE_INSTRUMENTS)["steering_wheel"]

        # The experiment turned it clockwise seen from the seat about its axis.
        self.assertEqual(steering_wheel["axis"], [-0.95, 0.0, 0.25])
        self.assertEqual(steering_wheel["ratio"], 16.0)
        self.assertEqual(steering_wheel["lock_deg"], 500.0)

    def test_only_the_instruments_the_profile_has(self):
        only_speed = {"speed": PROFILE_INSTRUMENTS["speed"]}

        self.assertEqual(list(pack_experiment.instruments(only_speed)), ["speedometer"])


class DynamicsTest(unittest.TestCase):
    """What the dynamic bicycle model moves a vehicle by."""

    def test_centre_of_gravity_sits_where_the_weight_split_puts_it(self):
        fields = pack_experiment.dynamics("ovcs1", 1.122, -1.319)

        # 48 % of the weight on the front axle: 48 % of the wheelbase ahead of the rear one.
        self.assertAlmostEqual(fields["centre_of_gravity_x_m"], -1.319 + 0.48 * 2.441, places=3)

    def test_every_vehicle_is_a_road_car_as_weighed(self):
        for vehicle_id, weighed in pack_experiment.WEIGHED.items():
            fields = pack_experiment.dynamics(vehicle_id, 1.0, -1.0)

            self.assertEqual(
                fields,
                pack_experiment.vehicle_dynamics.road_car(
                    **weighed, front_axle_x_m=1.0, rear_axle_x_m=-1.0
                ),
            )


class MaterialNamesTest(unittest.TestCase):
    """The materials of a binary glTF."""

    def test_reads_the_names_of_a_models_materials(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "model.glb"
            write_glb(model, ["Paint", "MIRRORS"])

            self.assertEqual(pack_experiment.gltf_material_names(model), ["Paint", "MIRRORS"])


class CrownColoursTest(unittest.TestCase):
    """The colour of each kind of tree's crown, from its impostors' atlases."""

    def test_a_kinds_colour_is_its_atlases_opaque_pixels_tinted(self):
        with tempfile.TemporaryDirectory() as work:
            atlas = Image.new("RGBA", (4, 2), (255, 0, 0, 0))
            atlas.paste((0, 255, 0, 255), (0, 0, 2, 2))
            atlas.save(Path(work) / "fir.png")
            impostors = [{"atlas": "trees/fir.dds", "kind": "conifer"}]

            colours = pack_experiment.crown_colours(
                impostors, {"trees/fir.dds": Path(work) / "fir.png"}
            )

        self.assertEqual(colours, {"conifer": [0.0, 0.95, 0.0]})


if __name__ == "__main__":
    unittest.main()
