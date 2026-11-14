"""Read an OpenStreetMap extract: its tagged nodes, ways and areas, in a map frame.

Positions are metres east and north of an origin given in Belgian Lambert 2008 (EPSG:3812),
the frame of a circuit's road sections.
"""

import math
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass, field

import numpy as np

# Belgian Lambert 2008: a Lambert conformal conic projection of the GRS80 ellipsoid.
SEMI_MAJOR_AXIS_M = 6378137.0
FLATTENING = 1.0 / 298.257222101
STANDARD_PARALLELS_DEG = (49.0 + 50.0 / 60.0, 51.0 + 10.0 / 60.0)
ORIGIN_LATITUDE_DEG = 50.0 + 47.0 / 60.0 + 52.134 / 3600.0
ORIGIN_LONGITUDE_DEG = 4.0 + 21.0 / 60.0 + 33.177 / 3600.0
FALSE_EASTING_M = 649328.0
FALSE_NORTHING_M = 665262.0
ECCENTRICITY = math.sqrt(FLATTENING * (2.0 - FLATTENING))


def _conformal(latitude_rad):
    sine = np.sin(latitude_rad)
    scale = np.cos(latitude_rad) / np.sqrt(1.0 - (ECCENTRICITY * sine) ** 2)
    stretch = np.tan(math.pi / 4.0 - latitude_rad / 2.0) / (
        (1.0 - ECCENTRICITY * sine) / (1.0 + ECCENTRICITY * sine)
    ) ** (ECCENTRICITY / 2.0)
    return scale, stretch


def lambert_2008(latitude_deg, longitude_deg):
    """Return the Belgian Lambert 2008 easting and northing of WGS84 positions."""
    parallels = np.radians(STANDARD_PARALLELS_DEG)
    scales, stretches = _conformal(parallels)
    cone = math.log(scales[0] / scales[1]) / math.log(stretches[0] / stretches[1])
    reach = SEMI_MAJOR_AXIS_M * scales[0] / (cone * stretches[0] ** cone)
    _, origin_stretch = _conformal(math.radians(ORIGIN_LATITUDE_DEG))
    _, stretch = _conformal(np.radians(latitude_deg))
    radius = reach * stretch**cone
    turn = cone * np.radians(np.asarray(longitude_deg) - ORIGIN_LONGITUDE_DEG)
    easting = FALSE_EASTING_M + radius * np.sin(turn)
    northing = FALSE_NORTHING_M + reach * origin_stretch**cone - radius * np.cos(turn)
    return easting, northing


@dataclass
class Node:
    """A tagged point: its id and its position (metres east and north)."""

    identifier: str
    tags: dict
    point: np.ndarray


@dataclass
class Way:
    """A tagged line: its node ids and their positions (N x 2, metres east and north)."""

    tags: dict
    nodes: list
    points: np.ndarray


@dataclass
class Area:
    """A tagged outline: a closed ring of positions, its first point not repeated."""

    tags: dict
    points: np.ndarray


@dataclass
class Extract:
    """What an extract holds: every tagged node, every tagged way, and every tagged area."""

    nodes: list = field(default_factory=list)
    ways: list = field(default_factory=list)
    areas: list = field(default_factory=list)

    def highways(self, kinds):
        """Return the ways whose `highway` is one of `kinds`."""
        return [way for way in self.ways if way.tags.get("highway") in kinds]

    def parkings(self):
        """Return the areas tagged `amenity=parking`."""
        return [area for area in self.areas if area.tags.get("amenity") == "parking"]


def _tags(element):
    return {tag.get("k"): tag.get("v") for tag in element.findall("tag")}


def _rings(member_ways):
    """Return the closed rings the node lists of `member_ways` join into."""
    open_runs = [list(nodes) for nodes in member_ways if len(nodes) >= 2]
    rings = []
    while open_runs:
        run = open_runs.pop()
        while run[0] != run[-1]:
            joining = next((other for other in open_runs if run[-1] in (other[0], other[-1])), None)
            if joining is None:
                break
            open_runs.remove(joining)
            run += joining[1:] if joining[0] == run[-1] else joining[-2::-1]
        if run[0] == run[-1] and len(run) >= 4:
            rings.append(run)
    return rings


def read(path, origin):
    """Return the Extract of the OSM XML file at `path`, relative to `origin` (east, north)."""
    root = ElementTree.parse(path).getroot()
    identifiers, latitudes, longitudes, tagged = [], [], [], {}
    for node in root.iter("node"):
        identifiers.append(node.get("id"))
        if node.find("tag") is not None:
            tagged[node.get("id")] = _tags(node)
        latitudes.append(float(node.get("lat")))
        longitudes.append(float(node.get("lon")))
    easting, northing = lambert_2008(np.array(latitudes), np.array(longitudes))
    position = dict(
        zip(identifiers, zip(easting - origin[0], northing - origin[1], strict=True), strict=True)
    )

    def points(nodes):
        return np.array([position[node] for node in nodes], np.float64).reshape(-1, 2)

    extract = Extract()
    extract.nodes = [
        Node(identifier, tags, np.array(position[identifier], np.float64))
        for identifier, tags in tagged.items()
    ]
    node_lists = {}
    for way in root.iter("way"):
        nodes = [ref.get("ref") for ref in way.findall("nd") if ref.get("ref") in position]
        node_lists[way.get("id")] = nodes
        tags = _tags(way)
        if not tags or len(nodes) < 2:
            continue
        extract.ways.append(Way(tags, nodes, points(nodes)))
        if nodes[0] == nodes[-1] and len(nodes) >= 4:
            extract.areas.append(Area(tags, points(nodes[:-1])))
    for relation in root.iter("relation"):
        tags = _tags(relation)
        if tags.get("type") != "multipolygon":
            continue
        outers = [
            node_lists[member.get("ref")]
            for member in relation.findall("member")
            if member.get("type") == "way"
            and member.get("role") in ("outer", "")
            and member.get("ref") in node_lists
        ]
        for ring in _rings(outers):
            extract.areas.append(Area(tags, points(ring[:-1])))
    return extract
