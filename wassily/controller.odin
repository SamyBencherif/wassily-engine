package wassily

import "core:math"
import "core:math/linalg"

import "vendor:glfw"

// Walks on a collider (or the y=0 plane without one) and jumps with Space / gamepad A; yaw/pitch in degrees, yaw 0 faces +Z.
First_Person_Controller :: struct {
	position: Vector3,
	yaw: f64,
	pitch: f64,
	eye_height: f64,
	speed: f64,       // units per second
	sensitivity: f64, // degrees per pixel of mouse motion
	look_speed: f64,  // degrees per second at full right-stick deflection
	deadzone: f64,    // gamepad stick deadzone, 0..1
	fov: f64,
	jump_speed: f64, // initial upward velocity, units per second
	gravity: f64,    // units per second squared
	velocity_y: f64,
	radius: f64,    // body is a stack of spheres from the feet up to eye height
	max_slope: f64,  // steepest walkable surface, degrees from horizontal
	grounded: bool,
	captured: bool,
	last_cursor: [2]f64,
}

first_person_controller :: proc(position: Vector3 = {0, 0, 0}, yaw: f64 = 0) -> First_Person_Controller
{
	return First_Person_Controller {
		position    = position,
		yaw         = yaw,
		eye_height  = 1.7,
		speed       = 5,
		sensitivity = 0.1,
		look_speed  = 120,
		deadzone    = 0.15,
		fov         = 60,
		jump_speed  = 5,
		gravity     = 9.81 * 1.5,
		radius      = 0.3,
		max_slope   = 60,
	}
}

// Ericson, Real-Time Collision Detection, 5.1.5.
@(private="file")
closest_point_on_triangle :: proc(p: Vector3, t: Triangle) -> Vector3
{
	a, b, c := t[0], t[1], t[2]
	ab, ac := b - a, c - a
	ap := p - a
	d1, d2 := linalg.dot(ab, ap), linalg.dot(ac, ap)
	if d1 <= 0 && d2 <= 0 { return a }
	bp := p - b
	d3, d4 := linalg.dot(ab, bp), linalg.dot(ac, bp)
	if d3 >= 0 && d4 <= d3 { return b }
	vc := d1 * d4 - d3 * d2
	if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
	cp := p - c
	d5, d6 := linalg.dot(ab, cp), linalg.dot(ac, cp)
	if d6 >= 0 && d5 <= d6 { return c }
	vb := d5 * d2 - d1 * d6
	if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
	va := d3 * d6 - d5 * d4
	if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	}
	denom := 1 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)
}

// Pushes the body out of the collider. Walkable surfaces push straight up so the player doesn't slide down slopes.
@(private="file")
resolve_collisions :: proc(c: ^First_Person_Controller, collider: []Triangle) -> (grounded: bool)
{
	r := c.radius
	min_ground_ny := math.cos(c.max_slope * math.PI / 180)
	sphere_count := int(math.ceil((c.eye_height - r) / r)) + 1

	for _ in 0 ..< 3 {
		lo := c.position - r
		hi := c.position + Vector3{r, c.eye_height + r, r}
		for t in collider {
			if max(t[0].x, t[1].x, t[2].x) < lo.x || min(t[0].x, t[1].x, t[2].x) > hi.x ||
			   max(t[0].y, t[1].y, t[2].y) < lo.y || min(t[0].y, t[1].y, t[2].y) > hi.y ||
			   max(t[0].z, t[1].z, t[2].z) < lo.z || min(t[0].z, t[1].z, t[2].z) > hi.z {
				continue
			}
			for i in 0 ..< sphere_count {
				h := r + (c.eye_height - r) * f64(i) / f64(sphere_count - 1)
				center := c.position + Vector3{0, h, 0}
				d := center - closest_point_on_triangle(center, t)
				dist2 := linalg.dot(d, d)
				if dist2 >= r * r { continue }

				dist := math.sqrt(dist2)
				n: Vector3
				if dist > 1e-9 {
					n = d / dist
				} else {
					face := linalg.cross(t[1] - t[0], t[2] - t[0])
					if linalg.length(face) < 1e-12 { continue }
					n = linalg.normalize(face)
				}
				depth := r - dist

				if n.y >= min_ground_ny {
					c.position.y += depth / n.y
					grounded = true
					if c.velocity_y < 0 { c.velocity_y = 0 }
				} else {
					c.position += n * depth
					// Remove the part of vertical velocity going into the surface (ceilings, steep slopes).
					if c.velocity_y * n.y < 0 { c.velocity_y *= 1 - n.y * n.y }
				}
			}
		}
	}
	return grounded
}

// Returns the state of the first connected gamepad, if any.
@(private)
first_gamepad :: proc() -> (state: glfw.GamepadState, ok: bool)
{
	for jid in glfw.JOYSTICK_1 ..= glfw.JOYSTICK_LAST {
		if glfw.JoystickIsGamepad(i32(jid)) && glfw.GetGamepadState(i32(jid), &state) {
			return state, true
		}
	}
	return {}, false
}

// Radial deadzone, rescaled so output ramps smoothly from 0 at the deadzone edge to 1.
@(private="file")
apply_deadzone :: proc(x, y: f32, deadzone: f64) -> [2]f64
{
	v := [2]f64{f64(x), f64(y)}
	l := linalg.length(v)
	if l <= deadzone { return {} }
	return v / l * min((l - deadzone) / (1 - deadzone), 1)
}

// Call once per frame from the loop: handles mouse/right-stick look, WASD/left-stick movement and sets the camera.
// Grabs (hidden, unbounded) or releases the mouse used for looking around.
set_mouse_captured :: proc(c: ^First_Person_Controller, captured: bool)
{
	glfw.SetInputMode(g_window, glfw.CURSOR, glfw.CURSOR_DISABLED if captured else glfw.CURSOR_NORMAL)
	if captured {
		c.last_cursor.x, c.last_cursor.y = glfw.GetCursorPos(g_window)
	}
	c.captured = captured
}

// Click to capture the mouse; release it with set_mouse_captured. Uses the first connected gamepad.
// collider is in world space (e.g. Model.collider drawn with an identity transform); nil walks on the y=0 plane.
update_first_person_controller :: proc(c: ^First_Person_Controller, collider: []Triangle = nil)
{
	if !c.captured && glfw.GetMouseButton(g_window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
		set_mouse_captured(c, true)
	}

	if c.captured {
		x, y := glfw.GetCursorPos(g_window)
		c.yaw   -= (x - c.last_cursor.x) * c.sensitivity
		c.pitch -= (y - c.last_cursor.y) * c.sensitivity
		c.last_cursor = {x, y}
	}

	pad, has_pad := first_gamepad()
	left_stick: [2]f64
	if has_pad {
		left_stick = apply_deadzone(pad.axes[glfw.GAMEPAD_AXIS_LEFT_X], pad.axes[glfw.GAMEPAD_AXIS_LEFT_Y], c.deadzone)
		look := apply_deadzone(pad.axes[glfw.GAMEPAD_AXIS_RIGHT_X], pad.axes[glfw.GAMEPAD_AXIS_RIGHT_Y], c.deadzone)
		c.yaw   -= look.x * c.look_speed * dt()
		c.pitch -= look.y * c.look_speed * dt()
	}
	c.pitch = clamp(c.pitch, -89, 89)

	yaw := c.yaw * math.PI / 180
	pitch := c.pitch * math.PI / 180
	forward := Vector3{math.sin(yaw), 0, math.cos(yaw)}
	right := Vector3{-forward.z, 0, forward.x}

	move: Vector3
	if is_down(.W) { move += forward }
	if is_down(.S) { move -= forward }
	if is_down(.D) { move += right }
	if is_down(.A) { move -= right }
	if linalg.length(move) > 0 {
		move = linalg.normalize(move)
	}
	// GLFW stick Y is -1 when pushed up.
	move += forward * -left_stick.y + right * left_stick.x
	if l := linalg.length(move); l > 1 {
		move /= l
	}

	jump := is_down(.Space) || (has_pad && pad.buttons[glfw.GAMEPAD_BUTTON_A] == glfw.PRESS)
	if c.grounded && jump {
		c.velocity_y = c.jump_speed
	}
	c.velocity_y -= c.gravity * dt()

	horizontal := move * c.speed * dt()
	if collider == nil {
		c.position += horizontal + Vector3{0, c.velocity_y * dt(), 0}
		c.grounded = c.position.y <= 0
		if c.grounded {
			c.position.y = 0
			c.velocity_y = 0
		}
	} else {
		was_grounded := c.grounded
		// Substep so fast falls can't tunnel through thin geometry.
		displacement := horizontal + Vector3{0, c.velocity_y * dt(), 0}
		steps := max(int(math.ceil(linalg.length(displacement) / (c.radius * 0.5))), 1)
		c.grounded = false
		for _ in 0 ..< steps {
			c.position += displacement / f64(steps)
			if resolve_collisions(c, collider) { c.grounded = true }
		}

		// Stick to the ground when walking down slopes instead of launching off them.
		if was_grounded && !c.grounded && c.velocity_y <= 0 {
			saved := c.position
			c.position.y -= linalg.length(horizontal) * math.tan(c.max_slope * math.PI / 180) + 0.01
			if resolve_collisions(c, collider) {
				c.grounded = true
				c.velocity_y = 0
			} else {
				c.position = saved
			}
		}
	}

	eye := c.position + Vector3{0, c.eye_height, 0}
	look := Vector3{math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	camera(eye, eye + look, {0, 1, 0}, c.fov)
}
