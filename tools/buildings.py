"""Build a world's buildings closed, from their mapped footprints and the LiDAR.

    python3 tools/buildings.py GLB_OR_DIRECTORY...

checks the `Building_*` meshes of glb files (or of every glb under a directory) and prints how
many are closed solids, and what is wrong with the others.

Each mapped building is built from its footprint alone: the outline cleaned and squared
(footprints.py), the roof shape, eave height and slope the LiDAR surface shows inside it
(building_shapes.py), walls hung from the roof's outline to below the ground, and a floor.
The roofing and its colour are read from the graded photo (roofs.py). A building whose mesh
comes out faulty is built again with a simpler roof, down to a flat one over its bounding
rectangle. `write` puts them into a world glb in place of its `Building_*` meshes:

- walls and floor, drawn with the facade material `M_Facade_<kind>_<tint>`: TEXCOORD_0 is
  (metres along the wall from its corner, 1 - metres above its ground floor) / 3, TEXCOORD_1
  (the wall's top above its ground floor, the wall's length), in metres;
- the roof, drawn with `M_Roof_<roofing>`: TEXCOORD_0 is metres along the eave and up the
  slope, TEXCOORD_1 the distances in metres to two edges of the roof (the smaller of the two,
  where it is drawn, is the distance to the roof's edge), COLOR_0 the roof's albedo (linear
  RGB).

Needs numpy and Pillow.
"""

import math
import sys
import zlib
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import building_shapes
import footprints
import numpy as np
import roofs
import smooth_terrain

BUILDING_MESH_PREFIX = "Building_"
FACADE_MATERIAL_PREFIX = "M_Facade_"
GLTF_ARRAY_BUFFER = 34962

SQUARING_TOLERANCE_M = 0.4  # how far squaring a footprint may move a wall off its mapped line
MIN_AREA_M2 = 8.0
SHED_AREA_M2 = 25.0  # a smaller building's roof is too small for the LiDAR to show its shape
RASTER_EDGE_M = 2.0
ROOF_EDGE_M = 0.7  # the LiDAR this close to a roof's edge mixes roof and ground
MIN_ROOF_SAMPLES = 6
ROOF_TOP_QUANTILE = 0.75
STANDING_HEIGHTS_M = (1.5, 60.0)  # the LiDAR shows a building where its roof stands this high
MIN_WALL_M = 2.2
STOREY_M = 3.0
UNKNOWN_HEIGHT_M = 3.0  # of a building neither the LiDAR nor the map gives a height: one storey
MAPPED_SLOPE = 0.6  # of a roof whose shape the map names and the LiDAR does not show

# OpenStreetMap's roof:shape values, as the shapes of building_shapes.
MAPPED_ROOF_SHAPES = {
    "flat": "flat",
    "gabled": "gable",
    "half-hipped": "gable",
    "gambrel": "gable",
    "saltbox": "gable",
    "hipped": "hip",
    "mansard": "hip",
    "skillion": "skillion",
    "pyramidal": "pyramid",
}
HOUSE_TAGS = {
    "house",
    "residential",
    "detached",
    "semidetached_house",
    "terrace",
    "apartments",
    "bungalow",
    "farm",
    "dormitory",
    "cabin",
}
HALL_TAGS = {
    "industrial",
    "warehouse",
    "commercial",
    "retail",
    "supermarket",
    "hangar",
    "garage",
    "garages",
    "service",
    "roof",
    "shed",
    "barn",
    "farm_auxiliary",
    "manufacture",
}
CONCRETE_TAGS = {
    "stadium",
    "office",
    "public",
    "civic",
    "school",
    "hospital",
    "train_station",
    "transportation",
    "sports_centre",
    "sports_hall",
    "hotel",
    "college",
}
MAPPED_MATERIALS = {
    "brick": "brick",
    "stone": "stone",
    "sandstone": "stone",
    "limestone": "stone",
    "plaster": "plaster",
    "render": "plaster",
    "metal": "metal",
    "steel": "metal",
    "concrete": "concrete",
}
HOUSE_FACADES = ("brick", "brick", "plaster", "plaster", "stone")
HALL_AREA_M2 = 600.0
BLOCK_AREA_M2 = 250.0
BLOCK_HEIGHT_M = 9.0


@dataclass
class Surface:
    """The LiDAR surface model: heights above the world's origin, rows running south.

    `west_m` and `north_m` are the raster's edges, east and north of the world's origin.
    """

    heights_m: np.ndarray
    west_m: float
    north_m: float
    cell_m: float

    def covers(self, ring):
        """Tell whether a ring lies inside the raster, away from its edge."""
        rows, columns = self.heights_m.shape
        low, high = ring.min(0), ring.max(0)
        return bool(
            low[0] > self.west_m + RASTER_EDGE_M
            and high[0] < self.west_m + columns * self.cell_m - RASTER_EDGE_M
            and high[1] < self.north_m - RASTER_EDGE_M
            and low[1] > self.north_m - rows * self.cell_m + RASTER_EDGE_M
        )

    def cells(self, low, high):
        """Return the cell centres (K, 2) between two corners and the surface's height there.

        Each height is the median of the cell and its neighbours: an aerial or a bird is not
        the roof.
        """
        rows, columns = self.heights_m.shape
        first_column = max(int(math.floor((low[0] - self.west_m) / self.cell_m)), 1)
        last_column = min(int(math.ceil((high[0] - self.west_m) / self.cell_m)), columns - 2)
        first_row = max(int(math.floor((self.north_m - high[1]) / self.cell_m)), 1)
        last_row = min(int(math.ceil((self.north_m - low[1]) / self.cell_m)), rows - 2)
        if last_column < first_column or last_row < first_row:
            return np.zeros((0, 2)), np.zeros(0)
        around = [
            self.heights_m[
                first_row + down : last_row + 1 + down,
                first_column + right : last_column + 1 + right,
            ]
            for down in (-1, 0, 1)
            for right in (-1, 0, 1)
        ]
        heights_m = np.median(np.stack(around), axis=0)
        east = self.west_m + (np.arange(first_column, last_column + 1) + 0.5) * self.cell_m
        north = self.north_m - (np.arange(first_row, last_row + 1) + 0.5) * self.cell_m
        east, north = np.meshgrid(east, north)
        return np.column_stack([east.ravel(), north.ravel()]), heights_m.ravel()


def read_surface(tif_path, origin_m):
    """Return the Surface of a LiDAR surface model GeoTIFF about `origin_m` (east, north, up)."""
    heights_m, is_valid, west_m, north_m, cell_m = smooth_terrain.read_height_map(tif_path)
    heights_m = np.where(is_valid, heights_m - origin_m[2], np.nan)
    return Surface(heights_m, west_m - origin_m[0], north_m - origin_m[1], cell_m)


@dataclass
class Building:
    """One building ready to be written: its mesh, roof shape, roofing, colour and facade."""

    shell: building_shapes.Shell
    shape: str
    rings: list
    roofing: str
    albedo: np.ndarray
    facade: str


def facade_kind(tags, area_m2, height_m, pick):
    """Return the facade a building of these map tags, footprint area and height is given.

    `pick` is a whole number that is the building's own, choosing among what fits a house.
    """
    mapped = MAPPED_MATERIALS.get(tags.get("building:material", ""))
    if mapped is not None:
        return mapped
    kind = tags.get("building", "yes")
    if kind in CONCRETE_TAGS:
        return "concrete"
    if kind in HALL_TAGS or (kind not in HOUSE_TAGS and area_m2 > HALL_AREA_M2):
        return "metal"
    if kind not in HOUSE_TAGS and area_m2 > BLOCK_AREA_M2 and height_m > BLOCK_HEIGHT_M:
        return "concrete"
    return HOUSE_FACADES[pick % len(HOUSE_FACADES)]


def _facade(mapped_facades, facade_tints, outline, tags, height_m):
    """Return a building's facade material: the one it had, or one its map tags call for."""
    for centre, material in mapped_facades:
        if footprints.contains(outline, centre):
            return material
    pick = zlib.crc32(np.round(outline.mean(0), 1).tobytes())
    kind = facade_kind(tags, footprints.signed_area_m2(outline), height_m, pick)
    return f"{FACADE_MATERIAL_PREFIX}{kind}_{(pick // 7) % facade_tints[kind]}"


def _mapped_height_m(tags):
    """Return the height the map gives a building the LiDAR does not show."""
    for key, scale, extra in (("height", 1.0, 0.0), ("building:levels", STOREY_M, 1.0)):
        try:
            return float(tags[key].split()[0]) * scale + extra
        except (KeyError, ValueError, IndexError):
            continue
    return UNKNOWN_HEIGHT_M


def _pitch_deg(roof):
    """Return the mean pitch of a roof's triangles, weighted by their area."""
    normals = np.cross(roof[:, 1] - roof[:, 0], roof[:, 2] - roof[:, 0])
    areas = np.maximum(np.linalg.norm(normals, axis=1), 1e-12)
    pitches = np.degrees(np.arccos(np.clip(np.abs(normals[:, 2]) / areas, 0.0, 1.0)))
    return float((pitches * areas).sum() / areas.sum())


def _edge_distance_m(points, rings):
    return np.min([footprints.distance_to_ring_m(points, ring) for ring in rings], axis=0)


def _roof_fit(candidates, rings, tags, surface, ground_m):
    """Return the Fit of a footprint's roof and the LiDAR cells on it.

    The fit is what the LiDAR shows, or what the map says where the LiDAR shows no building.
    """
    named = MAPPED_ROOF_SHAPES.get(tags.get("roof:shape", ""))
    if not any(shape.name == named for shape in candidates):
        named = None
    flat = candidates[0]
    under_walls_m = ground_m(np.vstack(rings))
    ground_low_m, ground_top_m = float(under_walls_m.min()), float(under_walls_m.max())
    cells, heights_m = surface.cells(rings[0].min(0), rings[0].max(0))
    known = ~np.isnan(heights_m) & ~np.isnan(building_shapes.rise_at(flat, cells))
    cells, heights_m = cells[known], heights_m[known]
    top_m = float(np.quantile(heights_m, ROOF_TOP_QUANTILE)) - ground_low_m if len(cells) else 0.0
    if not STANDING_HEIGHTS_M[0] <= top_m <= STANDING_HEIGHTS_M[1]:
        shape = next((shape for shape in candidates if shape.name == named), flat)
        slope = 0.0 if shape is flat else MAPPED_SLOPE / building_shapes.steepest(shape)
        return building_shapes.Fit(shape, ground_top_m + _mapped_height_m(tags), slope, 0.0), cells
    if footprints.signed_area_m2(rings[0]) < SHED_AREA_M2:
        named = "flat"
    inner = _edge_distance_m(cells, rings) >= ROOF_EDGE_M
    if inner.sum() < MIN_ROOF_SAMPLES:
        inner[:] = True
    fit = building_shapes.fitted(candidates, cells[inner], heights_m[inner], named)
    short_m = ground_m(fit.shape.points) + MIN_WALL_M - fit.heights_m()
    fit.eave_m += max(float(short_m.max()), 0.0)
    return fit, cells


def _bounding_rectangle(outline):
    """Return the rectangle along a footprint's main direction that holds it."""
    angle = footprints.main_direction_rad(outline)
    along = np.array([math.cos(angle), math.sin(angle)])
    across = np.array([-along[1], along[0]])
    low, high = (outline @ along).min(), (outline @ along).max()
    near, far = (outline @ across).min(), (outline @ across).max()
    return np.array(
        [
            low * along + near * across,
            high * along + near * across,
            high * along + far * across,
            low * along + far * across,
        ]
    )


def _closed_shell(rings, tags, surface, ground_m):
    """Return (Shell, Fit, LiDAR cells on the roof) of a footprint, or None when none closes.

    A shape whose mesh is faulty is dropped and the others fitted again, down to the flat one.
    """
    try:
        candidates = building_shapes.shapes(rings[0], rings[1:])
    except footprints.FootprintError:
        return None
    while True:
        fit, cells = _roof_fit(candidates, rings, tags, surface, ground_m)
        try:
            foot_m = building_shapes.foot_height_m(fit.shape, ground_m)
            shell = building_shapes.shell(fit.shape, fit.heights_m(), foot_m, ground_m)
            fault = building_shapes.faults(shell.triangles())
        except footprints.FootprintError as error:
            fault = str(error)
        if fault is None:
            return shell, fit, cells
        if fit.shape is candidates[0]:
            return None
        candidates = [shape for shape in candidates if shape is not fit.shape]


def build_one(area, surface, ground_m, sample_albedo, mapped_facades, facade_tints):
    """Return the Building of one mapped area and how it was made, or (None, why not)."""
    outline = footprints.regularised(area.points, SQUARING_TOLERANCE_M)
    if outline is None or footprints.signed_area_m2(outline) < MIN_AREA_M2:
        return None, "too small"
    if not surface.covers(outline):
        return None, "off the LiDAR"
    holes = [footprints.regularised(hole, SQUARING_TOLERANCE_M) for hole in area.holes]
    rings = [outline] + [hole[::-1].copy() for hole in holes if hole is not None]
    made = "as mapped"
    closed = _closed_shell(rings, area.tags, surface, ground_m)
    if closed is None and len(rings) > 1:
        rings, made = rings[:1], "without its courtyards"
        closed = _closed_shell(rings, area.tags, surface, ground_m)
    if closed is None:
        rings, made = [_bounding_rectangle(outline)], "as a box"
        closed = _closed_shell(rings, area.tags, surface, ground_m)
    if closed is None:
        return None, "no closed mesh"
    shell, fit, cells = closed
    if len(cells) == 0:
        cells = fit.shape.points
    edge_m = _edge_distance_m(cells, rings)
    inside = edge_m >= min(roofs.LEAN_MARGIN_M, float(np.quantile(edge_m, 0.5)))
    colour = roofs.lit_colour(sample_albedo(cells[inside]))
    albedo = colour * min(1.0, roofs.BRIGHTEST_ROOF / max(float(colour.max()), 1e-6))
    area_m2 = sum(footprints.signed_area_m2(ring) for ring in rings)
    roofing = roofs.classify_roof(albedo, _pitch_deg(shell.roof), area_m2)
    height_m = fit.eave_m - float(ground_m(rings[0]).min())
    facade = _facade(mapped_facades, facade_tints, rings[0], area.tags, height_m)
    return Building(shell, fit.shape.name, rings, roofing, albedo, facade), made


def build(areas, surface, ground_m, sample_albedo, mapped_facades, facade_tints):
    """Return the Buildings of the mapped `areas` and a count of how each was made.

    `surface` is the LiDAR Surface, `ground_m(points)` the terrain's height and
    `sample_albedo(points)` the graded photo's colour at (K, 2) points east and north of the
    world's origin; `mapped_facades` are (a point inside a footprint, its facade material)
    and `facade_tints` how many tints each facade kind has. Grandstands are not built here.
    """
    built, made = [], Counter()
    seen = set()
    for area in areas:
        if "building" not in area.tags or area.tags["building"] == "grandstand":
            continue
        key = np.round(area.points, 2).tobytes()
        if key in seen:
            continue
        seen.add(key)
        building, how = build_one(
            area, surface, ground_m, sample_albedo, mapped_facades, facade_tints
        )
        made[how] += 1
        if building is not None:
            built.append(building)
    return built, made


# -------------------------------------------------------------------------------------- glb
def _godot(positions):
    """Return (east, north, up) positions in the world's frame: x east, y up, z south."""
    return np.column_stack([positions[:, 0], positions[:, 2], -positions[:, 1]])


def _face_normals(triangles):
    normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    return np.repeat(normals, 3, axis=0)


def primitives(building):
    """Return a building's (facade attributes, roof attributes), a vertex per triangle corner."""
    shell = building.shell
    solid = np.concatenate([shell.walls, shell.floor])
    blank = np.zeros((len(shell.floor) * 3, 2))
    facade = {
        "POSITION": _godot(solid.reshape(-1, 3)),
        "NORMAL": _godot(_face_normals(solid)),
        "TEXCOORD_0": np.concatenate([shell.wall_uv.reshape(-1, 2), blank]),
        "TEXCOORD_1": np.concatenate([shell.wall_uv2.reshape(-1, 2), blank]),
    }
    corners = shell.roof.reshape(-1, 3)
    roof = {
        "POSITION": _godot(corners),
        "NORMAL": _godot(_face_normals(shell.roof)),
        "TEXCOORD_0": building_shapes.roof_rows(shell.roof).reshape(-1, 2),
        "TEXCOORD_1": shell.roof_edges_m.reshape(-1, 2),
        "COLOR_0": np.tile(np.append(building.albedo, 1.0), (len(corners), 1)),
    }
    return facade, roof


def _append_accessor(gltf, replaced_views, elements):
    """Add `elements` to the glb as a new buffer view and accessor; return the accessor."""
    elements = np.ascontiguousarray(elements, np.float32)
    gltf["bufferViews"].append(
        {"buffer": 0, "byteLength": elements.nbytes, "target": GLTF_ARRAY_BUFFER}
    )
    replaced_views[len(gltf["bufferViews"]) - 1] = elements.tobytes()
    accessor = {
        "bufferView": len(gltf["bufferViews"]) - 1,
        "componentType": smooth_terrain.GLTF_FLOAT,
        "count": len(elements),
        "type": f"VEC{elements.shape[1]}",
    }
    if elements.shape[1] == 3:
        accessor["min"] = [float(bound) for bound in elements.min(axis=0)]
        accessor["max"] = [float(bound) for bound in elements.max(axis=0)]
    gltf["accessors"].append(accessor)
    return len(gltf["accessors"]) - 1


def _material(gltf, name):
    """Return the index of the glb's material `name`, adding it when new."""
    for index, material in enumerate(gltf["materials"]):
        if material["name"] == name:
            return index
    gltf["materials"].append(
        {"name": name, "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0.8}}
    )
    return len(gltf["materials"]) - 1


def _building_nodes(gltf):
    return [
        node
        for node in gltf["nodes"]
        if "mesh" in node and gltf["meshes"][node["mesh"]]["name"].startswith(BUILDING_MESH_PREFIX)
    ]


def mapped_facades(glb_path):
    """Return (a point inside the footprint, facade material) of a glb's `Building_*` meshes.

    The point is the middle of the building's walls, east and north of the world's origin.
    """
    gltf, binary = smooth_terrain.read_glb(glb_path)
    names = [material["name"] for material in gltf["materials"]]
    found = []
    for node in _building_nodes(gltf):
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            if names[primitive["material"]].startswith(FACADE_MATERIAL_PREFIX):
                walls = smooth_terrain.accessor_array(
                    gltf, binary, primitive["attributes"]["POSITION"]
                ).astype(np.float64)
                middle = (walls.min(0) + walls.max(0)) / 2.0
                found.append((np.array([middle[0], -middle[2]]), names[primitive["material"]]))
                break
    return found


def write(glb_path, buildings):
    """Rewrite the glb at `glb_path` with `buildings` in place of its `Building_*` meshes."""
    gltf, binary = smooth_terrain.read_glb(glb_path)
    replaced_views = {}
    for node in _building_nodes(gltf):
        del node["mesh"]
    for index, building in enumerate(buildings):
        written = []
        for attributes, material in zip(
            primitives(building), (building.facade, f"M_Roof_{building.roofing}"), strict=True
        ):
            written.append(
                {
                    "attributes": {
                        attribute: _append_accessor(gltf, replaced_views, elements)
                        for attribute, elements in attributes.items()
                    },
                    "material": _material(gltf, material),
                }
            )
        name = f"{BUILDING_MESH_PREFIX}{index:04d}"
        gltf["meshes"].append({"name": name, "primitives": written})
        gltf["nodes"].append({"name": name, "mesh": len(gltf["meshes"]) - 1})
        gltf["scenes"][gltf.get("scene", 0)]["nodes"].append(len(gltf["nodes"]) - 1)
    smooth_terrain.write_glb(glb_path, gltf, binary, replaced_views)


# ------------------------------------------------------------------------------------ audit
def audit(glb_path):
    """Return {mesh name: fault or None} for the `Building_*` meshes of a glb.

    A fault is what building_shapes.faults finds in the mesh's triangles, all primitives
    together.
    """
    gltf, binary = smooth_terrain.read_glb(glb_path)
    found = {}
    for node in _building_nodes(gltf):
        mesh = gltf["meshes"][node["mesh"]]
        triangles = []
        for primitive in mesh["primitives"]:
            positions = smooth_terrain.accessor_array(
                gltf, binary, primitive["attributes"]["POSITION"]
            ).astype(np.float64)
            if "indices" in primitive:
                indices = smooth_terrain.accessor_array(gltf, binary, primitive["indices"])
                positions = positions[indices.reshape(-1)]
            triangles.append(positions.reshape(-1, 3, 3))
        found[mesh["name"]] = building_shapes.faults(np.concatenate(triangles))
    return found


def main(paths):
    """Print how many buildings of the glb files at `paths` are closed, and the faults."""
    for path in paths:
        files = sorted(path.rglob("*.glb")) if path.is_dir() else [path]
        found = {}
        for file in files:
            found.update({f"{file.name} {name}": fault for name, fault in audit(file).items()})
        faulty = {name: fault for name, fault in found.items() if fault is not None}
        print(f"{path}: {len(found) - len(faulty)} of {len(found)} buildings are closed solids")
        kinds = Counter(fault.split(" ", 1)[1] for fault in faulty.values() if " " in fault)
        for kind, count in kinds.most_common():
            print(f"  {count} with {kind}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main([Path(argument) for argument in sys.argv[1:]])
