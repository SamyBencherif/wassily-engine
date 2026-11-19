package game

import "../wassily"
import "core:math"

world : wassily.Model
player : wassily.First_Person_Controller

init :: proc()
{
    world = wassily.load_model("assets/world.glb")

    player = wassily.first_person_controller()
    respawn()
}

respawn :: proc()
{
    spawn := world.spawn.? or_else wassily.Spawn{}
    player.position = spawn.position
    player.yaw = spawn.yaw
    player.pitch = 0
    player.velocity_y = 0
}

loop :: proc() 
{
    wassily.update_first_person_controller(&player, world.collider)

    pos := wassily.Vector3{0, 0, 0}
    rot := wassily.Vector3{0, 0, 0}
    sca := wassily.Vector3{1, 1, 1}

    transform := wassily.Transform{pos, rot, sca}
    wassily.draw_model(world, transform)

    if player.position.y < -40
    {
        respawn()
    }
}

main :: proc() 
{    
    wassily.run(init, loop);
}