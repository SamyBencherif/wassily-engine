GLBS := $(patsubst %.blend,%.glb,$(wildcard assets/*.blend))

main: shaders $(GLBS)
	odin run src

# noclip fly camera
editor: shaders $(GLBS)
	odin run src -define:EDITOR=true

shaders:
	glslc wassily/shader.vert -o wassily/vert.spv
	glslc wassily/shader.frag -o wassily/frag.spv
	glslc wassily/mesh.vert -o wassily/mesh_vert.spv
	glslc wassily/mesh.frag -o wassily/mesh_frag.spv
	glslc wassily/line.vert -o wassily/line_vert.spv

assets/%.glb: assets/%.blend tools/export_gltf.py
	blender -b $< --python-exit-code 1 --python tools/export_gltf.py -- $@

.PHONY: main editor shaders