# ruff: noqa: D102
"""Tests of the orthophoto classification."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ground_classes as classes

NEUTRAL_GRADE = {"black": [0.0, 0.0, 0.0], "gain": [1.0, 1.0, 1.0], "gamma": 1.0, "saturation": 1.0}


def patch(srgb_colour, size=64):
    """Return a linear albedo image of one sRGB colour."""
    rgb = np.full((size, size, 3), srgb_colour, np.uint8)
    return classes.graded(rgb, NEUTRAL_GRADE)


class ClassifyTest(unittest.TestCase):
    """Colours give the layer a person would name."""

    def test_names_the_layer_of_plain_colours(self):
        cases = {
            (70, 110, 60): classes.LAWN,
            (120, 120, 124): classes.WORN_ASPHALT,
            (200, 185, 160): classes.GRAVEL,
            (110, 85, 60): classes.SOIL,
            (150, 145, 85): classes.DRY_GRASS,
            (200, 40, 40): classes.WORN_ASPHALT,
        }
        for colour, layer in cases.items():
            labels = classes.classify(patch(colour))
            self.assertEqual(int(labels[32, 32]), layer, colour)

    def test_rough_vegetation_is_meadow(self):
        noise = np.random.default_rng(1).integers(-45, 45, (64, 64, 1))
        rgb = np.clip(np.array([70, 110, 60]) + noise, 0, 255).astype(np.uint8)

        labels = classes.classify(classes.graded(rgb, NEUTRAL_GRADE))

        self.assertEqual(int(labels[32, 32]), classes.MEADOW)

    def test_rough_grey_is_waste_ground_not_asphalt(self):
        noise = np.random.default_rng(2).integers(-45, 45, (64, 64, 1))
        rgb = np.clip(np.array([120, 120, 124]) + noise, 0, 255).astype(np.uint8)

        labels = classes.classify(classes.graded(rgb, NEUTRAL_GRADE))

        self.assertEqual(int(labels[32, 32]), classes.SOIL)

    def test_a_shadow_takes_the_layer_around_it(self):
        rgb = np.full((64, 64, 3), (70, 110, 60), np.uint8)
        rgb[28:36, 28:36] = (20, 20, 22)

        labels = classes.classify(classes.graded(rgb, NEUTRAL_GRADE))

        self.assertEqual(int(labels[32, 32]), classes.LAWN)

    def test_removes_speckle(self):
        rgb = np.full((64, 64, 3), (120, 120, 124), np.uint8)
        rgb[32, 32] = (70, 110, 60)

        labels = classes.classify(classes.graded(rgb, NEUTRAL_GRADE))

        self.assertTrue((labels == classes.WORN_ASPHALT).all())


class GradeTest(unittest.TestCase):
    """The grade turns a hazy photo into albedo."""

    def test_asphalt_comes_out_neutral_at_its_albedo(self):
        haze = np.array([10, 20, 35])
        asphalt = np.full((50, 3), (150, 160, 175), np.uint8)
        photo = np.concatenate([np.full((50, 3), haze, np.uint8), asphalt])

        grade = classes.estimate_grade(photo, asphalt)
        albedo = classes.graded(asphalt[:1], grade)[0]

        np.testing.assert_allclose(albedo, [classes.ASPHALT_ALBEDO] * 3, atol=0.005)

    def test_haze_comes_out_black(self):
        photo = np.full((50, 3), (10, 20, 35), np.uint8)
        asphalt = np.full((50, 3), (150, 160, 175), np.uint8)

        grade = classes.estimate_grade(np.concatenate([photo, asphalt]), asphalt)

        np.testing.assert_allclose(classes.graded(photo[:1], grade)[0], [0.0, 0.0, 0.0], atol=0.01)

    def test_srgb_inverts_linear(self):
        values = np.linspace(0.0, 1.0, 11)

        np.testing.assert_allclose(classes.srgb(classes.linear(values)), values, atol=1e-5)


class ClearColourTest(unittest.TestCase):
    """The colour of a surface without what stands on it."""

    def test_cars_shadows_and_paint_do_not_colour_a_lot(self):
        rng = np.random.default_rng(6)
        pixels = np.tile(np.array([[118, 118, 122]], np.uint8), (4000, 1))
        pixels[:900] = rng.integers(0, 255, (900, 3))  # cars
        pixels[900:1500] = (25, 27, 35)  # their shadows
        pixels[1500:1700] = (235, 235, 235)  # paint
        albedo = classes.graded(pixels, NEUTRAL_GRADE)

        colour = classes.clear_colour(albedo)

        np.testing.assert_allclose(colour, classes.graded(pixels[-1:], NEUTRAL_GRADE)[0], atol=0.01)


class SurfaceLayerTest(unittest.TestCase):
    """The layer of a road or lot."""

    def layer(self, srgb_colour, tagged=None, paved=True):
        albedo = classes.graded(np.array([srgb_colour], np.uint8), NEUTRAL_GRADE)[0]
        return classes.surface_layer(albedo, tagged, paved)

    def test_the_photo_tells_the_surface_of_what_is_not_tagged(self):
        cases = {
            ((70, 70, 74), True): classes.TRACK_ASPHALT,
            ((120, 120, 124), True): classes.WORN_ASPHALT,
            ((185, 185, 188), True): classes.CONCRETE,
            ((200, 185, 160), True): classes.GRAVEL,
            ((120, 95, 70), True): classes.SOIL,
            ((120, 120, 124), False): classes.GRAVEL,
            ((70, 110, 60), True): classes.LAWN,
        }
        for (colour, paved), layer in cases.items():
            self.assertEqual(self.layer(colour, None, paved), layer, (colour, paved))

    def test_a_tag_tells_what_the_photo_cannot(self):
        cases = {
            "paving_stones": classes.PAVERS,
            "concrete:plates": classes.CONCRETE,
            "fine_gravel": classes.GRAVEL,
            "dirt": classes.SOIL,
            "grass": classes.LAWN,
        }
        for tagged, layer in cases.items():
            self.assertEqual(self.layer((120, 120, 124), tagged), layer, tagged)

    def test_tagged_asphalt_is_fresh_or_worn_by_its_colour(self):
        self.assertEqual(self.layer((70, 70, 74), "asphalt"), classes.TRACK_ASPHALT)
        self.assertEqual(self.layer((190, 190, 190), "asphalt"), classes.WORN_ASPHALT)


if __name__ == "__main__":
    unittest.main()
