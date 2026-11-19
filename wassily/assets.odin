package wassily

import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "core:log"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "vendor:cgltf"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

// Loads a glTF/GLB file exported by tools/export_gltf.py. Call from init.
load_model :: proc(path: string) -> Model
{
	data, result := cgltf.parse_file({}, strings.clone_to_cstring(path, context.temp_allocator))
	if result != .success {
		log.panicf("wassily: could not parse model %q: %v", path, result)
	}
	defer cgltf.free(data)
	if result = cgltf.load_buffers({}, data, strings.clone_to_cstring(path, context.temp_allocator)); result != .success {
		log.panicf("wassily: could not load buffers of model %q: %v", path, result)
	}

	textures := make(map[^cgltf.image]Texture, allocator = context.temp_allocator)
	model: Model

	for &node, i in data.nodes {
		if node.mesh == nil {
			continue
		}

		vertices := make([dynamic]Vertex3D, context.temp_allocator)
		indices := make([dynamic]u32, context.temp_allocator)
		primitives := make([dynamic]Primitive)

		for &primitive in node.mesh.primitives {
			if primitive.type != .triangles {
				log.warnf("wassily: skipping non-triangle primitive in %q", path)
				continue
			}

			first_vertex := u32(len(vertices))
			first_index := u32(len(indices))
			color, texture := read_material(primitive.material, path, &textures)

			for attribute in primitive.attributes {
				if attribute.index != 0 {
					continue
				}
				#partial switch attribute.type {
				case .position:
					resize(&vertices, int(first_vertex) + int(attribute.data.count))
					positions := make([][3]f32, attribute.data.count, context.temp_allocator)
					_ = cgltf.accessor_unpack_floats(attribute.data, cast([^]f32)raw_data(positions), attribute.data.count * 3)
					for p, j in positions {
						vertices[int(first_vertex) + j].position = p
						vertices[int(first_vertex) + j].color = color
					}
				}
			}
			// UVs are read after positions so the vertex range exists.
			for attribute in primitive.attributes {
				if attribute.type == .texcoord && attribute.index == 0 {
					uvs := make([][2]f32, attribute.data.count, context.temp_allocator)
					_ = cgltf.accessor_unpack_floats(attribute.data, cast([^]f32)raw_data(uvs), attribute.data.count * 2)
					for uv, j in uvs {
						vertices[int(first_vertex) + j].uv = uv
					}
				}
			}

			vertex_count := u32(len(vertices)) - first_vertex
			if primitive.indices != nil {
				count := primitive.indices.count
				resize(&indices, len(indices) + int(count))
				_ = cgltf.accessor_unpack_indices(primitive.indices, raw_data(indices[first_index:]), size_of(u32), count)
				for &index in indices[first_index:] {
					index += first_vertex
				}
			} else {
				for j in 0 ..< vertex_count {
					append(&indices, first_vertex + j)
				}
			}

			append(&primitives, Primitive{first_index, u32(len(indices)) - first_index, texture})
		}

		if len(indices) == 0 {
			delete(primitives)
			continue
		}

		world: [16]f32
		cgltf.node_transform_world(&node, &world[0])

		mesh := Mesh {
			primitives = primitives[:],
			local      = linalg.matrix_cast(transmute(matrix[4, 4]f32)world, f64),
		}
		mesh.vertex_buffer, mesh.vertex_memory = create_device_local_buffer(slice.to_bytes(vertices[:]), {.VERTEX_BUFFER})
		mesh.index_buffer, mesh.index_memory = create_device_local_buffer(slice.to_bytes(indices[:]), {.INDEX_BUFFER})
		append(&g_meshes, mesh)

		name := strings.clone_from_cstring(node.name) if node.name != nil else fmt.aprintf("node_%v", i)
		model.objects[name] = mesh
	}

	append(&g_models, model)
	return model
}

// Returns the object with the given Blender object name.
model_mesh :: proc(model: Model, name: string) -> Mesh
{
	mesh, ok := model.objects[name]
	if !ok {
		names := make([dynamic]string, context.temp_allocator)
		for key in model.objects {
			append(&names, key)
		}
		log.panicf("wassily: model has no object %q; available: %v", name, names[:])
	}
	return mesh
}

// Loads a PNG/JPG/etc. as an sRGB texture. Call from init.
load_texture :: proc(path: string) -> Texture
{
	width, height, channels: i32
	pixels := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &width, &height, &channels, 4)
	if pixels == nil {
		log.panicf("wassily: could not load texture %q: %s", path, stbi.failure_reason())
	}
	defer stbi.image_free(pixels)

	return create_texture(u32(width), u32(height), pixels[:width * height * 4])
}

@(private = "file")
read_material :: proc(material: ^cgltf.material, path: string, textures: ^map[^cgltf.image]Texture) -> (color: [3]f32, texture: Texture)
{
	color = {1, 1, 1}
	if material == nil {
		return color, white_texture()
	}

	if material.extras.data != nil {
		Extras :: struct {
			wassily_color: [3]f32,
		}
		extras := Extras{color}
		text := string(cstring(rawptr(material.extras.data)))
		if json.unmarshal(transmute([]byte)text, &extras, allocator = context.temp_allocator) == nil {
			color = extras.wassily_color
		}
	}

	view := material.pbr_metallic_roughness.base_color_texture
	if !material.has_pbr_metallic_roughness || view.texture == nil || view.texture.image_ == nil {
		return color, white_texture()
	}

	image := view.texture.image_
	if cached, ok := textures[image]; ok {
		return color, cached
	}

	if image.buffer_view != nil {
		bytes := cgltf.buffer_view_data(image.buffer_view)
		width, height, channels: i32
		pixels := stbi.load_from_memory(bytes, i32(image.buffer_view.size), &width, &height, &channels, 4)
		if pixels == nil {
			log.panicf("wassily: could not decode texture in %q: %s", path, stbi.failure_reason())
		}
		defer stbi.image_free(pixels)
		texture = create_texture(u32(width), u32(height), pixels[:width * height * 4])
	} else {
		uri_path, _ := filepath.join({filepath.dir(path), string(image.uri)}, context.temp_allocator)
		texture = load_texture(uri_path)
	}

	textures[image] = texture
	return color, texture
}

@(private = "file")
white_texture :: proc() -> Texture
{
	if texture, ok := g_white_texture.?; ok {
		return texture
	}
	pixels := [4]byte{255, 255, 255, 255}
	texture := create_texture(1, 1, pixels[:])
	g_white_texture = texture
	return texture
}

@(private = "file")
create_texture :: proc(width, height: u32, pixels: []byte) -> Texture
{
	if len(g_textures) >= MAX_TEXTURES {
		log.panicf("wassily: more than %v textures loaded", MAX_TEXTURES)
	}

	texture: Texture
	texture.image, texture.memory = create_image(width, height, .R8G8B8A8_SRGB, {.TRANSFER_DST, .SAMPLED})
	upload_texture_pixels(texture.image, width, height, pixels)
	texture.view = create_image_view(texture.image, .R8G8B8A8_SRGB, {.COLOR})

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = g_descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &g_descriptor_set_layout,
	}
	must(vk.AllocateDescriptorSets(g_device, &alloc_info, &texture.descriptor_set))

	image_info := vk.DescriptorImageInfo {
		sampler     = g_sampler,
		imageView   = texture.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = texture.descriptor_set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)

	append(&g_textures, texture)
	return texture
}

destroy_assets :: proc()
{
	for mesh in g_meshes {
		vk.DestroyBuffer(g_device, mesh.vertex_buffer, nil)
		vk.FreeMemory(g_device, mesh.vertex_memory, nil)
		vk.DestroyBuffer(g_device, mesh.index_buffer, nil)
		vk.FreeMemory(g_device, mesh.index_memory, nil)
	}
	for texture in g_textures {
		vk.DestroyImageView(g_device, texture.view, nil)
		vk.DestroyImage(g_device, texture.image, nil)
		vk.FreeMemory(g_device, texture.memory, nil)
	}
	for mesh in g_meshes {
		delete(mesh.primitives)
	}
	for &model in g_models {
		for name in model.objects {
			delete(name)
		}
		delete(model.objects)
	}
	delete(g_meshes)
	delete(g_models)
	delete(g_textures)
}
