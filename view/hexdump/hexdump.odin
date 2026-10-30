// Package hexdump draws a file's bytes as a pane of hnoss widgets: each
// line an offset, the bytes in hex and the same bytes as text, with the
// bytes of the selected value highlighted, and around them, shaded, those
// of the set it is in. Only the lines on screen are formatted.
package hexdump

import "../hnoss/buffer"
import "../hnoss/layout"
import "../hnoss/style"
import "../hnoss/widgets"

// The pane's state, which the caller keeps across frames. Its address is
// the pane's identity for focus.
State :: struct {
	data:   []byte,
	line:   int, // the first line on screen
	follow: int, // an offset to bring on screen at the next draw, or -1
	digits: int, // the hex digits each offset is shown with
}

Range :: struct {
	offset, size: int,
}

// What the pane highlights: the bytes of value, the selected one's, and
// shaded around them those of outer, the set it is in. A value of size 0,
// of bits left over, is a mark at its offset. note, when it is not "", is
// a line at the bottom of the pane.
Highlight :: struct {
	value:     Range,
	has_value: bool,
	outer:     Range,
	has_outer: bool,
	note:      string,
}

// The bytes each line shows in a pane width columns wide, with offsets of
// digits hex digits: 16, or fewer when they do not fit, 1 at least.
bytes_per_line :: proc(width, digits: int) -> int {
	for n := 16; n > 1; n /= 2 {
		if line_width(n, digits) <= width do return n
	}
	return 1
}

// The columns of a line of n bytes: the offset, two spaces, each byte in
// hex followed by a space, with one more after the eighth of 16, another
// space, and the n bytes as text.
line_width :: proc(n, digits: int) -> int {
	return text_column(n, digits) + n
}

// Draws s.data in area, with a scrollbar when it does not fit, and the
// bytes of h highlighted. When s.follow is an offset, the pane first
// scrolls to show its line, a quarter down, unless it is on screen. While
// the pane has focus, ↑ ↓ (or k j) scroll by a line, PgUp PgDn by a page,
// and Home End to the first and last; the wheel scrolls; a click focuses
// it. Returns true when the first line on screen changed.
draw :: proc(ui: ^widgets.Ui, area: layout.Rect, s: ^State, h: Highlight) -> (changed: bool) {
	if area.width <= 0 || area.height <= 0 do return false
	old_line := s.line
	body := area
	if h.note != "" && body.height > 1 {
		note := layout.cut_bottom(&body, 1)
		buffer.set_string(ui.buf, note.x, note.y, h.note, ui.theme.muted, note.width)
	}

	n := bytes_per_line(body.width, s.digits)
	lines := (len(s.data) + n - 1) / n
	bar: layout.Rect
	if lines > body.height {
		bar = layout.cut_right(&body, 1)
		n = bytes_per_line(body.width, s.digits)
		lines = (len(s.data) + n - 1) / n
	}
	last := max(lines - body.height, 0)

	page := max(body.height - 1, 1)
	it: widgets.Key_Iter
	for k, i in widgets.next_key(ui, s, &it) {
		used := true
		code := k.code
		if code == .Char && k.mods == {} {
			switch k.char {
			case 'k': code = .Up
			case 'j': code = .Down
			}
		}
		#partial switch code {
		case .Up:        s.line -= 1
		case .Down:      s.line += 1
		case .Page_Up:   s.line -= page
		case .Page_Down: s.line += page
		case .Home:      s.line = 0
		case .End:       s.line = last
		case:
			used = false
		}
		if used {
			widgets.consume(ui, i)
			s.line = clamp(s.line, 0, last)
		}
	}
	mit: widgets.Key_Iter
	for e, i in widgets.next_mouse(ui, nil, body, &mit) {
		#partial switch e.kind {
		case .Press:
			widgets.focus(ui, s)
		case .Scroll:
			#partial switch e.button {
			case .Wheel_Up:   s.line -= 3
			case .Wheel_Down: s.line += 3
			}
		case:
			continue
		}
		s.line = clamp(s.line, 0, last)
		widgets.consume(ui, i)
	}

	if s.follow >= 0 {
		target := s.follow / n
		if target < s.line || target >= s.line + body.height do s.line = target - body.height / 4
		s.follow = -1
	}
	s.line = clamp(s.line, 0, last)
	if bar.width > 0 do widgets.scrollbar(ui, bar, lines, body.height, &s.line)

	for y in 0 ..< min(body.height, lines - s.line) {
		draw_line(ui, {body.x, body.y + y, body.width, 1}, s, (s.line + y) * n, n, h)
	}
	return s.line != old_line
}

// The column of byte i's hex in a line of n bytes.
@(private)
hex_column :: proc(i, n, digits: int) -> int {
	return digits + 2 + 3 * i + (n == 16 && i >= 8 ? 1 : 0)
}

@(private)
text_column :: proc(n, digits: int) -> int {
	return hex_column(n - 1, n, digits) + 4
}

// Draws the line of n bytes from start in line.
@(private)
draw_line :: proc(ui: ^widgets.Ui, line: layout.Rect, s: ^State, start, n: int, h: Highlight) {
	t := ui.theme
	lower := "0123456789abcdef"
	buf: [32]byte
	offset := hex_text(buf[:], start, s.digits)
	buffer.set_string(ui.buf, line.x, line.y, offset, t.muted, line.width)

	// the style of the byte at offset, and whether it is highlighted
	byte_style :: proc(t: widgets.Theme, h: Highlight, offset: int) -> (st: style.Style, on: bool) {
		if h.has_value && h.value.size > 0 && offset >= h.value.offset && offset < h.value.offset + h.value.size do return t.selected, true
		if h.has_outer && offset >= h.outer.offset && offset < h.outer.offset + h.outer.size do return t.selected_unfocused, true
		return {}, false
	}
	right := line.x + line.width
	for i in 0 ..< n {
		at := start + i
		if at >= len(s.data) do break
		b := s.data[at]
		st, on := byte_style(t, h, at)
		x := line.x + hex_column(i, n, s.digits)
		if h.has_value && h.value.size == 0 && at == h.value.offset {
			// a value of bits left over: a mark on the byte it starts in
			st = {fg = t.accent.fg, add = {.Underlined, .Bold}}
		}
		pair := [2]byte{lower[b >> 4], lower[b & 0xf]}
		if x + 2 <= right do buffer.set_string(ui.buf, x, line.y, string(pair[:]), st)
		// the spaces after it, between two highlighted bytes, join them: in
		// their style, or between the value and the set around it, the set's
		if i + 1 < n && at + 1 < len(s.data) && on {
			next, next_on := byte_style(t, h, at + 1)
			if next_on {
				gap_style := next == st ? st : t.selected_unfocused
				for gap := x + 2; gap < line.x + hex_column(i + 1, n, s.digits) && gap < right; gap += 1 {
					buffer.set_string(ui.buf, gap, line.y, " ", gap_style)
				}
			}
		}
		tx := line.x + text_column(n, s.digits) + i
		ch := [1]byte{b >= 0x20 && b < 0x7f ? b : '.'}
		if tx < right do buffer.set_string(ui.buf, tx, line.y, string(ch[:]), st)
	}
}

// x in uppercase hex, padded with zeros to digits, in buf.
@(private)
hex_text :: proc(buf: []byte, x, digits: int) -> string {
	n := max(digits, 1)
	for x >> uint(4 * n) > 0 do n += 1
	n = min(n, len(buf))
	hex := "0123456789ABCDEF"
	for i in 0 ..< n {
		buf[n - 1 - i] = hex[(x >> uint(4 * i)) & 0xf]
	}
	return string(buf[:n])
}
