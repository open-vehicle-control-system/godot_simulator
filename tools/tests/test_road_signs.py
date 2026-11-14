# ruff: noqa: D102
"""Tests of the sign builder: what is tagged, what is implied, and where a sign stands."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import osm
import road_markings
import road_network
import road_signs
import secondary_roads
import sign_faces

FLAT = road_signs.Site(lambda x, y: False, lambda x, y: False)


def way(highway, nodes, points, **tags):
    """Return a highway way through `points`."""
    return osm.Way({"highway": highway, **tags}, list(nodes), np.array(points, float))


def node(identifier, point, **tags):
    """Return a tagged node."""
    return osm.Node(identifier, tags, np.array(point, float))


def surveyed(points, half_width_m=3.0, highway="tertiary", transverse=(), **tags):
    """Return a surveyed road along `points`, sampled every metre."""
    sections = road_network.centreline(np.array(points, float))
    count = len(sections["s"])
    return secondary_roads.SurveyedRoad(
        road_network.KINDS[highway],
        {"highway": highway, **tags},
        sections,
        np.full(count, half_width_m),
        [np.zeros(count, bool)] * 2,
        np.full((count, secondary_roads.COLOUR_BINS, 3), 0.2),
        6,
        [],
        list(transverse),
    )


def east_road(**arguments):
    """Return a road running east along y = 0 from x = 0 to x = 100."""
    return surveyed([(0, 0), (100, 0)], **arguments)


def map_position(placed):
    """Return the (east, north) of something placed."""
    return placed["at"]


def map_facing(plate):
    """Return the unit (east, north) vector a plate's front looks along."""
    angle = np.radians(plate["yaw_deg"] - 90.0)
    return np.array([np.cos(angle), np.sin(angle)])


class TaggedTest(unittest.TestCase):
    """Signs and signals OpenStreetMap tags on nodes."""

    def extract(self, tagged, **way_tags):
        return osm.Extract(
            nodes=[tagged], ways=[way("tertiary", "abc", [(0, 0), (40, 0), (100, 0)], **way_tags)]
        )

    def test_a_forward_give_way_governs_the_traffic_along_the_way(self):
        tagged = node("b", (40, 0), highway="give_way", direction="forward")

        wanted = road_signs.tagged_signs(self.extract(tagged))

        self.assertEqual([sign.faces for sign in wanted], [("BE:B1",)])
        np.testing.assert_allclose(wanted[0].travel, [1.0, 0.0])
        self.assertEqual(wanted[0].source, road_signs.TAGGED)

    def test_a_backward_stop_governs_the_traffic_against_the_way(self):
        tagged = node("b", (40, 0), highway="stop", direction="backward")

        wanted = road_signs.tagged_signs(self.extract(tagged))

        self.assertEqual(wanted[0].faces, ("BE:B5",))
        np.testing.assert_allclose(wanted[0].travel, [-1.0, 0.0])

    def test_a_stop_without_direction_governs_the_traffic_to_the_nearer_end(self):
        tagged = node("b", (40, 0), highway="stop")
        extract = osm.Extract(
            nodes=[tagged], ways=[way("tertiary", "abcd", [(0, 0), (40, 0), (50, 0), (60, 0)])]
        )

        np.testing.assert_allclose(road_signs.tagged_signs(extract)[0].travel, [-1.0, 0.0])

    def test_a_stop_without_direction_on_a_one_way_follows_it(self):
        tagged = node("b", (40, 0), highway="stop")

        wanted = road_signs.tagged_signs(self.extract(tagged, oneway="yes"))

        np.testing.assert_allclose(wanted[0].travel, [1.0, 0.0])

    def test_a_zebra_crossing_is_signed_for_both_ways(self):
        tagged = node("b", (40, 0), highway="crossing", **{"crossing:markings": "zebra"})

        wanted = road_signs.tagged_signs(self.extract(tagged))

        self.assertEqual([sign.faces for sign in wanted], [("BE:F49",)] * 2)
        self.assertEqual(sorted(sign.travel[0] for sign in wanted), [-1.0, 1.0])

    def test_an_unmarked_crossing_gets_no_sign(self):
        tagged = node("b", (40, 0), highway="crossing", crossing="unmarked")

        self.assertEqual(road_signs.tagged_signs(self.extract(tagged)), [])

    def test_a_traffic_sign_names_its_faces(self):
        tagged = node("b", (40, 0), traffic_sign="BE:C43[50];B9", direction="forward")

        wanted = road_signs.tagged_signs(self.extract(tagged))

        self.assertEqual(wanted[0].faces, ("BE:C43[50]", "BE:B9"))

    def test_a_sign_no_face_is_drawn_for_is_reported_not_placed(self):
        tagged = node("b", (40, 0), traffic_sign="BE:F1", direction="forward")

        placement = road_signs.place(self.extract(tagged), [east_road()], FLAT)

        self.assertEqual(placement.plates, [])
        self.assertEqual(placement.unplaced, [("no face is drawn for it", "BE:F1")])

    def test_signals_at_a_junction_stand_on_every_approach(self):
        extract = osm.Extract(
            nodes=[node("x", (50, 0), highway="traffic_signals")],
            ways=[
                way("tertiary", "axb", [(0, 0), (50, 0), (100, 0)]),
                way("tertiary", "cxd", [(50, -50), (50, 0), (50, 50)]),
            ],
        )

        wanted = road_signs.tagged_signs(extract)

        travels = sorted(tuple(np.round(sign.travel).astype(int)) for sign in wanted)
        self.assertEqual(travels, [(-1, 0), (0, -1), (0, 1), (1, 0)])
        phases = {tuple(np.round(np.abs(sign.travel)).astype(int)): sign.phase for sign in wanted}
        self.assertEqual(phases, {(1, 0): 0.0, (0, 1): 0.5})

    def test_a_node_on_no_drawn_road_is_reported(self):
        extract = osm.Extract(nodes=[node("z", (40, 30), highway="stop")], ways=[])

        placement = road_signs.place(extract, [east_road()], FLAT)

        self.assertEqual(placement.posts, [])
        self.assertEqual(placement.unplaced[0][0], "on no mapped road")


class SpeedLimitTest(unittest.TestCase):
    """Speed limit signs where maxspeed changes."""

    def test_each_limit_is_signed_where_traffic_enters_it(self):
        extract = osm.Extract(
            ways=[
                way("tertiary", "ab", [(0, 0), (100, 0)], maxspeed="90"),
                way("tertiary", "bc", [(100, 0), (200, 0)], maxspeed="50"),
            ]
        )

        wanted = road_signs.speed_limit_signs(extract)

        entering = {sign.faces[0]: (tuple(sign.point), tuple(sign.travel)) for sign in wanted}
        self.assertEqual(
            entering,
            {
                "BE:C43[50]": ((105.0, 0.0), (1.0, 0.0)),
                "BE:C43[90]": ((95.0, 0.0), (-1.0, 0.0)),
            },
        )
        self.assertEqual([sign.sides for sign in wanted], [(road_signs.RIGHT,)] * 2)
        self.assertEqual(wanted[0].source, road_signs.DERIVED)

    def test_a_limit_is_repeated_on_the_left_of_a_one_way_only(self):
        extract = osm.Extract(
            ways=[
                way("tertiary", "ab", [(0, 0), (100, 0)], maxspeed="90"),
                way("tertiary", "bc", [(100, 0), (200, 0)], maxspeed="50", oneway="yes"),
            ]
        )

        wanted = road_signs.speed_limit_signs(extract)

        self.assertEqual([sign.faces for sign in wanted], [("BE:C43[50]",)])
        self.assertEqual(wanted[0].sides, (road_signs.RIGHT, road_signs.LEFT))

    def test_a_way_without_a_limit_implies_no_sign(self):
        extract = osm.Extract(
            ways=[
                way("tertiary", "ab", [(0, 0), (100, 0)], maxspeed="90"),
                way("tertiary", "bc", [(100, 0), (200, 0)]),
            ]
        )

        self.assertEqual(road_signs.speed_limit_signs(extract), [])

    def test_a_limit_that_carries_on_is_not_signed(self):
        extract = osm.Extract(
            ways=[
                way("tertiary", "ab", [(0, 0), (100, 0)], maxspeed="70"),
                way("tertiary", "bc", [(100, 0), (200, 0)], maxspeed="70"),
            ]
        )

        self.assertEqual(road_signs.speed_limit_signs(extract), [])

    def test_a_one_way_is_signed_only_where_it_is_entered(self):
        extract = osm.Extract(
            ways=[
                way("tertiary", "ab", [(0, 0), (100, 0)], maxspeed="90"),
                way("tertiary", "bc", [(100, 0), (200, 0)], maxspeed="50", oneway="-1"),
            ]
        )

        wanted = road_signs.speed_limit_signs(extract)

        self.assertEqual([sign.faces for sign in wanted], [("BE:C43[90]",)])

    def test_a_side_road_with_another_limit_is_signed_at_its_mouth(self):
        extract = osm.Extract(
            ways=[
                way("primary", "abc", [(0, 0), (100, 0), (200, 0)], maxspeed="90"),
                way("residential", "bd", [(100, 0), (100, 80)], maxspeed="30"),
            ]
        )

        wanted = road_signs.speed_limit_signs(extract)

        self.assertEqual([sign.faces for sign in wanted], [("BE:C43[30]",)])
        np.testing.assert_allclose(wanted[0].travel, [0.0, 1.0])


class ImpliedTest(unittest.TestCase):
    """Signs the roads' markings and roundabouts imply."""

    def crossing_road(self, transverse, **arguments):
        through = surveyed([(100, -50), (100, 50)], highway="secondary")
        return [east_road(transverse=transverse, **arguments), through]

    def test_a_lane_stop_line_before_a_junction_implies_a_stop_sign(self):
        line = road_markings.Transverse(road_markings.STOP_LINE, 94.0, 94.5, 0.2, 2.7)

        wanted = road_signs.marking_signs(self.crossing_road([line]))

        self.assertEqual([sign.faces for sign in wanted], [("BE:B5",)])
        np.testing.assert_allclose(wanted[0].travel, [1.0, 0.0], atol=1e-6)
        np.testing.assert_allclose(wanted[0].point, [94.0, 0.0], atol=1e-6)

    def test_a_line_over_the_left_lane_stops_the_traffic_against_the_road(self):
        line = road_markings.Transverse(road_markings.STOP_LINE, 6.0, 6.5, -2.7, -0.2)
        roads = [east_road(transverse=[line]), surveyed([(0, -50), (0, 50)], highway="secondary")]

        wanted = road_signs.marking_signs(roads)

        np.testing.assert_allclose(wanted[0].travel, [-1.0, 0.0], atol=1e-6)

    def test_a_bar_that_is_no_lane_implies_nothing(self):
        bar = road_markings.Transverse(road_markings.STOP_LINE, 94.0, 94.5, 1.6, 2.9)

        self.assertEqual(road_signs.marking_signs(self.crossing_road([bar])), [])

    def test_a_stop_line_before_a_minor_road_implies_nothing(self):
        line = road_markings.Transverse(road_markings.STOP_LINE, 94.0, 94.5, 0.2, 2.7)
        roads = [east_road(transverse=[line]), surveyed([(100, -50), (100, 50)], highway="service")]

        self.assertEqual(road_signs.marking_signs(roads), [])

    def test_a_service_road_implies_nothing(self):
        line = road_markings.Transverse(road_markings.STOP_LINE, 94.0, 94.5, 0.2, 2.7)

        wanted = road_signs.marking_signs(self.crossing_road([line], highway="service"))

        self.assertEqual(wanted, [])

    def test_a_zebra_crossing_implies_a_sign_each_way_at_its_near_edge(self):
        zebra = road_markings.Transverse(road_markings.CROSSING, 40.0, 44.0, -3.0, 3.0)

        wanted = road_signs.marking_signs([east_road(transverse=[zebra])])

        self.assertEqual([sign.faces for sign in wanted], [("BE:F49",)] * 2)
        near_edges = {round(float(sign.travel[0])): round(float(sign.point[0])) for sign in wanted}
        self.assertEqual(near_edges, {1: 40, -1: 44})

    def test_stripes_close_together_are_one_crossing(self):
        stripes = [
            road_markings.Transverse(road_markings.CROSSING, 40.0, 43.0, -3.0, 0.0),
            road_markings.Transverse(road_markings.CROSSING, 45.0, 48.0, 0.0, 3.0),
        ]

        self.assertEqual(road_signs.crossings(east_road(transverse=stripes)), [(40.0, 48.0)])

    def test_every_way_into_a_roundabout_gives_way(self):
        ring = [(10, 0), (0, 10), (-10, 0), (0, -10), (10, 0)]
        extract = osm.Extract(
            ways=[
                way("tertiary", "nwsen", ring, junction="roundabout"),
                way("tertiary", "ea", [(10, 0), (80, 0)]),
                way("tertiary", "bw", [(-80, 0), (-10, 0)], oneway="-1"),
            ]
        )

        wanted = road_signs.roundabout_signs(extract)

        self.assertEqual([sign.faces for sign in wanted], [("BE:B1", "BE:D5")])
        np.testing.assert_allclose(wanted[0].travel, [-1.0, 0.0])
        np.testing.assert_allclose(wanted[0].point, [14.5, 0.0])

    def test_a_tagged_sign_replaces_the_one_implied_there(self):
        tagged = road_signs.Wanted(
            ("BE:B1",), np.array([94.0, 0.0]), np.array([1.0, 0.0]), "tagged", "priority"
        )
        implied = road_signs.Wanted(
            ("BE:B5",), np.array([90.0, 0.0]), np.array([1.0, 0.0]), "derived", "priority"
        )
        opposite = road_signs.Wanted(
            ("BE:B5",), np.array([90.0, 0.0]), np.array([-1.0, 0.0]), "derived", "priority"
        )

        kept = road_signs.without_repeats([implied, opposite, tagged])

        self.assertEqual([sign.faces for sign in kept], [("BE:B1",), ("BE:B5",)])
        self.assertEqual(kept[1].travel[0], -1.0)


class PlacementTest(unittest.TestCase):
    """Where a sign stands and what it faces."""

    def placed(self, tagged, roads=None, site=FLAT, **way_tags):
        extract = osm.Extract(
            nodes=[tagged], ways=[way("tertiary", "abc", [(0, 0), (40, 0), (100, 0)], **way_tags)]
        )
        return road_signs.place(extract, roads or [east_road()], site)

    def test_a_sign_stands_right_of_the_traffic_it_governs(self):
        forward = self.placed(node("b", (40, 0), highway="stop", direction="forward"))
        backward = self.placed(node("b", (40, 0), highway="stop", direction="backward"))

        # Half the road, the clearance and half the 0.9 m plate from the centreline.
        np.testing.assert_allclose(map_position(forward.posts[0]), [40.0, -3.95], atol=0.02)
        np.testing.assert_allclose(map_position(backward.posts[0]), [40.0, 3.95], atol=0.02)

    def test_a_plate_faces_the_traffic_it_governs_turned_off_the_road(self):
        placement = self.placed(node("b", (40, 0), highway="give_way", direction="forward"))

        facing = map_facing(placement.plates[0])

        self.assertAlmostEqual(facing[0], -np.cos(np.radians(road_signs.SKEW_DEG)), places=3)
        self.assertLess(facing[1], 0.0)

    def test_a_plate_hangs_before_its_post_with_its_lower_edge_at_the_verge_height(self):
        placement = self.placed(node("b", (40, 0), highway="stop", direction="forward"))

        plate, post = placement.plates[0], placement.posts[0]

        low_m = float(sign_faces.outline("BE:B5")[:, 1].min())
        self.assertAlmostEqual(plate["above_m"] + low_m, road_signs.LOWER_EDGE_M, places=2)
        self.assertLess(map_position(plate)[0], map_position(post)[0])
        self.assertGreater(post["height_m"], plate["above_m"] - low_m)

    def test_a_sign_is_described_in_the_pack_frame_on_the_ground_at_its_foot(self):
        placement = self.placed(node("b", (40, 0), highway="stop", direction="forward"))

        described = road_signs.described(placement, lambda x, y: 12.5 if y < -3.9 else 0.0)

        # The pack's x is south, its y east.
        self.assertEqual(described["posts"][0]["position_m"], [3.95, 40.0, 12.5])
        self.assertEqual(described["posts"][0]["diameter_m"], road_signs.POST_DIAMETER_M)
        plate = described["plates"][0]
        self.assertEqual(plate["position_m"][2], 12.5 + placement.plates[0]["above_m"])
        self.assertEqual((plate["face"], plate["source"]), ("BE:B5", "tagged"))
        self.assertEqual(sorted(plate), ["face", "position_m", "source", "yaw_deg"])

    def test_a_plate_is_higher_where_people_walk(self):
        tagged = node("b", (40, 0), highway="stop", direction="forward")
        paved = road_signs.Site(lambda x, y: False, lambda x, y: True)

        beside_a_footway = self.placed(tagged, [east_road(sidewalk="both")])
        on_paved_ground = self.placed(tagged, site=paved)
        in_town = self.placed(tagged, [east_road(maxspeed="50")])

        for placement in (beside_a_footway, on_paved_ground, in_town):
            low_m = float(sign_faces.outline("BE:B5")[:, 1].min())
            lower_edge_m = placement.plates[0]["above_m"] + low_m
            self.assertAlmostEqual(lower_edge_m, road_signs.LOWER_EDGE_WALKED_M, places=2)

    def test_plates_take_the_size_of_their_road(self):
        tagged = node("b", (40, 0), traffic_sign="BE:B1;BE:C43[30];BE:B5", direction="forward")

        rural = self.placed(tagged)
        in_town = self.placed(tagged, [east_road(maxspeed="50")])

        def widths(placement):
            faces = [sign_faces.face(plate["face"]) for plate in placement.plates]
            return [round(float(np.ptp(face.outline_m[:, 0])), 1) for face in faces]

        # A triangle's side, a disc's diameter and an octagon's width.
        self.assertEqual(widths(rural), [0.8, 0.7, 0.9])
        self.assertEqual(widths(in_town), [0.6, 0.6, 0.9])
        self.assertEqual(
            [plate["face"] for plate in in_town.plates],
            ["BE:B1@built-up", "BE:C43[30]@built-up", "BE:B5"],
        )

    def test_a_sign_moves_back_off_the_road_that_joins(self):
        joining = surveyed([(40, -50), (40, 0)], half_width_m=3.0, highway="service")
        tagged = node("b", (40, 0), highway="give_way", direction="forward")

        placement = self.placed(tagged, [east_road(), joining])

        position = map_position(placement.posts[0])
        self.assertLess(position[0], 40.0 - 3.0 - road_signs.KEEP_OFF_M)
        self.assertGreater(position[0], 40.0 - road_signs.BACK_OFF_M - 0.01)

    def test_a_sign_without_free_ground_is_reported(self):
        tagged = node("b", (40, 0), highway="give_way", direction="forward")
        built = road_signs.Site(lambda x, y: True, lambda x, y: False)

        placement = self.placed(tagged, site=built)

        self.assertEqual(placement.posts, [])
        self.assertEqual(placement.unplaced[0][0], "no free ground beside the road")

    def test_a_one_way_speed_limit_stands_on_both_sides_facing_those_who_enter(self):
        extract = osm.Extract(
            ways=[
                way("tertiary", "ab", [(-100, 0), (0, 0)], maxspeed="90"),
                way("tertiary", "bc", [(0, 0), (100, 0)], maxspeed="50", oneway="yes"),
            ]
        )

        placement = road_signs.place(extract, [east_road(maxspeed="50")], FLAT)

        faces = [plate["face"] for plate in placement.plates]
        self.assertEqual(faces, ["BE:C43[50]@built-up"] * 2)
        norths = sorted(map_position(post)[1] for post in placement.posts)
        # Half the road, the clearance and half a built-up area's 0.6 m disc.
        np.testing.assert_allclose(norths, [-3.8, 3.8], atol=0.02)
        for plate in placement.plates:
            self.assertLess(map_facing(plate)[0], -0.99)
        self.assertEqual(placement.counts()["derived"], {"BE:C43[50]@built-up": 2})

    def test_faces_stack_on_one_post_the_first_on_top(self):
        tagged = node("b", (40, 0), traffic_sign="BE:B1;BE:D5", direction="forward")

        placement = self.placed(tagged)

        self.assertEqual(len(placement.posts), 1)
        self.assertEqual([plate["face"] for plate in placement.plates], ["BE:B1", "BE:D5"])
        self.assertGreater(placement.plates[0]["above_m"], placement.plates[1]["above_m"] + 0.6)

    def test_a_sign_mapped_beside_the_road_governs_the_traffic_it_is_right_of(self):
        extract = osm.Extract(nodes=[node("s", (40, 6), traffic_sign="BE:C43[70]")], ways=[])

        placement = road_signs.place(extract, [east_road()], FLAT)

        np.testing.assert_allclose(map_position(placement.posts[0]), [40.0, 3.85], atol=0.02)
        self.assertGreater(map_facing(placement.plates[0])[0], 0.99)


class MarkingsTest(unittest.TestCase):
    """Markings made to agree with the signs."""

    def place(self, tagged, transverse=()):
        road = east_road(transverse=transverse)
        extract = osm.Extract(
            nodes=[tagged], ways=[way("tertiary", "abc", [(0, 0), (40, 0), (100, 0)])]
        )
        return road_signs.place(extract, [road], FLAT), road

    def test_a_tagged_stop_gets_a_stop_line_across_its_lane(self):
        _, road = self.place(node("b", (40, 0), highway="stop", direction="forward"))

        line = road.transverse[0]
        self.assertEqual(line.kind, road_markings.STOP_LINE)
        self.assertAlmostEqual(line.from_m, 40.0)
        self.assertEqual(line.left_m, 0.0)
        self.assertAlmostEqual(line.right_m, 3.0 - road_signs.EDGE_LINE_INSET_M)

    def test_a_tagged_stop_stands_at_the_stop_line_drawn_nearby(self):
        drawn = road_markings.Transverse(road_markings.STOP_LINE, 46.0, 46.5, 0.1, 2.8)

        placement, road = self.place(
            node("b", (40, 0), highway="stop", direction="forward"), [drawn]
        )

        self.assertEqual(len(road.transverse), 1)
        self.assertAlmostEqual(map_position(placement.posts[0])[0], 46.0, places=1)

    def test_a_give_way_turns_the_stop_line_drawn_there_into_a_give_way_line(self):
        drawn = road_markings.Transverse(road_markings.STOP_LINE, 42.0, 42.5, 0.1, 2.8)

        _, road = self.place(node("b", (40, 0), highway="give_way", direction="forward"), [drawn])

        self.assertEqual(road.transverse[0].kind, road_markings.GIVE_WAY_LINE)

    def test_a_tagged_zebra_crossing_is_drawn_where_the_photo_showed_none(self):
        zebra = node("b", (40, 0), highway="crossing", crossing="zebra")

        placement, road = self.place(zebra)

        self.assertEqual(road.transverse[0].kind, road_markings.CROSSING)
        self.assertAlmostEqual(road.transverse[0].from_m, 38.0)
        self.assertAlmostEqual(road.transverse[0].to_m, 42.0)
        easts = sorted(round(map_position(post)[0]) for post in placement.posts)
        self.assertEqual(easts, [38, 42])

    def test_a_signal_stands_at_a_stop_line_before_the_road_it_guards(self):
        extract = osm.Extract(
            nodes=[node("x", (50, 0), highway="traffic_signals")],
            ways=[
                way("tertiary", "axb", [(0, 0), (50, 0), (100, 0)]),
                way("tertiary", "cxd", [(50, -50), (50, 0), (50, 50)]),
            ],
        )
        roads = [east_road(), surveyed([(50, -50), (50, 50)], half_width_m=4.0)]

        placement = road_signs.place(extract, roads, FLAT)

        self.assertEqual(len(placement.signals), 4)
        eastbound = next(signal for signal in placement.signals if map_facing(signal)[0] < -0.99)
        self.assertAlmostEqual(map_position(eastbound)[0], 50.0 - 4.0 - 2.0, delta=0.3)
        self.assertLess(map_position(eastbound)[1], -3.0)
        kinds = [mark.kind for mark in roads[0].transverse]
        self.assertEqual(kinds, [road_markings.STOP_LINE] * 2)
        self.assertEqual(placement.counts()["tagged"], {"signal": 4})


if __name__ == "__main__":
    unittest.main()
