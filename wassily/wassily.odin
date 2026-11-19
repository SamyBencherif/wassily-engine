package wassily

WIDTH  	:: 1920
HEIGHT 	:: 1080
TITLE 	:: "wassily"

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:log"

import "vendor:glfw"
import vk "vendor:vulkan"

Vertex2D :: struct {
	position: [2]f32,
	color: [3]f32
}

Vertex3D :: struct {
	position: [3]f32,
	uv: [2]f32,
	color: [3]f32
}

LineVertex :: struct {
	position: [3]f32,
	color: [3]f32
}

Vector3 :: [3]f64

// Colors are 0-255 per channel.
Color :: [3]f64

// Rotation is Euler angles in degrees, applied in X, Y, Z order.
Transform :: struct {
	position: Vector3,
	rotation: Vector3,
	scale: Vector3,
}

Texture :: struct {
	image: vk.Image,
	memory: vk.DeviceMemory,
	view: vk.ImageView,
	descriptor_set: vk.DescriptorSet,
}

// A range of a mesh's indices drawn with one material.
Primitive :: struct {
	first_index: u32,
	index_count: u32,
	texture: Texture,
}

Mesh :: struct {
	vertex_buffer: vk.Buffer,
	vertex_memory: vk.DeviceMemory,
	index_buffer: vk.Buffer,
	index_memory: vk.DeviceMemory,
	primitives: []Primitive,
	// Object placement from the source file, applied before the draw transform.
	local: matrix[4, 4]f64,
}

// Objects keyed by their Blender object name.
Model :: struct {
	objects: map[string]Mesh,
}

Mesh_Draw :: struct {
	mesh: Mesh,
	texture_override: Maybe(Texture),
	model: matrix[4, 4]f64,
}

Camera :: struct {
	position: Vector3,
	target: Vector3,
	up: Vector3,
	fov: f64,
}

CAMERA_NEAR :: 0.1
CAMERA_FAR :: 1000.0
MAX_TEXTURES :: 64

g_camera := Camera{position = {0, 0, -10}, target = {0, 0, 0}, up = {0, 1, 0}, fov = 60}
g_mesh_draws: [dynamic]Mesh_Draw
g_line_vertices: [dynamic]LineVertex
g_line_stream: Vertex_Stream
g_meshes: [dynamic]Mesh
g_models: [dynamic]Model
g_textures: [dynamic]Texture
g_white_texture: Maybe(Texture)
g_dt: f64

hello :: proc()
{
    fmt.println("Hello world")
}

size :: proc() -> (int, int)
{
    return WIDTH, HEIGHT
}

time :: proc() -> f64
{
	return glfw.GetTime()
}

// Seconds elapsed between the previous frame and the current one.
dt :: proc() -> f64
{
	return g_dt
}

Key :: enum i32 {
	A      = glfw.KEY_A,
	D      = glfw.KEY_D,
	E      = glfw.KEY_E,
	Q      = glfw.KEY_Q,
	S      = glfw.KEY_S,
	W      = glfw.KEY_W,
	Space  = glfw.KEY_SPACE,
	Escape = glfw.KEY_ESCAPE,
	Shift  = glfw.KEY_LEFT_SHIFT,
	Up     = glfw.KEY_UP,
	Down   = glfw.KEY_DOWN,
	Left   = glfw.KEY_LEFT,
	Right  = glfw.KEY_RIGHT,
}

is_down :: proc(key: Key) -> bool
{
	return glfw.GetKey(g_window, i32(key)) == glfw.PRESS
}

CIRCLE_SEGMENTS :: 64

// Coordinates are pixels in a WIDTH x HEIGHT canvas, origin top-left; colors are 0-255.
fill_circle :: proc(x: int, y: int, radius: int, color: Color)
{
    cx := f32(x) / WIDTH  * 2 - 1
    cy := f32(y) / HEIGHT * 2 - 1
    rx := f32(radius) / WIDTH  * 2
    ry := f32(radius) / HEIGHT * 2
    c := linalg.array_cast(color / 255, f32)

    for i in 0 ..< CIRCLE_SEGMENTS {
        a0 := f32(i)   / CIRCLE_SEGMENTS * 2 * math.PI
        a1 := f32(i+1) / CIRCLE_SEGMENTS * 2 * math.PI

        append(&g_vertices, Vertex2D{{cx, cy}, c})
        append(&g_vertices, Vertex2D{{cx + rx * math.cos(a0), cy + ry * math.sin(a0)}, c})
        append(&g_vertices, Vertex2D{{cx + rx * math.cos(a1), cy + ry * math.sin(a1)}, c})
    }
}

camera :: proc(position: Vector3, target: Vector3, up: Vector3, fov: f64)
{
	g_camera = {position, target, up, fov}
}

// texture_override replaces every primitive's own material texture.
draw_mesh :: proc(mesh: Mesh, transform: Transform, texture_override: Maybe(Texture) = nil)
{
	append(&g_mesh_draws, Mesh_Draw{mesh, texture_override, transform_matrix(transform) * mesh.local})
}

draw_model :: proc(model: Model, transform: Transform, texture_override: Maybe(Texture) = nil)
{
	for _, mesh in model.objects {
		draw_mesh(mesh, transform, texture_override)
	}
}

@(private = "file")
transform_matrix :: proc(transform: Transform) -> matrix[4, 4]f64
{
	DEG :: math.PI / 180
	r := transform.rotation * DEG
	rotation := linalg.quaternion_from_euler_angles_f64(r.x, r.y, r.z, .XYZ)
	return linalg.matrix4_translate_f64(transform.position) *
		linalg.matrix4_from_quaternion_f64(rotation) *
		linalg.matrix4_scale_f64(transform.scale)
}

draw_line_3d :: proc(a: Vector3, b: Vector3, color: Color)
{
	c := linalg.array_cast(color / 255, f32)
	append(&g_line_vertices, LineVertex{linalg.array_cast(a, f32), c})
	append(&g_line_vertices, LineVertex{linalg.array_cast(b, f32), c})
}

// Right-handed view, Vulkan clip space: depth in [0, 1] and Y pointing down.
camera_view_proj :: proc(aspect: f64) -> matrix[4, 4]f64
{
	view := linalg.matrix4_look_at_f64(g_camera.position, g_camera.target, g_camera.up)

	f := 1 / math.tan(g_camera.fov * math.PI / 180 / 2)
	n, far := f64(CAMERA_NEAR), f64(CAMERA_FAR)
	proj := matrix[4, 4]f64 {
		f / aspect, 0, 0, 0,
		0, -f, 0, 0,
		0, 0, far / (n - far), n * far / (n - far),
		0, 0, -1, 0,
	}
	return proj * view
}

run :: proc(initfn : proc(), loopfn : proc())
{
	context.logger = log.create_console_logger()
	g_ctx = context

	// TODO: update vendor bindings to glfw 3.4 and use this to set a custom allocator.
	// glfw.InitAllocator()

	// TODO: set up Vulkan allocator.

	glfw.SetErrorCallback(glfw_error_callback)

	if !glfw.Init() {log.panic("glfw: could not be initialized")}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

	g_window = glfw.CreateWindow(WIDTH, HEIGHT, "Vulkan", nil, nil)
	defer glfw.DestroyWindow(g_window)

	glfw.SetFramebufferSizeCallback(g_window, proc "c" (_: glfw.WindowHandle, _, _: i32) {
		g_framebuffer_resized = true
	})

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")

	create_info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "Hello Triangle",
			applicationVersion = vk.MAKE_VERSION(1, 0, 0),
			pEngineName = "No Engine",
			engineVersion = vk.MAKE_VERSION(1, 0, 0),
			apiVersion = vk.API_VERSION_1_0,
		},
	}

	extensions := slice.clone_to_dynamic(glfw.GetRequiredInstanceExtensions(), context.temp_allocator)

	// MacOS is a special snowflake ;)
	when ODIN_OS == .Darwin {
		create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}

	when ENABLE_VALIDATION_LAYERS {
		create_info.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
		create_info.enabledLayerCount = 1

		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING}, // all of them.
			pfnUserCallback = vk_messenger_callback,
		}
		create_info.pNext = &dbg_create_info
	}

	create_info.enabledExtensionCount = u32(len(extensions))
	create_info.ppEnabledExtensionNames = raw_data(extensions)

	must(vk.CreateInstance(&create_info, nil, &g_instance))
	defer vk.DestroyInstance(g_instance, nil)

	vk.load_proc_addresses_instance(g_instance)

	when ENABLE_VALIDATION_LAYERS {
		dbg_messenger: vk.DebugUtilsMessengerEXT
		must(vk.CreateDebugUtilsMessengerEXT(g_instance, &dbg_create_info, nil, &dbg_messenger))
		defer vk.DestroyDebugUtilsMessengerEXT(g_instance, dbg_messenger, nil)
	}

	must(glfw.CreateWindowSurface(g_instance, g_window, nil, &g_surface))
	defer vk.DestroySurfaceKHR(g_instance, g_surface, nil)

	// Pick a suitable GPU.
	must(pick_physical_device())

	// Setup logical device, 
	indices := find_queue_families(g_physical_device)
	{
		// TODO: this is kinda messy.
		indices_set := make(map[u32]struct {}, allocator = context.temp_allocator)
		indices_set[indices.graphics.?] = {}
		indices_set[indices.present.?] = {}

		queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(indices_set), context.temp_allocator)
		for _ in indices_set {
			append(
				&queue_create_infos,
				vk.DeviceQueueCreateInfo {
					sType = .DEVICE_QUEUE_CREATE_INFO,
					queueFamilyIndex = indices.graphics.?,
					queueCount = 1,
					pQueuePriorities = raw_data([]f32{1}),
				},// Scheduling priority between 0 and 1.
			)
		}

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pQueueCreateInfos       = raw_data(queue_create_infos),
			queueCreateInfoCount    = u32(len(queue_create_infos)),
			enabledLayerCount       = create_info.enabledLayerCount,
			ppEnabledLayerNames     = create_info.ppEnabledLayerNames,
			ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
			enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
		}

		must(vk.CreateDevice(g_physical_device, &device_create_info, nil, &g_device))

		vk.GetDeviceQueue(g_device, indices.graphics.?, 0, &g_graphics_queue)
		vk.GetDeviceQueue(g_device, indices.present.?, 0, &g_present_queue)
	}
	defer vk.DestroyDevice(g_device, nil)

	create_swapchain()
	defer destroy_swapchain()

	create_depth_resources()
	defer destroy_depth_resources()

	// Set up render pass.
	{
		attachments := [2]vk.AttachmentDescription {
			{
				format         = g_swapchain_format.format,
				samples        = {._1},
				loadOp         = .CLEAR,
				storeOp        = .STORE,
				stencilLoadOp  = .DONT_CARE,
				stencilStoreOp = .DONT_CARE,
				initialLayout  = .UNDEFINED,
				finalLayout    = .PRESENT_SRC_KHR,
			},
			{
				format         = g_depth_format,
				samples        = {._1},
				loadOp         = .CLEAR,
				storeOp        = .DONT_CARE,
				stencilLoadOp  = .DONT_CARE,
				stencilStoreOp = .DONT_CARE,
				initialLayout  = .UNDEFINED,
				finalLayout    = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			},
		}

		color_attachment_ref := vk.AttachmentReference {
			attachment = 0,
			layout     = .COLOR_ATTACHMENT_OPTIMAL,
		}

		depth_attachment_ref := vk.AttachmentReference {
			attachment = 1,
			layout     = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		}

		subpass := vk.SubpassDescription {
			pipelineBindPoint       = .GRAPHICS,
			colorAttachmentCount    = 1,
			pColorAttachments       = &color_attachment_ref,
			pDepthStencilAttachment = &depth_attachment_ref,
		}

		// The single depth image is shared across frames in flight, so writes must wait on the previous frame's.
		dependency := vk.SubpassDependency {
			srcSubpass    = vk.SUBPASS_EXTERNAL,
			dstSubpass    = 0,
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
		}

		render_pass := vk.RenderPassCreateInfo {
			sType           = .RENDER_PASS_CREATE_INFO,
			attachmentCount = len(attachments),
			pAttachments    = &attachments[0],
			subpassCount    = 1,
			pSubpasses      = &subpass,
			dependencyCount = 1,
			pDependencies   = &dependency,
		}

		must(vk.CreateRenderPass(g_device, &render_pass, nil, &g_render_pass))
	}
	defer vk.DestroyRenderPass(g_device, g_render_pass, nil)

	create_framebuffers()
	defer destroy_framebuffers()

	create_texture_resources()
	defer destroy_texture_resources()

	// Set up pipelines.
	{
		vert_2d := create_shader_module(SHADER_VERT)
		frag_2d := create_shader_module(SHADER_FRAG)
		mesh_vert := create_shader_module(SHADER_MESH_VERT)
		mesh_frag := create_shader_module(SHADER_MESH_FRAG)
		line_vert := create_shader_module(SHADER_LINE_VERT)
		defer for module in ([]vk.ShaderModule{vert_2d, frag_2d, mesh_vert, mesh_frag, line_vert}) {
			vk.DestroyShaderModule(g_device, module, nil)
		}

		g_pipeline, g_pipeline_layout = create_pipeline({
			vert       = vert_2d,
			frag       = frag_2d,
			stride     = size_of(Vertex2D),
			attributes = {
				{location = 0, format = .R32G32_SFLOAT,    offset = u32(offset_of(Vertex2D, position))},
				{location = 1, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex2D, color))},
			},
			topology   = .TRIANGLE_LIST,
			cull       = {.BACK},
			front_face = .CLOCKWISE,
		})

		// Projection flips Y, so the counter-clockwise OBJ winding stays counter-clockwise on screen.
		g_mesh_pipeline, g_mesh_pipeline_layout = create_pipeline({
			vert        = mesh_vert,
			frag        = mesh_frag,
			stride      = size_of(Vertex3D),
			attributes  = {
				{location = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex3D, position))},
				{location = 1, format = .R32G32_SFLOAT,    offset = u32(offset_of(Vertex3D, uv))},
				{location = 2, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex3D, color))},
			},
			topology    = .TRIANGLE_LIST,
			cull        = {.BACK},
			front_face  = .COUNTER_CLOCKWISE,
			depth       = true,
			push_size   = size_of(matrix[4, 4]f32),
			set_layouts = {g_descriptor_set_layout},
		})

		// Line shader outputs the same varyings as the 2D shader, so it reuses its fragment stage.
		g_line_pipeline, g_line_pipeline_layout = create_pipeline({
			vert       = line_vert,
			frag       = frag_2d,
			stride     = size_of(LineVertex),
			attributes = {
				{location = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(LineVertex, position))},
				{location = 1, format = .R32G32B32_SFLOAT, offset = u32(offset_of(LineVertex, color))},
			},
			topology   = .LINE_LIST,
			depth      = true,
			push_size  = size_of(matrix[4, 4]f32),
		})
	}
	defer vk.DestroyPipelineLayout(g_device, g_pipeline_layout, nil)
	defer vk.DestroyPipeline(g_device, g_pipeline, nil)
	defer vk.DestroyPipelineLayout(g_device, g_mesh_pipeline_layout, nil)
	defer vk.DestroyPipeline(g_device, g_mesh_pipeline, nil)
	defer vk.DestroyPipelineLayout(g_device, g_line_pipeline_layout, nil)
	defer vk.DestroyPipeline(g_device, g_line_pipeline, nil)

	// Create command pool.
	{
		pool_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = indices.graphics.?,
		}
		must(vk.CreateCommandPool(g_device, &pool_info, nil, &g_command_pool))

		alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = g_command_pool,
			level              = .PRIMARY,
			commandBufferCount = MAX_FRAMES_IN_FLIGHT,
		}
		must(vk.AllocateCommandBuffers(g_device, &alloc_info, &g_command_buffers[0]))
	}
	defer vk.DestroyCommandPool(g_device, g_command_pool, nil)

	// Set up sync primitives.
	{
		sem_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		fence_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			must(vk.CreateSemaphore(g_device, &sem_info, nil, &g_image_available_semaphores[i]))
			must(vk.CreateSemaphore(g_device, &sem_info, nil, &g_render_finished_semaphores[i]))
			must(vk.CreateFence(g_device, &fence_info, nil, &g_in_flight_fences[i]))
		}
	}
	defer for sem in g_image_available_semaphores {vk.DestroySemaphore(g_device, sem, nil)}
	defer for sem in g_render_finished_semaphores {vk.DestroySemaphore(g_device, sem, nil)}
	defer for fence in g_in_flight_fences {vk.DestroyFence(g_device, fence, nil)}

	create_vertex_stream(&g_vertex_stream, size_of(Vertex2D))
	defer destroy_vertex_stream(&g_vertex_stream)
	defer delete(g_vertices)

	create_vertex_stream(&g_line_stream, size_of(LineVertex))
	defer destroy_vertex_stream(&g_line_stream)
	defer delete(g_line_vertices)
	defer delete(g_mesh_draws)

	initfn()
	free_all(context.temp_allocator)
	defer destroy_assets()

	current_frame := 0
	last_time := glfw.GetTime()
	for !glfw.WindowShouldClose(g_window) {
		free_all(context.temp_allocator)

		glfw.PollEvents()

		now := glfw.GetTime()
		g_dt = now - last_time
		last_time = now

		// Wait for previous frame.
		must(vk.WaitForFences(g_device, 1, &g_in_flight_fences[current_frame], true, max(u64)))

		// Acquire an image from the swapchain.
		image_index: u32
		acquire_result := vk.AcquireNextImageKHR(
			g_device,
			g_swapchain,
			max(u64),
			g_image_available_semaphores[current_frame],
			0,
			&image_index,
		)
		#partial switch acquire_result {
		case .ERROR_OUT_OF_DATE_KHR:
			recreate_swapchain()
			continue
		case .SUCCESS, .SUBOPTIMAL_KHR:
		case:
			log.panicf("vulkan: acquire next image failure: %v", acquire_result)
		}

		must(vk.ResetFences(g_device, 1, &g_in_flight_fences[current_frame]))

		clear(&g_vertices)
		clear(&g_line_vertices)
		clear(&g_mesh_draws)
		loopfn()
		upload_vertex_stream(&g_vertex_stream, current_frame, g_vertices[:])
		upload_vertex_stream(&g_line_stream, current_frame, g_line_vertices[:])

		must(vk.ResetCommandBuffer(g_command_buffers[current_frame], {}))
		record_command_buffer(g_command_buffers[current_frame], image_index, current_frame)

		// Submit.
		submit_info := vk.SubmitInfo {
			sType                = .SUBMIT_INFO,
			waitSemaphoreCount   = 1,
			pWaitSemaphores      = &g_image_available_semaphores[current_frame],
			pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
			commandBufferCount   = 1,
			pCommandBuffers      = &g_command_buffers[current_frame],
			signalSemaphoreCount = 1,
			pSignalSemaphores    = &g_render_finished_semaphores[current_frame],
		}
		must(vk.QueueSubmit(g_graphics_queue, 1, &submit_info, g_in_flight_fences[current_frame]))

		// Present.
		present_info := vk.PresentInfoKHR {
			sType              = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &g_render_finished_semaphores[current_frame],
			swapchainCount     = 1,
			pSwapchains        = &g_swapchain,
			pImageIndices      = &image_index,
		}
		present_result := vk.QueuePresentKHR(g_present_queue, &present_info)
		switch {
		case present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || g_framebuffer_resized:
			g_framebuffer_resized = false
			recreate_swapchain()
		case present_result == .SUCCESS:
		case:
			log.panicf("vulkan: present failure: %v", present_result)
		}

		current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	}
	vk.DeviceWaitIdle(g_device)
}