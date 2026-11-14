"""Tests of the roof shapes of buildings, their fit to the LiDAR and their closed meshes."""

# ruff: noqa: D102

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import building_shapes

RECTANGLE = np.array([(0, 0), (12, 0), (12, 8), (0, 8)], np.float64)
SQUARE = np.array([(0, 0), (8, 0), (8, 8), (0, 8)], np.float64)
L_SHAPE = np.array([(0, 0), (14, 0), (14, 6), (6, 6), (6, 14), (0, 14)], np.float64)
T_SHAPE = np.array(
    [(0, 0), (6, 0), (6, 8), (14, 8), (14, 14), (-8, 14), (-8, 8), (0, 8)], np.float64
)
YARD_OUTLINE = np.array([(0, 0), (16, 0), (16, 16), (0, 16)], np.float64)
YARD = np.array([(5, 5), (5, 11), (11, 11), (11, 5)], np.float64)
FOOTPRINTS = {
    "rectangle": (RECTANGLE, ()),
    "l": (L_SHAPE, ()),
    "t": (T_SHAPE, ()),
    "courtyard": (YARD_OUTLINE, (YARD,)),
}


def level_ground(points):
    """Return a ground 100 m high everywhere."""
    return np.full(len(points), 100.0)


def shape_named(outline, holes, name):
    """Return the first roof shape of a footprint with this name."""
    return next(shape for shape in building_shapes.shapes(outline, holes) if shape.name == name)


def shell_of(shape, eave_m=104.0, slope=0.5, ground=level_ground, foot_m=99.5):
    """Return the closed mesh of a roof shape over level ground."""
    return building_shapes.shell(shape, eave_m + slope * shape.rise, foot_m, ground)


def lidar_of(shape, eave_m, slope, spacing_m=0.5):
    """Return points inside a shape's footprint and the roof's height there."""
    low, high = shape.points.min(0), shape.points.max(0)
    xs, ys = np.meshgrid(
        np.arange(low[0] + 0.25, high[0], spacing_m), np.arange(low[1] + 0.25, high[1], spacing_m)
    )
    samples = np.column_stack([xs.ravel(), ys.ravel()])
    rise = building_shapes.rise_at(shape, samples)
    inside = ~np.isnan(rise)
    return samples[inside], eave_m + slope * rise[inside]


class ShapesTest(unittest.TestCase):
    """The roof shapes a footprint offers."""

    def test_every_shape_of_every_footprint_is_watertight(self):
        for label, (outline, holes) in FOOTPRINTS.items():
            for shape in building_shapes.shapes(outline, holes):
                with self.subTest(footprint=label, shape=shape.name):
                    self.assertIsNone(building_shapes.faults(shell_of(shape).triangles()))

    def test_a_rectangle_offers_every_shape(self):
        names = {shape.name for shape in building_shapes.shapes(RECTANGLE, ())}
        self.assertEqual(names, {"flat", "gable", "hip", "skillion", "pyramid"})

    def test_a_hip_has_level_eaves(self):
        shell = shell_of(shape_named(L_SHAPE, (), "hip"))
        self.assertAlmostEqual(float(shell.walls[:, :, 2].max()), 104.0)
        self.assertAlmostEqual(float(shell.roof[:, :, 2].max()), 104.0 + 0.5 * 3.0)

    def test_a_gable_s_end_walls_reach_the_ridge(self):
        shell = shell_of(shape_named(RECTANGLE, (), "gable"))
        ridge_m = 104.0 + 0.5 * 4.0
        self.assertAlmostEqual(float(shell.roof[:, :, 2].max()), ridge_m)
        end_walls = shell.walls[np.all(np.abs(shell.walls[:, :, 0]) < 1e-9, axis=1)]
        self.assertAlmostEqual(float(end_walls[:, :, 2].max()), ridge_m)
        apex = end_walls.reshape(-1, 3)[end_walls[:, :, 2].argmax()]
        np.testing.assert_allclose(apex, (0.0, 4.0, ridge_m), atol=1e-9)

    def test_an_l_shaped_gable_has_a_gable_at_the_end_of_each_wing(self):
        shell = shell_of(shape_named(L_SHAPE, (), "gable"))
        tops = shell.walls.reshape(-1, 3)
        raised = tops[tops[:, 2] > 104.0 + 1e-6][:, :2]
        ends = {tuple(float(number) for number in np.round(point, 6)) for point in raised}
        self.assertEqual(ends, {(14.0, 3.0), (3.0, 14.0)})

    def test_a_skillion_rises_across_the_footprint(self):
        shell = shell_of(shape_named(RECTANGLE, (), "skillion"))
        self.assertAlmostEqual(float(shell.roof[:, :, 2].min()), 104.0)
        self.assertAlmostEqual(float(shell.roof[:, :, 2].max()), 104.0 + 0.5 * 8.0)

    def test_a_pyramid_rises_to_one_point(self):
        shape = shape_named(SQUARE, (), "pyramid")
        self.assertEqual(int((shape.rise > 0.0).sum()), 1)
        np.testing.assert_allclose(shape.points[shape.rise.argmax()], (4.0, 4.0))


class ShellTest(unittest.TestCase):
    """Walls, floor and texture coordinates of a building."""

    def test_walls_hang_below_the_lowest_ground_under_the_building(self):
        def sloping(points):
            return 100.0 + 0.2 * points[:, 0] - 0.1 * points[:, 1]

        shape = shape_named(L_SHAPE, (), "hip")
        foot_m = building_shapes.foot_height_m(shape, sloping)
        self.assertAlmostEqual(foot_m, 100.0 - 0.1 * 14.0 - building_shapes.SKIRT_M)
        shell = building_shapes.shell(shape, 108.0 + 0.5 * shape.rise, foot_m, sloping)
        self.assertIsNone(building_shapes.faults(shell.triangles()))
        self.assertAlmostEqual(float(shell.walls[:, :, 2].min()), foot_m)
        self.assertAlmostEqual(float(shell.floor[:, :, 2].max()), foot_m)

    def test_a_wall_s_windows_are_measured_from_its_own_corner_and_floor(self):
        def stepped(points):
            return np.where(points[:, 1] > 4.0, 101.0, 100.0)

        shell = building_shapes.shell(
            shape_named(RECTANGLE, (), "flat"), np.full(4, 106.0), 99.0, stepped
        )
        metres = shell.wall_uv[:, :, 0] * building_shapes.FACADE_UV_M
        self.assertAlmostEqual(float(metres.min()), 0.0)
        self.assertAlmostEqual(float(metres.max()), 12.0)
        south = np.all(np.abs(shell.walls[:, :, 1]) < 1e-9, axis=1)
        north = np.all(np.abs(shell.walls[:, :, 1] - 8.0) < 1e-9, axis=1)
        np.testing.assert_allclose(shell.wall_uv2[south][:, :, 0], 6.0)
        np.testing.assert_allclose(shell.wall_uv2[north][:, :, 0], 5.0)
        np.testing.assert_allclose(shell.wall_uv2[south][:, :, 1], 12.0)
        above_floor_m = (1.0 - shell.wall_uv[north][:, :, 1]) * building_shapes.FACADE_UV_M
        np.testing.assert_allclose(above_floor_m.max(), 5.0)

    def test_a_gable_end_is_one_wall(self):
        shell = shell_of(shape_named(RECTANGLE, (), "gable"))
        west = np.all(np.abs(shell.walls[:, :, 0]) < 1e-9, axis=1)
        np.testing.assert_allclose(shell.wall_uv2[west][:, :, 1], 8.0)
        along_m = shell.wall_uv[west][:, :, 0] * building_shapes.FACADE_UV_M
        self.assertAlmostEqual(float(along_m.max()), 8.0)

    def test_roof_rows_run_along_the_eave_and_up_the_slope(self):
        shell = shell_of(shape_named(RECTANGLE, (), "gable"), slope=0.75)
        south_side = shell.roof[np.all(shell.roof[:, :, 1] <= 4.0 + 1e-9, axis=1)]
        rows = building_shapes.roof_rows(south_side)
        np.testing.assert_allclose(np.ptp(rows[:, :, 0]), 12.0)
        np.testing.assert_allclose(np.ptp(rows[:, :, 1]), 5.0)


class RoofEdgeTest(unittest.TestCase):
    """Distances to the roof's edge."""

    def test_a_corner_is_as_far_from_the_roof_s_edge_as_from_its_triangle_s_outline_edges(self):
        shape = shape_named(RECTANGLE, (), "flat")
        edges_m = building_shapes.roof_edge_distances_m(shape, np.full(4, 106.0))
        self.assertEqual(edges_m.shape, (2, 3, 2))
        for triangle in edges_m:
            self.assertEqual(
                sorted(sorted(corner) for corner in triangle.tolist()),
                [[0.0, 0.0], [0.0, 8.0], [0.0, 12.0]],
            )

    def test_a_triangle_inside_the_roof_is_far_from_its_edge(self):
        shape = shape_named(RECTANGLE, (), "hip")
        edges_m = building_shapes.roof_edge_distances_m(shape, 104.0 + 0.75 * shape.rise)
        far = building_shapes.FAR_FROM_EDGE_M
        on_slope = edges_m[np.all(edges_m[:, :, 1] == far, axis=1)]
        self.assertEqual(sorted(set(np.round(on_slope[:, :, 0].ravel(), 6))), [0.0, 5.0, far])
        self.assertTrue(np.any(np.all(on_slope[:, :, 0] == far, axis=1)))


class FaultsTest(unittest.TestCase):
    """What keeps a mesh from being a closed solid."""

    def setUp(self):
        self.triangles = shell_of(shape_named(RECTANGLE, (), "gable")).triangles()

    def test_a_closed_building_has_none(self):
        self.assertIsNone(building_shapes.faults(self.triangles))

    def test_a_missing_wall_is_an_opening(self):
        self.assertIn("open", building_shapes.faults(self.triangles[1:]))

    def test_a_wall_wound_inwards_is_found(self):
        flipped = self.triangles.copy()
        flipped[5] = flipped[5][::-1]
        self.assertIn("winding", building_shapes.faults(flipped))

    def test_a_building_wound_inside_out_is_found(self):
        self.assertIn("inside out", building_shapes.faults(self.triangles[:, ::-1]))

    def test_a_triangle_without_area_is_found(self):
        sliver = self.triangles.copy()
        sliver[0, 2] = sliver[0, 1]
        self.assertIn("degenerate", building_shapes.faults(sliver))


class FitTest(unittest.TestCase):
    """Shapes fitted to LiDAR points."""

    def test_the_shape_the_lidar_shows_is_chosen(self):
        cases = [
            (RECTANGLE, "gable", 0.7),
            (RECTANGLE, "hip", 0.7),
            (RECTANGLE, "skillion", 0.3),
            (SQUARE, "pyramid", 0.6),
            (L_SHAPE, "hip", 0.6),
            (L_SHAPE, "gable", 0.6),
        ]
        noise = np.random.default_rng(3)
        for outline, name, slope in cases:
            with self.subTest(shape=name, corners=len(outline)):
                truth = shape_named(outline, (), name)
                samples, heights_m = lidar_of(truth, 105.0, slope)
                heights_m = heights_m + noise.normal(0.0, 0.08, len(heights_m))
                fit = building_shapes.fitted(
                    building_shapes.shapes(outline, ()), samples, heights_m
                )
                self.assertEqual(fit.shape.name, name)
                self.assertAlmostEqual(fit.eave_m, 105.0, delta=0.15)
                self.assertAlmostEqual(fit.slope, slope, delta=0.06)

    def test_a_roof_that_hardly_rises_is_flat(self):
        truth = shape_named(RECTANGLE, (), "gable")
        samples, heights_m = lidar_of(truth, 105.0, 0.08)
        fit = building_shapes.fitted(building_shapes.shapes(RECTANGLE, ()), samples, heights_m)
        self.assertEqual(fit.shape.name, "flat")
        self.assertAlmostEqual(fit.eave_m, 105.16, delta=0.1)

    def test_a_skillion_rises_no_more_than_a_single_pitch_does(self):
        truth = shape_named(RECTANGLE, (), "skillion")
        samples, heights_m = lidar_of(truth, 105.0, 1.2)
        fit = building_shapes._fit(truth, building_shapes.rise_at(truth, samples), heights_m)
        self.assertAlmostEqual(
            fit.slope * float(truth.rise.max()), building_shapes.SKILLION_MAX_RISE_M
        )

    def test_a_tree_over_the_roof_does_not_raise_it(self):
        truth = shape_named(RECTANGLE, (), "gable")
        samples, heights_m = lidar_of(truth, 105.0, 0.7)
        under_tree = (samples[:, 0] > 9.0) & (samples[:, 1] > 5.0)
        heights_m[under_tree] += 6.0
        fit = building_shapes.fitted(building_shapes.shapes(RECTANGLE, ()), samples, heights_m)
        self.assertEqual(fit.shape.name, "gable")
        self.assertAlmostEqual(fit.eave_m, 105.0, delta=0.3)

    def test_only_the_named_shape_is_fitted_when_the_map_names_it(self):
        truth = shape_named(RECTANGLE, (), "gable")
        samples, heights_m = lidar_of(truth, 105.0, 0.7)
        fit = building_shapes.fitted(
            building_shapes.shapes(RECTANGLE, ()), samples, heights_m, named="hip"
        )
        self.assertEqual(fit.shape.name, "hip")


if __name__ == "__main__":
    unittest.main()
