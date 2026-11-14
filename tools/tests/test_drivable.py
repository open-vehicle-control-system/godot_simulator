# ruff: noqa: D102
"""Tests of the drivable ground: what stands on a road, a lot or their margin."""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import drivable
import pack_experiment
import road_network


def road_east(length_m=100):
    """Return the sections of a road running east along y = 0."""
    return road_network.sections_along(
        np.stack([np.arange(length_m + 1, dtype=float), np.zeros(length_m + 1)], 1)
    )


class StripTest(unittest.TestCase):
    """Trees against a road."""

    def setUp(self):
        self.ground = drivable.Drivable()
        self.ground.add_strip(road_east(), 3.0, 4.0)

    def test_a_tree_on_the_road_is_on_drivable_ground(self):
        trees = np.array([(50.0, 0.0), (20.3, -3.9), (70.0, 2.9)])

        self.assertEqual(self.ground.covers(trees[:, 0], trees[:, 1]).tolist(), [True] * 3)

    def test_a_tree_just_beyond_the_edge_is_within_the_margin(self):
        covered = self.ground.covers([50.0, 50.0], [-4.4, 3.4])

        self.assertEqual(covered.tolist(), [True, True])

    def test_a_tree_beside_the_road_stands(self):
        # The road reaches 3 m to its left (north) and 4 m to its right (south).
        covered = self.ground.covers([50.0, 50.0, 50.0], [-4.6, 3.6, 30.0])

        self.assertEqual(covered.tolist(), [False, False, False])

    def test_a_tree_past_the_end_of_the_road_stands(self):
        self.assertEqual(self.ground.covers([102.0, -2.0], [0.0, 0.0]).tolist(), [False, False])

    def test_edges_follow_the_road_section_by_section(self):
        ground = drivable.Drivable()
        ground.add_strip(road_east(), 3.0, np.linspace(2.0, 8.0, 101))

        self.assertEqual(ground.covers([10.0, 90.0], [-6.0, -6.0]).tolist(), [False, True])

    def test_a_road_that_turns_is_followed(self):
        quarter = np.radians(np.linspace(0.0, 90.0, 80))
        bend = np.stack([50.0 * np.sin(quarter), 50.0 * (1.0 - np.cos(quarter))], 1)
        ground = drivable.Drivable()
        ground.add_strip(road_network.sections_along(bend), 3.0, 3.0)
        on_the_bend = 50.0 * np.sin(np.pi / 4), 50.0 * (1.0 - np.cos(np.pi / 4))

        covered = ground.covers([on_the_bend[0], 0.0], [on_the_bend[1], 50.0])

        self.assertEqual(covered.tolist(), [True, False])


class RasterTest(unittest.TestCase):
    """Trees against parking lots."""

    def setUp(self):
        # A lot 10 m wide from x = 20, 5 m deep below y = 100, in cells of 0.5 m.
        columns, rows = np.meshgrid(np.arange(80) * 0.5 + 0.25, 100.0 - np.arange(40) * 0.5 - 0.25)
        outside = np.maximum(np.abs(columns - 25.0) - 5.0, np.abs(rows - 97.5) - 2.5)
        self.ground = drivable.Drivable()
        self.ground.add_raster(outside, 0.0, 100.0, 0.5)

    def test_a_tree_in_a_lot_or_its_margin_is_on_drivable_ground(self):
        self.assertEqual(self.ground.covers([25.0, 30.3], [97.0, 97.0]).tolist(), [True, True])

    def test_a_tree_beside_a_lot_or_off_the_raster_stands(self):
        covered = self.ground.covers([31.5, 25.0, -5.0], [97.0, 93.5, 97.0])

        self.assertEqual(covered.tolist(), [False, False, False])


class TreesTest(unittest.TestCase):
    """A circuit's trees, listed in Godot's frame (x east, y up, z south)."""

    def test_trees_whose_trunk_is_on_a_road_are_dropped(self):
        ground = drivable.Drivable()
        ground.add_strip(road_east(), 3.0, 3.0)
        on_the_road = [40.0, 2.0, 1.0, 12.0, 0]
        on_the_verge = [40.0, 2.0, 3.3, 9.0, 1]
        beside_the_road = [40.0, 2.0, -6.0, 15.0, 1]

        kept = pack_experiment.trees_off_the_roads(
            [on_the_road, on_the_verge, beside_the_road], ground
        )

        self.assertEqual(kept, [beside_the_road])


if __name__ == "__main__":
    unittest.main()
