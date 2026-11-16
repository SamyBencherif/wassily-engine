package game

import "../wassily"
import "core:math"

mesh : wassily.Mesh
tex: wassily.Texture
cam_pos : wassily.Vector3

init :: proc()
{
    mesh = wassily.load_mesh("assets/room.obj")
    tex  = wassily.load_texture("assets/radial-wall.png")

    cam_pos = wassily.Vector3{0, 0, -10}
}

loop :: proc() 
{
    w, h := wassily.size()

    cam_up := wassily.Vector3{0, 1, 0}
    cam_fov : f64 = 60
    cam_speed : f64 = 5 // units per second

    if wassily.is_down(.W)
    {
        cam_pos += wassily.Vector3{0, 0, 1} * cam_speed * wassily.dt()
    }

    if wassily.is_down(.S)
    {
        cam_pos += wassily.Vector3{0, 0, -1} * cam_speed * wassily.dt()
    }

    if wassily.is_down(.A)
    {
        cam_pos += wassily.Vector3{1, 0, 0} * cam_speed * wassily.dt()
    }

    if wassily.is_down(.D)
    {
        cam_pos += wassily.Vector3{-1, 0, 0} * cam_speed * wassily.dt()
    }

    cam_target := cam_pos + wassily.Vector3{0, 0, 1}

    wassily.camera(cam_pos, cam_target, cam_up, cam_fov)

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