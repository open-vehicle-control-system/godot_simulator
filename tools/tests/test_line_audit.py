# ruff: noqa: D102
"""Tests of the audit of a pack's lines: reading the maps as the shader does, and defects."""

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import line_audit as audit
import road_markings
import road_network
import secondary_roads
import track_surfaces


class TwoTiles:
    """A stand-in for the mosaic: two orthophoto tiles side by side, 4 px/m."""

    west = 0.0
    north = 512.0
    px_per_m = 4.0
    rgb = np.zeros((2048, 4096, 3), np.uint8)
    tile_corners = [(0, 0), (512, 0)]

    @staticmethod
    def tile_origin_px(corner):
        return (0, round(corner[0] * 4.0))


def oblique_road_maps(directory):
    """Write the maps of a road heading north-east through (512, 256), across both tiles."""
    rows, columns = np.indices((1024, 2048))
    east, north = (columns + 0.5) * 0.5, 512.0 - (rows + 0.5) * 0.5
    along = ((east - 512.0) + (north - 256.0)) / np.sqrt(2.0) + 300.0
    right = ((east - 512.0) - (north - 256.0)) / np.sqrt(2.0)
    near = np.abs(right) < 15.0
    image = track_surfaces.road_map_image(
        np.where(near, along, np.nan).astype(np.float32),
        np.where(near, right, np.nan).astype(np.float32),
    )
    Image.fromarray(image[:, :1024], "RGBA").save(Path(directory) / "0_0.png")
    Image.fromarray(image[:, 1024:], "RGBA").save(Path(directory) / "512_0.png")


class MapMosaicTest(unittest.TestCase):
    """The road maps read where the terrain shader reads them."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as directory:
            oblique_road_maps(directory)
            cls.road_map = audit.MapMosaic(directory, TwoTiles)

    def test_decodes_what_the_builder_encodes(self):
        along = np.array([[10000.0, np.nan]], np.float32)
        right = np.array([[-2.5, np.nan]], np.float32)

        decoded = audit.decode_road_map(track_surfaces.road_map_image(along, right))

        self.assertEqual((float(decoded[0][0, 0]), float(decoded[1][0, 0])), (10000.0, -2.5))
        self.assertTrue(np.isnan(decoded[0][0, 1]) and np.isnan(decoded[1][0, 1]))

    def test_coordinates_are_blended_between_texels(self):
        along, right, _ = self.road_map.coordinates(np.array([400.1]), np.array([150.3]), None)

        self.assertAlmostEqual(float(along[0]), (-111.9 - 105.7) / np.sqrt(2.0) + 300.0, delta=0.1)
        self.assertAlmostEqual(float(right[0]), (-111.9 + 105.7) / np.sqrt(2.0), delta=0.01)

    def test_coordinates_carry_on_across_a_tile_border(self):
        north = np.linspace(250.0, 262.0, 200)
        for east in (511.9, 512.0 - 1e-6, 512.0, 512.1):
            _, right, _ = self.road_map.coordinates(np.full(200, east), north, None)

            wanted = ((east - 512.0) - (north - 256.0)) / np.sqrt(2.0)
            self.assertLess(float(np.abs(right - wanted).max()), 0.015, east)

    def test_ground_away_from_the_road_has_no_coordinates(self):
        along, right, _ = self.road_map.coordinates(np.array([400.0]), np.array([400.0]), None)

        self.assertTrue(np.isnan(along[0]) and np.isnan(right[0]))

    def test_no_marking_is_painted_where_two_roads_meet(self):
        road_map = audit.MapMosaic.__new__(audit.MapMosaic)
        road_map.west, road_map.north = 0.0, 512.0
        road_map.along = np.full((1024, 1024), 100.0)
        road_map.along[:, 500:] = 900.0
        road_map.right = np.zeros((1024, 1024))

        along, right = road_map.marking_coordinates(
            np.array([249.9, 250.1, 248.0]), np.array([100.0, 100.0, 100.0])
        )

        self.assertTrue(np.isnan(right[:2]).all() and np.isnan(along[:2]).all())
        self.assertEqual((float(along[2]), float(right[2])), (100.0, 0.0))

    def test_the_centreline_is_recovered_from_the_map(self):
        centre, normal, heading = audit.centrelines(self.road_map, 290, 20, 10.0)

        wanted = np.array([512.0, 256.0]) + (np.arange(290, 310) - 300.0)[:, None] / np.sqrt(2.0)
        self.assertLess(float(np.abs(centre - wanted).max()), 0.02)
        np.testing.assert_allclose(normal, np.tile([1.0, -1.0], (20, 1)) / np.sqrt(2.0), atol=0.01)
        np.testing.assert_allclose(heading, np.tile([1.0, 1.0], (20, 1)) / np.sqrt(2.0), atol=0.01)


class LapPaintTest(unittest.TestCase):
    """Where the shader paints the lap's lines, from the road lines image."""

    def setUp(self):
        s = np.arange(0.0, 100.0, 1.0)
        edges = [np.full(100, 5.0), np.full(100, 6.0)]
        gaps = [np.zeros(100, bool), s >= 60.0]
        self.lines = track_surfaces.lines_image(
            s, 100.0, edges, gaps, [[(30.0, 39.0, 1.0)], []], np.zeros(100), np.zeros(100)
        )

    def paint(self, along, right):
        line, kerb = audit.lap_paint(self.lines, np.array([along]), np.array([right]))
        return bool(line[0]), bool(kerb[0])

    def test_the_line_is_its_inset_inside_the_edge(self):
        outer = 5.0 - track_surfaces.LINE_INSET_M

        self.assertEqual(self.paint(10.0, -(outer - 0.05)), (True, False))
        self.assertEqual(self.paint(10.0, -(outer + 0.02)), (False, False))
        self.assertEqual(self.paint(10.0, -(outer - 0.2)), (False, False))

    def test_a_gap_is_not_painted(self):
        self.assertEqual(self.paint(80.0, 6.0 - track_surfaces.LINE_INSET_M - 0.05), (False, False))

    def test_a_kerb_lies_beyond_the_edge(self):
        self.assertEqual(self.paint(34.0, -5.5), (False, True))
        self.assertEqual(self.paint(34.0, 6.5), (False, False))

    def test_the_line_is_meant_at_its_middle(self):
        (left_m, left_painted), (right_m, right_painted) = audit.lap_line_offsets(
            self.lines, np.array([10, 80])
        )

        middle = track_surfaces.LINE_INSET_M + audit.LINE_WIDTH_M / 2.0
        np.testing.assert_allclose(left_m, 5.0 - middle)
        np.testing.assert_allclose(right_m, 6.0 - middle)
        self.assertEqual(list(right_painted), [True, False])


class RoadPaintTest(unittest.TestCase):
    """Where the shader paints the roads' lines, from the roads' lines image."""

    def setUp(self):
        sections = road_network.sections_along(
            np.stack([np.arange(61, dtype=float), np.zeros(61)], 1)
        )
        line = road_markings.Line(np.full(61, -1.0), np.zeros(61, np.uint8))
        line.pattern[10:20] = road_markings.SOLID
        road = secondary_roads.SurveyedRoad(
            road_network.KINDS["service"],
            {},
            sections,
            np.full(61, 2.5),
            [np.zeros(61, bool)] * 2,
            np.full((61, secondary_roads.COLOUR_BINS, 3), 0.2),
            6,
            [line],
            [road_markings.Transverse(road_markings.CROSSING, 30.0, 33.0, -2.0, 2.5)],
        )
        self.lines = secondary_roads.lines_image([road], [8], 1)

    def test_finds_the_roads_laid_in_the_image(self):
        self.assertEqual(audit.road_spans(self.lines), [(8, 61)])

    def test_a_line_is_painted_where_its_pattern_says(self):
        along = np.array([8 + 15.0, 8 + 15.0, 8 + 40.0])
        right = np.array([-1.02, -1.3, -1.0])

        self.assertEqual(list(audit.road_paint(self.lines, along, right)), [True, False, False])

    def test_a_dashed_line_is_painted_dash_by_dash(self):
        self.lines[2, 8 + 10 : 8 + 20, 2] = 1
        along = np.array([8 + 12.5, 8 + 18.0])
        right = np.array([-1.0, -1.0])

        painted = audit.road_paint(self.lines, along, right, [(2.5, 10.0)])

        self.assertEqual(list(painted), [False, True])

    def test_a_crossing_lies_between_its_ends(self):
        along = np.array([8 + 31.2, 8 + 31.2, 8 + 35.0])
        right = np.array([1.0, -2.3, 1.0])

        _, crossing = audit.road_extent(self.lines, along, right)

        self.assertEqual(list(crossing), [True, False, False])


class PhotoPaintTest(unittest.TestCase):
    """What the audit reads as a line in the photo."""

    def setUp(self):
        self.laterals = np.arange(-8.0, 8.0, 0.125)
        self.luminance = np.full((3, len(self.laterals)), 0.4)

    def test_a_line_against_lighter_ground_is_the_laps_line_on_either_side(self):
        self.luminance[:, np.abs(self.laterals) >= 5.0] = 0.7

        paint = audit.photo_paint(self.luminance, self.laterals)

        np.testing.assert_allclose(self.laterals[paint[0]], [-5.125, -5.0, 5.0, 5.125], atol=1e-9)

    def test_on_a_road_a_lighter_lane_is_not_a_line_and_a_thin_strip_is(self):
        self.luminance[:, self.laterals >= 3.0] = 0.7
        self.luminance[:, 20:22] = 0.6

        paint = audit.road_photo_paint(self.luminance, self.laterals)

        self.assertEqual(list(np.flatnonzero(paint[0])), [20, 21])


def survey(drawn_m, shown_m, painted=None, verge_m=None):
    """Return the LineSurvey of a straight line heading east, drawn and shown as given."""
    count = len(drawn_m)
    drawn_m, shown_m = np.asarray(drawn_m, float), np.asarray(shown_m, float)
    points = np.stack([np.arange(count, dtype=float), -drawn_m], 1)
    return audit.LineSurvey(
        "line",
        0,
        np.full(count, 5.0),
        ~np.isnan(drawn_m) if painted is None else painted,
        ~np.isnan(drawn_m),
        drawn_m,
        shown_m,
        np.full(count, np.nan) if verge_m is None else verge_m,
        points,
    )


def kinds(defects):
    """Return the kind of each defect."""
    return [defect["kind"] for defect in defects]


class LineDefectsTest(unittest.TestCase):
    """What the audit calls a defect."""

    def test_a_line_on_the_photos_line_has_no_defect(self):
        self.assertEqual(audit.line_defects(survey(np.full(60, 5.0), np.full(60, 5.05)), False), [])

    def test_a_break_where_the_photo_shows_the_line_is_a_gap(self):
        drawn = np.full(60, 5.0)
        drawn[20:30] = np.nan

        defects = audit.line_defects(survey(drawn, np.full(60, 5.0)), False)

        self.assertEqual(kinds(defects), ["gap over the photo's line"])
        self.assertEqual((defects[0]["from_m"], defects[0]["to_m"]), (20, 30))

    def test_a_break_where_the_photo_shows_no_line_is_deliberate(self):
        drawn, shown = np.full(60, 5.0), np.full(60, 5.0)
        drawn[20:30] = shown[20:30] = np.nan

        self.assertEqual(audit.line_defects(survey(drawn, shown), False), [])

    def test_a_line_beside_the_photos_is_misplaced(self):
        shown = np.full(60, 5.0)
        shown[20:40] = 5.6

        defects = audit.line_defects(survey(np.full(60, 5.0), shown), False)

        self.assertEqual(kinds(defects), ["off the photo's line"])
        self.assertAlmostEqual(defects[0]["worst_m"], 0.6)

    def test_a_sideways_step_is_a_defect_and_a_bend_is_not(self):
        stepped = np.full(60, 5.0)
        stepped[30:] = 5.1
        bend = 5.0 + 0.002 * np.arange(60) ** 2

        self.assertIn("sideways step", kinds(audit.line_defects(survey(stepped, stepped), False)))
        self.assertEqual(audit.line_defects(survey(bend, bend), False), [])

    def test_a_line_on_the_verge_is_a_defect(self):
        verge = np.full(60, 5.5)
        verge[20:30] = 4.5

        defects = audit.line_defects(
            survey(np.full(60, 5.0), np.full(60, 5.0), verge_m=verge), False
        )

        self.assertEqual(kinds(defects), ["on the verge"])


class CrossingProblemsTest(unittest.TestCase):
    """What the audit calls a malformed or repeated crossing."""

    def crossing(self, **changed):
        return {
            "length_m": 4,
            "stripes": 6,
            "drawn_share": 1.0,
            "paved_share": 1.0,
            "source": "osm node",
            "_at": np.array([0.0, 0.0]),
        } | changed

    def test_a_crossing_of_the_map_on_its_road_is_sound(self):
        self.assertEqual(audit.crossing_problems(self.crossing(), []), [])

    def test_two_crossings_at_one_place_are_duplicates(self):
        other = self.crossing(_at=np.array([5.0, 3.0]))

        self.assertEqual(
            audit.crossing_problems(self.crossing(), [other]), ["duplicate of 1 within 12 m"]
        )

    def test_a_crossing_nothing_supports_is_a_problem(self):
        problems = audit.crossing_problems(
            self.crossing(source="unsupported", paved_share=0.2, drawn_share=0.4, length_m=9), []
        )

        self.assertEqual(
            problems,
            [
                "length",
                "clipped or under another road",
                "not on paved ground",
                "no map node and no paint in the photo",
            ],
        )


if __name__ == "__main__":
    unittest.main()
