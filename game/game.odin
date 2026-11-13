package game

import "../wassily"

t := 0

loop :: proc() 
{
    w, h := wassily.size()
    wassily.fillCircle(w/2 + t, h/2, 100, 200, 255, 0)

    t = t+1
}

main :: proc() 
{
    wassily.run(loop);
}