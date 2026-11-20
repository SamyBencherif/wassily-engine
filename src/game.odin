package game

import "../wassily"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

World :: struct {
    name: string,
    model: wassily.Model,
}

Menu :: enum {
    None,
    Pause,
    Worlds,
}

worlds : [dynamic]World
current : int
player : wassily.First_Person_Controller
menu : Menu
selected : int

init :: proc()
{
    paths, err := filepath.glob("assets/*.glb", context.temp_allocator)
    if err != nil || len(paths) == 0 {
        panic("no worlds found in assets/*.glb")
    }
    for path in paths {
        append(&worlds, World{strings.clone(filepath.stem(path)), wassily.load_model(path)})
        if filepath.stem(path) == "world" { current = len(worlds) - 1 }
    }

    player = wassily.first_person_controller()
    respawn()
}

respawn :: proc()
{
    spawn := worlds[current].model.spawn.? or_else wassily.Spawn{}
    player.position = spawn.position
    player.yaw = spawn.yaw
    player.pitch = 0
    player.velocity_y = 0
}

open_menu :: proc(m: Menu)
{
    menu = m
    selected = current if m == .Worlds else 0
    wassily.set_mouse_captured(&player, false)
}

close_menu :: proc()
{
    menu = .None
    wassily.set_mouse_captured(&player, true)
}

loop :: proc() 
{
    if menu == .None {
        if wassily.is_pressed(.Escape) || wassily.is_gamepad_pressed(.Start) {
            open_menu(.Pause)
        } else {
            wassily.update_first_person_controller(&player, worlds[current].model.collider)
            if player.position.y < -40 {
                respawn()
            }
        }
    } else {
        update_menu()
    }

    model := worlds[current].model
    if "Cube.003" in model.objects {
        wassily.set_color(model, "Cube.003", rainbow(wassily.time() * 0.25))
    }
    wassily.draw_model(model, wassily.Transform{scale = {1, 1, 1}})

    if menu != .None {
        draw_menu()
    }
}

// Hue in turns (wraps every 1.0), full saturation and value.
rainbow :: proc(hue: f64) -> wassily.Color
{
    h := math.mod(hue, 1) * 6
    x := 1 - abs(math.mod(h, 2) - 1)
    rgb: [3]f64
    switch int(h) {
    case 0: rgb = {1, x, 0}
    case 1: rgb = {x, 1, 0}
    case 2: rgb = {0, 1, x}
    case 3: rgb = {0, x, 1}
    case 4: rgb = {x, 0, 1}
    case:   rgb = {1, 0, x}
    }
    return rgb * 255
}

PAUSE_ITEMS := []string{"Resume", "Worlds", "Quit"}

menu_items :: proc() -> []string
{
    switch menu {
    case .Pause:
        return PAUSE_ITEMS
    case .Worlds:
        items := make([]string, len(worlds) + 1, context.temp_allocator)
        for w, i in worlds { items[i] = w.name }
        items[len(worlds)] = "Back"
        return items
    case .None:
    }
    return nil
}

ITEM_SCALE  :: 4
ITEM_HEIGHT :: 60
ITEM_WIDTH  :: 500

item_rect :: proc(i, count: int) -> (x, y, w, h: int)
{
    width, height := wassily.size()
    top := height / 2 - count * ITEM_HEIGHT / 2 + 40
    return width / 2 - ITEM_WIDTH / 2, top + i * ITEM_HEIGHT, ITEM_WIDTH, ITEM_HEIGHT - 10
}

update_menu :: proc()
{
    items := menu_items()
    if wassily.is_pressed(.Up)   || wassily.is_pressed(.W) || wassily.is_gamepad_pressed(.Dpad_Up)   { selected -= 1 }
    if wassily.is_pressed(.Down) || wassily.is_pressed(.S) || wassily.is_gamepad_pressed(.Dpad_Down) { selected += 1 }
    selected = (selected + len(items)) % len(items)

    mouse := wassily.mouse_position()
    clicked := false
    for _, i in items {
        x, y, w, h := item_rect(i, len(items))
        if mouse.x >= f64(x) && mouse.x < f64(x + w) && mouse.y >= f64(y) && mouse.y < f64(y + h) {
            selected = i
            clicked = wassily.is_mouse_pressed()
        }
    }

    if wassily.is_pressed(.Escape) || wassily.is_gamepad_pressed(.B) || (menu == .Pause && wassily.is_gamepad_pressed(.Start)) {
        if menu == .Worlds { open_menu(.Pause) } else { close_menu() }
        return
    }

    if !(clicked || wassily.is_pressed(.Enter) || wassily.is_pressed(.Space) || wassily.is_gamepad_pressed(.A)) {
        return
    }
    switch menu {
    case .Pause:
        switch selected {
        case 0: close_menu()
        case 1: open_menu(.Worlds)
        case 2: wassily.quit()
        }
    case .Worlds:
        if selected < len(worlds) {
            current = selected
            respawn()
            close_menu()
        } else {
            open_menu(.Pause)
        }
    case .None:
    }
}

draw_menu :: proc()
{
    width, _ := wassily.size()
    items := menu_items()

    _, top, _, _ := item_rect(0, len(items))
    title := "Paused" if menu == .Pause else "Select world"
    wassily.draw_text(width / 2 - wassily.text_width(title, 6) / 2, top - 90, title, 6, {255, 255, 255})

    for item, i in items {
        x, y, w, h := item_rect(i, len(items))
        highlighted := i == selected
        wassily.fill_rect(x, y, w, h, {230, 230, 230} if highlighted else {40, 40, 40})

        label := item
        if menu == .Worlds && i == current { label = fmt.tprintf("%v (current)", item) }
        tx := x + w / 2 - wassily.text_width(label, ITEM_SCALE) / 2
        ty := y + h / 2 - 7 * ITEM_SCALE / 2
        wassily.draw_text(tx, ty, label, ITEM_SCALE, {20, 20, 20} if highlighted else {230, 230, 230})
    }
}

main :: proc() 
{    
    wassily.run(init, loop);
}
