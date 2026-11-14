"""Place the decals that show a road is driven on: tyre marks, oil stains, patches and covers.

Each decal stands where the data is evidence for it (docs/track_creation.md):

- tyre marks where cars brake hard, on the racing line: the braking zones of a speed profile
  of the lap, from its curvature; and where the graded photo shows a dark streak along the lap;
- oil stains and patched asphalt where the graded photo shows a small dark blot on the lap's
  asphalt, neither a shadow nor a car;
- manhole covers and drains where OpenStreetMap tags one on a road.

They lie on the asphalt only, clear of its painted lines, and few: a decal per hundred metres
of lap or so. The pack's decal textures are drawn here, so they are the pack's own.
Positions are metres east and north of the map frame's origin, as the lap's sections are.
"""

import math
from dataclasses import dataclass

import footprints
import numpy as np
import track_surfaces
from PIL import Image

KINDS = ("tyre_marks", "oil_stain", "patch", "manhole", "drain")
SOURCE = "Road decals: drawn by the pack's builder (tools/road_decals.py), CC0"
DRAW_DISTANCE_M = 120.0

# The speed profile: a car as fast as the lap lets a road car on slicks be.
LATERAL_GRIP_M_S2 = 12.0
BRAKING_M_S2 = 12.0
DRIVING_M_S2 = 4.0
TOP_SPEED_M_S = 75.0
SPEED_SMOOTHING_M = 12.0  # the curvature the profile reads, smoothed as the racing line's apex
BRAKING_DROP_M_S = 16.0  # a braking zone shedding less leaves no marks
MARKS_PER_DROP_M_S = 1.0 / 20.0  # a mark for every 20 m/s shed, at least one
MAX_MARKS_PER_ZONE = 3
MARK_LENGTH_M = (6.0, 14.0)
MARK_ALONG_ZONE = (0.35, 0.95)  # where in a braking zone marks lie: towards its end
MARK_SPREAD_M = 0.35  # how far a mark lies beside the racing line
MARK_OPACITY = (0.55, 0.9)
MARK_SAG_M = 0.1  # how far a mark's middle may lie off a curving course
TYRE_MARKS_WIDTH_M = 2.0  # a car's two tracks, 1.6 m apart
MARK_NEAR_STREAK_M = 10.0  # a braking mark is left out this close to a mark the photo shows

# Paint and the asphalt's edge: what a decal keeps clear of.
LINE_CLEAR_M = (
    track_surfaces.LINE_INSET_M + track_surfaces.LINE_WIDTH_M + 0.25
)  # from the asphalt's edge

# Blots: ground darker than the asphalt around it in the graded photo.
LATERAL_STEP_M = 0.25
LATERAL_REACH_M = 14.0
BASELINE_ALONG_M = 25.0
BLOT_CONTRAST = 0.03  # albedo luminance under the asphalt's median
SHADOW_CONTRAST = 0.08  # darker than this on average is a shadow or an object
MAX_BLOT_SATURATION = 0.2  # a car's paint is coloured; a stain is not
SHADOW_NEAR_ROWS = 6  # sections around a shadow whose blots may be its lighter rim
RUBBER_REACH_M = 1.2  # a blot this close to the racing line is its rubber
STAIN_CONTRAST = 0.035  # a stain or a patch is darker than a streak needs: it has no length
PAINT_CONTRAST = 0.06  # paint is this much lighter than the asphalt
PAINT_NEAR_CELLS = 4
MIN_BLOT_AREA_M2 = 0.4
STAIN_MAX_M = 2.5
STAIN_MARGIN_M = 0.5
PATCH_SIDE_M = (1.5, 6.0)
PATCH_FILL = 0.5
STREAK_LENGTH_M = (4.0, 30.0)  # longer is the racing line's rubber, which the shader draws
STREAK_MAX_WIDTH_M = 2.5
STREAK_ELONGATION = 3.0
STREAK_PIECE_M = 12.0
MIN_GAP_M = 15.0  # between two decals of one kind the photo places
# Shadows: the orthophotos' sun is in the south-east, 40 degrees up.
SHADOW_DIRECTION = (-math.sqrt(0.5), math.sqrt(0.5))
SHADOW_LENGTH_PER_HEIGHT = 1.2
CROWN_RADIUS_OVER_HEIGHT = track_surfaces.CROWN_RADIUS_OVER_HEIGHT
MIN_CROWN_RADIUS_M = track_surfaces.MIN_CROWN_RADIUS_M
BUILDING_SHADOW_M = 15.0

# Covers OpenStreetMap tags: their size (length along the road, width across).
COVER_SIZE_M = {"manhole": (0.8, 0.8), "drain": (0.6, 0.35)}
COVER_ON_ROAD_REACH_M = 0.5  # how far beyond a road's edge a mapped cover still lies on it

# The drawn textures: pixels across and along; the tyre marks are stretched along.
TEXTURE_PX = {
    "tyre_marks": (128, 1024),
    "oil_stain": (256, 256),
    "patch": (256, 256),
    "manhole": (256, 256),
    "drain": (256, 160),
}
TYRE_TRACK_M = 1.6
TYRE_WIDTH_M = 0.22


@dataclass
class Decal:
    """A decal lying on the ground: its middle, the heading of its length, its size."""

    kind: str
    x: float
    y: float
    heading_rad: float  # counter-clockwise from east
    length_m: float
    width_m: float
    opacity: float


# ---------------------------------------------------------------------------- braking marks
def lap_speeds(curvature_per_m, spacing_m):
    """Return the fastest speed at each section of a lap, braking and accelerating within grip.

    A corner limits the speed to what LATERAL_GRIP_M_S2 holds; a car brakes into it at
    BRAKING_M_S2 and accelerates out of it at DRIVING_M_S2.
    """
    bend = np.abs(track_surfaces.circular_smooth(curvature_per_m, SPEED_SMOOTHING_M / spacing_m))
    speeds = np.minimum(TOP_SPEED_M_S, np.sqrt(LATERAL_GRIP_M_S2 / np.maximum(bend, 1e-9)))
    count = len(speeds)
    for _ in range(2):  # twice round: the lap is closed
        for index in range(count - 1, -1, -1):
            after = speeds[(index + 1) % count]
            speeds[index] = min(speeds[index], math.sqrt(after**2 + 2.0 * BRAKING_M_S2 * spacing_m))
        for index in range(count):
            before = speeds[index - 1]
            speeds[index] = min(
                speeds[index], math.sqrt(before**2 + 2.0 * DRIVING_M_S2 * spacing_m)
            )
    return speeds


def braking_zones(speeds_m_s):
    """Return the hard braking zones of a lap: (first, last) sections, and the speed shed.

    A zone is a run of sections over which the speed falls, by BRAKING_DROP_M_S at least.
    """
    count = len(speeds_m_s)
    falling = np.roll(speeds_m_s, -1) < speeds_m_s - 1e-6
    if falling.all() or not falling.any():
        return []
    zones = []
    start = int(np.flatnonzero(~falling)[0]) + 1  # a section where no zone is under way
    index = 0
    while index < count:
        first = (start + index) % count
        if not falling[first]:
            index += 1
            continue
        length = 0
        while falling[(first + length) % count]:
            length += 1
        last = (first + length) % count
        drop = float(speeds_m_s[first] - speeds_m_s[last])
        if drop >= BRAKING_DROP_M_S:
            zones.append((first, last, drop))
        index += length
    return zones


def braking_marks(sections, zones, racing_offset_m, clear_m):
    """Return tyre marks on the racing line towards the end of each braking zone.

    A mark is moved in from the racing line as far as it must to stay clear, or left out
    where the asphalt is too narrow for it.

    `racing_offset_m` is the racing line right of the centreline per section, `clear_m` how
    far left and right of it a decal may reach, per section.
    """
    count = len(sections["s"])
    spacing_m = float(np.median(np.diff(sections["s"])))
    curvature = np.abs(track_surfaces.lap_curvature(sections))
    marks = []
    for first, last, drop in zones:
        rng = np.random.default_rng(first)
        length = (last - first) % count
        wanted = min(MAX_MARKS_PER_ZONE, 1 + int(drop * MARKS_PER_DROP_M_S))
        for share in np.sort(rng.uniform(*MARK_ALONG_ZONE, wanted)):
            middle = (first + round(share * length)) % count
            sag_limit = math.sqrt(8.0 * MARK_SAG_M / max(float(curvature[middle]), 1e-9))
            length_m = min(rng.uniform(*MARK_LENGTH_M), sag_limit)
            reach = round(length_m / 2.0 / spacing_m)
            ahead, behind = (middle + reach) % count, (middle - reach) % count
            slope = (racing_offset_m[ahead] - racing_offset_m[behind]) / max(2 * reach, 1)
            slope /= spacing_m
            covered = np.arange(middle - reach, middle + reach + 1) % count
            low = -float(clear_m[0][covered].min()) + _reach_across(length_m, slope)
            high = float(clear_m[1][covered].min()) - _reach_across(length_m, slope)
            lateral = racing_offset_m[middle] + rng.uniform(-MARK_SPREAD_M, MARK_SPREAD_M)
            opacity = float(rng.uniform(*MARK_OPACITY))
            if low > high:
                continue
            decal = _on_lap(
                sections, middle, min(max(lateral, low), high), slope, length_m, TYRE_MARKS_WIDTH_M
            )
            decal.kind, decal.opacity = "tyre_marks", opacity
            marks.append(decal)
    return marks


def _on_lap(sections, row, lateral_m, slope, length_m, width_m):
    """Return a decal at `lateral_m` right of section `row`, heading `slope` m/m to the right."""
    tx, ty = sections["tx"][row], sections["ty"][row]
    east = sections["x"][row] + ty * lateral_m
    north = sections["y"][row] - tx * lateral_m
    heading = math.atan2(ty, tx) - math.atan(slope)
    return Decal("", float(east), float(north), heading, float(length_m), float(width_m), 1.0)


def _reach_across(length_m, slope, width_m=TYRE_MARKS_WIDTH_M):
    """Return how far across the lap a decal heading `slope` m/m off it reaches from its middle."""
    turn = math.atan(slope)
    return abs(width_m / 2.0 * math.cos(turn)) + abs(length_m / 2.0 * math.sin(turn))


# ------------------------------------------------------------------------------ photo blots
def lap_darkness(ground, sections, inside_left_m, inside_right_m):
    """Return how much darker than the lap's asphalt the graded photo is along the lap.

    Returns (darkness, saturation, inside, laterals): per section and lateral step, the albedo
    luminance under the asphalt's median there, the colour's saturation, and whether the
    point lies within `inside_left_m` left and `inside_right_m` right of the centreline.
    """
    laterals = np.arange(-LATERAL_REACH_M, LATERAL_REACH_M + LATERAL_STEP_M / 2, LATERAL_STEP_M)
    x, y, tx, ty = (np.asarray(sections[key]) for key in ("x", "y", "tx", "ty"))
    east = x[:, None] + ty[:, None] * laterals[None, :]
    north = y[:, None] - tx[:, None] * laterals[None, :]
    albedo = ground.albedo_at(*ground.pixel(east, north))
    luminance = albedo @ np.array([0.2126, 0.7152, 0.0722])
    brightest = albedo.max(-1)
    saturation = (brightest - albedo.min(-1)) / np.maximum(brightest, 1e-3)
    inside = (laterals[None, :] > -np.asarray(inside_left_m)[:, None]) & (
        laterals[None, :] < np.asarray(inside_right_m)[:, None]
    )
    spacing_m = float(np.median(np.diff(sections["s"])))
    across = np.nanmedian(np.where(inside, luminance, np.nan), axis=1)
    across = np.where(np.isnan(across), np.nanmedian(across), across)
    window = max(1, round(BASELINE_ALONG_M / spacing_m)) | 1
    baseline = track_surfaces.circular_median(across, window)
    return baseline[:, None] - luminance, saturation, inside, laterals


@dataclass
class Blot:
    """Connected ground darker than the asphalt: its cells (rows unwrapped) and their contrast."""

    rows: np.ndarray
    columns: np.ndarray
    contrast: float


def blots(darkness, saturation, inside):
    """Return the dark blots on the asphalt that may be stains, patches or tyre marks.

    A blot's cells are BLOT_CONTRAST darker than the asphalt, joined side by side or corner to
    corner; rows wrap round the lap. Left out: blots touching the asphalt's limit (the lines,
    kerbs and verges beyond it), too dark (shadows, objects), near ground that dark (the
    lighter rim of a shadow), by paint (artwork, grid slots and the dark fringe the photo
    leaves around them) or coloured (cars).
    """
    count, width = darkness.shape
    dark = (darkness > BLOT_CONTRAST) & inside
    shadow_rows = ((darkness > SHADOW_CONTRAST) & inside).any(1)
    near_shadow = np.zeros(count, bool)
    for step in range(-SHADOW_NEAR_ROWS, SHADOW_NEAR_ROWS + 1):
        near_shadow |= np.roll(shadow_rows, step)
    painted = darkness < -PAINT_CONTRAST
    near_paint = painted.copy()
    for step in range(1, PAINT_NEAR_CELLS + 1):
        for axis in (0, 1):
            near_paint |= np.roll(painted, step, axis) | np.roll(painted, -step, axis)
    label = np.zeros(dark.shape, np.int32)
    found = []
    for row, column in zip(*np.nonzero(dark), strict=True):
        if label[row, column]:
            continue
        label[row, column] = len(found) + 1
        cells, pending = [], [(row, column)]
        while pending:
            at_row, at_column = pending.pop()
            cells.append((at_row, at_column))
            for step_row in (-1, 0, 1):
                for step_column in (-1, 0, 1):
                    next_row = (at_row + step_row) % count
                    next_column = at_column + step_column
                    if 0 <= next_column < width and dark[next_row, next_column]:
                        if not label[next_row, next_column]:
                            label[next_row, next_column] = len(found) + 1
                            pending.append((next_row, next_column))
        found.append(np.array(cells))
    kept = []
    for cells in found:
        rows, columns = cells[:, 0], cells[:, 1]
        if rows.max() - rows.min() > count // 2:
            rows = np.where(rows < count // 2, rows + count, rows)
        around = [
            inside[rows % count, np.clip(columns + step, 0, width - 1)].all() for step in (-1, 1)
        ]
        contrast = float(darkness[rows % count, columns].mean())
        coloured = float(saturation[rows % count, columns].mean()) > MAX_BLOT_SATURATION
        shaded = near_shadow[rows % count].any()
        by_paint = near_paint[rows % count, columns].any()
        if all(around) and contrast <= SHADOW_CONTRAST and not (coloured or shaded or by_paint):
            kept.append(Blot(rows, columns, contrast))
    return kept


def photo_decals(found, sections, laterals, racing_offset_m, shadowed):
    """Return the decals the photo's blots on the lap are evidence for.

    A small blot as dark as STAIN_CONTRAST is an oil stain, unless it lies on the racing
    line (`racing_offset_m` right of the centreline per section), where it is rubber the road
    already shows; a wide and squarish one is patched asphalt, and a streak along the lap
    tyre marks. Blots `shadowed(x, y)` says may be shadows are left out.
    """
    count = len(sections["s"])
    spacing_m = float(np.median(np.diff(sections["s"])))
    decals = []
    for blot in found:
        along_m = (blot.rows.max() - blot.rows.min() + 1) * spacing_m
        across_m = (blot.columns.max() - blot.columns.min() + 1) * LATERAL_STEP_M
        area_m2 = len(blot.rows) * spacing_m * LATERAL_STEP_M
        middle = round(float(blot.rows.mean())) % count
        lateral = float(laterals[blot.columns].mean())
        probe = _on_lap(sections, middle, lateral, 0.0, 1.0, 1.0)
        if area_m2 < MIN_BLOT_AREA_M2 or shadowed(probe.x, probe.y):
            continue
        opacity = float(np.clip(blot.contrast / SHADOW_CONTRAST + 0.25, 0.4, 1.0))
        if is_streak(along_m, across_m):
            decals += _streak_marks(blot, sections, laterals, opacity)
        elif blot.contrast < STAIN_CONTRAST:
            continue
        elif max(along_m, across_m) <= STAIN_MAX_M:
            if abs(lateral - racing_offset_m[middle]) < RUBBER_REACH_M:
                continue
            side = max(along_m, across_m) + STAIN_MARGIN_M
            turn = np.random.default_rng(middle).uniform(0.0, math.tau)
            decals.append(
                Decal("oil_stain", probe.x, probe.y, probe.heading_rad + turn, side, side, opacity)
            )
        elif is_patch(along_m, across_m, area_m2):
            decals.append(
                Decal("patch", probe.x, probe.y, probe.heading_rad, along_m, across_m, opacity)
            )
    return decals


def is_streak(along_m, across_m):
    """Tell whether a blot this long and wide is a streak along the lap."""
    return (
        STREAK_LENGTH_M[0] <= along_m <= STREAK_LENGTH_M[1]
        and across_m <= STREAK_MAX_WIDTH_M
        and along_m >= STREAK_ELONGATION * across_m
    )


def is_patch(along_m, across_m, area_m2):
    """Tell whether a blot this long, wide and large is patched asphalt."""
    low, high = PATCH_SIDE_M
    sides = low <= along_m <= high and low <= across_m <= high
    return sides and area_m2 >= PATCH_FILL * along_m * across_m


def _streak_marks(blot, sections, laterals, opacity):
    """Return the tyre marks along a streak, a piece every STREAK_PIECE_M, on its course."""
    count = len(sections["s"])
    spacing_m = float(np.median(np.diff(sections["s"])))
    first, last = int(blot.rows.min()), int(blot.rows.max())
    pieces = max(1, math.ceil((last - first + 1) * spacing_m / STREAK_PIECE_M))
    bounds = np.linspace(first, last + 1, pieces + 1)
    marks = []
    for start, end in zip(bounds[:-1], bounds[1:], strict=True):
        within = (blot.rows >= start) & (blot.rows < end)
        if within.sum() < 2:
            continue
        rows, lateral = blot.rows[within], laterals[blot.columns[within]]
        slope = np.polyfit(rows, lateral, 1)[0] if np.ptp(rows) > 0 else 0.0
        middle = (start + end) / 2.0
        at_middle = float(np.mean(lateral) + slope * (middle - rows.mean()))
        decal = _on_lap(
            sections,
            round(middle) % count,
            at_middle,
            slope / spacing_m,
            (end - start) * spacing_m,
            TYRE_MARKS_WIDTH_M,
        )
        decal.kind, decal.opacity = "tyre_marks", opacity
        marks.append(decal)
    return marks


def shadowed_by(trees, building_outlines):
    """Return a test of whether a point may lie in a tree's or a building's shadow.

    `trees` are (x, y, height) arrays; a tree's shadow reaches SHADOW_LENGTH_PER_HEIGHT its
    height along SHADOW_DIRECTION, as wide as its crown. A building shadows BUILDING_SHADOW_M
    around it.
    """
    trees = np.asarray(trees, np.float64).reshape(-1, 3)
    direction = np.array(SHADOW_DIRECTION)
    middles = [outline.mean(0) for outline in building_outlines]

    def shadowed(x, y):
        offset = np.array([x, y]) - trees[:, :2]
        along = offset @ direction
        beside = np.abs(offset @ np.array([-direction[1], direction[0]]))
        crown = np.maximum(MIN_CROWN_RADIUS_M, CROWN_RADIUS_OVER_HEIGHT * trees[:, 2])
        reach = SHADOW_LENGTH_PER_HEIGHT * trees[:, 2] + crown
        if np.any((along > -crown) & (along < reach) & (beside < crown)):
            return True
        for outline, middle in zip(building_outlines, middles, strict=True):
            if np.hypot(*(middle - (x, y))) > BUILDING_SHADOW_M + np.ptp(outline, 0).max():
                continue
            if footprints.contains(outline, (x, y)):
                return True
            starts, ends = outline, np.roll(outline, -1, axis=0)
            if _distance_to_segments((x, y), starts, ends) < BUILDING_SHADOW_M:
                return True
        return False

    return shadowed


def _distance_to_segments(point, starts, ends):
    span = ends - starts
    share = np.clip(
        ((point - starts) * span).sum(1) / np.maximum((span * span).sum(1), 1e-12), 0.0, 1.0
    )
    nearest = starts + span * share[:, None]
    return float(np.hypot(*(nearest - point).T).min())


def sparse(decals, min_gap_m=MIN_GAP_M):
    """Return `decals` thinned out: none within `min_gap_m` of a stronger one of its kind."""
    kept = []
    for decal in sorted(decals, key=lambda each: -each.opacity * each.length_m * each.width_m):
        if all(
            other.kind != decal.kind
            or math.hypot(other.x - decal.x, other.y - decal.y) >= min_gap_m
            for other in kept
        ):
            kept.append(decal)
    return kept


def away_from(decals, others, reach_m):
    """Return `decals` but those within `reach_m` of one of `others`."""
    return [
        decal
        for decal in decals
        if all(math.hypot(other.x - decal.x, other.y - decal.y) >= reach_m for other in others)
    ]


# ----------------------------------------------------------------------------------- covers
@dataclass
class Carriageway:
    """A road's asphalt and paint: per section, its edges and the offsets of its lines."""

    sections: dict
    left_m: np.ndarray
    right_m: np.ndarray
    line_offsets_m: list  # arrays per line, NaN where it is not painted


def cover_kind(tags):
    """Return the decal an OpenStreetMap node's tags map, or None."""
    if tags.get("man_made") != "manhole" and "manhole" not in tags:
        return None
    return "drain" if tags.get("manhole") in ("drain", "storm_drain") else "manhole"


def tagged_covers(nodes, carriageways):
    """Return the manholes and drains tagged on the roads, turned along them.

    A node off every road, or whose cover would reach a painted line, is not placed.
    """
    covers = []
    for node in nodes:
        kind = cover_kind(node.tags)
        if kind is None:
            continue
        length_m, width_m = COVER_SIZE_M[kind]
        for road in carriageways:
            x, y, tx, ty = (np.asarray(road.sections[key]) for key in ("x", "y", "tx", "ty"))
            nearest = int(np.argmin(np.hypot(x - node.point[0], y - node.point[1])))
            tx, ty = float(tx[nearest]), float(ty[nearest])
            east, north = node.point[0] - x[nearest], node.point[1] - y[nearest]
            if abs(east * tx + north * ty) > 1.5:
                continue
            lateral = east * ty - north * tx
            on_road = -road.left_m[nearest] - COVER_ON_ROAD_REACH_M <= lateral
            on_road &= lateral <= road.right_m[nearest] + COVER_ON_ROAD_REACH_M
            half_reach = math.hypot(length_m, width_m) / 2.0
            painted = [offsets[nearest] for offsets in road.line_offsets_m]
            clear = all(
                np.isnan(offset) or abs(lateral - offset) > half_reach + LINE_CLEAR_M / 2.0
                for offset in painted
            )
            if on_road and clear:
                heading = math.atan2(ty, tx)
                point = node.point
                covers.append(
                    Decal(kind, float(point[0]), float(point[1]), heading, length_m, width_m, 1.0)
                )
                break
    return covers


# --------------------------------------------------------------------------------- the pack
def described(decals, height_m):
    """Return decals as a pack's tiles list them, in its frame (x south, y east, z up).

    `height_m(x, y)` is the ground's height under a decal's middle. A decal's yaw is the
    heading of its length, counter-clockwise from the pack's x.
    """
    listed = []
    for decal in decals:
        yaw_deg = (math.degrees(decal.heading_rad) + 90.0 + 180.0) % 360.0 - 180.0
        listed.append(
            {
                "kind": decal.kind,
                "position_m": [
                    round(-decal.y, 2),
                    round(decal.x, 2),
                    round(float(height_m(decal.x, decal.y)), 2),
                ],
                "yaw_deg": round(yaw_deg, 1),
                "size_m": [round(decal.length_m, 2), round(decal.width_m, 2)],
                "opacity": round(decal.opacity, 2),
            }
        )
    return listed


def manifest(kinds, directory):
    """Return a pack's `decals`: the textures of the `kinds` placed, and how far they show."""
    return {
        "kinds": [{"id": kind, "textures": f"{directory}/{kind}"} for kind in kinds],
        "draw_distance_m": DRAW_DISTANCE_M,
    }


def write_textures(out_directory, kinds):
    """Write the albedo, normal and ORM maps of each of `kinds` as PNGs into `out_directory`."""
    out_directory.mkdir(parents=True, exist_ok=True)
    for stale in out_directory.glob("*.png"):
        stale.unlink()
    for kind in kinds:
        for suffix, image in zip(("albedo", "normal", "orm"), draw(kind), strict=True):
            image.save(out_directory / f"{kind}_{suffix}.png")


# --------------------------------------------------------------------------------- textures
def draw(kind):
    """Return a decal's (albedo RGBA, normal RGB, ORM RGB) images, drawn from noise.

    Columns run across the decal, rows along its length; the albedo's alpha is 0 on every
    border, so a decal never shows its box.
    """
    width, height = TEXTURE_PX[kind]
    rng = np.random.default_rng(KINDS.index(kind))
    across = (np.arange(width) + 0.5) / width
    along = (np.arange(height) + 0.5) / height
    u, v = np.meshgrid(across, along)
    colour, alpha, relief, roughness, metallic = DRAWERS[kind](u, v, rng)
    alpha = alpha * _border_fade(u, v)
    alpha[[0, -1], :] = 0.0
    alpha[:, [0, -1]] = 0.0
    albedo = np.dstack([np.broadcast_to(colour, u.shape + (3,)), alpha[..., None]])
    return (
        Image.fromarray(np.round(np.clip(albedo, 0, 1) * 255).astype(np.uint8), "RGBA"),
        _normal_map(relief, width, height),
        Image.fromarray(
            np.round(
                np.clip(
                    np.dstack([np.ones_like(u), np.broadcast_to(roughness, u.shape), metallic]),
                    0,
                    1,
                )
                * 255
            ).astype(np.uint8),
            "RGB",
        ),
    )


def noise(shape, cells, rng, octaves=4):
    """Return fractal value noise in [0, 1], over `cells` (across, along) at its first octave."""
    height, width = shape
    total = np.zeros(shape)
    weight = 0.0
    for octave in range(octaves):
        grid = rng.random(
            (max(2, cells[1] * 2**octave + 1), max(2, cells[0] * 2**octave + 1))
        ).astype(np.float32)
        layer = np.asarray(Image.fromarray(grid, "F").resize((width, height), Image.BICUBIC))
        total += layer * 0.5**octave
        weight += 0.5**octave
    return np.clip(total / weight, 0.0, 1.0)


def _border_fade(u, v):
    edge = np.minimum(np.minimum(u, 1.0 - u), np.minimum(v, 1.0 - v))
    return np.clip(edge / 0.02, 0.0, 1.0)


def _normal_map(relief, width, height):
    """Return the OpenGL normal map of a height field in pixels of relief per pixel."""
    slope_x = np.gradient(relief, axis=1)
    slope_y = np.gradient(relief, axis=0)
    normal = np.dstack([-slope_x, slope_y, np.ones_like(relief)])
    normal /= np.linalg.norm(normal, axis=-1, keepdims=True)
    return Image.fromarray(np.round((normal * 0.5 + 0.5) * 255).astype(np.uint8), "RGB")


def _tyre_marks(u, v, rng):
    width_m = TYRE_MARKS_WIDTH_M
    lateral_m = (u - 0.5) * width_m
    tracks = np.zeros_like(u)
    for side in (-1.0, 1.0):
        drift_m = (noise(u.shape, (1, 3), rng, 2) - 0.5) * 0.08
        off = np.abs(lateral_m - side * TYRE_TRACK_M / 2.0 - drift_m) / (TYRE_WIDTH_M / 2.0)
        tracks = np.maximum(tracks, np.clip(1.4 - off, 0.0, 1.0) ** 0.7)
    grooves = 0.6 + 0.4 * noise(u.shape, (48, 2), rng, 2)
    strength = 0.55 + 0.45 * noise(u.shape, (2, 6), rng, 3)
    ends = np.clip(v / 0.15, 0.0, 1.0) * np.clip((1.0 - v) / 0.3, 0.0, 1.0)
    alpha = tracks * grooves * strength * ends
    colour = np.array([0.13, 0.13, 0.135])
    return colour, alpha, alpha * 0.3, 0.55 + 0.0 * u, 0.0 * u


def _oil_stain(u, v, rng):
    radius = np.hypot(u - 0.5, v - 0.5) * 2.0
    edge = 0.62 + 0.3 * (noise(u.shape, (3, 3), rng, 4) - 0.5) * 2.0
    body = np.clip((edge - radius) / 0.12, 0.0, 1.0)
    ragged = noise(u.shape, (12, 12), rng, 2)
    for _ in range(3):
        centre = rng.uniform(0.25, 0.75, 2)
        drop = np.hypot(u - centre[0], v - centre[1]) / rng.uniform(0.03, 0.06)
        body = np.maximum(body, np.clip((1.3 - drop - ragged) / 0.4, 0.0, 1.0) * 0.8)
    mottle = 0.65 + 0.35 * noise(u.shape, (6, 6), rng, 3)
    alpha = body * mottle * 0.6
    colour = np.array([0.1, 0.095, 0.085])
    return colour, alpha, alpha * 0.2, 0.75 - 0.4 * body, 0.0 * u


def _patch(u, v, rng):
    jitter = (noise(u.shape, (5, 5), rng, 3) - 0.5) * 0.012
    inset = np.minimum(np.minimum(u, 1.0 - u), np.minimum(v, 1.0 - v)) + jitter
    inside = np.clip((inset - 0.04) / 0.006, 0.0, 1.0)
    seam = np.clip(1.0 - np.abs(inset - 0.04) / 0.007, 0.0, 1.0)
    grain = 0.8 + 0.2 * noise(u.shape, (24, 24), rng, 2)
    alpha = np.maximum(inside * 0.5 * grain, seam * 0.8)
    colour_inside = np.array([0.2, 0.2, 0.21])
    colour_seam = np.array([0.1, 0.1, 0.1])
    share = (seam / np.maximum(alpha, 1e-6) * 0.85)[..., None]
    colour = colour_inside * (1.0 - np.clip(share, 0, 1)) + colour_seam * np.clip(share, 0, 1)
    return colour, alpha, seam * 1.5 + inside * 0.3, 0.7 + 0.0 * u, 0.0 * u


def _manhole(u, v, rng):
    radius = np.hypot(u - 0.5, v - 0.5) * 2.0  # 1 at the decal's side: 0.4 m
    cover = radius < 0.77  # 0.62 m across
    frame = (radius >= 0.77) & (radius < 0.95)
    angle = np.arctan2(v - 0.5, u - 0.5)
    rings = (np.sin(radius * 60.0) > 0.3) & (radius < 0.68)
    spokes = np.cos(angle * 16.0) > 0.85
    relief = np.where(cover, 1.0 + 1.5 * (rings | spokes), 0.0) + np.where(frame, 1.5, 0.0)
    wear = noise(u.shape, (4, 4), rng, 3)
    tone = 0.24 + 0.08 * wear + 0.08 * (rings | spokes)
    colour = np.dstack([tone, tone * 0.97, tone * 0.93])
    alpha = np.clip((0.97 - radius) / 0.02, 0.0, 1.0)
    return colour, alpha, relief, 0.55 - 0.15 * (rings | spokes), 0.5 * (cover | frame)


def _drain(u, v, rng):
    frame = (np.minimum(u, 1.0 - u) < 0.08) | (np.minimum(v, 1.0 - v) < 0.12)
    slots = (np.sin(u * math.pi * 14.0) > 0.2) & ~frame
    relief = np.where(slots, -2.0, 0.5)
    wear = noise(u.shape, (4, 3), rng, 3)
    tone = np.where(slots, 0.04, 0.26 + 0.08 * wear)
    colour = np.dstack([tone, tone * 0.97, tone * 0.93])
    alpha = np.ones_like(u)
    return colour, alpha, relief, 0.5 + 0.0 * u, np.where(slots, 0.0, 0.5)


DRAWERS = {
    "tyre_marks": _tyre_marks,
    "oil_stain": _oil_stain,
    "patch": _patch,
    "manhole": _manhole,
    "drain": _drain,
}


# ------------------------------------------------------------------------------------ whole
def place(ground, sections, edges, racing_offset_m, nodes, carriageways, shadowed):
    """Return the decals of a circuit: braking marks, the photo's evidence and tagged covers.

    `edges` are the lap's asphalt edges (left, right) per section and `racing_offset_m` its
    racing line; `carriageways` the lap and the roads around it, on which tagged `nodes` may
    put covers; `shadowed(x, y)` tells where the photo's dark blots may be shadows.
    """
    sections = {key: np.asarray(sections[key]) for key in ("s", "x", "y", "tx", "ty")}
    clear = [np.asarray(edge) - LINE_CLEAR_M for edge in edges]
    spacing_m = float(np.median(np.diff(sections["s"])))
    darkness, saturation, inside, laterals = lap_darkness(ground, sections, clear[0], clear[1])
    from_photo = sparse(
        photo_decals(
            blots(darkness, saturation, inside), sections, laterals, racing_offset_m, shadowed
        )
    )
    streaks = [decal for decal in from_photo if decal.kind == "tyre_marks"]
    zones = braking_zones(lap_speeds(track_surfaces.lap_curvature(sections), spacing_m))
    braking = away_from(
        braking_marks(sections, zones, racing_offset_m, clear), streaks, MARK_NEAR_STREAK_M
    )
    return braking + from_photo + tagged_covers(nodes, carriageways)
