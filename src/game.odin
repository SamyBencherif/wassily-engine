package game

import "../wassily"
import "core:math"

world : wassily.Model
player : wassily.First_Person_Controller

init :: proc()
{
    world = wassily.load_model("assets/world.glb")

    player = wassily.first_person_controller({0, 0, 0}, 210)
}

loop :: proc() 
{
    wassily.update_first_person_controller(&player, world.collider)

    cube_pos := wassily.Vector3{0, 0, 0}
    cube_rot := wassily.Vector3{0, 0, 0}
    cube_sca := wassily.Vector3{1, 1, 1}

    transform := wassily.Transform{cube_pos, cube_rot, cube_sca}
    wassily.draw_model(world, transform)
}

main :: proc() 
{    
    wassily.run(init, loop);
}