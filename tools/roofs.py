"""Rebuild the roofs of a world glb as clean, classified surfaces.

The experiment's buildings carry their roof as a LiDAR-shaped mesh drawn with the orthophoto.
A photo is evidence of a roof, not its texture: it leans, it is shaded on one side and its
pixels stretch. For each `Building_*` mesh this tool reads the roof's shape (flat, a gable
that planes fit, or free), its colour in the graded photo away from the edges and out of the
shadows, and from both the roofing material. It then replaces the roof's primitives by one
drawn with the material `M_Roof_<class>`:

- POSITION, NORMAL: planes with a crisp ridge where a flat roof or a gable fits, the LiDAR
  shape otherwise;
- TEXCOORD_0: metres along the eave and metres up the slope, so rows of tiles run along the
  eave at their real size;
- COLOR_0: the roof's albedo (linear RGB), and in alpha the distance to the roof's edge over
  EDGE_RANGE_M, for the trim drawn there.

Needs numpy and Pillow.
"""

import math

import ground_classes
import numpy as np
import smooth_terrain

BUILDING_MESH_PREFIX = "Building_"
ROOF_MATERIAL_PREFIX = "M_Ortho_"
ROOF_CLASSES = ("slate", "clay_tiles", "concrete_tiles", "metal", "bitumen", "gravel", "green")

BRIGHTEST_ROOF = 0.3  # sheeting burns out in the photo
GABLE_WALL_MIN_M = 0.1
EAVE_QUANTILE = 0.25  # gable ends raise the upper part of a roof's outline
FLAT_RISE_M = 0.6  # a roof rising less than this above its eaves is flat
FLAT_PITCH_DEG = 8.0
GABLE_MAX_MISFIT_M = 0.6
GABLE_MAX_MISFIT_OVER_RISE = 0.3
SHED_PITCH_DEG = 20.0  # below this a large pitched roof is sheeting, not tiles
HALL_AREA_M2 = 350.0
LEAN_MARGIN_M = 1.5  # the photo's roofs lean: colour is read this far inside the edge
LIT_SHARE = 0.5  # the brightest share of a roof's pixels, out of its shaded side and shadows
EDGE_RANGE_M = 2.0
SAMPLE_SPACING_M = 0.5

CLAY_RED_OVER_GREEN = 1.15
CLAY_RED_OVER_BLUE = 1.3
LIGHT_ROOF_LUMINANCE = 0.5
DARK_ROOF_LUMINANCE = 0.3
GRAVEL_LUMINANCE = 0.42

GLTF_ARRAY_BUFFER = 34962
GLTF_ELEMENT_ARRAY_BUFFER = 34963


def classify_roof(albedo, pitch_deg, area_m2):
    """Return the roofing a roof of this colour and shape is covered with.

    `albedo` is the roof's linear colour in the graded photo. Shape decides what colour
    cannot: a flat roof carries no tiles, and a large roof of low pitch is sheeting.
    """
    red, green, blue = (float(channel) for channel in ground_classes.srgb(np.asarray(albedo)))
    luminance = 0.3 * red + 0.59 * green + 0.11 * blue
    is_vegetated = green > red * 1.05 and green > blue * 1.05
    is_clay = red > green * CLAY_RED_OVER_GREEN and red > blue * CLAY_RED_OVER_BLUE
    if pitch_deg < FLAT_PITCH_DEG:
        if is_vegetated:
            return "green"
        if luminance > LIGHT_ROOF_LUMINANCE and area_m2 > HALL_AREA_M2:
            return "metal"
        return "gravel" if luminance > GRAVEL_LUMINANCE else "bitumen"
    if is_clay:
        return "clay_tiles"
    if luminance > LIGHT_ROOF_LUMINANCE or (pitch_deg < SHED_PITCH_DEG and area_m2 > HALL_AREA_M2):
        return "metal"
    return "slate" if luminance < DARK_ROOF_LUMINANCE else "concrete_tiles"


def lit_colour(albedos):
    """Return a roof's colour from the photo's pixels on it: the median of its lit share.

    The photo shades one side of a pitched roof and casts chimneys' and trees' shadows on it;
    the roofing is one colour.
    """
    albedos = np.asarray(albedos, np.float64).reshape(-1, 3)
    luminance = albedos @ np.array([0.2126, 0.7152, 0.0722])
    lit = albedos[luminance >= np.quantile(luminance, 1.0 - LIT_SHARE)]
    return np.median(lit, axis=0)


def boundary_edges(triangles):
    """Return the edges (pairs of vertex indices) that only one triangle has."""
    edges = np.sort(triangles[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2), axis=1)
    unique, counts = np.unique(edges, axis=0, return_counts=True)
    return unique[counts == 1]


def distance_to_segments(points, starts, ends):
    """Return each 2D point's distance to the nearest of the segments."""
    along = ends - starts
    lengths_squared = np.maximum((along**2).sum(1), 1e-12)
    offsets = points[:, None, :] - starts[None, :, :]
    shares = np.clip((offsets * along[None]).sum(2) / lengths_squared[None], 0.0, 1.0)
    nearest = starts[None] + shares[..., None] * along[None]
    return np.sqrt(((points[:, None, :] - nearest) ** 2).sum(2)).min(1)


def ridge_frame(outline):
    """Return a footprint's centre, the unit vector along its length and the one across."""
    centre = (outline.min(0) + outline.max(0)) / 2.0
    spread = np.cov((outline - outline.mean(0)).T)
    _, vectors = np.linalg.eigh(spread)
    along = vectors[:, 1]
    across = np.array([-along[1], along[0]])
    centre = centre + across * np.mean(
        [((outline - centre) @ across).min(), ((outline - centre) @ across).max()]
    )
    return centre, along, across


def fit_gable(across_m, rise_m):
    """Return a gable's half width and ridge rise fitted to a roof, and how badly it fits.

    `across_m` is each roof point's distance across the building from its middle line and
    `rise_m` its height above the eaves. The misfit is the points' RMS distance to the gable.
    """
    half_width_m = float(np.abs(across_m).max())
    shape = np.clip(1.0 - np.abs(across_m) / half_width_m, 0.0, 1.0)
    fitted_rise_m = float((rise_m * shape).sum() / max((shape**2).sum(), 1e-9))
    # A rounded roof's best gable overshoots it: the ridge is no higher than the roof.
    ridge_rise_m = min(fitted_rise_m, float(rise_m.max()))
    misfit_m = float(np.sqrt(np.mean((rise_m - ridge_rise_m * shape) ** 2)))
    return half_width_m, ridge_rise_m, misfit_m


def split_at_ridge(points, triangles, across_m):
    """Return the triangles cut along the line where `across_m` is 0, and the points added.

    Returns `(points, triangles, across_m)`: no triangle crosses the ridge, so the two slopes
    meet in a crisp line.
    """
    points = [tuple(point) for point in points]
    across = list(across_m)
    cut = {}

    def crossing(first, second):
        key = (min(first, second), max(first, second))
        if key not in cut:
            share = across[first] / (across[first] - across[second])
            new = np.array(points[first]) + share * (np.array(points[second]) - points[first])
            points.append(tuple(new))
            across.append(0.0)
            cut[key] = len(points) - 1
        return cut[key]

    kept = []
    for triangle in triangles:
        sides = [across[corner] > 1e-9 for corner in triangle]
        lows = [across[corner] < -1e-9 for corner in triangle]
        if not (any(sides) and any(lows)):
            kept.append(tuple(triangle))
            continue
        # Walk the triangle's outline, adding a point wherever it crosses the ridge.
        outline = []
        for corner, following in zip(triangle, np.roll(triangle, -1), strict=True):
            outline.append(corner)
            if across[corner] * across[following] < -1e-18:
                outline.append(crossing(corner, following))
        for side in (1.0, -1.0):
            polygon = [corner for corner in outline if across[corner] * side >= -1e-9]
            for index in range(1, len(polygon) - 1):
                kept.append((polygon[0], polygon[index], polygon[index + 1]))
    return np.array(points), np.array(kept, np.int64), np.array(across)


class Roof:
    """One building's roof: its faces as separate triangles, ready to be written."""

    def __init__(self, positions, triangles, sample_albedo):
        """Build the roof from the LiDAR-shaped mesh `positions` (x, y up, z), `triangles`.

        `sample_albedo(x, z)` gives the graded photo's colour at world positions.
        """
        ground = positions[:, [0, 2]]
        edges = boundary_edges(triangles)
        outline = ground[np.unique(edges)]
        eave_m = float(np.quantile(positions[np.unique(edges), 1], EAVE_QUANTILE))
        centre, along, across = ridge_frame(outline)
        across_m = (ground - centre) @ across
        rise_m = positions[:, 1] - eave_m
        self.area_m2 = float(_areas(ground, triangles).sum())
        half_width_m, ridge_rise_m, misfit_m = fit_gable(across_m, rise_m)
        heights = positions[:, 1].copy()
        if np.quantile(rise_m, 0.9) < FLAT_RISE_M:
            self.shape = "flat"
            self.pitch_deg = 0.0
            heights[:] = float(np.median(positions[:, 1]))
        elif misfit_m < max(GABLE_MAX_MISFIT_M, GABLE_MAX_MISFIT_OVER_RISE * ridge_rise_m):
            self.shape = "gable"
            self.pitch_deg = math.degrees(math.atan2(ridge_rise_m, half_width_m))
            positions, triangles, across_m = split_at_ridge(positions, triangles, across_m)
            ground = positions[:, [0, 2]]
            heights = eave_m + ridge_rise_m * np.clip(1.0 - np.abs(across_m) / half_width_m, 0, 1)
        else:
            self.shape = "free"
            self.pitch_deg = math.degrees(math.atan2(max(ridge_rise_m, 0.0), half_width_m))
        placed = np.column_stack([ground[:, 0], heights, ground[:, 1]])
        edge_m = distance_to_segments(
            ground, ground_of(positions, edges[:, 0]), ground_of(positions, edges[:, 1])
        )
        slope_m = (half_width_m - np.abs(across_m)) / max(
            math.cos(math.radians(self.pitch_deg)), 0.2
        )
        rows = np.column_stack([(ground - centre) @ along, slope_m])

        inside = edge_m >= min(LEAN_MARGIN_M, float(np.quantile(edge_m, 0.5)))
        colour = lit_colour(sample_albedo(ground[inside, 0], ground[inside, 1]))
        self.albedo = colour * min(1.0, BRIGHTEST_ROOF / max(float(colour.max()), 1e-6))
        self.roofing = classify_roof(self.albedo, self.pitch_deg, self.area_m2)

        self.gable_walls = gable_walls(placed, positions, edges)
        corners = triangles.reshape(-1)
        self.positions = placed[corners].astype(np.float32)
        self.rows = rows[corners].astype(np.float32)
        colours = np.empty((len(corners), 4), np.float32)
        colours[:, :3] = self.albedo
        colours[:, 3] = np.clip(edge_m[corners] / EDGE_RANGE_M, 0.0, 1.0)
        self.colours = colours
        self.normals = _face_normals(self.positions)


def gable_walls(placed, original, edges):
    """Return the walls that close a rebuilt roof onto the walls below it.

    Where a roof's outline rose above the LiDAR-shaped one (a gable's ends), a quad joins the
    two: (positions, texture coordinates), as separate triangles. The texture coordinates are
    a facade's: (metres along the wall, 1 - metres above its foot) / 3.
    """
    positions, coordinates = [], []
    for first, second in edges:
        rise_first = placed[first, 1] - original[first, 1]
        rise_second = placed[second, 1] - original[second, 1]
        if max(rise_first, rise_second) < GABLE_WALL_MIN_M:
            continue
        length_m = float(np.hypot(*(placed[second, [0, 2]] - placed[first, [0, 2]])))
        low_first, low_second = original[first], original[second]
        quad = [low_first, low_second, placed[second], low_first, placed[second], placed[first]]
        heights = [0.0, 0.0, rise_second, 0.0, rise_second, rise_first]
        alongs = [0.0, length_m, length_m, 0.0, length_m, 0.0]
        positions.extend(quad)
        coordinates.extend(
            (along / 3.0, 1.0 - height / 3.0) for along, height in zip(alongs, heights, strict=True)
        )
    return np.array(positions, np.float32).reshape(-1, 3), np.array(
        coordinates, np.float32
    ).reshape(-1, 2)


def ground_of(positions, indices):
    """Return the (x, z) of the positions at `indices`."""
    return positions[indices][:, [0, 2]]


def _areas(ground, triangles):
    first, second, third = (ground[triangles[:, corner]] for corner in range(3))
    return 0.5 * np.abs(
        (second[:, 0] - first[:, 0]) * (third[:, 1] - first[:, 1])
        - (second[:, 1] - first[:, 1]) * (third[:, 0] - first[:, 0])
    )


def _face_normals(corner_positions):
    """Return an upward unit normal per corner of separate triangles."""
    faces = corner_positions.reshape(-1, 3, 3).astype(np.float64)
    normals = np.cross(faces[:, 1] - faces[:, 0], faces[:, 2] - faces[:, 0])
    normals[normals[:, 1] < 0.0] *= -1.0
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    return np.repeat(normals, 3, axis=0).astype(np.float32)


def facing_up(corner_positions):
    """Return separate triangles wound counter-clockwise seen from above."""
    faces = corner_positions.reshape(-1, 3, 3)
    normals = np.cross(faces[:, 1] - faces[:, 0], faces[:, 2] - faces[:, 0])
    flipped = normals[:, 1] < 0.0
    order = np.tile(np.arange(3), (len(faces), 1))
    order[flipped] = [0, 2, 1]
    return order


def roof_mesh(gltf, binary, mesh):
    """Return a building's roof as (positions, triangles), welded, or None without a roof."""
    names = [material["name"] for material in gltf["materials"]]
    positions, triangles, count = [], [], 0
    for primitive in mesh["primitives"]:
        if not names[primitive["material"]].startswith(ROOF_MATERIAL_PREFIX):
            continue
        part = smooth_terrain.accessor_array(gltf, binary, primitive["attributes"]["POSITION"])
        indices = smooth_terrain.accessor_array(gltf, binary, primitive["indices"]).reshape(-1, 3)
        positions.append(part.astype(np.float64))
        triangles.append(indices.astype(np.int64) + count)
        count += len(part)
    if not positions:
        return None
    positions = np.concatenate(positions)
    triangles = np.concatenate(triangles)
    welded, where = np.unique(np.round(positions, 3), axis=0, return_inverse=True)
    triangles = where.reshape(-1)[triangles]
    proper = (
        (triangles[:, 0] != triangles[:, 1])
        & (triangles[:, 1] != triangles[:, 2])
        & (triangles[:, 0] != triangles[:, 2])
    )
    return welded, triangles[proper]


def _append_accessor(gltf, replaced_views, elements, kind, target):
    """Add `elements` to the glb as a new buffer view and accessor; return the accessor."""
    gltf["bufferViews"].append({"buffer": 0, "byteLength": elements.nbytes, "target": target})
    replaced_views[len(gltf["bufferViews"]) - 1] = elements.tobytes()
    accessor = {
        "bufferView": len(gltf["bufferViews"]) - 1,
        "componentType": smooth_terrain.GLTF_FLOAT,
        "count": len(elements),
        "type": kind,
    }
    if kind == "VEC3":
        accessor["min"] = [float(bound) for bound in elements.min(axis=0)]
        accessor["max"] = [float(bound) for bound in elements.max(axis=0)]
    gltf["accessors"].append(accessor)
    return len(gltf["accessors"]) - 1


def _wall_primitive(gltf, replaced_views, walls, material):
    """Return a two-sided primitive of separate wall triangles drawn with `material`."""
    positions, coordinates = walls
    both_sides = np.concatenate([positions, positions.reshape(-1, 3, 3)[:, ::-1].reshape(-1, 3)])
    both_coordinates = np.concatenate(
        [coordinates, coordinates.reshape(-1, 3, 2)[:, ::-1].reshape(-1, 2)]
    )
    faces = both_sides.reshape(-1, 3, 3).astype(np.float64)
    normals = np.cross(faces[:, 1] - faces[:, 0], faces[:, 2] - faces[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    attributes = {
        "POSITION": _append_accessor(gltf, replaced_views, both_sides, "VEC3", GLTF_ARRAY_BUFFER),
        "NORMAL": _append_accessor(
            gltf,
            replaced_views,
            np.repeat(normals, 3, axis=0).astype(np.float32),
            "VEC3",
            GLTF_ARRAY_BUFFER,
        ),
        "TEXCOORD_0": _append_accessor(
            gltf, replaced_views, both_coordinates, "VEC2", GLTF_ARRAY_BUFFER
        ),
        # A facade draws windows below the wall's height: none on a gable.
        "TEXCOORD_1": _append_accessor(
            gltf, replaced_views, np.zeros_like(both_coordinates), "VEC2", GLTF_ARRAY_BUFFER
        ),
    }
    return {"attributes": attributes, "material": material}


def roof_material(gltf, roofing):
    """Return the index of the glb's material for `roofing`, adding it when new."""
    name = f"M_Roof_{roofing}"
    for index, material in enumerate(gltf["materials"]):
        if material["name"] == name:
            return index
    gltf["materials"].append(
        {"name": name, "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0.8}}
    )
    return len(gltf["materials"]) - 1


def write_roofs(glb_path, sample_albedo):
    """Rewrite the roofs of the glb at `glb_path`; return how many roofs took each roofing.

    `sample_albedo(x, z)` gives the graded photo's colour at world positions (glTF's x and z).
    """
    gltf, binary = smooth_terrain.read_glb(glb_path)
    names = [material["name"] for material in gltf["materials"]]
    replaced_views = {}
    counts = dict.fromkeys(ROOF_CLASSES, 0)
    for mesh in gltf["meshes"]:
        if not mesh["name"].startswith(BUILDING_MESH_PREFIX):
            continue
        found = roof_mesh(gltf, binary, mesh)
        if found is None or len(found[1]) == 0:
            continue
        roof = Roof(found[0], found[1], sample_albedo)
        order = facing_up(roof.positions).reshape(-1) + np.repeat(
            np.arange(0, len(roof.positions), 3), 3
        )
        attributes = {
            "POSITION": _append_accessor(
                gltf, replaced_views, roof.positions[order], "VEC3", GLTF_ARRAY_BUFFER
            ),
            "NORMAL": _append_accessor(
                gltf, replaced_views, roof.normals[order], "VEC3", GLTF_ARRAY_BUFFER
            ),
            "TEXCOORD_0": _append_accessor(
                gltf, replaced_views, roof.rows[order], "VEC2", GLTF_ARRAY_BUFFER
            ),
            "COLOR_0": _append_accessor(
                gltf, replaced_views, roof.colours[order], "VEC4", GLTF_ARRAY_BUFFER
            ),
        }
        walls = [
            primitive
            for primitive in mesh["primitives"]
            if not names[primitive["material"]].startswith(ROOF_MATERIAL_PREFIX)
        ]
        mesh["primitives"] = walls + [
            {"attributes": attributes, "material": roof_material(gltf, roof.roofing)}
        ]
        if walls and len(roof.gable_walls[0]):
            mesh["primitives"].append(
                _wall_primitive(gltf, replaced_views, roof.gable_walls, walls[0]["material"])
            )
        counts[roof.roofing] += 1
    smooth_terrain.write_glb(glb_path, gltf, binary, replaced_views)
    return counts
