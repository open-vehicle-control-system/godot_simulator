"""Roof shapes over a footprint, their fit to the LiDAR, and the closed mesh of a building.

A roof shape is a set of triangles covering the footprint exactly, with a rise at each of
their points: flat, a skillion (one plane), a gable, a hip (the footprint's straight
skeleton) or a pyramid. `fitted` chooses the shape, the eave height and the slope that the
LiDAR's roof points show. `shell` hangs a wall under every edge of the roof's outline, down
to a floor below the ground: walls, roof and floor share their edges, so the building is
closed whatever its shape, and a gable's ends are walls. `faults` tells what is wrong with a
mesh that is not closed.

Positions are (metres east, north, up). Needs numpy.
"""

import math
from dataclasses import dataclass

import footprints
import numpy as np
import straight_skeleton

SKIRT_M = 0.5  # how far below the lowest ground under a building its walls hang
GROUND_SAMPLE_M = 1.0
FACADE_UV_M = 3.0  # a facade's texture coordinates are metres over this
FLOOR_STEP_M = 1.5  # how far above the lower end of a wall its ground floor may be
WALL_TURN_SIN = 0.02  # two edges of an outline turning less than this are one wall

FLAT_RISE_M = 0.6  # a roof rising less than this above its eaves is flat
MAX_SLOPE = 1.75  # a roof of about 60 degrees
SKILLION_MAX_RISE_M = 5.0  # a single pitch rising more is two roofs, or a roof under trees
ON_RIDGE_M = 0.01  # a point this close to a ridge line is on it
PYRAMID_MAX_ASPECT = 2.0
GABLE_END_MIN_SHARE = 0.1  # of an end wall's length: how far from its corners a ridge may end
GABLE_SIDES_COS = -0.5  # the walls beside a gable end run back from it, opposed
OUTLIER_M = 1.5  # a LiDAR point further than this from the fitted roof is a tree or a chimney
MISFIT_CAP_M = 2.0
# How much better (metres RMS) a shape must fit than a flat roof to be chosen over it.
PRIORS_M = {"flat": 0.0, "gable": 0.05, "hip": 0.08, "skillion": 0.08, "pyramid": 0.1}

FAR_FROM_EDGE_M = 100.0

WELD_M = 1e-4
MIN_DOUBLED_AREA_M2 = 1e-8


@dataclass
class Shape:
    """A roof shape: `points` (N, 2), their `rise` (N,) and `triangles` (M, 3), seen from above.

    The roof stands at eave height + slope x rise; a gable, a hip and a skillion rise one
    metre per metre, a pyramid one metre in all.
    """

    name: str
    points: np.ndarray
    rise: np.ndarray
    triangles: np.ndarray


@dataclass
class Fit:
    """A shape fitted to the LiDAR: its eave height, its slope and how far it stays off."""

    shape: Shape
    eave_m: float
    slope: float
    misfit_m: float

    def heights_m(self):
        """Return the roof's height at each of the shape's points."""
        return self.eave_m + self.slope * self.shape.rise


@dataclass
class Shell:
    """A building's closed mesh, as separate triangles (count, 3 corners, 3 coordinates).

    A wall's texture coordinates are (metres along the wall from its corner, 1 - metres above
    its ground floor) / FACADE_UV_M, then (the wall's top above its ground floor, its length).
    `roof_edges_m` is roof_edge_distances_m's, a pair per roof corner.
    """

    roof: np.ndarray
    roof_edges_m: np.ndarray
    walls: np.ndarray
    wall_uv: np.ndarray
    wall_uv2: np.ndarray
    floor: np.ndarray

    def triangles(self):
        """Return every triangle of the building."""
        return np.concatenate([self.roof, self.walls, self.floor])


# --------------------------------------------------------------------------------- shapes
def _axes(outline):
    """Return a footprint's middle, the unit vector along its length and the one across."""
    angle = footprints.main_direction_rad(outline)
    along = np.array([math.cos(angle), math.sin(angle)])
    across = np.array([-along[1], along[0]])
    if np.ptp(outline @ across) > np.ptp(outline @ along):
        along, across = across, -along
    middle = np.array(
        [(axis_m.min() + axis_m.max()) / 2.0 for axis_m in (outline @ along, outline @ across)]
    )
    return along * middle[0] + across * middle[1], along, across


def split_along(points, triangles, across_m):
    """Return (points, triangles, across_m) with the triangles cut where `across_m` is 0.

    No triangle crosses the line, so two slopes meet there in a crisp ridge; two triangles
    sharing a cut edge share the point added on it.
    """
    points = [tuple(point) for point in points]
    across = [0.0 if abs(distance_m) < ON_RIDGE_M else float(distance_m) for distance_m in across_m]
    cut = {}

    def crossing(first, second):
        key = (min(first, second), max(first, second))
        if key not in cut:
            share = across[key[0]] / (across[key[0]] - across[key[1]])
            start, end = np.array(points[key[0]]), np.array(points[key[1]])
            points.append(tuple(start + share * (end - start)))
            across.append(0.0)
            cut[key] = len(points) - 1
        return cut[key]

    kept = []
    for triangle in triangles:
        sides = [across[corner] for corner in triangle]
        if not (max(sides) > 0.0 and min(sides) < 0.0):
            kept.append(tuple(int(corner) for corner in triangle))
            continue
        # Walk the triangle's outline, adding a point wherever it crosses the line.
        outline = []
        for corner, following in zip(triangle, np.roll(triangle, -1), strict=True):
            outline.append(int(corner))
            if across[corner] * across[following] < 0.0:
                outline.append(crossing(int(corner), int(following)))
        for side in (1.0, -1.0):
            polygon = [corner for corner in outline if across[corner] * side >= 0.0]
            for index in range(1, len(polygon) - 1):
                kept.append((polygon[0], polygon[index], polygon[index + 1]))
    return np.array(points), np.array(kept, np.int64), np.array(across)


def _ridge_gable(points, triangles, middle, across):
    """Return the gable whose one ridge runs through `middle`, square to `across`."""
    across_m = (points - middle) @ across
    half_width_m = float(np.abs(across_m).max())
    points, triangles, across_m = split_along(points, triangles, across_m)
    return Shape("gable", points, half_width_m - np.abs(across_m), triangles)


def _skillion(points, triangles, uphill):
    rise = points @ uphill
    return Shape("skillion", points, rise - rise.min(), triangles)


def _pyramid(outline):
    """Return the pyramid over an outline every corner of which sees its middle, or None."""
    area_m2 = footprints.signed_area_m2(outline)
    following = np.roll(outline, -1, axis=0)
    weights = footprints.cross(outline, following)
    apex = ((outline + following) * weights[:, None]).sum(0) / (6.0 * area_m2)
    if footprints.cross(outline - apex, following - apex).min() < 1e-3 * area_m2:
        return None
    count = len(outline)
    triangles = [(index, (index + 1) % count, count) for index in range(count)]
    return Shape(
        "pyramid", np.vstack([outline, apex]), np.append(np.zeros(count), 1.0), np.array(triangles)
    )


def _face_triangles(points, faces):
    triangles = []
    for face in faces:
        triangles += footprints.ear_clipped(points, face)
    return np.array(triangles, np.int64)


def _gable_ends(skeleton, ring_edges):
    """Return a hip's (points, rise, faces) with its ridges run out to the end walls.

    An end wall is one whose hip is a triangle between two walls running back from it: the
    ridge behind the hip is continued to the wall, the hip gone, so the wall under it rises
    to the ridge. None when the roof has no such end.
    """
    points, rise = skeleton.points.copy(), skeleton.times.copy()
    faces = [list(face) for face in skeleton.faces]
    around = {}
    for face in faces:
        for node, following in zip(face, face[1:] + face[:1], strict=True):
            around.setdefault(node, set()).add(following)
            around.setdefault(following, set()).add(node)
    before_edge = {end: start for start, end in ring_edges}
    after_edge = {start: end for start, end in ring_edges}
    ended = False
    for index, face in enumerate(skeleton.faces):
        if len(face) != 3 or len(around[face[2]]) != 3:
            continue
        start, end, top = face
        (inner,) = around[top] - {start, end}
        side_before = points[start] - points[before_edge[start]]
        side_after = points[after_edge[end]] - points[end]
        cosine = float(side_before @ side_after) / float(
            np.hypot(*side_before) * np.hypot(*side_after)
        )
        if cosine > GABLE_SIDES_COS or rise[inner] < 0.5 * rise[top]:
            continue
        wall, ridge = points[end] - points[start], points[top] - points[inner]
        denominator = float(footprints.cross(ridge, wall))
        if abs(denominator) < 1e-9:
            continue
        share = float(footprints.cross(ridge, points[inner] - points[start])) / denominator
        if not GABLE_END_MIN_SHARE < share < 1.0 - GABLE_END_MIN_SHARE:
            continue
        reached = points[start] + share * wall
        further = float(np.hypot(*(reached - points[top])) / np.hypot(*ridge))
        rise[top] += (rise[top] - rise[inner]) * further
        points[top] = reached
        faces[index] = None
        ended = True
    if not ended:
        return None
    return points, rise, [face for face in faces if face is not None]


def _skeleton_shapes(outline, holes, ring_edges):
    """Return the hip over a footprint and the gable made of it, as far as they can be made."""
    try:
        skeleton = straight_skeleton.skeleton(outline, holes)
        hip = _face_triangles(skeleton.points, skeleton.faces)
    except (straight_skeleton.SkeletonError, footprints.FootprintError):
        return []
    is_pyramid = len(skeleton.points) == len(outline) + sum(len(hole) for hole in holes) + 1
    found = [Shape("pyramid" if is_pyramid else "hip", skeleton.points, skeleton.times, hip)]
    ends = _gable_ends(skeleton, ring_edges)
    if ends is not None:
        try:
            found.insert(0, Shape("gable", ends[0], ends[1], _face_triangles(ends[0], ends[2])))
        except footprints.FootprintError:
            pass
    return found


def shapes(outline, holes=()):
    """Return the roof shapes a footprint can carry, the flat one first.

    `outline` runs counter-clockwise and each courtyard of `holes` clockwise. A gable comes
    as the hip's ridges run out to the end walls, then as one ridge along the footprint's
    length, then across it; a skillion rises across, then along, either way.
    """
    points, triangles = footprints.triangulated(outline, holes)
    ring_edges, count = [], 0
    for ring in [outline, *holes]:
        ring_edges += [(count + at, count + (at + 1) % len(ring)) for at in range(len(ring))]
        count += len(ring)
    middle, along, across = _axes(outline)
    found = [Shape("flat", points, np.zeros(len(points)), triangles)]
    found += _skeleton_shapes(outline, holes, ring_edges)
    found += [_ridge_gable(points, triangles, middle, axis) for axis in (across, along)]
    found += [_skillion(points, triangles, uphill) for uphill in (across, -across, along, -along)]
    is_compact = np.ptp(outline @ along) <= PYRAMID_MAX_ASPECT * np.ptp(outline @ across)
    if not holes and is_compact and not any(shape.name == "pyramid" for shape in found):
        pyramid = _pyramid(outline)
        if pyramid is not None:
            found.append(pyramid)
    return found


# ------------------------------------------------------------------------------------ fit
def rise_at(shape, samples):
    """Return a shape's rise at each of `samples` (K, 2), NaN off the footprint."""
    rise = np.full(len(samples), np.nan)
    for triangle in shape.triangles:
        first, second, third = shape.points[triangle]
        edge_1, edge_2 = second - first, third - first
        doubled_area = float(footprints.cross(edge_1, edge_2))
        if abs(doubled_area) < MIN_DOUBLED_AREA_M2:
            continue
        offsets = samples - first
        weight_1 = footprints.cross(offsets, edge_2) / doubled_area
        weight_2 = footprints.cross(edge_1, offsets) / doubled_area
        covered = (weight_1 >= -1e-9) & (weight_2 >= -1e-9) & (weight_1 + weight_2 <= 1 + 1e-9)
        corner_rise = shape.rise[triangle]
        rise[covered] = (
            corner_rise[0]
            + weight_1[covered] * (corner_rise[1] - corner_rise[0])
            + weight_2[covered] * (corner_rise[2] - corner_rise[0])
        )
    return rise


def steepest(shape):
    """Return the steepest slope of a shape's triangles, per unit of rise."""
    corners = shape.points[shape.triangles]
    edge_1, edge_2 = corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0]
    rise_1 = shape.rise[shape.triangles[:, 1]] - shape.rise[shape.triangles[:, 0]]
    rise_2 = shape.rise[shape.triangles[:, 2]] - shape.rise[shape.triangles[:, 0]]
    doubled_area = np.maximum(footprints.cross(edge_1, edge_2), MIN_DOUBLED_AREA_M2)
    east = (rise_1 * edge_2[:, 1] - rise_2 * edge_1[:, 1]) / doubled_area
    north = (rise_2 * edge_1[:, 0] - rise_1 * edge_2[:, 0]) / doubled_area
    return float(np.hypot(east, north).max())


def _fit(shape, rise, heights_m):
    """Return the Fit of one shape to the LiDAR heights at the points where it rises `rise`."""
    if shape.name == "flat":
        eave_m, slope = float(np.median(heights_m)), 0.0
    else:
        kept = np.ones(len(rise), bool)
        limit = MAX_SLOPE / max(steepest(shape), 1e-9)
        if shape.name == "skillion":
            limit = min(limit, SKILLION_MAX_RISE_M / max(float(shape.rise.max()), 1e-9))
        for _ in range(3):
            spread = rise[kept] - rise[kept].mean()
            slope = float((spread * heights_m[kept]).sum() / max((spread**2).sum(), 1e-9))
            slope = min(max(slope, 0.0), limit)
            eave_m = float(np.median(heights_m[kept] - slope * rise[kept]))
            kept = np.abs(heights_m - eave_m - slope * rise) < OUTLIER_M
            if kept.sum() < 3:
                kept[:] = True
    off_m = np.minimum(np.abs(heights_m - eave_m - slope * rise), MISFIT_CAP_M)
    return Fit(shape, eave_m, slope, float(np.sqrt(np.mean(off_m**2))))


def fitted(candidates, samples, heights_m, named=None):
    """Return the Fit, among the shapes `candidates`, that the LiDAR shows best.

    `samples` (K, 2) are points on the roof and `heights_m` the LiDAR's height there. A
    shape must fit better than a simpler one by its prior, and a roof that hardly rises is
    flat. `named` is the shape the map gives the roof, the only one fitted then.
    """
    flat = _fit(candidates[0], np.zeros(len(samples)), heights_m)
    best = None
    for shape in candidates[1:]:
        if named not in (None, shape.name):
            continue
        fit = _fit(shape, rise_at(shape, samples), heights_m)
        if best is None or fit.misfit_m + PRIORS_M[shape.name] < (
            best.misfit_m + PRIORS_M[best.shape.name] - 1e-9
        ):
            best = fit
    if best is None or named == "flat":
        return flat
    if best.slope * float(best.shape.rise.max()) < FLAT_RISE_M:
        return flat
    if named is None and flat.misfit_m <= best.misfit_m + PRIORS_M[best.shape.name]:
        return flat
    return best


# ---------------------------------------------------------------------------------- shell
def outline_edges(triangles):
    """Return the directed edges (start, end) that only one triangle has."""
    edges = triangles[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2)
    opposite = {(int(end), int(start)) for start, end in edges}
    return [
        (int(start), int(end)) for start, end in edges if (int(start), int(end)) not in opposite
    ]


def _walls(points, edges):
    """Return an outline's walls: each a list of edges on one straight line, in order."""
    after = dict(edges)
    if len(after) != len(edges):
        raise footprints.FootprintError("an outline that touches itself")
    walls, waiting = [], set(after)
    while waiting:
        loop = [min(waiting)]
        while after[loop[-1]] != loop[0]:
            loop.append(after[loop[-1]])
        waiting -= set(loop)
        directions = np.array([points[after[start]] - points[start] for start in loop])
        directions /= np.hypot(directions[:, 0], directions[:, 1])[:, None]
        turns = np.abs(footprints.cross(np.roll(directions, 1, axis=0), directions))
        corners = np.nonzero(turns > WALL_TURN_SIN)[0]
        first = int(corners[0]) if len(corners) else 0
        ordered = loop[first:] + loop[:first]
        is_corner = np.roll(turns > WALL_TURN_SIN, -first)
        for index, start in enumerate(ordered):
            if index == 0 or is_corner[index]:
                walls.append([])
            walls[-1].append((start, after[start]))
    return walls


def foot_height_m(shape, ground_m):
    """Return the height of a building's floor: under the lowest ground beneath it.

    `ground_m(points)` gives the terrain's height at (K, 2) points.
    """
    low, high = shape.points.min(0), shape.points.max(0)
    east, north = np.meshgrid(
        np.arange(low[0], high[0] + GROUND_SAMPLE_M, GROUND_SAMPLE_M),
        np.arange(low[1], high[1] + GROUND_SAMPLE_M, GROUND_SAMPLE_M),
    )
    samples = np.column_stack([east.ravel(), north.ravel()])
    under = samples[~np.isnan(rise_at(shape, samples))]
    return float(ground_m(np.vstack([shape.points, under])).min()) - SKIRT_M


def shell(shape, heights_m, foot_m, ground_m):
    """Return the Shell of a building: the roof `shape` at `heights_m`, walls and a floor.

    A wall hangs from every edge of the roof's outline down to `foot_m`; the floor is the
    roof's triangles turned over at that height. `ground_m(points)` gives the terrain's
    height, from which each wall's ground floor is measured.
    """
    points = np.column_stack([shape.points, heights_m])
    roof = points[shape.triangles]
    floor = roof[:, ::-1].copy()
    floor[:, :, 2] = foot_m
    walls, wall_uv, wall_uv2 = [], [], []
    for wall in _walls(shape.points, outline_edges(shape.triangles)):
        ends = np.array([shape.points[wall[0][0]], shape.points[wall[-1][1]]])
        low_m, high_m = sorted(float(height) for height in ground_m(ends))
        floor_m = min(high_m, low_m + FLOOR_STEP_M)
        along_m = np.cumsum(
            [0.0]
            + [float(np.hypot(*(shape.points[end] - shape.points[start]))) for start, end in wall]
        )
        for index, (start, end) in enumerate(wall):
            corners = [
                (start, foot_m, along_m[index]),
                (end, foot_m, along_m[index + 1]),
                (end, heights_m[end], along_m[index + 1]),
                (start, heights_m[start], along_m[index]),
            ]
            for triangle in ((0, 1, 2), (0, 2, 3)):
                picked = [corners[corner] for corner in triangle]
                walls.append([(*shape.points[node], height) for node, height, _ in picked])
                wall_uv.append(
                    [
                        (metres / FACADE_UV_M, 1.0 - (height - floor_m) / FACADE_UV_M)
                        for _, height, metres in picked
                    ]
                )
                wall_uv2.append([(heights_m[node] - floor_m, along_m[-1]) for node, _, _ in picked])
    edges_m = roof_edge_distances_m(shape, heights_m)
    return Shell(roof, edges_m, np.array(walls), np.array(wall_uv), np.array(wall_uv2), floor)


def roof_rows(roof):
    """Return a roof's texture coordinates per corner: metres along the eave, up the slope.

    `roof` is (count, 3, 3) separate triangles; a flat face's rows run along east.
    """
    normals = np.cross(roof[:, 1] - roof[:, 0], roof[:, 2] - roof[:, 0])
    lean = np.hypot(normals[:, 0], normals[:, 1])
    is_flat = lean < 1e-6 * np.maximum(np.abs(normals[:, 2]), 1e-12)
    uphill = np.where(
        is_flat[:, None], [[0.0, 1.0]], -normals[:, :2] / np.maximum(lean, 1e-12)[:, None]
    )
    along_eave = np.column_stack([uphill[:, 1], -uphill[:, 0]])
    cosine = np.abs(normals[:, 2]) / np.maximum(np.linalg.norm(normals, axis=1), 1e-12)
    return np.stack(
        [
            (roof[:, :, :2] * along_eave[:, None, :]).sum(2),
            (roof[:, :, :2] * uphill[:, None, :]).sum(2) / np.maximum(cosine, 0.2)[:, None],
        ],
        axis=2,
    )


def roof_edge_distances_m(shape, heights_m):
    """Return per roof triangle corner its distance to two of the triangle's outline edges.

    (M, 3, 2), measured on the roof: each of the two is a plane over the triangle, so the
    smaller, taken where the roof is drawn, is the distance to the roof's edge. A triangle
    with fewer edges on the outline is FAR_FROM_EDGE_M from the missing ones.
    """
    points = np.column_stack([shape.points, heights_m])
    outline = set(outline_edges(shape.triangles))
    distances_m = np.full((len(shape.triangles), 3, 2), FAR_FROM_EDGE_M)
    for index, triangle in enumerate(shape.triangles):
        on_outline = [
            corner
            for corner in range(3)
            if (triangle[corner], triangle[(corner + 1) % 3]) in outline
        ]
        for slot, corner in enumerate(on_outline[:2]):
            start, end, opposite = (points[triangle[(corner + turn) % 3]] for turn in range(3))
            along = (end - start) / np.linalg.norm(end - start)
            distances_m[index, :, slot] = 0.0
            distances_m[index, (corner + 2) % 3, slot] = np.linalg.norm(
                np.cross(opposite - start, along)
            )
    return distances_m


# --------------------------------------------------------------------------------- faults
def faults(triangles):
    """Return what keeps a mesh from being a closed solid, or None when nothing does.

    `triangles` is (count, 3 corners, 3 coordinates). A closed solid has no triangle without
    an area, every edge in exactly two triangles that run along it in opposite ways, and its
    faces wound outwards.
    """
    corners = np.asarray(triangles, np.float64)
    areas = np.linalg.norm(
        np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0]), axis=1
    )
    if (areas < MIN_DOUBLED_AREA_M2).any():
        return f"{int((areas < MIN_DOUBLED_AREA_M2).sum())} degenerate triangles"
    _, welded = np.unique(np.round(corners.reshape(-1, 3) / WELD_M), axis=0, return_inverse=True)
    welded = welded.reshape(-1, 3)
    edges = welded[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2)
    if (edges[:, 0] == edges[:, 1]).any():
        return f"{int((edges[:, 0] == edges[:, 1]).sum())} degenerate triangles"
    _, uses = np.unique(np.sort(edges, axis=1), axis=0, return_counts=True)
    if (uses == 1).any():
        return f"{int((uses == 1).sum())} open edges"
    if (uses > 2).any():
        return f"{int((uses > 2).sum())} edges shared by more than two triangles"
    _, same_way = np.unique(edges, axis=0, return_counts=True)
    if (same_way > 1).any():
        return f"{int((same_way > 1).sum())} edges with inconsistent winding"
    middle = corners.reshape(-1, 3).mean(0)
    offset = corners - middle
    volume_m3 = float(
        np.einsum("ij,ij->i", offset[:, 0], np.cross(offset[:, 1], offset[:, 2])).sum()
    )
    if volume_m3 <= 0.0:
        return "wound inside out"
    return None
