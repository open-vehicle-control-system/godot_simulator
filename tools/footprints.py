"""Building footprints: a mapped outline made a clean, regular polygon, and its triangles.

A ring is an (N, 2) array of points (metres east, north), its first point not repeated. A
mapped outline is evidence of where the walls stand, drawn by hand over a photo: its corners
are nearly square and its walls nearly straight. `cleaned` makes it a simple counter-clockwise
polygon, `regularised` squares it without moving it further than a tolerance, `triangulated`
cuts it, courtyards left open, into the triangles a roof or a floor is made of.

Needs numpy.
"""

import math

import numpy as np

MERGE_M = 0.05  # points closer than this are one
STRAIGHT_M = 0.02  # a point this close to the line through its neighbours is on it
JITTER_M = 0.2  # a wall's points this close to its line are the mapper's hand, not the wall
SNAP_DEG = 15.0  # a wall this close to the footprint's main direction, or across it, takes it
PARALLEL_SIN = 0.05
MIN_AREA_M2 = 1.0
EAR_MIN_DOUBLED_AREA_M2 = 1e-9


class FootprintError(ValueError):
    """A polygon this module cannot cut into triangles."""


def signed_area_m2(ring):
    """Return a ring's area, positive when it runs counter-clockwise."""
    following = np.roll(ring, -1, axis=0)
    return 0.5 * float((ring[:, 0] * following[:, 1] - following[:, 0] * ring[:, 1]).sum())


def cross(first, second):
    """Return the z of the cross product of 2D vectors."""
    return first[..., 0] * second[..., 1] - first[..., 1] * second[..., 0]


def contains(ring, point):
    """Tell whether a point lies inside a ring."""
    starts, ends = ring, np.roll(ring, -1, axis=0)
    spans = (starts[:, 1] > point[1]) != (ends[:, 1] > point[1])
    rise = np.where(spans, ends[:, 1] - starts[:, 1], 1.0)
    crossing_east = starts[:, 0] + (point[1] - starts[:, 1]) / rise * (ends[:, 0] - starts[:, 0])
    return bool((spans & (crossing_east > point[0])).sum() % 2)


def _crossing(start_1, end_1, start_2, end_2):
    """Return where two segments cross within both, or None."""
    along_1, along_2 = end_1 - start_1, end_2 - start_2
    denominator = cross(along_1, along_2)
    if abs(denominator) < 1e-12:
        return None
    share_1 = cross(start_2 - start_1, along_2) / denominator
    share_2 = cross(start_2 - start_1, along_1) / denominator
    if 0.0 < share_1 < 1.0 and 0.0 < share_2 < 1.0:
        return start_1 + share_1 * along_1
    return None


def _first_crossing(ring):
    """Return (edge, later edge, point) where two edges of a ring cross, or None."""
    count = len(ring)
    for edge in range(count):
        for later in range(edge + 2, count):
            if edge == 0 and later == count - 1:
                continue
            point = _crossing(ring[edge], ring[edge + 1], ring[later], ring[(later + 1) % count])
            if point is not None:
                return edge, later, point
    return None


def is_simple(ring):
    """Tell whether no two edges of a ring cross."""
    return _first_crossing(ring) is None


def _without_crossings(ring):
    """Return the largest loop of a ring that crosses itself."""
    while len(ring) >= 4:
        found = _first_crossing(ring)
        if found is None:
            break
        edge, later, point = found
        inner = np.vstack([point, ring[edge + 1 : later + 1]])
        outer = np.vstack([point, ring[later + 1 :], ring[: edge + 1]])
        ring = inner if abs(signed_area_m2(inner)) > abs(signed_area_m2(outer)) else outer
    return ring


def _without_repeats(ring):
    kept = [ring[0]]
    for point in ring[1:]:
        if np.hypot(*(point - kept[-1])) > MERGE_M:
            kept.append(point)
    if len(kept) > 1 and np.hypot(*(kept[-1] - kept[0])) <= MERGE_M:
        kept.pop()
    return np.array(kept)


def _without_straight_points(ring):
    """Return a ring without the points on the line through their neighbours, or spikes."""
    ring = list(ring)
    index = 0
    while len(ring) >= 3 and index < len(ring):
        before, point, after = ring[index - 1], ring[index], ring[(index + 1) % len(ring)]
        span = after - before
        length_m = float(np.hypot(*span))
        off_m = abs(float(cross(span, point - before))) / length_m if length_m > MERGE_M else 0.0
        if off_m < STRAIGHT_M:
            del ring[index]
            index = max(index - 1, 0)
        else:
            index += 1
    return np.array(ring).reshape(-1, 2)


def cleaned(ring):
    """Return a mapped ring as a simple counter-clockwise polygon, or None without an area.

    Points drawn twice, points along a straight wall and loops where the outline crosses
    itself are dropped.
    """
    ring = np.asarray(ring, np.float64).reshape(-1, 2)
    if len(ring) < 3:
        return None
    ring = _without_repeats(ring)
    if len(ring) >= 4:
        ring = _without_crossings(ring)
    ring = _without_straight_points(ring)
    if len(ring) < 3 or abs(signed_area_m2(ring)) < MIN_AREA_M2:
        return None
    return ring if signed_area_m2(ring) > 0.0 else ring[::-1].copy()


def main_direction_rad(ring):
    """Return the direction most of a ring's length runs along or across, in [0, pi / 2)."""
    edges = np.roll(ring, -1, axis=0) - ring
    lengths_m = np.hypot(edges[:, 0], edges[:, 1])
    angles = np.arctan2(edges[:, 1], edges[:, 0])
    quarter = math.atan2(
        float((lengths_m * np.sin(4.0 * angles)).sum()),
        float((lengths_m * np.cos(4.0 * angles)).sum()),
    )
    return (quarter / 4.0) % (math.pi / 2.0)


def distance_to_ring_m(points, ring):
    """Return each point's distance to the nearest edge of a ring."""
    starts, ends = ring, np.roll(ring, -1, axis=0)
    along = ends - starts
    lengths_squared = np.maximum((along**2).sum(1), 1e-12)
    offsets = points[:, None, :] - starts[None, :, :]
    shares = np.clip((offsets * along[None]).sum(2) / lengths_squared[None], 0.0, 1.0)
    nearest = starts[None] + shares[..., None] * along[None]
    return np.sqrt(((points[:, None, :] - nearest) ** 2).sum(2)).min(1)


def _simplified_run(points, tolerance_m):
    """Return an open line's points kept by Douglas and Peucker's rule, both ends included."""
    if len(points) <= 2:
        return list(points)
    span = points[-1] - points[0]
    length_m = max(float(np.hypot(*span)), 1e-12)
    off_m = np.abs(cross(span, points[1:-1] - points[0])) / length_m
    furthest = int(off_m.argmax()) + 1
    if off_m[furthest - 1] <= tolerance_m:
        return [points[0], points[-1]]
    head = _simplified_run(points[: furthest + 1], tolerance_m)
    return head[:-1] + _simplified_run(points[furthest:], tolerance_m)


def simplified(ring, tolerance_m):
    """Return a ring without the points closer than `tolerance_m` to the line they stray from."""
    far = int(np.hypot(*(ring - ring[0]).T).argmax())
    there = _simplified_run(ring[: far + 1], tolerance_m)
    back = _simplified_run(np.vstack([ring[far:], ring[:1]]), tolerance_m)
    return np.array(there[:-1] + back[:-1])


def _squared_lines(ring):
    """Return each edge's line (a point on it, its unit direction), snapped where it nearly fits.

    An edge within SNAP_DEG of the ring's main direction, or of its perpendicular, turns
    about its middle onto it.
    """
    main_rad = main_direction_rad(ring)
    quarter = math.pi / 2.0
    lines = []
    for start, end in zip(ring, np.roll(ring, -1, axis=0), strict=True):
        angle = math.atan2(end[1] - start[1], end[0] - start[0])
        off = (angle - main_rad + quarter / 2.0) % quarter - quarter / 2.0
        if abs(off) <= math.radians(SNAP_DEG):
            angle -= off
        lines.append(((start + end) / 2.0, np.array([math.cos(angle), math.sin(angle)])))
    return lines


def _corners(ring, lines):
    """Return the ring whose edges lie on `lines`: each corner where two of them meet.

    Two parallel lines meet nowhere: they are joined square through the mapped corner.
    """
    corners = []
    for index, corner in enumerate(ring):
        (point_1, along_1), (point_2, along_2) = lines[index - 1], lines[index]
        denominator = float(cross(along_1, along_2))
        if abs(denominator) > PARALLEL_SIN:
            share = float(cross(point_2 - point_1, along_2)) / denominator
            corners.append(point_1 + share * along_1)
        else:
            corners.append(point_1 + float((corner - point_1) @ along_1) * along_1)
            corners.append(point_2 + float((corner - point_2) @ along_2) * along_2)
    return np.array(corners)


def regularised(ring, tolerance_m):
    """Return a cleaned ring with straight walls and square corners, where the map allows.

    The mapper's jitter along a wall goes, and walls nearly along or across the footprint's
    main direction take it. No wall moves further than `tolerance_m` from where it is mapped:
    a footprint that squaring would move further is only straightened, or kept as it is.
    """
    mapped = cleaned(ring)
    if mapped is None:
        return None
    straight = cleaned(simplified(mapped, min(JITTER_M, tolerance_m)))
    if straight is None:
        return mapped
    squared = cleaned(_corners(straight, _squared_lines(straight)))
    for candidate in (squared, straight):
        if candidate is None or len(candidate) < 3 or not is_simple(candidate):
            continue
        moved_m = max(
            distance_to_ring_m(candidate, mapped).max(), distance_to_ring_m(mapped, candidate).max()
        )
        if moved_m <= tolerance_m:
            return candidate
    return mapped


# ----------------------------------------------------------------------------- triangles
def _sees(points, rings, start, end):
    """Tell whether no edge of the rings (lists of point indices) crosses start to end."""
    for ring in rings:
        for first, second in zip(ring, ring[1:] + ring[:1], strict=True):
            if len({first, second, start, end}) < 4:
                continue
            if _crossing(points[start], points[end], points[first], points[second]) is not None:
                return False
    return True


def _bridged(points, outline, holes):
    """Return one ring of point indices: the outline with each hole joined in by a bridge."""
    outline = list(outline)
    waiting = sorted(holes, key=lambda hole: -max(points[index][0] for index in hole))
    for position, hole in enumerate(waiting):
        rings = [outline] + waiting[position:]
        bridge = None
        for hole_at, hole_point in enumerate(hole):
            for outline_at, outline_point in enumerate(outline):
                length_m = float(np.hypot(*(points[hole_point] - points[outline_point])))
                if (bridge is None or length_m < bridge[0]) and _sees(
                    points, rings, hole_point, outline_point
                ):
                    bridge = (length_m, hole_at, outline_at)
        if bridge is None:
            raise FootprintError("a courtyard no corner of the outline sees")
        _, hole_at, outline_at = bridge
        outline = (
            outline[: outline_at + 1] + hole[hole_at:] + hole[: hole_at + 1] + outline[outline_at:]
        )
    return outline


def _is_ear(points, ring, at):
    before, corner, after = ring[at - 1], ring[at], ring[(at + 1) % len(ring)]
    first, second, third = points[before], points[corner], points[after]
    if cross(second - first, third - first) <= EAR_MIN_DOUBLED_AREA_M2:
        return False
    for other in ring:
        if other in (before, corner, after):
            continue
        point = points[other]
        if any(np.array_equal(point, own) for own in (first, second, third)):
            continue
        if (
            cross(second - first, point - first) >= 0.0
            and cross(third - second, point - second) >= 0.0
            and cross(first - third, point - third) >= 0.0
        ):
            return False
    return True


def ear_clipped(points, ring):
    """Return the triangles (point indices, counter-clockwise) of a counter-clockwise ring.

    `ring` lists indices into `points`; a point may be listed twice, as a bridged courtyard
    does. Points on a straight line stay corners of a triangle.
    """
    ring = list(ring)
    triangles = []
    while len(ring) > 3:
        ear = next((at for at in range(len(ring)) if _is_ear(points, ring, at)), None)
        if ear is None:
            raise FootprintError("a polygon ear clipping cannot cut")
        triangles.append((ring[ear - 1], ring[ear], ring[(ear + 1) % len(ring)]))
        del ring[ear]
    if cross(points[ring[1]] - points[ring[0]], points[ring[2]] - points[ring[0]]) <= 0.0:
        raise FootprintError("a polygon ear clipping cannot cut")
    triangles.append(tuple(ring))
    return triangles


def triangulated(outline, holes=()):
    """Return a footprint's points and triangles: (N, 2) and (M, 3) indices, counter-clockwise.

    `outline` runs counter-clockwise and each of `holes`, a courtyard, clockwise. The points
    are the outline's then each hole's, in order.
    """
    rings, count = [], 0
    for ring in [outline, *holes]:
        rings.append(list(range(count, count + len(ring))))
        count += len(ring)
    points = np.vstack([outline, *holes]).astype(np.float64)
    bridged = _bridged(points, rings[0], rings[1:])
    return points, np.array(ear_clipped(points, bridged), np.int64)
