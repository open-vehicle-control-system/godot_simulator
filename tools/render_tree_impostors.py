"""Render tree impostor atlases from a Blender file, run by a Python with Blender's bpy.

    python render_tree_impostors.py MODEL.blend OUT_DIR OBJECT... --views=N --card-px=PX

For each named object (a tree variant's LOD0 mesh) writes OUT_DIR/<object without _LOD0>.png:
N orthographic side views over half a turn, side by side, each PX wide, on a transparent
background, lit by a sun and a pale sky; and adds its view's width and height in metres to
OUT_DIR/sizes.json. The experiment's make_tree_impostors.py, with Cycles' seed and sampling
fixed so the render repeats. tree_impostors.py runs it.
"""

import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

SAMPLES = 48
SKY_COLOUR = (0.55, 0.62, 0.72, 1.0)
SKY_STRENGTH = 0.9
SUN_ENERGY = 2.5
SUN_ROTATION_DEG = (40.0, 0.0, 30.0)
# The crown's width is framed at this share of the bounding box's diagonal half-width.
CROWN_SHARE = 0.8


def set_up_render(width_px, height_px):
    """Set the scene to render a transparent, repeatable Cycles image of this size."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.seed = 0
    scene.cycles.use_animated_seed = False
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.render.film_transparent = True
    scene.render.resolution_x, scene.render.resolution_y = width_px, height_px
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("ImpostorSky")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = SKY_COLOUR
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = SKY_STRENGTH
    sun = bpy.data.lights.new("ImpostorSun", "SUN")
    sun.energy = SUN_ENERGY
    placed = bpy.data.objects.new("ImpostorSun", sun)
    placed.rotation_euler = tuple(math.radians(angle) for angle in SUN_ROTATION_DEG)
    scene.collection.objects.link(placed)


def bounds(placed):
    """Return the lowest and highest corners of an object's box in the world."""
    corners = [placed.matrix_world @ Vector(corner) for corner in placed.bound_box]
    low = Vector([min(corner[axis] for corner in corners) for axis in range(3)])
    high = Vector([max(corner[axis] for corner in corners) for axis in range(3)])
    return low, high


def render_variant(name, out_dir, views, card_px):
    """Render one variant's views; return their files, the view's width and height in metres."""
    tree = bpy.data.objects[name]
    for placed in bpy.context.scene.objects:
        if placed.type in ("MESH", "CURVE"):
            placed.hide_render = placed is not tree
    low, high = bounds(tree)
    base = Vector(((low.x + high.x) / 2, (low.y + high.y) / 2, low.z))
    height_m = high.z - low.z
    radius_m = CROWN_SHARE * max(
        (Vector((x, y, 0)) - Vector((base.x, base.y, 0))).length
        for x in (low.x, high.x)
        for y in (low.y, high.y)
    )
    width_m = 2 * radius_m
    height_px = int(round(card_px * height_m / width_m / 8) * 8)
    set_up_render(card_px, height_px)
    camera_data = bpy.data.cameras.new("ImpostorCamera")
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = max(width_m, height_m)
    camera = bpy.data.objects.new("ImpostorCamera", camera_data)
    bpy.context.scene.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    centre = base + Vector((0, 0, height_m / 2))
    frames = []
    for view in range(views):
        angle = math.pi * view / views
        towards = Vector((math.cos(angle), math.sin(angle), 0))
        camera.location = centre - towards * 100
        camera.rotation_euler = towards.to_track_quat("-Z", "Y").to_euler()
        frame = out_dir / f"_{name}_{view}.png"
        bpy.context.scene.render.filepath = str(frame)
        bpy.ops.render.render(write_still=True)
        frames.append(frame)
    bpy.data.objects.remove(camera)
    return frames, width_m, height_m, height_px


def main(blend, out_dir, names, views, card_px):
    """Render each named variant of `blend` into an atlas in `out_dir`."""
    from PIL import Image

    out_dir.mkdir(parents=True, exist_ok=True)
    sizes_path = out_dir / "sizes.json"
    sizes = json.loads(sizes_path.read_text()) if sizes_path.exists() else {}
    bpy.ops.wm.open_mainfile(filepath=str(blend.resolve()))
    for name in names:
        frames, width_m, height_m, height_px = render_variant(name, out_dir, views, card_px)
        atlas = Image.new("RGBA", (card_px * views, height_px))
        for view, frame in enumerate(frames):
            with Image.open(frame) as image:
                atlas.paste(image, (view * card_px, 0))
            frame.unlink()
        variant = name.removesuffix("_LOD0")
        atlas.save(out_dir / f"{variant}.png")
        sizes[variant] = [round(width_m, 2), round(height_m, 2)]
        print("impostor", variant, sizes[variant])
    sizes_path.write_text(json.dumps(sizes, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    positional = [argument for argument in sys.argv[1:] if not argument.startswith("--")]
    options = dict(
        argument[2:].split("=", 1) for argument in sys.argv[1:] if argument.startswith("--")
    )
    main(
        Path(positional[0]),
        Path(positional[1]),
        positional[2:],
        int(options["views"]),
        int(options["card-px"]),
    )
