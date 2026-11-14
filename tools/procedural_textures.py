"""Draw texture sets and tree impostor atlases from code alone, for the default track.

Every image is drawn from a fixed seed, so two runs draw the same pixels, and tiles: its
noise is periodic (filtered white noise in the frequency domain) and its patterns repeat a
whole number of times across it. A texture set is an albedo (sRGB), a normal map (OpenGL
convention: green up the image) and a roughness map, as docs/pack_format.md asks.

Needs numpy and Pillow.
"""

import math

import ground_classes
import numpy as np
from PIL import Image, ImageDraw

KINDS = ("grass", "gravel", "asphalt", "plaster", "brick", "clay_tiles", "metal_sheet")
TREE_KINDS = ("broadleaf", "conifer")
TREE_VIEWS = 3
TREE_SUPERSAMPLING = 3


def periodic_noise(side_px, wavelength_px, seed):
    """Return tiling noise of about `wavelength_px`, zero mean and unit deviation."""
    white = np.random.default_rng(seed).standard_normal((side_px, side_px))
    frequencies = np.fft.fftfreq(side_px)
    radius = np.hypot(frequencies[:, None], frequencies[None, :]) * wavelength_px
    band = np.exp(-0.5 * ((radius - 1.0) / 0.6) ** 2) + np.exp(-0.5 * (radius / 0.6) ** 2) * 0.5
    filtered = np.real(np.fft.ifft2(np.fft.fft2(white) * band))
    return (filtered - filtered.mean()) / max(float(filtered.std()), 1e-9)


def fractal_noise(side_px, wavelengths_px, seed):
    """Return the sum of noises of halving weight, one per wavelength, unit deviation."""
    total = sum(
        periodic_noise(side_px, wavelength, seed + index) * 0.6**index
        for index, wavelength in enumerate(wavelengths_px)
    )
    return total / float(total.std())


def cells(side_px, cell_px, seed):
    """Return tiling Worley cells: each pixel's distance to its cell's point and the cell's id.

    The points are jittered on a grid of `cell_px`, which divides `side_px`.
    """
    count = side_px // cell_px
    rng = np.random.default_rng(seed)
    points = np.indices((count, count)).transpose(1, 2, 0) + rng.uniform(
        0.1, 0.9, (count, count, 2)
    )
    points *= cell_px
    rows, columns = np.indices((side_px, side_px)) + 0.5
    cell_row, cell_column = (rows // cell_px).astype(int), (columns // cell_px).astype(int)
    nearest = np.full((side_px, side_px), np.inf)
    owner = np.zeros((side_px, side_px), int)
    for down in (-1, 0, 1):
        for right in (-1, 0, 1):
            row, column = cell_row + down, cell_column + right
            point = points[row % count, column % count]
            point_row = point[..., 0] + (row - row % count) * cell_px
            point_column = point[..., 1] + (column - column % count) * cell_px
            distance = np.hypot(rows - point_row, columns - point_column)
            closer = distance < nearest
            nearest = np.where(closer, distance, nearest)
            owner = np.where(closer, (row % count) * count + column % count, owner)
    return nearest / cell_px, owner


def normal_map(height, strength):
    """Return the OpenGL normal map of a tiling height field, as 8-bit RGB."""
    across = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5 * strength
    down = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 0.5 * strength
    normal = np.stack([-across, down, np.ones_like(height)], -1)
    normal /= np.linalg.norm(normal, axis=-1, keepdims=True)
    return _bytes(normal * 0.5 + 0.5)


def _bytes(values):
    return np.clip(np.round(values * 255.0), 0, 255).astype(np.uint8)


def _albedo(linear_rgb):
    return _bytes(ground_classes.srgb(np.clip(linear_rgb, 0.0, 1.0)))


def _mix(low, high, share):
    share = np.clip(share, 0.0, 1.0)[..., None]
    return np.asarray(low) * (1.0 - share) + np.asarray(high) * share


def _grass(side_px):
    blades = periodic_noise(side_px, 2.5, 11)
    tufts = fractal_noise(side_px, (24, 9), 12)
    height = 0.6 * blades + 0.4 * tufts
    colour = _mix((0.035, 0.07, 0.015), (0.13, 0.2, 0.05), 0.5 + 0.22 * height)
    colour = _mix(
        colour, (0.12, 0.13, 0.05), 0.4 * np.clip(periodic_noise(side_px, 60, 13) - 1.8, 0, 1)
    )
    return colour, height, 0.85 + 0.08 * blades, 3.0


def _gravel(side_px):
    distance, owner = cells(side_px, 8, 21)
    shade = np.random.default_rng(22).uniform(0.0, 1.0, owner.max() + 1)[owner]
    height = np.sqrt(np.clip(1.0 - distance**2 * 1.4, 0.0, 1.0)) + 0.1 * periodic_noise(
        side_px, 2, 23
    )
    colour = _mix((0.2, 0.17, 0.12), (0.45, 0.4, 0.32), shade) * (0.55 + 0.45 * height[..., None])
    return colour, height, 0.75 + 0.15 * (1.0 - height), 6.0


def _asphalt(side_px):
    distance, owner = cells(side_px, 4, 31)
    stone = np.random.default_rng(32).uniform(0.0, 1.0, owner.max() + 1)[owner]
    height = np.clip(0.9 - distance, 0.0, 1.0) * (0.5 + 0.5 * stone)
    height += 0.25 * fractal_noise(side_px, (40, 12), 33)
    grey = 0.11 + 0.035 * stone * (distance < 0.55) + 0.008 * periodic_noise(side_px, 30, 34)
    colour = np.repeat(grey[..., None], 3, -1) * (1.0, 1.0, 1.03)
    return colour, height, 0.8 + 0.1 * (distance > 0.55), 2.5


def _plaster(side_px):
    height = fractal_noise(side_px, (6, 2), 41)
    stain = periodic_noise(side_px, 90, 42)
    colour = np.full((side_px, side_px, 3), 0.62) * (1.0 + 0.03 * height + 0.04 * stain)[..., None]
    return colour, height, 0.9 + 0.03 * height, 1.5


def _brick(side_px):
    rows, columns = np.indices((side_px, side_px)) + 0.5
    course_count, brick_count = 26, 9
    course = (rows * course_count / side_px).astype(int)
    along = columns * brick_count / side_px + 0.5 * (course % 2)
    brick = course * brick_count * 2 + (along.astype(int) % brick_count)
    joint_rows = np.abs(rows * course_count / side_px - np.round(rows * course_count / side_px))
    joint_columns = np.abs(along - np.round(along))
    mortar = (joint_rows < 0.07) | (joint_columns < 0.025)
    shade = np.random.default_rng(51).uniform(0.0, 1.0, brick.max() + 1)[brick]
    grain = periodic_noise(side_px, 3, 52)
    colour = _mix((0.22, 0.07, 0.04), (0.42, 0.16, 0.09), shade + 0.1 * grain)
    colour = np.where(mortar[..., None], np.array([0.42, 0.4, 0.36]), colour)
    height = np.where(mortar, 0.0, 1.0) + 0.15 * grain
    return colour, height, np.where(mortar, 0.95, 0.85), 2.0


def _clay_tiles(side_px):
    rows, columns = np.indices((side_px, side_px)) + 0.5
    row_count, tile_count = 8, 13
    course = rows * row_count / side_px
    along = columns * tile_count / side_px + 0.5 * (course.astype(int) % 2)
    down_tile = course % 1.0  # 0 at a row's top edge, up the slope, 1 at its lower edge
    curve = np.sin(np.pi * (along % 1.0))
    height = 0.6 * curve + 0.4 * down_tile + 0.08 * periodic_noise(side_px, 3, 61)
    shade = np.random.default_rng(62).uniform(0.85, 1.1, (row_count + 1) * (tile_count + 1))
    tile = course.astype(int) * (tile_count + 1) + along.astype(int) % tile_count
    colour = np.array([0.36, 0.11, 0.05]) * (shade[tile] * (0.7 + 0.3 * curve))[..., None]
    colour *= (1.0 - 0.5 * np.clip((down_tile - 0.88) / 0.12, 0.0, 1.0))[..., None]
    return colour, height, 0.7 + 0.1 * curve, 4.0


def _metal_sheet(side_px):
    columns = np.indices((side_px, side_px))[1] + 0.5
    corrugation = np.sin(2.0 * np.pi * columns * 33 / side_px)
    dirt = fractal_noise(side_px, (50, 10), 71)
    height = 0.8 * corrugation + 0.05 * dirt
    colour = (
        np.full((side_px, side_px, 3), 0.42) * (0.9 + 0.1 * corrugation + 0.04 * dirt)[..., None]
    )
    return colour, height, 0.45 + 0.08 * dirt, 6.0


DRAWERS = {
    "grass": _grass,
    "gravel": _gravel,
    "asphalt": _asphalt,
    "plaster": _plaster,
    "brick": _brick,
    "clay_tiles": _clay_tiles,
    "metal_sheet": _metal_sheet,
}


def texture_set(kind, side_px):
    """Return a texture set of `kind` as {"albedo", "normal", "rough"}: 8-bit images."""
    colour, height, roughness, strength = DRAWERS[kind](side_px)
    return {
        "albedo": _albedo(colour),
        "normal": normal_map(height * strength * side_px / 512.0, 1.0),
        "rough": np.repeat(_bytes(roughness)[..., None], 3, -1),
    }


# ------------------------------------------------------------------------------------ trees
def _broadleaf_crown(rng):
    """Return leaf clusters (x, y, z up, radius) of a broadleaf tree 10 m tall."""
    count = 160
    theta = rng.uniform(0.0, math.tau, count)
    up = rng.uniform(-1.0, 1.0, count)
    reach = rng.uniform(0.55, 1.0, count) ** 0.5
    radius_m = 3.6
    x = np.cos(theta) * np.sqrt(1.0 - up**2) * reach * radius_m
    y = np.sin(theta) * np.sqrt(1.0 - up**2) * reach * radius_m
    z = 6.2 + up * reach * 3.4
    return np.stack([x, y, z, rng.uniform(0.6, 1.1, count)], -1)


def _conifer_crown(rng):
    """Return needle clusters (x, y, z up, radius) of a conifer 14 m tall."""
    count = 220
    z = rng.uniform(1.5, 13.6, count)
    reach = (14.0 - z) / 12.5 * 2.6 * rng.uniform(0.55, 1.0, count)
    theta = rng.uniform(0.0, math.tau, count)
    return np.stack(
        [np.cos(theta) * reach, np.sin(theta) * reach, z, rng.uniform(0.45, 0.8, count)], -1
    )


TREES = {
    # crown, width and height of a view in metres, a view's pixels, trunk height and colours
    "broadleaf": (
        _broadleaf_crown,
        10.0,
        10.0,
        (200, 200),
        3.6,
        (0.03, 0.065, 0.018),
        (0.1, 0.16, 0.045),
    ),
    "conifer": (_conifer_crown, 6.0, 14.0, (96, 224), 1.8, (0.02, 0.06, 0.03), (0.07, 0.14, 0.06)),
}


def tree_atlas(kind):
    """Return a tree's impostor atlas (RGBA, `TREE_VIEWS` views side by side), width and height.

    View k shows the tree seen across the card turned k / TREE_VIEWS of half a turn, lit from
    above and from the left.
    """
    crown, width_m, height_m, (view_px, height_px), trunk_m, dark, light = TREES[kind]
    clusters = crown(np.random.default_rng(81 + TREE_KINDS.index(kind)))
    scale = TREE_SUPERSAMPLING
    views = []
    for view in range(TREE_VIEWS):
        angle = math.pi * view / TREE_VIEWS
        across = clusters[:, 0] * math.cos(angle) + clusters[:, 1] * math.sin(angle)
        depth = -clusters[:, 0] * math.sin(angle) + clusters[:, 1] * math.cos(angle)
        image = Image.new("RGBA", (view_px * scale, height_px * scale), (0, 0, 0, 0))
        pen = ImageDraw.Draw(image)
        px_per_m = view_px * scale / width_m
        trunk_half = 0.16 * px_per_m
        middle = view_px * scale / 2.0
        bottom = height_px * scale
        pen.rectangle(
            [middle - trunk_half, bottom - (trunk_m + 1.0) * px_per_m, middle + trunk_half, bottom],
            fill=(54, 42, 32, 255),
        )
        for index in np.argsort(-depth):
            x, z, radius = across[index], clusters[index, 2], clusters[index, 3]
            lit = 0.5 + 0.25 * (z - 6.0) / 4.0 - 0.15 * x / 4.0 - 0.15 * depth[index] / 4.0
            colour = _albedo(np.array(_mix(dark, light, np.array(lit))))
            centre = (middle + x * px_per_m, bottom - z * px_per_m)
            r = radius * px_per_m
            pen.ellipse(
                [centre[0] - r, centre[1] - r, centre[0] + r, centre[1] + r], fill=(*colour, 255)
            )
        views.append(image.resize((view_px, height_px), Image.Resampling.LANCZOS))
    atlas = Image.new("RGBA", (view_px * TREE_VIEWS, height_px))
    for view, image in enumerate(views):
        atlas.paste(image, (view * view_px, 0))
    pixels = np.asarray(atlas).copy()
    opaque = pixels[..., 3] > 127
    pixels[..., 3] = np.where(opaque, 255, 0)
    # The clear pixels take the leaves' colour, so mipmaps do not darken the crown's rim.
    pixels[~opaque, :3] = pixels[opaque, :3].mean(0).astype(np.uint8)
    return pixels, width_m, height_m
