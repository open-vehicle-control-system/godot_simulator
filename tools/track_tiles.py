"""Cut a circuit's world into the tiles of a track pack, and write its far terrain.

The world is a glb in Godot's frame (x east, y up, z south of the map frame's origin). Its
ground meshes (terrain and road) are cut on the tiles' edges, a triangle that crosses one
split there, so neighbours meet without a seam; every other mesh goes whole to the tile
holding the centre of its bounds. Per tile, as docs/pack_format.md describes them:

- `<key>.glb`: the tile's meshes;
- `<key>.ground.f32`: the height of the ground, the collision the vehicle rests on;
- `<key>.photo.jpg`: its orthophoto;
- `<key>.json`: the trees, posts, plates and signals standing on it.

`tiles.json` lists the tiles; `far.glb` and `far.jpg` are the whole area, coarse, a mesh per
tile, drawn where a tile is not loaded. `canopy.glb` is the woods as one coarse surface over
the trees' crowns, a mesh per tile under the far terrain's photo, drawn where the trees are too
far to be drawn one by one.

Needs numpy and Pillow.
"""

import json
import struct
from dataclasses import dataclass, field

import numpy as np
import smooth_terrain
from PIL import Image

GROUND_STEP_M = 0.5
FAR_STEP_M = 16.0
FAR_PHOTO_M_PER_PX = 2.0
PHOTO_JPEG_QUALITY = 95
FAR_SKIRT_M = 8.0  # how far a far tile's rim hangs down, closing the gap to a finer neighbour
ON_EDGE_M = 1e-4  # closer than this to a tile's edge is on it
MIN_DOUBLED_AREA_M2 = 1e-9
GROUND_MATERIAL = {
    "name": "M_Ground",
    "doubleSided": True,
    "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0.9},
}
FAR_MATERIAL = {
    "name": "M_Far",
    "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0.9},
}
CANOPY_MATERIAL = {
    "name": "M_Canopy",
    "doubleSided": True,
    "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 1.0},
}
CANOPY_STEP_M = 8.0
CANOPY_REACH_M = 10.0  # how far around its trunk a tree holds the canopy up
CANOPY_OVER_TRUNK = 0.85  # of a tree's height: the canopy over its trunk
CANOPY_AT_REACH = 0.45  # and CANOPY_REACH_M from it
CANOPY_HEM_M = 1.0  # how far under the lowest foot around the canopy's edge hangs
CANOPY_CROWNS_M = 2.5  # how far a vertex stands above or under the canopy, as a crown or a gap
CANOPY_SHADES = (0.82, 1.08)  # a tree's own brightness, as the simulator draws trees
CANOPY_SEED = 7
TREE_KINDS = ("conifer", "broadleaf")
SIGN_KINDS = ("posts", "plates", "signals")
GLTF_TYPES = {1: "SCALAR", 2: "VEC2", 3: "VEC3", 4: "VEC4"}
GLTF_COMPONENTS = {np.dtype(np.float32): 5126, np.dtype(np.uint32): 5125}
GLTF_ARRAY_BUFFER = 34962
GLTF_ELEMENT_ARRAY_BUFFER = 34963


class TileGrid:
    """Square tiles in Godot's x (east) and z (south), named by their map corner."""

    def __init__(self, west_x_m, north_z_m, tile_m, origin_m):
        """Lay tiles `tile_m` wide from (west_x_m, north_z_m).

        `origin_m` is the map's (east, north) at the world's origin.
        """
        self.west_x_m = west_x_m
        self.north_z_m = north_z_m
        self.tile_m = tile_m
        self.origin_m = origin_m

    def cells(self, x_m, z_m):
        """Return the (column, row) of the tiles holding points, as integer arrays."""
        return (
            np.floor((np.asarray(x_m) - self.west_x_m) / self.tile_m).astype(int),
            np.floor((np.asarray(z_m) - self.north_z_m) / self.tile_m).astype(int),
        )

    def corner(self, cell):
        """Return the (x, z) of a tile's north-west corner, its lowest coordinates."""
        return (
            self.west_x_m + cell[0] * self.tile_m,
            self.north_z_m + cell[1] * self.tile_m,
        )

    def map_corner(self, cell):
        """Return the (east, north) of a tile's south-west corner in the map frame."""
        x_m, z_m = self.corner(cell)
        return (
            round(self.origin_m[0] + x_m),
            round(self.origin_m[1] - z_m - self.tile_m),
        )

    def key(self, cell):
        """Return a tile's name: `<east>_<north>` of its south-west corner."""
        east, north = self.map_corner(cell)
        return f"{east}_{north}"


# ---------------------------------------------------------------------------------- cutting
def _split(polygon, axis, at_m):
    """Return the parts of a convex polygon below and above `at_m` along `axis`.

    A corner on the line is in both parts. Where an edge crosses the line, the new corner is
    worked out from the edge's ends in one order, so the two triangles sharing the edge get
    the very same corner.
    """
    below, above = [], []
    count = len(polygon)
    for index in range(count):
        corner, following = polygon[index], polygon[(index + 1) % count]
        side = corner[axis] - at_m
        following_side = following[axis] - at_m
        if side <= ON_EDGE_M:
            below.append(corner)
        if side >= -ON_EDGE_M:
            above.append(corner)
        if (side < -ON_EDGE_M and following_side > ON_EDGE_M) or (
            side > ON_EDGE_M and following_side < -ON_EDGE_M
        ):
            first, second = sorted((corner, following), key=lambda end: tuple(end[:3]))
            crossing = first + (at_m - first[axis]) / (second[axis] - first[axis]) * (
                second - first
            )
            crossing[axis] = at_m
            below.append(crossing)
            above.append(crossing)
    return below, above


def _fan(polygon):
    """Return a convex polygon's triangles that have an area, as a list of (3, k) arrays."""
    triangles = []
    for index in range(1, len(polygon) - 1):
        corners = np.stack([polygon[0], polygon[index], polygon[index + 1]])
        edge_1, edge_2 = corners[1, :3] - corners[0, :3], corners[2, :3] - corners[0, :3]
        if np.linalg.norm(np.cross(edge_1, edge_2)) > MIN_DOUBLED_AREA_M2:
            triangles.append(corners)
    return triangles


def cut_triangles(triangles, grid):
    """Return `{cell: triangles}`: the triangles of each tile, those crossing an edge split.

    `triangles` is (count, 3 corners, k values), the first three values x, y, z; the other
    values are carried to the new corners in proportion.
    """
    x_m, z_m = triangles[:, :, 0], triangles[:, :, 2]
    first_column, first_row = grid.cells(x_m.min(1) + ON_EDGE_M, z_m.min(1) + ON_EDGE_M)
    last_column, last_row = grid.cells(x_m.max(1) - ON_EDGE_M, z_m.max(1) - ON_EDGE_M)
    last_column = np.maximum(first_column, last_column)
    last_row = np.maximum(first_row, last_row)
    whole = (first_column == last_column) & (first_row == last_row)
    cut = {}
    cells = np.stack([first_column[whole], first_row[whole]], -1)
    kept = triangles[whole]
    for cell in np.unique(cells, axis=0):
        cut[tuple(int(index) for index in cell)] = [kept[(cells == cell).all(1)]]
    for index in np.nonzero(~whole)[0]:
        strips = [(first_column[index], list(triangles[index].astype(np.float64)))]
        for column in range(first_column[index], last_column[index]):
            _, rest = strips.pop()
            below, above = _split(rest, 0, grid.corner((column + 1, 0))[0])
            strips += [(column, below), (column + 1, above)]
        for column, strip in strips:
            rest = strip
            for row in range(first_row[index], last_row[index] + 1):
                piece, rest = _split(rest, 2, grid.corner((0, row + 1))[1])
                pieces = _fan(piece)
                if pieces:
                    cut.setdefault((int(column), int(row)), []).append(np.stack(pieces))
    return {cell: np.concatenate(parts) for cell, parts in cut.items()}


def welded(triangles):
    """Return triangles' distinct corners (float32) and each triangle's three (uint32)."""
    corners = triangles.reshape(-1, triangles.shape[-1]).astype(np.float32)
    vertices, indices = np.unique(corners, axis=0, return_inverse=True)
    return vertices, indices.reshape(-1, 3).astype(np.uint32)


def ground_heights(triangles, corner_m, tile_m, step_m):
    """Return the height of the highest triangle over each point of a tile's grid, NaN under none.

    The grid is `step_m` apart from the tile's north-west `corner_m`, both edges included:
    rows run south, columns east.
    """
    count = round(tile_m / step_m) + 1
    lattice = smooth_terrain.Lattice(corner_m[0], corner_m[1], step_m, count, count)
    heights_m = np.full(lattice.shape, np.nan)
    for layer in triangles:
        heights_m = np.fmax(heights_m, smooth_terrain.heights_under_triangles(layer, lattice))
    return heights_m


# -------------------------------------------------------------------------------------- glb
class Glb:
    """A binary glTF being written: meshes in world space, a node each, materials by name."""

    def __init__(self):
        """Start an empty scene."""
        self.gltf = {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": []}],
            "nodes": [],
            "meshes": [],
            "materials": [],
            "accessors": [],
            "bufferViews": [],
            "buffers": [{}],
        }
        self.binary = bytearray()

    def material(self, definition):
        """Return the index of the material named as `definition`, adding it at first use."""
        names = [material["name"] for material in self.gltf["materials"]]
        if definition["name"] not in names:
            self.gltf["materials"].append(definition)
            return len(names)
        return names.index(definition["name"])

    def accessor(self, elements, target):
        """Append `elements` (count, components) and return its accessor's index."""
        elements = np.ascontiguousarray(elements)
        self.gltf["bufferViews"].append(
            {
                "buffer": 0,
                "byteOffset": len(self.binary),
                "byteLength": elements.nbytes,
                "target": target,
            }
        )
        self.binary += elements.tobytes() + b"\0" * (-elements.nbytes % 4)
        accessor = {
            "bufferView": len(self.gltf["bufferViews"]) - 1,
            "componentType": GLTF_COMPONENTS[elements.dtype],
            "count": len(elements),
            "type": GLTF_TYPES[elements.shape[1]],
        }
        if target == GLTF_ARRAY_BUFFER and elements.shape[1] == 3:
            accessor["min"] = [float(low) for low in elements.min(0)]
            accessor["max"] = [float(high) for high in elements.max(0)]
        self.gltf["accessors"].append(accessor)
        return len(self.gltf["accessors"]) - 1

    def add_mesh(self, name, primitives, translation=None):
        """Add a mesh and its node; a primitive is (attributes by name, indices, material).

        The node stands at `translation`, the origin without one.
        """
        written = []
        for attributes, indices, material in primitives:
            written.append(
                {
                    "attributes": {
                        attribute: self.accessor(elements.astype(np.float32), GLTF_ARRAY_BUFFER)
                        for attribute, elements in attributes.items()
                    },
                    "indices": self.accessor(
                        indices.reshape(-1, 1).astype(np.uint32), GLTF_ELEMENT_ARRAY_BUFFER
                    ),
                    "material": self.material(material),
                }
            )
        self.gltf["meshes"].append({"name": name, "primitives": written})
        node = {"name": name, "mesh": len(self.gltf["meshes"]) - 1}
        if translation is not None:
            node["translation"] = [float(along) for along in translation]
        self.gltf["nodes"].append(node)
        self.gltf["scenes"][0]["nodes"].append(len(self.gltf["nodes"]) - 1)

    def write(self, path):
        """Write the scene to `path`."""
        self.gltf["buffers"][0]["byteLength"] = len(self.binary)
        text = json.dumps(self.gltf, separators=(",", ":")).encode()
        text += b" " * (-len(text) % 4)
        with open(path, "wb") as file:
            file.write(
                struct.pack(
                    "<III", smooth_terrain.GLB_MAGIC, 2, 12 + 8 + len(text) + 8 + len(self.binary)
                )
            )
            file.write(struct.pack("<II", len(text), smooth_terrain.GLB_JSON_CHUNK))
            file.write(text)
            file.write(struct.pack("<II", len(self.binary), smooth_terrain.GLB_BINARY_CHUNK))
            file.write(self.binary)


# ------------------------------------------------------------------------------------ tiles
@dataclass
class Tile:
    """What one tile holds, in Godot's frame."""

    cell: tuple
    terrain: list = field(default_factory=list)  # arrays of triangles: x, y, z, normal
    road: list = field(default_factory=list)
    objects: list = field(default_factory=list)  # (mesh name, primitives)
    standing: dict = field(default_factory=dict)  # trees and signs by kind, as the pack lists them

    def has_ground(self):
        """Tell whether any terrain or road lies on the tile."""
        return bool(self.terrain or self.road)


def _ground_triangles(gltf, binary, mesh):
    """Return a ground mesh's triangles as (count, 3, 6): position and normal."""
    triangles = []
    for primitive in mesh["primitives"]:
        corners = np.concatenate(
            [
                smooth_terrain.accessor_array(gltf, binary, primitive["attributes"][attribute])
                for attribute in ("POSITION", "NORMAL")
            ],
            axis=1,
        )
        indices = smooth_terrain.accessor_array(gltf, binary, primitive["indices"])
        triangles.append(corners[indices.reshape(-1, 3)])
    return np.concatenate(triangles)


def _object_primitives(gltf, binary, mesh):
    """Return a mesh's primitives as (attributes, indices, material without its textures)."""
    primitives = []
    for primitive in mesh["primitives"]:
        attributes = {
            attribute: np.array(smooth_terrain.accessor_array(gltf, binary, accessor))
            for attribute, accessor in primitive["attributes"].items()
        }
        material = json.loads(json.dumps(gltf["materials"][primitive["material"]]))
        material.get("pbrMetallicRoughness", {}).pop("baseColorTexture", None)
        if "indices" in primitive:
            indices = np.array(smooth_terrain.accessor_array(gltf, binary, primitive["indices"]))
        else:
            indices = np.arange(len(attributes["POSITION"]), dtype=np.uint32)
        primitives.append((attributes, indices, material))
    return primitives


def cut_world(world_glb, grid, terrain_prefix, road_prefix):
    """Return `{cell: Tile}`: the world's ground cut on the tiles' edges, its other meshes whole.

    A mesh that is not ground goes to the tile holding the centre of its bounds.
    """
    gltf, binary = smooth_terrain.read_glb(world_glb)
    tiles = {}
    for prefix in (terrain_prefix, road_prefix):
        for mesh in smooth_terrain.meshes_named(gltf, prefix):
            cut = cut_triangles(_ground_triangles(gltf, binary, mesh), grid)
            for cell, triangles in cut.items():
                tile = tiles.setdefault(cell, Tile(cell))
                (tile.terrain if prefix == terrain_prefix else tile.road).append(triangles)
    for mesh in smooth_terrain.meshes_named(gltf, ""):
        if mesh["name"].startswith((terrain_prefix, road_prefix)):
            continue
        primitives = _object_primitives(gltf, binary, mesh)
        positions = np.concatenate([attributes["POSITION"] for attributes, _, _ in primitives])
        centre = (positions.min(0) + positions.max(0)) * 0.5
        column, row = grid.cells(centre[0], centre[2])
        cell = (int(column), int(row))
        tiles.setdefault(cell, Tile(cell)).objects.append((mesh["name"], primitives))
    return tiles


def place(tiles, grid, kind, listed):
    """Hand each of `listed` to the tile it stands on; return how many stand on none.

    An entry is a tree `[x, y, z, height]` or a sign's part with a `position_m`, in the
    pack's ROS frame (x = Godot z, y = Godot x).
    """
    homeless = 0
    for entry in listed:
        position = entry["position_m"] if isinstance(entry, dict) else entry
        column, row = grid.cells(position[1], position[0])
        tile = tiles.get((int(column), int(row)))
        if tile is None:
            homeless += 1
        else:
            tile.standing.setdefault(kind, []).append(entry)
    return homeless


def _ground_mesh(triangles, corner_m, tile_m):
    """Return a tile's ground triangles as one primitive, its UV 0 across the tile."""
    corners = np.concatenate(triangles)
    normals = corners[:, :, 3:6]
    corners[:, :, 3:6] = normals / np.linalg.norm(normals, axis=-1, keepdims=True)
    vertices, indices = welded(corners)
    uvs = np.stack(
        [(vertices[:, 0] - corner_m[0]) / tile_m, (vertices[:, 2] - corner_m[1]) / tile_m], -1
    )
    attributes = {"POSITION": vertices[:, :3], "NORMAL": vertices[:, 3:6], "TEXCOORD_0": uvs}
    return attributes, indices, GROUND_MATERIAL


def _ros_bounds(low, high):
    """Return Godot bounds as the pack's: [[x, y, z] lowest, [x, y, z] highest] in ROS."""
    return [
        [round(float(low[2]), 2), round(float(low[0]), 2), round(float(low[1]), 2)],
        [round(float(high[2]), 2), round(float(high[0]), 2), round(float(high[1]), 2)],
    ]


def write_tile(tile, grid, directory, names):
    """Write a tile's glb, ground heights and objects; return its index entry and its heights.

    `names` are the mesh names (terrain, road) of its ground. The heights are the grid's as
    measured (NaN where no ground lies) and as written, the gaps filled.
    """
    key = grid.key(tile.cell)
    corner_m = grid.corner(tile.cell)
    glb = Glb()
    lows, highs = [], []
    for name, triangles in zip(names, (tile.terrain, tile.road), strict=True):
        if triangles:
            mesh = _ground_mesh(triangles, corner_m, grid.tile_m)
            glb.add_mesh(f"{name}{key}", [mesh])
            lows.append(mesh[0]["POSITION"].min(0))
            highs.append(mesh[0]["POSITION"].max(0))
    for name, primitives in tile.objects:
        glb.add_mesh(name, primitives)
        for attributes, _, _ in primitives:
            lows.append(attributes["POSITION"].min(0))
            highs.append(attributes["POSITION"].max(0))
    glb.write(directory / f"{key}.glb")
    measured_m = ground_heights(
        [
            np.concatenate(layer)[:, :, :3].astype(np.float64)
            for layer in (tile.terrain, tile.road)
            if layer
        ],
        corner_m,
        grid.tile_m,
        GROUND_STEP_M,
    )
    is_ground = ~np.isnan(measured_m)
    filled_m = smooth_terrain.fill_gaps(np.nan_to_num(measured_m), is_ground)
    filled_m.astype("<f4").tofile(directory / f"{key}.ground.f32")
    standing = {
        "trees": {kind: tile.standing.get(kind, []) for kind in TREE_KINDS},
        **{kind: tile.standing.get(kind, []) for kind in SIGN_KINDS},
    }
    (directory / f"{key}.json").write_text(json.dumps(standing))
    entry = {
        "key": key,
        "corner_m": [round(corner_m[1], 3), round(corner_m[0], 3)],
        "bounds_m": _ros_bounds(np.min(lows, 0), np.max(highs, 0)),
    }
    return entry, measured_m, filled_m


# -------------------------------------------------------------------------------------- far
def far_mesh(measured_m, filled_m, corner_m, tile_m, photo_uv):
    """Return a tile's coarse terrain as a primitive: its ground every FAR_STEP_M, with a rim.

    Only the squares whose four corners have ground are drawn. The rim hangs FAR_SKIRT_M
    down from the tile's outer edges. `photo_uv(x, z)` gives UV 0. None without any square.
    """
    stride = round(FAR_STEP_M / GROUND_STEP_M)
    heights_m = filled_m[::stride, ::stride]
    is_ground = ~np.isnan(measured_m[::stride, ::stride])
    count = heights_m.shape[0]
    x_m = corner_m[0] + FAR_STEP_M * np.arange(count)
    z_m = corner_m[1] + FAR_STEP_M * np.arange(count)
    grid_x_m, grid_z_m = np.meshgrid(x_m, z_m)
    positions = np.stack([grid_x_m, heights_m, grid_z_m], -1).reshape(-1, 3)
    normals = smooth_terrain.lattice_normals(heights_m, FAR_STEP_M).reshape(-1, 3)
    drawn = is_ground[:-1, :-1] & is_ground[:-1, 1:] & is_ground[1:, :-1] & is_ground[1:, 1:]
    if not drawn.any():
        return None
    indices = smooth_terrain.grid_triangles(heights_m)
    half = len(indices) // 2
    indices = np.concatenate([indices[:half][drawn.ravel()], indices[half:][drawn.ravel()]])
    vertex = np.arange(count * count).reshape(count, count)
    rim = []
    for edge in (vertex[0, ::-1], vertex[-1, :], vertex[:, 0], vertex[::-1, -1]):
        low = len(positions) + np.arange(count)
        positions = np.concatenate([positions, positions[edge] - [0.0, FAR_SKIRT_M, 0.0]])
        normals = np.concatenate([normals, normals[edge]])
        for step in range(count - 1):
            if is_ground.ravel()[edge[step]] and is_ground.ravel()[edge[step + 1]]:
                rim.append([edge[step], low[step], edge[step + 1]])
                rim.append([edge[step + 1], low[step], low[step + 1]])
    if rim:
        indices = np.concatenate([indices, np.array(rim, np.uint32)])
    attributes = {
        "POSITION": positions,
        "NORMAL": normals,
        "TEXCOORD_0": photo_uv(positions[:, 0], positions[:, 2]),
    }
    return attributes, indices.astype(np.uint32), FAR_MATERIAL


def _photo_uv(grid, mosaic, photo_rgb):
    """Return the function giving a point's UV across the far terrain's photo, from (x, z)."""
    width_m = photo_rgb.shape[1] / mosaic.px_per_m
    height_m = photo_rgb.shape[0] / mosaic.px_per_m
    west_x_m = mosaic.west - grid.origin_m[0]
    north_z_m = -(mosaic.north - grid.origin_m[1])

    def photo_uv(x_m, z_m):
        return np.stack([(x_m - west_x_m) / width_m, (z_m - north_z_m) / height_m], -1)

    return photo_uv


def write_far(directory, grid, heights, mosaic, photo_rgb):
    """Write far.glb (a `Far_<key>` mesh per tile) and far.jpg, the whole photo, coarse.

    `heights` is `{cell: (measured, filled)}` as `write_tile` returns them; `photo_rgb`
    covers the ground `mosaic` does.
    """
    width_m = photo_rgb.shape[1] / mosaic.px_per_m
    height_m = photo_rgb.shape[0] / mosaic.px_per_m
    photo_uv = _photo_uv(grid, mosaic, photo_rgb)
    glb = Glb()
    for cell, (measured_m, filled_m) in sorted(heights.items()):
        mesh = far_mesh(measured_m, filled_m, grid.corner(cell), grid.tile_m, photo_uv)
        if mesh is not None:
            glb.add_mesh(f"Far_{grid.key(cell)}", [mesh])
    glb.write(directory / "far.glb")
    photo = Image.fromarray(photo_rgb).resize(
        (round(width_m / FAR_PHOTO_M_PER_PX), round(height_m / FAR_PHOTO_M_PER_PX)),
        Image.Resampling.BOX,
    )
    photo.save(directory / "far.jpg", quality=PHOTO_JPEG_QUALITY, subsampling=0)


# ----------------------------------------------------------------------------------- canopy
def canopy_lattice(trees, colours, corner_m, shape):
    """Return the canopy over `trees` on a lattice: its height, its hem and its colour.

    The lattice has `shape` (rows south, columns east) vertices every CANOPY_STEP_M from
    `corner_m`, Godot's (x, z). A tree `[x, y, z, height]` of the pack's ROS frame holds the
    canopy up within CANOPY_REACH_M of its trunk, highest over it; the heights are evened
    out, as crowns side by side are, and NaN where no tree reaches. The hem is under the
    lowest foot around; the colour blends `colours`, the linear colour of each kind's crowns,
    shaded tree by tree.
    """
    top_m = np.full(shape, np.nan)
    hem_m = np.full(shape, np.inf)
    colour = np.zeros((*shape, 3))
    weight = np.zeros(shape)
    random = np.random.default_rng(CANOPY_SEED)
    reach = int(np.ceil(CANOPY_REACH_M / CANOPY_STEP_M))
    for kind in TREE_KINDS:
        standing = np.array(trees.get(kind, []), np.float64).reshape(-1, 4)
        if not len(standing):
            continue
        x_m, foot_m, z_m, height_m = standing[:, 1], standing[:, 2], standing[:, 0], standing[:, 3]
        shade = random.uniform(*CANOPY_SHADES, len(standing))
        column = np.rint((x_m - corner_m[0]) / CANOPY_STEP_M).astype(int)
        row = np.rint((z_m - corner_m[1]) / CANOPY_STEP_M).astype(int)
        for row_step in range(-reach, reach + 1):
            for column_step in range(-reach, reach + 1):
                rows, columns = row + row_step, column + column_step
                away_m = np.hypot(
                    corner_m[0] + columns * CANOPY_STEP_M - x_m,
                    corner_m[1] + rows * CANOPY_STEP_M - z_m,
                )
                held = (
                    (away_m < CANOPY_REACH_M)
                    & (rows >= 0)
                    & (rows < shape[0])
                    & (columns >= 0)
                    & (columns < shape[1])
                )
                at = (rows[held], columns[held])
                nearness = 1.0 - (away_m[held] / CANOPY_REACH_M) ** 2
                crown = CANOPY_AT_REACH + (CANOPY_OVER_TRUNK - CANOPY_AT_REACH) * nearness
                np.fmax.at(top_m, at, foot_m[held] + height_m[held] * crown)
                np.minimum.at(hem_m, at, foot_m[held] - CANOPY_HEM_M)
                np.add.at(weight, at, nearness)
                np.add.at(colour, at, (nearness * shade[held])[:, None] * np.asarray(colours[kind]))
    return _evened(top_m), hem_m, colour / np.maximum(weight, 1e-9)[..., None]


def _evened(top_m):
    """Return the canopy's heights, each averaged with those around it that have one."""
    held = ~np.isnan(top_m)
    total = np.pad(np.where(held, top_m, 0.0), 1)
    count = np.pad(held.astype(np.float64), 1)
    rows, columns = top_m.shape
    around = [(row, column) for row in range(3) for column in range(3)]
    summed = sum(total[row : row + rows, column : column + columns] for row, column in around)
    counted = sum(count[row : row + rows, column : column + columns] for row, column in around)
    return np.where(held, summed / np.maximum(counted, 1.0), np.nan)


def canopy_mesh(top_m, hem_m, colour, normal, drawn, edges, corner_m, centre_m, photo_uv):
    """Return a tile's canopy as a primitive about `centre_m`, or None without any.

    `top_m`, `hem_m`, `colour` and `normal` are the tile's part of the lattice, from
    `corner_m`; `photo_uv(x, z)` gives UV 1, across the far terrain's photo;
    `drawn` tells which of its squares the canopy covers, and `edges` which of each drawn
    square's sides (north, south, west, east) are the canopy's edge, where it hangs to its hem.
    UV 0 carries how far above its hem a vertex is, so the simulator can lay the canopy down.
    """
    if not drawn.any():
        return None
    count_z, count_x = top_m.shape
    grid_x_m, grid_z_m = np.meshgrid(
        corner_m[0] + CANOPY_STEP_M * np.arange(count_x),
        corner_m[1] + CANOPY_STEP_M * np.arange(count_z),
    )
    filled_m = np.where(np.isnan(top_m), np.where(np.isinf(hem_m), 0.0, hem_m), top_m)
    positions = np.stack([grid_x_m, filled_m, grid_z_m], -1).reshape(-1, 3)
    normals = normal.reshape(-1, 3)
    colours = colour.reshape(-1, 3)
    hems_m = np.where(np.isinf(hem_m), 0.0, hem_m).reshape(-1)
    vertex = np.arange(count_z * count_x).reshape(count_z, count_x)
    north_west, north_east = vertex[:-1, :-1][drawn], vertex[:-1, 1:][drawn]
    south_west, south_east = vertex[1:, :-1][drawn], vertex[1:, 1:][drawn]
    triangles = [
        np.stack([north_west, south_west, north_east], -1),
        np.stack([north_east, south_west, south_east], -1),
    ]
    sides = (
        (north_east, north_west, (0.0, 0.0, -1.0)),
        (south_west, south_east, (0.0, 0.0, 1.0)),
        (north_west, south_west, (-1.0, 0.0, 0.0)),
        (south_east, north_east, (1.0, 0.0, 0.0)),
    )
    for side, (first, second, outwards) in enumerate(sides):
        on_edge = edges[side][drawn]
        ends = np.concatenate([first[on_edge], second[on_edge]])
        if not len(ends):
            continue
        count = len(ends) // 2
        base = len(positions)
        hem = positions[ends].copy()
        hem[:, 1] = hems_m[ends]
        positions = np.concatenate([positions, positions[ends], hem])
        hems_m = np.concatenate([hems_m, hems_m[ends], hems_m[ends]])
        normals = np.concatenate([normals, np.tile(outwards, (4 * count, 1))])
        colours = np.concatenate([colours, colours[ends], colours[ends]])
        high_first, high_second = base + np.arange(count), base + count + np.arange(count)
        low_first, low_second = high_first + 2 * count, high_second + 2 * count
        triangles.append(np.stack([high_first, low_first, high_second], -1))
        triangles.append(np.stack([high_second, low_first, low_second], -1))
    indices = np.concatenate(triangles)
    used, indices = np.unique(indices, return_inverse=True)
    above_hem_m = positions[:, 1] - hems_m
    attributes = {
        "POSITION": positions[used] - np.asarray(centre_m),
        "NORMAL": normals[used],
        "TEXCOORD_0": np.stack([above_hem_m[used], np.zeros(len(used))], -1),
        "TEXCOORD_1": photo_uv(positions[used, 0], positions[used, 2]),
        "COLOR_0": np.concatenate([colours[used], np.ones((len(used), 1))], -1),
    }
    return attributes, indices.reshape(-1, 3).astype(np.uint32), CANOPY_MATERIAL


def write_canopy(directory, mosaic, photo_rgb, origin_m, trees, colours):
    """Write canopy.glb, a `Canopy_<key>` mesh per tile of `directory` with woods on it.

    `trees` are the pack's by kind, in its ROS frame, and `colours` the linear colour of each
    kind's crowns; `mosaic`, `photo_rgb` and `origin_m` are those the tiles and the far
    terrain were written with. Every vertex stands a little above or under the canopy, a
    crown or a gap, and keeps the canopy's own normal. Each mesh's node stands at the middle
    of its canopy. Returns how many tiles have a canopy.
    """
    index = json.loads((directory / "tiles.json").read_text())
    tile_m = index["tile_size_m"]
    grid = TileGrid(mosaic.west - origin_m[0], -(mosaic.north - origin_m[1]), tile_m, origin_m)
    per_tile = round(tile_m / CANOPY_STEP_M)
    cells = {}
    for entry in index["tiles"]:
        column, row = grid.cells(
            entry["corner_m"][1] + 0.5 * tile_m, entry["corner_m"][0] + 0.5 * tile_m
        )
        cells[(int(column), int(row))] = entry["key"]
    columns = [cell[0] for cell in cells]
    rows = [cell[1] for cell in cells]
    first = (min(columns), min(rows))
    corner_m = grid.corner(first)
    shape = (
        (max(rows) - first[1] + 1) * per_tile + 1,
        (max(columns) - first[0] + 1) * per_tile + 1,
    )
    on_a_tile = {
        kind: [
            tree
            for tree in trees.get(kind, [])
            if tuple(int(at) for at in grid.cells(tree[1], tree[0])) in cells
        ]
        for kind in TREE_KINDS
    }
    top_m, hem_m, colour = canopy_lattice(on_a_tile, colours, corner_m, shape)
    held = ~np.isnan(top_m)
    normal = smooth_terrain.lattice_normals(
        np.where(held, top_m, np.where(np.isinf(hem_m), 0.0, hem_m)), CANOPY_STEP_M
    )
    crowns = np.random.default_rng(CANOPY_SEED).uniform(-CANOPY_CROWNS_M, CANOPY_CROWNS_M, shape)
    top_m = np.maximum(top_m + crowns, hem_m + CANOPY_HEM_M)
    photo_uv = _photo_uv(grid, mosaic, photo_rgb)
    drawn = held[:-1, :-1] & held[:-1, 1:] & held[1:, :-1] & held[1:, 1:]
    bare = np.pad(~drawn, 1, constant_values=True)
    edges = (bare[:-2, 1:-1], bare[2:, 1:-1], bare[1:-1, :-2], bare[1:-1, 2:])
    glb = Glb()
    written = 0
    for cell, key in sorted(cells.items()):
        row = (cell[1] - first[1]) * per_tile
        column = (cell[0] - first[0]) * per_tile
        vertices = (slice(row, row + per_tile + 1), slice(column, column + per_tile + 1))
        squares = (slice(row, row + per_tile), slice(column, column + per_tile))
        tile_corner_m = grid.corner(cell)
        tops = top_m[vertices]
        if not drawn[squares].any():
            continue
        centre_m = (
            tile_corner_m[0] + 0.5 * tile_m,
            float(np.nanmean(tops)),
            tile_corner_m[1] + 0.5 * tile_m,
        )
        mesh = canopy_mesh(
            tops,
            hem_m[vertices],
            colour[vertices],
            normal[vertices],
            drawn[squares],
            [edge[squares] for edge in edges],
            tile_corner_m,
            centre_m,
            photo_uv,
        )
        glb.add_mesh(f"Canopy_{key}", [mesh], centre_m)
        written += 1
    glb.write(directory / "canopy.glb")
    return written


# ------------------------------------------------------------------------------------ whole
def write(world_glb, directory, mosaic, photo_rgb, origin_m, tile_m, prefixes, trees, signs):
    """Write a pack's tiles, tiles.json and far terrain into `directory` from its whole world.

    `photo_rgb` is the photo the ground is drawn with, covering the ground `mosaic` does;
    `origin_m` is the map's (east, north) at the world's origin, `prefixes` the mesh name
    prefixes of the terrain and of the road, `trees` the pack's trees by kind and `signs`
    its posts, plates and signals, in the pack's ROS frame. The ground maps of the tiles that
    hold no ground are removed. Returns how many trees and sign parts stand on no tile.
    """
    grid = TileGrid(mosaic.west - origin_m[0], -(mosaic.north - origin_m[1]), tile_m, origin_m)
    tiles = {
        cell: tile
        for cell, tile in cut_world(world_glb, grid, *prefixes).items()
        if tile.has_ground()
    }
    homeless = sum(place(tiles, grid, kind, trees.get(kind, [])) for kind in TREE_KINDS)
    homeless += sum(place(tiles, grid, kind, signs.get(kind, [])) for kind in SIGN_KINDS)
    tile_directory = directory / "tiles"
    tile_directory.mkdir(exist_ok=True)
    kept = {grid.key(cell) for cell in tiles}
    for stale in tile_directory.iterdir():
        if stale.name.split(".")[0] not in kept or stale.suffix != ".png":
            stale.unlink()
    index, heights = [], {}
    for cell, tile in sorted(tiles.items()):
        entry, measured_m, filled_m = write_tile(tile, grid, tile_directory, prefixes)
        key = entry["key"]
        entry["maps"] = [
            kind
            for kind in ("track", "roads", "lots")
            if (tile_directory / f"{key}.{kind}.png").exists()
        ]
        index.append(entry)
        heights[cell] = (measured_m, filled_m)
        photo = photo_rgb[mosaic.pack_tile_window(grid.map_corner(cell), 1.0 / mosaic.px_per_m)]
        Image.fromarray(photo).save(
            tile_directory / f"{key}.photo.jpg", quality=PHOTO_JPEG_QUALITY, subsampling=0
        )
    (directory / "tiles.json").write_text(
        json.dumps({"tile_size_m": tile_m, "ground_step_m": GROUND_STEP_M, "tiles": index})
    )
    write_far(directory, grid, heights, mosaic, photo_rgb)
    return homeless
