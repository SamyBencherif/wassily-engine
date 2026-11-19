package game

import "../wassily"
import "core:math"

mesh : wassily.Mesh
tex: wassily.Texture
player : wassily.First_Person_Controller

init :: proc()
{
    mesh = wassily.load_mesh("assets/world.obj")
    tex  = wassily.load_texture("assets/radial-wall.png")

    player = wassily.first_person_controller({0, 0, 0}, 210)
}

loop :: proc() 
{
    wassily.update_first_person_controller(&player)

    cube_pos := wassily.Vector3{0, 0, 0}
    cube_rot := wassily.Vector3{0, 0, 0}
    cube_sca := wassily.Vector3{1, 1, 1}

    transform := wassily.Transform{cube_pos, cube_rot, cube_sca}
    wassily.draw_mesh(mesh, transform, tex)
}

main :: proc() 
{    
    wassily.run(init, loop);
}