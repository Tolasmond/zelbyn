package tests

import "../view/grid"
import "../view/vt"
import "core:strings"

// What the viewer's tests share: a grid's text and the events they feed.

// The text of g, a line per row, trailing spaces trimmed, each line ended.
view_text :: proc(g: ^grid.Grid) -> string {
	b := strings.builder_make(context.temp_allocator)
	for y in 0 ..< g.height {
		strings.write_string(&b, strings.trim_right(grid.line(g, y), " "))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

view_key :: proc(code: vt.Key_Code, mods: vt.Modifiers = {}) -> vt.Event {
	return vt.Key{code = code, mods = mods}
}

view_char :: proc(r: rune, mods: vt.Modifiers = {}) -> vt.Event {
	return vt.Key{code = .Char, char = r, mods = mods}
}

view_click :: proc(x, y: int) -> vt.Event {
	return vt.Mouse{kind = .Press, button = .Left, x = x, y = y}
}

view_drag :: proc(x, y: int) -> vt.Event {
	return vt.Mouse{kind = .Drag, button = .Left, x = x, y = y}
}

view_release :: proc(x, y: int) -> vt.Event {
	return vt.Mouse{kind = .Release, button = .Left, x = x, y = y}
}

view_wheel :: proc(x, y: int, down: bool) -> vt.Event {
	return vt.Mouse{kind = down ? .Wheel_Down : .Wheel_Up, x = x, y = y}
}
