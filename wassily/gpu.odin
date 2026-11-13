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

g_vert_shader_module: vk.ShaderModule
g_frag_shader_module: vk.ShaderModule
g_shader_stages: [2]vk.PipelineShaderStageCreateInfo

g_render_pass: vk.RenderPass
g_pipeline_layout: vk.PipelineLayout
g_pipeline: vk.Pipeline

g_command_pool: vk.CommandPool
g_command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer

g_image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence

MAX_VERTICES :: 1 << 16

// One buffer per frame in flight so the CPU never writes a buffer the GPU is still reading.
g_vertex_buffers: [MAX_FRAMES_IN_FLIGHT]vk.Buffer
g_vertex_buffer_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory
g_vertex_buffer_mapped: [MAX_FRAMES_IN_FLIGHT][^]Vertex
g_vertex_counts: [MAX_FRAMES_IN_FLIGHT]u32

g_vertices: [dynamic]Vertex

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
		attachments := []vk.ImageView{view}

		frame_buffer := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = g_render_pass,
			attachmentCount = 1,
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
	destroy_swapchain()

	create_swapchain()
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

	clear_color := vk.ClearValue{}
	clear_color.color.float32 = {0.0, 0.0, 0.0, 1.0}

	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = g_render_pass,
		framebuffer = g_swapchain_frame_buffers[image_index],
		renderArea = {extent = g_swapchain_extent},
		clearValueCount = 1,
		pClearValues = &clear_color,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)

	vk.CmdBindPipeline(command_buffer, .GRAPHICS, g_pipeline)

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
	vk.CmdBindVertexBuffers(command_buffer, 0, 1, &g_vertex_buffers[frame], &offset)
	vk.CmdDraw(command_buffer, g_vertex_counts[frame], 1, 0, 0)

	vk.CmdEndRenderPass(command_buffer)

	must(vk.EndCommandBuffer(command_buffer))
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

create_vertex_buffers :: proc() {
	size := vk.DeviceSize(MAX_VERTICES * size_of(Vertex))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer_info := vk.BufferCreateInfo {
			sType       = .BUFFER_CREATE_INFO,
			size        = size,
			usage       = {.VERTEX_BUFFER},
			sharingMode = .EXCLUSIVE,
		}
		must(vk.CreateBuffer(g_device, &buffer_info, nil, &g_vertex_buffers[i]))

		reqs: vk.MemoryRequirements
		vk.GetBufferMemoryRequirements(g_device, g_vertex_buffers[i], &reqs)

		alloc_info := vk.MemoryAllocateInfo {
			sType           = .MEMORY_ALLOCATE_INFO,
			allocationSize  = reqs.size,
			memoryTypeIndex = find_memory_type(reqs.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
		}
		must(vk.AllocateMemory(g_device, &alloc_info, nil, &g_vertex_buffer_memories[i]))
		must(vk.BindBufferMemory(g_device, g_vertex_buffers[i], g_vertex_buffer_memories[i], 0))

		data: rawptr
		must(vk.MapMemory(g_device, g_vertex_buffer_memories[i], 0, size, {}, &data))
		g_vertex_buffer_mapped[i] = cast([^]Vertex)data
	}
}

destroy_vertex_buffers :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g_device, g_vertex_buffer_memories[i])
		vk.DestroyBuffer(g_device, g_vertex_buffers[i], nil)
		vk.FreeMemory(g_device, g_vertex_buffer_memories[i], nil)
	}
}

upload_vertices :: proc(frame: int) {
	count := min(len(g_vertices), MAX_VERTICES)
	if count < len(g_vertices) {
		log.warnf("wassily: %v vertices exceeds MAX_VERTICES, truncating", len(g_vertices))
	}
	runtime.mem_copy(g_vertex_buffer_mapped[frame], raw_data(g_vertices), count * size_of(Vertex))
	g_vertex_counts[frame] = u32(count)
}