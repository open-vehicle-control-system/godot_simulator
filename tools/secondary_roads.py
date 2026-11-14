"""Survey the roads around a circuit: service, access, paddock and public roads.

OpenStreetMap says where a road is, roughly; the orthophoto is the evidence for its clean
model: a centreline, one smooth edge offset per stretch, the lines painted on it, its
surface and colour. Outputs, as docs/pack_format.md describes them: one road map per tile a
road passes, and the roads' lines image.
"""

import math
import warnings
from dataclasses import dataclass
from pathlib import Path

import ground_classes
import numpy as np
import road_markings
import road_network
import track_surfaces
from PIL import Image

SEARCH_BEYOND_M = 6.0  # how far beyond a road's usual edge its real edge is looked for
MIN_PAVED_WIDTH_M = 1.2
ROAD_BREAK_M = 1.0  # paint, a kerb, a car: a break this short does not end a road
MIN_EVIDENCE = 0.3  # the share of a road's length whose edge the photo must show
WIDTH_MEDIAN_M = 60.0
WIDTH_SMOOTHING_M = 15.0
HALF_WIDTH_RANGE_M = (1.0, 7.0)
COLOUR_INSET_M = 0.5
COLOUR_MEDIAN_M = 30.0
COLOUR_SMOOTHING_M = 10.0
SHADE_FLOOR = 0.75  # a stretch darker than this share of its road's colour is in shadow
COLOUR_BINS = 16  # the lanes across a road whose colour is kept apart
PAINT_STEP_M = 0.5  # how far apart along a road its paint is sampled
PAINT_CONTRAST = 0.06  # how much lighter than the road around it paint is in the photo
PAINT_ACROSS_M = 1.0  # the width a line is lighter than the median of
WIDE_PAINT_ACROSS_M = 2.0
WIDE_PAINT_CONTRAST = 0.12
PAINT_ALONG_M = 15.0  # the length a bar across the road is lighter than the median of
MAX_LINES = 6
LINES_APART_M = 0.8  # the photo's paint closer than this is one line found twice
LINES_BEYOND_M = 2.5
EDGE_LINE_INSET_M = 0.3
EDGE_LINE_WITHIN_M = 0.9  # a line this close to the edge is an edge line
JUNCTION_RADIUS_M = 3.0
JUNCTION_SNAP_M = 6.0
STOP_LINE_BEFORE_JUNCTION_M = 15.0
BAND_M = 4096  # the lines image's width: the roads lie end to end in bands this long
ROAD_PADDING_M = 4
ROWS_PER_BAND = 2 + MAX_LINES + COLOUR_BINS
ENDS_UNIT_M = 0.05  # one step of the ends of a marking across the road
OFFSET_ZERO = 32768
MAX_ROAD_LENGTH_M = 2000.0
PAVED_LABELS = (ground_classes.WORN_ASPHALT, ground_classes.TRACK_ASPHALT, ground_classes.GRAVEL)
UNPAVED_LABELS = PAVED_LABELS + (ground_classes.SOIL, ground_classes.DRY_GRASS)
LINED_LAYERS = (
    ground_classes.TRACK_ASPHALT,
    ground_classes.WORN_ASPHALT,
    ground_classes.CONCRETE,
    ground_classes.PAVERS,
)


@dataclass
class SurveyedRoad:
    """A road's clean model: sections along its fitted centreline and what lies on them."""

    kind: road_network.Kind
    tags: dict
    sections: dict
    half_width_m: np.ndarray
    gaps: list  # per side (left, right): where the edge opens onto something else
    colour: np.ndarray  # linear albedo per section and lane across, left to right
    layer: int
    lines: list  # road_markings.Line, per section
    transverse: list  # road_markings.Transverse


def runs(kept):
    """Return the runs of a road's kept sections as slices, none over MAX_ROAD_LENGTH_M."""
    found, start = [], None
    for index, keep in enumerate(np.append(kept, False)):
        if keep and start is None:
            start = index
        elif not keep and start is not None:
            for piece in range(start, index, round(MAX_ROAD_LENGTH_M)):
                end = min(piece + round(MAX_ROAD_LENGTH_M) + 1, index)
                if end - piece > road_network.MIN_ROAD_LENGTH_M:
                    found.append(slice(piece, end))
            start = None
    return found


def near(line_x, line_y, reach_m):
    """Return a test of which positions lie within `reach_m` of a line's points."""

    def within(x, y):
        return (
            np.hypot(x[:, None] - line_x[None, :], y[:, None] - line_y[None, :]).min(1) <= reach_m
        )

    return within


def paved_span(road_like, laterals_m, usual_half_width_m):
    """Return how far left and right of a section's centre its road reaches, NaN if unseen.

    `road_like` flags the ground along the section's cross profile at `laterals_m` (negative
    to the left). The road is the run of road-like ground that covers most of where the road
    usually is; breaks shorter than ROAD_BREAK_M do not end it. A
    side whose run reaches the end of the profile opens onto something else: NaN.
    """
    step_m = laterals_m[1] - laterals_m[0]
    changes = np.flatnonzero(np.diff(np.concatenate([[False], road_like, [False]]).astype(int)))
    starts, ends = list(changes[::2]), list(changes[1::2] - 1)
    index = 1
    while index < len(starts):
        if (starts[index] - ends[index - 1] - 1) * step_m < ROAD_BREAK_M:
            ends[index - 1] = ends.pop(index)
            starts.pop(index)
        else:
            index += 1
    best, best_overlap = None, 0.0
    for start, end in zip(starts, ends, strict=True):
        overlap = min(laterals_m[end], usual_half_width_m) - max(
            laterals_m[start], -usual_half_width_m
        )
        if overlap > best_overlap and laterals_m[end] - laterals_m[start] >= MIN_PAVED_WIDTH_M:
            best, best_overlap = (start, end), overlap
    if best is None:
        return np.nan, np.nan
    left = np.nan if best[0] == 0 else -laterals_m[best[0]]
    right = np.nan if best[1] == len(laterals_m) - 1 else laterals_m[best[1]]
    return left, right


def running_median(values, window):
    """Return the running median of an open run of values, ignoring NaN."""
    half = min(window // 2, len(values) - 1)
    padded = np.pad(values, half, mode="reflect")
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return np.nanmedian(np.lib.stride_tricks.sliding_window_view(padded, 2 * half + 1), -1)


def fit_road(raw_left_m, raw_right_m, usual_half_width_m, spacing_m):
    """Return a road's centre shift, half width and edge gaps from its edge readings.

    The readings are per section, from the mapped centreline, NaN where the photo shows no
    edge. Returns None when the photo does not confirm the road. A side without evidence is
    taken where the road usually ends. The shift is how far right of the mapped centreline
    the road's centre is; the half width holds over a stretch.
    """
    edges, gaps, shown = [], [], []
    for raw in (raw_left_m, raw_right_m):
        edge, gap = track_surfaces.fit_open_edge(raw, spacing_m)
        shown.append(not np.isnan(edge).any() and 1.0 - gap.mean() >= MIN_EVIDENCE)
        edges.append(edge if shown[-1] else np.full(len(raw), usual_half_width_m))
        gaps.append(gap)
    if not any(shown):
        return None
    shift = (edges[1] - edges[0]) / 2.0
    half_width = running_median((edges[0] + edges[1]) / 2.0, round(WIDTH_MEDIAN_M / spacing_m) | 1)
    half_width = road_network.open_smooth(half_width, WIDTH_SMOOTHING_M / spacing_m)
    return shift, np.clip(half_width, *HALF_WIDTH_RANGE_M), gaps


def lay_out(lengths_m):
    """Return where each road starts along the lines image's axis, and the band count.

    Roads lie end to end ROAD_PADDING_M apart; a road does not straddle two bands.
    """
    starts, cursor = [], ROAD_PADDING_M
    for length_m in lengths_m:
        needed = math.ceil(length_m) + ROAD_PADDING_M
        if cursor % BAND_M + needed > BAND_M:
            cursor = (cursor // BAND_M + 1) * BAND_M + ROAD_PADDING_M
        starts.append(cursor)
        cursor += needed + ROAD_PADDING_M
    return starts, (cursor - 1) // BAND_M + 1


def lines_image(roads, starts, bands):
    """Return the roads' lines image: BAND_M columns, ROWS_PER_BAND rows per band, RGBA.

    A road starting at `start` metres takes the columns from `start % BAND_M` of band
    `start // BAND_M`, one per metre. Row 0: (R, G) the road's half width, 16 bits,
    EDGE_UNIT_M per step; B the road's layer. Row 1: the marking across the road at that
    metre: R its kind, G and B its left and right ends, ENDS_UNIT_M per step, 128 on the
    centreline, above to the right. Rows 2 to 1 + MAX_LINES: a line each: (R, G) its
    offset right of the centreline, 16 bits, EDGE_UNIT_M per step from OFFSET_ZERO; B its
    pattern. The last COLOUR_BINS rows: the road's colour in lanes from its left edge to
    its right, sRGB. A road's first and last columns carry on through the padding around
    it.
    """
    image = np.zeros((bands * ROWS_PER_BAND, BAND_M, 4), np.uint8)
    image[..., 3] = 255

    def ends(offset_m):
        return np.clip(np.round(np.asarray(offset_m) / ENDS_UNIT_M) + 128, 0, 255)

    for road, start in zip(roads, starts, strict=True):
        s = road.sections["s"]
        metres = np.arange(-ROAD_PADDING_M // 2, math.ceil(s[-1]) + ROAD_PADDING_M // 2 + 1)
        nearest = np.clip(np.searchsorted(s, metres - 0.5), 0, len(s) - 1)
        inside = (metres >= 0) & (metres <= s[-1])
        row = (start // BAND_M) * ROWS_PER_BAND
        columns = start % BAND_M + metres
        image[row, columns, 0], image[row, columns, 1] = track_surfaces.sixteen_bits(
            road.half_width_m[nearest] / track_surfaces.EDGE_UNIT_M
        )
        image[row, columns, 2] = road.layer
        for mark in road.transverse:
            covered = columns[(metres + 0.5 >= mark.from_m) & (metres + 0.5 < mark.to_m) & inside]
            if mark.kind in road_markings.BARS:
                covered = [start % BAND_M + int((mark.from_m + mark.to_m) / 2.0)]
            image[row + 1, covered, 0] = mark.kind
            image[row + 1, covered, 1] = ends(mark.left_m)
            image[row + 1, covered, 2] = ends(mark.right_m)
        for number, line in enumerate(road.lines[:MAX_LINES]):
            line_row = row + 2 + number
            image[line_row, columns, 0], image[line_row, columns, 1] = track_surfaces.sixteen_bits(
                line.offset_m[nearest] / track_surfaces.EDGE_UNIT_M + OFFSET_ZERO
            )
            image[line_row, columns, 2] = np.where(inside, line.pattern[nearest], 0)
        image[row + 2 + MAX_LINES : row + ROWS_PER_BAND, columns, :3] = np.clip(
            np.round(ground_classes.srgb(road.colour[nearest]) * 255.0), 0, 255
        ).transpose(1, 0, 2)
    return image


def _profile(ground, sections, laterals_m):
    """Return the photo pixels of each section's cross profile (rows, columns)."""
    east = sections["x"][:, None] + sections["ty"][:, None] * laterals_m[None, :]
    north = sections["y"][:, None] - sections["tx"][:, None] * laterals_m[None, :]
    return ground.pixel(east, north)


def _colours(ground, sections, half_width_m, road_labels):
    """Return a road's colour per section and lane, or None where the photo shows no road.

    Each of the COLOUR_BINS lanes from the left edge to the right keeps its own colour (a
    cycle path, wheel tracks), as the median along the road: without cars, shadows or seams.
    """
    lanes = (np.arange(COLOUR_BINS) + 0.5) / COLOUR_BINS * 2.0 - 1.0
    laterals = lanes[None, :] * half_width_m[:, None]
    east = sections["x"][:, None] + sections["ty"][:, None] * laterals
    north = sections["y"][:, None] - sections["tx"][:, None] * laterals
    rows, columns = ground.pixel(east, north)
    on_road = np.isin(ground.labels[rows, columns], road_labels)
    albedo = np.where(on_road[..., None], ground.albedo_at(rows, columns), np.nan)
    if on_road.mean() < MIN_EVIDENCE:
        return None
    window = round(COLOUR_MEDIAN_M) | 1
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        whole = np.nanmedian(albedo, axis=(0, 1))
        along = np.stack(
            [
                np.stack([running_median(albedo[:, lane, c], window) for c in range(3)], -1)
                for lane in range(COLOUR_BINS)
            ],
            1,
        )
        across = np.nanmedian(along, axis=1)
    across = np.where(np.isnan(across), whole[None, :], across)
    colour = np.where(np.isnan(along), across[:, None, :], along)
    for lane in range(COLOUR_BINS):
        for channel in range(3):
            colour[:, lane, channel] = road_network.open_smooth(
                colour[:, lane, channel], COLOUR_SMOOTHING_M
            )
    shade = colour.mean(-1) / max(whole.mean(), 1e-3)
    return colour * (np.maximum(shade, SHADE_FLOOR) / np.maximum(shade, 1e-3))[..., None]


def _median_filtered(values, window, axis):
    """Return `values` under a running median along `axis`."""
    pad = [(0, 0), (0, 0)]
    pad[axis] = (window // 2, window // 2)
    padded = np.pad(values, pad, mode="reflect")
    return np.median(np.lib.stride_tricks.sliding_window_view(padded, window, axis=axis), -1)


def paint_masks(luminance, by_road, on_road, lateral_step_m):
    """Return where a road is painted: for lines along it, and for markings across it.

    `luminance` is the road in road coordinates (rows PAINT_STEP_M apart along it, columns
    across it). Paint is lighter than the road around it: than the median across a line's
    surroundings for a line (looked for `by_road`), than the median before and after for a
    bar (looked for `on_road`).
    """
    across = round(PAINT_ACROSS_M / lateral_step_m) | 1
    along = min(round(PAINT_ALONG_M / PAINT_STEP_M) | 1, (len(luminance) - 1) | 1)
    wide = round(WIDE_PAINT_ACROSS_M / lateral_step_m) | 1
    lines = luminance - _median_filtered(luminance, across, 1) >= PAINT_CONTRAST
    # A double line is too wide to stand out of its close surroundings, but lighter than any
    # lane's tone.
    lines |= luminance - _median_filtered(luminance, wide, 1) >= WIDE_PAINT_CONTRAST
    bars = luminance - _median_filtered(luminance, along, 0) >= PAINT_CONTRAST
    return lines & by_road, bars & on_road


def markings(ground, sections, half_width_m, road_labels):
    """Return a road's lines (per section, as the photo places them) and markings across.

    Paint is looked for up to LINES_BEYOND_M beyond the fitted edges, on road-like ground:
    where the photo shows no edge, a line still shows how far the road reaches.
    """
    s = sections["s"]
    at = np.arange(0.0, s[-1], PAINT_STEP_M)
    fine = {key: np.interp(at, s, sections[key]) for key in ("x", "y", "tx", "ty")}
    half_width = np.interp(at, s, half_width_m)
    step_m = track_surfaces.LATERAL_STEP_M
    reach = HALF_WIDTH_RANGE_M[1] + LINES_BEYOND_M
    laterals = np.arange(-reach, reach + 0.01, step_m)
    rows, columns = _profile(ground, fine, laterals)
    luminance = ground.brightness_at(rows, columns)
    on_road = np.abs(laterals)[None, :] <= half_width[:, None]
    by_road = np.abs(laterals)[None, :] <= half_width[:, None] + LINES_BEYOND_M
    by_road &= np.isin(ground.labels[rows, columns], road_labels)
    line_paint, bar_paint = paint_masks(luminance, by_road, on_road, step_m)
    nearest = np.clip(np.round(s / PAINT_STEP_M).astype(int), 0, len(at) - 1)
    lines = [
        road_markings.Line(line.offset_m[nearest], line.pattern[nearest])
        for line in road_markings.find_lines(line_paint, laterals, PAINT_STEP_M)
    ]
    lines.sort(key=lambda line: -np.count_nonzero(line.pattern))
    for index, line in enumerate(lines):
        for longer in lines[:index]:
            same = (np.abs(line.offset_m - longer.offset_m) < LINES_APART_M) & (longer.pattern > 0)
            line.pattern[same] = 0
    lines = [line for line in lines if line.pattern.any()]
    transverse = road_markings.find_stop_lines(bar_paint, laterals, PAINT_STEP_M)
    return lines[:MAX_LINES], transverse


def widened(half_width_m, lines):
    """Return a road's half width, reaching past every line painted on it."""
    needed = half_width_m.copy()
    for line in lines:
        beyond = np.abs(line.offset_m) + EDGE_LINE_INSET_M
        needed = np.where(line.pattern > 0, np.maximum(needed, beyond), needed)
    smooth = road_network.open_smooth(needed, WIDTH_SMOOTHING_M / road_network.SECTION_SPACING_M)
    return np.clip(np.maximum(half_width_m, smooth), *HALF_WIDTH_RANGE_M)


def survey(ground, road, sections):
    """Return the SurveyedRoad of a road's mapped `sections`, or None if the photo shows none."""
    kind = road.kind
    road_labels = PAVED_LABELS if kind.paved else UNPAVED_LABELS
    reach = kind.half_width_m + SEARCH_BEYOND_M
    laterals = np.arange(-reach, reach + 0.01, track_surfaces.LATERAL_STEP_M)
    rows, columns = _profile(ground, sections, laterals)
    road_like = np.isin(ground.labels[rows, columns], road_labels)
    spans = np.array([paved_span(flags, laterals, kind.half_width_m) for flags in road_like])
    spacing_m = road_network.SECTION_SPACING_M
    fitted = fit_road(spans[:, 0], spans[:, 1], kind.half_width_m, spacing_m)
    if fitted is None:
        return None
    shift, half_width, gaps = fitted
    centre = np.stack(
        [sections["x"] + sections["ty"] * shift, sections["y"] - sections["tx"] * shift], 1
    )
    fitted_sections = road_network.sections_along(centre)
    seen = _colours(ground, fitted_sections, half_width, road_labels)
    if seen is None:
        return None
    layer = ground_classes.surface_layer(
        np.median(seen, axis=(0, 1)), road.tags.get("surface"), kind.paved
    )
    if layer == ground_classes.LAWN:
        return None
    lines, transverse = [], []
    if layer in LINED_LAYERS:
        lines, transverse = markings(ground, fitted_sections, half_width, road_labels)
        half_width = widened(half_width, lines)
    colour = _colours(ground, fitted_sections, half_width, road_labels)
    return SurveyedRoad(
        kind, road.tags, fitted_sections, half_width, gaps, colour, layer, lines, transverse
    )


def open_junctions(surveyed, pieces, roads):
    """Stop the lines of surveyed roads where other roads join them.

    `pieces` names, for each surveyed road, its road in `roads`. A road through a junction
    loses its edge line on the side the other leaves from, over the other's width and the
    corners' radius; a road that joins it loses its lines over the through road's width.
    A stop line is kept only before a junction: elsewhere a bar across a lane is a seam of
    the photo or a lorry's roof.
    """
    by_road = {}
    for index, road_index in enumerate(pieces):
        by_road.setdefault(road_index, []).append(index)

    def nearest(road_index, point):
        found = None
        for index in by_road.get(road_index, []):
            sections = surveyed[index].sections
            distance = np.hypot(sections["x"] - point[0], sections["y"] - point[1])
            place = int(distance.argmin())
            if distance[place] <= JUNCTION_SNAP_M and (found is None or distance[place] < found[2]):
                found = (index, place, distance[place])
        return found

    def open_edge(index, place, reach_m, sides):
        road = surveyed[index]
        within = np.abs(road.sections["s"] - road.sections["s"][place]) <= reach_m
        for line in road.lines:
            for side in sides:
                by_edge = side * line.offset_m >= road.half_width_m - EDGE_LINE_WITHIN_M
                line.pattern[within & by_edge] = 0

    def end_lines(index, place, reach_m):
        road = surveyed[index]
        within = np.abs(road.sections["s"] - road.sections["s"][place]) <= reach_m
        for line in road.lines:
            line.pattern[within] = 0

    met = [[] for _ in surveyed]
    for road_index, place, other_index, side in road_network.junctions(roads):
        through = nearest(road_index, roads[road_index].points[place])
        if through is None:
            continue
        met[through[0]].append(surveyed[through[0]].sections["s"][through[1]])
        joining = nearest(other_index, roads[road_index].points[place])
        half_width_m = (
            surveyed[joining[0]].half_width_m[joining[1]]
            if joining
            else roads[other_index].kind.half_width_m
        )
        open_edge(through[0], through[1], half_width_m + JUNCTION_RADIUS_M, [side])
        if joining:
            end_lines(joining[0], joining[1], surveyed[through[0]].half_width_m[through[1]])
            met[joining[0]].append(surveyed[joining[0]].sections["s"][joining[1]])
    for road, junctions_m in zip(surveyed, met, strict=True):
        road.transverse = [
            mark
            for mark in road.transverse
            if mark.kind != road_markings.STOP_LINE
            or any(abs(mark.from_m - at) <= STOP_LINE_BEFORE_JUNCTION_M for at in junctions_m)
        ]


def survey_area(ground, extract, within):
    """Return the surveyed roads of an area, the minor roads first.

    `within(road, x, y)` tells which positions are in the area for a mapped road: a road
    with a section in it is surveyed as far as the photo covers it, so no road ends in sight
    of the area.
    """
    roads = road_network.chain(extract.highways(set(road_network.KINDS)))
    surveyed, pieces = [], []
    for road_index, road in enumerate(roads):
        sections = road_network.centreline(road.points)
        covered = ground.covers(sections["x"], sections["y"])
        kept = covered & (covered & within(road, sections["x"], sections["y"])).any()
        for run in runs(kept):
            piece = {key: values[run] for key, values in sections.items()}
            piece["s"] = piece["s"] - piece["s"][0]
            found = survey(ground, road, piece)
            if found is not None:
                surveyed.append(found)
                pieces.append(road_index)
    open_junctions(surveyed, pieces, roads)
    # The minor roads first: where roads of one rank overlap the map keeps the first laid.
    return sorted(surveyed, key=lambda road: road.kind.rank)


def lay(ground, surveyed):
    """Return the road map surveyed roads are laid on, end to end along its axis."""
    starts, _ = lay_out([road.sections["s"][-1] for road in surveyed])
    road_map = track_surfaces.RoadMap(ground.mosaic)
    for road, start in zip(surveyed, starts, strict=True):
        road_map.lay_road(
            ground.origin,
            road.sections,
            start + road.sections["s"],
            road.half_width_m,
            road.kind.rank,
        )
    return road_map


def write(ground, surveyed, road_map, out_directory):
    """Write the road maps and lines image of surveyed roads into `out_directory`.

    `road_map` is the map `lay` laid them on.
    """
    out_directory = Path(out_directory)
    starts, bands = lay_out([road.sections["s"][-1] for road in surveyed])
    track_surfaces.write_tile_maps(
        out_directory,
        ground.mosaic,
        "roads",
        lambda corner: road_map.tile_image(ground.mosaic, corner),
        "RGBA",
    )
    Image.fromarray(lines_image(surveyed, starts, bands), "RGBA").save(
        out_directory / "roads_lines.png"
    )
