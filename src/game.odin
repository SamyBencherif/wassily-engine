package game

import "../wassily"
import "core:fmt"
import "core:math"
import "core:math/rand"
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

// Set by `make editor`: the camera flies freely through the world.
EDITOR :: #config(EDITOR, false)

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
    player.noclip = EDITOR
    respawn()
}

respawn :: proc()
{
    spawn := worlds[current].model.spawn.? or_else wassily.Spawn{}
    player.position = spawn.position
    player.yaw = spawn.yaw
    player.pitch = 0
    player.velocity_y = 0
    player.grounded = false
    player.ground_triangle = -1
    platform_prev = nil
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
    model := worlds[current].model
    collider := model.collider

    if "MovingPlatform" in model.objects {
        position := ping_pong(PLATFORM_A, PLATFORM_B, wassily.time() * 0.06)
        wassily.set_position(model, "MovingPlatform", position)

        // Platform triangles come after the world's, so a ground index past them means the player stands on it.
        on_platform := player.grounded && player.ground_triangle >= len(model.collider)
        if prev, ok := platform_prev.?; ok && on_platform {
            player.position += position - prev
        }
        platform_prev = position

        combined := make([dynamic]wassily.Triangle, context.temp_allocator)
        append(&combined, ..model.collider)
        append(&combined, ..wassily.object_collider(model, "MovingPlatform"))
        collider = combined[:]
    }

    if menu == .None {
        if wassily.is_pressed(.Escape) || wassily.is_gamepad_pressed(.Start) {
            open_menu(.Pause)
        } else {
            wassily.update_first_person_controller(&player, collider)
            if !player.noclip && player.position.y < -40 {
                respawn()
            }
        }
    } else {
        update_menu()
    }

    model = worlds[current].model
    if "Cube.003" in model.objects {
        wassily.set_color(model, "Cube.003", rainbow(wassily.time() * 0.25))
    }
    if origin, ok := model.markers["_fire"]; ok {
        if menu == .None { update_fire(origin) }
        draw_fire(origin)
    } else {
        clear(&fire)
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

// Blender <x, y, z> is glTF/Y-up <x, z, -y>.
PLATFORM_A :: wassily.Vector3{-17.443, 4.86542, 0}
PLATFORM_B :: wassily.Vector3{-30.323, 4.86542, 0}

platform_prev : Maybe(wassily.Vector3)

// Eases from a to b and back once per 1.0 of t.
ping_pong :: proc(a, b: wassily.Vector3, t: f64) -> wassily.Vector3
{
    k := (1 - math.cos(t * math.TAU)) / 2
    return a + (b - a) * k
}

Particle :: struct {
    position: wassily.Vector3,
    velocity: wassily.Vector3,
    age, lifetime, size: f64,
}

FIRE_RATE      :: 120.0
FIRE_RADIUS    :: 0.35
FIRE_LIGHT_BOX :: wassily.Vector3{8, 5, 8}

fire : [dynamic]Particle
fire_spawn_debt : f64

update_fire :: proc(origin: wassily.Vector3)
{
    dt := min(wassily.dt(), 0.1)

    fire_spawn_debt += FIRE_RATE * dt
    for fire_spawn_debt >= 1 {
        fire_spawn_debt -= 1
        angle := rand.float64() * math.TAU
        r := math.sqrt(rand.float64()) * FIRE_RADIUS
        append(&fire, Particle{
            position = origin + {math.cos(angle) * r, 0, math.sin(angle) * r},
            velocity = {rand.float64_range(-0.2, 0.2), rand.float64_range(1.2, 2.2), rand.float64_range(-0.2, 0.2)},
            lifetime = rand.float64_range(0.6, 1.2),
            size     = rand.float64_range(0.15, 0.3),
        })
    }

    t := wassily.time()
    for i := 0; i < len(fire); {
        p := &fire[i]
        p.age += dt
        if p.age >= p.lifetime {
            unordered_remove(&fire, i)
            continue
        }
        // Pull toward the center axis so the flame tapers, with a little sway.
        p.velocity.x += ((origin.x - p.position.x) * 2 + math.sin(t * 7 + p.position.y * 3) * 0.6) * dt
        p.velocity.z += ((origin.z - p.position.z) * 2 + math.cos(t * 5 + p.position.y * 3) * 0.6) * dt
        p.position += p.velocity * dt
        i += 1
    }
}

draw_fire :: proc(origin: wassily.Vector3)
{
    for p in fire {
        k := p.age / p.lifetime
        // White-yellow core -> orange -> dim red; additive, so fading to black fades out.
        color := math.lerp(wassily.Color{255, 230, 120}, wassily.Color{255, 80, 10}, math.min(k * 2, 1))
        color *= (1 - k) * (1 - k) * 0.6
        size := p.size * (1 - k * 0.7)
        wassily.draw_rect_3d(p.position, size, size * 1.4, color)
    }

    t := wassily.time()
    flicker := 0.8 + 0.12 * math.sin(t * 13) + 0.08 * math.sin(t * 29 + 1.3)
    wassily.draw_box_light({
        center    = origin + {0, 1, 0},
        size      = FIRE_LIGHT_BOX,
        color     = {255, 140, 50},
        intensity = 2.5 * flicker,
    })
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
