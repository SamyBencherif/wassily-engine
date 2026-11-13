package game

import "../wassily"

loop :: proc() 
{
    w, h := wassily.size()
    // wassily.fillCircle(w/2, h/2, 100, 200, 255, 0)

    verts: [dynamic]wassily.Vertex
    wassily.drawCircle(0, 0, 0.5, {1, 0, 0}, 64, &verts)
    wassily.create_vertex_buffer(verts[:])
}

main :: proc() 
{
    wassily.run(loop);
}