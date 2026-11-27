/*
Vulkan triangle example by laytan, source:
https://gist.github.com/laytan/ba57af3e5a59ab5cb2fca9e25bcfe262

Compile and run using:

	odin run .

This example comes with pre-compiled shaders. During compilation the shaders
will be loaded from `vert.spv` and `frag.spv`.

If you make any changes to the shader source files (`shader.vert` or
`shader.frag`), then you must recompile them using `glslc`:

	glslc shader.vert -o vert.spv
	glslc shader.frag -o frag.spv

`glslc` is part of the Vulkan SDK, which you can find here:
https://vulkan.lunarg.com/sdk/home

This example uses glfw for window management.
*/
package wassily

import "base:runtime"

import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"

import "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Darwin {
	// NOTE: just a bogus import of the system library,
	// needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
	// when trying to load vulkan.
	@(require, extra_linker_flags = "-rpath /usr/local/lib")
	foreign import __ "system:System.framework"
}

SHADER_VERT :: #load("vert.spv")
SHADER_FRAG :: #load("frag.spv")
SHADER_MESH_VERT :: #load("mesh_vert.spv")
SHADER_MESH_FRAG :: #load("mesh_frag.spv")
SHADER_LINE_VERT :: #load("line_vert.spv")

// Enables Vulkan debug logging and validation layers.
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

MAX_FRAMES_IN_FLIGHT :: 2

g_ctx: runtime.Context

g_window: glfw.WindowHandle

g_framebuffer_resized: bool

g_instance: vk.Instance
g_physical_device: vk.PhysicalDevice
g_device: vk.Device
g_surface: vk.SurfaceKHR
g_graphics_queue: vk.Queue
g_present_queue: vk.Queue

g_swapchain: vk.SwapchainKHR
g_swapchain_images: []vk.Image
g_swapchain_views: []vk.ImageView
g_swapchain_format: vk.SurfaceFormatKHR
g_swapchain_extent: vk.Extent2D
g_swapchain_frame_buffers: []vk.Framebuffer

g_depth_format: vk.Format
g_depth_image: vk.Image
g_depth_memory: vk.DeviceMemory
g_depth_view: vk.ImageView

g_render_pass: vk.RenderPass
g_pipeline_layout: vk.PipelineLayout
g_pipeline: vk.Pipeline
g_mesh_pipeline_layout: vk.PipelineLayout
// Indexed [opaque/blend/filter][double_sided]; all share g_mesh_pipeline_layout.
g_mesh_pipelines: [3][2]vk.Pipeline
g_line_pipeline_layout: vk.PipelineLayout
g_line_pipeline: vk.Pipeline
g_rect_pipeline_layout: vk.PipelineLayout
g_rect_pipeline: vk.Pipeline

g_frame_set_layout: vk.DescriptorSetLayout
g_frame_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet
g_frame_buffers: [MAX_FRAMES_IN_FLIGHT]vk.Buffer
g_frame_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory
g_frame_mapped: [MAX_FRAMES_IN_FLIGHT]rawptr

g_descriptor_set_layout: vk.DescriptorSetLayout
g_descriptor_pool: vk.DescriptorPool
g_sampler: vk.Sampler

g_command_pool: vk.CommandPool
g_command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer

g_image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence

MAX_VERTICES :: 1 << 16

// One buffer per frame in flight so the CPU never writes a buffer the GPU is still reading.
Vertex_Stream :: struct {
	buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	counts:   [MAX_FRAMES_IN_FLIGHT]u32,
}

g_vertex_stream: Vertex_Stream
g_vertices: [dynamic]Vertex2D

// KHR_PORTABILITY_SUBSET_EXTENSION_NAME :: "VK_KHR_portability_subset"

DEVICE_EXTENSIONS := []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	// KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
}

@(require_results)
pick_physical_device :: proc() -> vk.Result {

	score_physical_device :: proc(device: vk.PhysicalDevice) -> (score: int) {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)

		name := byte_arr_str(&props.deviceName)
		log.infof("vulkan: evaluating device %q", name)
		defer log.infof("vulkan: device %q scored %v", name, score)

		features: vk.PhysicalDeviceFeatures
		vk.GetPhysicalDeviceFeatures(device, &features)

		// Need certain extensions supported.
		{
			extensions, result := physical_device_extensions(device, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: enumerate device extension properties failed: %v", result)
				return 0
			}

			required_loop: for required in DEVICE_EXTENSIONS {
				for &extension in extensions {
					extension_name := byte_arr_str(&extension.extensionName)
					if extension_name == string(required) {
						continue required_loop
					}
				}

				log.infof("vulkan: device does not support required extension %q", required)
				return 0
			}
		}

		// Check if swapchain is adequately supported.
		{
			support, result := query_swapchain_support(device, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: query swapchain support failure: %v", result)
				return 0
			}

			// Need at least a format and present mode.
			if len(support.formats) == 0 || len(support.presentModes) == 0 {
				log.info("vulkan: device does not support swapchain")
				return 0
			}
		}

		families := find_queue_families(device)
		if _, has_graphics := families.graphics.?; !has_graphics {
			log.info("vulkan: device does not have a graphics queue")
			return 0
		}
		if _, has_present := families.present.?; !has_present {
			log.info("vulkan: device does not have a presentation queue")
			return 0
		}

		// Favor GPUs.
		switch props.deviceType {
		case .DISCRETE_GPU:
			score += 300_000
		case .INTEGRATED_GPU:
			score += 200_000
		case .VIRTUAL_GPU:
			score += 100_000
		case .CPU, .OTHER:
		}
		log.infof("vulkan: scored %i based on device type %v", score, props.deviceType)

		// Maximum texture size.
		score += int(props.limits.maxImageDimension2D)
		log.infof(
			"vulkan: added the max 2D image dimensions (texture size) of %v to the score",
			props.limits.maxImageDimension2D,
		)
		return
	}

	count: u32
	vk.EnumeratePhysicalDevices(g_instance, &count, nil) or_return
	if count == 0 {log.panic("vulkan: no GPU found")}

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g_instance, &count, raw_data(devices)) or_return

	best_device_score := -1
	for device in devices {
		if score := score_physical_device(device); score > best_device_score {
			g_physical_device = device
			best_device_score = score
		}
	}

	if best_device_score <= 0 {
		log.panic("vulkan: no suitable GPU found")
	}
	return .SUCCESS
}

Queue_Family_Indices :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

find_queue_families :: proc(device: vk.PhysicalDevice) -> (ids: Queue_Family_Indices) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if .GRAPHICS in family.queueFlags {
			ids.graphics = u32(i)
		}

		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), g_surface, &supported)
		if supported {
			ids.present = u32(i)
		}

		// Found all needed queues?
		_, has_graphics := ids.graphics.?
		_, has_present := ids.present.?
		if has_graphics && has_present {
			break
		}
	}

	return
}

Swapchain_Support :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}

query_swapchain_support :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
) -> (
	support: Swapchain_Support,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, g_surface, &support.capabilities) or_return

	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, g_surface, &count, nil) or_return

		support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, g_surface, &count, raw_data(support.formats)) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, g_surface, &count, nil) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, g_surface, &count, raw_data(support.presentModes)) or_return
	}

	return
}

choose_swapchain_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}

	// Fallback non optimal.
	return formats[0]
}

choose_swapchain_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// FIFO (vsync) caps loopfn to the display rate, so per-frame animation runs at a steady speed.
	return .FIFO
}

choose_swapchain_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(g_window)
	return(
		vk.Extent2D {
			width = clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
			height = clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
		} \
	)
}

glfw_error_callback :: proc "c" (code: i32, description: cstring) {
	context = g_ctx
	log.errorf("glfw: %i: %s", code, description)
}

vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = g_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}

physical_device_extensions :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
) -> (
	exts: []vk.ExtensionProperties,
	res: vk.Result,
) {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) or_return

	exts = make([]vk.ExtensionProperties, count, allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(exts)) or_return

	return
}

create_swapchain :: proc() {
	indices := find_queue_families(g_physical_device)

	// Setup swapchain.
	{
		support, result := query_swapchain_support(g_physical_device, context.temp_allocator)
		if result != .SUCCESS {
			log.panicf("vulkan: query swapchain failed: %v", result)
		}

		surface_format := choose_swapchain_surface_format(support.formats)
		present_mode := choose_swapchain_present_mode(support.presentModes)
		extent := choose_swapchain_extent(support.capabilities)

		g_swapchain_format = surface_format
		g_swapchain_extent = extent

		image_count := support.capabilities.minImageCount + 1
		if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
			image_count = support.capabilities.maxImageCount
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = g_surface,
			minImageCount    = image_count,
			imageFormat      = surface_format.format,
			imageColorSpace  = surface_format.colorSpace,
			imageExtent      = extent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = support.capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = present_mode,
			clipped          = true,
		}

		if indices.graphics != indices.present {
			create_info.imageSharingMode = .CONCURRENT
			create_info.queueFamilyIndexCount = 2
			create_info.pQueueFamilyIndices = raw_data([]u32{indices.graphics.?, indices.present.?})
		}

		must(vk.CreateSwapchainKHR(g_device, &create_info, nil, &g_swapchain))
	}

	// Setup swapchain images.
	{
		count: u32
		must(vk.GetSwapchainImagesKHR(g_device, g_swapchain, &count, nil))

		g_swapchain_images = make([]vk.Image, count)
		g_swapchain_views = make([]vk.ImageView, count)
		must(vk.GetSwapchainImagesKHR(g_device, g_swapchain, &count, raw_data(g_swapchain_images)))

		for image, i in g_swapchain_images {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = g_swapchain_format.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			must(vk.CreateImageView(g_device, &create_info, nil, &g_swapchain_views[i]))
		}
	}
}

destroy_swapchain :: proc() {
	for view in g_swapchain_views {
		vk.DestroyImageView(g_device, view, nil)
	}
	delete(g_swapchain_views)
	delete(g_swapchain_images)
	vk.DestroySwapchainKHR(g_device, g_swapchain, nil)
}

create_framebuffers :: proc() {
	g_swapchain_frame_buffers = make([]vk.Framebuffer, len(g_swapchain_views))
	for view, i in g_swapchain_views {
		attachments := []vk.ImageView{view, g_depth_view}

		frame_buffer := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = g_render_pass,
			attachmentCount = u32(len(attachments)),
			pAttachments    = raw_data(attachments),
			width           = g_swapchain_extent.width,
			height          = g_swapchain_extent.height,
			layers          = 1,
		}
		must(vk.CreateFramebuffer(g_device, &frame_buffer, nil, &g_swapchain_frame_buffers[i]))
	}
}

destroy_framebuffers :: proc() {
	for frame_buffer in g_swapchain_frame_buffers {vk.DestroyFramebuffer(g_device, frame_buffer, nil)}
	delete(g_swapchain_frame_buffers)
}

recreate_swapchain :: proc() {
	// Don't do anything when minimized.
	for w, h := glfw.GetFramebufferSize(g_window); w == 0 || h == 0; w, h = glfw.GetFramebufferSize(g_window) {
		glfw.WaitEvents()

		// Handle closing while minimized.
		if glfw.WindowShouldClose(g_window) { break }
	}

	vk.DeviceWaitIdle(g_device)

	destroy_framebuffers()
	destroy_depth_resources()
	destroy_swapchain()

	create_swapchain()
	create_depth_resources()
	create_framebuffers()
}

create_shader_module :: proc(code: []byte) -> (module: vk.ShaderModule) {
	as_u32 := slice.reinterpret([]u32, code)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(as_u32),
	}
	must(vk.CreateShaderModule(g_device, &create_info, nil, &module))
	return
}

record_command_buffer :: proc(command_buffer: vk.CommandBuffer, image_index: u32, frame: int) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	must(vk.BeginCommandBuffer(command_buffer, &begin_info))

	clear_values: [2]vk.ClearValue
	clear_values[0].color.float32 = {0.0, 0.0, 0.0, 1.0}
	clear_values[1].depthStencil = {depth = 1.0}

	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = g_render_pass,
		framebuffer = g_swapchain_frame_buffers[image_index],
		renderArea = {extent = g_swapchain_extent},
		clearValueCount = len(clear_values),
		pClearValues = &clear_values[0],
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)

	viewport := vk.Viewport {
		width    = f32(g_swapchain_extent.width),
		height   = f32(g_swapchain_extent.height),
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
		extent = g_swapchain_extent,
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	offset: vk.DeviceSize = 0
	view_proj := camera_view_proj(f64(g_swapchain_extent.width) / f64(g_swapchain_extent.height))

	frame_uniforms := Frame_Uniforms {
		view_proj = linalg.matrix_cast(view_proj, f32),
	}
	for light, i in g_box_lights[:min(len(g_box_lights), MAX_BOX_LIGHTS)] {
		c := light.color / 255 * light.intensity
		frame_uniforms.lights[i] = {
			center    = {f32(light.center.x), f32(light.center.y), f32(light.center.z), 0},
			half_size = {f32(light.size.x / 2), f32(light.size.y / 2), f32(light.size.z / 2), 0},
			color     = {f32(c.r), f32(c.g), f32(c.b), 0},
		}
		frame_uniforms.light_count.x = i32(i + 1)
	}
	runtime.mem_copy(g_frame_mapped[frame], &frame_uniforms, size_of(frame_uniforms))

	Blended :: struct {
		draw: ^Mesh_Draw,
		primitive: Primitive,
		distance: f64,
	}
	blended := make([dynamic]Blended, context.temp_allocator)
	bound_pipeline: vk.Pipeline

	if len(g_mesh_draws) > 0 {
		vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, g_mesh_pipeline_layout, 1, 1, &g_frame_sets[frame], 0, nil)
		for &draw in g_mesh_draws {
			for primitive in draw.mesh.primitives {
				if primitive.alpha_mode == .Blend || primitive.alpha_mode == .Filter {
					c := linalg.array_cast(primitive.center, f64)
					world := (draw.model * [4]f64{c.x, c.y, c.z, 1}).xyz
					append(&blended, Blended{&draw, primitive, linalg.distance(world, g_camera.position)})
					continue
				}
				record_mesh_primitive(command_buffer, &draw, primitive, &bound_pipeline)
			}
		}
	}

	if g_line_stream.counts[frame] > 0 {
		vp := linalg.matrix_cast(view_proj, f32)
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, g_line_pipeline)
		vk.CmdPushConstants(command_buffer, g_line_pipeline_layout, {.VERTEX}, 0, size_of(vp), &vp)
		vk.CmdBindVertexBuffers(command_buffer, 0, 1, &g_line_stream.buffers[frame], &offset)
		vk.CmdDraw(command_buffer, g_line_stream.counts[frame], 1, 0, 0)
	}

	if len(blended) > 0 {
		slice.sort_by(blended[:], proc(a, b: Blended) -> bool { return a.distance > b.distance })
		bound_pipeline = {}
		vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, g_mesh_pipeline_layout, 1, 1, &g_frame_sets[frame], 0, nil)
		for b in blended {
			record_mesh_primitive(command_buffer, b.draw, b.primitive, &bound_pipeline)
		}
	}

	// Additive and depth-write free, so particle order doesn't matter.
	if g_rect_stream.counts[frame] > 0 {
		vp := linalg.matrix_cast(view_proj, f32)
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, g_rect_pipeline)
		vk.CmdPushConstants(command_buffer, g_rect_pipeline_layout, {.VERTEX}, 0, size_of(vp), &vp)
		vk.CmdBindVertexBuffers(command_buffer, 0, 1, &g_rect_stream.buffers[frame], &offset)
		vk.CmdDraw(command_buffer, g_rect_stream.counts[frame], 1, 0, 0)
	}

	// 2D last, with depth testing off, so it overlays the 3D scene.
	if g_vertex_stream.counts[frame] > 0 {
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, g_pipeline)
		vk.CmdBindVertexBuffers(command_buffer, 0, 1, &g_vertex_stream.buffers[frame], &offset)
		vk.CmdDraw(command_buffer, g_vertex_stream.counts[frame], 1, 0, 0)
	}

	vk.CmdEndRenderPass(command_buffer)

	must(vk.EndCommandBuffer(command_buffer))
}

@(private = "file")
record_mesh_primitive :: proc(command_buffer: vk.CommandBuffer, draw: ^Mesh_Draw, primitive: Primitive, bound_pipeline: ^vk.Pipeline)
{
	kind := 2 if primitive.alpha_mode == .Filter else 1 if primitive.alpha_mode == .Blend else 0
	pipeline := g_mesh_pipelines[kind][1 if primitive.double_sided else 0]
	if pipeline != bound_pipeline^ {
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
		bound_pipeline^ = pipeline
	}

	push := Mesh_Push {
		model  = linalg.matrix_cast(draw.model, f32),
		tint   = {f32(draw.tint.r / 255), f32(draw.tint.g / 255), f32(draw.tint.b / 255), primitive.alpha},
		params   = {primitive.alpha_cutoff, 1 if primitive.alpha_mode == .Filter else 0, 0, 0},
		emissive = {primitive.emissive.r, primitive.emissive.g, primitive.emissive.b, 0},
	}
	vk.CmdPushConstants(command_buffer, g_mesh_pipeline_layout, {.VERTEX}, 0, size_of(push), &push)
	offset: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(command_buffer, 0, 1, &draw.mesh.vertex_buffer, &offset)
	vk.CmdBindIndexBuffer(command_buffer, draw.mesh.index_buffer, 0, .UINT32)
	texture := draw.texture_override.? or_else primitive.texture
	vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, g_mesh_pipeline_layout, 0, 1, &texture.descriptor_set, 0, nil)
	vk.CmdDrawIndexed(command_buffer, primitive.index_count, 1, primitive.first_index, 0, 0)
}

byte_arr_str :: proc(arr: ^[$N]byte) -> string {
	return strings.truncate_to_byte(string(arr[:]), 0)
}

must :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("vulkan failure %v", result, location = loc)
	}
}

find_memory_type :: proc(type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
    mem_props: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(g_physical_device, &mem_props)
    for i in 0 ..< mem_props.memoryTypeCount {
        if type_filter & (1 << i) != 0 &&
           properties <= mem_props.memoryTypes[i].propertyFlags {
            return i
        }
    }
    log.panic("vulkan: no suitable memory type")
}

create_buffer :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
) {
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	must(vk.CreateBuffer(g_device, &buffer_info, nil, &buffer))

	reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_device, buffer, &reqs)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = reqs.size,
		memoryTypeIndex = find_memory_type(reqs.memoryTypeBits, properties),
	}
	must(vk.AllocateMemory(g_device, &alloc_info, nil, &memory))
	must(vk.BindBufferMemory(g_device, buffer, memory, 0))
	return
}

create_staging_buffer :: proc(data: []byte) -> (buffer: vk.Buffer, memory: vk.DeviceMemory) {
	size := vk.DeviceSize(len(data))
	buffer, memory = create_buffer(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})

	mapped: rawptr
	must(vk.MapMemory(g_device, memory, 0, size, {}, &mapped))
	runtime.mem_copy(mapped, raw_data(data), len(data))
	vk.UnmapMemory(g_device, memory)
	return
}

// Uploads data once into fast GPU-only memory via a staging buffer.
create_device_local_buffer :: proc(
	data: []byte,
	usage: vk.BufferUsageFlags,
) -> (
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
) {
	staging, staging_memory := create_staging_buffer(data)
	defer vk.DestroyBuffer(g_device, staging, nil)
	defer vk.FreeMemory(g_device, staging_memory, nil)

	buffer, memory = create_buffer(vk.DeviceSize(len(data)), usage + {.TRANSFER_DST}, {.DEVICE_LOCAL})

	cmd := begin_one_time_commands()
	region := vk.BufferCopy{size = vk.DeviceSize(len(data))}
	vk.CmdCopyBuffer(cmd, staging, buffer, 1, &region)
	end_one_time_commands(cmd)
	return
}

begin_one_time_commands :: proc() -> (cmd: vk.CommandBuffer) {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = g_command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	must(vk.AllocateCommandBuffers(g_device, &alloc_info, &cmd))

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	must(vk.BeginCommandBuffer(cmd, &begin_info))
	return
}

end_one_time_commands :: proc(cmd: vk.CommandBuffer) {
	cmd := cmd
	must(vk.EndCommandBuffer(cmd))

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}
	must(vk.QueueSubmit(g_graphics_queue, 1, &submit_info, 0))
	must(vk.QueueWaitIdle(g_graphics_queue))
	vk.FreeCommandBuffers(g_device, g_command_pool, 1, &cmd)
}

create_image :: proc(
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
) -> (
	image: vk.Image,
	memory: vk.DeviceMemory,
) {
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	must(vk.CreateImage(g_device, &image_info, nil, &image))

	reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g_device, image, &reqs)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = reqs.size,
		memoryTypeIndex = find_memory_type(reqs.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	must(vk.AllocateMemory(g_device, &alloc_info, nil, &memory))
	must(vk.BindImageMemory(g_device, image, memory, 0))
	return
}

create_image_view :: proc(image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags) -> (view: vk.ImageView) {
	create_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = image,
		viewType         = .D2,
		format           = format,
		subresourceRange = {aspectMask = aspect, levelCount = 1, layerCount = 1},
	}
	must(vk.CreateImageView(g_device, &create_info, nil, &view))
	return
}

upload_texture_pixels :: proc(image: vk.Image, width, height: u32, pixels: []byte) {
	staging, staging_memory := create_staging_buffer(pixels)
	defer vk.DestroyBuffer(g_device, staging, nil)
	defer vk.FreeMemory(g_device, staging_memory, nil)

	cmd := begin_one_time_commands()

	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}

	to_transfer := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		oldLayout           = .UNDEFINED,
		newLayout           = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = range,
		dstAccessMask       = {.TRANSFER_WRITE},
	}
	vk.CmdPipelineBarrier(cmd, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &to_transfer)

	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent      = {width, height, 1},
	}
	vk.CmdCopyBufferToImage(cmd, staging, image, .TRANSFER_DST_OPTIMAL, 1, &region)

	to_shader := to_transfer
	to_shader.oldLayout = .TRANSFER_DST_OPTIMAL
	to_shader.newLayout = .SHADER_READ_ONLY_OPTIMAL
	to_shader.srcAccessMask = {.TRANSFER_WRITE}
	to_shader.dstAccessMask = {.SHADER_READ}
	vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &to_shader)

	end_one_time_commands(cmd)
}

choose_depth_format :: proc() -> vk.Format {
	for format in ([]vk.Format{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}) {
		props: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(g_physical_device, format, &props)
		if .DEPTH_STENCIL_ATTACHMENT in props.optimalTilingFeatures {
			return format
		}
	}
	log.panic("vulkan: no supported depth format")
}

create_depth_resources :: proc() {
	g_depth_format = choose_depth_format()
	g_depth_image, g_depth_memory = create_image(
		g_swapchain_extent.width,
		g_swapchain_extent.height,
		g_depth_format,
		{.DEPTH_STENCIL_ATTACHMENT},
	)
	g_depth_view = create_image_view(g_depth_image, g_depth_format, {.DEPTH})
}

destroy_depth_resources :: proc() {
	vk.DestroyImageView(g_device, g_depth_view, nil)
	vk.DestroyImage(g_device, g_depth_image, nil)
	vk.FreeMemory(g_device, g_depth_memory, nil)
}

create_vertex_stream :: proc(stream: ^Vertex_Stream, vertex_size: int) {
	size := vk.DeviceSize(MAX_VERTICES * vertex_size)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		stream.buffers[i], stream.memories[i] = create_buffer(size, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		must(vk.MapMemory(g_device, stream.memories[i], 0, size, {}, &stream.mapped[i]))
	}
}

destroy_vertex_stream :: proc(stream: ^Vertex_Stream) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g_device, stream.memories[i])
		vk.DestroyBuffer(g_device, stream.buffers[i], nil)
		vk.FreeMemory(g_device, stream.memories[i], nil)
	}
}

upload_vertex_stream :: proc(stream: ^Vertex_Stream, frame: int, vertices: []$T) {
	count := min(len(vertices), MAX_VERTICES)
	if count < len(vertices) {
		log.warnf("wassily: %v vertices exceeds MAX_VERTICES, truncating", len(vertices))
	}
	runtime.mem_copy(stream.mapped[frame], raw_data(vertices), count * size_of(T))
	stream.counts[frame] = u32(count)
}

create_texture_resources :: proc() {
	sampler_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &sampler_binding,
	}
	must(vk.CreateDescriptorSetLayout(g_device, &layout_info, nil, &g_descriptor_set_layout))

	frame_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .UNIFORM_BUFFER,
		descriptorCount = 1,
		stageFlags      = {.VERTEX, .FRAGMENT},
	}
	frame_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &frame_binding,
	}
	must(vk.CreateDescriptorSetLayout(g_device, &frame_layout_info, nil, &g_frame_set_layout))

	pool_sizes := [2]vk.DescriptorPoolSize {
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_TEXTURES},
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = MAX_TEXTURES + MAX_FRAMES_IN_FLIGHT,
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = &pool_sizes[0],
	}
	must(vk.CreateDescriptorPool(g_device, &pool_info, nil, &g_descriptor_pool))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		size := vk.DeviceSize(size_of(Frame_Uniforms))
		g_frame_buffers[i], g_frame_memories[i] = create_buffer(size, {.UNIFORM_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		must(vk.MapMemory(g_device, g_frame_memories[i], 0, size, {}, &g_frame_mapped[i]))

		alloc_info := vk.DescriptorSetAllocateInfo {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = g_descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts        = &g_frame_set_layout,
		}
		must(vk.AllocateDescriptorSets(g_device, &alloc_info, &g_frame_sets[i]))

		buffer_info := vk.DescriptorBufferInfo {
			buffer = g_frame_buffers[i],
			range  = size,
		}
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = g_frame_sets[i],
			dstBinding      = 0,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER,
			pBufferInfo     = &buffer_info,
		}
		vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
	}

	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
		addressModeU = .REPEAT,
		addressModeV = .REPEAT,
		addressModeW = .REPEAT,
		maxLod       = 0,
	}
	must(vk.CreateSampler(g_device, &sampler_info, nil, &g_sampler))
}

destroy_texture_resources :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g_device, g_frame_memories[i])
		vk.DestroyBuffer(g_device, g_frame_buffers[i], nil)
		vk.FreeMemory(g_device, g_frame_memories[i], nil)
	}
	vk.DestroySampler(g_device, g_sampler, nil)
	vk.DestroyDescriptorPool(g_device, g_descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(g_device, g_frame_set_layout, nil)
	vk.DestroyDescriptorSetLayout(g_device, g_descriptor_set_layout, nil)
}

Pipeline_Desc :: struct {
	vert, frag:   vk.ShaderModule,
	stride:       u32,
	attributes:   []vk.VertexInputAttributeDescription,
	topology:     vk.PrimitiveTopology,
	cull:         vk.CullModeFlags,
	front_face:   vk.FrontFace,
	depth:        bool,
	// Adds color onto the target and tests depth without writing it.
	additive:     bool,
	// Alpha-blends over the target and tests depth without writing it.
	blend:        bool,
	// Multiplies the target by the output color and tests depth without writing it.
	multiply:     bool,
	// Reused instead of creating a new layout when set.
	layout:       vk.PipelineLayout,
	push_size:    u32,
	set_layouts:  []vk.DescriptorSetLayout,
}

create_pipeline :: proc(desc: Pipeline_Desc) -> (pipeline: vk.Pipeline, layout: vk.PipelineLayout) {
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = desc.vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = desc.frag, pName = "main"},
	}

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = desc.stride,
		inputRate = .VERTEX,
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = u32(len(desc.attributes)),
		pVertexAttributeDescriptions    = raw_data(desc.attributes),
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = desc.topology,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1,
		cullMode    = desc.cull,
		frontFace   = desc.front_face,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		minSampleShading     = 1,
	}

	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = b32(desc.depth),
		depthWriteEnable = b32(desc.depth && !desc.additive && !desc.blend && !desc.multiply),
		depthCompareOp   = .LESS,
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	if desc.additive {
		color_blend_attachment.blendEnable = true
		color_blend_attachment.srcColorBlendFactor = .ONE
		color_blend_attachment.dstColorBlendFactor = .ONE
		color_blend_attachment.colorBlendOp = .ADD
		color_blend_attachment.srcAlphaBlendFactor = .ZERO
		color_blend_attachment.dstAlphaBlendFactor = .ONE
		color_blend_attachment.alphaBlendOp = .ADD
	} else if desc.blend {
		color_blend_attachment.blendEnable = true
		color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attachment.colorBlendOp = .ADD
		color_blend_attachment.srcAlphaBlendFactor = .ONE
		color_blend_attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attachment.alphaBlendOp = .ADD
	} else if desc.multiply {
		color_blend_attachment.blendEnable = true
		color_blend_attachment.srcColorBlendFactor = .ZERO
		color_blend_attachment.dstColorBlendFactor = .SRC_COLOR
		color_blend_attachment.colorBlendOp = .ADD
		color_blend_attachment.srcAlphaBlendFactor = .ZERO
		color_blend_attachment.dstAlphaBlendFactor = .ONE
		color_blend_attachment.alphaBlendOp = .ADD
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	push_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		size       = desc.push_size,
	}

	layout = desc.layout
	if layout == 0 {
		layout_info := vk.PipelineLayoutCreateInfo {
			sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount         = u32(len(desc.set_layouts)),
			pSetLayouts            = raw_data(desc.set_layouts),
			pushConstantRangeCount = 1 if desc.push_size > 0 else 0,
			pPushConstantRanges    = &push_range,
		}
		must(vk.CreatePipelineLayout(g_device, &layout_info, nil, &layout))
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(stages),
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pDepthStencilState  = &depth_stencil,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = layout,
		renderPass          = g_render_pass,
		subpass             = 0,
		basePipelineIndex   = -1,
	}
	must(vk.CreateGraphicsPipelines(g_device, 0, 1, &pipeline_info, nil, &pipeline))
	return
}