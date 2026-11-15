main:
	# compile shaders
	glslc wassily/shader.vert -o wassily/vert.spv
	glslc wassily/shader.frag -o wassily/frag.spv
	glslc wassily/mesh.vert -o wassily/mesh_vert.spv
	glslc wassily/mesh.frag -o wassily/mesh_frag.spv
	glslc wassily/line.vert -o wassily/line_vert.spv
	
	# run program
	odin run src