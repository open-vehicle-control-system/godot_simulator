"""Write the default track pack: a small test circuit on rolling ground, from code alone, CC0.

The lap is a closed chain of straights and arcs of chosen radii (a medium corner, a fast
sweeper, an S, a hairpin, a chicane), about 1.5 km long and 10 m wide, on terrain rolled by
a few long waves and rising into a wooded rim at the world's edge, so the edge reads as a
ridge against the sky. It goes through the real tracks' builders: the road map, lines image
and kerbs of track_surfaces.py, the closed buildings of buildings.py, the sign faces of
sign_faces.py and the tiles of track_tiles.py. Where a real track has an orthophoto, this
one draws its own (the albedo of each surface, with broad variation and mowing stripes),
graded as the identity; its texture sets and tree atlases are procedural_textures.py's.
Every random choice comes from a fixed seed, so two builds are the same.

Needs numpy and Pillow.
"""

import math

import buildings
import footprints
import ground_classes
import numpy as np
import osm
import procedural_textures
import sign_faces
import smooth_terrain
import track_surfaces
import track_tiles
from PIL import Image

TRACK_ID = "default_track"
WORLD_M = 768.0
TILE_M = 256.0
ORIGIN_M = (WORLD_M / 2.0, WORLD_M / 2.0)  # the map's (east, north) at the world's origin
PHOTO_PX_PER_M = 1.0 / track_surfaces.TRACK_MAP_M_PER_PX
LATTICE_M = 4.0  # the terrain mesh's spacing; the ground is smooth at that scale
GROUND_STEP_M = 2.0
SECTION_M = 1.0
LAP_SMOOTHING_M = 4.0  # eases the curvature into and out of each arc
HALF_WIDTH_M = 5.0
# The lap: straights (metres; None for the two whose lengths close the loop) and arcs
# (degrees, positive left, and radius in metres), counter-clockwise from the start line.
LAP = (
    ("straight", None),
    ("arc", 90.0, 45.0),
    ("straight", 150.0),
    ("arc", 60.0, 140.0),
    ("straight", 90.0),
    ("arc", -80.0, 60.0),
    ("straight", 70.0),
    ("arc", 180.0, 24.0),
    ("straight", None),
    ("arc", -40.0, 45.0),
    ("arc", 40.0, 45.0),
    ("straight", 60.0),
    ("arc", 60.0, 90.0),
    ("straight", 40.0),
    ("arc", -30.0, 80.0),
    ("arc", 80.0, 60.0),
    ("straight", 30.0),
)
SPAWN_S_M = 20.0
KERB_CURVATURE_PER_M = 1.0 / 100.0  # corners tighter than this get kerbs
KERB_WIDTH_M = 1.0
# Terrain: long waves (amplitude m, wavelength m) and the rim rising at the world's edge.
WAVES = ((2.6, 520.0), (1.6, 310.0), (0.9, 190.0), (0.4, 120.0))
TERRAIN_SEED = 5
RIM_HEIGHT_M = 16.0
RIM_WIDTH_M = 95.0
ROAD_SMOOTHING_M = 40.0  # the road's profile along the lap
ROAD_FLAT_M = 8.0  # how far from the centreline the ground is the road's
ROAD_BLEND_M = track_surfaces.TRACK_MAP_REACH_M  # and where it is the terrain's again
# The ground layers: texture set, the width it covers and how far it takes the photo's colour.
LAWN, MEADOW, GRAVEL, TRACK_ASPHALT, RUN_OFF = range(5)
LAYERS = (
    ("grass", 2.5, 0.75),
    ("grass", 3.5, 0.8),
    ("gravel", 2.0, 0.9),
    ("asphalt", 2.0, 1.0),
    ("asphalt", 3.0, 1.0),
)
# Each layer's colour in the drawn photo (linear albedo).
PHOTO_ALBEDO = {
    LAWN: (0.05, 0.085, 0.028),
    MEADOW: (0.075, 0.09, 0.035),
    GRAVEL: (0.3, 0.26, 0.19),
    TRACK_ASPHALT: (0.13, 0.13, 0.135),
    RUN_OFF: (0.17, 0.17, 0.17),
}
PHOTO_SEED = 9
LAWN_REACH_M = 45.0  # the mown verge beside the lap
MOWING_STRIPE_M = 8.0
# Run-off beyond the outside of corners: (from, to) metres along the lap, its side (1 right,
# -1 left), its layer and how far beyond the asphalt's edge it reaches.
RUN_OFFS = (
    (150.0, 245.0, 1, RUN_OFF, 14.0),
    (605.0, 690.0, -1, RUN_OFF, 10.0),
    (745.0, 840.0, 1, GRAVEL, 16.0),
)
# The paddock beside the main straight, outside the lap: its corners east and north of the
# world's origin, and what stands on it.
PADDOCK = ((-120.0, -310.0), (60.0, -285.0))
TEXTURE_SIDE_PX = {"ground": 512, "building": 256}
# Facade kinds: texture set, the width it covers, window style, tints.
FACADES = {
    "plaster": ("plaster", 3.0, "house", ((0.97, 0.95, 0.9), (0.9, 0.92, 0.95))),
    "brick": ("brick", 2.0, "house", ((1.0, 1.0, 1.0),)),
    "metal": ("metal_sheet", 2.5, "hall", ((1.15, 1.17, 1.2), (0.8, 0.95, 1.1))),
}
ROOFINGS = {"clay_tiles": ("clay_tiles", 2.6), "metal": ("metal_sheet", 3.0)}
# Buildings: footprint corners (east, north of the world's origin), map tags, roof colour.
CLAY = (0.32, 0.1, 0.05)
SHEET = (0.55, 0.56, 0.58)
BUILDINGS = (
    (
        ((-100.0, -306.0), (-40.0, -306.0), (-40.0, -292.0), (-100.0, -292.0)),
        {"building": "garages", "building:material": "metal", "roof:shape": "flat", "height": "5"},
        SHEET,
    ),
    (
        ((-25.0, -304.0), (-11.0, -304.0), (-11.0, -293.0), (-25.0, -293.0)),
        {"building": "office", "building:material": "brick", "roof:shape": "hipped", "height": "8"},
        CLAY,
    ),
    (
        ((5.0, -307.0), (30.0, -307.0), (30.0, -294.0), (5.0, -294.0)),
        {"building": "shed", "building:material": "metal", "roof:shape": "gabled", "height": "5"},
        SHEET,
    ),
    (
        ((206.0, 40.0), (218.0, 40.0), (218.0, 49.0), (212.0, 49.0), (212.0, 55.0), (206.0, 55.0)),
        {
            "building": "house",
            "building:material": "plaster",
            "roof:shape": "gabled",
            "height": "6",
        },
        CLAY,
    ),
    (
        ((-225.0, 120.0), (-213.0, 116.0), (-210.0, 126.0), (-222.0, 130.0)),
        {
            "building": "house",
            "building:material": "plaster",
            "roof:shape": "hipped",
            "height": "6",
        },
        CLAY,
    ),
)
BUILDING_CLEAR_M = 6.0  # no tree this close to a building
# Trees: woods on the rim and lone trees in the infield.
TREE_SEED = 17
RIM_TREES = 900
INFIELD_TREES = 70
TREE_CLEAR_M = HALF_WIDTH_M + 9.0  # no tree this close to the lap's centreline
# Signs by the paddock's way onto the lap: face, east and north of its post, the yaw its
# front faces.
SIGNS = (
    ("BE:C43[30]", (-125.0, -282.0), 90.0),
    ("BE:B1", (65.0, -282.0), -90.0),
)
SIGN_LOWER_EDGE_M = 1.0
POST_DIAMETER_M = 0.076
SUN = {"azimuth_deg": 135.0, "elevation_deg": 42.0}
VISIBILITY_M = 12000.0


class DrawnMosaic(track_surfaces.Mosaic):
    """A photo drawn by the builder, laid out as the orthophoto mosaic of a real track."""

    def __init__(self, rgb, west, north, px_per_m):
        """Wrap `rgb` covering the ground from (west, north), `px_per_m` pixels a metre."""
        self.rgb = rgb
        self.west, self.north, self.px_per_m = west, north, px_per_m
        self.tile_px = round(track_surfaces.TILE_M * px_per_m)

    def pack_tile_corners(self):
        """Return the (east, north) corner of every pack tile the photo covers."""
        count = round(self.rgb.shape[0] / self.px_per_m / TILE_M)
        return [
            (round(self.west + column * TILE_M), round(self.north - (row + 1) * TILE_M))
            for column in range(count)
            for row in range(count)
        ]


# -------------------------------------------------------------------------------------- lap
def _circular_smooth(values, sigma_samples):
    return track_surfaces.circular_smooth(np.asarray(values, np.float64), sigma_samples)


def _trace(straight_lengths_m):
    """Return the lap's corners every SECTION_M or less, its two free straights so long."""
    heading, position, points = 0.0, np.zeros(2), [np.zeros(2)]
    free = iter(straight_lengths_m)
    for part in LAP:
        if part[0] == "straight":
            length_m = part[1] if part[1] is not None else next(free)
            turn = 0.0
        else:
            turn = math.radians(part[1])
            length_m = abs(turn) * part[2]
        steps = max(1, math.ceil(length_m / SECTION_M))
        for _ in range(steps):
            middle = heading + turn / steps / 2.0
            position = position + length_m / steps * np.array([math.cos(middle), math.sin(middle)])
            heading += turn / steps
            points.append(position)
    return np.array(points)


def lap_points():
    """Return the lap's centreline: points every metre or so, closed, about the world's origin.

    The two free straights take the lengths that bring the lap back onto its start.
    """
    end = _trace((0.0, 0.0))[-1]
    effects = np.stack([_trace((1.0, 0.0))[-1] - end, _trace((0.0, 1.0))[-1] - end], 1)
    lengths = np.linalg.solve(effects, -end)
    points = _trace(lengths)[:-1]
    return points - (points.min(0) + points.max(0)) / 2.0


def lap_sections():
    """Return the lap's sections every SECTION_M: `s`, `x`, `y`, `tx`, `ty`, as lists.

    `x`, `y` are east and north of the world's origin and (tx, ty) the unit heading.
    """
    points = lap_points()
    steps = np.diff(np.vstack([points, points[:1]]), axis=0)
    along = np.concatenate([[0.0], np.cumsum(np.hypot(*steps.T))])
    length_m = along[-1]
    count = round(length_m / SECTION_M)
    s = np.arange(count) * length_m / count
    closed = np.vstack([points, points[:1]])
    x = np.interp(s, along, closed[:, 0])
    y = np.interp(s, along, closed[:, 1])
    x = _circular_smooth(x, LAP_SMOOTHING_M / SECTION_M)
    y = _circular_smooth(y, LAP_SMOOTHING_M / SECTION_M)
    tx = np.roll(x, -1) - np.roll(x, 1)
    ty = np.roll(y, -1) - np.roll(y, 1)
    norm = np.hypot(tx, ty)
    steps = np.hypot(np.roll(x, -1) - x, np.roll(y, -1) - y)
    s = np.concatenate([[0.0], np.cumsum(steps[:-1])])
    return {
        "s": s.tolist(),
        "x": x.tolist(),
        "y": y.tolist(),
        "tx": (tx / norm).tolist(),
        "ty": (ty / norm).tolist(),
    }


def lap_length_m(sections):
    """Return the length of the closed lap."""
    x, y = sections["x"], sections["y"]
    return float(sections["s"][-1] + math.hypot(x[0] - x[-1], y[0] - y[-1]))


def kerbs(sections, length_m):
    """Return the kerbs of each side (left, right) as track_surfaces.kerb_segments gives them.

    A kerb lies on the inside of every corner tighter than KERB_CURVATURE_PER_M, and on its
    outside too where the corner is twice as tight.
    """
    curvature = _circular_smooth(track_surfaces.lap_curvature(sections), 6.0)
    s = np.asarray(sections["s"])
    inside_right = curvature > KERB_CURVATURE_PER_M
    inside_left = curvature < -KERB_CURVATURE_PER_M
    tight = np.abs(curvature) > 2.0 * KERB_CURVATURE_PER_M
    found = []
    for wanted in (inside_left | (inside_right & tight), inside_right | (inside_left & tight)):
        widths = np.where(wanted, KERB_WIDTH_M, 0.0)
        found.append(track_surfaces.kerb_segments(widths, s, length_m))
    return found


# ---------------------------------------------------------------------------------- terrain
def base_heights_m(east, north):
    """Return the rolling terrain's height at points east and north of the world's origin."""
    rng = np.random.default_rng(TERRAIN_SEED)
    heights = np.zeros(np.broadcast(east, north).shape)
    for amplitude_m, wavelength_m in WAVES:
        angle, phase = rng.uniform(0.0, math.tau, 2)
        across = east * math.cos(angle) + north * math.sin(angle)
        heights += amplitude_m * np.sin(math.tau * across / wavelength_m + phase)
    to_edge = WORLD_M / 2.0 - np.maximum(np.abs(east), np.abs(north))
    rise = np.clip(1.0 - to_edge / RIM_WIDTH_M, 0.0, 1.0)
    return heights + RIM_HEIGHT_M * rise * rise * (3.0 - 2.0 * rise)


def road_profile_m(sections):
    """Return the road's height per section: the terrain under it, smoothed along the lap."""
    heights = base_heights_m(np.asarray(sections["x"]), np.asarray(sections["y"]))
    return _circular_smooth(heights, ROAD_SMOOTHING_M / SECTION_M)


class Terrain:
    """The ground's heights on a lattice LATTICE_M apart, the road's near the lap.

    Beyond the road they blend into the rolling terrain. Rows run south from the world's north
    edge, columns east from its west edge.
    """

    def __init__(self, sections, lap_map):
        """Lay the road's profile into the terrain where `lap_map` places the ground."""
        count = round(WORLD_M / LATTICE_M) + 1
        self.east = -WORLD_M / 2.0 + LATTICE_M * np.arange(count)
        self.north = WORLD_M / 2.0 - LATTICE_M * np.arange(count)
        east, north = np.meshgrid(self.east, self.north)
        heights = base_heights_m(east, north)
        profile = road_profile_m(sections)
        rows = np.clip(
            ((WORLD_M / 2.0 - north) * PHOTO_PX_PER_M).astype(int), 0, lap_map.along.shape[0] - 1
        )
        columns = np.clip(
            ((east + WORLD_M / 2.0) * PHOTO_PX_PER_M).astype(int), 0, lap_map.along.shape[1] - 1
        )
        along = lap_map.along[rows, columns]
        right = np.abs(lap_map.right[rows, columns])
        near = ~np.isnan(along)
        length_m = lap_length_m(sections)
        s = np.append(sections["s"], length_m)
        road_m = np.interp(np.nan_to_num(along), s, np.append(profile, profile[0]))
        blend = np.clip((np.nan_to_num(right) - ROAD_FLAT_M) / (ROAD_BLEND_M - ROAD_FLAT_M), 0, 1)
        terrain_share = np.where(near, blend * blend * (3.0 - 2.0 * blend), 1.0)
        self.heights_m = road_m * (1.0 - terrain_share) + heights * terrain_share

    def height_m(self, east, north):
        """Return the ground's height at points, bilinear between the lattice's."""
        column = np.clip((np.asarray(east) - self.east[0]) / LATTICE_M, 0, len(self.east) - 1.001)
        row = np.clip((self.north[0] - np.asarray(north)) / LATTICE_M, 0, len(self.north) - 1.001)
        return smooth_terrain.sample_bilinear(self.heights_m, row, column)

    def triangles(self):
        """Return the ground's triangles as (count, 3, 6): Godot position and normal."""
        east, north = np.meshgrid(self.east, self.north)
        positions = np.stack([east, self.heights_m, -north], -1).reshape(-1, 3)
        normals = smooth_terrain.lattice_normals(self.heights_m, LATTICE_M).reshape(-1, 3)
        corners = np.concatenate([positions, normals], 1)
        return corners[smooth_terrain.grid_triangles(self.heights_m)]


def write_world(path, terrain):
    """Write the world the tiles are cut from: the ground as one terrain mesh."""
    triangles = terrain.triangles()
    vertices, indices = track_tiles.welded(triangles)
    glb = track_tiles.Glb()
    attributes = {"POSITION": vertices[:, :3], "NORMAL": vertices[:, 3:6]}
    glb.add_mesh(
        f"{smooth_terrain.TERRAIN_MESH_PREFIX}world",
        [(attributes, indices, track_tiles.GROUND_MATERIAL)],
    )
    glb.write(path)


# ---------------------------------------------------------------------------------- surface
def surface_labels(lap_map, sections):
    """Return the ground layer of every photo pixel."""
    shape = lap_map.along.shape
    rows, columns = np.indices(shape)
    east = (columns + 0.5) / PHOTO_PX_PER_M - WORLD_M / 2.0
    north = WORLD_M / 2.0 - (rows + 0.5) / PHOTO_PX_PER_M
    along, right = lap_map.along, lap_map.right
    beside = np.abs(np.nan_to_num(right, nan=np.inf))
    labels = np.full(shape, MEADOW, np.uint8)
    labels[beside < LAWN_REACH_M] = LAWN
    near = beside < track_surfaces.TRACK_MAP_REACH_M
    labels[_near_lap(east, north, sections, LAWN_REACH_M) & ~near] = LAWN
    for from_m, to_m, side, layer, reach_m in RUN_OFFS:
        outside = np.nan_to_num(right * side, nan=-1.0)
        on = (along >= from_m) & (along <= to_m) & (outside > HALF_WIDTH_M)
        labels[on & (outside < HALF_WIDTH_M + reach_m)] = layer
    (west, south), (east_edge, north_edge) = PADDOCK
    labels[(east >= west) & (east <= east_edge) & (north >= south) & (north <= north_edge)] = (
        RUN_OFF
    )
    labels[beside <= HALF_WIDTH_M + KERB_WIDTH_M] = TRACK_ASPHALT
    return labels


def _near_lap(east, north, sections, reach_m):
    """Return which points lie within `reach_m` of the lap's centreline, every 4 m of it."""
    near = np.zeros(east.shape, bool)
    for x, y in zip(sections["x"][::4], sections["y"][::4], strict=True):
        near |= (east - x) ** 2 + (north - y) ** 2 < reach_m**2
    return near


def drawn_photo(labels, lap_map):
    """Return the photo the ground is drawn with: each layer's albedo, varied, as sRGB."""
    side = labels.shape[0]
    albedo = np.zeros((*labels.shape, 3))
    for layer, colour in PHOTO_ALBEDO.items():
        albedo[labels == layer] = colour
    broad = procedural_textures.fractal_noise(side, (400, 120, 40), PHOTO_SEED)
    fine = procedural_textures.periodic_noise(side, 6, PHOTO_SEED + 10)
    vegetation = (labels == LAWN) | (labels == MEADOW)
    albedo *= (1.0 + np.where(vegetation, 0.12, 0.04) * broad + 0.03 * fine)[..., None]
    # Dry, yellower meadow where the broad noise is high.
    dry = 0.5 * np.clip(broad - 1.0, 0.0, 1.0) * (labels == MEADOW)
    albedo = albedo * (1.0 - dry[..., None]) + np.array([0.15, 0.14, 0.06]) * dry[..., None]
    rows = np.indices(labels.shape)[0] / PHOTO_PX_PER_M
    stripes = np.where((rows // MOWING_STRIPE_M) % 2 == 0, 1.06, 0.94)
    albedo[labels == LAWN] *= stripes[labels == LAWN][:, None]
    return np.round(ground_classes.srgb(np.clip(albedo, 0.0, 1.0)) * 255.0).astype(np.uint8)


# -------------------------------------------------------------------------------- buildings
def building_areas():
    """Return the buildings' footprints as osm.Area, counter-clockwise."""
    areas = []
    for corners, tags, _ in BUILDINGS:
        ring = np.array(corners, np.float64)
        if footprints.signed_area_m2(ring) < 0.0:
            ring = ring[::-1].copy()
        areas.append(osm.Area(dict(tags), ring))
    return areas


def roof_albedo(points):
    """Return the roof colour of the building holding the middle of `points`, per point."""
    middle = np.asarray(points).mean(0)
    for (_, _, colour), area in zip(BUILDINGS, building_areas(), strict=True):
        if footprints.contains(area.points, middle):
            return np.tile(colour, (len(points), 1))
    return np.tile(SHEET, (len(points), 1))


def build_buildings(terrain):
    """Return the default track's Buildings, closed, on its terrain."""
    count = round(WORLD_M / LATTICE_M)
    surface = buildings.Surface(
        np.full((count, count), np.nan), -WORLD_M / 2.0, WORLD_M / 2.0, LATTICE_M
    )
    built, made = buildings.build(
        building_areas(),
        surface,
        lambda points: terrain.height_m(points[:, 0], points[:, 1]),
        roof_albedo,
        [],
        {kind: len(facade[3]) for kind, facade in FACADES.items()},
    )
    if len(built) != len(BUILDINGS) or set(made) != {"as mapped"}:
        raise ValueError(f"default track buildings: {dict(made)}")
    for building in built:
        if building.roofing not in ROOFINGS:
            raise ValueError(f"default track: no texture for a {building.roofing} roof")
    return built


# ------------------------------------------------------------------------------ what stands
def _pack_position(east, north, height_m):
    """Return a point east and north of the world's origin in the pack's frame (x south)."""
    return [round(float(-north), 2), round(float(east), 2), round(float(height_m), 2)]


def trees(terrain, labels, sections):
    """Return the trees by kind, each [x, y, z, height] in the pack's frame.

    Woods stand on the rim and lone trees in the infield, never on the lap or its run-offs,
    nor by a building.
    """
    rng = np.random.default_rng(TREE_SEED)
    edge = WORLD_M / 2.0 - 4.0
    rim_east = rng.uniform(-edge, edge, RIM_TREES * 3)
    rim_north = rng.uniform(-edge, edge, RIM_TREES * 3)
    on_rim = WORLD_M / 2.0 - np.maximum(np.abs(rim_east), np.abs(rim_north)) < RIM_WIDTH_M * 0.9
    rim_east, rim_north = rim_east[on_rim][:RIM_TREES], rim_north[on_rim][:RIM_TREES]
    infield = lap_points()
    low, high = infield.min(0) + 40.0, infield.max(0) - 40.0
    lone_east = rng.uniform(low[0], high[0], INFIELD_TREES)
    lone_north = rng.uniform(low[1], high[1], INFIELD_TREES)
    east = np.concatenate([rim_east, lone_east])
    north = np.concatenate([rim_north, lone_north])
    heights = rng.uniform(9.0, 17.0, len(east))
    conifer = np.concatenate(
        [rng.uniform(0, 1, len(rim_east)) < 0.6, np.zeros(INFIELD_TREES, bool)]
    )
    rows = np.clip(((WORLD_M / 2.0 - north) * PHOTO_PX_PER_M).astype(int), 0, labels.shape[0] - 1)
    columns = np.clip(((east + WORLD_M / 2.0) * PHOTO_PX_PER_M).astype(int), 0, labels.shape[1] - 1)
    kept = (labels[rows, columns] == LAWN) | (labels[rows, columns] == MEADOW)
    kept &= ~_near_lap(east, north, sections, TREE_CLEAR_M)
    for area in building_areas():
        clear = footprints.distance_to_ring_m(np.column_stack([east, north]), area.points)
        kept &= (clear > BUILDING_CLEAR_M) & ~np.array(
            [footprints.contains(area.points, point) for point in zip(east, north, strict=True)]
        )
    ground_m = terrain.height_m(east, north)
    standing = {"conifer": [], "broadleaf": []}
    for index in np.flatnonzero(kept):
        position = _pack_position(east[index], north[index], ground_m[index])
        kind = "conifer" if conifer[index] else "broadleaf"
        standing[kind].append(position + [round(float(heights[index]), 2)])
    return standing


def signs(terrain):
    """Return the signs' faces and their posts and plates, as the pack lists them."""
    posts, plates = [], []
    for code, (east, north), yaw_deg in SIGNS:
        face = sign_faces.face(code)
        plate_m = float(np.ptp(face.outline_m[:, 1]))
        ground_m = float(terrain.height_m(np.array([east]), np.array([north]))[0])
        height_m = SIGN_LOWER_EDGE_M + plate_m + 0.04
        posts.append(
            {
                "position_m": _pack_position(east, north, ground_m),
                "height_m": round(height_m, 2),
                "diameter_m": POST_DIAMETER_M,
            }
        )
        # The plate hangs in front of its post: the pack's yaw is from x (south).
        facing = math.radians(yaw_deg)
        offset_m = POST_DIAMETER_M / 2.0 + 0.01
        front_east = math.sin(facing) * offset_m
        front_north = -math.cos(facing) * offset_m
        plates.append(
            {
                "face": code,
                "position_m": _pack_position(
                    east + front_east,
                    north + front_north,
                    ground_m + SIGN_LOWER_EDGE_M + plate_m / 2.0,
                ),
                "yaw_deg": yaw_deg,
                "source": "derived",
            }
        )
    return posts, plates


# ----------------------------------------------------------------------------------- writing
def texture_path(name):
    """Return a texture set's path in the pack, without its map suffixes."""
    return f"textures/{name}"


def surface_rules():
    """Return the track's `surfaces`: which simulator surface draws each glTF material."""
    rules = [{"materials": track_tiles.GROUND_MATERIAL["name"], "surface": "terrain"}]
    for roofing, (textures, size_m) in ROOFINGS.items():
        rules.append(
            {
                "materials": f"M_Roof_{roofing}",
                "surface": "roof",
                "textures": texture_path(textures),
                "size_m": size_m,
            }
        )
    for kind, (textures, size_m, windows, tints) in FACADES.items():
        for index, tint in enumerate(tints):
            rules.append(
                {
                    "materials": f"{buildings.FACADE_MATERIAL_PREFIX}{kind}_{index}",
                    "surface": "facade",
                    "textures": texture_path(textures),
                    "size_m": size_m,
                    "windows": windows,
                    "tint": list(tint),
                }
            )
    return rules


def texture_sets():
    """Return {texture set: its side in pixels} for every set the track names."""
    sides = {name: TEXTURE_SIDE_PX["ground"] for name, _, _ in LAYERS}
    for name, *_ in list(FACADES.values()) + list(ROOFINGS.values()):
        sides.setdefault(name, TEXTURE_SIDE_PX["building"])
    return dict(sorted(sides.items()))


def write_textures(directory, work):
    """Write the texture sets and tree atlases' sources into `work`.

    Returns the compression jobs (kind, source, DDS in `directory`) that make them the pack's.
    """
    jobs = []
    work.mkdir(parents=True, exist_ok=True)
    kinds = {"albedo": "colour", "normal": "normal", "rough": "colour"}
    for name, side_px in texture_sets().items():
        for suffix, image in procedural_textures.texture_set(name, side_px).items():
            source = work / f"{name}_{suffix}.png"
            Image.fromarray(image).save(source)
            jobs.append((kinds[suffix], source, directory / f"{texture_path(name)}_{suffix}.dds"))
    for kind in procedural_textures.TREE_KINDS:
        atlas, _, _ = procedural_textures.tree_atlas(kind)
        source = work / f"tree_{kind}.png"
        Image.fromarray(atlas, "RGBA").save(source)
        jobs.append(("colour", source, directory / "trees" / f"{kind}.dds"))
    return jobs


def impostors():
    """Return the track's `trees.impostors`."""
    found = []
    for kind in procedural_textures.TREE_KINDS:
        atlas, width_m, height_m = procedural_textures.tree_atlas(kind)
        found.append(
            {
                "atlas": f"trees/{kind}.dds",
                "views": procedural_textures.TREE_VIEWS,
                "width_m": width_m,
                "height_m": height_m,
                "kind": kind,
            }
        )
    return found


def manifest(sections, terrain, length_m, sign_codes):
    """Return the default track's pack.json."""
    s_index = round(SPAWN_S_M / SECTION_M)
    east, north = sections["x"][s_index], sections["y"][s_index]
    tx, ty = sections["tx"][s_index], sections["ty"][s_index]
    ground_m = float(terrain.height_m(np.array([east]), np.array([north]))[0])
    return {
        "format": 1,
        "kind": "track",
        "id": TRACK_ID,
        "name": "Default test circuit",
        "version": "0.1.0",
        "licence": "CC0-1.0",
        "attribution": [
            "Generated from code by tools/default_packs.py: terrain, lap, surfaces, textures, "
            "trees and buildings, CC0",
            sign_faces.SOURCE,
        ],
        "track": {
            "tiles": "tiles.json",
            "far": {"scene": "far.glb", "photo": "far.jpg"},
            "sun": SUN,
            "haze": {"visibility_m": VISIBILITY_M},
            "spawn": {
                "position_m": _pack_position(east, north, ground_m),
                "yaw_deg": round(math.degrees(math.atan2(tx, -ty)), 2),
            },
            "ground": {
                "layers": [
                    {"textures": texture_path(name), "size_m": size_m, "photo": photo}
                    for name, size_m, photo in LAYERS
                ],
                "slope_layer": MEADOW,
                "photo_grade": {
                    "black": [0.0, 0.0, 0.0],
                    "gain": [1.0, 1.0, 1.0],
                    "gamma": 1.0,
                    "saturation": 1.0,
                },
                "road": {
                    "lines": "road_lines.png",
                    "lap_length_m": round(length_m, 2),
                    "layer": TRACK_ASPHALT,
                },
            },
            "surfaces": surface_rules(),
            "trees": {"impostors": impostors()},
            "signs": {
                "faces": [
                    {
                        "id": code,
                        "image": f"signs/{sign_faces.file_name(code)}",
                        "outline_m": [
                            [round(float(x), 4), round(float(y), 4)]
                            for x, y in sign_faces.outline(code)
                        ],
                    }
                    for code in sign_codes
                ],
                "signal": {"lens_diameter_m": 0.2, "cycle_s": [18.0, 3.0, 23.0]},
            },
        },
    }


def write(directory, work):
    """Write the default track's files into `directory`, its sources into `work`.

    Returns its manifest and the compression jobs that write its DDS textures.
    """
    directory.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    sections = lap_sections()
    length_m = lap_length_m(sections)
    side_px = round(WORLD_M * PHOTO_PX_PER_M)
    mosaic = DrawnMosaic(
        np.zeros((side_px, side_px, 3), np.uint8),
        ORIGIN_M[0] - WORLD_M / 2.0,
        ORIGIN_M[1] + WORLD_M / 2.0,
        PHOTO_PX_PER_M,
    )
    lap_map = track_surfaces.RoadMap(mosaic)
    lap_map.lay_lap(ORIGIN_M, sections, length_m)
    labels = surface_labels(lap_map, sections)
    mosaic.rgb = drawn_photo(labels, lap_map)

    edges = [np.full(len(sections["s"]), HALF_WIDTH_M)] * 2
    gaps = [np.zeros(len(sections["s"]), bool)] * 2
    offset, rubber = track_surfaces.racing_line(
        track_surfaces.lap_curvature(sections), SECTION_M, edges[0], edges[1]
    )
    lines = track_surfaces.lines_image(
        np.asarray(sections["s"]), length_m, edges, gaps, kerbs(sections, length_m), offset, rubber
    )
    Image.fromarray(lines, "RGBA").save(directory / "road_lines.png")
    track_surfaces.write_tile_maps(
        directory,
        mosaic,
        "surface",
        lambda corner: track_surfaces.labels_tile(labels, mosaic, corner),
        "L",
    )
    track_surfaces.write_tile_maps(
        directory, mosaic, "track", lambda corner: lap_map.tile_image(mosaic, corner), "RGBA"
    )

    terrain = Terrain(sections, lap_map)
    world = work / "world.glb"
    write_world(world, terrain)
    buildings.write(world, build_buildings(terrain))
    posts, plates = signs(terrain)
    faces = directory / "signs"
    faces.mkdir(exist_ok=True)
    codes = sorted({code for code, _, _ in SIGNS})
    for code in codes:
        sign_faces.face(code).image.save(faces / sign_faces.file_name(code))
    homeless = track_tiles.write(
        world,
        directory,
        mosaic,
        mosaic.rgb,
        ORIGIN_M,
        TILE_M,
        (smooth_terrain.TERRAIN_MESH_PREFIX, smooth_terrain.ROAD_MESH_PREFIX),
        trees(terrain, labels, sections),
        {"posts": posts, "plates": plates},
        GROUND_STEP_M,
    )
    if homeless:
        raise ValueError(f"default track: {homeless} trees or signs stand on no tile")
    jobs = write_textures(directory, work)
    return manifest(sections, terrain, length_m, codes), jobs
