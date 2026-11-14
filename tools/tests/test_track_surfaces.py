# ruff: noqa: D102
"""Tests of the road survey: edges, kerbs, racing line and the lines image."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import track_surfaces as surfaces

SECTIONS = 40
STEPS = round(
    (surfaces.EDGE_SEARCH_TO_M + surfaces.KERB_MAX_WIDTH_M - surfaces.EDGE_SEARCH_FROM_M)
    / surfaces.LATERAL_STEP_M
)


def step_of(lateral_m):
    """Return the lateral step at `lateral_m` from the centreline."""
    return round((lateral_m - surfaces.EDGE_SEARCH_FROM_M) / surfaces.LATERAL_STEP_M)


def road(edge_m):
    """Return paved flags of a road whose asphalt ends at `edge_m`."""
    paved = np.zeros((SECTIONS, STEPS), bool)
    paved[:, : step_of(edge_m)] = True
    return paved


class AsphaltEndsTest(unittest.TestCase):
    """Where each section's asphalt seems to end."""

    def test_the_end_is_where_the_asphalt_stops(self):
        np.testing.assert_allclose(surfaces.asphalt_ends(road(5.0)), 5.0)

    def test_a_gap_in_the_asphalt_narrower_than_a_run_is_not_its_end(self):
        paved = road(5.0)
        paved[:, step_of(3.0)] = False

        np.testing.assert_allclose(surfaces.asphalt_ends(paved), 5.0)

    def test_asphalt_that_does_not_end_has_no_end(self):
        paved = road(5.0)
        paved[3, :] = True

        self.assertTrue(np.isnan(surfaces.asphalt_ends(paved)[3]))


INSIDE_M = surfaces.LINE_INSET_M + surfaces.LINE_WIDTH_M / 2.0  # a line inside the asphalt's end


def painted(line_m, count=400):
    """Return paint flags of a lap with a line at `line_m` (one value or one per section)."""
    paint = np.zeros((count, STEPS), bool)
    steps = np.broadcast_to(np.round((np.asarray(line_m) - 2.0) / 0.125).astype(int), count)
    paint[np.arange(count), steps] = True
    return paint


class LinePaintTest(unittest.TestCase):
    """Which of the photo's light ground is a line's paint."""

    def test_a_thin_light_strip_is_paint(self):
        luminance = np.full((5, STEPS), 0.4)
        luminance[:, 30:32] = 0.6

        paint = surfaces.line_paint(luminance, np.zeros(luminance.shape, bool))

        self.assertTrue(paint[:, 30:32].all())
        self.assertEqual(int(paint.sum()), 10)

    def test_only_the_inner_rim_of_lighter_ground_is_paint(self):
        luminance = np.full((5, STEPS), 0.4)
        luminance[:, 40:] = 0.7

        paint = surfaces.line_paint(luminance, np.zeros(luminance.shape, bool))

        self.assertTrue(paint[:, 40:42].all())
        self.assertEqual(int(paint.sum()), 10)

    def test_the_white_of_a_kerb_is_not_a_line_but_its_inner_rim_is(self):
        luminance = np.full((5, STEPS), 0.4)
        luminance[:, 30:38] = 0.6
        kerb = np.zeros((5, STEPS), bool)
        kerb[:, 28:50] = True

        paint = surfaces.line_paint(luminance, kerb)

        self.assertTrue(paint[:, 30:32].all())
        self.assertEqual(int(paint.sum()), 10)


class TraceLineTest(unittest.TestCase):
    """The course of a line through the evidence for it."""

    def test_follows_a_line_that_moves_sideways(self):
        steps = np.round(20 + 10 * np.sin(np.arange(400) / 400 * 2 * np.pi)).astype(int)
        score = np.zeros((400, 60))
        score[np.arange(400), steps] = 1.0

        np.testing.assert_array_equal(surfaces.trace_line(score), steps)

    def test_keeps_to_a_long_line_past_a_short_one_beside_it(self):
        score = np.zeros((400, 60))
        score[:, 30] = 1.0
        score[100:108, 22] = 2.0

        self.assertTrue((surfaces.trace_line(score) == 30).all())

    def test_carries_on_where_the_evidence_stops(self):
        score = np.zeros((400, 60))
        score[:, 30] = 1.0
        score[150:200] = 0.0

        self.assertTrue((surfaces.trace_line(score) == 30).all())


class EdgeLineTest(unittest.TestCase):
    """A side's edge line from the photo's paint and the asphalt's end."""

    def test_the_line_is_where_the_paint_is_not_where_the_asphalt_ends(self):
        line, gap = surfaces.edge_line(painted(6.0), np.full(400, 9.0), 1.0)

        np.testing.assert_allclose(line, 6.0, atol=1e-6)
        self.assertFalse(gap.any())

    def test_paved_run_off_beside_the_line_does_not_move_it(self):
        asphalt_end = np.full(400, 6.5)
        asphalt_end[100:200] = np.nan

        line, gap = surfaces.edge_line(painted(6.0), asphalt_end, 1.0)

        np.testing.assert_allclose(line, 6.0, atol=1e-6)
        self.assertFalse(gap.any())

    def test_noise_in_the_paint_does_not_wobble_the_line(self):
        noise = np.random.default_rng(3).uniform(-0.125, 0.125, 400)

        line, gap = surfaces.edge_line(painted(6.0 + noise), np.full(400, 7.0), 1.0)

        self.assertLess(float(np.abs(line - 6.0).max()), 0.06)
        self.assertLess(float(np.abs(np.diff(line)).max()), 0.01)
        self.assertFalse(gap.any())

    def test_without_paint_the_line_runs_just_inside_the_asphalts_end(self):
        line, gap = surfaces.edge_line(np.zeros((400, STEPS), bool), np.full(400, 5.0), 1.0)

        np.testing.assert_allclose(line, 5.0 - INSIDE_M, atol=1e-6)
        self.assertFalse(gap.any())

    def test_a_line_carries_on_under_what_hides_it(self):
        paint = painted(6.0)
        paint[100:130] = False

        line, gap = surfaces.edge_line(paint, np.full(400, 6.0 + INSIDE_M), 1.0)

        np.testing.assert_allclose(line, 6.0, atol=0.03)
        self.assertFalse(gap.any())

    def test_a_junction_is_a_gap_the_line_carries_on_across(self):
        paint = painted(6.0)
        paint[100:140] = False
        asphalt_end = np.full(400, 6.0 + INSIDE_M)
        asphalt_end[100:130] = np.nan
        asphalt_end[130:140] = 11.0

        line, gap = surfaces.edge_line(paint, asphalt_end, 1.0)

        np.testing.assert_allclose(line, 6.0, atol=0.03)
        self.assertTrue(gap[100:140].all())
        self.assertFalse(gap[:100].any() or gap[140:].any())

    def test_a_short_mark_inside_the_line_is_not_the_line(self):
        paint = painted(6.0)
        paint[100:103, 8] = True

        line, _ = surfaces.edge_line(paint, np.full(400, 6.0 + INSIDE_M), 1.0)

        np.testing.assert_allclose(line, 6.0, atol=1e-6)

    def test_paint_beyond_the_asphalt_is_not_the_line(self):
        paint = painted(6.0)
        paint[:, step_of(8.0)] = True
        paint[150:250, step_of(6.0)] = False

        line, _ = surfaces.edge_line(paint, np.full(400, 6.0 + INSIDE_M), 1.0)

        self.assertLess(float(np.abs(line - 6.0).max()), 0.03)


class KerbSegmentsTest(unittest.TestCase):
    """Kerbs as clean segments of whole stripes."""

    def setUp(self):
        self.s = np.arange(0.0, 400.0, 1.0)

    def test_paint_at_the_fitted_edge_is_measured(self):
        paint = np.zeros((SECTIONS, STEPS), bool)
        paint[:, step_of(4.75) : step_of(5.75)] = True

        np.testing.assert_allclose(surfaces.kerb_widths(paint, np.full(SECTIONS, 5.0)), 1.0)

    def test_a_kerb_is_whole_stripes_of_one_width(self):
        width = np.zeros(400)
        width[100:131] = 1.0 + np.random.default_rng(5).uniform(-0.15, 0.15, 31)

        segments = surfaces.kerb_segments(width, self.s, 400.0)

        self.assertEqual(len(segments), 1)
        from_m, to_m, width_m = segments[0]
        self.assertEqual((from_m, to_m), (99.0, 130.5))
        self.assertAlmostEqual(width_m, 1.0, places=6)

    def test_a_short_break_in_the_paint_does_not_split_a_kerb(self):
        width = np.zeros(400)
        width[100:130] = 1.0
        width[114:116] = 0.0

        self.assertEqual(len(surfaces.kerb_segments(width, self.s, 400.0)), 1)

    def test_a_short_stretch_of_paint_is_not_a_kerb(self):
        width = np.zeros(400)
        width[100:103] = 1.0

        self.assertEqual(surfaces.kerb_segments(width, self.s, 400.0), [])

    def test_a_kerb_across_the_start_line_ends_beyond_the_lap(self):
        width = np.zeros(400)
        width[390:] = 1.2
        width[:10] = 1.2

        self.assertEqual(surfaces.kerb_segments(width, self.s, 400.0), [(390.0, 409.5, 1.2)])


class KerbPaintTest(unittest.TestCase):
    """Which photo colours are kerb paint."""

    def test_tells_blurred_kerb_stripes_from_the_ground_around_them(self):
        cases = {
            (126, 114, 108): True,  # red and white
            (118, 128, 120): True,  # green and white
            (101, 102, 97): False,  # asphalt
            (51, 69, 50): False,  # grass
            (141, 134, 123): False,  # sand
        }
        for colour, expected in cases.items():
            albedo = surfaces.ground_classes.linear(np.array(colour) / 255.0)
            self.assertEqual(bool(surfaces.is_kerb_paint(albedo)), expected, colour)


class RacingLineTest(unittest.TestCase):
    """The racing line through a corner."""

    def test_cuts_inside_at_the_apex_and_runs_wide_before_it(self):
        curvature = np.zeros(400)
        curvature[190:210] = 1.0 / 30.0  # a right-hander
        edges = np.full(400, 5.0)

        offset, rubber = surfaces.racing_line(curvature, 1.0, edges, edges)

        self.assertGreater(offset[200], 2.0)
        self.assertLess(offset[140], -0.3)
        self.assertAlmostEqual(float(offset[0]), 0.0, places=2)
        self.assertGreater(rubber[200], rubber[0])

    def test_stays_on_the_asphalt(self):
        curvature = np.full(100, -1.0 / 10.0)
        left, right = np.full(100, 4.0), np.full(100, 6.0)

        offset, _ = surfaces.racing_line(curvature, 1.0, left, right)

        self.assertTrue((offset >= -4.0 + surfaces.RACING_LINE_MARGIN_M - 1e-6).all())


class LinesImageTest(unittest.TestCase):
    """The road lines image's encoding."""

    def test_encodes_edges_gaps_kerbs_and_the_racing_line_per_metre(self):
        s = np.arange(0.0, 100.0, 2.0)
        count = len(s)
        edges = [np.full(count, 5.0), np.full(count, 6.0)]
        gaps = [np.zeros(count, bool), s >= 60.0]
        kerbs = [[(45.0, 54.0, 1.2), (96.0, 103.5, 0.8)], []]

        image = surfaces.lines_image(
            s, 100.0, edges, gaps, kerbs, np.full(count, -1.0), np.full(count, 0.5)
        )

        self.assertEqual(image.shape, (3, 101, 4))
        self.assertEqual(list(image[0, 50]), [5000 >> 8, 5000 & 255, 6000 >> 8, 6000 & 255])
        self.assertEqual(list(image[1, 50]), [120, 0, 108, 128])
        self.assertEqual(list(image[1, 60, :2]), [0, 0])
        self.assertEqual([int(image[1, metre, 0]) for metre in (95, 98, 2, 4)], [0, 80, 80, 0])
        self.assertEqual(list(image[2, 50, :2]), [255, 255])
        self.assertEqual(list(image[2, 80, :2]), [255, 0])


class Square:
    """A stand-in for the mosaic: 100 m of ground at 4 px/m, its north-west corner at (0, 100)."""

    west = 0.0
    north = 100.0
    px_per_m = 4.0
    rgb = np.zeros((400, 400, 3), np.uint8)


class TrackCoordinatesTest(unittest.TestCase):
    """How far along and right of the centreline the ground is."""

    def setUp(self):
        # A lap heading east along north = 50, from east = 20 to 80, closed far away.
        self.sections = {
            "x": [20.0, 50.0, 80.0, 80.0, 20.0],
            "y": [50.0, 50.0, 50.0, -500.0, -500.0],
            "s": [0.0, 30.0, 60.0, 610.0, 670.0],
        }
        self.along, self.right = surfaces.track_coordinates(
            Square, (0.0, 0.0), self.sections, 1220.0
        )

    def at(self, east, north):
        """Return (along, right) at a map position."""
        row = int((100.0 - north) / surfaces.TRACK_MAP_M_PER_PX)
        column = int(east / surfaces.TRACK_MAP_M_PER_PX)
        return float(self.along[row, column]), float(self.right[row, column])

    def test_south_of_an_eastward_road_is_its_right(self):
        along, right = self.at(40.25, 45.25)

        self.assertAlmostEqual(along, 20.25, places=3)
        self.assertAlmostEqual(right, 4.75, places=3)

    def test_north_of_an_eastward_road_is_its_left(self):
        _, right = self.at(40.25, 53.25)

        self.assertAlmostEqual(right, -3.25, places=3)

    def test_ground_far_from_the_road_is_off_track(self):
        along, _ = self.at(40.0, 90.0)

        self.assertTrue(np.isnan(along))

    def test_the_image_holds_twenty_bits_along_and_twelve_right(self):
        along = np.array([[10000.0, np.nan]], np.float32)
        right = np.array([[-2.5, np.nan]], np.float32)

        image = surfaces.road_map_image(along, right)

        self.assertEqual(list(image[0, 0]), [80000 >> 12, (80000 >> 4) & 255, 7, 1798 & 255])
        self.assertEqual(list(image[0, 1]), [0, 0, 15, 255])


class RoadMapTest(unittest.TestCase):
    """Open roads laid on one map."""

    def road(self, x, y):
        s = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(x), np.diff(y)))])
        return {"x": x, "y": y, "s": s}

    def at(self, road_map, east, north):
        row = int((100.0 - north) / surfaces.TRACK_MAP_M_PER_PX)
        column = int(east / surfaces.TRACK_MAP_M_PER_PX)
        return float(road_map.along[row, column]), float(road_map.right[row, column])

    def setUp(self):
        self.road_map = surfaces.RoadMap(Square)
        main = self.road(np.linspace(20.0, 80.0, 61), np.full(61, 50.0))
        side = self.road(np.full(31, 50.0), np.linspace(50.0, 20.0, 31))
        self.road_map.lay_road((0.0, 0.0), side, 200.0 + side["s"], np.full(31, 2.0), 0)
        self.road_map.lay_road((0.0, 0.0), main, 100.0 + main["s"], np.full(61, 3.0), 1)

    def test_a_road_reaches_a_margin_beyond_its_edges(self):
        along, right = self.at(self.road_map, 30.25, 53.75)

        self.assertAlmostEqual(along, 110.25, places=3)
        self.assertAlmostEqual(right, -3.75, places=3)
        self.assertTrue(np.isnan(self.at(self.road_map, 30.25, 55.25)[0]))

    def test_a_junction_belongs_to_the_road_of_higher_rank(self):
        along, _ = self.at(self.road_map, 50.25, 48.25)

        self.assertAlmostEqual(along, 130.25, places=3)

    def test_beyond_the_through_road_the_side_road_is_itself(self):
        along, right = self.at(self.road_map, 49.25, 40.25)

        self.assertAlmostEqual(along, 209.75, places=3)
        self.assertAlmostEqual(right, 0.75, places=3)

    def test_tells_how_far_inside_a_through_road_the_ground_is(self):
        inside = self.road_map.inside_roads(1)
        row = int((100.0 - 49.25) / surfaces.TRACK_MAP_M_PER_PX)

        self.assertAlmostEqual(float(inside[row, int(30.25 / surfaces.TRACK_MAP_M_PER_PX)]), 2.25)
        self.assertEqual(float(inside[int((100.0 - 30.25) / 0.5), int(50.25 / 0.5)]), 0.0)
        self.assertEqual(float(inside[row, int(10.25 / surfaces.TRACK_MAP_M_PER_PX)]), 0.0)

    def test_a_road_ends_in_a_round_cap(self):
        along, right = self.at(self.road_map, 50.25, 18.25)

        self.assertAlmostEqual(along, 230.0, places=3)
        self.assertAlmostEqual(abs(right), float(np.hypot(0.25, 1.75)), places=3)
        self.assertTrue(np.isnan(self.at(self.road_map, 53.25, 17.25)[0]))


class FitOpenEdgeTest(unittest.TestCase):
    """The edge fitted along a road with two ends."""

    def test_the_edge_is_held_to_both_ends(self):
        raw = np.full(120, 3.0)
        raw[:10] = np.nan
        raw[-15:] = np.nan

        edge, gap = surfaces.fit_open_edge(raw, 1.0)

        np.testing.assert_allclose(edge, 3.0, atol=1e-6)
        self.assertTrue(gap[:10].all() and gap[-15:].all())
        self.assertFalse(gap[10:-15].any())

    def test_a_stray_reading_does_not_move_the_edge(self):
        raw = np.full(120, 3.0)
        raw[40:43] = 7.0

        edge, gap = surfaces.fit_open_edge(raw, 1.0)

        np.testing.assert_allclose(edge, 3.0, atol=1e-6)
        self.assertFalse(gap.any())

    def test_a_road_shorter_than_the_median_window_is_fitted(self):
        edge, _ = surfaces.fit_open_edge(np.full(12, 2.5), 1.0)

        np.testing.assert_allclose(edge, 2.5, atol=1e-6)

    def test_without_evidence_there_is_no_edge(self):
        edge, gap = surfaces.fit_open_edge(np.full(30, np.nan), 1.0)

        self.assertTrue(np.isnan(edge).all() and gap.all())


class ForestFloorTest(unittest.TestCase):
    """The ground under trees."""

    def test_a_crown_covers_the_ground_around_its_trunk(self):
        crowns = np.asarray(surfaces.crown_cover(Square, [(50.0, 50.0, 20.0)]))

        self.assertEqual(crowns[200, 200], 255)
        self.assertEqual(crowns[200, 200 + 16], 255)  # 4 m east, inside the 4.4 m crown
        self.assertEqual(crowns[200, 200 + 20], 0)

    def test_a_lone_tree_stands_on_what_surrounds_it(self):
        classes = surfaces.ground_classes
        labels = np.full((400, 400), classes.LAWN, np.uint8)
        labels[:, 200:] = classes.WORN_ASPHALT

        surfaces.lay_forest_floor(labels, surfaces.crown_cover(Square, [(50.0, 50.0, 20.0)]), 4.0)

        self.assertEqual(labels[200, 195], classes.LAWN)
        self.assertEqual(labels[200, 205], classes.WORN_ASPHALT)

    def test_under_a_closed_canopy_everything_is_forest_floor(self):
        classes = surfaces.ground_classes
        labels = np.full((400, 400), classes.LAWN, np.uint8)
        trees = [(east, north, 20.0) for east in range(20, 81, 5) for north in range(20, 81, 5)]

        surfaces.lay_forest_floor(labels, surfaces.crown_cover(Square, trees), 4.0)

        self.assertEqual(labels[200, 200], classes.FOREST_FLOOR)
        self.assertEqual(labels[20, 20], classes.LAWN)


class LoopHelpersTest(unittest.TestCase):
    """Helpers over closed loops of sections."""

    def test_first_run_finds_where_a_run_starts(self):
        flags = np.array([[0, 1, 0, 1, 1, 1], [0, 0, 0, 0, 1, 0]], bool)

        self.assertEqual(list(surfaces.first_run(flags, 2)), [3, -1])

    def test_keep_long_runs_drops_short_ones_across_the_loop_end(self):
        flags = np.array([1, 1, 0, 1, 0, 0, 0, 1, 1], bool)

        kept = surfaces.keep_long_runs(flags, 3)

        self.assertEqual(list(kept), [True, True, False, False, False, False, False, True, True])


if __name__ == "__main__":
    unittest.main()
