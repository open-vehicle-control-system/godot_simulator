"""Package the Godot experiment's outputs as local packs, until the builders are ported.

    python3 tools/pack_experiment.py EXPERIMENT_DIR OUT_DIR [CIRCUIT...]

EXPERIMENT_DIR is the experiment's checkout (its data/ holds the circuits and cars). Each pack
in OUT_DIR links to the experiment's large files instead of copying them, so the packs are for
local use only. A circuit's world is the experiment's with its terrain rebuilt smooth from the
LiDAR ground model (smooth_terrain.py); its surface maps and road lines are derived from its
orthophoto (track_surfaces.py), as are the roads and parking lots OpenStreetMap maps around
it (secondary_roads.py, parking_lots.py); its buildings are built closed from their mapped
footprints and the LiDAR surface model (buildings.py); its road signs stand where the map and
the highway code put them (road_signs.py), its decals lie where the lap, the photo and the map
are evidence for them (road_decals.py), and no tree stands on a road (drivable.py); the
whole is cut into the pack's tiles (track_tiles.py), the world it is cut from kept in
OUT_DIR/../work. Its
CC0 texture sets are downloaded once into OUT_DIR/../textures (fetch_textures.py) and
compressed there with Godot's encoders (compress_textures.gd, run with the Godot named by
the GODOT environment variable). The experiment's
frames are Godot's (+X left, +Y up, +Z forward); pack.json takes ROS ones (x forward, y left, z up).

Needs numpy and Pillow, and Godot 4.6 to compress the textures.
"""

import io
import json
import math
import os
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path

import buildings
import drivable
import fetch_textures
import ground_classes
import numpy as np
import osm
import parking_lots
import road_decals
import road_markings
import road_signs
import roofs
import secondary_roads
import sign_faces
import smooth_terrain
import track_surfaces
import track_tiles
from PIL import Image

WALLONIA_ATTRIBUTION = [
    "Service public de Wallonie: LiDAR 2021-2022 and orthophotos 2026, CC-BY 4.0",
    "OpenStreetMap contributors, ODbL 1.0",
    "Poly Haven: sky kloofendal_48d_partly_cloudy_puresky, CC0",
    "Poly Haven: models fir_tree_01, pine_tree_01 and jacaranda_tree, drawn as impostors, CC0",
]
# `trees_drawn_m`: how far trees are drawn one by one before the canopy stands for them;
# further in open country, where a lone tree has no canopy to become. `visibility_m`: how far
# one sees through the haze.
CIRCUITS = {
    "spa": {
        "name": "Spa-Francorchamps",
        "build": "Spa",
        "trees_drawn_m": 600.0,
        "visibility_m": 16000.0,
    },
    "mettet": {
        "name": "Circuit Jules Tacheny, Mettet",
        "build": "Mettet",
        "trees_drawn_m": 700.0,
        "visibility_m": 16000.0,
    },
}
# The mean of the tints the simulator gives trees (red, green, blue).
MEAN_TREE_TINT = (0.95, 0.95, 0.9025)
# The orthophotos' shadows fall to the north-west.
SUN = {"azimuth_deg": 45.0, "elevation_deg": 40.0}
# The ground layers, in the order of ground_classes.LAYERS and SURVEYED_LAYERS: texture set,
# the width it covers and how far it takes the photo's colour.
GROUND_LAYERS = [
    ("ambientcg:Grass004", 2.5, 0.75),
    ("ambientcg:Grass001", 3.0, 0.75),
    ("polyhaven:grass_ground", 3.0, 0.8),
    ("polyhaven:brown_mud_dry", 2.5, 0.85),
    ("polyhaven:gravelly_sand", 2.0, 0.9),
    ("polyhaven:asphalt_track", 2.0, 1.0),
    ("polyhaven:asphalt_04", 3.0, 1.0),
    ("polyhaven:forrest_ground_01", 3.0, 0.35),
    ("polyhaven:brushed_concrete", 3.0, 1.0),
    ("polyhaven:concrete_pavers", 2.0, 1.0),
]
# The layers laid as slabs, and the slabs' size.
LAYER_JOINTS_M = {ground_classes.CONCRETE: 5.0}
# How far from the lap a road is still part of the circuit's surroundings.
ROADS_NEAR_LAP_M = 250.0
# Public roads are followed further, to the junctions the circuit's access roads lead to.
PUBLIC_ROADS_NEAR_LAP_M = 450.0
# The LiDAR surface model lies beside the ground model, named after it.
SURFACE_MODEL = ("mnt_", "mns_")
BUILDING_CLEAR_M = 0.5
TERRAIN_EDGE_M = 2.0
LAP_STEP = 5  # every how many of the lap's sections that distance is measured from
ROAD_LINE_WIDTH_M = 0.15
# The middle of the lap's edge lines, inside its asphalt's edges.
LAP_LINE_FROM_EDGE_M = track_surfaces.LINE_INSET_M + track_surfaces.LINE_WIDTH_M / 2.0
# Facade kind: texture set, the width it covers, window style and the tint of each
# M_Facade_<kind>_<index> material.
FACADES = {
    "brick": (
        "polyhaven:brick_wall_02",
        2.0,
        "house",
        [(1, 1, 1), (0.92, 0.88, 0.86), (1.05, 0.98, 0.95)],
    ),
    "plaster": (
        "polyhaven:painted_plaster_wall",
        3.0,
        "house",
        [(0.97, 0.96, 0.93), (0.93, 0.91, 0.84), (0.88, 0.89, 0.90), (0.98, 0.93, 0.82)],
    ),
    "stone": ("polyhaven:stone_wall_04", 2.5, "house", [(1, 1, 1), (0.9, 0.9, 0.92)]),
    "metal": (
        "polyhaven:corrugated_iron_02",
        2.5,
        "hall",
        [(1.9, 1.9, 1.92), (1.6, 1.65, 1.7), (1.2, 1.35, 1.6), (1.05, 1.3, 1.1), (0.95, 0.97, 1.0)],
    ),
    "concrete": (
        "polyhaven:concrete_wall_008",
        4.0,
        "office",
        [(1, 1, 1), (0.9, 0.9, 0.88), (0.95, 0.93, 0.9)],
    ),
}
# Roofing (roofs.ROOF_CLASSES): texture set and the width it covers.
ROOFINGS = {
    "slate": ("polyhaven:roof_slates_03", 3.0),
    "clay_tiles": ("polyhaven:clay_roof_tiles_02", 2.6),
    "concrete_tiles": ("polyhaven:grey_roof_01", 6.0),
    "metal": ("polyhaven:corrugated_iron_03", 3.0),
    "bitumen": ("polyhaven:asphalt_pit_lane", 3.0),
    "gravel": ("polyhaven:floor_pebbles_01", 1.5),
    "green": ("ambientcg:Grass001", 3.0),
}
# Grandstand canopies and their columns: painted profiled sheet.
CANOPY_TEXTURES = ("polyhaven:corrugated_iron_03", 3.0)
CANOPY_TINT = (0.75, 0.12, 0.09)
BARRIER_TEXTURES = ("polyhaven:concrete_wall_001", 3.0)
BARRIER_TINT = (0.8, 0.8, 0.8)
SEAT_TEXTURES = "polyhaven:concrete_wall_008"
SEAT_TINT = (0.45, 0.04, 0.035)
SPAWN_INDEX = 3  # a few metres past the start of the experiment's lap
DEFAULT_STEREO = {
    "width_px": 1280,
    "height_px": 720,
    "hfov_deg": 90.0,
    "baseline_m": 0.12,
    "pitch_deg": 0.0,
    "rate_hz": 15.0,
}
# The experiment's mirrors: the glass it found by this material's name, and its cameras.
MIRRORS = {"material": "MIRRORS", "interior_hfov_deg": 45.0, "door_hfov_deg": 30.0}


# How each map of a texture set is compressed (compress_textures.gd's kinds).
TEXTURE_KINDS = {"albedo": "colour", "normal": "normal", "rough": "colour"}
TEXTURE_SIDE_PX = 2048  # every set at one size: the ground's layers share a texture array
TEXTURE_COMPRESSOR = Path(__file__).with_name("compress_textures.gd")
GROUND_MESH_PREFIXES = (smooth_terrain.TERRAIN_MESH_PREFIX, smooth_terrain.ROAD_MESH_PREFIX)


def ros(godot):
    """Return a Godot [x left, y up, z forward] vector as ROS [x forward, y left, z up]."""
    return [round(godot[2], 4), round(godot[0], 4), round(godot[1], 4)]


def texture_path(named):
    """Return a texture set's path in a pack, without its map suffixes."""
    return f"textures/{fetch_textures.set_name(named.split(':', 1)[1])}"


def surface_rules():
    """Return a circuit's `surfaces`: which simulator surface draws each glTF material."""
    rules = [{"materials": track_tiles.GROUND_MATERIAL["name"], "surface": "terrain"}]
    for roofing, (textures, size_m) in ROOFINGS.items():
        rules.append(
            {
                "materials": f"M_Roof_{roofing}",
                "surface": "roof",
                "textures": texture_path(textures),
                "size_m": size_m,
            }
        )
    for kind, (textures, size_m, windows, tints) in FACADES.items():
        for index, tint in enumerate(tints):
            rules.append(
                {
                    "materials": f"M_Facade_{kind}_{index}",
                    "surface": "facade",
                    "textures": texture_path(textures),
                    "size_m": size_m,
                    "windows": windows,
                    "tint": list(tint),
                }
            )
    rules.append(
        {
            "materials": "M_Grandstand_Seats",
            "surface": "seats",
            "textures": texture_path(SEAT_TEXTURES),
            "tint": list(SEAT_TINT),
        }
    )
    rules.append(
        {
            "materials": "M_Steel_*",
            "surface": "plain",
            "textures": texture_path(CANOPY_TEXTURES[0]),
            "size_m": CANOPY_TEXTURES[1],
            "tint": list(CANOPY_TINT),
        }
    )
    rules.append(
        {
            "materials": "M_Barrier*",
            "surface": "plain",
            "textures": texture_path(BARRIER_TEXTURES[0]),
            "size_m": BARRIER_TEXTURES[1],
            "tint": list(BARRIER_TINT),
        }
    )
    return rules


def texture_sets():
    """Return every texture set a circuit pack names, as `source:asset`."""
    named = [textures for textures, _, _ in GROUND_LAYERS]
    named += [facade[0] for facade in FACADES.values()]
    named += [roofing[0] for roofing in ROOFINGS.values()]
    named += [BARRIER_TEXTURES[0], SEAT_TEXTURES, CANOPY_TEXTURES[0]]
    return sorted(set(named))


def compress_textures(jobs):
    """Write DDS textures with Godot's encoders; a job is (kind, source image, DDS to write)."""
    if not jobs:
        return
    arguments = [str(part) for job in jobs for part in job]
    subprocess.run(
        [os.environ.get("GODOT", "godot"), "--headless", "--script", str(TEXTURE_COMPRESSOR), "--"]
        + arguments,
        check=True,
        stdout=subprocess.DEVNULL,
    )


def compressed_texture_sets(textures):
    """Write every map of the texture sets in `textures` as DDS beside its JPEG, once."""
    jobs = []
    for named in texture_sets():
        name = fetch_textures.set_name(named.split(":", 1)[1])
        for kind in fetch_textures.MAPS:
            source = textures / f"{name}_{kind}.jpg"
            compressed = textures / f"{name}_{kind}.dds"
            with Image.open(source) as image:
                if image.size != (TEXTURE_SIDE_PX, TEXTURE_SIDE_PX):
                    raise ValueError(f"{source} is not {TEXTURE_SIDE_PX} px square")
            if not compressed.exists():
                jobs.append((TEXTURE_KINDS[kind], source, compressed))
    compress_textures(jobs)


def tree_impostors(experiment):
    """Return the `impostors` of a circuit's trees and the atlases they are written from."""
    atlases = experiment / "data" / "trees"
    described = json.loads((atlases / "impostors.json").read_text())
    impostors, sources = [], {}
    for name, impostor in described.items():
        impostors.append(
            {
                "atlas": f"trees/{name}.dds",
                "views": impostor["views"],
                "width_m": impostor["width"],
                "height_m": impostor["height"],
                "kind": impostor["kind"],
            }
        )
        sources[f"trees/{name}.dds"] = atlases / f"{name}.png"
    return impostors, sources


def write_tree_atlases(directory, sources):
    """Write the impostor atlases of a pack as DDS."""
    (directory / "trees").mkdir(parents=True, exist_ok=True)
    compress_textures([("colour", source, directory / name) for name, source in sources.items()])


def crown_colours(impostors, sources):
    """Return the linear colour of each kind's crowns: its atlases' opaque pixels, tinted."""
    colours = {}
    for kind in track_tiles.TREE_KINDS:
        means = []
        for impostor in impostors:
            if impostor["kind"] != kind:
                continue
            with Image.open(sources[impostor["atlas"]]) as atlas:
                pixels = np.asarray(atlas.convert("RGBA"), np.float64) / 255.0
            opaque = pixels[..., 3] > 0.5
            means.append((ground_classes.linear(pixels[..., :3])[opaque]).mean(0))
        if means:
            colours[kind] = [
                round(float(level * tint), 4)
                for level, tint in zip(np.mean(means, 0), MEAN_TREE_TINT, strict=True)
            ]
    return colours


def tree_instances(trees):
    """Return a circuit's trees by kind, each [x, y, z, height] in the pack's ROS frame.

    `trees` are the experiment's: [x, y, z, height, is a conifer] in Godot's frame.
    """
    standing = {"conifer": [], "broadleaf": []}
    for x, y, z, height_m, conifer in trees:
        standing["conifer" if conifer else "broadleaf"].append([z, x, y, height_m])
    return standing


def trees_off_the_roads(trees, driven):
    """Return the experiment's trees whose trunk is not on the `driven` ground.

    A LiDAR crown peak over a road is a crown that overhangs it, not a trunk on it.
    """
    east = np.array([tree[0] for tree in trees])
    north = np.array([-tree[2] for tree in trees])
    on_the_road = driven.covers(east, north)
    return [tree for tree, dropped in zip(trees, on_the_road, strict=True) if not dropped]


def circuit_pack(experiment, track_id, circuit, textures):
    """Return the manifest of a circuit, the files it links to and its tree atlases' sources."""
    built = experiment / "data" / track_id / "godot"
    lap = json.loads((built / "track.json").read_text())
    start = lap["points"][SPAWN_INDEX]
    heading = lap["dirs"][SPAWN_INDEX]
    impostors, atlases = tree_impostors(experiment)
    links = {}
    for named in texture_sets():
        name = fetch_textures.set_name(named.split(":", 1)[1])
        for kind in fetch_textures.MAPS:
            links[f"textures/{name}_{kind}.dds"] = textures / f"{name}_{kind}.dds"
    links["sky.hdr"] = experiment / "data" / "sky" / "partly_cloudy_4k.hdr"
    manifest = {
        "format": 1,
        "kind": "track",
        "id": track_id,
        "name": circuit["name"],
        "version": "0.2.0",
        "licence": "CC-BY-4.0 AND ODbL-1.0",
        "attribution": WALLONIA_ATTRIBUTION
        + [
            (textures / f"{name}.source.txt").read_text().strip()
            for name in sorted(
                fetch_textures.set_name(named.split(":", 1)[1]) for named in texture_sets()
            )
        ],
        "track": {
            "tiles": "tiles.json",
            "far": {"scene": "far.glb", "photo": "far.jpg"},
            "sky": "sky.hdr",
            "sun": SUN,
            "haze": {"visibility_m": circuit["visibility_m"]},
            "spawn": {
                "position_m": ros(start),
                "yaw_deg": round(math.degrees(math.atan2(heading[0], heading[2])), 2),
            },
            "ground": {
                "layers": [
                    {"textures": texture_path(named), "size_m": size_m, "photo": photo}
                    | ({"joints_m": LAYER_JOINTS_M[layer]} if layer in LAYER_JOINTS_M else {})
                    for layer, (named, size_m, photo) in enumerate(GROUND_LAYERS)
                ],
                "slope_layer": ground_classes.MEADOW,
            },
            "surfaces": surface_rules(),
            "trees": {
                "impostors": impostors,
                "canopy": {"scene": "canopy.glb", "from_m": circuit["trees_drawn_m"]},
            },
        },
    }
    return manifest, links, atlases


def write_surfaces(experiment, track_id, circuit, directory, work, manifest, crowns):
    """Write a circuit's tiles, maps, lines and canopy, and name them in `manifest`.

    So is the photo's grade. The whole world the tiles are cut from is written into `work`;
    `crowns` is the colour of each kind of tree's crown.
    """
    data = experiment / "data" / track_id
    frame = json.loads((data / "frame.json").read_text())
    sections = json.loads((data / "build" / f"{circuit['build']}.sections.json").read_text())
    origin = frame["origin"][:2]
    standing = json.loads((data / "godot" / "trees.json").read_text())
    trees = [(x + origin[0], origin[1] - z, height_m) for x, _, z, height_m, _ in standing]
    surveyed = track_surfaces.Ground(data / "ortho", origin, sections, trees)
    ground = manifest["track"]["ground"]
    ground["photo_grade"] = surveyed.grade
    lap_length_m, lap_map, lap_edges, racing_offset_m = track_surfaces.build(
        surveyed, sections, directory
    )
    ground["road"] = {
        "lines": "road_lines.png",
        "lap_length_m": lap_length_m,
        "layer": ground_classes.TRACK_ASPHALT,
    }
    extract = osm.read(data / f"{track_id}_area.osm", origin)
    lap_x, lap_y = np.array(sections["x"])[::LAP_STEP], np.array(sections["y"])[::LAP_STEP]
    near_lap = secondary_roads.near(lap_x, lap_y, ROADS_NEAR_LAP_M)
    near_lap_for_public = secondary_roads.near(lap_x, lap_y, PUBLIC_ROADS_NEAR_LAP_M)

    def roads_area(road, x, y):
        return (near_lap_for_public if road_signs.is_public(road.tags) else near_lap)(x, y)

    roads = secondary_roads.survey_area(surveyed, extract, roads_area)
    road_map = secondary_roads.lay(surveyed, roads)
    lots, lot_edge_m = parking_lots.build(
        surveyed, extract, road_map.inside_roads(0), ~np.isnan(lap_map.along), directory
    )
    ground["lots"] = "lots.json"
    print(f"{track_id}: {len(roads)} roads, {len(lots)} parking lots and yards")
    # The lap and the lots: where no sign stands. With the roads: where no tree stands.
    driven = drivable.Drivable()
    lap = {key: np.append(sections[key], sections[key][0]) for key in ("x", "y", "tx", "ty")}
    driven.add_strip(
        lap, np.append(lap_edges[0], lap_edges[0][0]), np.append(lap_edges[1], lap_edges[1][0])
    )
    mosaic = surveyed.mosaic
    driven.add_raster(
        lot_edge_m,
        mosaic.west - origin[0],
        mosaic.north - origin[1],
        track_surfaces.TRACK_MAP_M_PER_PX,
    )
    terrain = np.array(smooth_terrain.height_map_bounds(experiment / frame["dtm"]))
    site = sign_site(extract, driven, terrain - np.tile(origin, 2), surveyed)
    signs = road_signs.place(extract, roads, site)
    secondary_roads.write(surveyed, roads, road_map, directory)
    ground["roads"] = {
        "lines": "roads_lines.png",
        "dashes_m": [list(dash) for dash in road_markings.DASHES_M],
        "line_width_m": ROAD_LINE_WIDTH_M,
    }
    for road in roads:
        driven.add_strip(road.sections, road.half_width_m, road.half_width_m)
    kept = trees_off_the_roads(standing, driven)
    print(
        f"{track_id}: {len(standing) - len(kept)} of {len(standing)} trees stood on a road or a lot"
    )
    work.mkdir(parents=True, exist_ok=True)
    height_m = smooth_terrain.write_smoothed_world(
        data / "godot" / "world.glb",
        work / "world.glb",
        experiment / frame["dtm"],
        frame["origin"],
        [lot.outline for lot in lots if lot.outline is not None],
    )

    placed = write_signs(signs, height_m, directory, manifest)
    print(f"{track_id} signs: {signs.counts()}")
    for reason, sign in signs.unplaced:
        print(f"{track_id} sign not placed, {reason}: {sign}")
    decals = road_decals.place(
        surveyed,
        sections,
        lap_edges,
        racing_offset_m,
        extract.nodes,
        carriageways(sections, lap_edges, roads),
        road_decals.shadowed_by(
            [(x, -z, height) for x, _, z, height, _ in standing],
            [area.points for area in extract.areas if "building" in area.tags],
        ),
    )
    placed["decals"] = write_decals(decals, height_m, directory, manifest)
    print(f"{track_id} decals: {dict(Counter(decal.kind for decal in decals))}")

    write_buildings(experiment, frame, extract, surveyed, height_m, data, work / "world.glb")
    photo = world_photo(data / "godot" / "world.glb", mosaic)
    homeless = track_tiles.write(
        work / "world.glb",
        directory,
        mosaic,
        photo,
        origin,
        track_surfaces.PACK_TILE_M,
        GROUND_MESH_PREFIXES,
        tree_instances(kept),
        placed,
    )
    tile_count = len(json.loads((directory / "tiles.json").read_text())["tiles"])
    faults = [
        fault
        for tile in sorted((directory / "tiles").glob("*.glb"))
        for fault in buildings.audit(tile).values()
    ]
    print(f"{track_id}: {faults.count(None)} of {len(faults)} buildings in the tiles are closed")
    print(f"{track_id}: {tile_count} tiles; {homeless} trees, sign parts and decals stood on none")
    wooded = track_tiles.write_canopy(
        directory, mosaic, photo, origin, tree_instances(kept), crowns
    )
    print(f"{track_id}: a canopy over {wooded} tiles")


def write_buildings(experiment, frame, extract, surveyed, height_m, data, world_glb):
    """Write the buildings the map shows into `world_glb`, in place of the experiment's.

    They stand on the terrain `height_m` gives, under the roofs of the LiDAR surface model,
    with the facades the experiment gave them.
    """
    track_id = data.name

    def ground_m(points):
        return height_m(points[:, 0], points[:, 1])

    def photo_albedo(points):
        return surveyed.albedo_at(*surveyed.pixel(points[:, 0], points[:, 1]))

    built, made = buildings.build(
        extract.areas,
        buildings.read_surface(experiment / frame["dtm"].replace(*SURFACE_MODEL), frame["origin"]),
        ground_m,
        photo_albedo,
        buildings.mapped_facades(data / "godot" / "world.glb"),
        {kind: len(facade[3]) for kind, facade in FACADES.items()},
    )
    buildings.write(world_glb, built)
    print(f"{track_id} buildings: {dict(made)}")
    print(f"{track_id} roof shapes: {dict(Counter(building.shape for building in built))}")
    print(f"{track_id} roofs: {dict(Counter(building.roofing for building in built))}")


def world_photo(world_glb, mosaic):
    """Return the photo the experiment's world draws its ground with, laid out as the mosaic.

    Each `M_Ortho_<east>_<north>` material of the world carries the photo of one orthophoto
    tile, as the experiment toned it.
    """
    gltf, binary = smooth_terrain.read_glb(world_glb)
    photo = np.zeros_like(mosaic.rgb)
    for material in gltf["materials"]:
        if not material["name"].startswith(roofs.ROOF_MATERIAL_PREFIX):
            continue
        east, north = material["name"][len(roofs.ROOF_MATERIAL_PREFIX) :].split("_")
        texture = gltf["textures"][material["pbrMetallicRoughness"]["baseColorTexture"]["index"]]
        view = gltf["bufferViews"][gltf["images"][texture["source"]]["bufferView"]]
        start = view.get("byteOffset", 0)
        image = Image.open(io.BytesIO(bytes(binary[start : start + view["byteLength"]])))
        row, column = mosaic.tile_origin_px((int(east), int(north)))
        photo[row : row + mosaic.tile_px, column : column + mosaic.tile_px] = np.asarray(
            image.convert("RGB")
        )
    return photo


def sign_site(extract, driven, terrain, ground):
    """Return the road_signs.Site of a circuit: on its terrain, off what is driven on.

    `driven` is the lap and the lots, `terrain` the (west, south, east, north) the terrain
    reaches to; no sign stands in a building either.
    """
    buildings = [area.points for area in extract.areas if "building" in area.tags]

    def blocked(x, y):
        west, south, east, north = terrain
        on_terrain = west + TERRAIN_EDGE_M < x < east - TERRAIN_EDGE_M
        on_terrain &= south + TERRAIN_EDGE_M < y < north - TERRAIN_EDGE_M
        if driven.covers(x, y)[0] or not on_terrain:
            return True
        return any(
            parking_lots.signed_distance(outline, x, y) < BUILDING_CLEAR_M
            for outline in buildings
            if np.all(np.abs(outline.mean(0) - (x, y)) < 100.0)
        )

    def walked(x, y):
        rows, columns = ground.pixel(np.array([x]), np.array([y]))
        return ground.labels[rows[0], columns[0]] in secondary_roads.LINED_LAYERS

    return road_signs.Site(blocked, walked)


def write_signs(signs, height_m, directory, manifest):
    """Write a circuit's sign faces and name them in `manifest`; return its placed signs."""
    faces = directory / "signs"
    faces.mkdir(exist_ok=True)
    for stale in faces.glob("*.png"):
        stale.unlink()
    for code in signs.faces():
        sign_faces.face(code).image.save(faces / sign_faces.file_name(code))
    manifest["track"]["signs"] = road_signs.manifest(signs, "signs")
    if signs.faces():
        manifest["attribution"].append(sign_faces.SOURCE)
    return road_signs.described(signs, height_m)


def carriageways(sections, lap_edges, roads):
    """Return the lap and the surveyed roads as road_decals.Carriageway: asphalt and paint."""
    left_m, right_m = (np.asarray(edge) for edge in lap_edges)
    lap_lines = [LAP_LINE_FROM_EDGE_M - left_m, right_m - LAP_LINE_FROM_EDGE_M]
    found = [road_decals.Carriageway(sections, left_m, right_m, lap_lines)]
    for road in roads:
        offsets = [np.where(line.pattern > 0, line.offset_m, np.nan) for line in road.lines]
        found.append(
            road_decals.Carriageway(road.sections, road.half_width_m, road.half_width_m, offsets)
        )
    return found


def write_decals(decals, height_m, directory, manifest):
    """Write the textures of the decals placed, name them in `manifest`; return them listed."""
    kinds = [kind for kind in road_decals.KINDS if any(decal.kind == kind for decal in decals)]
    road_decals.write_textures(directory / "decals", kinds)
    if kinds:
        manifest["track"]["decals"] = road_decals.manifest(kinds, "decals")
        manifest["attribution"].append(road_decals.SOURCE)
    return road_decals.described(decals, height_m)


def instruments(profile):
    """Return a car profile's instruments as a vehicle pack's.

    An axis is the one its part turns about by the right-hand rule as its reading rises; the
    experiment turned the steering wheel the other way about its own as the car steered left.
    """
    pack = {}
    if "speed" in profile:
        pack["speedometer"] = {
            "node": profile["speed"]["node"],
            "axis": ros(profile["speed"]["axis"]),
            "km_h_to_deg": profile["speed"]["kmh_to_deg"],
        }
    if "rpm" in profile:
        pack["rev_counter"] = {
            "node": profile["rpm"]["node"],
            "axis": ros(profile["rpm"]["axis"]),
            "deg_per_rpm": profile["rpm"]["deg_per_unit"],
            "max_rpm": profile["rpm"]["max"],
            "motor_to_wheel_ratio": profile["motor_to_wheel_ratio"],
        }
    if "steering_wheel" in profile:
        pack["steering_wheel"] = {
            "node": profile["steering_wheel"]["node"],
            "axis": ros([-along for along in profile["steering_wheel"]["axis"]]),
            "ratio": profile["steering_wheel"]["ratio"],
            "lock_deg": profile["steering_wheel"]["lock_deg"],
        }
    return pack


def gltf_material_names(model):
    """Return the names of the materials of a binary glTF file."""
    with model.open("rb") as file:
        file.seek(12)
        (json_length,) = struct.unpack("<I4x", file.read(8))
        document = json.loads(file.read(json_length))
    return [material.get("name", "") for material in document.get("materials", [])]


# Road tyres on dry asphalt hold about 0.8 g sideways; OVCS1 runs eco tyres.
LATERAL_GRIP_M_S2 = {"ovcs1": 7.8, "ovcs_mini": 8.0}


def vehicle_pack(experiment, vehicle_id, licence, attribution):
    """Return the manifest of a vehicle profile and the files it links to."""
    cars = experiment / "data" / "cars"
    profile = json.loads((cars / f"{vehicle_id}.json").read_text())
    front, rear = profile["x_front"], profile["x_rear"]
    body = profile.get("body_size", [1.62, 1.05, 3.85])
    body_centre = [
        0.0,
        profile.get("body_centre_height", 0.85),
        (front + rear) * 0.5 + profile.get("body_ahead_of_axles", 0.1),
    ]
    optics = profile.get("stereo", {})
    stereo = {
        "mount_m": ros(profile["stereo_mount"]),
        "width_px": optics.get("width", DEFAULT_STEREO["width_px"]),
        "height_px": optics.get("height", DEFAULT_STEREO["height_px"]),
        "hfov_deg": optics.get("hfov_deg", DEFAULT_STEREO["hfov_deg"]),
        "baseline_m": optics.get("baseline_m", DEFAULT_STEREO["baseline_m"]),
        "pitch_deg": optics.get("pitch_deg", DEFAULT_STEREO["pitch_deg"]),
        "rate_hz": optics.get("hz", DEFAULT_STEREO["rate_hz"]),
    }
    vehicle = {
        "front_axle_x_m": front,
        "rear_axle_x_m": rear,
        "front_track_m": profile["track_front"],
        "rear_track_m": profile["track_rear"],
        "wheel_radius_m": profile["wheel_radius"],
        "wheel_width_m": profile["wheel_width"],
        "max_lateral_acceleration_m_s2": LATERAL_GRIP_M_S2[vehicle_id],
        "body": {"size_m": ros(body), "centre_m": ros(body_centre)},
        "driver_eye_m": ros(profile["driver_eye"]),
        "driver_pitch_deg": profile.get("driver_pitch_deg", 0.0),
        "stereo": stereo,
    }
    links = {}
    model = cars / f"{vehicle_id}.glb"
    if model.exists():
        vehicle["model"] = "vehicle.glb"
        links["vehicle.glb"] = model
        if "instruments" in profile:
            vehicle["instruments"] = instruments(profile["instruments"])
        if MIRRORS["material"] in gltf_material_names(model):
            vehicle["mirrors"] = MIRRORS
    manifest = {
        "format": 1,
        "kind": "vehicle",
        "id": vehicle_id,
        "name": profile.get("name", vehicle_id.upper()),
        "version": "0.1.0",
        "licence": licence,
        "attribution": attribution,
        "vehicle": vehicle,
    }
    return manifest, links


def link_files(directory, links):
    """Link the large files of a pack into its directory."""
    for name, target in links.items():
        link = directory / name
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target.resolve())


def write_pack(out, manifest, links):
    """Write pack.json and links the large files into OUT/<id>."""
    directory = out / manifest["id"]
    directory.mkdir(parents=True, exist_ok=True)
    link_files(directory, links)
    (directory / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{directory}: {manifest['kind']} {manifest['name']}")


def write_circuit(experiment, out, textures, track_id, circuit):
    """Write a circuit's pack with what is derived from its orthophoto."""
    manifest, links, atlases = circuit_pack(experiment, track_id, circuit, textures)
    directory = out / track_id
    directory.mkdir(parents=True, exist_ok=True)
    write_tree_atlases(directory, atlases)
    write_surfaces(
        experiment,
        track_id,
        circuit,
        directory,
        out.parent / "work" / track_id,
        manifest,
        crown_colours(manifest["track"]["trees"]["impostors"], atlases),
    )
    write_pack(out, manifest, links)


def main(experiment, out, only):
    """Write every pack the experiment has outputs for, or the circuits `only` names."""
    textures = out.parent / "textures"
    fetch_textures.main(textures, texture_sets())
    compressed_texture_sets(textures)
    for track_id, circuit in CIRCUITS.items():
        if only and track_id not in only:
            continue
        if (experiment / "data" / track_id / "godot" / "world.glb").exists():
            write_circuit(experiment, out, textures, track_id, circuit)
    write_pack(
        out,
        *vehicle_pack(
            experiment,
            "ovcs1",
            "LicenseRef-local-use-only",
            ["Body from a third-party Assetto Corsa mod: not redistributable"],
        ),
    )
    write_pack(out, *vehicle_pack(experiment, "ovcs_mini", "CC0-1.0", []))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:])
