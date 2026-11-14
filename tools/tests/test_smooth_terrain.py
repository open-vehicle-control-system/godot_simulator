"""Tests of the terrain smoothing of a world glb."""

# ruff: noqa: D102

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, TiffImagePlugin

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import smooth_terrain as terrain

ORIGIN_M = (1000.0, 2016.0, 100.0)
EAST_SLOPE = 0.1
SOUTH_SLOPE = 0.05
ROAD_ABOVE_GROUND_M = 0.5
TIFF_DOUBLE = 12
TIFF_ASCII = 2


def plane(row_count, column_count):
    """Return heights that rise steadily along both axes."""
    rows, columns = np.mgrid[0:row_count, 0:column_count]
    return 10.0 + 0.3 * rows - 0.2 * columns


def ground_m(x_m, z_m):
    """Return the synthetic world's ground height at a Godot position."""
    return EAST_SLOPE * x_m + SOUTH_SLOPE * z_m


def write_height_map(tif_path, spike_cell=None, missing_cells=()):
    """Write a 32 m by 16 m GeoTIFF of the synthetic ground, one metre cells."""
    rows, columns = np.mgrid[0:16, 0:32]
    heights = (ORIGIN_M[2] + ground_m(columns + 0.5, rows + 0.5)).astype(np.float32)
    if spike_cell:
        heights[spike_cell] += 5.0
    for cell in missing_cells:
        heights[cell] = -9999.0
    tags = TiffImagePlugin.ImageFileDirectory_v2()
    for tag, kind, content in [
        (terrain.TIFF_PIXEL_SCALE_TAG, TIFF_DOUBLE, (1.0, 1.0, 0.0)),
        (terrain.TIFF_TIEPOINT_TAG, TIFF_DOUBLE, (0.0, 0.0, 0.0, ORIGIN_M[0], ORIGIN_M[1], 0.0)),
        (terrain.TIFF_NODATA_TAG, TIFF_ASCII, "-9999"),
    ]:
        tags.tagtype[tag] = kind
        tags[tag] = content
    Image.fromarray(heights).save(tif_path, tiffinfo=tags)


class GlbBuilder:
    """Assembles a small glb, one buffer view per accessor."""

    def __init__(self):
        """Start with an empty scene."""
        self.gltf = {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": []}],
            "nodes": [],
            "meshes": [],
            "accessors": [],
            "bufferViews": [],
            "buffers": [{"byteLength": 0}],
        }
        self.binary = b""

    def add_view(self, content):
        """Append bytes as a buffer view and return its index."""
        self.gltf["bufferViews"].append({"buffer": 0, "byteOffset": len(self.binary)})
        self.gltf["bufferViews"][-1]["byteLength"] = len(content)
        self.binary += content + b"\0" * (-len(content) % 4)
        return len(self.gltf["bufferViews"]) - 1

    def add_accessor(self, elements, kind):
        """Append an array as an accessor and return its index."""
        accessor = {
            "bufferView": self.add_view(elements.tobytes()),
            "componentType": 5126 if elements.dtype == np.float32 else 5125,
            "count": len(elements),
            "type": kind,
        }
        if kind == "VEC3":
            accessor["min"] = elements.min(axis=0).tolist()
            accessor["max"] = elements.max(axis=0).tolist()
        self.gltf["accessors"].append(accessor)
        return len(self.gltf["accessors"]) - 1

    def add_mesh(self, name, positions, triangles, uvs=None):
        """Append a mesh with its node."""
        positions = np.asarray(positions, np.float32)
        attributes = {"POSITION": self.add_accessor(positions, "VEC3")}
        if uvs is not None:
            normals = np.tile(np.float32([0, 1, 0]), (len(positions), 1))
            attributes["NORMAL"] = self.add_accessor(normals, "VEC3")
            attributes["TEXCOORD_0"] = self.add_accessor(np.asarray(uvs, np.float32), "VEC2")
        indices = self.add_accessor(np.asarray(triangles, np.uint32).reshape(-1, 1), "SCALAR")
        self.gltf["meshes"].append(
            {"name": name, "primitives": [{"attributes": attributes, "indices": indices}]}
        )
        self.gltf["nodes"].append({"name": name, "mesh": len(self.gltf["meshes"]) - 1})
        self.gltf["scenes"][0]["nodes"].append(len(self.gltf["nodes"]) - 1)

    def add_terrain_tile(self, name, tile_west_m, xs_m):
        """Append a flat tile whose texture spans 16 m from tile_west_m, with vertices at xs_m."""
        zs_m = np.arange(0.0, 16.5, 2.0)
        grid_x, grid_z = np.meshgrid(xs_m, zs_m)
        positions = np.stack([grid_x.ravel(), np.zeros(grid_x.size), grid_z.ravel()], axis=-1)
        uvs = np.stack([(grid_x.ravel() - tile_west_m) / 16.0, grid_z.ravel() / 16.0], axis=-1)
        self.add_mesh(name, positions, terrain.grid_triangles(grid_x * 0.0), uvs)

    def write(self, glb_path):
        """Write the glb."""
        self.gltf["buffers"][0]["byteLength"] = len(self.binary)
        json_text = json.dumps(self.gltf).encode()
        json_text += b" " * (-len(json_text) % 4)
        with open(glb_path, "wb") as glb_file:
            glb_file.write(
                struct.pack("<III", terrain.GLB_MAGIC, 2, 28 + len(json_text) + len(self.binary))
            )
            glb_file.write(struct.pack("<II", len(json_text), terrain.GLB_JSON_CHUNK) + json_text)
            glb_file.write(struct.pack("<II", len(self.binary), terrain.GLB_BINARY_CHUNK))
            glb_file.write(self.binary)


def write_world(glb_path):
    """Write two terrain tiles a metre apart, a road across both and a building."""
    builder = GlbBuilder()
    builder.add_terrain_tile("Terrain_1000_2000", 0.0, np.arange(1.0, 15.5, 2.0))
    builder.add_terrain_tile("Terrain_1016_2000", 16.0, np.arange(16.0, 32.5, 2.0))
    road_corners = [(4.0, 6.0), (20.0, 6.0), (4.0, 11.0), (20.0, 11.0)]
    builder.add_mesh(
        "Road_Road_000",
        [(x_m, ground_m(x_m, z_m) + ROAD_ABOVE_GROUND_M, z_m) for x_m, z_m in road_corners],
        [(0, 2, 1), (1, 2, 3)],
    )
    builder.add_mesh("Building_0", [(1, 0, 1), (2, 0, 1), (1, 3, 1)], [(0, 1, 2)])
    builder.gltf["images"] = [{"bufferView": builder.add_view(b"not really a jpeg")}]
    builder.write(glb_path)


def tile_grids(glb_path):
    """Return each terrain tile's xs, zs, heights and normals as grids."""
    gltf, binary = terrain.read_glb(glb_path)
    grids = {}
    for mesh in terrain.meshes_named(gltf, terrain.TERRAIN_MESH_PREFIX):
        attributes = mesh["primitives"][0]["attributes"]
        positions = terrain.accessor_array(gltf, binary, attributes["POSITION"])
        normals = terrain.accessor_array(gltf, binary, attributes["NORMAL"])
        xs_m, zs_m = np.unique(positions[:, 0]), np.unique(positions[:, 2])
        shape = (len(zs_m), len(xs_m))
        grids[mesh["name"]] = (
            xs_m,
            zs_m,
            positions[:, 1].reshape(shape),
            normals.reshape(shape + (3,)),
        )
    return grids


class FillGapsTest(unittest.TestCase):
    """Missing cells take the heights the ground around them implies."""

    def test_fills_a_hole_in_a_plane_with_the_plane(self):
        heights = plane(40, 50)
        is_valid = np.ones(heights.shape, bool)
        is_valid[15:22, 20:28] = False
        filled = terrain.fill_gaps(np.where(is_valid, heights, -9999.0), is_valid)
        self.assertLess(np.abs(filled - heights).max(), 0.02)

    def test_a_filled_hole_stays_within_the_heights_around_it(self):
        heights = np.random.default_rng(3).uniform(5.0, 6.0, (30, 30))
        is_valid = np.ones(heights.shape, bool)
        is_valid[0:9, 0:12] = False
        filled = terrain.fill_gaps(np.where(is_valid, heights, -9999.0), is_valid)
        self.assertGreaterEqual(filled.min(), 5.0)
        self.assertLessEqual(filled.max(), 6.0)

    def test_leaves_valid_cells_alone(self):
        heights = plane(12, 12)
        is_valid = np.ones(heights.shape, bool)
        is_valid[4, 5] = False
        filled = terrain.fill_gaps(heights, is_valid)
        np.testing.assert_array_equal(filled[is_valid], heights[is_valid])


class SmoothGroundTest(unittest.TestCase):
    """The ground raster loses its artefacts and keeps its shape."""

    def test_keeps_a_plane(self):
        heights = plane(30, 40)
        smoothed = terrain.smooth_ground(heights, np.ones(heights.shape, bool), 1.0)
        np.testing.assert_allclose(smoothed, heights, atol=1e-9)

    def test_removes_a_spike_and_a_pit(self):
        heights = plane(30, 40)
        heights[10, 10] += 6.0
        heights[20, 30] -= 6.0
        smoothed = terrain.smooth_ground(heights, np.ones(heights.shape, bool), 1.0)
        self.assertLess(np.abs(smoothed - plane(30, 40)).max(), 0.02)

    def test_turns_a_staircase_into_a_slope(self):
        staircase = np.tile(0.5 * (np.arange(60) // 2), (8, 1)).astype(float)
        smoothed = terrain.low_passed(staircase, 1.0)
        largest_kink = np.abs(np.diff(smoothed[:, 5:-5], n=2, axis=1)).max()
        self.assertEqual(np.abs(np.diff(staircase, n=2, axis=1)).max(), 0.5)
        self.assertLess(largest_kink, 0.05)

    def test_keeps_an_embankment(self):
        embankment = np.tile(np.where(np.arange(60) < 30, 0.0, 3.0), (8, 1))
        smoothed = terrain.low_passed(embankment, 1.0)
        self.assertLess(smoothed[:, :26].max(), 0.01)
        self.assertGreater(smoothed[:, 34:].min(), 2.99)


class LoweredUnderPointsTest(unittest.TestCase):
    """The ground never stands above a point of the road."""

    def test_lowers_the_quad_under_a_point_below_it(self):
        lattice = terrain.Lattice(0.0, 0.0, 2.0, 4, 3)
        point_m = np.array([[3.0, -0.2, 1.5]])
        lowered = terrain.lowered_under_points(np.zeros(lattice.shape), lattice, point_m)
        expected = np.zeros(lattice.shape)
        expected[0:2, 1:3] = -0.2 - terrain.ROAD_CLEARANCE_M
        np.testing.assert_allclose(lowered, expected)

    def test_leaves_ground_that_clears_the_points(self):
        lattice = terrain.Lattice(0.0, 0.0, 2.0, 4, 3)
        point_m = np.array([[3.0, 0.5, 1.5]])
        lowered = terrain.lowered_under_points(np.zeros(lattice.shape), lattice, point_m)
        np.testing.assert_array_equal(lowered, np.zeros(lattice.shape))


class GridTrianglesTest(unittest.TestCase):
    """The lattice's triangles face up."""

    def test_every_triangle_faces_up(self):
        heights = np.random.default_rng(5).uniform(0.0, 1.0, (6, 7))
        grid_x, grid_z = np.meshgrid(np.arange(7.0), np.arange(6.0))
        positions = np.stack([grid_x.ravel(), heights.ravel(), grid_z.ravel()], axis=-1)
        corners = positions[terrain.grid_triangles(heights)]
        normals = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        self.assertEqual(len(corners), 2 * 5 * 6)
        self.assertGreater(normals[:, 1].min(), 0.0)


class WriteSmoothedWorldTest(unittest.TestCase):
    """A world glb comes out with one smooth ground and everything else untouched."""

    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.source_glb = self.directory / "source.glb"
        self.out_glb = self.directory / "out" / "world.glb"
        self.out_glb.parent.mkdir()
        self.height_map_tif = self.directory / "ground.tif"
        write_world(self.source_glb)
        write_height_map(self.height_map_tif)

    def smooth(self):
        terrain.write_smoothed_world(self.source_glb, self.out_glb, self.height_map_tif, ORIGIN_M)
        return tile_grids(self.out_glb)

    def test_neighbouring_tiles_share_their_edge(self):
        west = self.smooth()["Terrain_1000_2000"]
        east = self.smooth()["Terrain_1016_2000"]
        self.assertEqual(west[0][-1], east[0][0])
        np.testing.assert_array_equal(west[2][:, -1], east[2][:, 0])
        np.testing.assert_array_equal(west[3][:, -1], east[3][:, 0])

    def test_tiles_cover_the_ground_they_texture(self):
        xs_m, zs_m, _, _ = self.smooth()["Terrain_1000_2000"]
        np.testing.assert_array_equal(xs_m, np.arange(0.0, 16.5, 2.0))
        np.testing.assert_array_equal(zs_m, np.arange(0.0, 16.5, 2.0))

    def test_ground_away_from_the_road_follows_the_height_map(self):
        xs_m, zs_m, heights_m, normals = self.smooth()["Terrain_1016_2000"]
        np.testing.assert_allclose(heights_m[1:-1, -2], ground_m(xs_m[-2], zs_m[1:-1]), atol=1e-3)
        expected_normal = np.array([-EAST_SLOPE, 1.0, -SOUTH_SLOPE])
        expected_normal /= np.linalg.norm(expected_normal)
        np.testing.assert_allclose(normals[3, -2], expected_normal, atol=1e-3)

    def test_ground_sits_just_under_the_road(self):
        for xs_m, zs_m, heights_m, _ in self.smooth().values():
            grid_x, grid_z = np.meshgrid(xs_m, zs_m)
            under_road = (grid_x > 4) & (grid_x < 20) & (grid_z > 6) & (grid_z < 11)
            road_m = ground_m(grid_x, grid_z) + ROAD_ABOVE_GROUND_M
            sink_m = (road_m - heights_m)[under_road]
            self.assertGreaterEqual(sink_m.min(), terrain.ROAD_EDGE_SINK_M - 1e-4)
            self.assertLessEqual(sink_m.max(), terrain.ROAD_SINK_M + 1e-4)

    def test_ground_beside_the_road_reaches_its_edge(self):
        xs_m, zs_m, heights_m, _ = self.smooth()["Terrain_1016_2000"]
        beside_m = heights_m[list(zs_m).index(12.0), list(xs_m).index(18.0)]
        edge_m = ground_m(18.0, 11.0) + ROAD_ABOVE_GROUND_M
        self.assertAlmostEqual(beside_m, edge_m - terrain.ROAD_EDGE_SINK_M, places=4)

    def test_a_missing_cell_and_a_spike_leave_no_mark(self):
        expected = self.smooth()
        write_height_map(self.height_map_tif, spike_cell=(4, 29), missing_cells=[(8, 28), (8, 29)])
        for name, (_, _, heights_m, _) in self.smooth().items():
            np.testing.assert_allclose(heights_m, expected[name][2], atol=0.02)

    def test_position_bounds_match_the_vertices(self):
        self.smooth()
        gltf, binary = terrain.read_glb(self.out_glb)
        for mesh in terrain.meshes_named(gltf, terrain.TERRAIN_MESH_PREFIX):
            index = mesh["primitives"][0]["attributes"]["POSITION"]
            positions = terrain.accessor_array(gltf, binary, index)
            self.assertEqual(gltf["accessors"][index]["min"], positions.min(axis=0).tolist())
            self.assertEqual(gltf["accessors"][index]["max"], positions.max(axis=0).tolist())
            triangles = terrain.accessor_array(gltf, binary, mesh["primitives"][0]["indices"])
            self.assertLess(int(triangles.max()), len(positions))

    def test_texture_coordinates_keep_their_mapping(self):
        self.smooth()
        gltf, binary = terrain.read_glb(self.out_glb)
        mesh = terrain.meshes_named(gltf, terrain.TERRAIN_MESH_PREFIX)[1]
        attributes = mesh["primitives"][0]["attributes"]
        positions = terrain.accessor_array(gltf, binary, attributes["POSITION"])
        uvs = terrain.accessor_array(gltf, binary, attributes["TEXCOORD_0"])
        np.testing.assert_allclose(uvs[:, 0], (positions[:, 0] - 16.0) / 16.0, atol=1e-5)
        np.testing.assert_allclose(uvs[:, 1], positions[:, 2] / 16.0, atol=1e-5)

    def test_other_content_is_copied_byte_for_byte(self):
        self.smooth()
        source_gltf, source_binary = terrain.read_glb(self.source_glb)
        gltf, binary = terrain.read_glb(self.out_glb)
        terrain_accessors = set()
        for mesh in terrain.meshes_named(source_gltf, terrain.TERRAIN_MESH_PREFIX):
            primitive = mesh["primitives"][0]
            terrain_accessors |= {primitive["indices"], *primitive["attributes"].values()}
        terrain_views = {
            source_gltf["accessors"][index]["bufferView"] for index in terrain_accessors
        }
        for index, source_view in enumerate(source_gltf["bufferViews"]):
            if index in terrain_views:
                continue
            view = gltf["bufferViews"][index]
            start, source_start = view["byteOffset"], source_view["byteOffset"]
            self.assertEqual(
                bytes(binary[start : start + view["byteLength"]]),
                bytes(source_binary[source_start : source_start + source_view["byteLength"]]),
            )
            self.assertEqual(start % 4, 0)
        self.assertEqual(gltf["meshes"], source_gltf["meshes"])
        self.assertEqual(gltf["nodes"], source_gltf["nodes"])

    def test_replaces_a_symlink_instead_of_writing_through_it(self):
        source_bytes = self.source_glb.read_bytes()
        self.out_glb.symlink_to(self.source_glb)
        self.smooth()
        self.assertFalse(self.out_glb.is_symlink())
        self.assertEqual(self.source_glb.read_bytes(), source_bytes)


class GlbRoundTripTest(unittest.TestCase):
    """A glb written without replacements reads back the same."""

    def test_reads_back_what_it_wrote(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        write_world(directory / "source.glb")
        gltf, binary = terrain.read_glb(directory / "source.glb")
        terrain.write_glb(directory / "copy.glb", gltf, binary, {})
        copy_gltf, copy_binary = terrain.read_glb(directory / "copy.glb")
        self.assertEqual(copy_gltf, gltf)
        self.assertEqual(bytes(copy_binary), bytes(binary))
        for index in range(len(gltf["accessors"])):
            np.testing.assert_array_equal(
                terrain.accessor_array(copy_gltf, copy_binary, index),
                terrain.accessor_array(gltf, binary, index),
            )


class LevelledTest(unittest.TestCase):
    """The ground of a parking lot evened out."""

    def setUp(self):
        self.heights = np.zeros((60, 60))
        self.heights[:, 30:] = 0.4  # a step across the map
        # 40 m square, its north-west corner 10 m in from the map's.
        self.outline = [(10.0, -10.0), (50.0, -10.0), (50.0, -50.0), (10.0, -50.0)]

    def test_a_step_inside_a_lot_becomes_a_grade(self):
        levelled = terrain.levelled(self.heights, 1.0, 0.0, 0.0, [self.outline])

        self.assertLess(np.abs(np.diff(levelled[30])).max(), 0.06)
        self.assertAlmostEqual(levelled[30, 15], 0.0, delta=0.01)
        self.assertAlmostEqual(levelled[30, 45], 0.4, delta=0.01)

    def test_the_ground_outside_a_lot_keeps_its_shape(self):
        levelled = terrain.levelled(self.heights, 1.0, 0.0, 0.0, [self.outline])

        np.testing.assert_allclose(levelled[3], self.heights[3])

    def test_without_lots_nothing_changes(self):
        self.assertIs(terrain.levelled(self.heights, 1.0, 0.0, 0.0, []), self.heights)


if __name__ == "__main__":
    unittest.main()
