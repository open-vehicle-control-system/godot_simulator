"""Place traffic signs and signals along surveyed roads, as Belgium does.

Two kinds of evidence: what OpenStreetMap tags (`highway=traffic_signals`, `stop`,
`give_way`, `crossing`, `traffic_sign=*`), and what the data implies under the Belgian
highway code: a speed limit sign where `maxspeed` changes, a stop sign at a stop line the
road builder drew, a give-way sign at every entry of a roundabout, a crossing sign at every
zebra crossing drawn. Each placed sign says which it is. Nothing is placed without either.

Placement follows the arrêté ministériel of 11 October 1976 (Wallonia's consolidated text):
right of the carriageway in the direction of travel, the plate's near side at least 0.5 m
from the carriageway's edge, its lower edge 1 m up on a verge and at least 2.2 m up where
people walk or park; signs at the stop or give-way line itself; a speed limit repeated on
the left of a one-way carriageway only. Positions are metres east and north, as osm.py reads them.
"""

import math
import re
from dataclasses import dataclass, field

import numpy as np
import road_markings
import road_network
import sign_faces

PUBLIC_RANK = road_network.KINDS["residential"].rank
PRIVATE_ACCESS = ("private", "no")
SNAP_M = 8.0  # how far from a surveyed centreline a mapped point may lie
BESIDE_M = 15.0  # how far from a road a sign mapped beside it may stand
PARALLEL = 0.7  # the cosine under which two directions run along each other
CLEARANCE_M = 0.5
LOWER_EDGE_M = 1.0
LOWER_EDGE_WALKED_M = 2.2
SKEW_DEG = 5.0  # a plate is turned this far away from the road, against glare
POST_DIAMETER_M = 0.076
POST_ABOVE_PLATE_M = 0.04
STACK_GAP_M = 0.04
PLATE_OFF_POST_M = 0.01
BACK_OFF_M = 12.0  # how far back along its road a sign may move to find free ground
KEEP_OFF_M = 0.3
SAME_SIGN_M = 12.0  # two signs of a role this close, for the same traffic, are one
AGREE_M = 10.0  # how far from its sign a marking may be and still be the sign's
LANE_FROM_CENTRE_M = 1.0
LANE_TO_EDGE_M = 1.5
JUNCTION_AHEAD_M = 15.0
ROUNDABOUT_ENTRY_M = 1.5  # a roundabout's give-way line, before its ring's edge
SPEED_SIGN_PAST_M = 5.0  # a limit's sign stands this far into its stretch
MIN_LIMIT_LENGTH_M = 30.0
BUILT_UP_KM_H = 50
CROSSING_LENGTH_M = 4.0
STOP_LINE_LENGTH_M = 0.5
EDGE_LINE_INSET_M = 0.3
SIGNAL_POLE_DIAMETER_M = 0.114
SIGNAL_LENS_DIAMETER_M = 0.2
SIGNAL_LOWER_EDGE_M = 2.3
SIGNAL_HEAD_HEIGHT_M = 0.9
SIGNAL_HEAD_HALF_WIDTH_M = 0.25
SIGNAL_HEAD_DEPTH_M = 0.2
SIGNAL_SETBACK_M = 2.0  # a signal's stop line, before the road it guards
SIGNAL_CYCLE_S = (18.0, 3.0, 23.0)  # green, amber, red
SIGNALLED_CROSSINGS = ("traffic_signals",)
MARKED_CROSSINGS = ("zebra", "marked", "uncontrolled", "yes", "surface", "lines")
FOOTWAY_SIDES = ("both", "left", "right", "yes", "separate")
NAMED_SIGNS = {"stop": "BE:B5", "give_way": "BE:B1"}
COMPASS = ("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE")
COMPASS += ("S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
TAGGED, DERIVED = "tagged", "derived"
PRIORITY, CROSSING, SPEED, SIGNAL, OTHER = "priority", "crossing", "speed", "signal", "other"
RIGHT, LEFT = 1, -1


@dataclass
class Wanted:
    """A sign the data asks for: its faces, top to bottom, and the traffic it governs."""

    faces: tuple  # sign codes; empty for a signal
    point: np.ndarray  # where on the road
    travel: np.ndarray  # the unit direction of the traffic it governs
    source: str  # TAGGED or DERIVED
    role: str
    sides: tuple = (RIGHT,)
    phase: float = 0.0  # a signal's place in its junction's cycle, 0 to 1
    to_junction_m: float = 0.0  # a junction's signal: how far ahead of `point` its node is


@dataclass
class Site:
    """What a builder knows of the ground signs stand on."""

    blocked: object  # (x, y) -> True where nothing may stand: a lap, a building
    walked: object  # (x, y) -> True where the ground beside the road is paved


@dataclass
class Placement:
    """The signs of an area and what could not be placed.

    Posts, plates and signals are as a pack's tiles list them, but for their place: `at` (east,
    north) and `above_m`, the height above the ground at the post's foot.
    """

    posts: list = field(default_factory=list)
    plates: list = field(default_factory=list)
    signals: list = field(default_factory=list)
    unplaced: list = field(default_factory=list)  # (reason, what)

    def faces(self):
        """Return the ids of the faces placed, sorted."""
        return sorted({plate["face"] for plate in self.plates})

    def counts(self):
        """Return how many plates and signals each source placed: {source: {code: count}}."""
        found = {TAGGED: {}, DERIVED: {}}
        for plate in self.plates:
            by_code = found[plate["source"]]
            by_code[plate["face"]] = by_code.get(plate["face"], 0) + 1
        for signal in self.signals:
            by_code = found[signal["source"]]
            by_code["signal"] = by_code.get("signal", 0) + 1
        return found


def is_public(tags):
    """Tell whether a highway's tags are a public road's: a street, not a service road."""
    kind = road_network.KINDS.get(tags.get("highway"))
    return (
        kind is not None and kind.rank >= PUBLIC_RANK and tags.get("access") not in PRIVATE_ACCESS
    )


def headings(tags):
    """Return the ways traffic runs along a way: 1 with its nodes' order, -1 against."""
    if tags.get("oneway") == "-1":
        return (-1,)
    if tags.get("oneway") in ("yes", "1", "true") or tags.get("junction") == "roundabout":
        return (1,)
    return (1, -1)


def speed_limit(tags):
    """Return a way's `maxspeed` in km/h, or None when it is not a plain number."""
    limit = tags.get("maxspeed", "")
    return int(limit) if limit.isdigit() else None


def _unit(vector):
    return np.asarray(vector, np.float64) / max(float(np.hypot(*vector)), 1e-9)


def _drivable(extract):
    return [way for way in extract.ways if way.tags.get("highway") in road_network.KINDS]


def _direction_at(way, place):
    """Return the unit direction of a way at its node `place`, along its nodes' order."""
    before, after = max(place - 1, 0), min(place + 1, len(way.points) - 1)
    return _unit(way.points[after] - way.points[before])


def _point_along(way, from_end, distance_m):
    """Return the point `distance_m` into a way from an end, and the direction onward there.

    `from_end` is 0 for the way's first node, -1 for its last.
    """
    points = way.points if from_end == 0 else way.points[::-1]
    steps = np.hypot(*np.diff(points, axis=0).T)
    travelled = np.concatenate([[0.0], np.cumsum(steps)])
    distance_m = min(distance_m, travelled[-1] / 2.0)
    segment = min(int(np.searchsorted(travelled, distance_m, side="right")) - 1, len(steps) - 1)
    onward = _unit(points[segment + 1] - points[segment])
    return points[segment] + onward * (distance_m - travelled[segment]), onward


def _arrives_at(way, node):
    """Tell whether traffic on a way can reach its node `node`."""
    allowed = headings(way.tags)
    place = way.nodes.index(node)
    return (1 in allowed and place > 0) or (-1 in allowed and place < len(way.nodes) - 1)


def sign_codes(tags):
    """Return the sign codes a node's `traffic_sign` names, with the region's prefix."""
    codes = []
    for named in re.split(r"[;,]", tags.get("traffic_sign", "")):
        named = named.strip()
        if named == "maxspeed" and speed_limit(tags) is not None:
            codes.append(f"BE:C43[{speed_limit(tags)}]")
        elif named in NAMED_SIGNS:
            codes.append(NAMED_SIGNS[named])
        elif named:
            codes.append(named if ":" in named else f"BE:{named}")
    return codes


def _compass_travel(direction):
    """Return the travel a sign facing compass `direction` governs, or None if it is none."""
    if direction in COMPASS:
        bearing_deg = 22.5 * COMPASS.index(direction)
    elif direction.replace(".", "", 1).isdigit():
        bearing_deg = float(direction)
    else:
        return None
    bearing = math.radians(bearing_deg)
    return -np.array([math.sin(bearing), math.cos(bearing)])


def _tagged_travels(node, way, place):
    """Return the travel directions a node's sign governs on a way it is on.

    `direction` (or `traffic_signals:direction`) says it; without it a one-way has one
    answer, and a stop or give-way governs the traffic heading for the way's nearer end.
    """
    forward = _direction_at(way, place)
    told = node.tags.get("direction") or node.tags.get("traffic_signals:direction")
    if told == "forward":
        return [forward]
    if told == "backward":
        return [-forward]
    allowed = headings(way.tags)
    if told == "both" or node.tags.get("highway") not in ("stop", "give_way"):
        return [heading * forward for heading in allowed]
    if len(allowed) == 1:
        return [allowed[0] * forward]
    return [forward if place >= len(way.nodes) / 2.0 else -forward]


def tagged_signs(extract):
    """Return the Wanted signs and signals the extract's nodes tag."""
    ways = _drivable(extract)
    wanted = []
    for node in extract.nodes:
        highway = node.tags.get("highway")
        codes = [code for code in sign_codes(node.tags) if sign_faces.is_drawn(code)]
        crossing = highway == "crossing" or "crossing" in node.tags
        signalled = highway == "traffic_signals" or (
            crossing
            and (
                node.tags.get("crossing") in SIGNALLED_CROSSINGS
                or node.tags.get("crossing:signals") == "yes"
            )
        )
        if highway in NAMED_SIGNS:
            faces, role = (NAMED_SIGNS[highway],), PRIORITY
        elif signalled:
            faces, role = (), SIGNAL
        elif crossing and (
            node.tags.get("crossing:markings", "no") != "no"
            or node.tags.get("crossing") in MARKED_CROSSINGS
        ):
            faces, role = ("BE:F49",), CROSSING
        elif codes:
            faces, role = tuple(codes), OTHER
        else:
            continue
        on = [
            (way, way.nodes.index(node.identifier)) for way in ways if node.identifier in way.nodes
        ]
        if not on:
            # Beside its road when it is a mapped sign; else on a way no road is drawn for.
            wanted.append(Wanted(faces, node.point, None, TAGGED, role))
        elif role == SIGNAL and len(on) > 1:
            wanted += _junction_signals(node, on)
        else:
            way, place = on[0]
            for travel in _tagged_travels(node, way, place):
                wanted.append(Wanted(faces, node.point, travel, TAGGED, role))
    return wanted + _sided_signs(extract, ways)


def _sided_signs(extract, ways):
    """Return the Wanted signs of `traffic_sign:forward` and `traffic_sign:backward`."""
    wanted = []
    for node in extract.nodes:
        way = next((way for way in ways if node.identifier in way.nodes), None)
        for key, heading in (("traffic_sign:forward", 1), ("traffic_sign:backward", -1)):
            codes = [
                code
                for code in sign_codes({"traffic_sign": node.tags.get(key, "")})
                if sign_faces.is_drawn(code)
            ]
            if codes and way is not None:
                travel = heading * _direction_at(way, way.nodes.index(node.identifier))
                wanted.append(Wanted(tuple(codes), node.point, travel, TAGGED, OTHER))
    return wanted


def undrawn_signs(extract):
    """Return the sign codes the extract's nodes tag that no face is drawn for, sorted."""
    keys = ("traffic_sign", "traffic_sign:forward", "traffic_sign:backward")
    return sorted(
        {
            code
            for node in extract.nodes
            for key in keys
            for code in sign_codes({**node.tags, "traffic_sign": node.tags.get(key, "")})
            if not sign_faces.is_drawn(code)
        }
    )


def _junction_signals(node, on):
    """Return a signal for every way traffic reaches a signalled junction node by.

    The approaches along the first one's axis share a phase; the others take the other
    half of the cycle.
    """
    wanted = []
    for way, place in on:
        forward = _direction_at(way, place)
        for heading in headings(way.tags):
            arrives = place > 0 if heading == 1 else place < len(way.nodes) - 1
            if not arrives:
                continue
            travel = heading * forward
            along_first = wanted and abs(float(travel @ wanted[0].travel)) >= PARALLEL
            phase = 0.0 if not wanted or along_first else 0.5
            point, _ = _point_along(way, 0 if place == 0 else -1, SNAP_M)
            if 0 < place < len(way.nodes) - 1:
                point = node.point - travel * SNAP_M
            before_m = float(np.hypot(*(node.point - point)))
            wanted.append(
                Wanted((), point, travel, TAGGED, SIGNAL, phase=phase, to_junction_m=before_m)
            )
    return wanted


def speed_limit_signs(extract):
    """Return the Wanted speed limit signs where `maxspeed` changes between ways.

    A way's limit is signed where traffic enters it from ways that all have another
    limit: on the right, a little into the way, and on the left too of a one-way. A way
    without a plain `maxspeed` implies nothing, and a roundabout's ring carries no limit
    sign.
    """
    ways = _drivable(extract)
    at_node = {}
    for way in ways:
        for node in set(way.nodes):
            at_node.setdefault(node, []).append(way)
    wanted = []
    for way in ways:
        limit = speed_limit(way.tags)
        length_m = float(np.hypot(*np.diff(way.points, axis=0).T).sum())
        ring = way.tags.get("junction") == "roundabout"
        if limit is None or ring or length_m < MIN_LIMIT_LENGTH_M or not is_public(way.tags):
            continue
        for end, heading in ((0, 1), (-1, -1)):
            others = [other for other in at_node[way.nodes[end]] if other is not way]
            if heading not in headings(way.tags) or not others:
                continue
            others = [other for other in others if _arrives_at(other, way.nodes[end])]
            limits = [speed_limit(other.tags) for other in others]
            if not others or None in limits or limit in limits:
                continue
            point, travel = _point_along(way, end, SPEED_SIGN_PAST_M)
            one_way = len(headings(way.tags)) == 1
            sides = (RIGHT, LEFT) if one_way else (RIGHT,)
            wanted.append(Wanted((f"BE:C43[{limit}]",), point, travel, DERIVED, SPEED, sides))
    return wanted


def roundabout_signs(extract):
    """Return the Wanted give-way signs of roundabouts: one at every public way in.

    The Belgian code requires a B1 (give way) with the D5 (roundabout) at each entry.
    """
    ways = _drivable(extract)
    rings = [way for way in ways if way.tags.get("junction") == "roundabout"]
    ring_nodes = {node: way for way in rings for node in way.nodes}
    wanted = []
    for way in ways:
        if way.tags.get("junction") == "roundabout" or not is_public(way.tags):
            continue
        for end, heading in ((0, -1), (-1, 1)):
            ring = ring_nodes.get(way.nodes[end])
            if ring is None or heading not in headings(way.tags):
                continue
            before_m = road_network.KINDS[ring.tags["highway"]].half_width_m + ROUNDABOUT_ENTRY_M
            point, into_way = _point_along(way, end, before_m)
            wanted.append(Wanted(("BE:B1", "BE:D5"), point, -into_way, DERIVED, PRIORITY))
    return wanted


def _travels(road):
    return headings(road.tags)


def _spot(road, along_m):
    """Return a surveyed road's point and unit tangent at `along_m`."""
    sections = road.sections
    values = [np.interp(along_m, sections["s"], sections[key]) for key in ("x", "y", "tx", "ty")]
    return np.array(values[:2]), _unit(values[2:])


def _governed_heading(road, mark):
    """Return the heading of the traffic a stop line across a lane governs, or None.

    Belgium drives on the right: a line over the right half of the road, from its centre
    to its edge, stops the traffic along the road; over the left half, the traffic
    against it. A bar that is neither is not a lane's stop line.
    """
    half_width_m = float(np.interp(mark.from_m, road.sections["s"], road.half_width_m))
    one_way = _travels(road)
    if len(one_way) == 1:
        spans = mark.right_m - mark.left_m >= half_width_m
        return one_way[0] if spans else None
    for heading in (1, -1):
        inner, outer = (
            (mark.left_m, mark.right_m) if heading == 1 else (-mark.right_m, -mark.left_m)
        )
        if inner <= LANE_FROM_CENTRE_M and inner >= -LANE_FROM_CENTRE_M:
            if outer >= half_width_m - LANE_TO_EDGE_M:
                return heading
    return None


def _meets_a_road(surveyed, index, along_m, heading):
    """Tell whether a road of at least its rank crosses a road's course ahead of `along_m`."""
    road = surveyed[index]
    ahead_m = along_m + heading * np.arange(0.0, JUNCTION_AHEAD_M + 0.5, 1.0)
    length_m = road.sections["s"][-1]
    ahead_m = ahead_m[(ahead_m >= 0.0) & (ahead_m <= length_m)]
    points, tangents = zip(*[_spot(road, at) for at in ahead_m], strict=True)
    points, tangents = np.array(points), np.array(tangents)
    for other_index, other in enumerate(surveyed):
        if other_index == index or other.kind.rank < road.kind.rank:
            continue
        distance = np.hypot(
            points[:, 0, None] - other.sections["x"][None, :],
            points[:, 1, None] - other.sections["y"][None, :],
        )
        ours, theirs = np.unravel_index(distance.argmin(), distance.shape)
        if distance[ours, theirs] > other.half_width_m[theirs]:
            continue
        other_tangent = np.array([other.sections["tx"][theirs], other.sections["ty"][theirs]])
        if abs(float(tangents[ours] @ other_tangent)) < PARALLEL:
            return True
    return False


def marking_signs(surveyed):
    """Return the Wanted signs the markings drawn on public roads imply.

    A stop sign for the traffic a lane's stop line stops before a road of at least its
    rank; a crossing sign for each way traffic reaches a zebra crossing.
    """
    wanted = []
    for index, road in enumerate(surveyed):
        if not is_public(road.tags):
            continue
        for mark in road.transverse:
            if mark.kind != road_markings.STOP_LINE:
                continue
            heading = _governed_heading(road, mark)
            if heading is None or not _meets_a_road(surveyed, index, mark.from_m, heading):
                continue
            point, tangent = _spot(road, mark.from_m)
            wanted.append(Wanted(("BE:B5",), point, heading * tangent, DERIVED, PRIORITY))
        for from_m, to_m in crossings(road):
            for heading in _travels(road):
                point, tangent = _spot(road, from_m if heading == 1 else to_m)
                wanted.append(Wanted(("BE:F49",), point, heading * tangent, DERIVED, CROSSING))
    return wanted


def crossings(road):
    """Return where a road's zebra crossings are, as (from, to) along it.

    Stripes drawn less than SAME_SIGN_M apart are one crossing.
    """
    spans = []
    for mark in sorted(road.transverse, key=lambda mark: mark.from_m):
        if mark.kind != road_markings.CROSSING:
            continue
        if spans and mark.from_m - spans[-1][1] < SAME_SIGN_M:
            spans[-1][1] = max(spans[-1][1], mark.to_m)
        else:
            spans.append([mark.from_m, mark.to_m])
    return [tuple(span) for span in spans]


def without_repeats(wanted):
    """Return the Wanted signs with one per role, place and traffic: the tagged one first."""
    kept = []
    for sign in sorted(wanted, key=lambda sign: sign.source != TAGGED):
        repeated = any(
            other.role == sign.role
            and sign.role != OTHER
            and sign.travel is not None
            and other.travel is not None
            and float(np.hypot(*(other.point - sign.point))) <= SAME_SIGN_M
            and float(other.travel @ sign.travel) >= PARALLEL
            for other in kept
        )
        if not repeated:
            kept.append(sign)
    return kept


def locate(surveyed, point, travel):
    """Return the surveyed road a mapped point is on: (index, distance along, heading).

    The road runs along `travel`; None when no such road is within SNAP_M. Without `travel`
    the sign is mapped beside its road, within BESIDE_M: it governs the traffic it stands to
    the right of.
    """
    reach_m = SNAP_M if travel is not None else BESIDE_M
    found = None
    for index, road in enumerate(surveyed):
        sections = road.sections
        distance = np.hypot(sections["x"] - point[0], sections["y"] - point[1])
        place = int(distance.argmin())
        if distance[place] > reach_m or (found and distance[place] >= found[0]):
            continue
        tangent = np.array([sections["tx"][place], sections["ty"][place]])
        if travel is None:
            offset = point - np.array([sections["x"][place], sections["y"][place]])
            right_of_tangent = offset[0] * tangent[1] - offset[1] * tangent[0]
            heading = 1 if right_of_tangent >= 0.0 else -1
        else:
            along = float(tangent @ travel)
            if abs(along) < PARALLEL:
                continue
            heading = 1 if along > 0.0 else -1
        if heading in _travels(road) or travel is not None:
            found = (distance[place], index, float(sections["s"][place]), heading)
    return found[1:] if found else None


def _clear(surveyed, index, position, reach_m, site):
    """Tell whether a post may stand at `position`: off every other road, and not blocked."""
    if site.blocked(position[0], position[1]):
        return False
    for other_index, other in enumerate(surveyed):
        if other_index == index:
            continue
        distance = np.hypot(other.sections["x"] - position[0], other.sections["y"] - position[1])
        if (distance < other.half_width_m + reach_m).any():
            return False
    return True


def is_built_up(tags):
    """Tell whether a road's tags are those of a built-up area's street."""
    limit = speed_limit(tags)
    urban = "urban" in tags.get("maxspeed:type", "") + tags.get("zone:traffic", "")
    return urban or (limit is not None and limit <= BUILT_UP_KM_H)


def _is_walked(road, position, outward, site):
    """Tell whether people walk where a post stands: a built-up street, or paved ground."""
    paved = site.walked(*position) and site.walked(*(position + outward))
    return is_built_up(road.tags) or road.tags.get("sidewalk") in FOOTWAY_SIDES or paved


def _beside(surveyed, index, along_m, heading, side, half_width_m, site):
    """Return where a post stands beside a road, or None without free ground in BACK_OFF_M.

    With the position come the travel direction there and the unit vector away from the
    road. The post is `half_width_m` (of what it carries) and CLEARANCE_M clear of the edge,
    `side` of the traffic along `heading`, moved back against the traffic until it is
    off every other road.
    """
    road = surveyed[index]
    length_m = road.sections["s"][-1]
    for back_m in np.arange(0.0, BACK_OFF_M + 0.5, 1.0):
        at_m = along_m - heading * back_m
        if not 0.0 <= at_m <= length_m:
            break
        centre, tangent = _spot(road, at_m)
        outward = side * heading * np.array([tangent[1], -tangent[0]])
        edge_m = float(np.interp(at_m, road.sections["s"], road.half_width_m))
        position = centre + outward * (edge_m + CLEARANCE_M + half_width_m)
        if _clear(surveyed, index, position, KEEP_OFF_M + half_width_m, site):
            return position, heading * tangent, outward
    return None


def _yaw_deg(travel, side):
    """Return the pack yaw a plate faces: against the traffic, turned SKEW_DEG off the road.

    The pack's x is south and its y east: a map direction at `angle` from east is at
    `angle + 90` degrees from x.
    """
    facing_deg = math.degrees(math.atan2(travel[1], travel[0])) + 180.0 + side * SKEW_DEG
    return round((facing_deg + 90.0 + 180.0) % 360.0 - 180.0, 1)


def _lane(road, along_m, heading):
    """Return the laterals (left, right) of the lane the traffic along `heading` uses."""
    half_width_m = float(np.interp(along_m, road.sections["s"], road.half_width_m))
    edge_m = half_width_m - EDGE_LINE_INSET_M
    if len(_travels(road)) == 1:
        return -edge_m, edge_m
    return (0.0, edge_m) if heading == 1 else (-edge_m, 0.0)


def _same_lane(road, mark, heading):
    return mark.kind in road_markings.BARS and _governed_heading(road, mark) == heading


def agree_markings(surveyed, index, along_m, heading, sign):
    """Make a road's markings agree with a sign placed on it; return where the sign belongs.

    A stop sign or a signal stands at its stop line: the one drawn within AGREE_M, else one
    is added across its lane. A give-way sign turns a stop line drawn there into a give-way
    line. A crossing sign stands at its crossing: the one drawn, else one is added.
    """
    road = surveyed[index]
    near = [mark for mark in road.transverse if abs(mark.from_m - along_m) <= AGREE_M]
    if sign.role == CROSSING:
        drawn = [mark for mark in near if mark.kind == road_markings.CROSSING]
        if not drawn and sign.source == TAGGED:
            half_width_m = float(np.interp(along_m, road.sections["s"], road.half_width_m))
            start_m = max(along_m - CROSSING_LENGTH_M / 2.0, 0.0)
            road.transverse.append(
                road_markings.Transverse(
                    road_markings.CROSSING,
                    start_m,
                    start_m + CROSSING_LENGTH_M,
                    -half_width_m,
                    half_width_m,
                )
            )
        spans = [
            span for span in crossings(road) if span[0] - AGREE_M <= along_m <= span[1] + AGREE_M
        ]
        return (spans[0][0] if heading == 1 else spans[0][1]) if spans else along_m
    lines = [mark for mark in near if _same_lane(road, mark, heading)]
    line = min(lines, key=lambda mark: abs(mark.from_m - along_m)) if lines else None
    if sign.faces[:1] == ("BE:B1",):
        if line is not None:
            line.kind = (
                road_markings.GIVE_WAY_LINE if heading == 1 else road_markings.GIVE_WAY_LINE_AGAINST
            )
            return line.from_m
        return along_m
    if sign.role == SIGNAL or sign.faces[:1] == ("BE:B5",):
        if line is None:
            line = road_markings.Transverse(
                road_markings.STOP_LINE,
                along_m,
                along_m + STOP_LINE_LENGTH_M,
                *_lane(road, along_m, heading),
            )
            road.transverse.append(line)
        line.kind = road_markings.STOP_LINE
        return line.from_m
    return along_m


def _junction_mouth_m(surveyed, index, point):
    """Return how far from a junction's node the roads that meet a road there reach."""
    reach_m = 0.0
    for other_index, other in enumerate(surveyed):
        if other_index == index:
            continue
        distance = np.hypot(other.sections["x"] - point[0], other.sections["y"] - point[1])
        place = int(distance.argmin())
        if distance[place] <= SNAP_M:
            reach_m = max(reach_m, float(other.half_width_m[place]))
    return reach_m


def place(extract, surveyed, site):
    """Return the Placement of an area's signs and signals on its surveyed roads.

    Markings of the roads in `surveyed` are made to agree with the signs: call this before
    the roads' lines are written.
    """
    wanted = without_repeats(
        tagged_signs(extract)
        + speed_limit_signs(extract)
        + roundabout_signs(extract)
        + marking_signs(surveyed)
    )
    placement = Placement()
    for code in undrawn_signs(extract):
        placement.unplaced.append(("no face is drawn for it", code))
    for sign in wanted:
        what = f"{sign.source} {'+'.join(sign.faces) or 'signal'} at {sign.point.round(1)}"
        if sign.travel is None and sign.role != OTHER:
            placement.unplaced.append(("on no mapped road", what))
            continue
        found = locate(surveyed, sign.point, sign.travel)
        if found is None:
            placement.unplaced.append(("off the surveyed roads", what))
            continue
        index, along_m, heading = found
        road = surveyed[index]
        if sign.to_junction_m:
            _, tangent = _spot(road, along_m)
            node = sign.point + heading * tangent * sign.to_junction_m
            back_m = _junction_mouth_m(surveyed, index, node) + SIGNAL_SETBACK_M
            along_m += heading * (sign.to_junction_m - back_m)
            along_m = float(np.clip(along_m, 0.0, road.sections["s"][-1]))
        along_m = agree_markings(surveyed, index, along_m, heading, sign)
        for side in sign.sides:
            if sign.role == SIGNAL:
                stood = _stand_signal(surveyed, index, along_m, heading, side, sign, site)
            else:
                stood = _stand_sign(surveyed, index, along_m, heading, side, sign, site)
            if stood is None:
                placement.unplaced.append(("no free ground beside the road", what))
                continue
            post, plates, signals = stood
            placement.posts.append(post)
            placement.plates += plates
            placement.signals += signals
    return placement


def _stand_sign(surveyed, index, along_m, heading, side, sign, site):
    built_up = is_built_up(surveyed[index].tags)
    identifiers = [sign_faces.face_id(code, built_up) for code in sign.faces]
    faces = [sign_faces.outline(identifier) for identifier in identifiers]
    half_width_m = max(float(outline[:, 0].max()) for outline in faces)
    stood = _beside(surveyed, index, along_m, heading, side, half_width_m, site)
    if stood is None:
        return None
    position, travel, outward = stood
    walked = _is_walked(surveyed[index], position, outward, site)
    lower_edge_m = LOWER_EDGE_WALKED_M if walked else LOWER_EDGE_M
    yaw_deg = _yaw_deg(travel, side)
    plates = []
    for identifier, outline in list(zip(identifiers, faces, strict=True))[::-1]:
        centre_m = lower_edge_m - float(outline[:, 1].min())
        plates.append(
            {
                "face": identifier,
                "at": position - travel * (POST_DIAMETER_M / 2.0 + PLATE_OFF_POST_M),
                "foot": position,
                "above_m": centre_m,
                "yaw_deg": yaw_deg,
                "source": sign.source,
            }
        )
        lower_edge_m = centre_m + float(outline[:, 1].max()) + STACK_GAP_M
    post = {
        "at": position,
        "foot": position,
        "above_m": 0.0,
        "height_m": round(lower_edge_m - STACK_GAP_M + POST_ABOVE_PLATE_M, 2),
        "diameter_m": POST_DIAMETER_M,
    }
    return post, plates[::-1], []


def _stand_signal(surveyed, index, along_m, heading, side, sign, site):
    stood = _beside(surveyed, index, along_m, heading, side, SIGNAL_HEAD_HALF_WIDTH_M, site)
    if stood is None:
        return None
    position, travel, _ = stood
    signal = {
        "at": position - travel * (SIGNAL_POLE_DIAMETER_M / 2.0 + SIGNAL_HEAD_DEPTH_M / 2.0),
        "foot": position,
        "above_m": SIGNAL_LOWER_EDGE_M + SIGNAL_HEAD_HEIGHT_M / 2.0,
        "yaw_deg": _yaw_deg(travel, 0),
        "phase": sign.phase,
        "source": sign.source,
    }
    post = {
        "at": position,
        "foot": position,
        "above_m": 0.0,
        "height_m": round(SIGNAL_LOWER_EDGE_M + SIGNAL_HEAD_HEIGHT_M, 2),
        "diameter_m": SIGNAL_POLE_DIAMETER_M,
    }
    return post, [], [signal]


def described(placement, height_m):
    """Return a Placement as a pack's tiles list it, in the pack's frame (x south, y east).

    `height_m(x, y)` is the ground's height: everything on a post stands on the ground at
    the post's foot.
    """

    def in_pack(placed):
        ground_m = float(height_m(placed["foot"][0], placed["foot"][1]))
        position = [-placed["at"][1], placed["at"][0], ground_m + placed["above_m"]]
        kept = {key: value for key, value in placed.items() if key not in ("at", "foot", "above_m")}
        return {"position_m": [round(float(value), 2) for value in position]} | kept

    return {
        kind: [in_pack(placed) for placed in getattr(placement, kind)]
        for kind in ("posts", "plates", "signals")
    }


def manifest(placement, faces_directory):
    """Return a pack's `signs`: the placed signs' faces and the signal head."""
    return {
        "faces": [
            {
                "id": identifier,
                "image": f"{faces_directory}/{sign_faces.file_name(identifier)}",
                "outline_m": [
                    [round(float(x), 4), round(float(y), 4)]
                    for x, y in sign_faces.outline(identifier)
                ],
            }
            for identifier in placement.faces()
        ],
        "signal": {
            "lens_diameter_m": SIGNAL_LENS_DIAMETER_M,
            "cycle_s": list(SIGNAL_CYCLE_S),
        },
    }
