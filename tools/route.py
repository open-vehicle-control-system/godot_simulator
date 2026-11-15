"""A track pack's route: the track's centre line, which --follow-route drives.

route.json holds `points_m`, the line's points in the pack's frame (ROS: x, y, z up, metres),
and `closed`, true for a circuit, whose last point joins its first.
"""

import json

FILE_NAME = "route.json"


def write(directory, points_m, closed):
    """Write route.json into `directory` from `points_m` ([x, y, z] each); return its name."""
    route = {
        "closed": bool(closed),
        "points_m": [[round(float(value), 2) for value in point] for point in points_m],
    }
    (directory / FILE_NAME).write_text(json.dumps(route, separators=(",", ":")) + "\n")
    return FILE_NAME
