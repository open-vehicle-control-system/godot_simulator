"""Draw the faces of Belgian road signs, from their published designs.

A face is the plate's outline in metres and the image its front shows. Everything is drawn
here from shapes: no artwork file is copied. The designs are those of the Belgian highway
code (arrêté royal of 1 December 1975, article 65 and following), which follow the Vienna
convention; the sizes are the minimum ones of the arrêté ministériel of 11 October 1976
(articles 6.4.1, 6.4.2 and 12.13), which differ in and out of built-up areas.
"""

import functools
import math
import re
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageDraw

SOURCE = (
    "Road sign faces: drawn by the pack's builder (tools/sign_faces.py) after the designs of "
    "the Belgian highway code (arrêté royal of 1 December 1975), CC0"
)
FACE_PX = 256
SUPERSAMPLING = 4
RED = (196, 20, 28)
BLUE = (12, 78, 152)
YELLOW = (246, 196, 12)
WHITE = (240, 240, 238)
BLACK = (24, 24, 26)
# The plates' sizes: a triangle's side, an octagon's width, a disc's diameter and a diamond's
# side, on a road of under four lanes outside built-up areas, then inside them.
SIZES_M = (
    {"triangle": 0.9, "octagon": 0.9, "disc": 0.7, "diamond": 0.4},
    {"triangle": 0.7, "octagon": 0.9, "disc": 0.6, "diamond": 0.4},
)
CROSSING_SIDE_M = 0.6
BUILT_UP = "@built-up"  # ends the id of a face at its built-up size, when that differs
CORNER_RADIUS_M = 0.035
CORNER_STEPS = 5
DISC_STEPS = 40
RIM = 0.02  # the light rim along a plate's edge, as a share of its size
SPEED_LIMIT = re.compile(r"BE:C43\[(\d{1,3})\]")


@dataclass
class Face:
    """A sign's plate: its convex outline and the image its bounding box shows.

    The outline is N x 2 metres about the plate's centre, x to the viewer's right, y up.
    """

    code: str
    outline_m: np.ndarray
    image: Image.Image


def _arc(centre, radii, from_deg, to_deg, steps=24):
    """Return the points of an elliptical arc, angles counter-clockwise from +x."""
    angles = np.radians(np.linspace(from_deg, to_deg, steps + 1))
    return [
        (centre[0] + radii[0] * math.cos(angle), centre[1] + radii[1] * math.sin(angle))
        for angle in angles
    ]


# Glyphs as strokes in a box 0.6 wide and 1 high, y up: every stroke is a polyline.
_BOWL = _arc((0.3, 0.7), (0.3, 0.3), 0, 180) + _arc((0.3, 0.3), (0.3, 0.3), 180, 360)
_SIX = (
    _arc((0.3, 0.7), (0.3, 0.3), 35, 180)
    + [(0.0, 0.3)]
    + _arc((0.3, 0.3), (0.3, 0.3), 180, -180, 48)
)
GLYPHS = {
    "0": [_BOWL + [_BOWL[0]]],
    "1": [[(0.08, 0.74), (0.38, 1.0), (0.38, 0.0)]],
    "2": [_arc((0.3, 0.7), (0.3, 0.3), 165, -45) + [(0.0, 0.0), (0.6, 0.0)]],
    "3": [_arc((0.29, 0.76), (0.27, 0.24), 150, -90) + _arc((0.29, 0.26), (0.31, 0.26), 90, -150)],
    "4": [[(0.46, 0.0), (0.46, 1.0), (0.0, 0.3), (0.62, 0.3)]],
    "5": [[(0.56, 1.0), (0.09, 1.0), (0.05, 0.57)] + _arc((0.28, 0.32), (0.32, 0.32), 135, -150)],
    "6": [_SIX],
    "7": [[(0.0, 1.0), (0.6, 1.0), (0.2, 0.0)]],
    "8": [
        _arc((0.3, 0.75), (0.25, 0.25), -90, 270, 48),
        _arc((0.3, 0.27), (0.3, 0.27), 90, 450, 48),
    ],
    "9": [[(0.6 - x, 1.0 - y) for x, y in _SIX]],
    "S": [_arc((0.3, 0.75), (0.28, 0.25), 25, 270) + _arc((0.3, 0.25), (0.3, 0.25), 90, -155)],
    "T": [[(0.0, 1.0), (0.6, 1.0)], [(0.3, 1.0), (0.3, 0.0)]],
    "O": [_BOWL + [_BOWL[0]]],
    "P": [
        [(0.0, 0.0), (0.0, 1.0), (0.32, 1.0)]
        + _arc((0.32, 0.73), (0.27, 0.27), 90, -90)
        + [(0.0, 0.46)]
    ],
}
GLYPH_WIDTH = {"1": 0.46}
GLYPH_STROKE = 0.17  # of the glyph's height
GLYPH_GAP = 0.2
SHARP_JOINT = 0.9  # the cosine of the turn from which a stroke's joint is rounded


class _Canvas:
    """A square drawing in plate units: (-0.5, -0.5) bottom left to (0.5, 0.5) top right."""

    def __init__(self, background):
        self.size = FACE_PX * SUPERSAMPLING
        self.image = Image.new("RGB", (self.size, self.size), background)
        self.draw = ImageDraw.Draw(self.image)

    def _px(self, points):
        return [((x + 0.5) * self.size, (0.5 - y) * self.size) for x, y in points]

    def polygon(self, points, colour):
        self.draw.polygon(self._px(points), fill=colour)

    def disc(self, centre, radius, colour):
        (left, top), (right, bottom) = self._px(
            [(centre[0] - radius, centre[1] + radius), (centre[0] + radius, centre[1] - radius)]
        )
        self.draw.ellipse([left, top, right, bottom], fill=colour)

    def stroke(self, points, width, colour):
        """Draw a polyline `width` wide with round joints and flat ends."""
        points = [
            point for index, point in enumerate(points) if index == 0 or point != points[index - 1]
        ]
        sides = []
        for start, end in zip(points[:-1], points[1:], strict=True):
            along = np.subtract(end, start)
            across = np.array([-along[1], along[0]]) / np.hypot(*along) * width / 2.0
            sides.append(across)
            self.polygon([start + across, end + across, end - across, start - across], colour)
        closed = points[0] == points[-1]
        for index, joint in enumerate(points[:-1]):
            if index == 0 and not closed:
                continue
            before, after = sides[index - 1], sides[index]
            if before @ after < SHARP_JOINT * (width / 2.0) ** 2:
                self.disc(joint, width / 2.0, colour)
            else:
                # A gentle turn: fill the wedges between the two segments' ends.
                self.polygon([joint, joint + before, joint + after], colour)
                self.polygon([joint, joint - before, joint - after], colour)

    def text(self, text, centre, height, colour, narrowed=1.0):
        """Draw `text` in the stroke glyphs, `height` high, centred on `centre`.

        `narrowed` scales the glyphs' width.
        """
        widths = [GLYPH_WIDTH.get(glyph, 0.6) * narrowed for glyph in text]
        gap = GLYPH_GAP * narrowed
        total = sum(widths) + gap * (len(text) - 1)
        left = centre[0] - total * height / 2.0
        for glyph, width in zip(text, widths, strict=True):
            for stroke in GLYPHS[glyph]:
                placed = [
                    (left + x * narrowed * height, centre[1] + (y - 0.5) * height)
                    for x, y in stroke
                ]
                self.stroke(placed, GLYPH_STROKE * height, colour)
            left += (width + gap) * height

    def finished(self):
        return self.image.resize((FACE_PX, FACE_PX), Image.LANCZOS)


def rounded(corners, radius):
    """Return a convex polygon with its corners rounded to `radius`, counter-clockwise."""
    corners = np.asarray(corners, np.float64)
    points = []
    for index, corner in enumerate(corners):
        before = corners[index - 1] - corner
        after = corners[(index + 1) % len(corners)] - corner
        before /= np.hypot(*before)
        after /= np.hypot(*after)
        half_angle = math.acos(float(np.clip(before @ after, -1.0, 1.0))) / 2.0
        setback = radius / math.tan(half_angle)
        bisector = (before + after) / np.hypot(*(before + after))
        centre = corner + bisector * radius / math.sin(half_angle)
        start, end = corner + before * setback, corner + after * setback
        from_angle = math.atan2(*(start - centre)[::-1])
        turn = (math.atan2(*(end - centre)[::-1]) - from_angle + math.pi) % (2 * math.pi) - math.pi
        for step in range(CORNER_STEPS + 1):
            angle = from_angle + turn * step / CORNER_STEPS
            points.append(centre + radius * np.array([math.cos(angle), math.sin(angle)]))
    return np.array(points)


def _regular(count, radius, first_deg):
    return [
        (
            radius * math.cos(math.radians(first_deg + 360.0 * index / count)),
            radius * math.sin(math.radians(first_deg + 360.0 * index / count)),
        )
        for index in range(count)
    ]


def _scaled(points, factor, centre=(0.0, 0.0)):
    return [
        (centre[0] + (x - centre[0]) * factor, centre[1] + (y - centre[1]) * factor)
        for x, y in points
    ]


def _plate(corners, size_m):
    """Return the outline in metres of a plate whose unit `corners` span `size_m`."""
    return rounded(np.array(corners) * size_m, CORNER_RADIUS_M), size_m


def _give_way(sizes_m):
    height = math.sqrt(3.0) / 2.0
    corners = [(-0.5, height / 2.0), (0.0, -height / 2.0), (0.5, height / 2.0)]
    centroid = (0.0, height / 6.0)
    canvas = _Canvas(WHITE)
    canvas.polygon(_scaled(corners, 1.0 - 3.0 * RIM, centroid), RED)
    canvas.polygon(_scaled(corners, 0.56, centroid), WHITE)
    return *_plate(corners, sizes_m["triangle"]), canvas


def _stop(sizes_m):
    corners = _regular(8, 0.5 / math.cos(math.pi / 8.0), 22.5)
    canvas = _Canvas(WHITE)
    canvas.polygon(_scaled(corners, 1.0 - 2.0 * RIM), RED)
    canvas.polygon(_scaled(corners, 0.9), WHITE)
    canvas.polygon(_scaled(corners, 0.9 - 2.5 * RIM), RED)
    canvas.text("STOP", (0.0, 0.0), 0.31, WHITE, narrowed=0.72)
    return *_plate(corners, sizes_m["octagon"]), canvas


def _disc(colour, sizes_m):
    canvas = _Canvas(WHITE)
    canvas.disc((0.0, 0.0), 0.5 - RIM, colour)
    return np.array(_regular(DISC_STEPS, sizes_m["disc"] / 2.0, 0.0)), sizes_m["disc"], canvas


def _speed_limit(limit, sizes_m):
    outline, size_m, canvas = _disc(RED, sizes_m)
    canvas.disc((0.0, 0.0), 0.37, WHITE)
    canvas.text(limit, (0.0, 0.0), 0.36 if len(limit) < 3 else 0.28, BLACK)
    return outline, size_m, canvas


def _no_entry(sizes_m):
    outline, size_m, canvas = _disc(RED, sizes_m)
    canvas.polygon([(-0.36, -0.07), (0.36, -0.07), (0.36, 0.07), (-0.36, 0.07)], WHITE)
    return outline, size_m, canvas


def _closed(sizes_m):
    outline, size_m, canvas = _disc(RED, sizes_m)
    canvas.disc((0.0, 0.0), 0.37, WHITE)
    return outline, size_m, canvas


def _roundabout(sizes_m):
    outline, size_m, canvas = _disc(BLUE, sizes_m)
    radius, width, head = 0.25, 0.1, 0.1
    for turn_deg in (90.0, 210.0, 330.0):
        canvas.stroke(_arc((0.0, 0.0), (radius, radius), turn_deg, turn_deg + 72.0), width, WHITE)
        base = math.radians(turn_deg + 70.0)
        outward = np.array([math.cos(base), math.sin(base)])
        onward = np.array([-outward[1], outward[0]])
        canvas.polygon(
            [
                (radius + head) * outward,
                (radius - head) * outward,
                radius * outward + 1.5 * head * onward,
            ],
            WHITE,
        )
    return outline, size_m, canvas


def _priority_road(sizes_m):
    corners = _regular(4, 0.5, 0.0)
    canvas = _Canvas(WHITE)
    canvas.polygon(_scaled(corners, 1.0 - 2.0 * RIM), BLACK)
    canvas.polygon(_scaled(corners, 1.0 - 3.0 * RIM), WHITE)
    canvas.polygon(_scaled(corners, 0.7), YELLOW)
    return *_plate(corners, sizes_m["diamond"] * math.sqrt(2.0)), canvas


def _pedestrian_crossing(_sizes_m):
    corners = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
    canvas = _Canvas(WHITE)
    canvas.polygon(_scaled(corners, 1.0 - 2.0 * RIM), BLUE)
    canvas.polygon([(-0.4, -0.36), (0.4, -0.36), (0.0, 0.4)], WHITE)
    # The walker, striding to the left, on the crossing's stripes.
    canvas.disc((-0.015, 0.16), 0.04, BLACK)
    canvas.stroke([(-0.005, 0.105), (0.01, -0.06)], 0.062, BLACK)
    canvas.stroke([(0.005, 0.09), (-0.085, 0.02), (-0.125, -0.03)], 0.026, BLACK)
    canvas.stroke([(0.005, 0.09), (0.075, 0.01), (0.095, -0.05)], 0.026, BLACK)
    canvas.stroke([(0.01, -0.05), (-0.055, -0.14), (-0.12, -0.215)], 0.036, BLACK)
    canvas.stroke([(0.01, -0.05), (0.05, -0.14), (0.115, -0.215)], 0.036, BLACK)
    for stripe in range(5):
        left = -0.27 + stripe * 0.118
        canvas.polygon(
            [(left, -0.31), (left + 0.07, -0.31), (left + 0.064, -0.25), (left + 0.012, -0.25)],
            BLACK,
        )
    return *_plate(corners, CROSSING_SIDE_M), canvas


DRAWN = {
    "BE:B1": _give_way,
    "BE:B5": _stop,
    "BE:B9": _priority_road,
    "BE:C1": _no_entry,
    "BE:C3": _closed,
    "BE:D5": _roundabout,
    "BE:F49": _pedestrian_crossing,
}


SHAPES = {
    "BE:B1": "triangle",
    "BE:B5": "octagon",
    "BE:B9": "diamond",
    "BE:C1": "disc",
    "BE:C3": "disc",
    "BE:D5": "disc",
}


def is_drawn(code):
    """Tell whether a sign code has a face here."""
    return code in DRAWN or SPEED_LIMIT.fullmatch(code) is not None


def face_id(code, built_up):
    """Return the id of a sign code's face at the size its road asks for."""
    shape = SHAPES.get(code, "disc" if SPEED_LIMIT.fullmatch(code) else None)
    smaller = shape is not None and SIZES_M[1][shape] != SIZES_M[0][shape]
    return code + BUILT_UP if built_up and smaller else code


def outline(identifier):
    """Return the plate outline of a face that is drawn."""
    return face(identifier).outline_m


@functools.cache
def face(identifier):
    """Return the Face of a face id (`BE:B1`, `BE:C43[50]@built-up`), or None if not drawn."""
    code = identifier.removesuffix(BUILT_UP)
    sizes_m = SIZES_M[identifier.endswith(BUILT_UP)]
    limit = SPEED_LIMIT.fullmatch(code)
    if limit:
        outline, size_m, canvas = _speed_limit(limit.group(1), sizes_m)
    elif code in DRAWN:
        outline, size_m, canvas = DRAWN[code](sizes_m)
    else:
        return None
    image = canvas.finished()
    # The canvas is a square of `size_m`; the image covers the outline's bounding box.
    low, high = outline.min(0), outline.max(0)
    box = [
        round((low[0] / size_m + 0.5) * FACE_PX),
        round((0.5 - high[1] / size_m) * FACE_PX),
        round((high[0] / size_m + 0.5) * FACE_PX),
        round((0.5 - low[1] / size_m) * FACE_PX),
    ]
    return Face(identifier, outline, image.crop(box))


def file_name(identifier):
    """Return the name of a face's image in a pack: `BE:C43[50]` is `be_c43_50.png`."""
    return re.sub(r"[^a-z0-9]+", "_", identifier.lower()).strip("_") + ".png"
