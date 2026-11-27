# Usage: blender -b input.blend --python tools/export_gltf.py -- output.glb
import sys

import bpy


def material_color(material):
    if material.node_tree is None:
        return [1.0, 1.0, 1.0]
    for node in material.node_tree.nodes:
        if node.type != "BSDF_PRINCIPLED":
            continue
        coat_weight = node.inputs["Coat Weight"]
        coat_tint = node.inputs["Coat Tint"]
        if (coat_weight.is_linked or coat_weight.default_value > 0) and not coat_tint.is_linked:
            return list(coat_tint.default_value[:3])
        base_color = node.inputs["Base Color"]
        if not base_color.is_linked:
            return list(base_color.default_value[:3])
        return [1.0, 1.0, 1.0]
    return [1.0, 1.0, 1.0]


def world_color(world):
    if world is None:
        return [0.0, 0.0, 0.0]
    if world.node_tree is not None:
        for node in world.node_tree.nodes:
            if node.type == "BACKGROUND" and not node.inputs["Color"].is_linked:
                strength = node.inputs["Strength"].default_value
                return [c * strength for c in node.inputs["Color"].default_value[:3]]
    return list(world.color[:3])


def main():
    output = sys.argv[sys.argv.index("--") + 1]

    # Written as glTF material extras; the engine multiplies it with the texture.
    for material in bpy.data.materials:
        material["wassily_color"] = material_color(material)

    # Scene extras; ambient term for baked lighting.
    scene = bpy.context.scene
    scene["wassily_ambient"] = world_color(scene.world)

    bpy.ops.export_scene.gltf(
        filepath=output,
        export_format="GLB",
        export_extras=True,
        export_apply=True,
        export_yup=True,
        export_lights=True,
        # Point light intensity stays in Blender watts; the engine converts.
        export_import_convert_lighting_mode="RAW",
    )


main()
