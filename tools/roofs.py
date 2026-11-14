"""Tell what a roof is covered with, and its colour, from the graded photo.

A photo is evidence of a roof, not its texture: it leans, it is shaded on one side and its
pixels stretch. A roof's colour is read away from its edges and out of the shadows, and its
roofing follows from that colour and the roof's shape; the simulator draws the roofing's own
texture, tinted to that colour (buildings.py writes both into the world).

Needs numpy.
"""

import ground_classes
import numpy as np

ROOF_MATERIAL_PREFIX = "M_Ortho_"
ROOF_CLASSES = ("slate", "clay_tiles", "concrete_tiles", "metal", "bitumen", "gravel", "green")

BRIGHTEST_ROOF = 0.3  # sheeting burns out in the photo
FLAT_PITCH_DEG = 8.0
SHED_PITCH_DEG = 20.0  # below this a large pitched roof is sheeting, not tiles
HALL_AREA_M2 = 350.0
LEAN_MARGIN_M = 1.5  # the photo's roofs lean: colour is read this far inside the edge
LIT_SHARE = 0.5  # the brightest share of a roof's pixels, out of its shaded side and shadows

CLAY_RED_OVER_GREEN = 1.15
CLAY_RED_OVER_BLUE = 1.3
LIGHT_ROOF_LUMINANCE = 0.5
DARK_ROOF_LUMINANCE = 0.3
GRAVEL_LUMINANCE = 0.42


def classify_roof(albedo, pitch_deg, area_m2):
    """Return the roofing a roof of this colour and shape is covered with.

    `albedo` is the roof's linear colour in the graded photo. Shape decides what colour
    cannot: a flat roof carries no tiles, and a large roof of low pitch is sheeting.
    """
    red, green, blue = (float(channel) for channel in ground_classes.srgb(np.asarray(albedo)))
    luminance = 0.3 * red + 0.59 * green + 0.11 * blue
    is_vegetated = green > red * 1.05 and green > blue * 1.05
    is_clay = red > green * CLAY_RED_OVER_GREEN and red > blue * CLAY_RED_OVER_BLUE
    if pitch_deg < FLAT_PITCH_DEG:
        if is_vegetated:
            return "green"
        if luminance > LIGHT_ROOF_LUMINANCE and area_m2 > HALL_AREA_M2:
            return "metal"
        return "gravel" if luminance > GRAVEL_LUMINANCE else "bitumen"
    if is_clay:
        return "clay_tiles"
    if luminance > LIGHT_ROOF_LUMINANCE or (pitch_deg < SHED_PITCH_DEG and area_m2 > HALL_AREA_M2):
        return "metal"
    return "slate" if luminance < DARK_ROOF_LUMINANCE else "concrete_tiles"


def lit_colour(albedos):
    """Return a roof's colour from the photo's pixels on it: the median of its lit share.

    The photo shades one side of a pitched roof and casts chimneys' and trees' shadows on it;
    the roofing is one colour.
    """
    albedos = np.asarray(albedos, np.float64).reshape(-1, 3)
    luminance = albedos @ np.array([0.2126, 0.7152, 0.0722])
    lit = albedos[luminance >= np.quantile(luminance, 1.0 - LIT_SHARE)]
    return np.median(lit, axis=0)
