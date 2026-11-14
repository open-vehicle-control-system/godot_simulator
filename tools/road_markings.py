"""Find the markings painted on a road in the photo's paint, and model them clean.

The input is paint masks in road coordinates: one row per sample along the road, one column
per lateral step across it. The output is a model a road painter would recognise: lines at
a smooth lateral offset, solid or dashed to a standard rhythm, and stop lines. Nothing
here follows the photo's pixels.
"""

from dataclasses import dataclass

import numpy as np
import road_network
import track_surfaces

# Belgian road markings: (dash, gap) in metres. A dashed line takes the standard its rhythm
# in the photo is closest to; its phase is the road's own.
DASHES_M = ((2.5, 10.0), (2.5, 5.0), (5.0, 2.5), (1.25, 1.25))
SOLID = 255
DOUBLE = 254  # two solid lines side by side
DOUBLE_MIN_WIDTH_M = 0.6  # paint this wide in the photo is two lines
LINE_WINDOW_M = 25.0
LINE_MIN_DENSITY = 0.13
LINE_SOLID_DENSITY = 0.75
LINE_WORN_DENSITY = 0.45
LINE_MIN_LENGTH_M = 20.0
LINE_BREAK_M = 12.0
LINE_APART_M = 0.45  # two lines closer than this are one
LINE_DRIFT_M = 1.0  # how far a line may move sideways between two windows
LINE_SMOOTHING_M = 5.0
LINE_REACH_M = 0.4  # how far from a line its paint is looked for
DASH_MIN_STRENGTH = 0.35
STOP_LINE_MIN_SPAN_M = 2.0
STOP_LINE_MAX_LENGTH_M = 1.5
SPAN_BREAK_M = 0.3
STOP_LINE, CROSSING = 1, 2
# A line of triangles pointing at the traffic that gives way: along the road, or against it.
GIVE_WAY_LINE, GIVE_WAY_LINE_AGAINST = 3, 4
BARS = (STOP_LINE, GIVE_WAY_LINE, GIVE_WAY_LINE_AGAINST)


@dataclass
class Line:
    """A painted line: per sample, its offset right of the centreline and its pattern.

    `pattern` is 0 where the line is not painted, SOLID, DOUBLE, or 1 + an index into
    DASHES_M.
    """

    offset_m: np.ndarray
    pattern: np.ndarray


@dataclass
class Transverse:
    """A marking across the road, between two laterals.

    A STOP_LINE, a CROSSING, or a give-way line.
    """

    kind: int
    from_m: float  # along the road
    to_m: float
    left_m: float  # lateral
    right_m: float


def _window_peaks(density, laterals_m):
    """Return the laterals a window's paint gathers at: the middle of each run of it."""
    spread = np.convolve(density, [1.0, 1.0, 1.0], mode="same")
    dense = np.concatenate([[False], spread >= LINE_MIN_DENSITY, [False]])
    changes = np.flatnonzero(np.diff(dense.astype(int)))
    peaks = []
    for first, beyond in zip(changes[::2], changes[1::2], strict=True):
        weights = spread[first:beyond]
        peak = float((laterals_m[first:beyond] * weights).sum() / weights.sum())
        if peaks and peak - peaks[-1] < LINE_APART_M:
            continue
        peaks.append(peak)
    return peaks


def _tracks(paint, laterals_m, step_m):
    """Return the lines' rough courses: lists of (window centre sample, lateral)."""
    window = max(2, round(LINE_WINDOW_M / step_m))
    hop = max(1, window // 2)
    open_tracks, tracks = [], []
    for number, first in enumerate(range(0, max(len(paint) - hop, 1), hop)):
        density = paint[first : first + window].mean(0)
        centre = min(first + window // 2, len(paint) - 1)
        for peak in _window_peaks(density, laterals_m):
            near = [
                track
                for track in open_tracks
                if number - track["window"] in (1, 2)
                and abs(track["course"][-1][1] - peak) <= LINE_DRIFT_M
            ]
            if near:
                track = min(near, key=lambda track: abs(track["course"][-1][1] - peak))
            else:
                track = {"course": []}
                open_tracks.append(track)
                tracks.append(track)
            track["course"].append((centre, peak))
            track["window"] = number
    return [track["course"] for track in tracks if len(track["course"]) >= 2]


def dash_pattern(marks, density, step_m):
    """Return the pattern of a dashed line: 1 + the DASHES_M index its rhythm fits, or 0.

    `marks` flags the samples with paint, `density` is the share of them. Paint without one
    of the standard rhythms is not a line.
    """
    along_m = np.arange(len(marks)) * step_m
    periods = sorted({dash + gap for dash, gap in DASHES_M})
    strength = [
        abs((np.exp(-2j * np.pi * along_m / period) * marks).sum()) / max(marks.sum(), 1)
        for period in periods
    ]
    best = int(np.argmax(strength))
    if strength[best] < DASH_MIN_STRENGTH:
        return 0
    fitting = [index for index, (dash, gap) in enumerate(DASHES_M) if dash + gap == periods[best]]
    duty = [abs(DASHES_M[index][0] / periods[best] - density) for index in fitting]
    return 1 + fitting[int(np.argmin(duty))]


def find_lines(paint, laterals_m, step_m):
    """Return the Lines painted along a road.

    `paint` flags painted ground per sample along the road (rows, `step_m` apart) and
    lateral (columns, at `laterals_m` right of the centreline).
    """
    count = len(paint)
    samples = np.arange(count)
    window = min(max(3, round(LINE_WINDOW_M / step_m) | 1), (count - 1) | 1)
    lines = []
    for course in _tracks(paint, laterals_m, step_m):
        centres, peaks = np.array(course).T
        around = np.interp(samples, centres, peaks)
        near = np.abs(laterals_m[None, :] - around[:, None]) <= LINE_REACH_M
        marked = paint & near
        marks = marked.any(1)
        raw = np.where(
            marks, (marked * laterals_m[None, :]).sum(1) / np.maximum(marked.sum(1), 1), np.nan
        )
        if not marks.any():
            continue
        # The course found window by window already tells the line's paint from the rest:
        # a median over a long stretch would reject the paint of a line that drifts across
        # a road mapped off its centre.
        carried = np.interp(samples, samples[marks], raw[marks])
        offset = road_network.open_smooth(carried, LINE_SMOOTHING_M / step_m)
        padded = np.pad(marks.astype(float), window // 2, mode="reflect")
        density = np.convolve(padded, np.full(window, 1.0 / window), mode="valid")
        shown = density >= LINE_MIN_DENSITY
        shown &= (samples >= centres[0] - window // 2) & (samples <= centres[-1] + window // 2)
        shown = ~track_surfaces.keep_long_open_runs(~shown, round(LINE_BREAK_M / step_m) + 1)
        shown = track_surfaces.keep_long_open_runs(shown, round(LINE_MIN_LENGTH_M / step_m))
        solid = shown & (density >= LINE_SOLID_DENSITY)
        solid = track_surfaces.keep_long_open_runs(solid, round(LINE_MIN_LENGTH_M / step_m))
        dashed = shown & ~solid
        pattern = np.where(solid, SOLID, 0).astype(np.uint8)
        if dashed.sum() * step_m >= LINE_MIN_LENGTH_M:
            rhythm = dash_pattern(marks & dashed, density[dashed].mean(), step_m)
            # Without a rhythm, what the photo shows of a line is a worn solid one, or nothing.
            worn = dashed & (density >= LINE_WORN_DENSITY)
            pattern[dashed if rhythm else worn] = rhythm if rhythm else SOLID
        width_m = (marked.sum(1) * (laterals_m[1] - laterals_m[0]))[marks & (pattern == SOLID)]
        if len(width_m) and np.median(width_m) >= DOUBLE_MIN_WIDTH_M:
            pattern[pattern == SOLID] = DOUBLE
        if pattern.any():
            lines.append(Line(offset, pattern))
    return lines


def _widest_run(flags, laterals_m):
    """Return the ends (left, right) of a row's widest painted run, closing short breaks."""
    step_m = laterals_m[1] - laterals_m[0]
    best, start, last = (0.0, 0.0), None, None
    for column in np.flatnonzero(flags):
        if last is None or (column - last - 1) * step_m > SPAN_BREAK_M:
            start = column
        last = column
        if laterals_m[last] - laterals_m[start] > best[1] - best[0]:
            best = (laterals_m[start], laterals_m[last])
    return best


def find_stop_lines(paint, laterals_m, step_m):
    """Return the stop lines of a road: short bars across at least a lane.

    `paint` flags, as for `find_lines`, the ground lighter than the road is a few metres
    before and after: a line along the road is not in it. A longer band is not a marking:
    at the photo's resolution a pedestrian crossing's stripes cannot be told from sunlit
    ground between two shadows.
    """
    spans = np.array([_widest_run(flags, laterals_m) for flags in paint])
    wide = spans[:, 1] - spans[:, 0] >= STOP_LINE_MIN_SPAN_M
    found, start = [], None
    for sample, flag in enumerate(np.append(wide, False)):
        if flag and start is None:
            start = sample
        elif not flag and start is not None:
            if (sample - start) * step_m <= STOP_LINE_MAX_LENGTH_M:
                left, right = np.median(spans[start:sample], axis=0)
                found.append(
                    Transverse(
                        STOP_LINE, start * step_m, sample * step_m, float(left), float(right)
                    )
                )
            start = None
    return found
