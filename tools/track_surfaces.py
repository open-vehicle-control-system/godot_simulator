"""Derive a circuit's ground surfaces from its orthophoto: surface maps, road lines, photo grade.

Inputs are the orthophoto tiles (`ortho_<east>_<north>.jpg`, each TILE_M wide, named by their
south-west corner in the map frame) and the road's cross-sections (`s`, `x`, `y`, `tx`, `ty`
per section and the lateral `offsets` of its mesh, relative to the frame's origin).

Outputs, as docs/pack_format.md describes them:
- one surface map per tile: the ground layer of every photo pixel;
- one track map per tile the road passes: how far along the lap and how far right of the
  centreline every pixel near the road is;
- the road lines image: per metre of lap, where the asphalt ends on each side, the kerbs
  found there, and the racing line;
- the photo grade that turns the photo's colours into albedo.
"""

import math
import warnings
from pathlib import Path

import ground_classes
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

Image.MAX_IMAGE_PIXELS = None

TILE_M = 512.0
PACK_TILE_M = 256.0  # the pack's tiles: each orthophoto tile is cut into whole ones
BLOCK_PX = 2048
BLOCK_MARGIN_PX = 48
GRADE_SAMPLE_STEP_PX = 8

LATERAL_STEP_M = 0.125
EDGE_SEARCH_FROM_M = 2.0
EDGE_SEARCH_TO_M = 12.0
EDGE_RUN_M = 0.5
FIT_MEDIAN_M = 80.0
FIT_OUTLIER_M = 0.75
FIT_SMOOTHING_M = 10.0
FIT_GAP_M = 8.0
LINE_WIDTH_M = 0.15
LINE_INSET_M = 0.1  # the asphalt beyond the edge line, as the terrain shader draws it
LINE_SMOOTHING_M = 4.0
PAINT_CONTRAST = 0.06  # how much lighter than the ground around it paint is in the photo
PAINT_ACROSS_M = 1.5  # the width a line is lighter than the median of
PAINT_MAX_WIDTH_M = 0.625  # lighter ground wider than this is not a line
PAINT_RIM_STEPS = 2  # the lateral steps of a lit border that stand for a line along it
PAINT_REACH_M = 0.3  # how far from a line's course its paint is looked for
PAINT_ALONG_M = 6.0
PAINT_PERSISTENCE = 0.4  # the share of PAINT_ALONG_M a line shows paint over
PAINT_OFF_ASPHALT_WEIGHT = 0.4  # what paint beyond the asphalt's end is worth: it may be read short
ASPHALT_END_WEIGHT = 0.3  # what the asphalt's end is worth as evidence, next to paint
ASPHALT_END_REACH_M = 0.4
TRACE_STEP_COST = 0.05
INNER_PREFERENCE_PER_M = 0.01
KERB_MAX_WIDTH_M = 2.0
KERB_SLACK_M = 0.5  # how far inside the fitted edge kerb paint may start
KERB_MIN_WIDTH_M = 0.5
KERB_MIN_LENGTH_M = 6.0
KERB_BREAK_M = 3.0
KERB_STRIPE_M = 1.5
KERB_WIDTH_STEP_M = 0.1
KERB_RED_OVER_OTHERS = 1.08
KERB_GREEN_OVER_RED = 1.06
KERB_GREEN_LUMINANCE = 0.42
EDGE_UNIT_M = 0.001  # one step of the lines images' 16-bit edges and offsets
RACING_LINE_UNIT_M = 0.05
KERB_UNIT_M = 0.01

TRACK_MAP_M_PER_PX = 0.5
TRACK_MAP_REACH_M = 20.0
ALONG_UNIT_M = 0.125  # one step of a road map's 20-bit distance along the road
RIGHT_UNIT_M = 0.01  # one step of its 12-bit distance right of the centreline
RIGHT_ZERO = 2048
OFF_ROAD = 4095
ROAD_MAP_MARGIN_M = 1.5  # how far beyond a road's edge its road map reaches
THROUGH_ROAD_SCORE_M = 100.0  # what each rank is worth where roads overlap

CORNER_CURVATURE_PER_M = 1.0 / 60.0  # a corner this tight pulls the racing line fully inside
RACING_LINE_MARGIN_M = 1.6
APEX_SMOOTHING_M = 12.0
APPROACH_SMOOTHING_M = 45.0

CROWN_RADIUS_OVER_HEIGHT = 0.22
MIN_CROWN_RADIUS_M = 1.5
CANOPY_REACH_M = 4.0
CLOSED_CANOPY = 0.55  # the share of crown cover around a point from which the canopy is closed


class Mosaic:
    """The orthophoto tiles as one image, with the map frame's coordinates of its pixels."""

    def __init__(self, ortho_directory):
        """Read every `ortho_<east>_<north>.jpg` of `ortho_directory`."""
        tiles = {}
        for path in sorted(Path(ortho_directory).glob("ortho_*.jpg")):
            _, east, north = path.stem.split("_")
            tiles[(int(east), int(north))] = path
        self.tile_corners = sorted(tiles)
        self.west = min(east for east, _ in tiles)
        self.north = max(north for _, north in tiles) + TILE_M
        first = Image.open(tiles[self.tile_corners[0]])
        self.tile_px = first.size[0]
        self.px_per_m = self.tile_px / TILE_M
        columns = round((max(east for east, _ in tiles) - self.west) / TILE_M) + 1
        rows = round((self.north - min(north for _, north in tiles)) / TILE_M)
        self.rgb = np.zeros((rows * self.tile_px, columns * self.tile_px, 3), np.uint8)
        for corner, path in tiles.items():
            row, column = self.tile_origin_px(corner)
            self.rgb[row : row + self.tile_px, column : column + self.tile_px] = np.asarray(
                Image.open(path).convert("RGB")
            )

    def tile_origin_px(self, corner, tile_m=TILE_M):
        """Return the (row, column) of the top-left pixel of the tile `tile_m` wide at `corner`."""
        east, north = corner
        return (
            round((self.north - north - tile_m) * self.px_per_m),
            round((east - self.west) * self.px_per_m),
        )

    def pack_tile_corners(self):
        """Return the (east, north) corner of every pack tile the orthophotos cover."""
        steps = [step * PACK_TILE_M for step in range(round(TILE_M / PACK_TILE_M))]
        return sorted(
            (round(east + across), round(north + up))
            for east, north in self.tile_corners
            for across in steps
            for up in steps
        )

    def pack_tile_window(self, corner, m_per_px):
        """Return the slices of a pack tile in an array covering the mosaic at `m_per_px`."""
        row, column = (
            round(px / self.px_per_m / m_per_px) for px in self.tile_origin_px(corner, PACK_TILE_M)
        )
        side = round(PACK_TILE_M / m_per_px)
        return slice(row, row + side), slice(column, column + side)

    def pixel(self, east, north):
        """Return the (row, column) arrays of map positions, clipped to the mosaic."""
        rows = np.clip(((self.north - north) * self.px_per_m).astype(int), 0, self.rgb.shape[0] - 1)
        columns = np.clip(
            ((east - self.west) * self.px_per_m).astype(int), 0, self.rgb.shape[1] - 1
        )
        return rows, columns


def classify_mosaic(rgb, grade):
    """Return the ground layer of every pixel, classified block by block with a margin."""
    labels = np.zeros(rgb.shape[:2], np.uint8)
    height, width = labels.shape
    for top in range(0, height, BLOCK_PX):
        for left in range(0, width, BLOCK_PX):
            y0, x0 = max(top - BLOCK_MARGIN_PX, 0), max(left - BLOCK_MARGIN_PX, 0)
            y1 = min(top + BLOCK_PX + BLOCK_MARGIN_PX, height)
            x1 = min(left + BLOCK_PX + BLOCK_MARGIN_PX, width)
            block = ground_classes.classify(ground_classes.graded(rgb[y0:y1, x0:x1], grade))
            labels[top : top + BLOCK_PX, left : left + BLOCK_PX] = block[
                top - y0 : top - y0 + BLOCK_PX, left - x0 : left - x0 + BLOCK_PX
            ]
    return labels


def first_run(flags, run_length):
    """Return, per row, the index where the first run of `run_length` true flags starts.

    Rows without such a run give -1.
    """
    windows = np.lib.stride_tricks.sliding_window_view(flags, run_length, axis=1).all(-1)
    found = windows.any(1)
    return np.where(found, windows.argmax(1), -1)


def circular_median(values, window):
    """Return the running median of a closed loop of values."""
    half = window // 2
    padded = np.concatenate([values[-half:], values, values[:half]])
    return np.median(np.lib.stride_tricks.sliding_window_view(padded, window), axis=-1)


def circular_smooth(values, sigma_samples):
    """Return a closed loop of values, Gaussian-smoothed."""
    reach = max(1, int(3 * sigma_samples))
    kernel = np.exp(-0.5 * (np.arange(-reach, reach + 1) / sigma_samples) ** 2)
    return np.convolve(np.pad(values, reach, mode="wrap"), kernel / kernel.sum(), mode="valid")


def keep_long_runs(flags, run_length):
    """Return a closed loop of flags without the true runs shorter than `run_length`."""
    count = len(flags)
    kept = np.zeros(count, bool)
    if flags.all():
        return flags.copy()
    start = int(np.argmin(flags))  # a false flag: runs are counted from there
    run = []
    for step in range(1, count + 1):
        index = (start + step) % count
        if flags[index]:
            run.append(index)
            continue
        if len(run) >= run_length:
            kept[run] = True
        run = []
    return kept


def asphalt_ends(paved):
    """Return where each section's asphalt seems to end on one side, NaN where it does not.

    `paved` flags the ground per section (rows) and lateral step outwards from
    EDGE_SEARCH_FROM_M (columns).
    """
    ends = first_run(~paved, round(EDGE_RUN_M / LATERAL_STEP_M))
    return np.where(ends >= 0, EDGE_SEARCH_FROM_M + ends * LATERAL_STEP_M, np.nan)


def keep_long_open_runs(flags, run_length):
    """Return an open run of flags without the true runs shorter than `run_length`."""
    return keep_long_runs(np.concatenate([flags, [False]]), run_length)[:-1]


def fit_open_edge(raw_edge_m, spacing_m):
    """Return the edge fitted to the evidence along an open road, and where it has a gap.

    The evidence is `raw_edge_m` per section, NaN where there is none. An edge drawn by a
    road builder is smooth: evidence far from the median of its surroundings is rejected,
    and the rest is low-passed. The edge is held from the first and to the last trusted
    reading; a long stretch without one is returned as a gap, across which the edge
    carries on. Without any trusted reading the edge is NaN.
    """
    count = len(raw_edge_m)
    trusted = _trusted(raw_edge_m, spacing_m, "reflect")
    if not trusted.any():
        return np.full(count, np.nan), np.ones(count, bool)
    sections = np.arange(count)
    carried = np.interp(sections, sections[trusted], raw_edge_m[trusted])
    reach = max(1, int(3 * FIT_SMOOTHING_M / spacing_m))
    kernel = np.exp(-0.5 * (np.arange(-reach, reach + 1) / (FIT_SMOOTHING_M / spacing_m)) ** 2)
    edge = np.convolve(np.pad(carried, reach, mode="edge"), kernel / kernel.sum(), mode="valid")
    return edge, keep_long_open_runs(~trusted, max(1, round(FIT_GAP_M / spacing_m)))


def _trusted(raw_edge_m, spacing_m, beyond_the_ends):
    """Return which readings lie within FIT_OUTLIER_M of the median of their surroundings.

    `beyond_the_ends` is how the readings carry on past the first and last: "wrap" around a
    lap, "reflect" at the ends of an open road.
    """
    window = max(3, round(FIT_MEDIAN_M / spacing_m) | 1)
    half = min(window // 2, len(raw_edge_m) - 1)
    padded = np.pad(raw_edge_m, half, mode=beyond_the_ends)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)  # windows of nothing but NaN
        surroundings = np.nanmedian(
            np.lib.stride_tricks.sliding_window_view(padded, 2 * half + 1), -1
        )
    return np.abs(raw_edge_m - surroundings) <= FIT_OUTLIER_M  # false for NaN


def line_paint(luminance, kerb_paint):
    """Return which samples of cross profiles (rows) are a line's paint.

    Paint is lighter than the median of the ground across it, thin, and not `kerb_paint`.
    Where lighter ground carries on outwards (a line against a kerb, concrete or a pale
    verge), its inner rim counts: a line runs along that border, and the step in
    lightness places it better than the kerb's blurred colours do. Columns run outwards
    from the centreline.
    """
    step_m = LATERAL_STEP_M
    window = round(PAINT_ACROSS_M / step_m) | 1
    padded = np.pad(luminance, ((0, 0), (window // 2, window // 2)), mode="reflect")
    around = np.median(np.lib.stride_tricks.sliding_window_view(padded, window, axis=1), -1)
    light = luminance - around >= PAINT_CONTRAST
    widest = round(PAINT_MAX_WIDTH_M / step_m)
    wide = np.zeros_like(light)
    if light.shape[1] > widest:
        runs = np.lib.stride_tricks.sliding_window_view(light, widest + 1, axis=1).all(-1)
        for shift in range(widest + 1):
            wide[:, shift : shift + runs.shape[1]] |= runs
    inwards = window // 2
    before = np.pad(luminance, ((0, 0), (inwards, 0)), mode="edge")[:, :-1]
    inside = np.median(np.lib.stride_tricks.sliding_window_view(before, inwards, axis=1), -1)
    lit = luminance - inside >= PAINT_CONTRAST
    rim = lit.copy()
    rim[:, PAINT_RIM_STEPS:] &= ~lit[:, :-PAINT_RIM_STEPS]
    return (light & ~wide & ~kerb_paint) | rim


def trace_line(score):
    """Return the lateral step, per section of a closed lap, of the line the evidence shows.

    `score` is the evidence for a line per section (rows) and lateral step (columns). The
    line is the course around the lap with the most evidence that moves at most one step
    sideways per section, each such move costing TRACE_STEP_COST: a line does not jump.
    """
    count, steps = score.shape
    twice = np.concatenate([score, score])
    best = twice[0].astype(np.float64)
    came_from = np.zeros((2 * count, steps), np.int8)
    for index in range(1, 2 * count):
        from_inside = np.concatenate([[-np.inf], best[:-1]]) - TRACE_STEP_COST
        from_outside = np.concatenate([best[1:], [-np.inf]]) - TRACE_STEP_COST
        options = np.stack([from_inside, best, from_outside])
        choice = options.argmax(0)
        came_from[index] = choice - 1
        best = options[choice, np.arange(steps)] + twice[index]
    course = np.zeros(2 * count, int)
    course[-1] = int(best.argmax())
    for index in range(2 * count - 1, 0, -1):
        course[index - 1] = course[index] + came_from[index, course[index]]
    half = count // 2
    return np.roll(course[half : half + count], half)


def edge_line(paint, asphalt_end_m, spacing_m):
    """Return where one side's edge line runs around a closed lap, and where it has a gap.

    `paint` flags a line's paint per section (rows) and lateral step outwards from
    EDGE_SEARCH_FROM_M (columns); `asphalt_end_m` is where each section's asphalt seems to
    end, NaN where it does not. The painted line is the evidence: where the photo shows
    none along the course, a line runs LINE_INSET_M inside the asphalt's end. With neither
    over a long stretch the road opens onto a junction or a pit lane: the line's course
    carries on across it and the stretch is returned as a gap.
    """
    count, steps = paint.shape
    laterals = EDGE_SEARCH_FROM_M + np.arange(steps) * LATERAL_STEP_M
    by_asphalt_m = asphalt_end_m - LINE_INSET_M - LINE_WIDTH_M / 2.0
    on_asphalt = laterals[None, :] <= np.nan_to_num(asphalt_end_m, nan=np.inf)[:, None]
    at_asphalt_end = np.abs(laterals[None, :] - by_asphalt_m[:, None]) <= LATERAL_STEP_M
    score = paint * np.where(on_asphalt, 1.0, PAINT_OFF_ASPHALT_WEIGHT)
    score = score + ASPHALT_END_WEIGHT * at_asphalt_end - INNER_PREFERENCE_PER_M * laterals
    course_m = laterals[trace_line(score)]
    marked = paint & (np.abs(laterals[None, :] - course_m[:, None]) <= PAINT_REACH_M)
    shown = marked.any(1)
    window = max(1, round(PAINT_ALONG_M / spacing_m) | 1)
    persistent = (
        np.convolve(np.pad(shown.astype(float), window // 2, mode="wrap"), np.ones(window))[
            window - 1 : window - 1 + count
        ]
        >= PAINT_PERSISTENCE * window
    )
    painted_m = (marked * laterals[None, :]).sum(1) / np.maximum(marked.sum(1), 1)
    by_asphalt = np.abs(by_asphalt_m - course_m) <= ASPHALT_END_REACH_M
    reading = np.where(
        shown & persistent, painted_m, np.where(by_asphalt & ~persistent, by_asphalt_m, np.nan)
    )
    known = ~np.isnan(reading)
    if not known.any():
        return np.full(count, EDGE_SEARCH_TO_M), np.ones(count, bool)
    sections = np.arange(count)
    carried = np.interp(sections, sections[known], reading[known], period=count)
    line = circular_smooth(carried, LINE_SMOOTHING_M / spacing_m)
    return line, keep_long_runs(~known, max(1, round(FIT_GAP_M / spacing_m)))


def kerb_widths(kerb_paint, edge_m):
    """Return how wide the kerb paint at the fitted edge is, per section; 0 without paint."""
    laterals = EDGE_SEARCH_FROM_M + np.arange(kerb_paint.shape[1]) * LATERAL_STEP_M
    beside_edge = (laterals[None, :] >= edge_m[:, None] - KERB_SLACK_M) & (
        laterals[None, :] <= edge_m[:, None] + KERB_MAX_WIDTH_M
    )
    return (kerb_paint & beside_edge).sum(1) * LATERAL_STEP_M


def kerb_segments(width_m, sections_s, lap_length_m):
    """Return the kerbs of one side as clean segments: (from_m, to_m, width_m) along the lap.

    A kerb is paint at least KERB_MIN_WIDTH_M wide over KERB_MIN_LENGTH_M; short breaks in the
    paint are closed. A kerb is built of whole stripes: it starts and ends on a multiple of
    KERB_STRIPE_M and has one width, in steps of KERB_WIDTH_STEP_M. A segment across the
    start line has `to_m` beyond the lap's length.
    """
    spacing_m = float(np.median(np.diff(sections_s)))
    painted = width_m >= KERB_MIN_WIDTH_M
    painted = ~keep_long_runs(~painted, round(KERB_BREAK_M / spacing_m) + 1)
    painted = keep_long_runs(painted, max(1, round(KERB_MIN_LENGTH_M / spacing_m)))
    if not painted.any() or painted.all():
        return []
    count = len(painted)
    starts = np.flatnonzero(painted & ~np.roll(painted, 1))
    segments = []
    for start in starts:
        length = 1
        while painted[(start + length) % count]:
            length += 1
        inside = (start + np.arange(length)) % count
        from_m = math.floor(sections_s[start] / KERB_STRIPE_M) * KERB_STRIPE_M
        end_s = sections_s[inside[-1]] + (lap_length_m if inside[-1] < start else 0.0)
        to_m = math.ceil(end_s / KERB_STRIPE_M) * KERB_STRIPE_M
        solid = width_m[inside][width_m[inside] >= KERB_MIN_WIDTH_M]
        width = round(round(float(np.median(solid)) / KERB_WIDTH_STEP_M) * KERB_WIDTH_STEP_M, 3)
        segments.append((from_m, to_m, width))
    return segments


def racing_line(curvature_per_m, section_spacing_m, left_edge_m, right_edge_m):
    """Return the racing line's lateral offset (m, positive right) and how rubbered it is.

    `curvature_per_m` is positive turning right. The line is pulled inside at the apex and
    outside on the way in and out; rubber builds up with cornering.
    """
    apex = circular_smooth(curvature_per_m, APEX_SMOOTHING_M / section_spacing_m)
    approach = circular_smooth(curvature_per_m, APPROACH_SMOOTHING_M / section_spacing_m)
    pull = np.clip((2.0 * apex - approach * 1.6) / CORNER_CURVATURE_PER_M, -1.0, 1.0)
    room = np.where(pull > 0.0, right_edge_m, left_edge_m) - RACING_LINE_MARGIN_M
    offset = pull * np.maximum(room, 0.0)
    rubber = np.clip(0.35 + 0.65 * np.abs(apex) / CORNER_CURVATURE_PER_M, 0.0, 1.0)
    return offset, rubber


def sixteen_bits(steps):
    """Return whole numbers as (high byte, low byte) arrays, clipped to 16 bits."""
    whole = np.clip(np.round(steps), 0, 65535).astype(np.uint16)
    return (whole >> 8).astype(np.uint8), (whole & 255).astype(np.uint8)


def lines_image(sections_s, lap_length_m, edges, gaps, kerbs, line_offset_m, rubber):
    """Return the road lines image: one column per metre of lap, three rows, RGBA.

    Row 0: (R, G) the left and (B, A) the right asphalt edge, 16 bits each, EDGE_UNIT_M
    per step from the centreline. Row 1: R, G the left and right kerb widths (KERB_UNIT_M
    per step), B the racing line (RACING_LINE_UNIT_M per step, 128 on the centreline, above
    to the right), A the rubber on it. Row 2: R, G 255 where the left and right edge lines
    are painted, 0 in their gaps.

    `edges`, `gaps` are per section and side, `kerbs` the segments of each side.
    """
    metres = np.arange(math.ceil(lap_length_m) + 1, dtype=np.float64)

    def along(values):
        return np.interp(metres, sections_s, values, period=lap_length_m)

    image = np.zeros((3, len(metres), 4), np.uint8)
    image[2, :, 3] = 255
    image[1, :, 2] = np.clip(np.round(along(line_offset_m) / RACING_LINE_UNIT_M) + 128, 0, 255)
    image[1, :, 3] = np.clip(np.round(along(rubber) * 255.0), 0, 255)
    for side in range(2):
        high, low = sixteen_bits(along(edges[side]) / EDGE_UNIT_M)
        image[0, :, 2 * side], image[0, :, 2 * side + 1] = high, low
        image[2, :, side] = np.where(along(gaps[side].astype(float)) > 0.5, 0, 255)
        for from_m, to_m, width_m in kerbs[side]:
            covered = (metres >= from_m) & (metres < to_m)
            covered |= metres + lap_length_m < to_m
            image[1, covered, side] = round(width_m / KERB_UNIT_M)
    return image


class RoadMap:
    """Where the ground is along the roads: for every pixel, the nearest road's coordinates.

    `along` and `right` are float arrays at TRACK_MAP_M_PER_PX covering the mosaic: the
    distance along the road and right of its centreline, NaN away from any road.
    """

    def __init__(self, mosaic):
        """Start with no road on the ground the mosaic covers."""
        self.west, self.north = mosaic.west, mosaic.north
        height = round(mosaic.rgb.shape[0] / mosaic.px_per_m / TRACK_MAP_M_PER_PX)
        width = round(mosaic.rgb.shape[1] / mosaic.px_per_m / TRACK_MAP_M_PER_PX)
        self.along = np.full((height, width), np.nan, np.float32)
        self.right = np.full((height, width), np.nan, np.float32)
        self._score = np.full((height, width), np.inf, np.float32)
        self._inside_m = np.zeros((height, width), np.float32)
        self._rank = np.full((height, width), -1, np.int8)

    def inside_roads(self, least_rank):
        """Return how far inside a road of at least `least_rank` the ground is, 0 outside any."""
        return np.where(self._rank >= least_rank, self._inside_m, 0.0)

    def lay_lap(self, origin, sections, lap_length_m):
        """Lay a closed lap: the ground within TRACK_MAP_REACH_M of its centreline."""
        s = np.array(sections["s"])
        x, y = np.array(sections["x"]), np.array(sections["y"])
        self._lay(
            np.append(x, x[0]) + origin[0],
            np.append(y, y[0]) + origin[1],
            np.append(s, lap_length_m),
            np.zeros(len(s) + 1),
            TRACK_MAP_REACH_M,
            0,
        )

    def lay_road(self, origin, sections, along_m, edge_m, rank):
        """Lay an open road: the ground up to ROAD_MAP_MARGIN_M beyond its edges.

        `along_m` is where each section is along the roads' common axis and `edge_m` how far
        its edges are from its centreline. Where roads overlap, the ground between the edges
        of the road of highest `rank` is that road's.
        """
        self._lay(
            np.array(sections["x"]) + origin[0],
            np.array(sections["y"]) + origin[1],
            along_m,
            edge_m,
            ROAD_MAP_MARGIN_M,
            rank + 1,
        )

    def _lay(self, east, north, along_m, edge_m, margin_m, rank):
        x = (east - self.west) / TRACK_MAP_M_PER_PX
        y = (self.north - north) / TRACK_MAP_M_PER_PX
        height, width = self.along.shape
        for index in range(len(x) - 1):
            start = np.array([x[index], y[index]])
            step = np.array([x[index + 1], y[index + 1]]) - start
            length = float(np.hypot(*step))
            if length <= 0.0:
                continue
            reach = (max(edge_m[index], edge_m[index + 1]) + margin_m) / TRACK_MAP_M_PER_PX
            low = np.minimum(start, start + step) - reach
            high = np.maximum(start, start + step) + reach
            column0, column1 = max(int(low[0]), 0), min(int(high[0]) + 1, width)
            row0, row1 = max(int(low[1]), 0), min(int(high[1]) + 1, height)
            if column0 >= column1 or row0 >= row1:
                continue
            east_px = np.arange(column0, column1) + 0.5 - start[0]
            south_px = np.arange(row0, row1) + 0.5 - start[1]
            share = np.clip(
                (east_px[None, :] * step[0] + south_px[:, None] * step[1]) / length**2, 0, 1
            )
            off_east = east_px[None, :] - share * step[0]
            off_south = south_px[:, None] - share * step[1]
            distance = np.hypot(off_east, off_south) * TRACK_MAP_M_PER_PX
            # Image rows run south: the right of a heading (east, south) is (-south, east).
            to_right = np.copysign(distance, off_east * -step[1] + off_south * step[0])
            beyond = distance - (edge_m[index] + share * (edge_m[index + 1] - edge_m[index]))
            score = np.where(beyond > 0.0, beyond, beyond - rank * THROUGH_ROAD_SCORE_M)
            window = (slice(row0, row1), slice(column0, column1))
            closer = (beyond < margin_m) & (score < self._score[window])
            self._score[window] = np.where(closer, score, self._score[window])
            self.along[window] = np.where(
                closer,
                along_m[index] + share * (along_m[index + 1] - along_m[index]),
                self.along[window],
            )
            self.right[window] = np.where(closer, to_right, self.right[window])
            self._inside_m[window] = np.where(
                closer, np.maximum(-beyond, 0.0), self._inside_m[window]
            )
            self._rank[window] = np.where(closer, rank - 1, self._rank[window])

    def tile_image(self, mosaic, corner):
        """Return the road map of one pack tile, or None when no road passes it."""
        window = mosaic.pack_tile_window(corner, TRACK_MAP_M_PER_PX)
        if np.isnan(self.along[window]).all():
            return None
        return road_map_image(self.along[window], self.right[window])


def track_coordinates(mosaic, origin, sections, lap_length_m):
    """Return how far along the lap and how far right of the centreline the ground is.

    Two float arrays at TRACK_MAP_M_PER_PX covering the mosaic, NaN further than
    TRACK_MAP_REACH_M from the centreline.
    """
    road_map = RoadMap(mosaic)
    road_map.lay_lap(origin, sections, lap_length_m)
    return road_map.along, road_map.right


def road_map_image(along, right):
    """Return road coordinates as an RGBA image.

    The distance along the road takes 20 bits, ALONG_UNIT_M per step: R, G and the high half
    of B. The distance right of the centreline takes 12 bits, RIGHT_UNIT_M per step from
    RIGHT_ZERO: the low half of B, and A; OFF_ROAD away from any road.
    """
    on_road = ~np.isnan(along)
    along_steps = np.where(on_road, np.round(np.nan_to_num(along) / ALONG_UNIT_M), 0).astype(
        np.uint32
    )
    right_steps = np.where(
        on_road,
        np.clip(np.round(np.nan_to_num(right) / RIGHT_UNIT_M) + RIGHT_ZERO, 0, OFF_ROAD - 1),
        OFF_ROAD,
    ).astype(np.uint32)
    return np.stack(
        [
            along_steps >> 12,
            (along_steps >> 4) & 255,
            ((along_steps & 15) << 4) | (right_steps >> 8),
            right_steps & 255,
        ],
        -1,
    ).astype(np.uint8)


def paint_track(labels, mosaic, origin, sections, edges):
    """Mark the asphalt between the road's edges as the track's in `labels`."""
    x, y, tx, ty = (np.array(sections[key]) for key in ("x", "y", "tx", "ty"))
    drawing = Image.fromarray(np.zeros(labels.shape, np.uint8))
    pen = ImageDraw.Draw(drawing)
    left = np.stack([x - ty * edges[0], y + tx * edges[0]], 1)
    right = np.stack([x + ty * edges[1], y - tx * edges[1]], 1)
    count = len(x)
    for index in range(count):
        following = (index + 1) % count
        quad = [left[index], left[following], right[following], right[index]]
        pen.polygon(
            [
                (
                    (east + origin[0] - mosaic.west) * mosaic.px_per_m,
                    (mosaic.north - north - origin[1]) * mosaic.px_per_m,
                )
                for east, north in quad
            ],
            fill=1,
        )
    labels[np.asarray(drawing) == 1] = ground_classes.TRACK_ASPHALT


def is_kerb_paint(albedo):
    """Return which graded photo colours are kerb paint.

    At 25 cm per pixel red and white stripes blur into pink and green and white ones into a
    pale green, lighter than grass.
    """
    colour = ground_classes.srgb(albedo)
    red, green, blue = colour[..., 0], colour[..., 1], colour[..., 2]
    pink = (red > green * KERB_RED_OVER_OTHERS) & (red > blue * KERB_RED_OVER_OTHERS)
    luminance = 0.3 * red + 0.59 * green + 0.11 * blue
    pale_green = (
        (green > red * KERB_GREEN_OVER_RED) & (green > blue) & (luminance > KERB_GREEN_LUMINANCE)
    )
    return pink | pale_green


def crown_cover(mosaic, trees):
    """Return which mosaic pixels lie under a tree's crown.

    `trees` are (east, north, height) in the map frame; a crown is CROWN_RADIUS_OVER_HEIGHT
    of its tree's height wide, at least MIN_CROWN_RADIUS_M.
    """
    drawing = Image.new("L", (mosaic.rgb.shape[1], mosaic.rgb.shape[0]), 0)
    pen = ImageDraw.Draw(drawing)
    for east, north, height_m in trees:
        radius_px = max(MIN_CROWN_RADIUS_M, CROWN_RADIUS_OVER_HEIGHT * height_m) * mosaic.px_per_m
        column = (east - mosaic.west) * mosaic.px_per_m
        row = (mosaic.north - north) * mosaic.px_per_m
        pen.ellipse(
            [column - radius_px, row - radius_px, column + radius_px, row + radius_px], fill=255
        )
    return drawing


def lay_forest_floor(labels, crowns, px_per_m):
    """Mark the ground under a closed canopy as forest floor in `labels`.

    A photo shows crowns, shadows and bare branches there, not the ground. A lone tree stands
    on what surrounds it: the ground under it keeps its layer.
    """
    canopy = crowns.filter(ImageFilter.GaussianBlur(CANOPY_REACH_M * px_per_m))
    labels[np.asarray(canopy) > CLOSED_CANOPY * 255] = ground_classes.FOREST_FLOOR


def survey_road(mosaic, labels, albedo_at, brightness_at, origin, sections):
    """Return the road's fitted edges, their gaps, its kerbs, racing line and rubber.

    Edges, gaps, racing line and rubber are per section (edges, gaps and kerbs for the left
    side, then the right); kerbs are segments along the lap. An edge is LINE_INSET_M beyond
    the edge line fitted to that side, a gap where that line is not painted.

    `albedo_at(rows, columns)` gives the graded photo's colour at mosaic pixels and
    `brightness_at(rows, columns)` how light the photo itself is there.
    """
    x, y, tx, ty = (np.array(sections[key]) for key in ("x", "y", "tx", "ty"))
    laterals = np.arange(EDGE_SEARCH_FROM_M, EDGE_SEARCH_TO_M + KERB_MAX_WIDTH_M, LATERAL_STEP_M)
    s = np.array(sections["s"])
    spacing_m = float(np.median(np.diff(s)))
    lap_length_m = float(s[-1] + math.hypot(x[0] - x[-1], y[0] - y[-1]))
    edges, gaps, kerbs = [], [], []
    for side in (-1.0, 1.0):  # left, right
        east = x[:, None] + ty[:, None] * side * laterals[None, :] + origin[0]
        north = y[:, None] - tx[:, None] * side * laterals[None, :] + origin[1]
        rows, columns = mosaic.pixel(east, north)
        kerb_paint = is_kerb_paint(albedo_at(rows, columns))
        ground = labels[rows, columns]
        paved = (ground == ground_classes.WORN_ASPHALT) | (ground == ground_classes.TRACK_ASPHALT)
        paint = line_paint(brightness_at(rows, columns), kerb_paint)
        line, gap = edge_line(paint, asphalt_ends(paved), spacing_m)
        edge = line + LINE_WIDTH_M / 2.0 + LINE_INSET_M
        edges.append(edge)
        gaps.append(gap)
        kerbs.append(kerb_segments(kerb_widths(kerb_paint, edge), s, lap_length_m))
    offset, rubber = racing_line(lap_curvature(sections), spacing_m, edges[0], edges[1])
    return edges, gaps, kerbs, offset, rubber


def lap_curvature(sections):
    """Return the curvature of a closed lap per section, per metre, positive turning right."""
    tx, ty = np.asarray(sections["tx"]), np.asarray(sections["ty"])
    spacing_m = float(np.median(np.diff(sections["s"])))
    heading = np.unwrap(np.arctan2(ty, tx))
    turn = np.diff(
        np.concatenate(
            [heading, [heading[0] + round((heading[-1] - heading[0]) / math.tau) * math.tau]]
        )
    )
    return -turn / spacing_m


class Ground:
    """A circuit's ground as its orthophoto shows it: graded into albedo and classified.

    Positions are metres east and north of `origin`, as the road's sections are.
    """

    def __init__(self, ortho_directory, origin, sections, trees):
        """Read the photo; grade it on the road's asphalt and classify it.

        `trees` are the (east, north, height) of every tree in the map frame.
        """
        self.mosaic = Mosaic(ortho_directory)
        self.origin = origin
        rows, columns = self.pixel(np.array(sections["x"]), np.array(sections["y"]))
        sample = self.mosaic.rgb[::GRADE_SAMPLE_STEP_PX, ::GRADE_SAMPLE_STEP_PX].reshape(-1, 3)
        self.grade = ground_classes.estimate_grade(sample, self.mosaic.rgb[rows, columns])
        self.labels = classify_mosaic(self.mosaic.rgb, self.grade)
        lay_forest_floor(self.labels, crown_cover(self.mosaic, trees), self.mosaic.px_per_m)

    def pixel(self, x, y):
        """Return the (row, column) arrays of positions, clipped to the photo."""
        return self.mosaic.pixel(x + self.origin[0], y + self.origin[1])

    def covers(self, x, y):
        """Return which positions the photo covers."""
        east, north = x + self.origin[0], y + self.origin[1]
        height_m = self.mosaic.rgb.shape[0] / self.mosaic.px_per_m
        width_m = self.mosaic.rgb.shape[1] / self.mosaic.px_per_m
        return (
            (east >= self.mosaic.west)
            & (east < self.mosaic.west + width_m)
            & (north <= self.mosaic.north)
            & (north > self.mosaic.north - height_m)
        )

    def brightness_at(self, rows, columns):
        """Return how light the photo itself is at photo pixels, 0 to 1: its paint stands out."""
        return self.mosaic.rgb[rows, columns] @ np.array([0.3, 0.59, 0.11], np.float32) / 255.0

    def albedo_at(self, rows, columns):
        """Return the graded photo's colour at photo pixels."""
        return ground_classes.graded(self.mosaic.rgb[rows, columns], self.grade)


def tile_key(corner):
    """Return the name of the pack tile at `corner`: `<east>_<north>`."""
    return f"{corner[0]}_{corner[1]}"


def write_tile_maps(directory, mosaic, kind, image_of, mode):
    """Write one PNG per pack tile into `directory`/tiles, named `<east>_<north>.<kind>.png`.

    `image_of(corner)` gives a tile's image, or None for a tile that gets no file.
    """
    tiles = directory / "tiles"
    tiles.mkdir(exist_ok=True)
    for stale in tiles.glob(f"*.{kind}.png"):
        stale.unlink()
    for corner in mosaic.pack_tile_corners():
        image = image_of(corner)
        if image is not None:
            Image.fromarray(image, mode).save(tiles / f"{tile_key(corner)}.{kind}.png")


def labels_tile(labels, mosaic, corner):
    """Return the surface map of one pack tile."""
    return labels[mosaic.pack_tile_window(corner, 1.0 / mosaic.px_per_m)]


def build(ground, sections, out_directory):
    """Write the surface maps, track maps and road lines of a lap into `out_directory`.

    Marks the lap's asphalt in the ground's labels. Returns the lap's length, its RoadMap,
    its fitted asphalt edges (left, right) per section and its racing line, right of the
    centreline per section.
    """
    out_directory = Path(out_directory)
    mosaic, origin, labels = ground.mosaic, ground.origin, ground.labels
    x, y = np.array(sections["x"]), np.array(sections["y"])
    edges, gaps, kerbs, offset, rubber = survey_road(
        mosaic, labels, ground.albedo_at, ground.brightness_at, origin, sections
    )
    paint_track(labels, mosaic, origin, sections, edges)

    s = np.array(sections["s"])
    lap_length_m = float(s[-1] + math.hypot(x[0] - x[-1], y[0] - y[-1]))
    lines = lines_image(s, lap_length_m, edges, gaps, kerbs, offset, rubber)
    Image.fromarray(lines, "RGBA").save(out_directory / "road_lines.png")
    lap_map = RoadMap(mosaic)
    lap_map.lay_lap(origin, sections, lap_length_m)
    write_tile_maps(
        out_directory, mosaic, "surface", lambda corner: labels_tile(labels, mosaic, corner), "L"
    )
    write_tile_maps(
        out_directory, mosaic, "track", lambda corner: lap_map.tile_image(mosaic, corner), "RGBA"
    )
    return round(lap_length_m, 2), lap_map, edges, offset
