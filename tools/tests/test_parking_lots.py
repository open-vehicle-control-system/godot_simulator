# ruff: noqa: D102
"""Tests of the parking lot survey: outline, bay grid, lot map and description."""

import math
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import parking_lots as lots

PX_M = 0.25
SQUARE = np.array([(0.0, 0.0), (40.0, 0.0), (40.0, 30.0), (0.0, 30.0)])


def turned(along_m, across_m, angle_rad):
    """Return positions given in a frame turned by `angle_rad`."""
    cosine, sine = math.cos(angle_rad), math.sin(angle_rad)
    return along_m * cosine - across_m * sine, along_m * sine + across_m * cosine


def bay_paint(rows, bay_width_m, angle_rad, missing=()):
    """Return the painted pixels of rows of bays: (first divider, dividers, from, to) each.

    The dividers numbered in `missing` are hidden.
    """
    along, across = [], []
    for first_m, dividers, from_m, to_m in rows:
        for divider in range(dividers):
            if divider in missing:
                continue
            reach = np.arange(from_m, to_m, PX_M)
            along.append(np.full(len(reach), first_m + divider * bay_width_m))
            across.append(reach)
    return turned(np.concatenate(along), np.concatenate(across), angle_rad)


class SignedDistanceTest(unittest.TestCase):
    """The distance to a lot's outline."""

    def test_is_negative_inside_and_positive_outside(self):
        distance = lots.signed_distance(
            SQUARE, np.array([20.0, 20.0, 43.0, -3.0]), np.array([10.0, 29.0, 15.0, -4.0])
        )

        np.testing.assert_allclose(distance, [-10.0, -1.0, 3.0, 5.0])

    def test_the_winding_of_the_outline_does_not_matter(self):
        distance = lots.signed_distance(SQUARE[::-1], np.array([20.0]), np.array([10.0]))

        np.testing.assert_allclose(distance, [-10.0])


class FitOutlineTest(unittest.TestCase):
    """A mapped outline moved to where the lot ends."""

    def test_an_edge_moves_to_where_the_surface_ends(self):
        # The lot really reaches 2 m further east and stops 1.5 m short in the north.
        fitted = lots.fit_outline(
            SQUARE, lambda x, y: (x >= 0) & (x <= 42) & (y >= 0) & (y <= 28.5)
        )

        np.testing.assert_allclose(
            fitted, [(0, 0), (42, 0), (42, 28.5), (0, 28.5)], atol=lots.OUTLINE_STEP_M
        )

    def test_an_edge_along_which_the_surface_carries_on_stays_as_mapped(self):
        fitted = lots.fit_outline(SQUARE, lambda x, y: (x >= 0) & (y >= 0) & (y <= 30))

        np.testing.assert_allclose(fitted, SQUARE, atol=lots.OUTLINE_STEP_M)

    def test_cars_along_an_edge_do_not_move_it(self):
        def lot_like(x, y):
            parked = (y > 27.0) & (x % 10.0 < 2.0)
            return (x >= 0) & (x <= 40) & (y >= 0) & (y <= 30) & ~parked

        np.testing.assert_allclose(
            lots.fit_outline(SQUARE, lot_like), SQUARE, atol=lots.OUTLINE_STEP_M
        )

    def test_a_clockwise_outline_is_fitted_the_same(self):
        fitted = lots.fit_outline(
            SQUARE[::-1], lambda x, y: (x >= 0) & (x <= 42) & (y >= 0) & (y <= 30)
        )

        self.assertAlmostEqual(fitted[:, 0].max(), 42.0, delta=lots.OUTLINE_STEP_M)


class BayGridTest(unittest.TestCase):
    """The bays a lot's paint shows."""

    def test_finds_the_direction_width_and_rows_of_the_bays(self):
        angle = math.radians(30.0)
        paint = bay_paint([(-20.0, 15, -8.0, -3.0), (-17.5, 12, 3.0, 8.0)], 2.5, angle)

        found_angle, width_m, rows = lots.bay_grid(*paint)

        self.assertAlmostEqual(math.degrees(found_angle) % 180.0, 30.0, delta=0.5)
        self.assertAlmostEqual(width_m, 2.5, delta=0.03)
        self.assertEqual(len(rows), 2)
        flipped = abs(math.degrees(found_angle) - 30.0) > 90.0
        longest = rows[0]
        along = sorted(-end if flipped else end for end in longest.along_m)
        across = sorted(-end if flipped else end for end in longest.across_m)
        np.testing.assert_allclose(along, [-20.0, 15.0], atol=0.3)
        np.testing.assert_allclose(across, [-8.0, -3.0], atol=0.3)

    def test_dividers_hidden_by_cars_are_drawn_all_the_same(self):
        paint = bay_paint([(0.0, 14, 0.0, 5.0)], 2.6, 0.0, missing=(3, 4, 9))

        _, width_m, rows = lots.bay_grid(*paint)

        self.assertAlmostEqual(width_m, 2.6, delta=0.03)
        self.assertEqual(len(rows), 1)
        self.assertAlmostEqual(abs(rows[0].along_m[1] - rows[0].along_m[0]), 13 * 2.6, delta=0.3)

    def test_a_line_along_the_row_closes_it(self):
        along, across = bay_paint([(0.0, 14, 0.0, 5.0)], 2.5, 0.0)
        line = np.arange(0.0, 32.5, PX_M)
        along = np.concatenate([along, line])
        across = np.concatenate([across, np.zeros(len(line))])

        _, _, rows = lots.bay_grid(along, across)

        low_end = int(np.argmin(rows[0].across_m))
        self.assertTrue(rows[0].ends[low_end])
        self.assertFalse(rows[0].ends[1 - low_end])

    def test_cars_and_scattered_paint_are_not_bays(self):
        rng = np.random.default_rng(5)
        blobs_x, blobs_y = np.meshgrid(np.arange(0.0, 2.0, PX_M), np.arange(0.0, 4.5, PX_M))
        cars = [
            (blobs_x.ravel() + east, blobs_y.ravel() + north)
            for east, north in rng.uniform(0, 60, (30, 2))
        ]
        x = np.concatenate([car[0] for car in cars] + [rng.uniform(0, 60, 300)])
        y = np.concatenate([car[1] for car in cars] + [rng.uniform(0, 60, 300)])

        found = lots.bay_grid(x, y)

        self.assertTrue(found is None or found[2] == [])

    def test_a_lot_without_paint_has_no_bays(self):
        self.assertIsNone(lots.bay_grid(np.zeros(0), np.zeros(0)))


class PaintMaskTest(unittest.TestCase):
    """Thin light paint told from the ground and from cars."""

    def test_a_thin_line_is_paint_and_a_white_car_is_not(self):
        luminance = np.full((60, 60), 0.4, np.float32)
        luminance[10:50, 20] = 0.55
        luminance[20:38, 40:48] = 0.9

        mask = lots.paint_mask(luminance)

        self.assertTrue(mask[12:48, 20].all())
        self.assertFalse(mask[22:36, 42:46].any())


class Field:
    """A stand-in for the surveyed ground: 100 m of asphalt at 4 px/m, grass east of 60 m."""

    class Mosaic:
        """Its photo."""

        west = 0.0
        north = 100.0
        px_per_m = 4.0
        rgb = np.zeros((400, 400, 3), np.uint8)

    mosaic = Mosaic
    origin = (0.0, 0.0)
    labels = np.full((400, 400), 6, np.uint8)
    labels[:, 240:] = 0


class LotMapTest(unittest.TestCase):
    """Lots laid on the map."""

    def at(self, lot_map, east, north):
        row, column = int((100.0 - north) / lot_map.cell_m), int(east / lot_map.cell_m)
        return int(lot_map.lot[row, column]), float(lot_map.edge_m[row, column])

    def setUp(self):
        self.roads = np.zeros((200, 200), np.float32)
        self.outline = np.array([(20.0, 20.0), (80.0, 20.0), (80.0, 50.0), (20.0, 50.0)])

    def lot_map(self):
        lot_map = lots.LotMap(Field, self.roads)
        lot_map.lay(1, lots.Lot(self.outline, 6, np.zeros(3)))
        return lot_map

    def test_the_ground_inside_the_outline_is_the_lots(self):
        lot, edge_m = self.at(self.lot_map(), 30.25, 25.25)

        self.assertEqual(lot, 1)
        self.assertLess(edge_m, -1.5)

    def test_the_ground_outside_the_outline_is_not(self):
        lot_map = self.lot_map()

        self.assertGreater(self.at(lot_map, 30.25, 18.25)[1], 0.0)
        self.assertEqual(self.at(lot_map, 30.25, 10.25)[0], 0)

    def test_vegetation_inside_the_outline_is_not_the_lots(self):
        lot_map = self.lot_map()

        self.assertLess(self.at(lot_map, 55.25, 35.25)[1], 0.0)
        self.assertGreater(self.at(lot_map, 65.25, 35.25)[1], 0.0)

    def test_a_lot_stops_at_the_edge_of_a_road_through_it(self):
        self.roads[130:140, :] = 2.0

        lot_map = self.lot_map()

        self.assertGreater(self.at(lot_map, 40.25, 32.25)[1], 0.0)
        self.assertLess(self.at(lot_map, 40.25, 40.25)[1], 0.0)


class YardsTest(unittest.TestCase):
    """Paved ground with cars on it that no map calls a lot."""

    def test_what_stands_on_a_surface_is_clutter_and_the_surface_is_not(self):
        brightness = np.full((60, 60), 0.5, np.float32)
        brightness[:, 40:] = 0.7  # another surface
        brightness[10:14, 10:12] = 0.9  # a white car
        brightness[30:34, 20:22] = 0.15  # a dark one

        clutter = lots.cluttered(brightness, np.ones((60, 60), bool))

        self.assertTrue(clutter[10:14, 10:12].all() and clutter[30:34, 20:22].all())
        self.assertEqual(clutter.sum(), 16)

    def test_clutter_off_made_ground_does_not_count(self):
        brightness = np.full((30, 30), 0.5, np.float32)
        brightness[10:14, 10:12] = 0.9

        self.assertFalse(lots.cluttered(brightness, np.zeros((30, 30), bool)).any())

    def test_a_yard_is_a_large_connected_area_of_cluttered_made_ground(self):
        clutter = np.zeros((40, 40), np.float32)
        clutter[5:20, 5:20] = 0.3  # 15 x 15 cells of 2 m
        clutter[30:33, 30:33] = 0.3  # too small
        clutter[5:20, 25:38] = 0.3  # not made ground
        made = np.ones((40, 40), np.float32)
        made[:, 24:] = 0.4
        free = np.ones((40, 40), bool)
        free[5:20, 5:8] = False  # a road

        areas = lots.yard_areas(clutter, made, free, 2.0)

        self.assertEqual(len(areas), 1)
        self.assertEqual(int(areas[0].sum()), 15 * 12)
        self.assertTrue(areas[0][10, 10] and not areas[0][10, 6])

    def test_a_yard_is_laid_where_it_reaches(self):
        lot_map = lots.LotMap(Field, np.zeros((200, 200), np.float32))
        edge_m = np.full((10, 10), -1.0, np.float32)
        yard = lots.Lot(None, 6, np.zeros(3), reach=(slice(20, 30), slice(40, 50), edge_m))

        lot_map.lay(2, yard)

        self.assertEqual(int(lot_map.lot[25, 45]), 2)
        self.assertEqual(int(lot_map.lot[35, 45]), 0)


class LotFilesTest(unittest.TestCase):
    """What the pack holds of a lot."""

    def test_the_lot_map_holds_the_lot_and_the_distance_to_its_edge(self):
        image = lots.lot_map_image(
            np.array([[3, 0]], np.uint8), np.array([[-1.0, 0.5]], np.float32)
        )

        self.assertEqual(list(image[0, 0]), [3, 88, 0])
        self.assertEqual(list(image[0, 1]), [0, 148, 0])

    def test_a_lot_is_described_in_the_packs_frame(self):
        row = lots.Row((-10.0, 15.0), (2.0, 7.0), (True, False))
        lot = lots.Lot(
            SQUARE, 6, np.array([0.2, 0.21, 0.22]), (20.0, 15.0), math.radians(30.0), 2.5, [row]
        )

        described = lots.described(lot)

        # East 20, north 15 is x (south) -15, y (east) 20; east is a quarter turn from south.
        self.assertEqual(described["origin_m"], [-15.0, 20.0])
        self.assertAlmostEqual(described["yaw_deg"], 120.0)
        self.assertEqual(described["bay_width_m"], 2.5)
        self.assertEqual(
            described["rows"], [{"along_m": [-10.0, 15.0], "across_m": [2.0, 7.0], "ends": [1, 0]}]
        )


if __name__ == "__main__":
    unittest.main()
