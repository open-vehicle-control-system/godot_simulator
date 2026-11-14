"""Tests of the roofs' classification and rebuilding."""

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


def grid_roof(height_at, width_m=10.0, length_m=20.0):
    """Return a roof mesh over a rectangle, 1 m apart, with `height_at(x, z)` heights."""
    xs, zs = np.meshgrid(np.arange(width_m + 1.0), np.arange(length_m + 1.0))
    positions = np.column_stack([xs.ravel(), height_at(xs.ravel(), zs.ravel()), zs.ravel()])
    columns = int(width_m) + 1
    triangles = []
    for row in range(int(length_m)):
        for column in range(int(width_m)):
            corner = row * columns + column
            triangles.append((corner, corner + 1, corner + columns))
            triangles.append((corner + 1, corner + columns + 1, corner + columns))
    return positions, np.array(triangles)


def grey(x, z):
    """Return a mid grey for every position."""
    return np.tile(albedo((110, 110, 112)), (len(x), 1))


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


class GeometryTest(unittest.TestCase):
    """The helpers the roofs are rebuilt with."""

    def test_boundary_edges_are_those_of_one_triangle(self):
        triangles = np.array([[0, 1, 2], [1, 3, 2]])

        edges = roofs.boundary_edges(triangles)

        self.assertEqual(sorted(map(tuple, edges)), [(0, 1), (0, 2), (1, 3), (2, 3)])

    def test_distance_to_segments_is_to_the_nearest(self):
        points = np.array([[1.0, 1.0], [5.0, 0.5]])
        starts = np.array([[0.0, 0.0], [0.0, 0.0]])
        ends = np.array([[10.0, 0.0], [0.0, 10.0]])

        np.testing.assert_allclose(roofs.distance_to_segments(points, starts, ends), [1.0, 0.5])

    def test_a_gable_is_fitted_to_its_points(self):
        across = np.linspace(-5.0, 5.0, 21)
        rise = 3.0 * (1.0 - np.abs(across) / 5.0)

        half_width_m, ridge_rise_m, misfit_m = roofs.fit_gable(across, rise)

        self.assertAlmostEqual(half_width_m, 5.0)
        self.assertAlmostEqual(ridge_rise_m, 3.0)
        self.assertAlmostEqual(misfit_m, 0.0)

    def test_no_triangle_crosses_the_ridge_after_the_split(self):
        points = np.array([[0.0, 0.0, 0.0], [4.0, 0.0, 0.0], [0.0, 0.0, 4.0]])
        across = np.array([-1.0, 3.0, -1.0])

        split_points, triangles, split_across = roofs.split_at_ridge(
            points, np.array([[0, 1, 2]]), across
        )

        self.assertEqual(len(split_points), 5)
        for triangle in triangles:
            self.assertFalse(
                (split_across[triangle] > 0).any() and (split_across[triangle] < 0).any()
            )
        areas = roofs._areas(split_points[:, [0, 2]], triangles)
        self.assertAlmostEqual(float(areas.sum()), 8.0)


class RoofTest(unittest.TestCase):
    """A roof rebuilt from its LiDAR-shaped mesh."""

    def test_a_bumpy_flat_roof_becomes_one_plane(self):
        bumps = np.random.default_rng(1).uniform(-0.2, 0.2, 11 * 21)
        positions, triangles = grid_roof(lambda x, z: 6.0 + bumps)

        roof = roofs.Roof(positions, triangles, grey)

        self.assertEqual(roof.shape, "flat")
        self.assertLess(float(np.ptp(roof.positions[:, 1])), 1e-6)
        np.testing.assert_allclose(roof.normals, np.tile([0.0, 1.0, 0.0], (len(roof.normals), 1)))

    def test_a_rounded_gable_becomes_two_planes_with_a_ridge_along_its_length(self):
        def rounded(x, z):
            return 6.0 + 3.0 * np.sqrt(np.clip(1.0 - np.abs(x - 5.0) / 5.0, 0.0, 1.0)) * 0.8

        positions, triangles = grid_roof(rounded)

        roof = roofs.Roof(positions, triangles, grey)

        self.assertEqual(roof.shape, "gable")
        slopes = np.unique(np.round(roof.normals, 4), axis=0)
        self.assertEqual(len(slopes), 2)
        self.assertAlmostEqual(float(slopes[0][2]), 0.0)  # no slope along the 20 m length
        ridge = roof.positions[np.isclose(roof.positions[:, 0], 5.0)]
        self.assertLess(float(np.ptp(ridge[:, 1])), 1e-5)

    def test_a_rounded_roof_is_not_given_a_ridge_above_it(self):
        def rounded(x, z):
            return 6.0 + 3.0 * np.sqrt(np.clip(1.0 - np.abs(x - 5.0) / 5.0, 0.0, 1.0)) * 0.8

        positions, triangles = grid_roof(rounded)

        roof = roofs.Roof(positions, triangles, grey)

        self.assertLessEqual(float(roof.positions[:, 1].max()), float(positions[:, 1].max()) + 1e-6)

    def test_gable_ends_are_walled_up_to_the_roof(self):
        positions, triangles = grid_roof(lambda x, z: np.full_like(x, 6.0) + 0.4 * (x == 5.0))
        positions[:, 1] = 6.0 + 3.0 * (1.0 - np.abs(positions[:, 0] - 5.0) / 5.0)
        lidar = positions.copy()
        ends = (lidar[:, 2] == 0.0) | (lidar[:, 2] == 20.0)
        lidar[ends, 1] = 6.0  # the LiDAR roof comes down to the walls at the gable ends

        roof = roofs.Roof(lidar, triangles, grey)
        wall_positions, wall_coordinates = roof.gable_walls

        self.assertEqual(roof.shape, "gable")
        self.assertGreater(len(wall_positions), 0)
        self.assertTrue(np.isin(wall_positions[:, 2], [0.0, 20.0]).all())
        self.assertAlmostEqual(
            float(wall_positions[:, 1].max()), float(roof.positions[:, 1].max()), places=4
        )
        self.assertEqual(len(wall_positions), len(wall_coordinates))

    def test_rows_run_along_the_eave_at_their_real_size(self):
        positions, triangles = grid_roof(lambda x, z: 6.0 + 3.0 * (1.0 - np.abs(x - 5.0) / 5.0))

        roof = roofs.Roof(positions, triangles, grey)

        along_eave = roof.rows[:, 0]
        up_slope = roof.rows[:, 1]
        self.assertAlmostEqual(float(np.ptp(along_eave)), 20.0, places=4)
        self.assertAlmostEqual(float(up_slope.max()), float(np.hypot(5.0, 3.0)), places=4)
        self.assertAlmostEqual(float(up_slope.min()), 0.0, places=4)

    def test_a_shape_no_gable_fits_keeps_its_heights(self):
        positions, triangles = grid_roof(lambda x, z: 6.0 + 0.3 * z * (x > 5.0))

        roof = roofs.Roof(positions, triangles, grey)

        self.assertEqual(roof.shape, "free")
        self.assertAlmostEqual(float(roof.positions[:, 1].max()), 12.0)

    def test_the_colour_is_read_away_from_the_edge_and_the_edge_distance_kept(self):
        def photo(x, z):
            leaning = (x < 1.0)[:, None]
            return np.where(leaning, albedo((30, 90, 30)), albedo((150, 85, 60)))

        positions, triangles = grid_roof(lambda x, z: 6.0 + 3.0 * (1.0 - np.abs(x - 5.0) / 5.0))

        roof = roofs.Roof(positions, triangles, photo)

        clay = albedo((150, 85, 60))
        np.testing.assert_allclose(roof.albedo / roof.albedo.max(), clay / clay.max(), atol=1e-6)
        self.assertLessEqual(float(roof.albedo.max()), roofs.BRIGHTEST_ROOF + 1e-9)
        self.assertEqual(roof.roofing, "clay_tiles")
        self.assertAlmostEqual(float(roof.colours[:, 3].min()), 0.0)
        self.assertAlmostEqual(float(roof.colours[:, 3].max()), 1.0)


if __name__ == "__main__":
    unittest.main()
