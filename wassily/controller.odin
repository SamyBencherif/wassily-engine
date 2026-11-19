package wassily

import "core:math"
import "core:math/linalg"

import "vendor:glfw"

// Walks on the y=0 plane; yaw/pitch in degrees, yaw 0 faces +Z.
First_Person_Controller :: struct {
	position: Vector3,
	yaw: f64,
	pitch: f64,
	eye_height: f64,
	speed: f64,       // units per second
	sensitivity: f64, // degrees per pixel of mouse motion
	fov: f64,
	captured: bool,
	last_cursor: [2]f64,
}

first_person_controller :: proc(position: Vector3 = {0, 0, 0}, yaw: f64 = 0) -> First_Person_Controller
{
	return First_Person_Controller {
		position    = {position.x, 0, position.z},
		yaw         = yaw,
		eye_height  = 1.7,
		speed       = 5,
		sensitivity = 0.1,
		fov         = 60,
	}
}

// Call once per frame from the loop: handles mouse look, WASD movement and sets the camera.
// Click to capture the mouse, Escape to release it.
update_first_person_controller :: proc(c: ^First_Person_Controller)
{
	if !c.captured && glfw.GetMouseButton(g_window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
		glfw.SetInputMode(g_window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		c.last_cursor.x, c.last_cursor.y = glfw.GetCursorPos(g_window)
		c.captured = true
	}
	if c.captured && is_down(.Escape) {
		glfw.SetInputMode(g_window, glfw.CURSOR, glfw.CURSOR_NORMAL)
		c.captured = false
	}

	if c.captured {
		x, y := glfw.GetCursorPos(g_window)
		c.yaw   -= (x - c.last_cursor.x) * c.sensitivity
		c.pitch -= (y - c.last_cursor.y) * c.sensitivity
		c.pitch = clamp(c.pitch, -89, 89)
		c.last_cursor = {x, y}
	}

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
		c.position += linalg.normalize(move) * c.speed * dt()
	}
	c.position.y = 0

	eye := c.position + Vector3{0, c.eye_height, 0}
	look := Vector3{math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	camera(eye, eye + look, {0, 1, 0}, c.fov)
}
