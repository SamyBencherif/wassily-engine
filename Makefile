main:
	# compile shaders
	glslc wassily/shader.vert -o wassily/vert.spv
	glslc wassily/shader.frag -o wassily/frag.spv
	
	# run program
	odin run src