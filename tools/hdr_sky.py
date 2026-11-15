"""Read an equirectangular Radiance HDR sky and find where its sun is.

The panorama's rows run from straight up to straight down; the sun is its brightest spot.
Needs numpy.
"""

import numpy as np


def read(path):
    """Return a Radiance HDR file's pixels as linear RGB floats, (rows, columns, 3), top first."""
    content = path.read_bytes()
    header_end = content.index(b"\n\n") + 2
    size_end = content.index(b"\n", header_end)
    size = content[header_end:size_end].split()
    if size[0] != b"-Y" or size[2] != b"+X":
        raise ValueError(f"{path}: only -Y H +X W panoramas are read")
    height, width = int(size[1]), int(size[3])
    data = np.frombuffer(content, np.uint8, offset=size_end + 1)
    rgbe = np.empty((height, width, 4), np.uint8)
    at = 0
    for row in range(height):
        if width >= 8 and width < 32768 and data[at] == 2 and data[at + 1] == 2:
            at += 4
            for channel in range(4):
                column = 0
                while column < width:
                    count = int(data[at])
                    if count > 128:
                        count -= 128
                        rgbe[row, column : column + count, channel] = data[at + 1]
                        at += 2
                    else:
                        rgbe[row, column : column + count, channel] = data[at + 1 : at + 1 + count]
                        at += 1 + count
                    column += count
        else:
            rgbe[row] = data[at : at + width * 4].reshape(width, 4)
            at += width * 4
    scale = np.where(rgbe[..., 3] > 0, np.ldexp(1.0, rgbe[..., 3].astype(np.int32) - 136), 0.0)
    return (rgbe[..., :3] * scale[..., None]).astype(np.float32)


def sun_elevation_deg(image):
    """Return the elevation above the horizon of the panorama's brightest pixel's centre."""
    row, _ = np.unravel_index(np.argmax(image.sum(-1)), image.shape[:2])
    return 90.0 - (row + 0.5) * 180.0 / image.shape[0]
