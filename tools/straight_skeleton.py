"""The straight skeleton of a footprint: the roof whose every face rises from one wall.

Each edge of the polygon moves inwards at one speed; where the moving edges meet they leave
the skeleton's arcs, as the hips, valleys and ridges of a hipped roof do. The wavefront is
followed event by event (Felkel and Obdrzalek): an edge shrinking to nothing, or a reflex
corner splitting the edge it runs into. A node's time is its distance from the edges of the
faces it lies on, which is its height on a roof of unit slope.

A result is checked before it is returned: each face is a simple polygon, a plane rising
from its edge, and the faces cover the footprint. A footprint this module gets wrong raises
SkeletonError, so its caller roofs it another way.

Needs numpy.
"""

import heapq
import math
from dataclasses import dataclass

import footprints
import numpy as np

SAME_POINT_M = 1e-6
SAME_TIME = 1e-9
FACE_PLANE_M = 1e-5
OPPOSED = 1e-9  # 1 + the cosine between two edge normals, under which the edges face each other


class SkeletonError(ValueError):
    """A footprint whose skeleton came out wrong."""


@dataclass
class Skeleton:
    """A footprint's roof of unit slope.

    `points` (N, 2) and `times` (N,) are its nodes, the rings' points first, in order;
    `faces` lists, per edge of the rings in that order, the nodes around its face,
    counter-clockwise from the edge's start and end.
    """

    points: np.ndarray
    times: np.ndarray
    faces: list


@dataclass(eq=False)
class _Edge:
    start: np.ndarray
    along: np.ndarray
    inward: np.ndarray


@dataclass(eq=False)
class _Vertex:
    """A corner of the wavefront: where it started and when, and the edges it parts."""

    point: np.ndarray
    time: float
    left: _Edge
    right: _Edge
    velocity: np.ndarray | None = None  # None: its edges face each other, it runs a ridge
    is_reflex: bool = False
    before: "_Vertex" = None
    after: "_Vertex" = None
    is_alive: bool = True

    def at(self, time):
        """Return where the vertex is at `time`."""
        if self.velocity is None:
            return self.point
        return self.point + (time - self.time) * self.velocity


class _Wavefront:
    def __init__(self, rings):
        self.vertices = []
        self.events = []
        self.pushed = 0
        self.arcs = []  # (point, time, point, time)
        self.edges = []
        for ring in rings:
            ring_edges = []
            for start, end in zip(ring, np.roll(ring, -1, axis=0), strict=True):
                along = (end - start) / np.hypot(*(end - start))
                ring_edges.append(_Edge(start, along, np.array([-along[1], along[0]])))
            corners = [
                self.vertex(point, 0.0, ring_edges[index - 1], ring_edges[index])
                for index, point in enumerate(ring)
            ]
            for index, corner in enumerate(corners):
                corner.before, corner.after = corners[index - 1], corners[(index + 1) % len(ring)]
            self.edges += ring_edges
        for corner in list(self.vertices):
            self.schedule(corner)

    def vertex(self, point, time, left, right):
        vertex = _Vertex(np.array(point, np.float64), time, left, right)
        facing = 1.0 + float(left.inward @ right.inward)
        if facing > OPPOSED:
            vertex.velocity = (left.inward + right.inward) / facing
            vertex.is_reflex = float(footprints.cross(left.along, right.along)) < -1e-9
        self.vertices.append(vertex)
        return vertex

    def push(self, time, kind, *details):
        self.pushed += 1
        heapq.heappush(self.events, (time, self.pushed, kind, details))

    def arc(self, start, start_time, end, end_time):
        if np.hypot(*(end - start)) > SAME_POINT_M:
            self.arcs.append((start, start_time, end, end_time))

    # ------------------------------------------------------------------------ events
    def schedule(self, vertex):
        """Queue what can happen to a new vertex: to its two edges, and to the edge it splits."""
        if vertex.velocity is None:
            self.schedule_ridge(vertex)
            return
        self.schedule_collapse(vertex.before, vertex)
        self.schedule_collapse(vertex, vertex.after)
        if vertex.is_reflex:
            for edge in self.edges:
                if edge is not vertex.left and edge is not vertex.right:
                    self.schedule_split(vertex, edge)

    def schedule_ridge(self, vertex):
        """Queue a ridge vertex's meeting, at once, with the nearer of its neighbours.

        Its two edges face each other and have met: the shorter of them is gone.
        """
        time = vertex.time
        to_before = float(np.hypot(*(vertex.before.at(time) - vertex.point)))
        to_after = float(np.hypot(*(vertex.after.at(time) - vertex.point)))
        if to_before <= to_after:
            self.push(time, "collapse", vertex.before, vertex, vertex.before.at(time))
        else:
            self.push(time, "collapse", vertex, vertex.after, vertex.after.at(time))

    def schedule_collapse(self, first, second):
        """Queue the time the wavefront edge between two neighbours shrinks to nothing."""
        if first.velocity is None or second.velocity is None:
            return
        along = first.right.along
        closing = float((first.velocity - second.velocity) @ along)
        if closing <= 1e-12:
            return
        apart = (second.point - second.time * second.velocity) - (
            first.point - first.time * first.velocity
        )
        latest = max(first.time, second.time)
        time = float(apart @ along) / closing
        if time < latest - SAME_TIME * (1.0 + latest):
            return
        time = max(time, latest)
        self.push(time, "collapse", first, second, (first.at(time) + second.at(time)) / 2.0)

    def schedule_split(self, vertex, edge):
        """Queue the time a reflex vertex reaches the line of `edge` as it moves inwards."""
        approach = 1.0 - float(edge.inward @ vertex.velocity)
        if approach <= 1e-12:
            return
        height_m = float(edge.inward @ (vertex.point - edge.start))
        time = (height_m - vertex.time * (1.0 - approach)) / approach
        if time < vertex.time - SAME_TIME * (1.0 + vertex.time):
            return
        time = max(time, vertex.time)
        self.push(time, "split", vertex, edge, vertex.at(time))

    def run(self):
        while self.events:
            time, _, kind, details = heapq.heappop(self.events)
            if kind == "collapse":
                self.collapse(time, *details)
            else:
                self.split(time, *details)
        if any(vertex.is_alive for vertex in self.vertices):
            raise SkeletonError("the wavefront did not close")

    def close_ring(self, time, point, *others):
        """End the vertices of a ring that has shrunk to `point`, or to a ridge reaching it."""
        for vertex in others:
            now = vertex.at(time)
            self.arc(vertex.point, vertex.time, now, time)
            self.arc(now, time, point, time)
            vertex.is_alive = False

    def collapse(self, time, first, second, point):
        if not (first.is_alive and second.is_alive and first.after is second):
            return
        if first.before is second:
            self.close_ring(time, first.at(time), first, second)
            return
        self.arc(first.point, first.time, point, time)
        self.arc(second.point, second.time, point, time)
        first.is_alive = second.is_alive = False
        if first.before.before is second:
            self.close_ring(time, point, first.before)
            return
        merged = self.vertex(point, time, first.left, second.right)
        merged.before, merged.after = first.before, second.after
        merged.before.after = merged.after.before = merged
        self.schedule(merged)

    def split(self, time, vertex, edge, point):
        if not vertex.is_alive:
            return
        slack_m = 1e-7 * (1.0 + time)
        for start in self.vertices:
            end = start.after
            if not start.is_alive or start.right is not edge or vertex in (start, end):
                continue
            along_m = float((point - start.at(time)) @ edge.along)
            length_m = float((end.at(time) - start.at(time)) @ edge.along)
            if -slack_m <= along_m <= length_m + slack_m:
                break
        else:
            return
        self.arc(vertex.point, vertex.time, point, time)
        vertex.is_alive = False
        near = self.vertex(point, time, vertex.left, edge)
        far = self.vertex(point, time, edge, vertex.right)
        near.before, near.after = vertex.before, end
        far.before, far.after = start, vertex.after
        near.before.after = near.after.before = near
        far.before.after = far.after.before = far
        for half in (near, far):
            if half.after.after is half:
                half.is_alive = False
                self.close_ring(time, point, half.after)
            else:
                self.schedule(half)


def _node(nodes, times, point, time):
    """Return the index of the node at `point`, added when new."""
    for index, known in enumerate(nodes):
        if abs(known[0] - point[0]) <= SAME_POINT_M and abs(known[1] - point[1]) <= SAME_POINT_M:
            return index
    nodes.append(point)
    times.append(time)
    return len(nodes) - 1


def _face(neighbours, start, end):
    """Return the nodes around the face on the left of the edge from `start` to `end`."""
    face = [start, end]
    before, node = start, end
    for _ in range(len(neighbours) * 2):
        around = neighbours[node]
        following = around[around.index(before) - 1]
        if following == start:
            return face
        face.append(following)
        before, node = node, following
    raise SkeletonError("a face that does not close")


def skeleton(outline, holes=()):
    """Return the Skeleton of a footprint: `outline` counter-clockwise, `holes` clockwise."""
    rings = [np.asarray(ring, np.float64) for ring in [outline, *holes]]
    front = _Wavefront(rings)
    front.run()
    nodes = [point for ring in rings for point in ring]
    times = [0.0] * len(nodes)
    links = set()
    count = 0
    ring_edges = []
    for ring in rings:
        for index in range(len(ring)):
            ring_edges.append((count + index, count + (index + 1) % len(ring)))
        count += len(ring)
    links.update(ring_edges)
    for start, start_time, end, end_time in front.arcs:
        first = _node(nodes, times, start, start_time)
        second = _node(nodes, times, end, end_time)
        if first != second and (second, first) not in links:
            links.add((first, second))
    points = np.array(nodes)
    neighbours = {index: [] for index in range(len(points))}
    for first, second in links:
        neighbours[first].append(second)
        neighbours[second].append(first)
    for node, around in neighbours.items():
        around.sort(
            key=lambda other, node=node: math.atan2(
                points[other][1] - points[node][1], points[other][0] - points[node][0]
            )
        )
    result = Skeleton(points, np.array(times), [_face(neighbours, *edge) for edge in ring_edges])
    _check(result, front.edges, sum(footprints.signed_area_m2(ring) for ring in rings))
    return result


def _check(result, edges, area_m2):
    """Raise SkeletonError unless the faces are planes from their edges that cover the area."""
    covered_m2 = 0.0
    for face, edge in zip(result.faces, edges, strict=True):
        if len(set(face)) != len(face):
            raise SkeletonError("a face that touches itself")
        height_m = (result.points[face] - edge.start) @ edge.inward
        slack_m = FACE_PLANE_M * (1.0 + float(result.times.max()))
        if np.abs(height_m - result.times[face]).max() > slack_m:
            raise SkeletonError("a face that is no plane")
        face_m2 = footprints.signed_area_m2(result.points[face])
        if face_m2 <= 0.0 or not footprints.is_simple(result.points[face]):
            raise SkeletonError("a face that folds over")
        covered_m2 += face_m2
    if abs(covered_m2 - area_m2) > 1e-6 * max(area_m2, 1.0):
        raise SkeletonError("faces that do not cover the footprint")
