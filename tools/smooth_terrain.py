"""Write a world glb whose terrain is one smooth, seamless surface.

The experiment's world.glb carries its ground as `Terrain_*` tiles that are flat shaded (every
quad has its own vertices and its face's normal), leave an open strip between some tiles and
sample the LiDAR ground almost unfiltered. This tool rebuilds those tiles from the LiDAR ground
model: gaps and spikes are filled by interpolation, the heights are low-passed before they are
sampled on the tiles' lattice, the ground is pulled just under the `Road_*` meshes and blended
back over a band beyond their edge, and every tile takes its heights and normals from one
lattice, so neighbours agree along their common edge. Everything else in the glb is copied
byte for byte.

    python3 tools/smooth_terrain.py SOURCE_GLB OUT_GLB HEIGHT_MAP_TIF FRAME_JSON

Needs numpy and Pillow (which reads the float32 GeoTIFF and its georeference tags).
"""

import argparse
import json
import mmap
import os
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

TERRAIN_MESH_PREFIX = "Terrain_"
ROAD_MESH_PREFIX = "Road_"

LOW_PASS_SIGMA_M = 1.0
LEVEL_SIGMA_M = 4.0
LEVEL_EDGE_M = 2.0
SPIKE_HEIGHT_M = 0.75
GAP_RELAXATION_PASSES = 200
GAP_RELAXATION_WEIGHT = 0.8

ROAD_SINK_M = 0.08
ROAD_EDGE_SINK_M = 0.03
ROAD_SINK_DEPTH_M = 1.5
ROAD_CLEARANCE_M = 0.01
SHOULDER_WIDTH_M = 1.2
EDGE_BAND_M = 6.0
ROAD_EDGE_SPACING_M = 0.25
WELD_TOLERANCE_M = 0.001

GLB_MAGIC = 0x46546C67
GLB_JSON_CHUNK = 0x4E4F534A
GLB_BINARY_CHUNK = 0x004E4942
GLTF_FLOAT = 5126
GLTF_UNSIGNED_INT = 5125
GLTF_COMPONENT_TYPES = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
GLTF_COMPONENT_COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}
TIFF_PIXEL_SCALE_TAG = 33550
TIFF_TIEPOINT_TAG = 33922
TIFF_NODATA_TAG = 42113


# ---------------------------------------------------------------------------- height rasters
def fill_gaps(heights_m, is_valid):
    """Return the heights with every invalid cell interpolated from the valid ones around it."""
    if is_valid.all():
        return heights_m.astype(np.float64)
    if not is_valid.any():
        raise ValueError("a height map without one valid cell cannot be filled")
    weights = is_valid.astype(np.float64)
    coarse_guess = _pyramid_filled(np.where(is_valid, heights_m, 0.0) * weights, weights)
    filled = np.where(is_valid, heights_m, coarse_guess).astype(np.float64)
    gap_rows, gap_columns = np.nonzero(~is_valid)
    row_slice = slice(max(gap_rows.min() - 1, 0), gap_rows.max() + 2)
    column_slice = slice(max(gap_columns.min() - 1, 0), gap_columns.max() + 2)
    window = filled[row_slice, column_slice]
    is_gap = ~is_valid[row_slice, column_slice]
    # Relaxing towards the neighbours' mean makes the fill harmonic: a gap in a plane becomes
    # that plane, and a filled cell never leaves the range of the heights around the gap.
    for _ in range(GAP_RELAXATION_PASSES):
        padded = np.pad(window, 1, mode="edge")
        neighbour_mean = 0.25 * (
            padded[:-2, 1:-1] + padded[2:, 1:-1] + padded[1:-1, :-2] + padded[1:-1, 2:]
        )
        window[is_gap] += GAP_RELAXATION_WEIGHT * (neighbour_mean[is_gap] - window[is_gap])
    return filled


def _pyramid_filled(weighted_sums, weights):
    """Return the weighted mean per cell, taken from coarser levels where a cell has no weight."""
    has_weight = weights > 0
    own_mean = weighted_sums / np.where(has_weight, weights, 1.0)
    if has_weight.all():
        return own_mean
    row_count, column_count = weights.shape
    pad = ((0, row_count % 2), (0, column_count % 2))

    def halved(cells):
        padded = np.pad(cells, pad)
        return padded[0::2, 0::2] + padded[1::2, 0::2] + padded[0::2, 1::2] + padded[1::2, 1::2]

    coarse = _pyramid_filled(halved(weighted_sums), halved(weights))
    upsampled = np.repeat(np.repeat(coarse, 2, axis=0), 2, axis=1)[:row_count, :column_count]
    return np.where(has_weight, own_mean, upsampled)


def spike_mask(heights_m, spike_height_m):
    """Return where a cell stands further than spike_height_m from its neighbours' median."""
    padded = np.pad(heights_m, 1, mode="edge")
    row_count, column_count = heights_m.shape
    neighbours = np.stack(
        [
            padded[row : row + row_count, column : column + column_count]
            for row in range(3)
            for column in range(3)
            if (row, column) != (1, 1)
        ]
    )
    neighbours.sort(axis=0)
    median = 0.5 * (neighbours[3] + neighbours[4])
    return np.abs(heights_m - median) > spike_height_m


def low_passed(heights_m, sigma_cells):
    """Return the heights after a Gaussian low-pass that leaves a plane as it is."""
    radius = int(np.ceil(3.0 * sigma_cells))
    offsets = np.arange(-radius, radius + 1)
    kernel = np.exp(-0.5 * (offsets / sigma_cells) ** 2)
    kernel /= kernel.sum()
    smoothed = heights_m.astype(np.float64)
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (radius, radius)
        # Odd reflection continues a slope past the border instead of flattening it.
        padded = np.pad(smoothed, pad, mode="reflect", reflect_type="odd")
        length = smoothed.shape[axis]
        smoothed = sum(
            weight * np.take(padded, np.arange(start, start + length), axis=axis)
            for start, weight in enumerate(kernel)
        )
    return smoothed


def sample_bilinear(heights_m, rows, columns):
    """Return the heights at fractional cell-centre coordinates.

    Up to one cell beyond the outer cell centres the raster's slope continues.
    """
    rows = np.clip(rows, -1.0, heights_m.shape[0])
    columns = np.clip(columns, -1.0, heights_m.shape[1])
    row_low = np.clip(np.floor(rows).astype(np.int64), 0, heights_m.shape[0] - 2)
    column_low = np.clip(np.floor(columns).astype(np.int64), 0, heights_m.shape[1] - 2)
    row_weight = rows - row_low
    column_weight = columns - column_low
    upper = (
        heights_m[row_low, column_low] * (1 - column_weight)
        + heights_m[row_low, column_low + 1] * column_weight
    )
    lower = (
        heights_m[row_low + 1, column_low] * (1 - column_weight)
        + heights_m[row_low + 1, column_low + 1] * column_weight
    )
    return upper * (1 - row_weight) + lower * row_weight


def smooth_ground(heights_m, is_valid, cell_m):
    """Return the ground raster without gaps or spikes, low-passed."""
    filled = fill_gaps(heights_m, is_valid)
    despiked = fill_gaps(filled, ~spike_mask(filled, SPIKE_HEIGHT_M))
    return low_passed(despiked, LOW_PASS_SIGMA_M / cell_m)


def levelled(heights_m, cell_m, west_m, north_m, outlines):
    """Return the heights with the ground inside `outlines` evened out.

    A parking lot is graded: what the LiDAR shows of kerbs, parked cars and their gaps on it
    is not its surface. Inside each outline (points east, north, as `west_m` and `north_m`)
    the heights give way to their low-pass over LEVEL_SIGMA_M, eased in over LEVEL_EDGE_M.
    """
    if not outlines:
        return heights_m
    inside = Image.new("L", (heights_m.shape[1], heights_m.shape[0]), 0)
    pen = ImageDraw.Draw(inside)
    for outline in outlines:
        pen.polygon(
            [((east - west_m) / cell_m, (north_m - north) / cell_m) for east, north in outline],
            fill=255,
        )
    eased = inside.filter(ImageFilter.MinFilter(2 * round(LEVEL_EDGE_M / cell_m) + 1)).filter(
        ImageFilter.GaussianBlur(LEVEL_EDGE_M / cell_m / 2.0)
    )
    share = np.asarray(eased, np.float64) / 255.0
    return heights_m + share * (low_passed(heights_m, LEVEL_SIGMA_M / cell_m) - heights_m)


def read_height_map(tif_path):
    """Return a GeoTIFF's heights, validity mask, west edge, north edge and cell size."""
    Image.MAX_IMAGE_PIXELS = None
    with Image.open(tif_path) as image:
        heights_m = np.array(image, dtype=np.float64)
        tags = image.tag_v2
        cell_m = float(tags[TIFF_PIXEL_SCALE_TAG][0])
        tiepoint = tags[TIFF_TIEPOINT_TAG]
        is_valid = np.isfinite(heights_m)
        if TIFF_NODATA_TAG in tags:
            is_valid &= heights_m != float(tags[TIFF_NODATA_TAG])
    if tiepoint[0] != 0 or tiepoint[1] != 0:
        raise ValueError(f"{tif_path}: the tiepoint is not the raster's upper-left corner")
    return heights_m, is_valid, float(tiepoint[3]), float(tiepoint[4]), cell_m


def height_map_bounds(tif_path):
    """Return the (west, south, east, north) edges of a GeoTIFF, without reading its heights."""
    Image.MAX_IMAGE_PIXELS = None
    with Image.open(tif_path) as image:
        cell_m = float(image.tag_v2[TIFF_PIXEL_SCALE_TAG][0])
        west_m, north_m = (float(edge) for edge in image.tag_v2[TIFF_TIEPOINT_TAG][3:5])
        return west_m, north_m - cell_m * image.height, west_m + cell_m * image.width, north_m


# ---------------------------------------------------------------------------------- lattice
class Lattice:
    """The terrain's vertex positions: a regular grid in Godot x (east) and z (south)."""

    def __init__(self, first_x_m, first_z_m, step_m, column_count, row_count):
        """Hold the first vertex, the spacing and the vertex counts."""
        self.step_m = step_m
        self.xs_m = first_x_m + step_m * np.arange(column_count)
        self.zs_m = first_z_m + step_m * np.arange(row_count)
        self.shape = (row_count, column_count)

    def index_span(self, low_m, high_m, coordinates_m):
        """Return the slice of the lattice coordinates lying within [low_m, high_m]."""
        tolerance_m = 1e-3
        inside = np.nonzero(
            (coordinates_m >= low_m - tolerance_m) & (coordinates_m <= high_m + tolerance_m)
        )[0]
        return slice(int(inside[0]), int(inside[-1]) + 1)


def heights_under_triangles(triangles_m, lattice):
    """Return the triangles' height at each lattice vertex they cover, NaN elsewhere."""
    heights_m = np.full(lattice.shape, np.nan)
    corner_x = triangles_m[:, :, 0]
    corner_z = triangles_m[:, :, 2]
    first_column = np.ceil((corner_x.min(axis=1) - lattice.xs_m[0]) / lattice.step_m).astype(int)
    last_column = np.floor((corner_x.max(axis=1) - lattice.xs_m[0]) / lattice.step_m).astype(int)
    first_row = np.ceil((corner_z.min(axis=1) - lattice.zs_m[0]) / lattice.step_m).astype(int)
    last_row = np.floor((corner_z.max(axis=1) - lattice.zs_m[0]) / lattice.step_m).astype(int)
    edge_1 = triangles_m[:, 1] - triangles_m[:, 0]
    edge_2 = triangles_m[:, 2] - triangles_m[:, 0]
    doubled_area = edge_1[:, 0] * edge_2[:, 2] - edge_1[:, 2] * edge_2[:, 0]
    tolerance = 1e-6
    for row_offset in range(int((last_row - first_row).max()) + 1):
        for column_offset in range(int((last_column - first_column).max()) + 1):
            rows = first_row + row_offset
            columns = first_column + column_offset
            candidates = np.nonzero(
                (rows <= last_row)
                & (columns <= last_column)
                & (rows >= 0)
                & (rows < lattice.shape[0])
                & (columns >= 0)
                & (columns < lattice.shape[1])
                & (np.abs(doubled_area) > tolerance)
            )[0]
            from_corner_x = lattice.xs_m[columns[candidates]] - triangles_m[candidates, 0, 0]
            from_corner_z = lattice.zs_m[rows[candidates]] - triangles_m[candidates, 0, 2]
            weight_1 = (
                from_corner_x * edge_2[candidates, 2] - from_corner_z * edge_2[candidates, 0]
            ) / doubled_area[candidates]
            weight_2 = (
                edge_1[candidates, 0] * from_corner_z - edge_1[candidates, 2] * from_corner_x
            ) / doubled_area[candidates]
            covered = (
                (weight_1 >= -tolerance)
                & (weight_2 >= -tolerance)
                & (weight_1 + weight_2 <= 1 + tolerance)
            )
            hit = candidates[covered]
            heights_m[rows[hit], columns[hit]] = (
                triangles_m[hit, 0, 1]
                + weight_1[covered] * edge_1[hit, 1]
                + weight_2[covered] * edge_2[hit, 1]
            )
    return heights_m


def boundary_points(triangles_m, spacing_m):
    """Return points at most spacing_m apart along the edges only one triangle uses."""
    corners = triangles_m.reshape(-1, 3)
    welded = np.round(corners[:, [0, 2]] / WELD_TOLERANCE_M).astype(np.int64)
    _, first_corner, vertex_ids = np.unique(welded, axis=0, return_index=True, return_inverse=True)
    vertex_ids = vertex_ids.reshape(-1, 3)
    edges = np.concatenate([vertex_ids[:, [0, 1]], vertex_ids[:, [1, 2]], vertex_ids[:, [2, 0]]])
    edges.sort(axis=1)
    edges = edges[edges[:, 0] != edges[:, 1]]
    unique_edges, use_counts = np.unique(edges, axis=0, return_counts=True)
    boundary = unique_edges[use_counts == 1]
    starts = corners[first_corner[boundary[:, 0]]]
    ends = corners[first_corner[boundary[:, 1]]]
    lengths_m = np.hypot(ends[:, 0] - starts[:, 0], ends[:, 2] - starts[:, 2])
    piece_counts = np.maximum(np.ceil(lengths_m / spacing_m).astype(int), 1)
    points = []
    for piece_count in np.unique(piece_counts):
        chosen = piece_counts == piece_count
        for fraction in np.arange(piece_count + 1) / piece_count:
            points.append(starts[chosen] + fraction * (ends[chosen] - starts[chosen]))
    return np.concatenate(points) if points else np.zeros((0, 3))


def nearest_points(points_m, lattice, radius_m):
    """Return each lattice vertex's distance to its nearest point and that point's height.

    Vertices with no point within radius_m get an infinite distance and a NaN height.
    """
    distances_m = np.full(lattice.shape, np.inf)
    nearest_heights_m = np.full(lattice.shape, np.nan)
    columns = np.round((points_m[:, 0] - lattice.xs_m[0]) / lattice.step_m).astype(int)
    rows = np.round((points_m[:, 2] - lattice.zs_m[0]) / lattice.step_m).astype(int)
    reach = int(np.ceil(radius_m / lattice.step_m)) + 1
    for row_offset in range(-reach, reach + 1):
        for column_offset in range(-reach, reach + 1):
            vertex_rows = rows + row_offset
            vertex_columns = columns + column_offset
            on_lattice = np.nonzero(
                (vertex_rows >= 0)
                & (vertex_rows < lattice.shape[0])
                & (vertex_columns >= 0)
                & (vertex_columns < lattice.shape[1])
            )[0]
            vertex_rows = vertex_rows[on_lattice]
            vertex_columns = vertex_columns[on_lattice]
            candidate_m = np.hypot(
                lattice.xs_m[vertex_columns] - points_m[on_lattice, 0],
                lattice.zs_m[vertex_rows] - points_m[on_lattice, 2],
            )
            # A repeated index keeps its last assignment: the nearest point goes last.
            order = np.argsort(-candidate_m, kind="stable")
            order = order[candidate_m[order] <= radius_m]
            vertex_rows, vertex_columns = vertex_rows[order], vertex_columns[order]
            closer = candidate_m[order] < distances_m[vertex_rows, vertex_columns]
            vertex_rows, vertex_columns = vertex_rows[closer], vertex_columns[closer]
            distances_m[vertex_rows, vertex_columns] = candidate_m[order][closer]
            nearest_heights_m[vertex_rows, vertex_columns] = points_m[on_lattice[order], 1][closer]
    return distances_m, nearest_heights_m


def ground_under_road(ground_m, road_triangles_m, lattice):
    """Return the ground pulled just under the road and blended back beyond its edge."""
    if len(road_triangles_m) == 0:
        return ground_m.copy()
    road_m = heights_under_triangles(road_triangles_m, lattice)
    edge_distance_m, edge_m = nearest_points(
        boundary_points(road_triangles_m, ROAD_EDGE_SPACING_M), lattice, EDGE_BAND_M
    )
    under_road = np.isfinite(road_m)
    in_band = np.isfinite(edge_distance_m) & ~under_road
    blend = np.clip(
        (edge_distance_m[in_band] - SHOULDER_WIDTH_M) / (EDGE_BAND_M - SHOULDER_WIDTH_M), 0.0, 1.0
    )
    blend = blend * blend * (3 - 2 * blend)
    conformed_m = ground_m.copy()
    conformed_m[in_band] = (edge_m[in_band] - ROAD_EDGE_SINK_M) * (1 - blend) + ground_m[
        in_band
    ] * blend
    # The sink grows inwards from the edge: the ground meets the road's border closely and
    # still clears the road's own curvature between the terrain's coarser vertices.
    depth = np.clip(edge_distance_m[under_road] / ROAD_SINK_DEPTH_M, 0.0, 1.0)
    conformed_m[under_road] = road_m[under_road] - (
        ROAD_EDGE_SINK_M + (ROAD_SINK_M - ROAD_EDGE_SINK_M) * depth
    )
    return lowered_under_points(conformed_m, lattice, road_triangles_m.reshape(-1, 3))


def lowered_under_points(heights_m, lattice, points_m):
    """Return the heights with each lattice quad lowered until it clears the points over it.

    A quad's surface is taken as the higher of its two diagonal splits.
    """
    column_position = (points_m[:, 0] - lattice.xs_m[0]) / lattice.step_m
    row_position = (points_m[:, 2] - lattice.zs_m[0]) / lattice.step_m
    over_lattice = (
        (column_position >= 0)
        & (column_position <= lattice.shape[1] - 1)
        & (row_position >= 0)
        & (row_position <= lattice.shape[0] - 1)
    )
    column_position, row_position = column_position[over_lattice], row_position[over_lattice]
    columns = np.minimum(column_position.astype(int), lattice.shape[1] - 2)
    rows = np.minimum(row_position.astype(int), lattice.shape[0] - 2)
    east = column_position - columns
    south = row_position - rows
    near_west, near_east = heights_m[rows, columns], heights_m[rows, columns + 1]
    far_west, far_east = heights_m[rows + 1, columns], heights_m[rows + 1, columns + 1]
    split_west_to_east = np.where(
        east >= south,
        near_west + east * (near_east - near_west) + south * (far_east - near_east),
        near_west + south * (far_west - near_west) + east * (far_east - far_west),
    )
    split_east_to_west = np.where(
        east + south <= 1,
        near_west + east * (near_east - near_west) + south * (far_west - near_west),
        far_east + (1 - east) * (far_west - far_east) + (1 - south) * (near_east - far_east),
    )
    surface_m = np.maximum(split_west_to_east, split_east_to_west)
    excess_m = np.maximum(surface_m - (points_m[over_lattice, 1] - ROAD_CLEARANCE_M), 0.0)
    lowering_m = np.zeros(lattice.shape)
    for row_offset in (0, 1):
        for column_offset in (0, 1):
            np.maximum.at(lowering_m, (rows + row_offset, columns + column_offset), excess_m)
    return heights_m - lowering_m


def lattice_normals(heights_m, step_m):
    """Return the unit normal at each lattice vertex, in Godot's x, y (up), z."""
    slope_z, slope_x = np.gradient(heights_m, step_m)
    normals = np.stack([-slope_x, np.ones_like(heights_m), -slope_z], axis=-1)
    return normals / np.linalg.norm(normals, axis=-1, keepdims=True)


def grid_triangles(heights_m):
    """Return a height grid's triangles as indices into its row-major vertices, facing up.

    Each quad is split along the diagonal whose ends differ least in height, so the split
    follows the contour lines instead of cutting ridges across a bank.
    """
    row_count, column_count = heights_m.shape
    vertex = np.arange(row_count * column_count).reshape(row_count, column_count)
    near_west, near_east = vertex[:-1, :-1], vertex[:-1, 1:]
    far_west, far_east = vertex[1:, :-1], vertex[1:, 1:]
    split_west_to_east = np.abs(heights_m[:-1, :-1] - heights_m[1:, 1:]) < np.abs(
        heights_m[:-1, 1:] - heights_m[1:, :-1]
    )
    first = np.where(
        split_west_to_east[..., None],
        np.stack([near_west, far_west, far_east], axis=-1),
        np.stack([near_west, far_west, near_east], axis=-1),
    )
    second = np.where(
        split_west_to_east[..., None],
        np.stack([near_west, far_east, near_east], axis=-1),
        np.stack([near_east, far_west, far_east], axis=-1),
    )
    return np.concatenate([first.reshape(-1, 3), second.reshape(-1, 3)]).astype(np.uint32)


# -------------------------------------------------------------------------------------- glb
def read_glb(glb_path):
    """Return a glb's JSON as a dict and its binary chunk as a read-only memory map."""
    with open(glb_path, "rb") as glb_file:
        mapped = mmap.mmap(glb_file.fileno(), 0, access=mmap.ACCESS_READ)
    magic, version, _ = struct.unpack_from("<III", mapped, 0)
    json_length, json_kind = struct.unpack_from("<II", mapped, 12)
    if magic != GLB_MAGIC or version != 2 or json_kind != GLB_JSON_CHUNK:
        raise ValueError(f"{glb_path} is not a glTF 2 binary file")
    gltf = json.loads(bytes(mapped[20 : 20 + json_length]))
    binary_start = 20 + json_length
    binary_length, binary_kind = struct.unpack_from("<II", mapped, binary_start)
    if binary_kind != GLB_BINARY_CHUNK or len(gltf["buffers"]) != 1:
        raise ValueError(f"{glb_path} must hold exactly one embedded buffer")
    return gltf, memoryview(mapped)[binary_start + 8 : binary_start + 8 + binary_length]


def write_glb(glb_path, gltf, binary, replaced_views):
    """Write the glb with its buffer views repacked, taking replaced_views' bytes by index."""
    gltf = json.loads(json.dumps(gltf))
    contents = []
    binary_length = 0
    for view_index, view in enumerate(gltf["bufferViews"]):
        if view_index in replaced_views:
            content = replaced_views[view_index]
        else:
            start = view.get("byteOffset", 0)
            content = binary[start : start + view["byteLength"]]
        view["byteOffset"] = binary_length
        view["byteLength"] = len(content)
        padding = -len(content) % 4
        contents.append((content, padding))
        binary_length += len(content) + padding
    gltf["buffers"][0]["byteLength"] = binary_length
    json_text = json.dumps(gltf, separators=(",", ":")).encode()
    json_text += b" " * (-len(json_text) % 4)
    # Written beside the target and moved over it: a symlink there is replaced, not followed.
    partial_path = glb_path.with_name(glb_path.name + ".partial")
    with open(partial_path, "wb") as glb_file:
        glb_file.write(
            struct.pack("<III", GLB_MAGIC, 2, 12 + 8 + len(json_text) + 8 + binary_length)
        )
        glb_file.write(struct.pack("<II", len(json_text), GLB_JSON_CHUNK))
        glb_file.write(json_text)
        glb_file.write(struct.pack("<II", binary_length, GLB_BINARY_CHUNK))
        for content, padding in contents:
            glb_file.write(content)
            glb_file.write(b"\0" * padding)
    os.replace(partial_path, glb_path)


def accessor_array(gltf, binary, accessor_index):
    """Return an accessor's elements as a (count, components) array."""
    accessor = gltf["accessors"][accessor_index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    if "byteStride" in view or "sparse" in accessor:
        raise ValueError(f"accessor {accessor_index}: interleaved and sparse data are not read")
    component_count = GLTF_COMPONENT_COUNTS[accessor["type"]]
    return np.frombuffer(
        binary,
        dtype=GLTF_COMPONENT_TYPES[accessor["componentType"]],
        count=accessor["count"] * component_count,
        offset=view.get("byteOffset", 0) + accessor.get("byteOffset", 0),
    ).reshape(-1, component_count)


def meshes_named(gltf, prefix):
    """Return the meshes whose name starts with prefix, refusing ones a node transforms."""
    meshes = []
    for node in gltf["nodes"]:
        if "mesh" not in node or not gltf["meshes"][node["mesh"]]["name"].startswith(prefix):
            continue
        if any(key in node for key in ("matrix", "translation", "rotation", "scale")):
            raise ValueError(f"node {node['name']} is transformed: its mesh is not in world space")
        meshes.append(gltf["meshes"][node["mesh"]])
    return meshes


def mesh_triangles(gltf, binary, meshes):
    """Return the meshes' triangles as a (count, 3 corners, 3 coordinates) array."""
    triangles = [np.zeros((0, 3, 3))]
    for mesh in meshes:
        for primitive in mesh["primitives"]:
            positions = accessor_array(gltf, binary, primitive["attributes"]["POSITION"])
            indices = accessor_array(gltf, binary, primitive["indices"]).reshape(-1, 3)
            triangles.append(positions[indices].astype(np.float64))
    return np.concatenate(triangles)


def _texture_axis(coordinates_m, texture_coordinates):
    """Return where a texture coordinate linear in the coordinates is 0, and its rate per metre."""
    low, high = np.argmin(coordinates_m), np.argmax(coordinates_m)
    per_metre = (texture_coordinates[high] - texture_coordinates[low]) / (
        coordinates_m[high] - coordinates_m[low]
    )
    return float(coordinates_m[low] - texture_coordinates[low] / per_metre), float(per_metre)


class TerrainTile:
    """One terrain mesh: the ground it textures and how its texture maps onto it."""

    def __init__(self, gltf, binary, mesh):
        """Read the tile's extent and texture mapping from its mesh."""
        if len(mesh["primitives"]) != 1 or set(mesh["primitives"][0]["attributes"]) != {
            "POSITION",
            "NORMAL",
            "TEXCOORD_0",
        }:
            raise ValueError(f"{mesh['name']}: expected one primitive with position, normal, uv")
        self.name = mesh["name"]
        self.primitive = mesh["primitives"][0]
        positions = accessor_array(gltf, binary, self.primitive["attributes"]["POSITION"])
        uvs = accessor_array(gltf, binary, self.primitive["attributes"]["TEXCOORD_0"])
        self.u_origin_m, self.u_per_m = _texture_axis(positions[:, 0], uvs[:, 0])
        self.v_origin_m, self.v_per_m = _texture_axis(positions[:, 2], uvs[:, 1])
        self.x_span_m = sorted((self.u_origin_m, self.u_origin_m + 1.0 / self.u_per_m))
        self.z_span_m = sorted((self.v_origin_m, self.v_origin_m + 1.0 / self.v_per_m))
        distinct_x_m = np.unique(positions[:, 0])
        self.step_m = float(np.diff(distinct_x_m).min())

    def uvs(self, xs_m, zs_m):
        """Return the texture coordinates of the vertices at xs_m by zs_m, row-major."""
        grid_u, grid_v = np.meshgrid(
            (xs_m - self.u_origin_m) * self.u_per_m, (zs_m - self.v_origin_m) * self.v_per_m
        )
        return np.stack([grid_u.ravel(), grid_v.ravel()], axis=-1)


def terrain_lattice(tiles, west_m, east_m, north_z_m, south_z_m):
    """Return the lattice all tiles share: their texture edges are on it, within the bounds."""
    step_m = tiles[0].step_m
    anchor_x_m = tiles[0].x_span_m[0]
    anchor_z_m = tiles[0].z_span_m[0]
    for tile in tiles:
        off_lattice_m = [
            abs((edge_m - anchor_m + step_m / 2) % step_m - step_m / 2)
            for edge_m, anchor_m in [
                (tile.x_span_m[0], anchor_x_m),
                (tile.x_span_m[1], anchor_x_m),
                (tile.z_span_m[0], anchor_z_m),
                (tile.z_span_m[1], anchor_z_m),
            ]
        ]
        if tile.step_m != step_m or max(off_lattice_m) > 1e-2:
            raise ValueError(f"{tile.name} does not fit a {step_m} m lattice with the other tiles")
    first_x_m = anchor_x_m + step_m * np.ceil((west_m - anchor_x_m) / step_m - 1e-6)
    first_z_m = anchor_z_m + step_m * np.ceil((north_z_m - anchor_z_m) / step_m - 1e-6)
    column_count = int(np.floor((east_m - first_x_m) / step_m + 1e-6)) + 1
    row_count = int(np.floor((south_z_m - first_z_m) / step_m + 1e-6)) + 1
    return Lattice(first_x_m, first_z_m, step_m, column_count, row_count)


def _replace_accessor(gltf, replaced_views, view_users, accessor_index, elements):
    """Queue an accessor's new elements and update its count, type and bounds."""
    accessor = gltf["accessors"][accessor_index]
    if view_users[accessor["bufferView"]] != 1 or accessor.get("byteOffset", 0) != 0:
        raise ValueError(f"accessor {accessor_index} shares its buffer view")
    replaced_views[accessor["bufferView"]] = elements.tobytes()
    accessor["count"] = len(elements)
    if elements.dtype == np.uint32:
        accessor["componentType"] = GLTF_UNSIGNED_INT
    if "min" in accessor:
        accessor["min"] = [float(bound) for bound in elements.min(axis=0)]
        accessor["max"] = [float(bound) for bound in elements.max(axis=0)]


def write_smoothed_world(source_glb, out_glb, height_map_tif, origin_m, level_outlines=()):
    """Write source_glb to out_glb with its terrain rebuilt smooth from the LiDAR ground.

    origin_m is the world's origin (east, north, height) in the height map's coordinates:
    Godot x = east - origin, y = height - origin, z = -(north - origin). The ground inside
    each of `level_outlines` (points east, north of the origin) is evened out. Returns the
    terrain's height at positions east and north of the origin, as a function of both.
    """
    gltf, binary = read_glb(source_glb)
    tiles = [TerrainTile(gltf, binary, mesh) for mesh in meshes_named(gltf, TERRAIN_MESH_PREFIX)]
    if not tiles:
        raise ValueError(f"{source_glb} has no {TERRAIN_MESH_PREFIX}* mesh")
    raster_m, is_valid, raster_west_m, raster_north_m, cell_m = read_height_map(height_map_tif)
    raster_m = smooth_ground(raster_m, is_valid, cell_m)
    origin_east_m, origin_north_m, origin_height_m = origin_m
    raster_m = levelled(
        raster_m,
        cell_m,
        raster_west_m - origin_east_m,
        raster_north_m - origin_north_m,
        level_outlines,
    )
    west_m = raster_west_m - origin_east_m
    north_z_m = -(raster_north_m - origin_north_m)
    lattice = terrain_lattice(
        tiles,
        west_m,
        west_m + cell_m * raster_m.shape[1],
        north_z_m,
        north_z_m + cell_m * raster_m.shape[0],
    )
    grid_x_m, grid_z_m = np.meshgrid(lattice.xs_m, lattice.zs_m)
    lidar_m = (
        sample_bilinear(
            raster_m, (grid_z_m - north_z_m) / cell_m - 0.5, (grid_x_m - west_m) / cell_m - 0.5
        )
        - origin_height_m
    )
    road_triangles_m = mesh_triangles(gltf, binary, meshes_named(gltf, ROAD_MESH_PREFIX))
    heights_m = ground_under_road(lidar_m, road_triangles_m, lattice)
    normals = lattice_normals(heights_m, lattice.step_m)

    view_users = np.bincount(
        [accessor["bufferView"] for accessor in gltf["accessors"]]
        + [image["bufferView"] for image in gltf.get("images", []) if "bufferView" in image],
        minlength=len(gltf["bufferViews"]),
    )
    replaced_views = {}
    for tile in tiles:
        columns = lattice.index_span(*tile.x_span_m, lattice.xs_m)
        rows = lattice.index_span(*tile.z_span_m, lattice.zs_m)
        tile_heights_m = heights_m[rows, columns]
        tile_x_m, tile_z_m = np.meshgrid(lattice.xs_m[columns], lattice.zs_m[rows])
        positions = np.stack([tile_x_m.ravel(), tile_heights_m.ravel(), tile_z_m.ravel()], axis=-1)
        attributes = tile.primitive["attributes"]
        for accessor_index, elements in [
            (attributes["POSITION"], positions.astype(np.float32)),
            (attributes["NORMAL"], normals[rows, columns].reshape(-1, 3).astype(np.float32)),
            (
                attributes["TEXCOORD_0"],
                tile.uvs(lattice.xs_m[columns], lattice.zs_m[rows]).astype(np.float32),
            ),
            (tile.primitive["indices"], grid_triangles(tile_heights_m).reshape(-1, 1)),
        ]:
            _replace_accessor(gltf, replaced_views, view_users, accessor_index, elements)
    write_glb(out_glb, gltf, binary, replaced_views)

    def height_m(east_m, north_m):
        rows = (-np.asarray(north_m, np.float64) - lattice.zs_m[0]) / lattice.step_m
        columns = (np.asarray(east_m, np.float64) - lattice.xs_m[0]) / lattice.step_m
        return sample_bilinear(heights_m, rows, columns)

    return height_m


def main():
    """Smooth the terrain of the glb named on the command line."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source_glb", type=Path)
    parser.add_argument("out_glb", type=Path)
    parser.add_argument("height_map_tif", type=Path, help="LiDAR ground model, a GeoTIFF")
    parser.add_argument("frame_json", type=Path, help='holds the world\'s "origin"')
    arguments = parser.parse_args()
    origin_m = json.loads(arguments.frame_json.read_text())["origin"]
    arguments.out_glb.parent.mkdir(parents=True, exist_ok=True)
    write_smoothed_world(
        arguments.source_glb, arguments.out_glb, arguments.height_map_tif, origin_m
    )


if __name__ == "__main__":
    main()
