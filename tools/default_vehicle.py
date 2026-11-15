"""Write the default vehicle pack: a generic compact car, from code alone, CC0.

Its dimensions are about OVCS1's (2.44 m wheelbase, 1.4 m track, 0.3 m wheel radius). Its
model, `vehicle.glb`, is a provisional placeholder of boxes and a cylinder: pack.json names
the model, so a finished one replaces the file without touching anything else.

Needs numpy.
"""

import math

import numpy as np
import track_tiles

VEHICLE_ID = "default_car"
MODEL = "vehicle.glb"
FRONT_AXLE_X_M = 1.22
REAR_AXLE_X_M = -1.22
TRACK_M = 1.4
WHEEL_RADIUS_M = 0.3
WHEEL_WIDTH_M = 0.2
WHEEL_SEGMENTS = 24
PAINT = {
    "name": "Paint",
    "pbrMetallicRoughness": {
        "baseColorFactor": [0.55, 0.56, 0.6, 1.0],
        "metallicFactor": 0.6,
        "roughnessFactor": 0.35,
    },
}
GLASS = {
    "name": "Glass",
    "alphaMode": "BLEND",
    "pbrMetallicRoughness": {
        "baseColorFactor": [0.02, 0.03, 0.035, 0.75],
        "metallicFactor": 0.0,
        "roughnessFactor": 0.05,
    },
}
TRIM = {
    "name": "Trim",
    "pbrMetallicRoughness": {
        "baseColorFactor": [0.03, 0.03, 0.03, 1.0],
        "metallicFactor": 0.0,
        "roughnessFactor": 0.7,
    },
}
HEADLIGHT = {
    "name": "Headlight",
    "emissiveFactor": [0.6, 0.6, 0.55],
    "pbrMetallicRoughness": {"baseColorFactor": [0.9, 0.9, 0.85, 1.0], "roughnessFactor": 0.1},
}
TAIL_LIGHT = {
    "name": "Tail_Light",
    "emissiveFactor": [0.4, 0.0, 0.0],
    "pbrMetallicRoughness": {"baseColorFactor": [0.6, 0.02, 0.02, 1.0], "roughnessFactor": 0.2},
}
TYRE = {
    "name": "Tyre",
    "doubleSided": True,
    "pbrMetallicRoughness": {
        "baseColorFactor": [0.03, 0.03, 0.03, 1.0],
        "metallicFactor": 0.0,
        "roughnessFactor": 0.9,
    },
}
RIM = {
    "name": "Rim",
    "doubleSided": True,
    "pbrMetallicRoughness": {
        "baseColorFactor": [0.6, 0.6, 0.62, 1.0],
        "metallicFactor": 0.9,
        "roughnessFactor": 0.3,
    },
}
# The body's boxes in the vehicle's ROS frame: centre, size and material.
BODY_BOXES = (
    ((0.0, 0.0, 0.7), (3.9, 1.56, 0.5), PAINT),
    ((-0.32, 0.0, 1.17), (1.9, 1.36, 0.44), GLASS),
    ((-0.32, 0.0, 1.41), (1.8, 1.3, 0.05), PAINT),
    ((1.97, 0.0, 0.5), (0.06, 1.52, 0.2), TRIM),
    ((-1.97, 0.0, 0.5), (0.06, 1.52, 0.2), TRIM),
    ((1.955, 0.58, 0.78), (0.03, 0.32, 0.1), HEADLIGHT),
    ((1.955, -0.58, 0.78), (0.03, 0.32, 0.1), HEADLIGHT),
    ((-1.955, 0.62, 0.8), (0.03, 0.28, 0.1), TAIL_LIGHT),
    ((-1.955, -0.62, 0.8), (0.03, 0.28, 0.1), TAIL_LIGHT),
)


def gltf_vector(ros):
    """Return a vehicle ROS vector (x forward, y left, z up) in glTF's frame (+X left, +Y up)."""
    return [ros[1], ros[2], ros[0]]


def box(centre_m, size_m, material):
    """Return a box as a glTF primitive: (attributes, indices, material), flat-shaded."""
    centre, half = np.array(gltf_vector(centre_m)), np.array(gltf_vector(size_m)) / 2.0
    positions, normals, indices = [], [], []
    for axis in range(3):
        for sign in (-1.0, 1.0):
            normal = np.zeros(3)
            normal[axis] = sign
            first, second = [other for other in range(3) if other != axis]
            if (sign < 0) != (axis == 1):
                first, second = second, first
            # A face's corners run counter-clockwise seen from outside.
            for along_first, along_second in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                corner = normal.copy()
                corner[first], corner[second] = along_first, along_second
                positions.append(centre + corner * half)
                normals.append(normal)
            start = len(positions) - 4
            indices += [start, start + 1, start + 2, start, start + 2, start + 3]
    attributes = {"POSITION": np.array(positions), "NORMAL": np.array(normals)}
    return attributes, np.array(indices, np.uint32), material


def wheel():
    """Return the wheel's primitives: a tyre along glTF's X, its rim on the outer face (+X)."""
    angles = np.linspace(0.0, math.tau, WHEEL_SEGMENTS, endpoint=False)
    ring = np.stack([np.zeros_like(angles), np.sin(angles), np.cos(angles)], -1)
    half = WHEEL_WIDTH_M / 2.0
    tread = np.concatenate(
        [ring * WHEEL_RADIUS_M + [-half, 0, 0], ring * WHEEL_RADIUS_M + [half, 0, 0]]
    )
    tread_normals = np.concatenate([ring, ring])
    count = WHEEL_SEGMENTS
    tread_indices = []
    for index in range(count):
        following = (index + 1) % count
        tread_indices += [
            index,
            following,
            count + following,
            index,
            count + following,
            count + index,
        ]
    primitives = [
        ({"POSITION": tread, "NORMAL": tread_normals}, np.array(tread_indices, np.uint32), TYRE)
    ]
    # The rim stands a millimetre proud of the tyre's outer face.
    caps = (
        (-1.0, WHEEL_RADIUS_M, TYRE, 0.0),
        (1.0, WHEEL_RADIUS_M, TYRE, 0.0),
        (1.0, 0.2, RIM, 0.001),
    )
    for side, radius_m, material, proud_m in caps:
        cap = np.concatenate([[[0.0, 0.0, 0.0]], ring * radius_m]) + [side * (half + proud_m), 0, 0]
        normals = np.tile([side, 0.0, 0.0], (len(cap), 1))
        fan = []
        for index in range(count):
            following = (index + 1) % count
            fan += [0, 1 + index, 1 + following] if side > 0 else [0, 1 + following, 1 + index]
        primitives.append(
            ({"POSITION": cap, "NORMAL": normals}, np.array(fan, np.uint32), material)
        )
    return primitives


def write_model(path):
    """Write the placeholder model: a `Body` of boxes and a `Wheel`."""
    glb = track_tiles.Glb()
    glb.add_mesh("Body", [box(*part) for part in BODY_BOXES])
    glb.add_mesh("Wheel", wheel())
    glb.write(path)


def manifest():
    """Return the default vehicle's pack.json."""
    return {
        "format": 1,
        "kind": "vehicle",
        "id": VEHICLE_ID,
        "name": "Default compact car",
        "version": "0.1.0",
        "licence": "CC0-1.0",
        "attribution": ["Model: a provisional placeholder built by tools/default_vehicle.py, CC0"],
        "vehicle": {
            "model": MODEL,
            "front_axle_x_m": FRONT_AXLE_X_M,
            "rear_axle_x_m": REAR_AXLE_X_M,
            "front_track_m": TRACK_M,
            "rear_track_m": TRACK_M,
            "wheel_radius_m": WHEEL_RADIUS_M,
            "wheel_width_m": WHEEL_WIDTH_M,
            "max_lateral_acceleration_m_s2": 8.0,
            # A front-wheel drive compact: 60 % of its weight on the front axle.
            "mass_kg": 1200.0,
            "centre_of_gravity_x_m": round(
                REAR_AXLE_X_M + 0.6 * (FRONT_AXLE_X_M - REAR_AXLE_X_M), 4
            ),
            "centre_of_gravity_height_m": 0.55,
            "yaw_inertia_kg_m2": 1750.0,
            "front_cornering_stiffness_n_per_rad": 100000.0,
            "rear_cornering_stiffness_n_per_rad": 95000.0,
            "driven_axle": "front",
            "body": {"size_m": [3.9, 1.56, 0.99], "centre_m": [0.0, 0.0, 0.94]},
            "driver_eye_m": [-0.35, 0.36, 1.2],
            "driver_pitch_deg": -3.0,
            "stereo": {
                "mount_m": [0.5, 0.0, 1.32],
                "width_px": 1280,
                "height_px": 720,
                "hfov_deg": 90.0,
                "baseline_m": 0.12,
                "pitch_deg": 0.0,
                "rate_hz": 15.0,
            },
        },
    }


def write(directory):
    """Write the default vehicle pack's model into `directory`; return its manifest."""
    directory.mkdir(parents=True, exist_ok=True)
    write_model(directory / MODEL)
    return manifest()
