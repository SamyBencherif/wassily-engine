package game

import "../wassily"
import "core:math"

mesh : wassily.Mesh
tex: wassily.Texture
camPos : wassily.Vector3

init :: proc()
{
    mesh = wassily.loadMesh("assets/cube.obj")
    tex  = wassily.loadTexture("assets/brick.jpg")

    camPos = wassily.Vector3{0, 0, -10}
}

loop :: proc() 
{
    w, h := wassily.size()

    camTarget := wassily.Vector3{0, 0, 0}
    camUp := wassily.Vector3{0, 1, 0}
    camFov : f64 = 60

    if wassily.is_down(wassily.KEY_W)
    {
        camPos += wassily.Vector3{0, 0, 1}
    }

    if wassily.is_down(wassily.KEY_S)
    {
        camPos += wassily.Vector3{0, 0, -1}
    }

    wassily.camera(camPos, camTarget, camUp, camFov)

    cubePos := wassily.Vector3{0, 0, 0}
    cubeRot := wassily.Vector3{180*wassily.time(), 180*wassily.time(), 180*wassily.time()} // given in Euler angles
    cubeSca := wassily.Vector3{1, 1, 1}

    transform := wassily.Transform{cubePos, cubeRot, cubeSca}
    wassily.drawMesh(mesh, transform, tex)
    
    a := wassily.Vector3{3, 3, 3}
    b := wassily.Vector3{5, 5, 5}
    color := wassily.Color{255, 100, 100}

    wassily.drawLine3D(a, b, color) 
}

main :: proc() 
{    
    wassily.run(init, loop);
}