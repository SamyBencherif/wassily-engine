package wassily

WIDTH  	:: 256
HEIGHT 	:: 256
TITLE 	:: "wassily"

import "core:fmt"
import "core:math"
import "core:slice"
import "core:log"

import "vendor:glfw"
import vk "vendor:vulkan"

Vertex :: struct {
	position: [2]f32,
	color: [3]f32
}

hello :: proc()
{
    fmt.println("Hello world")
}

size :: proc() -> (int, int)
{
    return WIDTH, HEIGHT
}

CIRCLE_SEGMENTS :: 64

// Coordinates are pixels in a WIDTH x HEIGHT canvas, origin top-left; colors are 0-255.
fillCircle :: proc(x: int, y: int, radius: int, colorR : int, colorG : int, colorB : int)
{
    cx := f32(x) / WIDTH  * 2 - 1
    cy := f32(y) / HEIGHT * 2 - 1
    rx := f32(radius) / WIDTH  * 2
    ry := f32(radius) / HEIGHT * 2
    color := [3]f32{f32(colorR), f32(colorG), f32(colorB)} / 255

    for i in 0 ..< CIRCLE_SEGMENTS {
        a0 := f32(i)   / CIRCLE_SEGMENTS * 2 * math.PI
        a1 := f32(i+1) / CIRCLE_SEGMENTS * 2 * math.PI

        append(&g_vertices, Vertex{{cx, cy}, color})
        append(&g_vertices, Vertex{{cx + rx * math.cos(a0), cy + ry * math.sin(a0)}, color})
        append(&g_vertices, Vertex{{cx + rx * math.cos(a1), cy + ry * math.sin(a1)}, color})
    }
}

run :: proc(loopfn : proc())
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

	// Load shaders.
	{
		g_vert_shader_module = create_shader_module(SHADER_VERT)
		g_shader_stages[0] = vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = g_vert_shader_module,
			pName  = "main",
		}

		g_frag_shader_module = create_shader_module(SHADER_FRAG)
		g_shader_stages[1] = vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = g_frag_shader_module,
			pName  = "main",
		}
	}
	defer vk.DestroyShaderModule(g_device, g_vert_shader_module, nil)
	defer vk.DestroyShaderModule(g_device, g_frag_shader_module, nil)

	// Set up render pass.
	{
		color_attachment := vk.AttachmentDescription {
			format         = g_swapchain_format.format,
			samples        = {._1},
			loadOp         = .CLEAR,
			storeOp        = .STORE,
			stencilLoadOp  = .DONT_CARE,
			stencilStoreOp = .DONT_CARE,
			initialLayout  = .UNDEFINED,
			finalLayout    = .PRESENT_SRC_KHR,
		}

		color_attachment_ref := vk.AttachmentReference {
			attachment = 0,
			layout     = .COLOR_ATTACHMENT_OPTIMAL,
		}

		subpass := vk.SubpassDescription {
			pipelineBindPoint    = .GRAPHICS,
			colorAttachmentCount = 1,
			pColorAttachments    = &color_attachment_ref,
		}

		dependency := vk.SubpassDependency {
			srcSubpass    = vk.SUBPASS_EXTERNAL,
			dstSubpass    = 0,
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}

		render_pass := vk.RenderPassCreateInfo {
			sType           = .RENDER_PASS_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_attachment,
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

	// Set up pipeline.
	{
		dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
		dynamic_state := vk.PipelineDynamicStateCreateInfo {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = 2,
			pDynamicStates    = raw_data(dynamic_states),
		}

		binding := vk.VertexInputBindingDescription {
			binding   = 0,
			stride    = size_of(Vertex),
			inputRate = .VERTEX,
		}

		attributes := []vk.VertexInputAttributeDescription {
			{location = 0, binding = 0, format = .R32G32_SFLOAT,    offset = u32(offset_of(Vertex, position))},
			{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, color))},
		}

		vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
			sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount   = 1,
			pVertexBindingDescriptions      = &binding,
			vertexAttributeDescriptionCount = u32(len(attributes)),
			pVertexAttributeDescriptions    = raw_data(attributes),
		}

		input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
			sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
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
			cullMode    = {.BACK},
			frontFace   = .CLOCKWISE,
		}

		multisampling := vk.PipelineMultisampleStateCreateInfo {
			sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
			minSampleShading     = 1,
		}

		color_blend_attachment := vk.PipelineColorBlendAttachmentState {
			colorWriteMask = {.R, .G, .B, .A},
		}

		color_blending := vk.PipelineColorBlendStateCreateInfo {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_blend_attachment,
		}

		pipeline_layout := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
		}
		must(vk.CreatePipelineLayout(g_device, &pipeline_layout, nil, &g_pipeline_layout))

		pipeline := vk.GraphicsPipelineCreateInfo {
			sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
			stageCount          = 2,
			pStages             = &g_shader_stages[0],
			pVertexInputState   = &vertex_input_info,
			pInputAssemblyState = &input_assembly,
			pViewportState      = &viewport_state,
			pRasterizationState = &rasterizer,
			pMultisampleState   = &multisampling,
			pColorBlendState    = &color_blending,
			pDynamicState       = &dynamic_state,
			layout              = g_pipeline_layout,
			renderPass          = g_render_pass,
			subpass             = 0,
			basePipelineIndex   = -1,
		}
		must(vk.CreateGraphicsPipelines(g_device, 0, 1, &pipeline, nil, &g_pipeline))
	}
	defer vk.DestroyPipelineLayout(g_device, g_pipeline_layout, nil)
	defer vk.DestroyPipeline(g_device, g_pipeline, nil)

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

	create_vertex_buffers()
	defer destroy_vertex_buffers()
	defer delete(g_vertices)

	current_frame := 0
	for !glfw.WindowShouldClose(g_window) {
		free_all(context.temp_allocator)

		glfw.PollEvents()

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
		loopfn()
		upload_vertices(current_frame)

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