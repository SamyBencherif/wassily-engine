package wassily

import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import stbi "vendor:stb/image"
import vk "vendor:vulkan"

// Loads a Wavefront OBJ (positions, UVs; faces are fan-triangulated). Call from init.
load_mesh :: proc(path: string) -> Mesh
{
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.panicf("wassily: could not read mesh %q: %v", path, err)
	}

	positions := make([dynamic][3]f32, context.temp_allocator)
	uvs := make([dynamic][2]f32, context.temp_allocator)
	vertices := make([dynamic]Vertex3D, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}

		switch fields[0] {
		case "v":
			append(&positions, [3]f32{parse_f32(fields[1]), parse_f32(fields[2]), parse_f32(fields[3])})
		case "vt":
			// OBJ puts the UV origin bottom-left; Vulkan samples from top-left.
			append(&uvs, [2]f32{parse_f32(fields[1]), 1 - parse_f32(fields[2])})
		case "f":
			first := u32(len(vertices))
			for corner in fields[1:] {
				parts := strings.split(corner, "/", context.temp_allocator)
				vertex := Vertex3D{color = {1, 1, 1}}
				vertex.position = positions[obj_index(parts[0], len(positions))]
				if len(parts) > 1 && parts[1] != "" {
					vertex.uv = uvs[obj_index(parts[1], len(uvs))]
				}
				append(&vertices, vertex)
			}
			for i in 1 ..< u32(len(fields) - 2) {
				append(&indices, first, first + i, first + i + 1)
			}
		}
	}

	mesh: Mesh
	mesh.vertex_buffer, mesh.vertex_memory = create_device_local_buffer(slice.to_bytes(vertices[:]), {.VERTEX_BUFFER})
	mesh.index_buffer, mesh.index_memory = create_device_local_buffer(slice.to_bytes(indices[:]), {.INDEX_BUFFER})
	mesh.index_count = u32(len(indices))
	append(&g_meshes, mesh)
	return mesh
}

// Loads a PNG/JPG/etc. as an sRGB texture. Call from init.
load_texture :: proc(path: string) -> Texture
{
	if len(g_textures) >= MAX_TEXTURES {
		log.panicf("wassily: more than %v textures loaded", MAX_TEXTURES)
	}

	width, height, channels: i32
	pixels := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &width, &height, &channels, 4)
	if pixels == nil {
		log.panicf("wassily: could not load texture %q: %s", path, stbi.failure_reason())
	}
	defer stbi.image_free(pixels)

	texture: Texture
	texture.image, texture.memory = create_image(u32(width), u32(height), .R8G8B8A8_SRGB, {.TRANSFER_DST, .SAMPLED})
	upload_texture_pixels(texture.image, u32(width), u32(height), pixels[:width * height * 4])
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
	delete(g_meshes)
	delete(g_textures)
}

@(private = "file")
parse_f32 :: proc(s: string) -> f32
{
	value, _ := strconv.parse_f32(s)
	return value
}

// OBJ indices are 1-based; negative values count back from the end.
@(private = "file")
obj_index :: proc(s: string, count: int) -> int
{
	i, ok := strconv.parse_int(s)
	if !ok || i == 0 || abs(i) > count {
		log.panicf("wassily: bad OBJ index %q", s)
	}
	return i - 1 if i > 0 else count + i
}
