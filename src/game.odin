package game

import "../wassily"
import "core:math"

mesh : wassily.Mesh
tex: wassily.Texture
player : wassily.First_Person_Controller

init :: proc()
{
    mesh = wassily.load_mesh("assets/room.obj")
    tex  = wassily.load_texture("assets/radial-wall.png")

    player = wassily.first_person_controller({0, 0, -10})
}

loop :: proc() 
{
    wassily.update_first_person_controller(&player)

    cube_pos := wassily.Vector3{0, 0, 0}
    cube_rot := wassily.Vector3{0, 0, 0}
    cube_sca := wassily.Vector3{1, 1, 1}

    transform := wassily.Transform{cube_pos, cube_rot, cube_sca}
    wassily.draw_mesh(mesh, transform, tex)
    
    a := wassily.Vector3{3, 3, 3}
    b := wassily.Vector3{5, 5, 5}
    color := wassily.Color{255, 100, 100}

    wassily.draw_line_3d(a, b, color) 
}

main :: proc() 
{    
    wassily.run(init, loop);
}