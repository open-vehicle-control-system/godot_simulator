# ruff: noqa: D102
"""Tests of a world cut into a pack's tiles."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import smooth_terrain
import track_tiles

TILE_M = 16.0


def grid():
    """Tiles 16 m wide whose corner (0, 0) is at the map's (1000, 2000)."""
    return track_tiles.TileGrid(0.0, 0.0, TILE_M, (1000.0, 2000.0))


def sloped(points):
    """Return points (x, z) on a plane, with its normal: x, y, z, nx, ny, nz."""
    points = np.asarray(points, np.float64)
    heights = 0.1 * points[:, 0] + 0.05 * points[:, 1]
    normal = np.array([-0.1, 1.0, -0.05]) / np.linalg.norm([-0.1, 1.0, -0.05])
    return np.concatenate(
        [points[:, :1], heights[:, None], points[:, 1:], np.tile(normal, (len(points), 1))], 1
    )


def area_m2(triangles):
    """Return the area triangles cover seen from above."""
    edge_1 = triangles[:, 1, [0, 2]] - triangles[:, 0, [0, 2]]
    edge_2 = triangles[:, 2, [0, 2]] - triangles[:, 0, [0, 2]]
    return 0.5 * np.abs(edge_1[:, 0] * edge_2[:, 1] - edge_1[:, 1] * edge_2[:, 0]).sum()


def open_edges(triangles):
    """Return the edges only one of the triangles uses, as sorted pairs of rounded corners."""
    uses = {}
    for triangle in triangles:
        corners = [tuple(np.round(corner[:3], 6)) for corner in triangle]
        for first, second in zip(corners, corners[1:] + corners[:1], strict=True):
            edge = tuple(sorted((first, second)))
            uses[edge] = uses.get(edge, 0) + 1
    return {edge for edge, count in uses.items() if count == 1}


class TileGridTest(unittest.TestCase):
    """Tiles and their names."""

    def test_a_tile_is_named_by_the_map_corner_to_its_south_west(self):
        # Godot z runs south: the tile from z 16 to 32 lies 32 m south of the origin.
        self.assertEqual(grid().key((1, 1)), "1016_1968")

    def test_a_point_is_in_the_tile_whose_lowest_corner_is_before_it(self):
        columns, rows = grid().cells([0.0, 15.9, 16.0, -0.1], [31.9, 32.0, -16.0, 0.0])

        self.assertEqual(columns.tolist(), [0, 0, 1, -1])
        self.assertEqual(rows.tolist(), [1, 2, -1, 0])


class CutTrianglesTest(unittest.TestCase):
    """Ground cut on the tiles' edges."""

    def setUp(self):
        # Two triangles sharing an edge that crosses the corner where four tiles meet.
        self.source = np.stack(
            [
                sloped([(10.0, 9.0), (25.0, 12.0), (13.0, 27.0)]),
                sloped([(25.0, 12.0), (30.0, 29.0), (13.0, 27.0)]),
            ]
        )
        self.cut = track_tiles.cut_triangles(self.source, grid())

    def test_a_triangle_inside_a_tile_is_kept_as_it_is(self):
        inside = sloped([(1.0, 1.0), (5.0, 1.0), (1.0, 5.0)])[None]

        cut = track_tiles.cut_triangles(inside, grid())

        self.assertEqual(list(cut), [(0, 0)])
        np.testing.assert_array_equal(cut[(0, 0)], inside)

    def test_a_triangle_touching_an_edge_is_not_split(self):
        touching = sloped([(0.0, 0.0), (16.0, 0.0), (16.0, 16.0)])[None]

        cut = track_tiles.cut_triangles(touching, grid())

        self.assertEqual(list(cut), [(0, 0)])

    def test_every_piece_lies_within_its_tile(self):
        self.assertEqual(sorted(self.cut), [(0, 0), (0, 1), (1, 0), (1, 1)])
        for (column, row), triangles in self.cut.items():
            self.assertGreaterEqual(triangles[:, :, 0].min(), column * TILE_M - 1e-9)
            self.assertLessEqual(triangles[:, :, 0].max(), (column + 1) * TILE_M + 1e-9)
            self.assertGreaterEqual(triangles[:, :, 2].min(), row * TILE_M - 1e-9)
            self.assertLessEqual(triangles[:, :, 2].max(), (row + 1) * TILE_M + 1e-9)

    def test_the_pieces_cover_what_the_triangles_covered(self):
        pieces = np.concatenate(list(self.cut.values()))

        self.assertAlmostEqual(area_m2(pieces), area_m2(self.source), places=9)

    def test_the_pieces_leave_no_seam(self):
        pieces = np.concatenate(list(self.cut.values()))

        # Every edge a piece has on a tile's border is shared with the piece across it.
        on_a_border = [
            edge
            for edge in open_edges(pieces)
            if any(
                abs(edge[0][axis] - 16.0) < 1e-9 and abs(edge[1][axis] - 16.0) < 1e-9
                for axis in (0, 2)
            )
        ]
        self.assertEqual(on_a_border, [])

    def test_new_corners_stay_on_the_surface_and_keep_its_normal(self):
        for triangles in self.cut.values():
            corners = triangles.reshape(-1, 6)
            np.testing.assert_allclose(
                corners[:, 1], 0.1 * corners[:, 0] + 0.05 * corners[:, 2], atol=1e-9
            )
            np.testing.assert_allclose(
                corners[:, 3:], np.tile(self.source[0, 0, 3:], (len(corners), 1))
            )


class GroundHeightsTest(unittest.TestCase):
    """The ground a tile's collision is made of."""

    def test_heights_are_the_triangles_at_each_point_of_the_grid(self):
        square = np.stack(
            [
                sloped([(0.0, 0.0), (16.0, 0.0), (16.0, 16.0)]),
                sloped([(0.0, 0.0), (16.0, 16.0), (0.0, 16.0)]),
            ]
        )[:, :, :3]

        heights = track_tiles.ground_heights([square], (0.0, 0.0), TILE_M, 0.5)

        self.assertEqual(heights.shape, (33, 33))
        # Row 4 is 2 m south, column 10 is 5 m east.
        self.assertAlmostEqual(heights[4, 10], 0.1 * 5.0 + 0.05 * 2.0)

    def test_the_road_stands_above_the_terrain_under_it(self):
        terrain = np.float64(
            [[[0, 0, 0], [16, 0, 0], [16, 0, 16]], [[0, 0, 0], [16, 0, 16], [0, 0, 16]]]
        )
        road = np.float64([[[4, 0.08, 0], [8, 0.08, 0], [8, 0.08, 16]]])

        heights = track_tiles.ground_heights([terrain, road], (0.0, 0.0), TILE_M, 0.5)

        self.assertAlmostEqual(heights[2, 15], 0.08)
        self.assertAlmostEqual(heights[2, 2], 0.0)

    def test_a_point_over_no_ground_has_no_height(self):
        half = np.float64([[[0, 0, 0], [8, 0, 0], [8, 0, 16]], [[0, 0, 0], [8, 0, 16], [0, 0, 16]]])

        heights = track_tiles.ground_heights([half], (0.0, 0.0), TILE_M, 0.5)

        self.assertTrue(np.isnan(heights[:, 17:]).all())
        self.assertFalse(np.isnan(heights[:, :17]).any())


def write_world(path):
    """Write terrain over 32 m by 16 m, a road across both tiles and a building in the second."""
    world = track_tiles.Glb()
    xs, zs = np.meshgrid(np.arange(0.0, 32.5, 2.0), np.arange(0.0, 16.5, 2.0))
    positions = np.stack([xs.ravel(), 0.1 * xs.ravel(), zs.ravel()], -1)
    slope = {"NORMAL": np.tile(np.float32([-0.0995, 0.995, 0.0]), (len(positions), 1))}
    photo = {"name": "M_Ortho_a"}
    world.add_mesh(
        "Terrain_a",
        [({"POSITION": positions, **slope}, smooth_terrain.grid_triangles(0.1 * xs), photo)],
    )
    road = np.float32([[3, 0.5, 5], [29, 3.1, 5], [29, 3.1, 9], [3, 0.5, 9]])
    world.add_mesh(
        "Road_a",
        [
            (
                {"POSITION": road, "NORMAL": slope["NORMAL"][:4]},
                np.uint32([[0, 2, 1], [0, 3, 2]]),
                photo,
            )
        ],
    )
    wall = np.float32([[20, 2, 2], [28, 2, 2], [28, 6, 2]])
    brick = {"name": "M_Facade_brick_0", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}
    world.add_mesh("Building_0000", [({"POSITION": wall}, np.uint32([[0, 1, 2]]), brick)])
    world.write(path)


class TwoTilePhoto:
    """A stand-in for the mosaic over the world `write_world` writes: 2 px per metre."""

    west = 1000.0
    north = 2000.0
    px_per_m = 2.0
    rgb = np.full((32, 64, 3), 90, np.uint8)

    @staticmethod
    def pack_tile_window(corner, m_per_px):
        side = round(TILE_M / m_per_px)
        column = round((corner[0] - 1000.0) / m_per_px)
        return slice(0, side), slice(column, column + side)


class WriteTest(unittest.TestCase):
    """A world written as a pack's tiles."""

    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.work.name)
        write_world(cls.directory / "world.glb")
        (cls.directory / "tiles").mkdir()
        (cls.directory / "tiles" / "1016_1984.track.png").write_bytes(b"")
        (cls.directory / "tiles" / "1048_1984.track.png").write_bytes(b"")
        trees = {"conifer": [[4.0, 20.0, 2.0, 12.0], [4.0, 90.0, 0.0, 9.0]]}
        signs = {"posts": [{"position_m": [8.0, 3.0, 0.3], "height_m": 2.0, "diameter_m": 0.08}]}
        cls.homeless = track_tiles.write(
            cls.directory / "world.glb",
            cls.directory,
            TwoTilePhoto,
            TwoTilePhoto.rgb,
            (1000.0, 2000.0),
            TILE_M,
            ("Terrain_", "Road_"),
            trees,
            signs,
        )
        cls.index = json.loads((cls.directory / "tiles.json").read_text())

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def tile(self, key):
        gltf, binary = smooth_terrain.read_glb(self.directory / "tiles" / f"{key}.glb")
        return gltf, binary

    def test_the_index_lists_each_tile_with_its_corner_and_what_it_holds(self):
        self.assertEqual(self.index["tile_size_m"], TILE_M)
        self.assertEqual(self.index["ground_step_m"], 0.5)
        self.assertEqual([tile["key"] for tile in self.index["tiles"]], ["1000_1984", "1016_1984"])
        second = self.index["tiles"][1]
        # ROS x is Godot z, ROS y is Godot x.
        self.assertEqual(second["corner_m"], [0.0, 16.0])
        self.assertEqual(second["bounds_m"], [[0.0, 16.0, 1.6], [16.0, 32.0, 6.0]])
        self.assertEqual(second["maps"], ["track"])

    def test_the_maps_of_a_tile_without_ground_are_removed(self):
        self.assertFalse((self.directory / "tiles" / "1048_1984.track.png").exists())

    def test_ground_is_cut_on_the_edge_and_shares_it(self):
        edges = []
        for key, edge_x in (("1000_1984", 16.0), ("1016_1984", 16.0)):
            gltf, binary = self.tile(key)
            for name in (f"Terrain_{key}", f"Road_{key}"):
                (mesh,) = smooth_terrain.meshes_named(gltf, name)
                positions = smooth_terrain.accessor_array(
                    gltf, binary, mesh["primitives"][0]["attributes"]["POSITION"]
                )
                if key == "1000_1984":
                    self.assertLessEqual(positions[:, 0].max(), 16.0)
                else:
                    self.assertGreaterEqual(positions[:, 0].min(), 16.0)
                on_edge = positions[positions[:, 0] == edge_x]
                edges.append({tuple(corner) for corner in on_edge.tolist()})
        self.assertEqual(edges[0], edges[2])
        self.assertEqual(edges[1], edges[3])
        # The road's two sides and the diagonal its triangles share.
        self.assertEqual(len(edges[1]), 3)

    def test_ground_is_textured_across_its_tile(self):
        gltf, binary = self.tile("1016_1984")
        (mesh,) = smooth_terrain.meshes_named(gltf, "Terrain_")
        attributes = mesh["primitives"][0]["attributes"]
        positions = smooth_terrain.accessor_array(gltf, binary, attributes["POSITION"])
        uvs = smooth_terrain.accessor_array(gltf, binary, attributes["TEXCOORD_0"])

        np.testing.assert_allclose(uvs[:, 0], (positions[:, 0] - 16.0) / 16.0, atol=1e-6)
        np.testing.assert_allclose(uvs[:, 1], positions[:, 2] / 16.0, atol=1e-6)
        self.assertEqual(gltf["materials"][mesh["primitives"][0]["material"]]["name"], "M_Ground")

    def test_a_mesh_goes_whole_to_the_tile_holding_its_centre(self):
        first, _ = self.tile("1000_1984")
        second, _ = self.tile("1016_1984")

        self.assertEqual(smooth_terrain.meshes_named(first, "Building_"), [])
        self.assertEqual(len(smooth_terrain.meshes_named(second, "Building_")), 1)
        (brick,) = [m for m in second["materials"] if m["name"] == "M_Facade_brick_0"]
        self.assertNotIn("baseColorTexture", brick["pbrMetallicRoughness"])

    def test_the_ground_heights_of_neighbours_agree_on_their_edge(self):
        first = np.fromfile(self.directory / "tiles" / "1000_1984.ground.f32", "<f4")
        second = np.fromfile(self.directory / "tiles" / "1016_1984.ground.f32", "<f4")
        first, second = first.reshape(33, 33), second.reshape(33, 33)

        np.testing.assert_allclose(first[:, -1], second[:, 0], atol=1e-5)
        # On the road 7 m south, 10 m east; on the terrain 1 m south.
        self.assertAlmostEqual(first[14, 20], 0.5 + 0.1 * 7.0, places=5)
        self.assertAlmostEqual(first[2, 20], 1.0, places=5)

    def test_trees_and_signs_are_listed_by_the_tile_they_stand_on(self):
        first = json.loads((self.directory / "tiles" / "1000_1984.json").read_text())
        second = json.loads((self.directory / "tiles" / "1016_1984.json").read_text())

        self.assertEqual(first["trees"], {"conifer": [], "broadleaf": []})
        self.assertEqual(second["trees"]["conifer"], [[4.0, 20.0, 2.0, 12.0]])
        self.assertEqual(len(first["posts"]), 1)
        self.assertEqual(second["posts"] + second["plates"] + second["signals"], [])
        self.assertEqual(self.homeless, 1)

    def test_every_tile_has_its_photo(self):
        for key in ("1000_1984", "1016_1984"):
            with Image.open(self.directory / "tiles" / f"{key}.photo.jpg") as photo:
                self.assertEqual(photo.size, (32, 32))

    def test_the_far_terrain_has_a_mesh_per_tile_over_the_whole_photo(self):
        gltf, binary = smooth_terrain.read_glb(self.directory / "far.glb")

        self.assertEqual(
            [mesh["name"] for mesh in gltf["meshes"]], ["Far_1000_1984", "Far_1016_1984"]
        )
        attributes = gltf["meshes"][1]["primitives"][0]["attributes"]
        positions = smooth_terrain.accessor_array(gltf, binary, attributes["POSITION"])
        uvs = smooth_terrain.accessor_array(gltf, binary, attributes["TEXCOORD_0"])
        np.testing.assert_allclose(uvs[:, 0], positions[:, 0] / 32.0, atol=1e-6)
        # The rim hangs below the ground's lowest point.
        self.assertAlmostEqual(positions[:, 1].min(), 1.6 - track_tiles.FAR_SKIRT_M, places=5)
        with Image.open(self.directory / "far.jpg") as photo:
            self.assertEqual(photo.size, (16, 8))


if __name__ == "__main__":
    unittest.main()
