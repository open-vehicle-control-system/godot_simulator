"""Classify an orthophoto into the ground layers a track pack's surface maps name.

A surface map is an 8-bit image whose pixel value is the index of the layer that covers that
pixel (see docs/pack_format.md). Classification reads colour and local texture only, so it
works on any spring orthophoto of about 25 cm per pixel.
"""

import numpy as np
from PIL import Image, ImageFilter

LAYERS = (
    "lawn",
    "meadow",
    "dry_grass",
    "soil",
    "gravel",
    "track_asphalt",
    "worn_asphalt",
    "forest_floor",
)
LAWN, MEADOW, DRY_GRASS, SOIL, GRAVEL, TRACK_ASPHALT, WORN_ASPHALT, FOREST_FLOOR = range(8)
# Layers a survey of roads and parking lots gives, that the photo's colours alone do not tell.
CONCRETE, PAVERS = 8, 9
SURVEYED_LAYERS = ("concrete", "pavers")
UNKNOWN = 255
VEGETATION = (LAWN, MEADOW, FOREST_FLOOR)
# OpenStreetMap `surface` values; asphalt is told fresh from worn by its colour.
TAGGED_LAYERS = {
    "concrete": CONCRETE,
    "concrete:plates": CONCRETE,
    "concrete:lanes": CONCRETE,
    "paving_stones": PAVERS,
    "sett": PAVERS,
    "cobblestone": PAVERS,
    "unhewn_cobblestone": PAVERS,
    "gravel": GRAVEL,
    "fine_gravel": GRAVEL,
    "compacted": GRAVEL,
    "pebblestone": GRAVEL,
    "unpaved": SOIL,
    "dirt": SOIL,
    "ground": SOIL,
    "earth": SOIL,
    "mud": SOIL,
    "grass": LAWN,
}

ASPHALT_ALBEDO = 0.14
HAZE_PERCENTILE = 0.3
GRADE_GAMMA = 0.7
GRADE_SATURATION = 1.3
SHADOW_LUMINANCE = 0.16
ROUGH_TEXTURE = 0.02
DARK_VEGETATION_LUMINANCE = 0.2
ROUGH_GROUND_TEXTURE = 0.045
GREY_SATURATION = 0.09
EARTH_GREEN_OVER_RED = 0.62  # redder than this is paint
GRAVEL_LUMINANCE = 0.43
DRY_GRASS_SATURATION = 0.22
TEXTURE_WINDOW_PX = 9
TEXTURE_REGION_PX = 10
FILL_REACH_PX = 12
MAJORITY_RADIUS_PX = 1.5
FRESH_ASPHALT_LUMINANCE = 0.36
CONCRETE_LUMINANCE = 0.62
CLEAR_COLOUR_BINS = 48
CLEAR_COLOUR_BAND = 0.07  # how far from the commonest luminance a clear pixel may be


def blurred(channel, radius_px):
    """Return a float image in [0, 1], Gaussian-blurred."""
    image = Image.fromarray(np.clip(channel * 255.0, 0, 255).astype(np.uint8))
    return np.asarray(image.filter(ImageFilter.GaussianBlur(radius_px)), np.float32) / 255.0


def local_texture(luminance):
    """Return the local standard deviation of `luminance` over the texture window."""
    box = ImageFilter.BoxBlur(TEXTURE_WINDOW_PX // 2)
    as_image = Image.fromarray(np.clip(luminance * 255.0, 0, 255).astype(np.uint8))
    mean = np.asarray(as_image.filter(box), np.float32) / 255.0
    squares = Image.fromarray(np.clip(luminance**2 * 255.0, 0, 255).astype(np.uint8))
    mean_of_squares = np.asarray(squares.filter(box), np.float32) / 255.0
    return np.sqrt(np.maximum(mean_of_squares - mean**2, 0.0))


def linear(srgb):
    """Return sRGB values in [0, 1] as linear light."""
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


def srgb(linear_light):
    """Return linear light in [0, 1] as sRGB values."""
    return np.where(
        linear_light <= 0.0031308,
        linear_light * 12.92,
        1.055 * np.maximum(linear_light, 1e-6) ** (1 / 2.4) - 0.055,
    )


def estimate_grade(photo, asphalt):
    """Return the grade that turns a hazy, sunlit photo into albedo.

    `photo` is a sample of the photo's pixels and `asphalt` pixels known to be asphalt (both
    uint8, N x 3): the haze is the photo's darkest colour, and asphalt comes out neutral at
    ASPHALT_ALBEDO.
    """
    black = np.percentile(linear(photo.astype(np.float32) / 255.0), HAZE_PERCENTILE, axis=0)
    lit = np.median(linear(asphalt.astype(np.float32) / 255.0), axis=0) - black
    gain = ASPHALT_ALBEDO / np.maximum(lit, 1e-3) ** GRADE_GAMMA
    return {
        "black": [round(float(c), 4) for c in black],
        "gain": [round(float(c), 4) for c in gain],
        "gamma": GRADE_GAMMA,
        "saturation": GRADE_SATURATION,
    }


def graded(rgb, grade):
    """Return the linear albedo of sRGB photo pixels (uint8) under `grade`."""
    light = linear(rgb.astype(np.float32) / 255.0) - np.array(grade["black"], np.float32)
    albedo = np.array(grade["gain"], np.float32) * np.maximum(light, 0.0) ** grade["gamma"]
    grey = albedo @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    return np.clip(grey[..., None] + (albedo - grey[..., None]) * grade["saturation"], 0.0, 1.0)


def classify_colours(albedo):
    """Return the layer index of each pixel of a graded photo (linear albedo, H x W x 3).

    Pixels too dark to tell (shadows) are UNKNOWN.
    """
    colour = srgb(albedo).astype(np.float32)
    smooth = np.stack([blurred(colour[..., c], 1.0) for c in range(3)], -1)
    red, green, blue = smooth[..., 0], smooth[..., 1], smooth[..., 2]
    luminance = 0.3 * red + 0.59 * green + 0.11 * blue
    highest, lowest = smooth.max(-1), smooth.min(-1)
    saturation = (highest - lowest) / (highest + 1e-3)
    # Rough and mown grass are told apart over a few metres: a blade's own texture is noise.
    texture = blurred(
        local_texture(0.3 * colour[..., 0] + 0.59 * colour[..., 1] + 0.11 * colour[..., 2]),
        TEXTURE_REGION_PX,
    )

    vegetation = (green > red * 1.05) & (green > blue * 1.05)
    grey = (saturation < GREY_SATURATION) | (blue >= red)
    earthy = (red >= green * 0.98) & (green > blue) & (green > red * EARTH_GREEN_OVER_RED)
    warm = earthy & ~grey & ~vegetation

    labels = np.full(albedo.shape[:2], WORN_ASPHALT, np.uint8)
    labels[warm] = SOIL
    labels[warm & (luminance > GRAVEL_LUMINANCE)] = GRAVEL
    labels[warm & (green > red * 0.93) & (saturation >= DRY_GRASS_SATURATION)] = DRY_GRASS
    labels[vegetation] = LAWN
    labels[vegetation & (texture > ROUGH_TEXTURE)] = MEADOW
    labels[vegetation & (luminance < DARK_VEGETATION_LUMINANCE) & (texture > ROUGH_TEXTURE)] = (
        FOREST_FLOOR
    )
    # Asphalt is smooth: grey ground that is rough over metres is rubble, scrub, waste
    # ground or leafless wood.
    labels[grey & ~vegetation & (texture > ROUGH_GROUND_TEXTURE)] = SOIL
    labels[(luminance < SHADOW_LUMINANCE) & ~vegetation] = UNKNOWN
    return labels


def fill_unknown(labels):
    """Return `labels` with UNKNOWN pixels given the layer most common around them."""
    unknown = labels == UNKNOWN
    if not unknown.any():
        return labels
    votes = np.stack(
        [blurred((labels == layer).astype(np.float32), FILL_REACH_PX) for layer in range(8)]
    )
    filled = labels.copy()
    filled[unknown] = votes.argmax(0).astype(np.uint8)[unknown]
    return filled


def majority(labels):
    """Return `labels` with speckle removed: each pixel takes its neighbourhood's layer."""
    votes = np.stack(
        [blurred((labels == layer).astype(np.float32), MAJORITY_RADIUS_PX) for layer in range(8)]
    )
    return votes.argmax(0).astype(np.uint8)


def classify(albedo):
    """Return the cleaned layer index of each pixel of a graded photo."""
    return majority(fill_unknown(classify_colours(albedo)))


def _luminance(colour):
    return 0.3 * colour[..., 0] + 0.59 * colour[..., 1] + 0.11 * colour[..., 2]


def clear_colour(albedo):
    """Return the colour of a surface without what stands on it: cars, their shadows, paint.

    `albedo` is the graded photo's pixels of the surface (N x 3). The surface is what most
    of them show: the commonest luminance, and the median colour of the pixels near it.
    """
    colour = srgb(albedo)
    luminance = _luminance(colour)
    counts, edges = np.histogram(luminance, CLEAR_COLOUR_BINS, (0.0, 1.0))
    smoothed = np.convolve(counts, [0.25, 0.5, 0.25], mode="same")
    commonest = edges[int(smoothed.argmax())] + 0.5 / CLEAR_COLOUR_BINS
    clear = np.abs(luminance - commonest) <= CLEAR_COLOUR_BAND
    return np.median(albedo[clear], axis=0)


def surface_layer(albedo, tagged, paved):
    """Return the layer of a road or lot from its clear colour (linear albedo) and tags.

    `tagged` is its OpenStreetMap `surface` or None, `paved` what its kind is by default.
    Vegetation comes back as LAWN: the photo shows no made surface there.
    """
    colour = srgb(np.asarray(albedo, np.float32))
    red, green, blue = colour
    luminance = float(_luminance(colour))
    if tagged in TAGGED_LAYERS:
        return TAGGED_LAYERS[tagged]
    if tagged is None and green > red * 1.05 and green > blue * 1.05:
        return LAWN
    saturation = (colour.max() - colour.min()) / (colour.max() + 1e-3)
    grey = saturation < GREY_SATURATION or blue >= red
    if tagged == "asphalt" or (paved and grey):
        if luminance > CONCRETE_LUMINANCE and tagged is None:
            return CONCRETE
        return TRACK_ASPHALT if luminance < FRESH_ASPHALT_LUMINANCE else WORN_ASPHALT
    if grey or luminance > GRAVEL_LUMINANCE:
        return GRAVEL
    return SOIL
