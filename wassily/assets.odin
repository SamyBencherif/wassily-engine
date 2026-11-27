package wassily

import "core:encoding/json"
import "core:fmt"
import "core:math"
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
	collider := make([dynamic]Triangle)
	pending := make([dynamic]Pending_Mesh, context.temp_allocator)
	lights := make([dynamic]Point_Light, context.temp_allocator)

	for &node, i in data.nodes {
		if node.light != nil {
			if node.light.type == .point {
				world: [16]f32
				cgltf.node_transform_world(&node, &world[0])
				color := linalg.array_cast(node.light.color, f64) * f64(node.light.intensity)
				append(&lights, Point_Light{{f64(world[12]), f64(world[13]), f64(world[14])}, color})
			} else {
				log.warnf("wassily: skipping %v light in %q; only point lights are baked", node.light.type, path)
			}
			continue
		}
		if node.name != nil && string(node.name) == "_spawn" {
			world: [16]f32
			cgltf.node_transform_world(&node, &world[0])
			m := linalg.matrix_cast(transmute(matrix[4, 4]f32)world, f64)
			// Blender's local Z is glTF's local Y after the Y-up conversion.
			facing := m[1].xyz
			model.spawn = Spawn{m[3].xyz, math.atan2(facing.x, facing.z) * 180 / math.PI}
			continue
		}
		if node.mesh == nil {
			if node.name != nil {
				world: [16]f32
				cgltf.node_transform_world(&node, &world[0])
				model.markers[strings.clone_from_cstring(node.name)] = {f64(world[12]), f64(world[13]), f64(world[14])}
			}
			continue
		}

		vertices := make([dynamic]Vertex3D, context.temp_allocator)
		normals := make([dynamic][3]f32, context.temp_allocator)
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
			resize(&normals, len(vertices))
			// UVs and normals are read after positions so the vertex range exists.
			for attribute in primitive.attributes {
				if attribute.type == .texcoord && attribute.index == 0 {
					uvs := make([][2]f32, attribute.data.count, context.temp_allocator)
					_ = cgltf.accessor_unpack_floats(attribute.data, cast([^]f32)raw_data(uvs), attribute.data.count * 2)
					for uv, j in uvs {
						vertices[int(first_vertex) + j].uv = uv
					}
				}
				if attribute.type == .normal && attribute.index == 0 {
					_ = cgltf.accessor_unpack_floats(attribute.data, cast([^]f32)raw_data(normals[first_vertex:]), attribute.data.count * 3)
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

		local := linalg.matrix_cast(transmute(matrix[4, 4]f32)world, f64)

		if node.name != nil && strings.has_prefix(string(node.name), "_collider") {
			delete(primitives)
			for i := 0; i + 2 < len(indices); i += 3 {
				triangle: Triangle
				for k in 0 ..< 3 {
					p := linalg.array_cast(vertices[indices[i + k]].position, f64)
					triangle[k] = (local * [4]f64{p.x, p.y, p.z, 1}).xyz
				}
				append(&collider, triangle)
			}
			continue
		}

		name := strings.clone_from_cstring(node.name) if node.name != nil else fmt.aprintf("node_%v", i)
		append(&pending, Pending_Mesh{name, local, vertices[:], normals[:], indices[:], primitives[:]})
	}

	ambient := [3]f64{1, 1, 1}
	if len(lights) > 0 {
		ambient = scene_ambient(data)
	}
	bake_lights(pending[:], lights[:], ambient)

	for p in pending {
		triangles := make([]Triangle, len(p.indices) / 3)
		for &triangle, t in triangles {
			for k in 0 ..< 3 {
				triangle[k] = linalg.array_cast(p.vertices[p.indices[t * 3 + k]].position, f64)
			}
		}

		mesh := Mesh {
			primitives = p.primitives,
			local      = p.local,
			triangles  = triangles,
		}
		mesh.vertex_buffer, mesh.vertex_memory = create_device_local_buffer(slice.to_bytes(p.vertices), {.VERTEX_BUFFER})
		mesh.index_buffer, mesh.index_memory = create_device_local_buffer(slice.to_bytes(p.indices), {.INDEX_BUFFER})
		append(&g_meshes, mesh)
		model.objects[p.name] = mesh
	}

	model.collider = collider[:]
	append(&g_models, model)
	return model
}

@(private = "file")
Pending_Mesh :: struct {
	name: string,
	local: matrix[4, 4]f64,
	vertices: []Vertex3D,
	normals: [][3]f32,
	indices: []u32,
	primitives: []Primitive,
}

// World space; color is premultiplied by Blender power in watts.
@(private = "file")
Point_Light :: struct {
	position: Vector3,
	color: [3]f64,
}

// The "wassily_ambient" scene extra written by tools/export_gltf.py (Blender world color).
@(private = "file")
scene_ambient :: proc(data: ^cgltf.data) -> [3]f64
{
	if data.scene == nil || data.scene.extras.data == nil {
		return {}
	}
	Extras :: struct {
		wassily_ambient: [3]f64,
	}
	extras: Extras
	text := string(cstring(rawptr(data.scene.extras.data)))
	_ = json.unmarshal(transmute([]byte)text, &extras, allocator = context.temp_allocator)
	return extras.wassily_ambient
}

// Writes per-vertex irradiance from point lights (Lambert, inverse square, hard shadows
// cast by every visible mesh) into Vertex3D.light. Without lights, everything is fully lit.
@(private = "file")
bake_lights :: proc(meshes: []Pending_Mesh, lights: []Point_Light, ambient: [3]f64)
{
	occluders := make([dynamic]Triangle, context.temp_allocator)
	for m in meshes {
		for i := 0; i + 2 < len(m.indices); i += 3 {
			triangle: Triangle
			for k in 0 ..< 3 {
				p := linalg.array_cast(m.vertices[m.indices[i + k]].position, f64)
				triangle[k] = (m.local * [4]f64{p.x, p.y, p.z, 1}).xyz
			}
			append(&occluders, triangle)
		}
	}

	SHADOW_BIAS :: 0.01
	for m in meshes {
		normal_matrix := linalg.inverse_transpose((matrix[3, 3]f64)(m.local))
		for &vertex, v in m.vertices {
			if len(lights) == 0 {
				vertex.light = {1, 1, 1}
				continue
			}
			p := linalg.array_cast(vertex.position, f64)
			position := (m.local * [4]f64{p.x, p.y, p.z, 1}).xyz
			normal := linalg.normalize0(normal_matrix * linalg.array_cast(m.normals[v], f64))
			origin := position + normal * SHADOW_BIAS

			total := ambient
			for light in lights {
				to_light := light.position - position
				distance_sq := linalg.dot(to_light, to_light)
				distance := math.sqrt(distance_sq)
				direction := to_light / distance
				cosine := linalg.dot(normal, direction)
				if cosine <= 0 || ray_blocked(origin, light.position, occluders[:]) {
					continue
				}
				// Matches Blender: a point light of P watts gives radiance P / (4 pi^2 d^2) off white Lambert.
				total += light.color * cosine / (4 * math.PI * math.PI * distance_sq)
			}
			vertex.light = linalg.array_cast(total, f32)
		}
	}
}

// Whether the segment from a to b crosses any triangle (Moller-Trumbore).
@(private = "file")
ray_blocked :: proc(a, b: Vector3, triangles: []Triangle) -> bool
{
	direction := b - a
	for t in triangles {
		e1 := t[1] - t[0]
		e2 := t[2] - t[0]
		h := linalg.cross(direction, e2)
		det := linalg.dot(e1, h)
		if abs(det) < 1e-12 {
			continue
		}
		inv := 1 / det
		s := a - t[0]
		u := inv * linalg.dot(s, h)
		if u < 0 || u > 1 {
			continue
		}
		q := linalg.cross(s, e1)
		w := inv * linalg.dot(direction, q)
		if w < 0 || u + w > 1 {
			continue
		}
		hit := inv * linalg.dot(e2, q)
		if hit > 0 && hit < 0.999 {
			return true
		}
	}
	return false
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
		delete(mesh.triangles)
	}
	for &model in g_models {
		for name in model.objects {
			delete(name)
		}
		delete(model.objects)
		for name in model.markers {
			delete(name)
		}
		delete(model.markers)
		delete(model.collider)
	}
	delete(g_meshes)
	delete(g_models)
	delete(g_textures)
}
