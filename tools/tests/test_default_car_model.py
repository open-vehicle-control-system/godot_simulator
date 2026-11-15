# ruff: noqa: D102
"""Tests of the default car model's builder that need no source model."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import default_car_model


class ConvexHullTest(unittest.TestCase):
    """The outline of the door mirrors' glass."""

    def test_keeps_the_corners_counter_clockwise(self):
        points = [(0, 0), (2, 0), (1, 1), (2, 2), (0, 2), (1, 0.5)]

        hull = default_car_model.convex_hull(points)

        self.assertEqual([tuple(corner) for corner in hull], [(0, 0), (2, 0), (2, 2), (0, 2)])


class ObjectNameTest(unittest.TestCase):
    """The source's object names."""

    def test_drops_the_index_the_exporter_appended(self):
        self.assertEqual(default_car_model.object_name("brake-disc-rear-l_6"), "brake-disc-rear-l")
        self.assertEqual(default_car_model.object_name("spring.001_75"), "spring.001")


class MirrorGlassTest(unittest.TestCase):
    """The pane added over a door mirror's back."""

    def test_faces_back_just_proud_of_the_housing(self):
        # A housing's back face: a unit square in the plane z = 0, facing -z.
        housing = {
            "POSITION": np.array([[0, 0, 0], [0, 1, 0], [1, 1, 0], [1, 0, 0]], float),
            "indices": np.array([[0, 1, 2], [0, 2, 3]], np.uint32),
        }

        glass = default_car_model.mirror_glass([housing])

        self.assertTrue(np.allclose(glass["NORMAL"], [0, 0, -1]))
        self.assertTrue(
            np.allclose(glass["POSITION"][:, 2], -default_car_model.MIRROR_GLASS_PROUD_M)
        )
        first = glass["POSITION"][glass["indices"][0]]
        facing = np.cross(first[1] - first[0], first[2] - first[0])
        self.assertLess(facing[2], 0.0)


if __name__ == "__main__":
    unittest.main()
