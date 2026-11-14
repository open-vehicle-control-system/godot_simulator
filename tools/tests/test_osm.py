# ruff: noqa: D102
"""Tests of the OpenStreetMap reader: projection, ways and areas."""

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import osm

ORIGIN_LATITUDE_DEG = 50.797815
ORIGIN_LONGITUDE_DEG = 4.359215833
EXTRACT = """<?xml version='1.0' encoding='utf-8'?>
<osm version="0.6">
 <node id="1" lat="50.797815" lon="4.359215833" />
 <node id="2" lat="50.798815" lon="4.359215833" />
 <node id="3" lat="50.798815" lon="4.360215833" />
 <node id="4" lat="50.797815" lon="4.360215833" />
 <node id="5" lat="50.798815" lon="4.359215833">
  <tag k="highway" v="give_way" /><tag k="direction" v="forward" /></node>
 <way id="10"><nd ref="1" /><nd ref="2" /><nd ref="99" />
  <tag k="highway" v="service" /><tag k="surface" v="gravel" /></way>
 <way id="11"><nd ref="1" /><nd ref="2" /><nd ref="3" /><nd ref="4" /><nd ref="1" />
  <tag k="amenity" v="parking" /></way>
 <way id="12"><nd ref="1" /><nd ref="2" /><nd ref="3" /></way>
 <way id="13"><nd ref="1" /><nd ref="4" /><nd ref="3" /></way>
 <way id="14"><nd ref="3" /><nd ref="4" /><tag k="highway" v="footway" /></way>
 <relation id="20"><member type="way" ref="12" role="outer" />
  <member type="way" ref="13" role="outer" />
  <tag k="type" v="multipolygon" /><tag k="amenity" v="parking" /><tag k="name" v="P1" />
 </relation>
</osm>
"""


def extract(origin=(649328.0, 665262.0)):
    """Return EXTRACT as osm.read gives it."""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "area.osm"
        path.write_text(EXTRACT)
        return osm.read(path, origin)


class LambertTest(unittest.TestCase):
    """WGS84 positions in Belgian Lambert 2008."""

    def test_the_projection_origin_is_at_the_false_easting_and_northing(self):
        easting, northing = osm.lambert_2008(ORIGIN_LATITUDE_DEG, ORIGIN_LONGITUDE_DEG)

        self.assertAlmostEqual(float(easting), 649328.0, delta=0.01)
        self.assertAlmostEqual(float(northing), 665262.0, delta=0.01)

    def test_brussels_is_where_the_national_grid_puts_it(self):
        # The Atomium: 50.894941 N, 4.341547 E.
        easting, northing = osm.lambert_2008(50.894941, 4.341547)

        self.assertAlmostEqual(float(easting), 648085.0, delta=3.0)
        self.assertAlmostEqual(float(northing), 676067.0, delta=3.0)


class ReadTest(unittest.TestCase):
    """Ways and areas of an extract."""

    def test_a_way_is_in_metres_from_the_origin(self):
        way = extract().highways({"service"})[0]

        self.assertEqual(way.tags["surface"], "gravel")
        np.testing.assert_allclose(way.points[0], [0.0, 0.0], atol=0.01)
        self.assertAlmostEqual(way.points[1][0], 0.0, delta=0.01)
        self.assertAlmostEqual(way.points[1][1], 111.25, delta=0.1)

    def test_positions_are_relative_to_the_origin(self):
        way = extract((649328.0 + 10.0, 665262.0 - 5.0)).highways({"service"})[0]

        np.testing.assert_allclose(way.points[0], [-10.0, 5.0], atol=0.01)

    def test_a_node_outside_the_extract_is_left_out(self):
        self.assertEqual(extract().highways({"service"})[0].nodes, ["1", "2"])

    def test_highways_are_selected_by_kind(self):
        self.assertEqual(len(extract().highways({"footway", "service"})), 2)
        self.assertEqual(len(extract().highways({"primary"})), 0)

    def test_a_closed_way_is_an_area(self):
        parkings = extract().parkings()

        self.assertEqual(len(parkings[0].points), 4)

    def test_a_multipolygon_joins_its_outer_ways_into_a_ring(self):
        named = [area for area in extract().parkings() if area.tags.get("name") == "P1"]

        self.assertEqual(len(named), 1)
        self.assertEqual(len(named[0].points), 4)


if __name__ == "__main__":
    unittest.main()


class NodesTest(unittest.TestCase):
    """Tagged nodes of an extract."""

    def test_a_tagged_node_is_read_with_its_tags_and_position(self):
        nodes = extract().nodes

        self.assertEqual([node.identifier for node in nodes], ["5"])
        self.assertEqual(nodes[0].tags, {"highway": "give_way", "direction": "forward"})
        np.testing.assert_allclose(nodes[0].point, [0.0, 111.25], atol=0.1)
