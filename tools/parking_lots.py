"""Survey a circuit's parking lots: drawn empty, with the bays the photo shows.

OpenStreetMap gives a lot's rough outline; the orthophoto is the evidence for its clean
model: an outline moved to where the surface ends, the surface and its colour without the
cars on it, and a regular grid of bays. Outputs, as docs/pack_format.md describes them: one
lot map per tile a lot touches, and the lots' description.
"""

import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import ground_classes
import numpy as np
import track_surfaces
from PIL import Image, ImageDraw, ImageFilter

MIN_LOT_SHARE = 0.5  # the share of a mapped lot the photo must show as a made surface
WINDOW_MARGIN_M = 6.0
OUTLINE_SEARCH_M = 4.0
OUTLINE_STEP_M = 0.25
OUTLINE_RUN_M = 0.75  # this much ground that is not the lot's ends it
OUTLINE_MIN_EDGE_M = 5.0
OUTLINE_MIN_EVIDENCE = 0.4
PARALLEL = 0.15  # the sine of the angle under which two edges count as one line
MASK_SMOOTHING_M = 1.5
PAINT_OPENING_PX = 3
PAINT_CONTRAST = 0.035
PAINT_INSET_M = 0.75
MIN_PAINT_PIXELS = 60
ANGLE_BIN_M = 0.25
BAY_WIDTHS_M = np.arange(2.2, 3.61, 0.025)
ROW_BIN_M = 0.5
DIVIDER_RUN_PX = 5  # a divider is paint over most of this many pixels in a line
DIVIDER_MIN_RUN_PX = 3
ROW_MIN_PIXELS = 8
ROW_MIN_CORE_M = 1.5  # the least band of rhythmic paint a row is found from
ROW_MIN_RHYTHM = 0.4  # how much of a row's paint keeps the bays' rhythm
ROW_PHASE_DRIFT = 0.2  # of a bay's width
BAY_DEPTH_M = (3.0, 12.0)
DIVIDER_REACH_M = 0.3
DIVIDER_MIN_SHARE = 0.3  # of a divider's length, or of a row's dividers, the photo must show
DIVIDER_BREAK_M = 0.75
MAX_MISSING_DIVIDERS = 3
MIN_DIVIDERS = 3
END_LINE_SHARE = 0.5
MAX_ROWS = 16
MAX_LOTS = 255
CLUTTER_PX_M = 1.0  # the resolution clutter is looked for at
CLUTTER_SURROUNDINGS_PX = 9  # the width whose median brightness is a surface's own
CLUTTER_CONTRAST = 0.12
YARD_CELL_M = 2.0
YARD_REACH_M = 4.0  # the distance over which clutter makes a yard
YARD_MIN_CLUTTER = 0.12
YARD_MIN_MADE = 0.75
YARD_MIN_AREA_M2 = 300.0
WAY_CORRIDOR_M = 14.0  # the width kept clear of yards along a mapped way
MAP_REACH_M = 3.0
EDGE_UNIT_M = 0.025  # one step of a lot map's distance to the lot's edge
EDGE_ZERO = 128


@dataclass
class Row:
    """A row of bays in a lot's frame: dividers a bay's width apart between two lines."""

    along_m: tuple  # from the first divider to the last
    across_m: tuple  # the dividers' ends
    ends: tuple  # whether a line closes the row at each of `across_m`


@dataclass
class Lot:
    """A lot's clean model. Its frame has `origin` and its first axis `angle_rad` from east."""

    outline: np.ndarray  # None for a yard, which has `reach` instead
    layer: int
    colour: np.ndarray
    origin: tuple = (0.0, 0.0)
    angle_rad: float = 0.0
    bay_width_m: float = 0.0
    rows: list = field(default_factory=list)
    reach: tuple = None  # a yard's (map rows, map columns, distance to its edge there)


def signed_distance(outline, x, y):
    """Return how far positions are from a closed outline: negative inside it."""
    x, y = np.broadcast_arrays(x, y)
    distance = np.full(x.shape, np.inf)
    inside = np.zeros(x.shape, bool)
    for start, end in zip(outline, np.roll(outline, -1, axis=0), strict=True):
        step = end - start
        share = np.clip(
            ((x - start[0]) * step[0] + (y - start[1]) * step[1]) / max(step @ step, 1e-12), 0, 1
        )
        distance = np.minimum(
            distance, np.hypot(x - start[0] - share * step[0], y - start[1] - share * step[1])
        )
        if start[1] != end[1]:
            crossing = (start[1] > y) != (end[1] > y)
            at = start[0] + (y - start[1]) / (end[1] - start[1]) * step[0]
            inside ^= crossing & (x < at)
    return np.where(inside, -distance, distance)


def fit_outline(outline, lot_like_at):
    """Return a lot's outline with each edge moved to where the photo shows the lot ending.

    `lot_like_at(x, y)` tells which positions show the lot's kind of ground. Each edge of the
    mapped outline keeps its direction and moves, by the median of the readings along it, to
    where that ground ends. An edge too short, or along which the ground does not end
    (another paved area carries on), stays where it was mapped.
    """
    count = len(outline)
    following = np.roll(outline, -1, axis=0)
    steps = following - outline
    lengths = np.hypot(steps[:, 0], steps[:, 1])
    area = 0.5 * np.sum(outline[:, 0] * following[:, 1] - following[:, 0] * outline[:, 1])
    outward = np.stack([steps[:, 1], -steps[:, 0]], 1) / np.maximum(lengths, 1e-9)[:, None]
    outward *= 1.0 if area > 0.0 else -1.0
    laterals = np.arange(-OUTLINE_SEARCH_M, OUTLINE_SEARCH_M + 1e-6, OUTLINE_STEP_M)
    run = round(OUTLINE_RUN_M / OUTLINE_STEP_M)
    offsets = np.zeros(count)
    for edge in range(count):
        if lengths[edge] < OUTLINE_MIN_EDGE_M:
            continue
        shares = (np.arange(1.0, lengths[edge] - 0.5, 1.0)) / lengths[edge]
        along = outline[edge][None, :] + shares[:, None] * steps[edge][None, :]
        x = along[:, 0, None] + outward[edge, 0] * laterals[None, :]
        y = along[:, 1, None] + outward[edge, 1] * laterals[None, :]
        lot_like = lot_like_at(x, y)
        ends = track_surfaces.first_run(~lot_like, run)
        seen = lot_like[:, 0] & (ends >= 0)
        if seen.mean() >= OUTLINE_MIN_EVIDENCE:
            offsets[edge] = np.median(laterals[ends[seen]]) - OUTLINE_STEP_M / 2.0
    moved = outline + outward * offsets[:, None]
    fitted = np.empty_like(outline)
    for vertex in range(count):
        before = (vertex - 1) % count
        cross = (steps[before, 0] * steps[vertex, 1] - steps[before, 1] * steps[vertex, 0]) / max(
            lengths[before] * lengths[vertex], 1e-9
        )
        if abs(cross) < PARALLEL:
            shift = (outward[before] * offsets[before] + outward[vertex] * offsets[vertex]) / 2.0
            fitted[vertex] = outline[vertex] + shift
            continue
        # Where the two moved edges' lines cross.
        gap = moved[vertex] - moved[before]
        share = (gap[0] * steps[vertex, 1] - gap[1] * steps[vertex, 0]) / (
            steps[before, 0] * steps[vertex, 1] - steps[before, 1] * steps[vertex, 0]
        )
        fitted[vertex] = moved[before] + share * steps[before]
    return fitted


def _rhythm(along_m, row, row_count, width_m):
    """Return, per row bin, the sum of the paint's phases at a bay width."""
    waves = np.exp(-2j * np.pi * along_m / width_m)
    return np.bincount(row, waves.real, row_count) + 1j * np.bincount(row, waves.imag, row_count)


def _divider_paint(along_m, across_m):
    """Return which paint is on thin lines across the rows: no cars, no lines along them."""
    column = np.floor((along_m - along_m.min()) / ANGLE_BIN_M).astype(int) + 1
    line = np.floor((across_m - across_m.min()) / ANGLE_BIN_M).astype(int) + DIVIDER_RUN_PX
    grid = np.zeros((line.max() + DIVIDER_RUN_PX + 1, column.max() + 2), bool)
    grid[line, column] = True
    runs = np.lib.stride_tricks.sliding_window_view(
        np.pad(grid, ((DIVIDER_RUN_PX // 2,) * 2, (0, 0))), DIVIDER_RUN_PX, axis=0
    ).sum(-1)
    wide = grid & np.roll(grid, 1, axis=1) & np.roll(grid, -1, axis=1)
    wide = wide | np.roll(wide, 1, axis=1) | np.roll(wide, -1, axis=1)
    return ((runs >= DIVIDER_MIN_RUN_PX) & ~wide)[line, column]


def _rows(along_m, across_m):
    """Return the bay width and rows of paint in a frame, and how strong their rhythm is."""
    thin = _divider_paint(along_m, across_m)
    if thin.sum() < MIN_PAINT_PIXELS:
        return 0.0, [], 0.0
    every = (along_m, across_m)
    along_m, across_m = along_m[thin], across_m[thin]
    lowest = across_m.min()
    row = np.floor((across_m - lowest) / ROW_BIN_M).astype(int)
    row_count = int(row.max()) + 1
    pixels = np.bincount(row, minlength=row_count)
    busy = pixels >= ROW_MIN_PIXELS
    strengths = [
        np.abs(_rhythm(along_m, row, row_count, width))[busy].sum() for width in BAY_WIDTHS_M
    ]
    if not busy.any():
        return 0.0, [], 0.0
    width_m = float(BAY_WIDTHS_M[int(np.argmax(strengths))])
    rhythm = _rhythm(along_m, row, row_count, width_m)
    in_rhythm = busy & (np.abs(rhythm) >= ROW_MIN_RHYTHM * np.maximum(pixels, 1))
    rows, start = [], None
    for index in range(row_count + 1):
        inside = index < row_count and in_rhythm[index]
        if inside and start is not None:
            drift = np.angle(rhythm[index] * np.conj(rhythm[start:index].sum())) / math.tau
            inside = abs(drift) <= ROW_PHASE_DRIFT
            if not inside:
                rows += _row_stretches(along_m, across_m, row, start, index, rhythm, width_m, every)
                start = index
                continue
        if inside and start is None:
            start = index
        elif not inside and start is not None:
            rows += _row_stretches(along_m, across_m, row, start, index, rhythm, width_m, every)
            start = None
    return width_m, _without_repeats(rows), float(max(strengths))


def _without_repeats(rows):
    """Return rows without those that lie over a longer one."""
    kept = []
    for row in sorted(rows, key=lambda row: row.along_m[0] - row.along_m[1]):
        over = [
            min(row.across_m[1], other.across_m[1]) > max(row.across_m[0], other.across_m[0])
            and min(row.along_m[1], other.along_m[1]) > max(row.along_m[0], other.along_m[0])
            for other in kept
        ]
        if not any(over):
            kept.append(row)
    return kept


def _row_stretches(along_m, across_m, row, first, beyond, rhythm, width_m, every):
    """Return the Rows of a run of row bins: its stretches of dividers the photo shows.

    `along_m`, `across_m` are the dividers' paint, `every` all the lot's paint.
    """
    depth_m = (beyond - first) * ROW_BIN_M
    if not ROW_MIN_CORE_M <= depth_m <= BAY_DEPTH_M[1]:
        return []
    offset_m = -np.angle(rhythm[first:beyond].sum()) / math.tau * width_m
    in_run = (row >= first) & (row < beyond)
    number = np.round((along_m - offset_m) / width_m).astype(int)
    on_divider = in_run & (np.abs(along_m - offset_m - number * width_m) <= DIVIDER_REACH_M)
    if not on_divider.any():
        return []
    lowest = int(number[on_divider].min())
    seen = np.bincount(number[on_divider] - lowest)
    shown = seen >= DIVIDER_MIN_SHARE * depth_m / ANGLE_BIN_M
    found, start, last = [], None, None
    for index in list(np.flatnonzero(shown)) + [None]:
        if index is not None and (last is None or index - last - 1 <= MAX_MISSING_DIVIDERS):
            start = index if start is None else start
            last = index
            continue
        if start is not None and shown[start : last + 1].sum() >= MIN_DIVIDERS:
            along = (offset_m + (lowest + start) * width_m, offset_m + (lowest + last) * width_m)
            core = (first * ROW_BIN_M, beyond * ROW_BIN_M)
            low, high = _divider_reach(along_m, across_m, along, offset_m, width_m, core)
            ends = tuple(_line_along(*every, along, at) for at in (low, high))
            if not BAY_DEPTH_M[0] <= high - low <= BAY_DEPTH_M[1]:
                continue
            found.append(Row(along, (round(float(low), 1), round(float(high), 1)), ends))
        start = last = index
    return found


def _divider_reach(along_m, across_m, along, offset_m, width_m, core):
    """Return how far across a row its dividers reach, from the band `core` they were found in.

    `core` is measured from the lowest paint. The dividers reach as far as the photo shows
    paint on a share of them, without a break longer than DIVIDER_BREAK_M.
    """
    lowest = across_m.min()
    number = np.round((along_m - offset_m) / width_m)
    on_divider = (
        (np.abs(along_m - offset_m - number * width_m) <= DIVIDER_REACH_M)
        & (along_m >= along[0] - DIVIDER_REACH_M)
        & (along_m <= along[1] + DIVIDER_REACH_M)
    )
    dividers = round((along[1] - along[0]) / width_m) + 1
    line = np.floor((across_m[on_divider] - lowest) / ANGLE_BIN_M).astype(int)
    shown = np.bincount(line, minlength=int(core[1] / ANGLE_BIN_M) + 1) >= max(
        2.0, DIVIDER_MIN_SHARE * dividers
    )
    first, last = round(core[0] / ANGLE_BIN_M), round(core[1] / ANGLE_BIN_M) - 1
    allowed = round(DIVIDER_BREAK_M / ANGLE_BIN_M)
    missing = 0
    while first > 0 and missing <= allowed:
        first -= 1
        missing = 0 if shown[first] else missing + 1
    first += missing
    missing = 0
    while last < len(shown) - 1 and missing <= allowed:
        last += 1
        missing = 0 if shown[last] else missing + 1
    last -= missing
    return lowest + first * ANGLE_BIN_M, lowest + (last + 1) * ANGLE_BIN_M


def _line_along(along_m, across_m, along, across_at_m):
    """Return whether the paint shows a line along a row, at one of its dividers' ends."""
    near = (
        (np.abs(across_m - across_at_m) <= DIVIDER_REACH_M)
        & (along_m >= along[0])
        & (along_m <= along[1])
    )
    bins = max(1, round((along[1] - along[0]) / ANGLE_BIN_M))
    covered = np.unique(np.floor((along_m[near] - along[0]) / ANGLE_BIN_M)).size
    return bool(covered >= END_LINE_SHARE * bins)


def bay_grid(paint_x, paint_y):
    """Return the bays the painted ground of a lot shows: (angle, bay width, rows), or None.

    `paint_x`, `paint_y` are the positions of the painted pixels. Bay lines are many short
    parallel lines one bay's width apart: the grid's axes are the directions the paint lines
    up along, its rows the bands where the paint keeps the bays' rhythm. `angle` is the
    direction of the rows' axis from x, counter-clockwise; the rows are in that frame.
    """
    if len(paint_x) < MIN_PAINT_PIXELS:
        return None

    def sharpness(angle_rad):
        across = -paint_x * math.sin(angle_rad) + paint_y * math.cos(angle_rad)
        counts = np.bincount(np.floor((across - across.min()) / ANGLE_BIN_M).astype(int))
        return float((counts.astype(float) ** 2).sum())

    coarse = np.radians(np.arange(0.0, 180.0, 1.0))
    best = coarse[int(np.argmax([sharpness(angle) for angle in coarse]))]
    fine = best + np.radians(np.arange(-1.0, 1.01, 0.125))
    best = fine[int(np.argmax([sharpness(angle) for angle in fine]))]
    found = None
    for angle in (best, best + math.pi / 2.0):
        along = paint_x * math.cos(angle) + paint_y * math.sin(angle)
        across = -paint_x * math.sin(angle) + paint_y * math.cos(angle)
        width_m, rows, strength = _rows(along, across)
        if rows and (found is None or strength > found[3]):
            found = (angle, width_m, rows, strength)
    if found is None:
        return None
    rows = sorted(found[2], key=lambda row: row.along_m[0] - row.along_m[1])[:MAX_ROWS]
    return found[0], found[1], rows


def paint_mask(luminance):
    """Return which pixels of a lot are paint: thin and lighter than the ground around them."""
    image = Image.fromarray(np.clip(luminance * 255.0, 0, 255).astype(np.uint8))
    opened = image.filter(ImageFilter.MinFilter(PAINT_OPENING_PX)).filter(
        ImageFilter.MaxFilter(PAINT_OPENING_PX)
    )
    return luminance - np.asarray(opened, np.float32) / 255.0 >= PAINT_CONTRAST


class _Window:
    """The part of the photo around a lot, with the positions of its pixels."""

    def __init__(self, ground, outline):
        mosaic = ground.mosaic
        low = outline.min(0) - WINDOW_MARGIN_M
        high = outline.max(0) + WINDOW_MARGIN_M
        rows, columns = ground.pixel(np.array([low[0], high[0]]), np.array([high[1], low[1]]))
        self.rows = slice(int(rows[0]), int(rows[1]) + 1)
        self.columns = slice(int(columns[0]), int(columns[1]) + 1)
        self.x = (
            mosaic.west + (np.arange(self.columns.start, self.columns.stop) + 0.5) / mosaic.px_per_m
        ) - ground.origin[0]
        self.y = (
            mosaic.north - (np.arange(self.rows.start, self.rows.stop) + 0.5) / mosaic.px_per_m
        ) - ground.origin[1]
        self.px_per_m = mosaic.px_per_m
        self.labels = ground.labels[self.rows, self.columns]
        self.albedo = ground.albedo_at(self.rows, self.columns)

    def inside(self, outline, inset_m=0.0):
        """Return which pixels lie inside an outline, at least `inset_m` from it."""
        drawing = Image.new("L", (len(self.x), len(self.y)), 0)
        points = [
            ((x - self.x[0]) * self.px_per_m + 0.5, (self.y[0] - y) * self.px_per_m + 0.5)
            for x, y in outline
        ]
        ImageDraw.Draw(drawing).polygon(points, fill=255)
        if inset_m > 0.0:
            drawing = drawing.filter(ImageFilter.MinFilter(2 * round(inset_m * self.px_per_m) + 1))
        return np.asarray(drawing) > 0

    def at(self, values, x, y):
        """Return `values` (one per pixel) at positions, the nearest pixel's when outside."""
        columns = np.clip(((x - self.x[0]) * self.px_per_m + 0.5).astype(int), 0, len(self.x) - 1)
        rows = np.clip(((self.y[0] - y) * self.px_per_m + 0.5).astype(int), 0, len(self.y) - 1)
        return values[rows, columns]


def survey(ground, area):
    """Return the Lot of a mapped parking `area`, or None when the photo shows no made lot."""
    if not ground.covers(area.points[:, 0], area.points[:, 1]).all():
        return None
    window = _Window(ground, area.points)
    lot_like = ~np.isin(window.labels, ground_classes.VEGETATION)
    mapped = window.inside(area.points)
    if not mapped.any() or lot_like[mapped].mean() < MIN_LOT_SHARE:
        return None
    colour = ground_classes.clear_colour(window.albedo[mapped & lot_like])
    layer = ground_classes.surface_layer(colour, area.tags.get("surface"), True)
    if layer == ground_classes.LAWN:
        return None
    outline = fit_outline(area.points, lambda x, y: window.at(lot_like, x, y))
    lot = Lot(outline, layer, colour, tuple(outline.mean(0)))
    shown = ground_classes.srgb(window.albedo)
    luminance = 0.3 * shown[..., 0] + 0.59 * shown[..., 1] + 0.11 * shown[..., 2]
    painted = paint_mask(luminance) & window.inside(outline, PAINT_INSET_M) & lot_like
    rows, columns = np.nonzero(painted)
    grid = bay_grid(window.x[columns] - lot.origin[0], window.y[rows] - lot.origin[1])
    if grid is not None:
        lot.angle_rad, lot.bay_width_m, lot.rows = grid
    return lot


def cluttered(brightness, made):
    """Return which pixels of made ground hold something: a car, its shadow, stored goods.

    `brightness` is the photo's (0 to 1). What stands on a surface is much lighter or darker
    than the surface around it.
    """
    image = Image.fromarray(np.clip(brightness * 255.0, 0, 255).astype(np.uint8))
    around = np.asarray(image.filter(ImageFilter.MedianFilter(CLUTTER_SURROUNDINGS_PX)), np.float32)
    return made & (np.abs(brightness - around / 255.0) >= CLUTTER_CONTRAST)


def yard_areas(clutter_share, made_share, free, cell_m):
    """Return the yards of a map: boolean masks of the paved areas cars and goods stand on.

    `clutter_share` and `made_share` are, per map cell, how much of the ground around is
    cluttered and how much is made; `free` tells the cells no road, lot or building takes. A
    yard is a connected area of cluttered made ground of at least YARD_MIN_AREA_M2.
    """
    yard = free & (clutter_share >= YARD_MIN_CLUTTER) & (made_share >= YARD_MIN_MADE)
    seen = np.zeros(yard.shape, bool)
    areas = []
    for row, column in zip(*np.nonzero(yard), strict=True):
        if seen[row, column]:
            continue
        seen[row, column] = True
        stack, cells = [(row, column)], []
        while stack:
            at = stack.pop()
            cells.append(at)
            for step in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                beside = (at[0] + step[0], at[1] + step[1])
                if (
                    0 <= beside[0] < yard.shape[0]
                    and 0 <= beside[1] < yard.shape[1]
                    and yard[beside]
                    and not seen[beside]
                ):
                    seen[beside] = True
                    stack.append(beside)
        if len(cells) * cell_m**2 >= YARD_MIN_AREA_M2:
            area = np.zeros(yard.shape, bool)
            area[tuple(np.array(cells).T)] = True
            areas.append(area)
    return sorted(areas, key=lambda area: -area.sum())


def survey_yards(ground, taken, buildings, ways):
    """Return the yards the photo shows as Lots: paved ground no map calls a parking lot.

    `taken` tells the map cells (TRACK_MAP_M_PER_PX) a road or lot has, `buildings` the
    outlines of buildings and `ways` the polylines of every mapped way: a road that was not
    surveyed keeps what the photo shows of it. A yard is drawn like a lot, without bays: one
    layer in the colour of its clear ground, to a smooth border.
    """
    mosaic = ground.mosaic
    cell_m = YARD_CELL_M
    step = round(CLUTTER_PX_M * mosaic.px_per_m)
    rows, columns = np.ix_(
        np.arange(0, ground.labels.shape[0], step), np.arange(0, ground.labels.shape[1], step)
    )
    made = ~np.isin(ground.labels[rows, columns], ground_classes.VEGETATION)
    clutter = cluttered(ground.brightness_at(rows, columns), made)
    size = (
        round(made.shape[1] * CLUTTER_PX_M / cell_m),
        round(made.shape[0] * CLUTTER_PX_M / cell_m),
    )

    def share(flags):
        image = Image.fromarray((flags * 255).astype(np.uint8))
        smooth = image.filter(ImageFilter.GaussianBlur(YARD_REACH_M / CLUTTER_PX_M))
        return np.asarray(smooth.resize(size, Image.BILINEAR), np.float32) / 255.0

    built = Image.new("L", size, 0)
    pen = ImageDraw.Draw(built)
    for outline in buildings:
        pen.polygon(
            [
                (
                    (x + ground.origin[0] - mosaic.west) / cell_m,
                    (mosaic.north - y - ground.origin[1]) / cell_m,
                )
                for x, y in outline
            ],
            fill=255,
        )
    for way in ways:
        pen.line(
            [
                (
                    (x + ground.origin[0] - mosaic.west) / cell_m,
                    (mosaic.north - y - ground.origin[1]) / cell_m,
                )
                for x, y in way
            ],
            fill=255,
            width=round(WAY_CORRIDOR_M / cell_m),
        )
    free = (np.asarray(built) == 0) & ~np.asarray(
        Image.fromarray(taken).resize(size, Image.NEAREST)
    )
    fine = track_surfaces.TRACK_MAP_M_PER_PX
    lots = []
    for area in yard_areas(share(clutter), share(made), free, cell_m):
        cells = np.nonzero(area)
        low = (max(cells[0].min() - 4, 0), max(cells[1].min() - 4, 0))
        high = (min(cells[0].max() + 5, area.shape[0]), min(cells[1].max() + 5, area.shape[1]))
        window = area[low[0] : high[0], low[1] : high[1]]
        scale = round(cell_m / fine)
        image = Image.fromarray((window * 255).astype(np.uint8)).resize(
            (window.shape[1] * scale, window.shape[0] * scale), Image.NEAREST
        )
        smooth = image.filter(ImageFilter.GaussianBlur(MASK_SMOOTHING_M / fine))
        edge_m = (
            (0.5 - np.asarray(smooth, np.float32) / 255.0) * MASK_SMOOTHING_M * math.sqrt(math.tau)
        )
        coarse = round(cell_m / CLUTTER_PX_M)
        photo = (
            slice(low[0] * coarse, min(high[0] * coarse, made.shape[0])),
            slice(low[1] * coarse, min(high[1] * coarse, made.shape[1])),
        )
        inside = np.asarray(image.resize((window.shape[1] * coarse, window.shape[0] * coarse))) > 0
        inside = inside[: photo[0].stop - photo[0].start, : photo[1].stop - photo[1].start]
        clear = inside & made[photo] & ~clutter[photo]
        if clear.sum() < MIN_PAINT_PIXELS:
            continue
        albedo = ground.albedo_at(rows[photo[0]], columns[:, photo[1]])
        colour = ground_classes.clear_colour(albedo[clear])
        layer = ground_classes.surface_layer(colour, None, True)
        if layer == ground_classes.LAWN:
            continue
        reach = (
            slice(low[0] * scale, high[0] * scale),
            slice(low[1] * scale, high[1] * scale),
            edge_m,
        )
        lots.append(Lot(None, layer, colour, reach=reach))
    return lots


class LotMap:
    """Which lot the ground is in and how far from its edge, for every map pixel."""

    def __init__(self, ground, inside_roads_m):
        """Start with no lot on the ground the photo covers.

        `inside_roads_m` is how far inside a road each map pixel is, 0 outside any: a lot
        stops at the edge of a road the photo shows.
        """
        self.ground = ground
        self._inside_roads_m = inside_roads_m
        mosaic = ground.mosaic
        self.cell_m = track_surfaces.TRACK_MAP_M_PER_PX
        height = round(mosaic.rgb.shape[0] / mosaic.px_per_m / self.cell_m)
        width = round(mosaic.rgb.shape[1] / mosaic.px_per_m / self.cell_m)
        self.lot = np.zeros((height, width), np.uint8)
        self.edge_m = np.full((height, width), MAP_REACH_M, np.float32)
        made = ~np.isin(ground.labels, ground_classes.VEGETATION)
        image = Image.fromarray((made * 255).astype(np.uint8))
        smooth = image.filter(ImageFilter.GaussianBlur(MASK_SMOOTHING_M * mosaic.px_per_m))
        share = np.asarray(smooth.resize((width, height), Image.BILINEAR), np.float32) / 255.0
        # Near its border a smoothed mask falls off as the distance to the border does.
        self._made_edge_m = (0.5 - share) * MASK_SMOOTHING_M * math.sqrt(math.tau)

    def lay(self, number, lot):
        """Lay lot `number` (from 1): its outline, less the vegetation the photo shows in it."""
        if lot.outline is None:
            rows, columns, edge_m = lot.reach
            closer = edge_m < self.edge_m[rows, columns]
            self.lot[rows, columns] = np.where(closer, number, self.lot[rows, columns])
            self.edge_m[rows, columns] = np.where(closer, edge_m, self.edge_m[rows, columns])
            return
        mosaic, origin = self.ground.mosaic, self.ground.origin
        low = lot.outline.min(0) - MAP_REACH_M
        high = lot.outline.max(0) + MAP_REACH_M
        column0 = max(int((low[0] + origin[0] - mosaic.west) / self.cell_m), 0)
        column1 = min(int((high[0] + origin[0] - mosaic.west) / self.cell_m) + 1, self.lot.shape[1])
        row0 = max(int((mosaic.north - high[1] - origin[1]) / self.cell_m), 0)
        row1 = min(int((mosaic.north - low[1] - origin[1]) / self.cell_m) + 1, self.lot.shape[0])
        if column0 >= column1 or row0 >= row1:
            return
        x = mosaic.west + (np.arange(column0, column1) + 0.5) * self.cell_m - origin[0]
        y = mosaic.north - (np.arange(row0, row1) + 0.5) * self.cell_m - origin[1]
        window = (slice(row0, row1), slice(column0, column1))
        edge_m = np.maximum(
            signed_distance(lot.outline, x[None, :], y[:, None]), self._made_edge_m[window]
        )
        on_road_m = self._inside_roads_m[window]
        edge_m = np.maximum(edge_m, np.where(on_road_m > 0.0, on_road_m, -np.inf))
        closer = edge_m < self.edge_m[window]
        self.lot[window] = np.where(closer, number, self.lot[window])
        self.edge_m[window] = np.where(closer, edge_m, self.edge_m[window])

    def tile_image(self, corner):
        """Return the lot map of one pack tile, or None when no lot touches it."""
        window = self.ground.mosaic.pack_tile_window(corner, self.cell_m)
        if not self.lot[window].any():
            return None
        return lot_map_image(self.lot[window], self.edge_m[window])


def lot_map_image(lot, edge_m):
    """Return a lot map as an RGB image.

    R: the lot's number, 0 outside any lot. G: the distance to the lot's edge, EDGE_UNIT_M
    per step from EDGE_ZERO, below it inside the lot.
    """
    steps = np.clip(np.round(edge_m / EDGE_UNIT_M) + EDGE_ZERO, 0, 255).astype(np.uint8)
    return np.stack([lot, steps, np.zeros_like(lot)], -1)


def described(lot):
    """Return a lot as lots.json holds it, in the pack's ROS frame (x south, y east)."""
    return {
        "layer": int(lot.layer),
        "colour": [round(float(channel), 4) for channel in lot.colour],
        "origin_m": [round(-lot.origin[1], 2), round(lot.origin[0], 2)],
        "yaw_deg": round(math.degrees(lot.angle_rad) + 90.0, 2),
        "bay_width_m": round(lot.bay_width_m, 3),
        "rows": [
            {
                "along_m": [round(float(end), 2) for end in row.along_m],
                "across_m": [round(float(end), 2) for end in row.across_m],
                "ends": [int(end) for end in row.ends],
            }
            for row in lot.rows
        ],
    }


def build(ground, extract, inside_roads_m, kept_clear, out_directory):
    """Write the lot maps and lots.json of an area's parking lots.

    Returns the lots, and the distance to the nearest lot's edge per map pixel (negative
    inside a lot).

    `inside_roads_m` is how far inside a surveyed road the ground is, per map pixel
    (track_surfaces.RoadMap.inside_roads): mapped lots often lie over the roads they line.
    `kept_clear` tells the map pixels no yard may take (a circuit's lap and its run-offs).
    The mapped lots come first, then the yards the photo shows, the largest first.
    """
    out_directory = Path(out_directory)
    lots = [lot for lot in (survey(ground, area) for area in extract.parkings()) if lot]
    lots = lots[:MAX_LOTS]
    lot_map = LotMap(ground, inside_roads_m)
    for number, lot in enumerate(lots, 1):
        lot_map.lay(number, lot)
    taken = (lot_map.edge_m < 0.0) | (inside_roads_m > 0.0) | kept_clear
    buildings = [area.points for area in extract.areas if "building" in area.tags]
    ways = [way.points for way in extract.ways if "highway" in way.tags]
    for lot in survey_yards(ground, taken, buildings, ways)[: MAX_LOTS - len(lots)]:
        lots.append(lot)
        lot_map.lay(len(lots), lot)
    track_surfaces.write_tile_maps(out_directory, ground.mosaic, "lots", lot_map.tile_image, "RGB")
    (out_directory / "lots.json").write_text(json.dumps([described(lot) for lot in lots]))
    return lots, lot_map.edge_m
