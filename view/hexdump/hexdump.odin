// Package hexdump is the pane of a file's bytes: each line an offset, the
// bytes in hex and the same bytes as text, with the bytes of the selected
// value highlighted, and around them, shaded, those of the set it is in.
// Only the lines on screen are formatted. It handles a key or a mouse event
// at a time (view/vt), and draws into a grid (view/grid).
package hexdump

import "../grid"
import "../outline"
import "../vt"

// The pane's state, which the caller keeps.
State :: struct {
	data:     []byte,
	line:     int, // the first line on screen
	follow:   int, // an offset to bring on screen at the next settle, or -1
	digits:   int, // the hex digits each offset is shown with
	dragging: bool, // the scrollbar's thumb is held
}

Range :: struct {
	offset, size: int,
}

// What the pane highlights: the bytes of value, the selected one's, and
// shaded around them those of outer, the set it is in. A value of size 0,
// of bits left over, is a mark at its offset. error is where a failed
// decode stopped, marked over both: a byte, or the bytes a value in
// decompressed bytes came from, or past the last byte, a mark where the
// next would be. note, when it is not "", is a line at the bottom of the
// pane.
Highlight :: struct {
	value:     Range,
	has_value: bool,
	outer:     Range,
	has_outer: bool,
	error:     Range,
	has_error: bool,
	note:      string,
}

// The style of the byte where a failed decode stopped.
ERROR_STYLE :: grid.Style{fg = .Black, bg = .Red, attrs = {.Bold}}

// The style of a mark: a value of no bytes, or of bits left over.
MARK_STYLE :: grid.Style{fg = outline.ACCENT.fg, attrs = {.Underlined, .Bold}}

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

// The pane's parts, in area, for h: the lines of bytes, its scrollbar's
// column, the last, while they do not fit, and the line of h's note at the
// bottom; the bytes a line shows, the lines there are, and the last that
// can be first on screen.
@(private)
Parts :: struct {
	body, bar, note: grid.Rect,
	per_line:        int,
	lines, last:     int,
}

@(private)
parts :: proc(s: ^State, area: grid.Rect, h: Highlight) -> (p: Parts) {
	p.body = area
	if h.note != "" && area.height > 1 do p.note, p.body = grid.split_bottom(area, 1)
	// a mark at the end of the data has a place of its own, past its last
	// byte, maybe on a line of its own
	positions := len(s.data)
	if end_mark(s, h) do positions += 1
	p.per_line = bytes_per_line(p.body.width, s.digits)
	p.lines = (positions + p.per_line - 1) / p.per_line
	if p.lines > p.body.height {
		p.bar, p.body = grid.split_right(p.body, 1)
		p.per_line = bytes_per_line(p.body.width, s.digits)
		p.lines = (positions + p.per_line - 1) / p.per_line
	}
	p.last = max(p.lines - p.body.height, 0)
	return
}

// Handles key k, while the pane, area, has focus: ↑ ↓ (or k j) scroll by a
// line, PgUp PgDn by a page, and Home End to the first and last. Returns
// whether the key was the pane's.
handle_key :: proc(s: ^State, k: vt.Key, area: grid.Rect, h: Highlight) -> (used: bool) {
	settle(s, area, h)
	p := parts(s, area, h)
	page := max(p.body.height - 1, 1)
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
	case .End:       s.line = p.last
	case:
		return false
	}
	s.line = clamp(s.line, 0, p.last)
	return true
}

// Handles mouse event e, in the pane, area: the wheel scrolls, and a click
// or a drag on the scrollbar scrolls to where it is. Returns whether the
// event was the pane's: in it, or a drag of its thumb.
handle_mouse :: proc(s: ^State, e: vt.Mouse, area: grid.Rect, h: Highlight) -> (used: bool) {
	settle(s, area, h)
	p := parts(s, area, h)
	if e.kind == .Release && s.dragging {
		s.dragging = false
		return true
	}
	if s.dragging && e.kind == .Drag || grid.contains(p.bar, e.x, e.y) && e.kind == .Press && e.button == .Left {
		s.dragging = true
		s.line = grid.scrollbar_line(p.bar, p.lines, p.body.height, e.y)
		return true
	}
	if !grid.contains(area, e.x, e.y) do return false
	#partial switch e.kind {
	case .Wheel_Up:   s.line -= 3
	case .Wheel_Down: s.line += 3
	}
	s.line = clamp(s.line, 0, p.last)
	return true
}

// Keeps s whole for the pane, area, highlighting h: when s.follow is an
// offset, scrolls to show its line, a quarter down, unless it is on
// screen; and the first line on screen where the lines fill it.
settle :: proc(s: ^State, area: grid.Rect, h: Highlight) {
	p := parts(s, area, h)
	if s.follow >= 0 && p.per_line > 0 {
		target := s.follow / p.per_line
		if target < s.line || target >= s.line + p.body.height do s.line = target - p.body.height / 4
		s.follow = -1
	}
	s.line = clamp(s.line, 0, p.last)
}

// Draws s.data in area of g, with a scrollbar when it does not fit, and the
// bytes of h highlighted.
draw :: proc(g: ^grid.Grid, area: grid.Rect, s: ^State, h: Highlight) {
	if area.width <= 0 || area.height <= 0 do return
	settle(s, area, h)
	p := parts(s, area, h)
	if p.note.height > 0 do grid.put(g, p.note.x, p.note.y, h.note, outline.MUTED, p.note.width)
	if p.bar.width > 0 do grid.scrollbar(g, p.bar, p.lines, p.body.height, s.line, outline.ACCENT, outline.MUTED)
	for y in 0 ..< min(p.body.height, p.lines - s.line) {
		draw_line(g, {p.body.x, p.body.y + y, p.body.width, 1}, s, (s.line + y) * p.per_line, p.per_line, h)
	}
}

// Whether h has a mark past the last byte of s.data: a value of no bytes
// at the end, or an error there or past it.
@(private)
end_mark :: proc(s: ^State, h: Highlight) -> bool {
	return (h.has_value && h.value.size == 0 && h.value.offset == len(s.data)) || (h.has_error && h.error.offset >= len(s.data))
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

// Draws the line of n bytes from start in line of g.
@(private)
draw_line :: proc(g: ^grid.Grid, line: grid.Rect, s: ^State, start, n: int, h: Highlight) {
	lower := "0123456789abcdef"
	buf: [32]byte
	offset := hex_text(buf[:], start, s.digits)
	grid.put(g, line.x, line.y, offset, outline.MUTED, line.width)

	// the style of the byte at offset, and whether it is highlighted
	byte_style :: proc(h: Highlight, offset: int) -> (st: grid.Style, on: bool) {
		// the error first: the value selected at first is often the one that failed
		if h.has_error && offset >= h.error.offset && offset < h.error.offset + max(h.error.size, 1) do return ERROR_STYLE, true
		if h.has_value && h.value.size > 0 && offset >= h.value.offset && offset < h.value.offset + h.value.size do return outline.SELECTED, true
		if h.has_outer && offset >= h.outer.offset && offset < h.outer.offset + h.outer.size do return outline.SELECTED_UNFOCUSED, true
		return {}, false
	}
	right := line.x + line.width
	// text in a style at x, when it fits before the line's right
	put :: proc(g: ^grid.Grid, x, y, right: int, text: string, st: grid.Style) {
		if x + len(text) <= right do grid.put(g, x, y, text, st, len(text))
	}
	for i in 0 ..< n {
		at := start + i
		if at >= len(s.data) {
			// a value of no bytes, or an error, at the end: a mark where the
			// next byte would be
			if at == len(s.data) && end_mark(s, h) {
				st := MARK_STYLE
				if h.has_error && h.error.offset >= at {
					st = ERROR_STYLE
					st.attrs += {.Underlined}
				}
				put(g, line.x + hex_column(i, n, s.digits), line.y, right, "  ", st)
				put(g, line.x + text_column(n, s.digits) + i, line.y, right, " ", st)
			}
			break
		}
		b := s.data[at]
		st, on := byte_style(h, at)
		x := line.x + hex_column(i, n, s.digits)
		if h.has_value && h.value.size == 0 && at == h.value.offset && st != ERROR_STYLE {
			// a value of bits left over: a mark on the byte it starts in
			st = MARK_STYLE
		}
		pair := [2]byte{lower[b >> 4], lower[b & 0xf]}
		put(g, x, line.y, right, string(pair[:]), st)
		// the spaces after it, between two highlighted bytes, join them: in
		// their style, or between the value and the set around it, the set's
		if i + 1 < n && at + 1 < len(s.data) && on {
			next, next_on := byte_style(h, at + 1)
			if next_on {
				gap_style := next == st ? st : outline.SELECTED_UNFOCUSED
				for gap := x + 2; gap < line.x + hex_column(i + 1, n, s.digits) && gap < right; gap += 1 {
					put(g, gap, line.y, right, " ", gap_style)
				}
			}
		}
		ch := [1]byte{b >= 0x20 && b < 0x7f ? b : '.'}
		put(g, line.x + text_column(n, s.digits) + i, line.y, right, string(ch[:]), st)
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
