"""Tests of the straight skeleton of building footprints."""

# ruff: noqa: D102

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import footprints
import straight_skeleton

L_SHAPE = np.array([(0, 0), (10, 0), (10, 4), (4, 4), (4, 10), (0, 10)], np.float64)
T_SHAPE = np.array(
    [(0, 0), (4, 0), (4, 6), (10, 6), (10, 10), (-6, 10), (-6, 6), (0, 6)], np.float64
)
YARD_OUTLINE = np.array([(0, 0), (12, 0), (12, 12), (0, 12)], np.float64)
YARD = np.array([(4, 4), (4, 8), (8, 8), (8, 4)], np.float64)


def interior_nodes(skeleton, ring_points):
    """Return the skeleton's nodes off the outline as sorted (x, y, time) rounded tuples."""
    rows = np.column_stack([skeleton.points, skeleton.times])[ring_points:]
    return sorted(tuple(float(number) for number in np.round(row, 6) + 0.0) for row in rows)


class SkeletonTest(unittest.TestCase):
    """Skeletons of footprints, as roofs of unit slope."""

    def assert_is_a_roof(self, skeleton, rings):
        """Check each edge's face is a plane rising from it, the faces covering the rings."""
        points = np.vstack(rings)
        starts = points
        ends = np.vstack([np.roll(ring, -1, axis=0) for ring in rings])
        self.assertEqual(len(skeleton.faces), len(points))
        covered_m2 = 0.0
        for face, start, end in zip(skeleton.faces, starts, ends, strict=True):
            along = (end - start) / np.hypot(*(end - start))
            inward = np.array([-along[1], along[0]])
            np.testing.assert_allclose(skeleton.points[face[0]], start, atol=1e-9)
            np.testing.assert_allclose(skeleton.points[face[1]], end, atol=1e-9)
            np.testing.assert_allclose(
                (skeleton.points[face] - start) @ inward, skeleton.times[face], atol=1e-6
            )
            area_m2 = footprints.signed_area_m2(skeleton.points[face])
            self.assertGreater(area_m2, 0.0)
            self.assertTrue(footprints.is_simple(skeleton.points[face]))
            covered_m2 += area_m2
        self.assertAlmostEqual(covered_m2, sum(footprints.signed_area_m2(ring) for ring in rings))

    def test_a_rectangle_has_a_ridge_between_two_hips(self):
        rectangle = np.array([(0, 0), (10, 0), (10, 4), (0, 4)], np.float64)
        skeleton = straight_skeleton.skeleton(rectangle)
        self.assertEqual(interior_nodes(skeleton, 4), [(2.0, 2.0, 2.0), (8.0, 2.0, 2.0)])
        self.assertEqual([len(face) for face in skeleton.faces], [4, 3, 4, 3])
        self.assert_is_a_roof(skeleton, [rectangle])

    def test_a_square_rises_to_one_point(self):
        square = np.array([(0, 0), (6, 0), (6, 6), (0, 6)], np.float64)
        skeleton = straight_skeleton.skeleton(square)
        self.assertEqual(interior_nodes(skeleton, 4), [(3.0, 3.0, 3.0)])
        self.assert_is_a_roof(skeleton, [square])

    def test_an_l_shape_has_a_ridge_along_each_wing(self):
        skeleton = straight_skeleton.skeleton(L_SHAPE)
        self.assertEqual(
            interior_nodes(skeleton, 6), [(2.0, 2.0, 2.0), (2.0, 8.0, 2.0), (8.0, 2.0, 2.0)]
        )
        self.assert_is_a_roof(skeleton, [L_SHAPE])

    def test_a_t_shape_is_roofed(self):
        skeleton = straight_skeleton.skeleton(T_SHAPE)
        self.assert_is_a_roof(skeleton, [T_SHAPE])
        self.assertAlmostEqual(float(skeleton.times.max()), 2.0, places=6)

    def test_a_wing_wider_than_the_other_is_roofed(self):
        wide = np.array([(0, 0), (14, 0), (14, 6), (4, 6), (4, 12), (0, 12)], np.float64)
        skeleton = straight_skeleton.skeleton(wide)
        self.assert_is_a_roof(skeleton, [wide])
        self.assertAlmostEqual(float(skeleton.times.max()), 3.0, places=6)

    def test_a_courtyard_is_ringed_by_a_ridge(self):
        skeleton = straight_skeleton.skeleton(YARD_OUTLINE, [YARD])
        self.assert_is_a_roof(skeleton, [YARD_OUTLINE, YARD])
        self.assertAlmostEqual(float(skeleton.times.max()), 2.0, places=6)
        self.assertEqual(len(interior_nodes(skeleton, 8)), 4)

    def test_an_oblique_many_cornered_footprint_is_roofed(self):
        angle = np.radians(27.0)
        turn = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
        ring = np.array(
            [(0, 0), (9, 0), (9, 3), (15, 3), (15, 11), (11, 13), (6, 11), (6, 7), (0, 7)],
            np.float64,
        )
        skeleton = straight_skeleton.skeleton(ring @ turn.T)
        self.assert_is_a_roof(skeleton, [ring @ turn.T])


if __name__ == "__main__":
    unittest.main()
