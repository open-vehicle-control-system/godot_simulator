# ruff: noqa: D102
"""Tests of the markings found in a road's paint."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import road_markings

STEP_M = 0.5
LATERALS_M = np.arange(-6.0, 6.01, 0.125)
SAMPLES = 400


def column(lateral_m):
    """Return the column of the paint mask at `lateral_m`."""
    return int(np.argmin(np.abs(LATERALS_M - lateral_m)))


def dashes(dash_m, gap_m, phase_m=0.0):
    """Return which samples along the road a dashed line paints."""
    along_m = np.arange(SAMPLES) * STEP_M
    return (along_m - phase_m) % (dash_m + gap_m) < dash_m


class FindLinesTest(unittest.TestCase):
    """Lines along a road."""

    def setUp(self):
        self.paint = np.zeros((SAMPLES, len(LATERALS_M)), bool)

    def test_a_solid_line_is_found_where_it_is(self):
        self.paint[:, column(3.0)] = True

        lines = road_markings.find_lines(self.paint, LATERALS_M, STEP_M)

        self.assertEqual(len(lines), 1)
        np.testing.assert_allclose(lines[0].offset_m, 3.0, atol=0.07)
        self.assertTrue((lines[0].pattern == road_markings.SOLID).all())

    def test_a_line_the_photo_shows_with_holes_and_wobble_is_drawn_whole_and_straight(self):
        rng = np.random.default_rng(1)
        for sample in range(SAMPLES):
            if rng.random() < 0.8:
                self.paint[sample, column(-2.0) + rng.integers(-1, 2)] = True

        lines = road_markings.find_lines(self.paint, LATERALS_M, STEP_M)

        self.assertEqual(len(lines), 1)
        np.testing.assert_allclose(lines[0].offset_m, -2.0, atol=0.1)
        self.assertTrue((lines[0].pattern == road_markings.SOLID).all())

    def test_a_line_is_followed_where_the_road_drifts_off_its_mapped_centreline(self):
        course = 1.5 * np.sin(np.arange(SAMPLES) * STEP_M * 2.0 * np.pi / 200.0)
        for sample in range(SAMPLES):
            self.paint[sample, column(course[sample])] = True

        lines = road_markings.find_lines(self.paint, LATERALS_M, STEP_M)

        self.assertEqual(len(lines), 1)
        ends = round(15.0 / STEP_M)  # a line's course is held level over its last metres
        off_course = np.abs(lines[0].offset_m - course)[ends:-ends]
        self.assertLess(float(off_course.max()), 0.1)

    def test_dashes_take_the_standard_their_rhythm_fits(self):
        for index, (dash_m, gap_m) in enumerate(road_markings.DASHES_M):
            paint = np.zeros_like(self.paint)
            paint[dashes(dash_m, gap_m, 3.0), column(0.0)] = True

            lines = road_markings.find_lines(paint, LATERALS_M, STEP_M)

            self.assertEqual(len(lines), 1, (dash_m, gap_m))
            self.assertEqual(set(lines[0].pattern.tolist()), {index + 1}, (dash_m, gap_m))

    def test_paint_too_wide_for_one_line_is_a_double_line(self):
        self.paint[:, column(-0.375) : column(0.375) + 1] = True

        lines = road_markings.find_lines(self.paint, LATERALS_M, STEP_M)

        self.assertEqual(len(lines), 1)
        np.testing.assert_allclose(lines[0].offset_m, 0.0, atol=0.07)
        self.assertTrue((lines[0].pattern == road_markings.DOUBLE).all())

    def test_a_line_stops_where_its_paint_does(self):
        self.paint[:200, column(1.0)] = True

        lines = road_markings.find_lines(self.paint, LATERALS_M, STEP_M)

        self.assertTrue(lines[0].pattern[:180].all())
        self.assertFalse(lines[0].pattern[230:].any())

    def test_two_lines_side_by_side_are_two_lines(self):
        self.paint[:, column(-3.0)] = True
        self.paint[dashes(2.5, 10.0), column(0.0)] = True

        lines = road_markings.find_lines(self.paint, LATERALS_M, STEP_M)

        self.assertEqual(sorted(round(float(np.median(line.offset_m))) for line in lines), [-3, 0])

    def test_scattered_paint_is_not_a_line(self):
        rng = np.random.default_rng(2)
        self.paint[rng.random(self.paint.shape) < 0.004] = True

        self.assertEqual(road_markings.find_lines(self.paint, LATERALS_M, STEP_M), [])

    def test_paint_without_rhythm_is_not_a_dashed_line(self):
        rng = np.random.default_rng(3)
        self.paint[rng.random(SAMPLES) < 0.3, column(0.0)] = True

        self.assertEqual(road_markings.find_lines(self.paint, LATERALS_M, STEP_M), [])


class FindStopLinesTest(unittest.TestCase):
    """Bars across a road."""

    def setUp(self):
        self.paint = np.zeros((SAMPLES, len(LATERALS_M)), bool)

    def test_a_short_bar_across_a_lane_is_a_stop_line(self):
        self.paint[60, column(0.0) : column(3.0) + 1] = True

        found = road_markings.find_stop_lines(self.paint, LATERALS_M, STEP_M)

        self.assertEqual([mark.kind for mark in found], [road_markings.STOP_LINE])
        self.assertAlmostEqual(found[0].left_m, 0.0, delta=0.07)

    def test_a_light_band_across_the_road_is_not_a_marking(self):
        self.paint[100:108, column(-3.0) : column(3.0) + 1] = True

        self.assertEqual(road_markings.find_stop_lines(self.paint, LATERALS_M, STEP_M), [])

    def test_a_car_is_not_a_marking(self):
        self.paint[100:109, column(1.0) : column(2.8)] = True
        self.paint[200:230, column(-3.0) : column(3.0)] = True

        self.assertEqual(road_markings.find_stop_lines(self.paint, LATERALS_M, STEP_M), [])


if __name__ == "__main__":
    unittest.main()
