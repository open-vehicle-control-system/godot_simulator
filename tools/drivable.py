"""Tell where vehicles drive, so nothing is stood there: no tree, no sign, no pole.

LiDAR crown peaks fall over the asphalt where a crown overhangs a road; a trunk there would
stop the vehicle on the road. The drivable ground is the roads (a lap, the surveyed roads
around it) as strips along their sections, and parking lots and yards as a raster of the
distance to their edge. Positions are metres east and north, as osm.py reads them.
"""

import numpy as np

MARGIN_M = 0.5  # how far beyond a drivable surface's edge nothing stands either


class Drivable:
    """The ground vehicles drive on, widened by MARGIN_M."""

    def __init__(self):
        """Start with no drivable ground."""
        self._strips = []
        self._rasters = []

    def add_strip(self, sections, left_m, right_m):
        """Add a road: from `left_m` left of its sections' centreline to `right_m` right.

        `sections` holds `x`, `y` and the unit tangent `tx`, `ty` per section; the edges are
        per section, or one value.
        """
        x, y, tx, ty = (np.asarray(sections[key], np.float64) for key in ("x", "y", "tx", "ty"))
        left_m = np.broadcast_to(np.asarray(left_m, np.float64), x.shape)
        right_m = np.broadcast_to(np.asarray(right_m, np.float64), x.shape)
        spacing_m = float(np.median(np.hypot(np.diff(x), np.diff(y)))) if len(x) > 1 else 1.0
        self._strips.append((x, y, tx, ty, left_m, right_m, spacing_m))

    def add_raster(self, edge_m, west_m, north_m, cell_m):
        """Add surfaces as a raster of the distance to their edge, negative inside them.

        The raster's first cell has its corner at (`west_m`, `north_m`); rows run south.
        """
        self._rasters.append((edge_m, west_m, north_m, cell_m))

    def covers(self, x, y):
        """Return which positions are on drivable ground or within MARGIN_M of it."""
        x, y = np.atleast_1d(np.asarray(x, np.float64)), np.atleast_1d(np.asarray(y, np.float64))
        covered = np.zeros(x.shape, bool)
        for strip_x, strip_y, tx, ty, left_m, right_m, spacing_m in self._strips:
            reach_m = max(left_m.max(), right_m.max()) + MARGIN_M + spacing_m
            near = np.flatnonzero(
                (x > strip_x.min() - reach_m)
                & (x < strip_x.max() + reach_m)
                & (y > strip_y.min() - reach_m)
                & (y < strip_y.max() + reach_m)
            )
            if not len(near):
                continue
            east = x[near, None] - strip_x[None, :]
            north = y[near, None] - strip_y[None, :]
            nearest = np.hypot(east, north).argmin(1)
            east, north = east[np.arange(len(near)), nearest], north[np.arange(len(near)), nearest]
            along = east * tx[nearest] + north * ty[nearest]
            right = east * ty[nearest] - north * tx[nearest]
            covered[near] |= (
                (np.abs(along) <= spacing_m / 2.0 + MARGIN_M)
                & (right <= right_m[nearest] + MARGIN_M)
                & (right >= -left_m[nearest] - MARGIN_M)
            )
        for edge_m, west_m, north_m, cell_m in self._rasters:
            rows = np.floor((north_m - y) / cell_m).astype(int)
            columns = np.floor((x - west_m) / cell_m).astype(int)
            inside = (rows >= 0) & (rows < edge_m.shape[0])
            inside &= (columns >= 0) & (columns < edge_m.shape[1])
            covered[inside] |= edge_m[rows[inside], columns[inside]] <= MARGIN_M
        return covered
