"""Tests of the roofs' classification and colour."""

# ruff: noqa: D102

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ground_classes
import roofs


def albedo(srgb_colour):
    """Return an sRGB colour (0 to 255) as linear albedo."""
    return ground_classes.linear(np.array(srgb_colour) / 255.0)


class ClassifyRoofTest(unittest.TestCase):
    """Roofing from colour and shape."""

    def test_names_the_roofing(self):
        cases = {
            ((60, 62, 68), 35.0, 120.0): "slate",
            ((150, 85, 60), 35.0, 120.0): "clay_tiles",
            ((115, 105, 98), 35.0, 120.0): "concrete_tiles",
            ((190, 192, 195), 12.0, 2000.0): "metal",
            ((100, 100, 104), 12.0, 2000.0): "metal",
            ((70, 70, 74), 0.0, 200.0): "bitumen",
            ((150, 145, 135), 0.0, 200.0): "gravel",
            ((190, 192, 195), 0.0, 2000.0): "metal",
            ((80, 110, 70), 0.0, 200.0): "green",
            ((150, 85, 60), 12.0, 2000.0): "clay_tiles",
        }
        for (colour, pitch_deg, area_m2), roofing in cases.items():
            self.assertEqual(
                roofs.classify_roof(albedo(colour), pitch_deg, area_m2), roofing, colour
            )


class LitColourTest(unittest.TestCase):
    """A roof's colour out of its shadows."""

    def test_shadows_and_the_shaded_side_do_not_darken_the_colour(self):
        lit = np.tile(albedo((150, 85, 60)), (60, 1))
        shaded = np.tile(albedo((70, 40, 30)), (40, 1))

        colour = roofs.lit_colour(np.concatenate([lit, shaded]))

        np.testing.assert_allclose(colour, albedo((150, 85, 60)), atol=1e-6)


if __name__ == "__main__":
    unittest.main()
