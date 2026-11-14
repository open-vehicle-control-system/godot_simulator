"""Tests of the building of closed buildings from mapped footprints and the LiDAR."""

# ruff: noqa: D102

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import building_shapes
import buildings
import osm
import smooth_terrain
import track_tiles

FOOTPRINT = np.array([(0, 0), (12, 0), (12, 8), (0, 8)], np.float64)
MAPPED = FOOTPRINT + np.array([(0.1, -0.05), (-0.08, 0.06), (0.05, 0.1), (-0.06, -0.08)])
TINTS = {"brick": 3, "plaster": 4, "stone": 2, "metal": 5, "concrete": 3}
WEST_M, NORTH_M = -20.0, 30.0


def ground(points):
    """Return a ground rising to the east."""
    return 10.0 + 0.05 * points[:, 0]


def grey(points):
    """Return a dark grey for every point."""
    return np.full((len(points), 3), 0.05)


def surface(roof_at=None):
    """Return a LiDAR surface 50 m wide: the ground, and `roof_at(cells)` over FOOTPRINT."""
    east, north = np.meshgrid(WEST_M + np.arange(50) + 0.5, NORTH_M - np.arange(50) - 0.5)
    cells = np.column_stack([east.ravel(), north.ravel()])
    heights_m = ground(cells)
    if roof_at is not None:
        on_roof = np.all((cells > FOOTPRINT.min(0)) & (cells < FOOTPRINT.max(0)), axis=1)
        heights_m[on_roof] = roof_at(cells[on_roof])
    return buildings.Surface(heights_m.reshape(50, 50), WEST_M, NORTH_M, 1.0)


def gable(cells):
    """Return a gable 6 m above the ground's foot, its ridge along the footprint's length."""
    return 16.0 + 0.6 * (4.0 - np.abs(cells[:, 1] - 4.0))


def built(tags, roof_at=gable, facades=()):
    """Return the building of MAPPED with `tags` and how it was made."""
    return buildings.build_one(
        osm.Area(tags, MAPPED), surface(roof_at), ground, grey, facades, TINTS
    )


class SurfaceTest(unittest.TestCase):
    """The LiDAR surface model's cells."""

    def test_cells_are_given_at_their_centres_without_spikes(self):
        lidar = surface()
        lidar.heights_m[26, 22] += 30.0  # a bird over (2.5, 3.5)
        cells, heights_m = lidar.cells(np.array([2.0, 3.0]), np.array([4.0, 5.0]))
        self.assertIn((2.5, 3.5), {tuple(cell) for cell in cells})
        np.testing.assert_allclose(heights_m, ground(cells), atol=0.06)

    def test_a_footprint_at_the_raster_s_edge_is_not_covered(self):
        self.assertTrue(surface().covers(FOOTPRINT))
        self.assertFalse(surface().covers(FOOTPRINT + (17.0, 0.0)))


class BuildOneTest(unittest.TestCase):
    """One mapped area built."""

    def test_a_building_takes_the_roof_the_lidar_shows_and_is_closed(self):
        building, made = built({"building": "yes"})
        self.assertEqual((building.shape, made), ("gable", "as mapped"))
        self.assertIsNone(building_shapes.faults(building.shell.triangles()))
        self.assertAlmostEqual(float(building.shell.roof[:, :, 2].min()), 16.0, delta=0.3)
        self.assertAlmostEqual(float(building.shell.roof[:, :, 2].max()), 18.4, delta=0.3)

    def test_its_walls_stand_square_and_go_under_the_lowest_ground(self):
        building, _ = built({"building": "yes"})
        self.assertEqual(len(building.rings[0]), 4)
        self.assertLess(float(building.shell.walls[:, :, 2].min()), 10.0 - 0.4)
        edges = np.roll(building.rings[0], -1, axis=0) - building.rings[0]
        self.assertAlmostEqual(float(edges[0] @ edges[1]), 0.0, places=6)

    def test_a_building_the_lidar_does_not_show_takes_the_map_s_height(self):
        building, _ = built({"building": "yes", "building:levels": "2"}, roof_at=None)
        self.assertEqual(building.shape, "flat")
        self.assertAlmostEqual(float(building.shell.roof[:, :, 2].max()), 10.6 + 7.0, delta=0.05)

    def test_a_roof_the_lidar_shows_too_low_is_raised_to_a_wall_s_height_over_the_ground(self):
        building, _ = built({"building": "yes"}, roof_at=lambda cells: 12.6 + 0.0 * cells[:, 0])
        self.assertEqual(building.shape, "flat")
        self.assertAlmostEqual(
            float(building.shell.roof[:, :, 2].min()), 10.6 + buildings.MIN_WALL_M, delta=0.02
        )

    def test_a_low_cabin_the_lidar_shows_is_not_given_the_map_s_height(self):
        building, _ = built({"building": "yes"}, roof_at=lambda cells: 11.9 + 0.0 * cells[:, 0])
        self.assertLess(float(building.shell.roof[:, :, 2].max()), 10.6 + 2.5)

    def test_a_roof_that_follows_the_slope_is_not_lifted_to_the_highest_ground(self):
        def steep(points):
            return 10.0 + 0.3 * points[:, 0]

        lidar = surface(lambda cells: steep(cells) + 4.0)
        building, _ = buildings.build_one(
            osm.Area({"building": "yes"}, MAPPED), lidar, steep, grey, (), TINTS
        )
        self.assertEqual(building.shape, "skillion")
        self.assertAlmostEqual(float(building.shell.roof[:, :, 2].min()), 14.0, delta=0.3)

    def test_the_map_s_roof_shape_is_kept(self):
        building, _ = built({"building": "yes", "roof:shape": "hipped"})
        self.assertEqual(building.shape, "hip")

    def test_a_faulty_roof_gives_way_to_another(self):
        real_faults = building_shapes.faults
        checked = []

        def faulty_once(triangles):
            checked.append(len(triangles))
            return "3 open edges" if len(checked) == 1 else real_faults(triangles)

        with mock.patch.object(building_shapes, "faults", faulty_once):
            building, made = built({"building": "yes"})
        self.assertEqual((building.shape, made), ("gable", "as mapped"))
        self.assertEqual(len(checked), 2)

    def test_a_building_no_mesh_closes_is_not_built(self):
        with mock.patch.object(building_shapes, "faults", lambda triangles: "1 open edges"):
            self.assertEqual(built({"building": "yes"}), (None, "no closed mesh"))

    def test_it_keeps_the_facade_it_had(self):
        facades = [(np.array([50.0, 50.0]), "M_Facade_stone_1"), (np.array([6.0, 4.0]), "M_F_0")]
        self.assertEqual(built({"building": "yes"}, facades=facades)[0].facade, "M_F_0")

    def test_an_unknown_building_gets_the_facade_its_tags_call_for(self):
        self.assertRegex(built({"building": "industrial"})[0].facade, r"^M_Facade_metal_[0-4]$")
        self.assertRegex(
            built({"building": "house"})[0].facade, r"^M_Facade_(brick|plaster|stone)_[0-3]$"
        )

    def test_a_dark_pitched_roof_is_slate(self):
        self.assertEqual(built({"building": "yes"})[0].roofing, "slate")


class BuildTest(unittest.TestCase):
    """Which mapped areas are built."""

    def test_grandstands_and_areas_mapped_twice_are_left_out(self):
        areas = [
            osm.Area({"building": "yes"}, MAPPED),
            osm.Area({"building": "yes"}, MAPPED),
            osm.Area({"building": "grandstand"}, MAPPED + (0.0, 12.0)),
            osm.Area({"amenity": "parking"}, MAPPED + (14.0, 0.0)),
            osm.Area({"building": "yes"}, MAPPED[:3] * 0.2),
        ]
        made, how = buildings.build(areas, surface(gable), ground, grey, (), TINTS)
        self.assertEqual(len(made), 1)
        self.assertEqual(dict(how), {"as mapped": 1, "too small": 1})


def write_world(path):
    """Write a world with one open building whose walls stand around (6, 4) east and north."""
    world = track_tiles.Glb()
    wall = np.float32([[0, 10, 0], [12, 10, -8], [12, 16, -8]])
    brick = {"name": "M_Facade_brick_2"}
    world.add_mesh("Building_0007", [({"POSITION": wall}, np.uint32([[0, 1, 2]]), brick)])
    world.add_mesh("Barrier_0", [({"POSITION": wall}, np.uint32([[0, 1, 2]]), brick)])
    world.write(path)


class GlbTest(unittest.TestCase):
    """Buildings read from and written into a world glb."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "world.glb"
        write_world(self.path)

    def test_the_facades_of_a_world_are_read_with_a_point_in_their_footprint(self):
        ((centre, material),) = buildings.mapped_facades(self.path)
        np.testing.assert_allclose(centre, (6.0, 4.0))
        self.assertEqual(material, "M_Facade_brick_2")

    def test_an_open_building_is_reported(self):
        self.assertIn("open", buildings.audit(self.path)["Building_0007"])

    def test_buildings_replace_the_world_s_and_are_closed(self):
        building, _ = built({"building": "yes"}, facades=buildings.mapped_facades(self.path))
        buildings.write(self.path, [building])
        self.assertEqual(buildings.audit(self.path), {"Building_0000": None})
        gltf, binary = smooth_terrain.read_glb(self.path)
        self.assertEqual(len(smooth_terrain.meshes_named(gltf, "Barrier_")), 1)
        (mesh,) = smooth_terrain.meshes_named(gltf, "Building_")
        materials = [gltf["materials"][part["material"]]["name"] for part in mesh["primitives"]]
        self.assertEqual(materials, ["M_Facade_brick_2", "M_Roof_slate"])
        facade, roof = mesh["primitives"]
        self.assertEqual(
            sorted(facade["attributes"]), ["NORMAL", "POSITION", "TEXCOORD_0", "TEXCOORD_1"]
        )
        self.assertEqual(
            sorted(roof["attributes"]),
            ["COLOR_0", "NORMAL", "POSITION", "TEXCOORD_0", "TEXCOORD_1"],
        )

    def test_walls_face_outwards_and_the_roof_up_in_the_world_s_frame(self):
        building, _ = built({"building": "yes"})
        facade, roof = buildings.primitives(building)
        self.assertGreater(float(roof["NORMAL"][:, 1].min()), 0.5)
        south = np.all(np.abs(facade["POSITION"].reshape(-1, 3, 3)[:, :, 2]) < 1e-6, axis=1)
        np.testing.assert_allclose(facade["NORMAL"].reshape(-1, 3, 3)[south][:, :, 2], 1.0)
        corners = facade["POSITION"].reshape(-1, 3, 3)[south]
        winding = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        self.assertTrue(np.all(winding[:, 2] > 0.0))


if __name__ == "__main__":
    unittest.main()
