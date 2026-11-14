"""Tests of the cleaning, regularising and triangulating of building footprints."""

# ruff: noqa: D102

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import footprints

L_SHAPE = np.array([(0, 0), (10, 0), (10, 4), (4, 4), (4, 10), (0, 10)], np.float64)


def triangles_area_m2(points, triangles):
    """Return the summed area of triangles, each counted positive when counter-clockwise."""
    first, second, third = (points[triangles[:, corner]] for corner in range(3))
    return 0.5 * float(
        (
            (second[:, 0] - first[:, 0]) * (third[:, 1] - first[:, 1])
            - (second[:, 1] - first[:, 1]) * (third[:, 0] - first[:, 0])
        ).sum()
    )


class CleanedTest(unittest.TestCase):
    """Mapped rings made simple polygons."""

    def test_near_coincident_and_collinear_points_are_dropped(self):
        ring = [(0, 0), (5, 0), (5.01, 0.01), (10, 0), (10, 6), (10.02, 6.0), (0, 6), (0, 3)]
        cleaned = footprints.cleaned(np.array(ring, np.float64))
        np.testing.assert_allclose(cleaned, [(0, 0), (10, 0), (10, 6), (0, 6)], atol=0.03)

    def test_a_clockwise_ring_is_turned_counter_clockwise(self):
        cleaned = footprints.cleaned(L_SHAPE[::-1])
        self.assertGreater(footprints.signed_area_m2(cleaned), 0.0)
        self.assertEqual(len(cleaned), 6)

    def test_a_self_crossing_ring_keeps_its_largest_loop(self):
        bow = np.array([(0, 0), (10, 0), (10, 6), (12, 8), (12, 6), (10, 8), (0, 8)], np.float64)
        cleaned = footprints.cleaned(bow)
        self.assertTrue(footprints.is_simple(cleaned))
        self.assertAlmostEqual(footprints.signed_area_m2(cleaned), 81.0, delta=0.5)

    def test_a_ring_without_area_is_no_footprint(self):
        self.assertIsNone(footprints.cleaned(np.array([(0, 0), (5, 0), (9, 0.001)])))


class RegularisedTest(unittest.TestCase):
    """Footprints squared within a tolerance."""

    def test_near_right_angles_become_right_angles(self):
        angle = np.radians(20.0)
        turn = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
        jittered = L_SHAPE + np.array(
            [(0.1, -0.08), (-0.05, 0.1), (0.08, 0.05), (-0.1, -0.1), (0.05, 0.1), (-0.08, 0.02)]
        )
        regular = footprints.regularised(jittered @ turn.T, 0.4)
        self.assertEqual(len(regular), 6)
        edges = np.roll(regular, -1, axis=0) - regular
        edges /= np.linalg.norm(edges, axis=1, keepdims=True)
        corners_cos = (edges * np.roll(edges, -1, axis=0)).sum(1)
        np.testing.assert_allclose(corners_cos, 0.0, atol=1e-9)
        moved_m = np.linalg.norm(regular - footprints.cleaned(jittered @ turn.T), axis=1)
        self.assertLess(moved_m.max(), 0.4)

    def test_jitter_along_a_wall_is_removed(self):
        ring = [(0, 0), (4, 0.06), (8, -0.05), (12, 0), (12, 7), (6, 7.08), (0, 7)]
        regular = footprints.regularised(np.array(ring, np.float64), 0.4)
        self.assertEqual(len(regular), 4)

    def test_an_oblique_wall_keeps_its_direction(self):
        ring = np.array([(0, 0), (10, 0), (10, 5), (6, 9), (0, 9)], np.float64)
        regular = footprints.regularised(ring, 0.4)
        np.testing.assert_allclose(regular, ring, atol=1e-9)

    def test_a_footprint_that_would_move_too_far_is_kept(self):
        # Each wall is 12 degrees off the next one's perpendicular: squaring moves corners.
        ring = np.array([(0, 0), (20, 0), (24, 19), (4, 19)], np.float64)
        regular = footprints.regularised(ring, 0.4)
        np.testing.assert_allclose(regular, ring, atol=1e-9)


class TriangulatedTest(unittest.TestCase):
    """Footprints cut into triangles."""

    def test_a_concave_footprint_is_covered_once(self):
        points, triangles = footprints.triangulated(L_SHAPE)
        self.assertEqual(len(triangles), 4)
        self.assertAlmostEqual(triangles_area_m2(points, triangles), 64.0)

    def test_a_courtyard_is_left_open(self):
        outer = np.array([(0, 0), (12, 0), (12, 12), (0, 12)], np.float64)
        courtyard = np.array([(4, 4), (4, 8), (8, 8), (8, 4)], np.float64)
        points, triangles = footprints.triangulated(outer, [courtyard])
        self.assertEqual(len(points), 8)
        self.assertAlmostEqual(triangles_area_m2(points, triangles), 144.0 - 16.0)
        centres = points[triangles].mean(1)
        in_courtyard = np.all((centres > 4.0) & (centres < 8.0), axis=1)
        self.assertFalse(in_courtyard.any())

    def test_every_triangle_is_counter_clockwise(self):
        points, triangles = footprints.triangulated(L_SHAPE)
        for triangle in triangles:
            self.assertGreater(triangles_area_m2(points, triangle[None]), 0.0)


if __name__ == "__main__":
    unittest.main()
