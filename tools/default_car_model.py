"""Write the default car's model and measurements from "Generic Sedan Car", CC BY 4.0.

    "Generic Sedan Car" by Márcio Meireles (MMC Works),
    https://sketchfab.com/3d-models/generic-sedan-car-58c33766470d46e7b2aed542650494e5

The source is not in the repository: download its glTF binary ("Download 3D model", glTF,
the smaller textures) to build/sedan_src/small.glb; its SHA-256 is checked, so the built pack
matches the committed one. Each part of the source is a named object; this module merges every
part but the wheels into one `Body` mesh by material, keeps one rear wheel (tyre, rim and brake
disc) as the `Wheel` centred on its axle, the steering wheel as `Cockpit_Steer` turning about its
column, adds glass to the door mirrors, moves the origin to the ground midway between the axles,
and downsizes the textures. The source is read as data: nothing in it is run.

Needs numpy and Pillow.
"""

import copy
import hashlib
import io
import re
from pathlib import Path

import numpy as np
import smooth_terrain
import track_tiles
from PIL import Image

REPOSITORY = Path(__file__).resolve().parent.parent
SOURCE = REPOSITORY / "build" / "sedan_src" / "small.glb"
SOURCE_SHA256 = "38d945860d5b25deb1ec6bc2dfb82e945234bf6d4c1e39358b6333adf1e3b6e4"
SOURCE_URL = "https://sketchfab.com/3d-models/generic-sedan-car-58c33766470d46e7b2aed542650494e5"
CREDIT = (
    '"Generic Sedan Car" by Márcio Meireles (MMC Works), '
    f"{SOURCE_URL}, CC BY 4.0 (http://creativecommons.org/licenses/by/4.0/)"
)
MODIFICATIONS = (
    "merged into one body mesh by material, one rear wheel kept as the wheel the simulator "
    "copies to each corner, the steering wheel separated to turn, mirror glass added to the "
    "door mirrors, the origin moved to the ground midway between the axles, textures "
    "downsized and re-encoded as JPEG and PNG"
)
# Source objects by role; the other wheels, tyres and discs are dropped.
WHEEL_PARTS = ("generic-tire-low.002", "generic-wheel.002", "brake-disc-rear-l")
DROPPED_PREFIXES = ("generic-tire-low", "generic-wheel", "brake-disc-")
STEERING_WHEEL = "steering-wheel"
DOOR_MIRRORS = ("side-mirror-l", "side-mirror-r")
WHEEL_NODES = {
    "front_left": "Name-Wheel.Ft.L",
    "front_right": "Name-Wheel.Ft.R",
    "rear_left": "Name-Wheel.Bk.L",
}
TYRE = "generic-tire-low.002"
WINDSCREEN = "windshield"
DRIVER_SEAT = "front-seat"
DRIVER_BACKREST = "front-seat-backrest"
MIRROR_MATERIAL = {
    "name": "Mirror",
    "pbrMetallicRoughness": {
        "baseColorFactor": [0.8, 0.8, 0.8, 1.0],
        "metallicFactor": 1.0,
        "roughnessFactor": 0.05,
    },
}
# The door mirror's back faces: their normals point within about 30 degrees of straight back.
MIRROR_FACING_BACK = 0.85
MIRROR_GLASS_SHRINK = 0.85
MIRROR_GLASS_PROUD_M = 0.003
# A seated driver's eyes stand about this far above the seat cushion (SAE J941's eyellipse
# over the H-point) and ahead of the head restraint's face.
EYE_ABOVE_CUSHION_M = 0.68
EYE_AHEAD_OF_HEAD_RESTRAINT_M = 0.12
HEAD_RESTRAINT_DEPTH_M = 0.15
# The stereo camera sits behind the windscreen's top, centred, clear of the glass.
STEREO_BELOW_WINDSCREEN_TOP_M = 0.05
STEREO_BEHIND_GLASS_M = 0.05
# Downsized texture sides by material: what shows from the driver's seat and the chase view
# keeps the most; the engine bay and underbody show next to nothing.
TEXTURE_SIDE_PX = {
    "Car_Paint_-_All_Colors": 1024,
    "interior": 1024,
    "engine": 128,
    "car-bottom": 256,
    "suspension-pipe-brakes": 256,
}
DEFAULT_TEXTURE_SIDE_PX = 512
JPEG_QUALITY = 85
MATERIAL_TEXTURES = ("normalTexture", "occlusionTexture", "emissiveTexture")
PBR_TEXTURES = ("baseColorTexture", "metallicRoughnessTexture")
COMPONENT_TYPES = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}
COMPONENT_COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_source(path=SOURCE):
    """Return the source's glTF and binary chunk, refusing a file other than the expected one."""
    if not path.exists():
        raise FileNotFoundError(f"{path}: download the source model ({SOURCE_URL}) there")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError(f"{path}: SHA-256 {digest}, expected {SOURCE_SHA256}")
    return smooth_terrain.read_glb(path)


def accessor_elements(gltf, binary, index):
    """Return an accessor's elements as an array of (count, components)."""
    accessor = gltf["accessors"][index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    dtype = np.dtype(COMPONENT_TYPES[accessor["componentType"]])
    components = COMPONENT_COUNTS[accessor["type"]]
    element_bytes = dtype.itemsize * components
    stride = view.get("byteStride", element_bytes)
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    count = accessor["count"]
    raw = np.frombuffer(binary, np.uint8, stride * (count - 1) + element_bytes, start)
    rows = np.lib.stride_tricks.as_strided(raw, (count, element_bytes), (stride, 1))
    return rows.copy().view(dtype).reshape(count, components)


def node_matrix(node):
    """Return a node's local transform as a 4x4 matrix."""
    if "matrix" in node:
        return np.array(node["matrix"], np.float64).reshape(4, 4).T
    for key in ("translation", "rotation", "scale"):
        if key in node:
            raise ValueError(f"node {node.get('name')}: only matrices are read")
    return np.eye(4)


def world_matrices(gltf):
    """Return {node index: (world matrix, parent index)} over the default scene."""
    placed = {}
    pending = [(root, np.eye(4), None) for root in gltf["scenes"][gltf.get("scene", 0)]["nodes"]]
    while pending:
        index, parent_matrix, parent = pending.pop()
        matrix = parent_matrix @ node_matrix(gltf["nodes"][index])
        placed[index] = (matrix, parent)
        pending += [(child, matrix, index) for child in gltf["nodes"][index].get("children", [])]
    return placed


def object_name(name):
    """Return a source object's name without the index its exporter appended."""
    return re.sub(r"_\d+$", "", name)


def read_parts(gltf, binary):
    """Return the source's mesh primitives in its world frame, each named by its object.

    A part is {name, material, POSITION, NORMAL, optionally TANGENT and TEXCOORD_0, indices}.
    """
    placed = world_matrices(gltf)
    parts = []
    for index, (matrix, parent) in sorted(placed.items()):
        node = gltf["nodes"][index]
        if "mesh" not in node:
            continue
        name = object_name(gltf["nodes"][parent]["name"] if parent is not None else node["name"])
        linear = matrix[:3, :3]
        normal_matrix = np.linalg.inv(linear).T
        mirrored = np.linalg.det(linear) < 0
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            attributes = primitive["attributes"]
            positions = accessor_elements(gltf, binary, attributes["POSITION"]).astype(np.float64)
            part = {
                "name": name,
                "material": primitive["material"],
                "POSITION": positions @ linear.T + matrix[:3, 3],
                "NORMAL": unit(
                    accessor_elements(gltf, binary, attributes["NORMAL"]) @ normal_matrix.T
                ),
            }
            if "TANGENT" in attributes:
                tangents = accessor_elements(gltf, binary, attributes["TANGENT"])
                handedness = tangents[:, 3:] * (-1.0 if mirrored else 1.0)
                part["TANGENT"] = np.hstack([unit(tangents[:, :3] @ linear.T), handedness])
            if "TEXCOORD_0" in attributes:
                part["TEXCOORD_0"] = accessor_elements(gltf, binary, attributes["TEXCOORD_0"])
            triangles = accessor_elements(gltf, binary, primitive["indices"]).reshape(-1, 3)
            part["indices"] = (triangles[:, ::-1] if mirrored else triangles).astype(np.uint32)
            parts.append(part)
    return parts


def unit(vectors):
    """Return `vectors` scaled to length 1 (zero vectors stay zero)."""
    lengths = np.linalg.norm(vectors, axis=1, keepdims=True)
    return vectors / np.where(lengths > 0, lengths, 1.0)


def named(parts, name):
    """Return the parts of the object `name`."""
    found = [part for part in parts if part["name"] == name]
    if not found:
        raise ValueError(f"the source has no object {name}")
    return found


def positions_of(parts):
    """Return the positions of all of `parts`."""
    return np.concatenate([part["POSITION"] for part in parts])


def node_position(gltf, name):
    """Return the world position of the node `name` (exporter index ignored)."""
    for index, (matrix, _) in world_matrices(gltf).items():
        if object_name(gltf["nodes"][index].get("name", "")) == name:
            return matrix[:3, 3]
    raise ValueError(f"the source has no node {name}")


def convex_hull(points):
    """Return the convex hull of 2D `points`, counter-clockwise (Andrew's monotone chain)."""
    ordered = sorted({(float(x), float(y)) for x, y in points})
    if len(ordered) < 3:
        return np.array(ordered)

    def half(sequence):
        chain = []
        for point in sequence:
            while len(chain) >= 2 and cross(chain[-2], chain[-1], point) <= 0:
                chain.pop()
            chain.append(point)
        return chain[:-1]

    return np.array(half(ordered) + half(ordered[::-1]))


def cross(origin, first, second):
    """Return the z of (first - origin) x (second - origin)."""
    return (first[0] - origin[0]) * (second[1] - origin[1]) - (first[1] - origin[1]) * (
        second[0] - origin[0]
    )


def mirror_glass(housing_parts):
    """Return a flat pane of glass over the back of a door mirror's housing, as a part."""
    corners = []
    normals = []
    for part in housing_parts:
        triangles = part["POSITION"][part["indices"]]
        facing = unit(
            np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
        )
        back = facing[:, 2] < -MIRROR_FACING_BACK
        corners.append(triangles[back].reshape(-1, 3))
        normals.append(facing[back])
    corners, normal = np.concatenate(corners), unit(np.concatenate(normals).mean(0)[None])[0]
    centre = corners.mean(0)
    across = unit(np.cross([0.0, 1.0, 0.0], normal)[None])[0]
    up = np.cross(normal, across)
    flat = np.stack([(corners - centre) @ across, (corners - centre) @ up], -1)
    outline = convex_hull(flat) * MIRROR_GLASS_SHRINK
    rim = centre + normal * MIRROR_GLASS_PROUD_M + outline[:, :1] * across + outline[:, 1:] * up
    positions = np.vstack([centre + normal * MIRROR_GLASS_PROUD_M, rim])
    count = len(outline)
    fan = [[0, 1 + (index + 1) % count, 1 + index] for index in range(count)]
    first = positions[fan[0]]
    if np.dot(np.cross(first[1] - first[0], first[2] - first[0]), normal) < 0:
        fan = [triangle[::-1] for triangle in fan]
    return {
        "name": "mirror-glass",
        "material": None,
        "POSITION": positions,
        "NORMAL": np.tile(normal, (len(positions), 1)),
        "indices": np.array(fan, np.uint32),
    }


def frame(gltf, parts):
    """Return what places the model: its origin and wheel measurements, in the source's frame."""
    front_left = node_position(gltf, WHEEL_NODES["front_left"])
    front_right = node_position(gltf, WHEEL_NODES["front_right"])
    rear_left = node_position(gltf, WHEEL_NODES["rear_left"])
    tyre = positions_of(named(parts, TYRE))
    wheel_radius_m = (tyre[:, 1].max() - tyre[:, 1].min()) / 2.0
    origin = np.array(
        [0.0, rear_left[1] - wheel_radius_m, (front_left[2] + rear_left[2]) / 2.0], np.float64
    )
    return {
        "origin": origin,
        "wheel_centre": rear_left,
        "wheelbase_m": front_left[2] - rear_left[2],
        "track_m": front_left[0] - front_right[0],
        "wheel_radius_m": wheel_radius_m,
        "wheel_width_m": tyre[:, 0].max() - tyre[:, 0].min(),
    }


def moved(part, offset):
    """Return `part` with its positions moved by `offset`."""
    return {**part, "POSITION": part["POSITION"] + offset}


def steering_pivot(parts):
    """Return the steering wheel's centre and the axis it turns about, towards the driver."""
    positions = positions_of(parts)
    middle = positions.mean(0)
    _, _, axes = np.linalg.svd(positions - middle)
    axis = axes[2] if axes[2][2] < 0 else -axes[2]
    across = np.stack([axes[0], axes[1]])
    flat = (positions - middle) @ across.T
    centre = middle + ((flat.min(0) + flat.max(0)) / 2.0) @ across
    return centre, axis


def driver_eye(parts):
    """Return where a driver's eyes are, above the driver's seat, in the source's frame."""
    seat = positions_of(named(parts, DRIVER_SEAT))
    backrest = positions_of(named(parts, DRIVER_BACKREST))
    head_restraint = backrest[backrest[:, 1] > backrest[:, 1].max() - HEAD_RESTRAINT_DEPTH_M]
    return np.array(
        [
            (seat[:, 0].min() + seat[:, 0].max()) / 2.0,
            seat[:, 1].max() + EYE_ABOVE_CUSHION_M,
            head_restraint[:, 2].max() + EYE_AHEAD_OF_HEAD_RESTRAINT_M,
        ]
    )


def stereo_mount(parts):
    """Return the stereo camera's place behind the windscreen's top, in the source's frame."""
    glass = positions_of(named(parts, WINDSCREEN))
    centre_strip = glass[np.abs(glass[:, 0]) < 0.15]
    slope, intercept = np.polyfit(centre_strip[:, 1], centre_strip[:, 2], 1)
    height_m = glass[:, 1].max() - STEREO_BELOW_WINDSCREEN_TOP_M
    return np.array([0.0, height_m, slope * height_m + intercept - STEREO_BEHIND_GLASS_M])


def texture_side_px(material):
    """Return the side a material's textures are downsized to."""
    return TEXTURE_SIDE_PX.get(material["name"], DEFAULT_TEXTURE_SIDE_PX)


def encoded_image(gltf, binary, image_index, side_px):
    """Return a source image downsized to `side_px` wide: (bytes, MIME type), PNG with alpha."""
    view = gltf["bufferViews"][gltf["images"][image_index]["bufferView"]]
    start = view.get("byteOffset", 0)
    with Image.open(io.BytesIO(bytes(binary[start : start + view["byteLength"]]))) as image:
        has_alpha = image.mode in ("LA", "RGBA") or "transparency" in image.info
        converted = image.convert("RGBA" if has_alpha else "RGB")
    width, height = converted.size
    if width > side_px:
        converted = converted.resize(
            (side_px, max(1, round(height * side_px / width))), Image.Resampling.LANCZOS
        )
    out = io.BytesIO()
    if has_alpha:
        converted.save(out, "PNG", optimize=False)
        return out.getvalue(), "image/png"
    converted.save(out, "JPEG", quality=JPEG_QUALITY, optimize=False, progressive=False)
    return out.getvalue(), "image/jpeg"


class Textures:
    """The written model's textures, each source texture added once per side."""

    def __init__(self, glb, gltf, binary):
        """Add textures to `glb` from the source's `gltf` and `binary`."""
        self.glb, self.gltf, self.binary = glb, gltf, binary
        self.added = {}
        glb.gltf.update({"images": [], "textures": [], "samplers": gltf.get("samplers", [])})

    def index(self, source_texture, side_px):
        """Return the written texture standing for `source_texture` at `side_px`."""
        key = (source_texture, side_px)
        if key not in self.added:
            texture = self.gltf["textures"][source_texture]
            encoded, mime_type = encoded_image(self.gltf, self.binary, texture["source"], side_px)
            self.glb.gltf["bufferViews"].append(
                {"buffer": 0, "byteOffset": len(self.glb.binary), "byteLength": len(encoded)}
            )
            self.glb.binary += encoded + b"\0" * (-len(encoded) % 4)
            view = len(self.glb.gltf["bufferViews"]) - 1
            self.glb.gltf["images"].append({"bufferView": view, "mimeType": mime_type})
            written = {"source": len(self.glb.gltf["images"]) - 1}
            if "sampler" in texture:
                written["sampler"] = texture["sampler"]
            self.glb.gltf["textures"].append(written)
            self.added[key] = len(self.glb.gltf["textures"]) - 1
        return self.added[key]

    def material(self, source_material):
        """Return a copy of a source material naming the written textures."""
        material = copy.deepcopy(source_material)
        side_px = texture_side_px(material)
        slots = [material.get(slot) for slot in MATERIAL_TEXTURES]
        slots += [material.get("pbrMetallicRoughness", {}).get(slot) for slot in PBR_TEXTURES]
        for slot in slots:
            if slot is not None:
                if slot.get("texCoord", 0) != 0:
                    raise ValueError(f"{material['name']}: only TEXCOORD_0 is read")
                slot["index"] = self.index(slot["index"], side_px)
        return material


def attributes_for(material):
    """Return the vertex attributes a material draws with."""
    names = ["POSITION", "NORMAL"]
    pbr = material.get("pbrMetallicRoughness", {})
    if any(slot in material for slot in MATERIAL_TEXTURES) or any(
        slot in pbr for slot in PBR_TEXTURES
    ):
        names.append("TEXCOORD_0")
    if "normalTexture" in material:
        names.append("TANGENT")
    return names


def primitives(parts, materials):
    """Return `parts` merged by material as glTF primitives (attributes, indices, material)."""
    merged = []
    for material_index in sorted({part["material"] for part in parts}, key=str):
        material = materials[material_index]
        names = attributes_for(material)
        group = [part for part in parts if part["material"] == material_index]
        offsets = np.cumsum([0] + [len(part["POSITION"]) for part in group])
        attributes = {name: np.concatenate([part[name] for part in group]) for name in names}
        indices = np.concatenate(
            [part["indices"] + offset for part, offset in zip(group, offsets, strict=False)]
        )
        merged.append((attributes, indices.reshape(-1), material))
    return merged


def write(path, source=SOURCE):
    """Write the default car's model to `path`; return what the manifest measures from it.

    Positions are in the vehicle's ROS frame (x forward, y left, z up): `front_axle_x_m`,
    `rear_axle_x_m`, `track_m`, `wheel_radius_m`, `wheel_width_m`, `body_size_m`,
    `body_centre_m`, `driver_eye_m`, `stereo_mount_m` and the steering wheel's `steering_axis`.
    """
    gltf, binary = read_source(source)
    parts = read_parts(gltf, binary)
    placed = frame(gltf, parts)
    to_vehicle = -placed["origin"]
    wheel = [
        moved(part, -placed["wheel_centre"]) for name in WHEEL_PARTS for part in named(parts, name)
    ]
    steering = named(parts, STEERING_WHEEL)
    pivot, axis = steering_pivot(steering)
    body = [
        moved(part, to_vehicle)
        for part in parts
        if not part["name"].startswith(DROPPED_PREFIXES) and part["name"] != STEERING_WHEEL
    ]
    materials = {index: material for index, material in enumerate(gltf["materials"])}
    materials[None] = MIRROR_MATERIAL
    body += [moved(mirror_glass(named(parts, mirror)), to_vehicle) for mirror in DOOR_MIRRORS]
    glb = track_tiles.Glb()
    glb.gltf["asset"] = {
        "version": "2.0",
        "copyright": f"{CREDIT}. Modified: {MODIFICATIONS}",
        "extras": gltf["asset"].get("extras", {}),
    }
    textures = Textures(glb, gltf, binary)
    written = {index: textures.material(material) for index, material in materials.items()}
    glb.add_mesh("Body", primitives(body, written))
    glb.add_mesh("Wheel", primitives(wheel, written))
    glb.add_mesh(
        "Cockpit_Steer",
        primitives([moved(part, -pivot) for part in steering], written),
        translation=pivot + to_vehicle,
    )
    glb.write(path)
    body_positions = positions_of(body)
    low, high = body_positions.min(0), body_positions.max(0)
    return {
        "front_axle_x_m": placed["wheelbase_m"] / 2.0,
        "rear_axle_x_m": -placed["wheelbase_m"] / 2.0,
        "track_m": placed["track_m"],
        "wheel_radius_m": placed["wheel_radius_m"],
        "wheel_width_m": placed["wheel_width_m"],
        "body_size_m": ros(high - low),
        "body_centre_m": ros((high + low) / 2.0),
        "driver_eye_m": ros(driver_eye(parts) + to_vehicle),
        "stereo_mount_m": ros(stereo_mount(parts) + to_vehicle),
        "steering_axis": ros(axis),
    }


def ros(gltf_vector):
    """Return a glTF vector (+X left, +Y up, +Z forward) in the vehicle's ROS frame."""
    return [float(gltf_vector[2]), float(gltf_vector[0]), float(gltf_vector[1])]
