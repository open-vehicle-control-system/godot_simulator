# ruff: noqa: D102
"""Tests of the survey of open roads: spans, fits, lines and the lines image."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import road_markings
import road_network
import secondary_roads as roads

LATERALS_M = np.arange(-8.0, 8.01, 0.125)


def profile(left_m, right_m):
    """Return the road-like flags across a road reaching `left_m` left and `right_m` right."""
    return (LATERALS_M >= -left_m - 1e-6) & (LATERALS_M <= right_m + 1e-6)


class PavedSpanTest(unittest.TestCase):
    """How far a section's road reaches either side."""

    def test_the_span_is_the_road_under_the_mapped_centreline(self):
        left, right = roads.paved_span(profile(2.0, 3.0), LATERALS_M, 2.5)

        self.assertAlmostEqual(left, 2.0)
        self.assertAlmostEqual(right, 3.0)

    def test_a_road_mapped_off_its_centre_is_still_found(self):
        flags = (LATERALS_M >= 3.0) & (LATERALS_M <= 7.0)

        left, right = roads.paved_span(flags, LATERALS_M, 3.5)

        self.assertAlmostEqual(left, -3.0)
        self.assertAlmostEqual(right, 7.0)

    def test_paint_or_a_car_does_not_end_the_road(self):
        flags = profile(3.0, 3.0)
        flags[(LATERALS_M > 0.9) & (LATERALS_M < 1.6)] = False

        self.assertEqual(roads.paved_span(flags, LATERALS_M, 2.5), (3.0, 3.0))

    def test_a_side_that_opens_onto_more_paving_has_no_edge(self):
        left, right = roads.paved_span(LATERALS_M <= 2.0, LATERALS_M, 2.5)

        self.assertTrue(np.isnan(left))
        self.assertAlmostEqual(right, 2.0)

    def test_ground_that_shows_no_road_has_no_span(self):
        left, right = roads.paved_span(np.zeros(len(LATERALS_M), bool), LATERALS_M, 2.5)

        self.assertTrue(np.isnan(left) and np.isnan(right))


class FitRoadTest(unittest.TestCase):
    """A road's centre and width from its edge readings."""

    def test_the_centre_moves_to_the_middle_of_the_edges(self):
        shift, half_width, _ = roads.fit_road(np.full(200, 1.5), np.full(200, 4.5), 2.5, 1.0)

        np.testing.assert_allclose(shift, 1.5, atol=1e-6)
        np.testing.assert_allclose(half_width, 3.0, atol=1e-6)

    def test_the_width_holds_over_a_stretch_whatever_the_noise(self):
        rng = np.random.default_rng(4)
        left = 3.0 + rng.normal(0.0, 0.2, 300)
        right = 3.0 + rng.normal(0.0, 0.2, 300)
        right[100:110] = 8.0

        _, half_width, _ = roads.fit_road(left, right, 2.5, 1.0)

        self.assertLess(np.ptp(half_width), 0.1)
        np.testing.assert_allclose(half_width, 3.0, atol=0.1)

    def test_a_stretch_without_an_edge_is_a_gap_the_width_carries_across(self):
        right = np.full(200, 3.0)
        right[80:110] = np.nan

        _, half_width, gaps = roads.fit_road(np.full(200, 3.0), right, 2.5, 1.0)

        np.testing.assert_allclose(half_width, 3.0, atol=1e-6)
        self.assertTrue(gaps[1][80:110].all())
        self.assertFalse(gaps[0].any())

    def test_a_side_the_photo_does_not_show_is_where_the_road_usually_ends(self):
        shift, half_width, _ = roads.fit_road(np.full(200, np.nan), np.full(200, 3.5), 2.5, 1.0)

        np.testing.assert_allclose(shift, 0.5, atol=1e-6)
        np.testing.assert_allclose(half_width, 3.0, atol=1e-6)

    def test_a_road_the_photo_does_not_show_is_not_confirmed(self):
        self.assertIsNone(roads.fit_road(np.full(200, np.nan), np.full(200, np.nan), 2.5, 1.0))


class LinesOnTheRoadTest(unittest.TestCase):
    """The road under the lines painted on it."""

    def test_a_road_reaches_past_the_lines_painted_on_it(self):
        half_width = np.full(200, 3.0)
        line = road_markings.Line(np.full(200, 4.0), np.full(200, road_markings.SOLID, np.uint8))

        np.testing.assert_allclose(
            roads.widened(half_width, [line]), 4.0 + roads.EDGE_LINE_INSET_M, atol=1e-6
        )


class PaintMasksTest(unittest.TestCase):
    """Paint told from the road around it."""

    def setUp(self):
        self.luminance = np.full((120, 65), 0.4)
        self.everywhere = np.ones((120, 65), bool)

    def test_a_line_along_the_road_is_paint_for_lines_only(self):
        self.luminance[:, 30] = 0.6

        lines, bars = roads.paint_masks(self.luminance, self.everywhere, self.everywhere, 0.125)

        self.assertTrue(lines[:, 30].all())
        self.assertEqual(lines.sum(), 120)
        self.assertFalse(bars.any())

    def test_a_band_across_the_road_is_paint_for_bars_only(self):
        self.luminance[50:58, :] = 0.6

        lines, bars = roads.paint_masks(self.luminance, self.everywhere, self.everywhere, 0.125)

        self.assertTrue(bars[50:58].all())
        self.assertFalse(lines.any())

    def test_a_double_line_is_paint_across_its_whole_width(self):
        self.luminance[:, 28:34] = 0.65

        lines, _ = roads.paint_masks(self.luminance, self.everywhere, self.everywhere, 0.125)

        self.assertTrue(lines[:, 28:34].all())
        self.assertEqual(lines.sum(), 120 * 6)

    def test_a_lighter_lane_is_not_paint(self):
        self.luminance[:, 40:] = 0.55

        lines, _ = roads.paint_masks(self.luminance, self.everywhere, self.everywhere, 0.125)

        self.assertFalse(lines.any())


class LinesImageTest(unittest.TestCase):
    """The roads laid end to end in the lines image."""

    def road(self, length_m):
        count = length_m + 1
        sections = road_network.sections_along(
            np.stack([np.arange(count, dtype=float), np.zeros(count)], 1)
        )
        colour = np.full((count, roads.COLOUR_BINS, 3), 0.2)
        colour[:, 0] = (0.5, 0.2, 0.1)
        line = road_markings.Line(np.full(count, -1.0), np.zeros(count, np.uint8))
        line.pattern[10:20] = road_markings.SOLID
        mark = road_markings.Transverse(road_markings.CROSSING, 30.0, 33.0, -2.0, 2.5)
        return roads.SurveyedRoad(
            road_network.KINDS["service"],
            {},
            sections,
            np.full(count, 2.5),
            [np.zeros(count, bool)] * 2,
            colour,
            6,
            [line],
            [mark],
        )

    def test_roads_lie_end_to_end_with_padding(self):
        starts, bands = roads.lay_out([100.0, 50.2])

        self.assertEqual(starts, [4, 112])
        self.assertEqual(bands, 1)

    def test_a_road_does_not_straddle_two_bands(self):
        starts, bands = roads.lay_out([4000.0, 200.0])

        self.assertEqual(starts, [4, roads.BAND_M + 4])
        self.assertEqual(bands, 2)

    def test_encodes_edges_layer_lines_markings_and_colour_per_metre(self):
        image = roads.lines_image([self.road(60)], [roads.BAND_M + 8], 2)
        band = image[roads.ROWS_PER_BAND :]

        self.assertEqual(image.shape, (2 * roads.ROWS_PER_BAND, roads.BAND_M, 4))
        self.assertFalse(image[: roads.ROWS_PER_BAND, :, :3].any())
        self.assertEqual(list(band[0, 8 + 30, :3]), [2500 >> 8, 2500 & 255, 6])
        self.assertEqual(list(band[2, 8 + 15, :3]), [31768 >> 8, 31768 & 255, 255])
        self.assertEqual(list(band[2, 8 + 25, :3]), [31768 >> 8, 31768 & 255, 0])
        self.assertEqual(list(band[1, 8 + 31, :3]), [road_markings.CROSSING, 88, 178])
        self.assertEqual(band[1, 8 + 35, 0], 0)
        self.assertGreater(
            band[2 + roads.MAX_LINES, 8 + 30, 0], band[3 + roads.MAX_LINES, 8 + 30, 0]
        )

    def test_a_road_carries_on_through_its_padding(self):
        band = roads.lines_image([self.road(60)], [8], 1)

        self.assertEqual(list(band[0, 6, :3]), [2500 >> 8, 2500 & 255, 6])
        self.assertEqual(list(band[0, 8 + 62, :3]), [2500 >> 8, 2500 & 255, 6])
        self.assertFalse(band[0, 8 + 63, :2].any())

    def test_a_stop_line_takes_the_metre_it_is_in(self):
        road = self.road(60)
        road.transverse = [road_markings.Transverse(road_markings.STOP_LINE, 40.0, 40.5, 0.0, 2.5)]

        band = roads.lines_image([road], [8], 1)

        self.assertEqual(list(band[1, 8 + 40, :3]), [road_markings.STOP_LINE, 128, 178])
        self.assertEqual(band[1, 8 + 39, 0], 0)
        self.assertEqual(band[1, 8 + 41, 0], 0)


class RunsTest(unittest.TestCase):
    """The stretches of a road an area keeps."""

    def test_a_road_is_cut_where_it_leaves_the_area(self):
        kept = np.zeros(200, bool)
        kept[20:80] = True
        kept[120:126] = True

        self.assertEqual(roads.runs(kept), [slice(20, 80)])

    def test_near_tells_what_lies_by_a_line(self):
        within = roads.near(np.array([0.0, 100.0]), np.array([0.0, 0.0]), 30.0)

        self.assertEqual(
            list(within(np.array([10.0, 50.0]), np.array([20.0, 20.0]))), [True, False]
        )


if __name__ == "__main__":
    unittest.main()
