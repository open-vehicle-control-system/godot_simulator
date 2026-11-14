"""Audit the lines a track pack draws, along the whole lap and every road around it.

    python3 tools/line_audit.py EXPERIMENT_DIR PACKS_DIR TRACK OUT_DIR

Reads what the simulator reads (the pack's track map, roads map and lines images) and works
out, as the terrain shader does, where paint lands on the ground. Per metre of every line it
measures whether the line is drawn, how far it is from the paint and the verge the
orthophoto shows, and how much it steps sideways from one metre to the next. Every zebra
crossing is listed with what supports it. OUT_DIR gets `<track>_audit.json`, the defects as
text on the output, and images: the lap and the roads unrolled over the photo and over its
classification, an overview from above, and a crop from above at the worst defects.

Positions in the report are the pack's (ROS: metres, as `--spawn` takes them).
"""

import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import ground_classes
import numpy as np
import osm
import secondary_roads
import track_surfaces
from PIL import Image, ImageDraw

MAP_TILE_PX = round(track_surfaces.TILE_M / track_surfaces.TRACK_MAP_M_PER_PX)
SEAM_M = 8.0  # the terrain shader's: texels further apart along a road are not blended
LINE_WIDTH_M = 0.15
KERB_FROM_M = 0.05
ROAD_ROWS = secondary_roads.ROWS_PER_BAND
DOUBLE_LINE = 254
CROSSING = 2
CROSSING_STRIPE_M = 0.5

SAMPLE_STEP_M = 0.02  # across a line, where paint is looked for
LAP_REACH_M = 16.0
ROAD_BEYOND_M = 3.0
PHOTO_STEP_M = 0.125
PAINT_MAX_WIDTH_M = 0.9
PAINT_NEAR_M = 2.5  # how far from a drawn line the photo's line is looked for
ON_PAINT_M = 0.5  # paint this close to where a line would run is that line's
GAP_MIN_M = 3.0
GAP_PAINTED_SHARE = 0.6
MISPLACED_M = 0.3
MISPLACED_MIN_M = 3.0
MISPLACED_MEDIAN_M = 5
KINK_M = 0.05
ON_VERGE_M = 0.25
EDGE_RUN_M = 0.5
UNSHOWN_MIN_M = 10.0
UNSHOWN_SHARE = 0.1
CROSSING_NODE_M = 8.0
CROSSING_SAME_M = 12.0
CROSSING_LENGTH_M = (2.5, 6.5)
CROSSING_MIN_DRAWN = 0.7
CROSSING_MIN_PAVED = 0.7
CROSSING_MIN_STRIPES = 3
STRIP_M = 500
STRIPS_PER_SHEET = 5
STRIP_PX_PER_M = 4
CROP_M = 50.0
ROAD_STRIP_REACH_M = 10.0
CROP_PX_PER_M = 16
WORST_CROPS = 6
PAVED = (ground_classes.WORN_ASPHALT, ground_classes.TRACK_ASPHALT)
GREEN = (
    ground_classes.LAWN,
    ground_classes.MEADOW,
    ground_classes.DRY_GRASS,
    ground_classes.FOREST_FLOOR,
)


def decode_road_map(image):
    """Return a road map image as (metres along, metres right), NaN away from any road."""
    texel = image.astype(np.int64)
    along_steps = (texel[..., 0] << 12) | (texel[..., 1] << 4) | (texel[..., 2] >> 4)
    right_steps = ((texel[..., 2] & 15) << 8) | texel[..., 3]
    on_road = right_steps != track_surfaces.OFF_ROAD
    along = np.where(on_road, along_steps * track_surfaces.ALONG_UNIT_M, np.nan)
    right = np.where(
        on_road,
        (right_steps - track_surfaces.RIGHT_ZERO) * track_surfaces.RIGHT_UNIT_M,
        np.nan,
    )
    return along, right


class MapMosaic:
    """A pack's road maps as one array each, read where the terrain shader reads them."""

    def __init__(self, directory, mosaic):
        """Read the `<east>_<north>.png` road maps of `directory` onto `mosaic`'s ground."""
        self.west, self.north = mosaic.west, mosaic.north
        shape = tuple(
            round(side / mosaic.px_per_m / track_surfaces.TRACK_MAP_M_PER_PX)
            for side in mosaic.rgb.shape[:2]
        )
        self.along = np.full(shape, np.nan)
        self.right = np.full(shape, np.nan)
        for corner in mosaic.tile_corners:
            path = Path(directory) / f"{corner[0]}_{corner[1]}.png"
            if not path.exists():
                continue
            row, column = (
                round(px / mosaic.px_per_m / track_surfaces.TRACK_MAP_M_PER_PX)
                for px in mosaic.tile_origin_px(corner)
            )
            window = (slice(row, row + MAP_TILE_PX), slice(column, column + MAP_TILE_PX))
            self.along[window], self.right[window] = decode_road_map(
                np.asarray(Image.open(path).convert("RGBA"))
            )

    def texel_centres(self):
        """Return the map positions (east, north) of every texel's centre."""
        rows, columns = np.indices(self.along.shape)
        return (
            self.west + (columns + 0.5) * track_surfaces.TRACK_MAP_M_PER_PX,
            self.north - (rows + 0.5) * track_surfaces.TRACK_MAP_M_PER_PX,
        )

    def coordinates(self, east, north, wrap_m):
        """Return (along, right, at a seam) at map positions as the terrain shader reads them.

        The four texels around a position are blended, within its tile: a tile's map is a
        texture of its own, and by its border the coordinates carry on as its last two
        texels have them. NaN where one of them is off the road. Where they are further
        than SEAM_M apart along the road the nearest texel's stand. `wrap_m` is the lap's
        length, None for roads that do not close.
        """
        column = (np.asarray(east, np.float64) - self.west) / track_surfaces.TRACK_MAP_M_PER_PX
        row = (self.north - np.asarray(north, np.float64)) / track_surfaces.TRACK_MAP_M_PER_PX
        height, width = self.along.shape
        outside = (column < 0) | (row < 0) | (column >= width) | (row >= height)
        column, row = np.clip(column, 0, width - 1e-6), np.clip(row, 0, height - 1e-6)
        tile_column = np.floor(column / MAP_TILE_PX) * MAP_TILE_PX
        tile_row = np.floor(row / MAP_TILE_PX) * MAP_TILE_PX
        at_column, at_row = column - tile_column - 0.5, row - tile_row - 0.5
        corner_column = np.clip(np.floor(at_column), 0, MAP_TILE_PX - 2)
        corner_row = np.clip(np.floor(at_row), 0, MAP_TILE_PX - 2)
        within_column, within_row = at_column - corner_column, at_row - corner_row
        along = np.zeros(column.shape)
        right = np.zeros(column.shape)
        first = None
        seam = np.zeros(column.shape, bool)
        for offset_row in (0, 1):
            for offset_column in (0, 1):
                rows = (tile_row + corner_row + offset_row).astype(int)
                columns = (tile_column + corner_column + offset_column).astype(int)
                texel_along, texel_right = self.along[rows, columns], self.right[rows, columns]
                if first is None:
                    first = texel_along
                if wrap_m is not None:
                    texel_along = texel_along + wrap_m * np.round((first - texel_along) / wrap_m)
                seam |= np.abs(texel_along - first) > SEAM_M
                share = (within_column if offset_column else 1.0 - within_column) * (
                    within_row if offset_row else 1.0 - within_row
                )
                along += share * texel_along
                right += share * texel_right
        nearest_rows = np.clip(np.floor(at_row + 0.5), 0, MAP_TILE_PX - 1) + tile_row
        nearest_columns = np.clip(np.floor(at_column + 0.5), 0, MAP_TILE_PX - 1) + tile_column
        nearest = (nearest_rows.astype(int), nearest_columns.astype(int))
        along = np.where(seam, self.along[nearest], along)
        right = np.where(seam, self.right[nearest], right)
        if wrap_m is not None:
            along = np.mod(along, wrap_m)
        along[outside] = np.nan
        return along, np.where(np.isnan(along), np.nan, right), seam & ~np.isnan(along)

    def marking_coordinates(self, east, north):
        """Return (along, right) of open roads where the shader paints their markings.

        As `coordinates`, NaN too at a seam: where two roads meet the coordinates are a
        texel's, and paint drawn from them would be a staircase.
        """
        along, right, seam = self.coordinates(east, north, None)
        return np.where(seam, np.nan, along), np.where(seam, np.nan, right)


def _paint_coordinates(road_map, east, north, wrap_m):
    """Return (along, right) where paint is drawn: the lap's (`wrap_m`), or open roads'."""
    if wrap_m is None:
        return road_map.marking_coordinates(east, north)
    return road_map.coordinates(east, north, wrap_m)[:2]


def centrelines(road_map, first_m, count, reach_m, wrap_m=None):
    """Return each metre's centre, right-hand normal and heading of a road, as its map has it.

    Three arrays (`count` x 2, east and north), from `first_m` along the map's axis: per
    metre, the plane fitted through the positions of the texels within `reach_m` of the
    centreline. NaN where the map holds too few texels of that metre.
    """
    east, north = road_map.texel_centres()
    along, right = road_map.along, road_map.right
    last_m = first_m + count
    if wrap_m is None:
        near = (along > first_m - 1.5) & (along < last_m + 1.5) & (np.abs(right) <= reach_m)
        along, right, east, north = along[near], right[near], east[near], north[near]
    else:
        near = np.abs(right) <= reach_m
        along, right, east, north = along[near], right[near], east[near], north[near]
        head, tail = along < 2.0, along > wrap_m - 2.0
        along = np.concatenate([along, along[head] + wrap_m, along[tail] - wrap_m])
        right = np.concatenate([right, right[head], right[tail]])
        east = np.concatenate([east, east[head], east[tail]])
        north = np.concatenate([north, north[head], north[tail]])
    order = np.argsort(along)
    along, right, east, north = along[order], right[order], east[order], north[order]
    centre = np.full((count, 2), np.nan)
    normal = np.full((count, 2), np.nan)
    heading = np.full((count, 2), np.nan)
    for index in range(count):
        metre = first_m + index
        low, high = np.searchsorted(along, [metre - 0.75, metre + 0.75])
        if high - low < 8 or np.ptp(right[low:high]) < 1.0:
            continue
        design = np.stack([np.ones(high - low), right[low:high], along[low:high] - metre], 1)
        fitted = np.linalg.lstsq(
            design, np.stack([east[low:high], north[low:high]], 1), rcond=None
        )[0]
        centre[index] = fitted[0]
        normal[index] = fitted[1] / max(np.hypot(*fitted[1]), 1e-9)
        heading[index] = fitted[2] / max(np.hypot(*fitted[2]), 1e-9)
    return centre, normal, heading


def sixteen_bits(image, channel):
    """Return the 16-bit numbers an image holds from `channel` (high byte, then low)."""
    return image[..., channel].astype(np.float64) * 256.0 + image[..., channel + 1]


def between_metres(values, at):
    """Return per-metre `values` (metres along their last axis) at `at` metres, blended."""
    last = values.shape[-1] - 1
    at = np.clip(np.nan_to_num(at), 0, last)
    low = np.floor(at).astype(int)
    share = at - low
    return values[..., low] * (1 - share) + values[..., np.minimum(low + 1, last)] * share


def lap_paint(lines, along, right):
    """Return where the terrain shader paints the lap's edge lines and kerbs.

    `lines` is the road lines image; `along` and `right` are track coordinates. Two flag
    arrays: the white line and the kerb.
    """
    side = (np.nan_to_num(right) >= 0).astype(int)
    edges = np.stack([sixteen_bits(lines[0], 0), sixteen_bits(lines[0], 2)])
    edge = np.choose(side, between_metres(edges, along)) * track_surfaces.EDGE_UNIT_M
    kerbs = lines[1, :, :2].astype(np.float64).T
    kerb = np.choose(side, between_metres(kerbs, along)) * track_surfaces.KERB_UNIT_M
    flags = lines[2, :, :2].astype(np.float64).T
    painted = np.choose(side, between_metres(flags, along)) >= 127.5
    from_centre = np.abs(right)
    outer = edge - track_surfaces.LINE_INSET_M
    line = painted & (from_centre >= outer - LINE_WIDTH_M) & (from_centre <= outer)
    kerbed = (kerb >= KERB_FROM_M) & (from_centre >= edge) & (from_centre <= edge + kerb)
    on_map = ~np.isnan(along)
    return line & on_map, kerbed & on_map


def lap_line_offsets(lines, metres):
    """Return, per side, where the lap's line is meant at whole metres: (centre, painted)."""
    row = lines[:, np.clip(metres, 0, lines.shape[1] - 1)]
    found = []
    for side in range(2):
        edge = sixteen_bits(row[0], 2 * side) * track_surfaces.EDGE_UNIT_M
        centre = edge - track_surfaces.LINE_INSET_M - LINE_WIDTH_M / 2.0
        found.append((centre, row[2, :, side] >= 127.5))
    return found


def road_spans(lines):
    """Return the roads of a roads' lines image as (first column on the axis, length in m)."""
    spans = []
    for band in range(lines.shape[0] // ROAD_ROWS):
        used = np.concatenate([[False], lines[band * ROAD_ROWS, :, :2].any(-1), [False]])
        changes = np.flatnonzero(np.diff(used.astype(int)))
        for first, beyond in zip(changes[::2], changes[1::2], strict=True):
            # A road's first and last columns are repeated in two columns around it.
            spans.append((int(band * lines.shape[1] + first + 2), int(beyond - first - 4)))
    return spans


def _band(lines, along):
    """Return the first row of the band `along` is in, and its column there."""
    width = lines.shape[1]
    band = np.floor(np.nan_to_num(along) / width).astype(int)
    first_row = np.clip(band, 0, lines.shape[0] // ROAD_ROWS - 1) * ROAD_ROWS
    return first_row, np.nan_to_num(along) - band * width


def _half_width(lines, first_row, column):
    width = lines.shape[1]
    low = np.clip(np.floor(column).astype(int), 0, width - 1)
    high = np.minimum(low + 1, width - 1)
    share = column - low
    blended = sixteen_bits(lines[first_row, low], 0) * (1 - share)
    blended += sixteen_bits(lines[first_row, high], 0) * share
    return blended * track_surfaces.EDGE_UNIT_M, (low, high, share)


def road_paint(lines, along, right, dashes_m=()):
    """Return where the terrain shader paints lines along the roads.

    `dashes_m` are the dashed patterns' (dash, gap); without them dashes are drawn solid.
    """
    first_row, column = _band(lines, along)
    half_width, (low, high, share) = _half_width(lines, first_row, column)
    nearest = np.clip(np.floor(column + 0.5).astype(int), 0, lines.shape[1] - 1)
    painted = np.zeros(np.shape(along), bool)
    for line in range(secondary_roads.MAX_LINES):
        row = first_row + 2 + line
        offset = sixteen_bits(lines[row, low], 0) * (1 - share)
        offset += sixteen_bits(lines[row, high], 0) * share
        offset = (offset - secondary_roads.OFFSET_ZERO) * track_surfaces.EDGE_UNIT_M
        pattern = lines[row, nearest, 2]
        off = right - offset
        off = np.where(pattern == DOUBLE_LINE, np.abs(off) - LINE_WIDTH_M, off)
        dashed = np.ones(np.shape(along), bool)
        for index, (dash_m, gap_m) in enumerate(dashes_m):
            dashed &= (pattern != index + 1) | (np.mod(along, dash_m + gap_m) <= dash_m)
        painted |= (pattern > 0) & dashed & (np.abs(off) <= LINE_WIDTH_M / 2.0)
    return painted & (np.abs(right) <= half_width) & ~np.isnan(along)


def road_extent(lines, along, right):
    """Return where the roads' fitted edges and their zebra crossings are, as flags."""
    first_row, column = _band(lines, along)
    half_width, _ = _half_width(lines, first_row, column)
    across = lines[first_row + 1, np.clip(column.astype(int), 0, lines.shape[1] - 1)]
    ends = (across[..., 1:3].astype(np.float64) - 128.0) * secondary_roads.ENDS_UNIT_M
    on_map = ~np.isnan(along)
    edge = on_map & (np.abs(np.abs(right) - half_width) <= PHOTO_STEP_M / 2.0)
    crossing = (across[..., 0] == CROSSING) & (right >= ends[..., 0]) & (right <= ends[..., 1])
    return edge, crossing & on_map & (np.abs(right) <= half_width)


def photo_paint(luminance, laterals_m):
    """Return which samples of cross profiles (rows) are a line's paint, as the builder tells.

    Each side of the centreline is read outwards from it: a line against lighter ground
    shows as that ground's inner rim.
    """
    right = laterals_m >= 0.0
    paint = np.zeros(luminance.shape, bool)
    no_kerb = np.zeros(luminance.shape, bool)
    paint[:, right] = track_surfaces.line_paint(luminance[:, right], no_kerb[:, right])
    paint[:, ~right] = track_surfaces.line_paint(luminance[:, ~right][:, ::-1], no_kerb[:, ~right])[
        :, ::-1
    ]
    return paint


def road_photo_paint(luminance, laterals_m):
    """Return which samples of cross profiles (rows) are paint on a road around the lap.

    Lighter than the median across it, as the roads' builder tells: a road's lanes and
    patches are lit borders too, and no line runs along those.
    """
    step_m = laterals_m[1] - laterals_m[0]
    window = round(secondary_roads.PAINT_ACROSS_M / step_m) | 1
    padded = np.pad(luminance, ((0, 0), (window // 2, window // 2)), mode="reflect")
    around = np.median(np.lib.stride_tricks.sliding_window_view(padded, window, axis=1), -1)
    return luminance - around >= secondary_roads.PAINT_CONTRAST


def paint_runs(flags, laterals_m):
    """Return the middles (m) of a profile's runs of paint no wider than a line shows."""
    changes = np.flatnonzero(np.diff(np.concatenate([[False], flags, [False]]).astype(int)))
    step_m = laterals_m[1] - laterals_m[0]
    return [
        (laterals_m[first] + laterals_m[beyond - 1]) / 2.0
        for first, beyond in zip(changes[::2], changes[1::2], strict=True)
        if (beyond - first) * step_m <= PAINT_MAX_WIDTH_M
    ]


def nearest_paint(flags, laterals_m, wanted_m, reach_m):
    """Return, per profile, the photo's line nearest `wanted_m` within `reach_m`, else NaN."""
    found = np.full(len(flags), np.nan)
    for index, wanted in enumerate(wanted_m):
        if np.isnan(wanted):
            continue
        runs = paint_runs(flags[index], laterals_m)
        if runs:
            nearest = min(runs, key=lambda run: abs(run - wanted))
            if abs(nearest - wanted) <= reach_m:
                found[index] = nearest
    return found


def runs_of(flags, least):
    """Return the (first, beyond) of each run of at least `least` true flags."""
    changes = np.flatnonzero(np.diff(np.concatenate([[False], flags, [False]]).astype(int)))
    return [
        (int(first), int(beyond))
        for first, beyond in zip(changes[::2], changes[1::2], strict=True)
        if beyond - first >= least
    ]


def kinks(points):
    """Return how far each point of a line (N x 2) steps sideways off its smooth course.

    The sideways part of the line's second difference, less its median over the metres
    around: a bend is not a step. NaN next to a missing point.
    """
    second = points[2:] - 2.0 * points[1:-1] + points[:-2]
    chord = points[2:] - points[:-2]
    length = np.maximum(np.hypot(chord[:, 0], chord[:, 1]), 1e-9)
    sideways = (second[:, 0] * chord[:, 1] - second[:, 1] * chord[:, 0]) / length
    padded = np.pad(sideways, 3, mode="edge")
    smooth = np.nanmedian(np.lib.stride_tricks.sliding_window_view(padded, 7), -1)
    return np.concatenate([[np.nan], np.abs(sideways - smooth), [np.nan]])


def running_nanmedian(values, window):
    """Return the running median of `values`, ignoring NaN; NaN where a window is empty."""
    padded = np.pad(values, window // 2, mode="constant", constant_values=np.nan)
    views = np.lib.stride_tricks.sliding_window_view(padded, window)
    filled = np.where(np.isnan(views).all(-1, keepdims=True), 0.0, views)
    return np.where(np.isnan(views).all(-1), np.nan, np.nanmedian(filled, -1))


@dataclass
class LineSurvey:
    """One line, per metre: what the pack means, what is drawn, what the photo shows.

    Laterals are metres right of the centreline the map holds. `covered` tells where any
    line is drawn on the line's course, `drawn_m` where the line itself is. `shown_m` is the photo's
    line near the drawn (or meant) one, `verge_m` where the photo's vegetation starts
    beyond the centreline on the line's side (NaN when there is none), `points` where the line is
    drawn on the ground (east, north).
    """

    name: str
    first_m: int
    meant_m: np.ndarray
    painted: np.ndarray
    covered: np.ndarray
    drawn_m: np.ndarray
    shown_m: np.ndarray
    verge_m: np.ndarray
    points: np.ndarray


def line_defects(line, closed):
    """Return the defects of one line as dicts: kind, from_m, to_m, worst_m."""
    count = len(line.meant_m)
    drawn = ~np.isnan(line.drawn_m)
    on_paint = np.abs(line.shown_m - line.meant_m) <= ON_PAINT_M
    defects = []

    def add(kind, first, beyond, worst):
        defects.append(
            {
                "line": line.name,
                "kind": kind,
                "from_m": int(line.first_m + first),
                "to_m": int(line.first_m + beyond),
                "worst_m": round(float(worst), 3),
            }
        )

    for first, beyond in runs_of(~line.covered, round(GAP_MIN_M)):
        if not closed and (first == 0 or beyond == count):
            continue
        if on_paint[first:beyond].mean() >= GAP_PAINTED_SHARE:
            add("gap over the photo's line", first, beyond, beyond - first)
    off = running_nanmedian(line.drawn_m - line.shown_m, MISPLACED_MEDIAN_M)
    for first, beyond in runs_of(np.abs(off) > MISPLACED_M, round(MISPLACED_MIN_M)):
        add("off the photo's line", first, beyond, np.nanmax(np.abs(off[first:beyond])))
    on_verge = np.sign(line.meant_m) * (line.drawn_m - line.verge_m)
    for first, beyond in runs_of(on_verge > ON_VERGE_M, round(MISPLACED_MIN_M)):
        add("on the verge", first, beyond, np.nanmax(on_verge[first:beyond]))
    points = np.concatenate([line.points[-1:], line.points, line.points[:1]]) if closed else None
    stepped = kinks(points)[1:-1] if closed else kinks(line.points)
    for index in np.flatnonzero(stepped > KINK_M):
        add("sideways step", int(index), int(index) + 1, stepped[index])
    unshown = drawn & np.isnan(line.shown_m)
    for first, beyond in runs_of(unshown, round(UNSHOWN_MIN_M)):
        add("drawn where the photo shows no line", first, beyond, beyond - first)
    return defects


class Audit:
    """A pack's lines against its photo."""

    def __init__(self, experiment, packs, track_id):
        """Read the pack `track_id` of `packs` and the experiment's photo and map of it."""
        data = Path(experiment) / "data" / track_id
        self.pack = Path(packs) / track_id
        self.track_id = track_id
        self.origin = json.loads((data / "frame.json").read_text())["origin"][:2]
        self.ground = json.loads((self.pack / "pack.json").read_text())["track"]["ground"]
        self.mosaic = track_surfaces.Mosaic(data / "ortho")
        self.labels = track_surfaces.classify_mosaic(self.mosaic.rgb, self.ground["photo_grade"])
        self.extract = osm.read(data / f"{track_id}_area.osm", self.origin)
        self.lap_length_m = self.ground["road"]["lap_length_m"]
        self.lap_map = MapMosaic(self.pack / "track", self.mosaic)
        self.roads_map = MapMosaic(self.pack / "roads", self.mosaic)
        self.lap_lines = np.asarray(Image.open(self.pack / "road_lines.png").convert("RGBA"))
        self.roads_lines = np.asarray(Image.open(self.pack / "roads_lines.png").convert("RGBA"))

    def luminance(self, east, north):
        """Return how light the photo is at map positions, 0 to 1."""
        rows, columns = self.mosaic.pixel(east, north)
        return self.mosaic.rgb[rows, columns] @ np.array([0.3, 0.59, 0.11]) / 255.0

    def paved(self, east, north):
        """Return where the photo shows asphalt at map positions."""
        rows, columns = self.mosaic.pixel(east, north)
        return np.isin(self.labels[rows, columns], PAVED)

    def green(self, east, north):
        """Return where the photo shows vegetation at map positions."""
        rows, columns = self.mosaic.pixel(east, north)
        return np.isin(self.labels[rows, columns], GREEN)

    def pack_position(self, point):
        """Return a map position (east, north) as the pack's ROS x, y."""
        return [
            round(float(self.origin[1] - point[1]), 1),
            round(float(point[0] - self.origin[0]), 1),
        ]

    def survey_lines(
        self, road_map, wrap_m, first_m, count, reach_m, paint_of, photo_paint_of, meant
    ):
        """Return the LineSurveys of one road and its (centre, normal, heading) per metre.

        `paint_of(along, right)` flags where the shader paints a line,
        `photo_paint_of(luminance, laterals)` where the photo shows one; `meant` lists
        each line as (name, lateral per metre, painted per metre).
        """
        centre, normal, heading = centrelines(road_map, first_m, count, reach_m, wrap_m)
        laterals = np.arange(-reach_m, reach_m, SAMPLE_STEP_M)
        east = centre[:, :1] + normal[:, :1] * laterals[None, :]
        north = centre[:, 1:] + normal[:, 1:] * laterals[None, :]
        along, right = _paint_coordinates(
            road_map, np.nan_to_num(east, nan=-1e9), np.nan_to_num(north, nan=-1e9), wrap_m
        )
        if wrap_m is None:
            along[(along < first_m - 1.0) | (along > first_m + count + 1.0)] = np.nan
        drawn = paint_of(along, np.where(np.isnan(along), np.nan, right))
        photo_laterals = np.arange(-reach_m, reach_m, PHOTO_STEP_M)
        photo_east = centre[:, :1] + normal[:, :1] * photo_laterals[None, :]
        photo_north = centre[:, 1:] + normal[:, 1:] * photo_laterals[None, :]
        known = ~np.isnan(photo_east)
        luminance = self.luminance(np.nan_to_num(photo_east), np.nan_to_num(photo_north))
        paint = photo_paint_of(luminance, photo_laterals) & known
        verge = self.green(np.nan_to_num(photo_east), np.nan_to_num(photo_north)) & known
        surveys = []
        for name, meant_m, painted in meant:
            near = np.abs(laterals[None, :] - meant_m[:, None]) <= ON_PAINT_M
            covered = drawn & near
            drawn_m = np.where(
                covered.any(1) & painted,
                (covered * laterals[None, :]).sum(1) / np.maximum(covered.sum(1), 1),
                np.nan,
            )
            wanted = np.where(np.isnan(drawn_m), meant_m, drawn_m)
            wanted = np.where(np.isnan(centre[:, 0]), np.nan, wanted)
            reach = np.where(np.isnan(drawn_m), ON_PAINT_M, PAINT_NEAR_M)
            shown = np.array(
                [
                    nearest_paint(paint[index : index + 1], photo_laterals, [at], reach[index])[0]
                    for index, at in enumerate(wanted)
                ]
            )
            side = np.sign(np.nanmedian(meant_m)) or 1.0
            outwards = (side * photo_laterals >= 1.0)[None, :] & verge
            if side < 0:
                outwards = outwards[:, ::-1]
            ends = track_surfaces.first_run(outwards, round(EDGE_RUN_M / PHOTO_STEP_M))
            ordered = photo_laterals[::-1] if side < 0 else photo_laterals
            verge_m = np.where(ends >= 0, ordered[np.maximum(ends, 0)], np.nan)
            points = centre + normal * drawn_m[:, None]
            surveys.append(
                LineSurvey(
                    name, first_m, meant_m, painted, covered.any(1), drawn_m, shown, verge_m, points
                )
            )
        return surveys, (centre, normal, heading)

    def lap(self):
        """Return the lap's two edge lines surveyed, and its geometry per metre."""
        count = math.floor(self.lap_length_m)
        offsets = lap_line_offsets(self.lap_lines, np.arange(count))
        meant = [
            (name, sign * centre_m, painted)
            for (name, sign), (centre_m, painted) in zip(
                (("lap left", -1.0), ("lap right", 1.0)), offsets, strict=True
            )
        ]
        return self.survey_lines(
            self.lap_map,
            self.lap_length_m,
            0,
            count,
            LAP_REACH_M,
            lambda along, right: lap_paint(self.lap_lines, along, right)[0],
            photo_paint,
            meant,
        )

    def roads(self):
        """Return, per road around the lap: (first_m, length, line surveys, geometry)."""
        found = []
        width = self.roads_lines.shape[1]
        for number, (first_m, length) in enumerate(road_spans(self.roads_lines)):
            if length < 2:
                continue
            row = (first_m // width) * ROAD_ROWS
            columns = first_m % width + np.arange(length)
            half_width = (
                sixteen_bits(self.roads_lines[row, columns], 0) * track_surfaces.EDGE_UNIT_M
            )
            meant = []
            for index in range(secondary_roads.MAX_LINES):
                texels = self.roads_lines[row + 2 + index, columns]
                if not texels[:, 2].any():
                    continue
                offset = sixteen_bits(texels, 0) - secondary_roads.OFFSET_ZERO
                meant.append(
                    (
                        f"road {number} line {index}",
                        offset * track_surfaces.EDGE_UNIT_M,
                        texels[:, 2] > 0,
                    )
                )
            surveys, geometry = self.survey_lines(
                self.roads_map,
                None,
                first_m,
                length,
                float(half_width.max()) + ROAD_BEYOND_M,
                lambda along, right: road_paint(self.roads_lines, along, right),
                road_photo_paint,
                meant,
            )
            found.append((first_m, length, surveys, geometry))
        return found

    def crossings(self, roads):
        """Return every zebra crossing the pack draws, with what supports it."""
        nodes = [
            node
            for node in self.extract.nodes
            if node.tags.get("highway") == "crossing" or "crossing" in node.tags
        ]
        width = self.roads_lines.shape[1]
        found = []
        for number, (first_m, length, _, (centre, normal, heading)) in enumerate(roads):
            row = (first_m // width) * ROAD_ROWS
            columns = first_m % width + np.arange(length)
            across = self.roads_lines[row + 1, columns]
            for first, beyond in runs_of(across[:, 0] == CROSSING, 1):
                known = np.flatnonzero(~np.isnan(centre[:, 0]))
                if len(known) == 0:
                    continue
                middle = int(known[np.abs(known - (first + beyond) // 2).argmin()])
                left, right = (
                    across[middle, 1:3].astype(float) - 128.0
                ) * secondary_roads.ENDS_UNIT_M
                at = centre[middle] + normal[middle] * (left + right) / 2.0
                found.append(
                    {
                        "road": number,
                        "from_m": first_m + first,
                        "to_m": first_m + beyond,
                        "position": self.pack_position(at),
                        "heading_deg": round(
                            math.degrees(math.atan2(heading[middle][0], -heading[middle][1])), 1
                        ),
                        "length_m": beyond - first,
                        "width_m": round(float(right - left), 2),
                        "stripes": int((right - left) / (2.0 * CROSSING_STRIPE_M)),
                        **self._crossing_support(
                            first_m, first, beyond, left, right, centre, normal, nodes, at
                        ),
                        "_at": at,
                    }
                )
        for index, crossing in enumerate(found):
            crossing["problems"] = crossing_problems(crossing, found[:index] + found[index + 1 :])
        for crossing in found:
            del crossing["_at"]
        return found

    def _crossing_support(self, first_m, first, beyond, left, right, centre, normal, nodes, at):
        metres = np.arange(first, beyond)
        laterals = np.arange(left, right, 0.1)
        east = (centre[metres, :1] + normal[metres, :1] * laterals[None, :]).ravel()
        north = (centre[metres, 1:] + normal[metres, 1:] * laterals[None, :]).ravel()
        known = ~np.isnan(east)
        east, north = east[known], north[known]
        along, _ = self.roads_map.marking_coordinates(east, north)
        drawn = (along >= first_m + first - 0.5) & (along <= first_m + beyond + 0.5)
        around = np.concatenate(
            [np.arange(first - 6, first - 1), np.arange(beyond + 1, beyond + 6)]
        )
        around = around[(around >= 0) & (around < len(centre))]
        before_after = self.luminance(
            (centre[around, :1] + normal[around, :1] * laterals[None, :]).ravel(),
            (centre[around, 1:] + normal[around, 1:] * laterals[None, :]).ravel(),
        )
        own = at - np.array(self.origin)
        distances = [float(np.hypot(*(node.point - own))) for node in nodes]
        nearest = int(np.argmin(distances)) if distances else -1
        mapped = nearest >= 0 and distances[nearest] <= CROSSING_NODE_M
        contrast = float(np.mean(self.luminance(east, north)) - np.nanmedian(before_after))
        return {
            "drawn_share": round(float(drawn.mean()), 2) if len(east) else 0.0,
            "paved_share": round(float(self.paved(east, north).mean()), 2) if len(east) else 0.0,
            "photo_contrast": round(contrast, 3),
            "osm_node": nodes[nearest].identifier if mapped else None,
            "osm_node_m": round(distances[nearest], 1) if mapped else None,
            "source": ("osm node" if mapped else "")
            + (" and " if mapped and contrast >= track_surfaces.PAINT_CONTRAST / 2 else "")
            + ("photo" if contrast >= track_surfaces.PAINT_CONTRAST / 2 else "")
            or "unsupported",
        }


def crossing_problems(crossing, others):
    """Return what is wrong with a crossing, given the other crossings drawn."""
    problems = []
    if not CROSSING_LENGTH_M[0] <= crossing["length_m"] <= CROSSING_LENGTH_M[1]:
        problems.append("length")
    if crossing["stripes"] < CROSSING_MIN_STRIPES:
        problems.append("too few stripes")
    if crossing["drawn_share"] < CROSSING_MIN_DRAWN:
        problems.append("clipped or under another road")
    if crossing["paved_share"] < CROSSING_MIN_PAVED:
        problems.append("not on paved ground")
    if crossing["source"] == "unsupported":
        problems.append("no map node and no paint in the photo")
    near = [
        other for other in others if np.hypot(*(other["_at"] - crossing["_at"])) <= CROSSING_SAME_M
    ]
    if near:
        problems.append(f"duplicate of {len(near)} within {CROSSING_SAME_M:g} m")
    return problems


def _strip_image(audit, road_map, wrap_m, geometry, first_m, reach_m, paint_of, backdrop):
    """Return a road unrolled: columns along it, rows across it, paint over `backdrop`."""
    centre, normal, _ = geometry
    count = len(centre)
    at = np.arange(0, count - 1 + 1e-9, 1.0 / STRIP_PX_PER_M)
    index = np.minimum(at.astype(int), count - 2)
    share = (at - index)[:, None]
    middle = centre[index] * (1 - share) + centre[index + 1] * share
    across = normal[index] * (1 - share) + normal[index + 1] * share
    laterals = np.arange(-reach_m, reach_m, PHOTO_STEP_M)
    east = np.nan_to_num(middle[None, :, 0] + across[None, :, 0] * laterals[:, None], nan=-1e9)
    north = np.nan_to_num(middle[None, :, 1] + across[None, :, 1] * laterals[:, None], nan=-1e9)
    rows, columns = audit.mosaic.pixel(east, north)
    image = backdrop[rows, columns].copy()
    along, right = _paint_coordinates(road_map, east, north, wrap_m)
    if wrap_m is None:
        along[(along < first_m - 1.0) | (along > first_m + count + 1.0)] = np.nan
    painted = paint_of(along, np.where(np.isnan(along), np.nan, right))
    for flags, colour in reversed(list(zip(painted, COLOURS, strict=False))):
        # Only the border of what is filled (a kerb, a crossing): the photo shows through.
        border = flags & ~(np.roll(flags, 1, 0) & np.roll(flags, -1, 0))
        image[border] = colour
    image[east < -1e8] = 0
    return image


COLOURS = ((255, 0, 255), (0, 255, 255), (255, 255, 0))
CLASS_COLOURS = np.array(
    [
        (60, 140, 60),
        (40, 110, 40),
        (150, 150, 70),
        (120, 90, 60),
        (190, 170, 130),
        (90, 90, 90),
        (120, 120, 120),
        (20, 70, 30),
    ],
    np.uint8,
)


def _marked(strip, defects, first_m):
    """Return a strip with a red tick above every defect's metres."""
    marked = np.concatenate([np.zeros((6, strip.shape[1], 3), np.uint8), strip])
    for defect in defects:
        low = max((defect["from_m"] - first_m) * STRIP_PX_PER_M, 0)
        high = (defect["to_m"] - first_m) * STRIP_PX_PER_M
        marked[:6, low:high] = (255, 40, 40)
    return marked


def write_sheets(marked, path_stem):
    """Write an unrolled, marked road as sheets of STRIPS_PER_SHEET strips of STRIP_M each."""
    width = STRIP_M * STRIP_PX_PER_M
    pieces = [marked[:, start : start + width] for start in range(0, marked.shape[1], width)]
    for sheet in range(0, len(pieces), STRIPS_PER_SHEET):
        rows = pieces[sheet : sheet + STRIPS_PER_SHEET]
        canvas = np.zeros((len(rows) * (marked.shape[0] + 4), width, 3), np.uint8)
        for index, piece in enumerate(rows):
            top = index * (marked.shape[0] + 4)
            canvas[top : top + marked.shape[0], : piece.shape[1]] = piece
        Image.fromarray(canvas).save(f"{path_stem}_{sheet // STRIPS_PER_SHEET:02d}.png")


def write_crop(audit, point, path):
    """Write the ground around a map position from above, with the paint the pack draws."""
    side = round(CROP_M * CROP_PX_PER_M)
    offsets = (np.arange(side) + 0.5) / CROP_PX_PER_M - CROP_M / 2.0
    east = point[0] + offsets[None, :] + 0.0 * offsets[:, None]
    north = point[1] - offsets[:, None] + 0.0 * offsets[None, :]
    rows, columns = audit.mosaic.pixel(east, north)
    image = audit.mosaic.rgb[rows, columns].copy()
    along, right, _ = audit.lap_map.coordinates(east, north, audit.lap_length_m)
    line, kerb = lap_paint(audit.lap_lines, along, right)
    image[kerb] = COLOURS[1]
    image[line] = COLOURS[0]
    along, right = audit.roads_map.marking_coordinates(east, north)
    image[road_paint(audit.roads_lines, along, right) & ~line] = (255, 160, 0)
    Image.fromarray(image).save(path)


def write_overview(audit, lines, defects, path):
    """Write the whole area from above, 1 m per pixel: drawn lines, and defects in red."""
    step = round(audit.mosaic.px_per_m)
    image = Image.fromarray(audit.mosaic.rgb[::step, ::step].copy())
    pen = ImageDraw.Draw(image)

    def pixel(point):
        return (point[0] - audit.mosaic.west, audit.mosaic.north - point[1])

    for line in lines:
        for first, beyond in runs_of(~np.isnan(line.points[:, 0]), 2):
            pen.line([pixel(point) for point in line.points[first:beyond]], fill=COLOURS[0])
    for defect in defects:
        x, y = pixel(defect["_at"])
        pen.ellipse([x - 4, y - 4, x + 4, y + 4], outline=(255, 30, 30), width=2)
    image.save(path)


def summary(lines, defects):
    """Return the totals of a set of line surveys and their defects."""
    kinds = {}
    for defect in defects:
        entry = kinds.setdefault(defect["kind"], {"count": 0, "metres": 0})
        entry["count"] += 1
        entry["metres"] += defect["to_m"] - defect["from_m"]
    drawn = sum(int((~np.isnan(line.drawn_m)).sum()) for line in lines)
    painted = sum(int(line.painted.sum()) for line in lines)
    unpainted = sum(int((~line.painted).sum()) for line in lines)
    off = np.concatenate([line.drawn_m - line.shown_m for line in lines] or [np.zeros(0)])
    off = np.abs(off[~np.isnan(off)])
    return {
        "line_drawn_km": round(drawn / 1000.0, 3),
        "line_painted_but_not_drawn_km": round((painted - drawn) / 1000.0, 3),
        "line_not_painted_km": round(unpainted / 1000.0, 3),
        "metres_with_the_photos_line": len(off),
        "median_off_the_photos_line_m": round(float(np.median(off)), 3) if len(off) else None,
        "p95_off_the_photos_line_m": round(float(np.percentile(off, 95)), 3) if len(off) else None,
        "defects": kinds,
    }


def _located(audit, defects, line):
    """Give each defect of `line` a position: the pack's, and the map's for the images."""
    for defect in defects:
        middle = (defect["from_m"] + defect["to_m"]) // 2 - line.first_m
        candidates = np.flatnonzero(~np.isnan(line.points[:, 0]))
        if len(candidates) == 0:
            defect["_at"], defect["position"] = np.array([np.nan, np.nan]), None
            continue
        nearest = candidates[np.abs(candidates - middle).argmin()]
        defect["_at"] = line.points[nearest]
        defect["position"] = audit.pack_position(line.points[nearest])
    return defects


def main(experiment, packs, track_id, out_directory):
    """Audit a pack's lines and write the report and its images into `out_directory`."""
    out_directory = Path(out_directory)
    out_directory.mkdir(parents=True, exist_ok=True)
    audit = Audit(experiment, packs, track_id)
    classes = CLASS_COLOURS[np.minimum(audit.labels, len(CLASS_COLOURS) - 1)]

    lap_lines, lap_geometry = audit.lap()
    lap_defects = [
        defect for line in lap_lines for defect in _located(audit, line_defects(line, True), line)
    ]
    for name, backdrop in (("photo", audit.mosaic.rgb), ("classes", classes)):
        strip = _strip_image(
            audit,
            audit.lap_map,
            audit.lap_length_m,
            lap_geometry,
            0,
            LAP_REACH_M,
            lambda along, right: lap_paint(audit.lap_lines, along, right),
            backdrop,
        )
        write_sheets(_marked(strip, lap_defects, 0), out_directory / f"{track_id}_lap_{name}")

    roads = audit.roads()
    road_lines, road_defects, strips = [], [], []
    for first_m, _, surveys, geometry in roads:
        found = [
            defect
            for line in surveys
            for defect in _located(audit, line_defects(line, False), line)
        ]
        road_lines += surveys
        road_defects += found
        strip = _strip_image(
            audit,
            audit.roads_map,
            None,
            geometry,
            first_m,
            ROAD_STRIP_REACH_M,
            lambda along, right: (
                road_paint(audit.roads_lines, along, right, audit.ground["roads"]["dashes_m"]),
                *road_extent(audit.roads_lines, along, right),
            ),
            audit.mosaic.rgb,
        )
        strips.append(_marked(strip, found, first_m))
    if strips:
        gap = np.full((strips[0].shape[0], 8, 3), 255, np.uint8)
        gap[:6] = 0
        joined = np.concatenate([part for strip in strips for part in (strip, gap)], 1)
        write_sheets(joined, out_directory / f"{track_id}_roads_photo")
    crossings = audit.crossings(roads)

    every = lap_defects + road_defects
    write_overview(audit, lap_lines + road_lines, every, out_directory / f"{track_id}_overview.png")
    worst = sorted(lap_defects, key=lambda defect: -(defect["to_m"] - defect["from_m"]))
    worst += sorted(road_defects, key=lambda defect: -(defect["to_m"] - defect["from_m"]))[
        :WORST_CROPS
    ]
    for index, defect in enumerate(worst[: 2 * WORST_CROPS]):
        if defect["position"] is not None:
            write_crop(audit, defect["_at"], out_directory / f"{track_id}_defect_{index:02d}.png")
    for defect in every:
        del defect["_at"]
    report = {
        "track": track_id,
        "lap": summary(lap_lines, lap_defects),
        "roads": summary(road_lines, road_defects),
        "crossings": {
            "drawn": len(crossings),
            "with_problems": sum(1 for crossing in crossings if crossing["problems"]),
        },
        "lap_defects": lap_defects,
        "road_defects": road_defects,
        "crossing_list": crossings,
    }
    (out_directory / f"{track_id}_audit.json").write_text(json.dumps(report, indent=1))
    print(
        json.dumps({key: report[key] for key in ("track", "lap", "roads", "crossings")}, indent=1)
    )
    for defect in every:
        print(
            f"{defect['line']}: {defect['kind']} from {defect['from_m']} to {defect['to_m']} m,"
            f" worst {defect['worst_m']} m, at {defect['position']}"
        )
    for crossing in crossings:
        print(f"crossing: {crossing}")
    return report


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
