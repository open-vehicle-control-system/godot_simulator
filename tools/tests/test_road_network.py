# ruff: noqa: D102
"""Tests of the road network: chains of ways, centrelines and junctions."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import osm
import road_network


def way(highway, nodes, points, **tags):
    """Return a highway way through `points`."""
    return osm.Way({"highway": highway, **tags}, list(nodes), np.array(points, float))


class ChainTest(unittest.TestCase):
    """Ways joined into roads."""

    def test_two_ways_of_a_kind_meeting_end_to_end_are_one_road(self):
        roads = road_network.chain(
            [
                way("service", "ab", [(0, 0), (10, 0)]),
                way("service", "cb", [(20, 0), (10, 0)]),
            ]
        )

        self.assertEqual(len(roads), 1)
        self.assertEqual(roads[0].nodes, ["a", "b", "c"])
        np.testing.assert_allclose(roads[0].points, [(0, 0), (10, 0), (20, 0)])

    def test_ways_meeting_at_a_junction_stay_apart(self):
        roads = road_network.chain(
            [
                way("service", "ab", [(0, 0), (10, 0)]),
                way("service", "bc", [(10, 0), (20, 0)]),
                way("service", "bd", [(10, 0), (10, 10)]),
            ]
        )

        self.assertEqual(len(roads), 3)

    def test_ways_of_different_kinds_stay_apart(self):
        roads = road_network.chain(
            [
                way("service", "ab", [(0, 0), (10, 0)]),
                way("primary", "bc", [(10, 0), (20, 0)]),
            ]
        )

        self.assertEqual([road.highway for road in roads], ["service", "primary"])

    def test_what_the_ground_does_not_carry_is_left_out(self):
        cases = {
            "tunnel": "yes",
            "bridge": "viaduct",
            "service": "parking_aisle",
        }
        for key, value in cases.items():
            ways = [way("service", "ab", [(0, 0), (10, 0)], **{key: value})]

            self.assertEqual(road_network.chain(ways), [], key)

    def test_a_footway_is_not_a_road(self):
        self.assertEqual(road_network.chain([way("footway", "ab", [(0, 0), (10, 0)])]), [])


class CentrelineTest(unittest.TestCase):
    """Sections along a mapped polyline."""

    def test_sections_are_a_metre_apart_along_the_road(self):
        sections = road_network.centreline(np.array([(0.0, 0.0), (50.0, 0.0)]))

        np.testing.assert_allclose(np.diff(sections["s"]), 1.0, atol=1e-6)
        self.assertEqual(len(sections["s"]), 51)
        np.testing.assert_allclose(sections["tx"], 1.0, atol=1e-6)
        np.testing.assert_allclose(sections["ty"], 0.0, atol=1e-6)

    def test_a_corner_of_the_polyline_is_rounded(self):
        sections = road_network.centreline(np.array([(0.0, 0.0), (50.0, 0.0), (50.0, 50.0)]))

        turn = np.abs(np.diff(np.arctan2(sections["ty"], sections["tx"])))
        self.assertLess(turn.max(), np.radians(15.0))
        np.testing.assert_allclose([sections["x"][0], sections["y"][0]], [0.0, 0.0], atol=0.05)
        np.testing.assert_allclose([sections["x"][-1], sections["y"][-1]], [50.0, 50.0], atol=0.05)


class JunctionsTest(unittest.TestCase):
    """Where roads meet."""

    def setUp(self):
        self.roads = road_network.chain(
            [
                way("primary", "abc", [(0, 0), (20, 0), (40, 0)]),
                way("service", "bd", [(20, 0), (20, 30)]),
                way("service", "be", [(20, 0), (20, -30)]),
            ]
        )

    def test_a_road_joining_from_the_left_opens_the_left_side(self):
        self.assertIn((0, 1, 1, -1), road_network.junctions(self.roads))

    def test_a_road_joining_from_the_right_opens_the_right_side(self):
        self.assertIn((0, 1, 2, 1), road_network.junctions(self.roads))

    def test_a_road_ending_on_a_junction_is_not_through_it(self):
        through = {junction[0] for junction in road_network.junctions(self.roads)}

        self.assertEqual(through, {0})


if __name__ == "__main__":
    unittest.main()
