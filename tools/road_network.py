"""Turn OpenStreetMap highway ways into the roads around a circuit: chains and centrelines.

A road is a chain of ways of one kind, joined end to end where no other road meets them, so
its fitted width and its dashes run on across the ways' ends. Positions are metres east and
north, as osm.py reads them.
"""

from dataclasses import dataclass

import numpy as np

SECTION_SPACING_M = 1.0
CENTRELINE_SMOOTHING_M = 3.0
MIN_ROAD_LENGTH_M = 12.0
JUNCTION_LEAVING_M = 6.0  # how far along a joining road its direction is read


@dataclass(frozen=True)
class Kind:
    """What a `highway` value stands for: its usual size and surface, before the photo."""

    rank: int  # the road of higher rank runs through a junction
    half_width_m: float
    paved: bool


KINDS = {
    "primary": Kind(6, 3.5, True),
    "secondary": Kind(5, 3.25, True),
    "tertiary": Kind(4, 3.0, True),
    "unclassified": Kind(3, 2.75, True),
    "residential": Kind(2, 2.75, True),
    "service": Kind(1, 2.0, True),
    "track": Kind(0, 1.5, False),
}
# Ways the ground does not carry, or that belong to something else.
SKIPPED_TAGS = (
    ("tunnel", None),
    ("bridge", None),
    ("covered", None),
    ("area", "yes"),
    ("service", "parking_aisle"),
    ("service", "driveway"),
)


@dataclass
class Road:
    """A chain of ways: its kind, tags, node ids and their positions (N x 2)."""

    highway: str
    tags: dict
    nodes: list
    points: np.ndarray

    @property
    def kind(self):
        """Return what the road's `highway` stands for."""
        return KINDS[self.highway]


def _skipped(tags):
    return any(
        key in tags and tags[key] != "no" and (wanted is None or tags[key] == wanted)
        for key, wanted in SKIPPED_TAGS
    )


def chain(ways):
    """Return the roads the highway `ways` form, joined where exactly two of a kind meet."""
    roads = [
        Road(way.tags["highway"], way.tags, list(way.nodes), way.points.copy())
        for way in ways
        if way.tags.get("highway") in KINDS and not _skipped(way.tags)
    ]
    uses = {}
    for road in roads:
        for node in set(road.nodes):
            uses[node] = uses.get(node, 0) + 1
    joined = True
    while joined:
        joined = False
        for road in roads:
            if road.nodes[0] == road.nodes[-1]:
                continue
            for other in roads:
                if other is road or other.highway != road.highway:
                    continue
                if other.nodes[0] == other.nodes[-1] or uses[road.nodes[-1]] != 2:
                    continue
                if road.nodes[-1] == other.nodes[-1]:
                    other.nodes.reverse()
                    other.points = other.points[::-1]
                if road.nodes[-1] != other.nodes[0]:
                    continue
                road.nodes += other.nodes[1:]
                road.points = np.concatenate([road.points, other.points[1:]])
                roads.remove(other)
                joined = True
                break
            if joined:
                break
    return roads


def open_smooth(values, sigma_samples):
    """Return an open run of values, Gaussian-smoothed, its ends held."""
    reach = max(1, int(3 * sigma_samples))
    kernel = np.exp(-0.5 * (np.arange(-reach, reach + 1) / sigma_samples) ** 2)
    return np.convolve(np.pad(values, reach, mode="edge"), kernel / kernel.sum(), mode="valid")


def smooth_course(values, sigma_samples):
    """Return an open run of positions, Gaussian-smoothed, carrying straight on past its ends."""
    reach = min(max(1, int(3 * sigma_samples)), len(values) - 1)
    kernel = np.exp(-0.5 * (np.arange(-reach, reach + 1) / sigma_samples) ** 2)
    padded = np.pad(values, reach, mode="reflect", reflect_type="odd")
    return np.convolve(padded, kernel / kernel.sum(), mode="valid")


def sections_along(points):
    """Return a polyline as sections: `s`, `x`, `y` and the unit tangent `tx`, `ty` of each."""
    x, y = points[:, 0], points[:, 1]
    steps = np.hypot(np.diff(x), np.diff(y))
    s = np.concatenate([[0.0], np.cumsum(steps)])
    tangent_x, tangent_y = np.gradient(x, s), np.gradient(y, s)
    length = np.maximum(np.hypot(tangent_x, tangent_y), 1e-9)
    return {"s": s, "x": x, "y": y, "tx": tangent_x / length, "ty": tangent_y / length}


def centreline(points):
    """Return a road's sections every SECTION_SPACING_M along its smoothed polyline.

    A mapper's polyline turns at its nodes; a road does not.
    """
    steps = np.hypot(*np.diff(points, axis=0).T)
    keep = np.concatenate([[True], steps > 1e-6])
    points = points[keep]
    distance = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(points, axis=0).T))])
    count = max(2, round(distance[-1] / SECTION_SPACING_M) + 1)
    at = np.linspace(0.0, distance[-1], count)
    sigma = CENTRELINE_SMOOTHING_M / SECTION_SPACING_M
    smooth = np.stack(
        [smooth_course(np.interp(at, distance, points[:, axis]), sigma) for axis in range(2)], 1
    )
    return sections_along(smooth)


def junctions(roads):
    """Return where roads meet: (road, node position in the road, joining road, side).

    For each node two roads share, the road through it gets an entry per direction the other
    leaves in: `side` is -1 when it leaves to the left, 1 to the right. A road that ends on
    the node is not through it.
    """
    at_node = {}
    for index, road in enumerate(roads):
        for place, node in enumerate(road.nodes):
            at_node.setdefault(node, []).append((index, place))
    met = []
    for uses in at_node.values():
        for index, place in uses:
            road = roads[index]
            if place in (0, len(road.nodes) - 1):
                continue
            ahead = road.points[place + 1] - road.points[place - 1]
            for other_index, other_place in uses:
                if other_index == index:
                    continue
                other = roads[other_index]
                for leaving in _leaving_directions(other.points, other_place):
                    side = -1 if ahead[0] * leaving[1] - ahead[1] * leaving[0] > 0 else 1
                    met.append((index, place, other_index, side))
    return met


def _leaving_directions(points, place):
    """Return the directions a polyline leaves its point `place` in, JUNCTION_LEAVING_M on."""
    directions = []
    for step in (-1, 1):
        at = place
        while 0 <= at + step < len(points):
            at += step
            if np.hypot(*(points[at] - points[place])) >= JUNCTION_LEAVING_M:
                break
        if at != place:
            directions.append(points[at] - points[place])
    return directions
