// Package outline is the pane of the rows of a decoded tree (view/rows):
// an outline of the tree, each row indented by its depth, with a marker for
// a set or array that can be expanded, its name, its value, and its offset
// in the file. It handles a key or a mouse event at a time (view/vt), and
// draws into a grid (view/grid).
package outline

import "../grid"
import "../rows"
import "../vt"

// The pane's state, which the caller keeps.
State :: struct {
	model:    ^rows.Model,
	selected: int, // the selected row
	offset:   int, // the first row on screen
	digits:   int, // the hex digits each offset is shown with (offset_digits); 0 shows none
	// set to bring the selection on screen at the next settle, as a key
	// that moves it does, when it is set from outside
	show_selection: bool,
	dragging:       bool, // the scrollbar's thumb is held
}

// The styles of the viewer's panes.
TEXT :: grid.Style{}
MUTED :: grid.Style{fg = .Bright_Black}
TITLE :: grid.Style{attrs = {.Bold}}
ACCENT :: grid.Style{fg = .Cyan}
SELECTED :: grid.Style{fg = .Black, bg = .Cyan, attrs = {.Bold}}
SELECTED_UNFOCUSED :: grid.Style{bg = .Bright_Black}

// The hex digits that show every offset of an input of size bytes, at
// least 4.
offset_digits :: proc(size: int) -> int {
	n := 4
	for x := size >> 16; x > 0; x >>= 4 do n += 1
	return n
}

// The pane's rows and its scrollbar, in area: the scrollbar's column, the
// last, while the rows do not fit.
@(private)
parts :: proc(s: ^State, area: grid.Rect) -> (body, bar: grid.Rect) {
	body = area
	if rows.count(s.model) > area.height do bar, body = grid.split_right(area, 1)
	return
}

// Handles key k, while the pane, area, has focus: ↑ ↓ (or k j), PgUp PgDn,
// Home End move the selection; → (or l) expands the selected row, or moves
// to its first row when it is expanded; ← (or h) collapses it, or moves to
// the row it is under; Enter expands or collapses it. The selection is
// kept on screen. Returns whether the key was the pane's.
handle_key :: proc(s: ^State, k: vt.Key, area: grid.Rect) -> (used: bool) {
	m := s.model
	page := max(area.height - 1, 1)
	code := k.code
	if code == .Char && k.mods == {} {
		switch k.char {
		case 'k': code = .Up
		case 'j': code = .Down
		case 'h': code = .Left
		case 'l': code = .Right
		}
	}
	#partial switch code {
	case .Up:        s.selected -= 1
	case .Down:      s.selected += 1
	case .Page_Up:   s.selected -= page
	case .Page_Down: s.selected += page
	case .Home:      s.selected = 0
	case .End:       s.selected = rows.count(m) - 1
	case .Right:
		if !rows.expand(m, s.selected) && is_expanded(m, s.selected) do s.selected += 1
	case .Left:
		if !rows.collapse(m, s.selected) {
			if p := rows.parent(m, s.selected); p >= 0 do s.selected = p
		}
	case .Enter:
		if !rows.collapse(m, s.selected) do rows.expand(m, s.selected)
	case:
		return false
	}
	s.show_selection = true
	settle(s, area)
	return true
}

// Handles mouse event e, in the pane, area: a click selects a row, and on
// its marker, where it is drawn, expands or collapses it; the wheel
// scrolls; a click or a drag on the scrollbar scrolls to where it is, until
// the left button is released. Returns whether the event was the pane's:
// in it, or of the left button while it holds the thumb.
handle_mouse :: proc(s: ^State, e: vt.Mouse, area: grid.Rect) -> (used: bool) {
	m := s.model
	body, bar := parts(s, area)
	left := e.button == .Left
	// a press of the left button starts afresh, also after a release lost
	if e.kind == .Press && left do s.dragging = false
	if e.kind == .Release && left && s.dragging {
		s.dragging = false
		return true
	}
	if s.dragging && e.kind == .Drag && left || grid.contains(bar, e.x, e.y) && e.kind == .Press && left {
		s.dragging = true
		s.offset = grid.scrollbar_line(bar, rows.count(m), body.height, e.y)
		settle(s, area)
		return true
	}
	if !grid.contains(area, e.x, e.y) do return false
	#partial switch e.kind {
	case .Press:
		r := s.offset + e.y - body.y
		if e.button == .Left && r < rows.count(m) {
			s.selected = r
			if row, ok := row_at(m, r); ok {
				// a marker cut off, or under the offset, is not there to click
				marker := body.x + 2 * row.depth
				text_right := body.x + text_width(s, row, body.width)
				on_marker := e.x >= marker && e.x < marker + 2 && marker + 2 < text_right
				if on_marker && !rows.collapse(m, r) do rows.expand(m, r)
			}
		}
	case .Wheel_Up:   s.offset -= 3
	case .Wheel_Down: s.offset += 3
	}
	settle(s, area)
	return true
}

// Keeps s whole for the pane, area: the selection on a row, and on screen
// when show_selection is set, and the first row on screen where the rows
// fill it.
settle :: proc(s: ^State, area: grid.Rect) {
	n := rows.count(s.model)
	body, _ := parts(s, area)
	s.selected = clamp(s.selected, 0, max(n - 1, 0))
	if s.show_selection {
		s.show_selection = false
		if s.selected < s.offset do s.offset = s.selected
		if s.selected >= s.offset + body.height do s.offset = s.selected - body.height + 1
	}
	s.offset = clamp(s.offset, 0, max(n - body.height, 0))
}

// Draws the rows of s.model in area of g, with a scrollbar when they do not
// fit, the selection in the style of a pane that has focus or not.
draw :: proc(g: ^grid.Grid, area: grid.Rect, s: ^State, focused: bool) {
	if area.width <= 0 || area.height <= 0 do return
	settle(s, area)
	body, bar := parts(s, area)
	if bar.width > 0 do grid.scrollbar(g, bar, rows.count(s.model), body.height, s.offset, ACCENT, MUTED)
	// only a scrollbar fits: no row is drawn, nor formatted
	if body.width <= 0 do return
	for r, i in rows.rows(s.model, s.offset, body.height, preview = body.width) {
		selected := s.offset + i == s.selected
		draw_row(g, {body.x, body.y + i, body.width, 1}, s, r, selected ? (focused ? SELECTED : SELECTED_UNFOCUSED) : TEXT, selected)
	}
}

// The selected row, when there are rows, its text cut at preview
// characters (rows.rows).
selected_row :: proc(s: ^State, preview := 1) -> (row: rows.Row, ok: bool) {
	return row_at(s.model, s.selected, preview)
}

// Row r, for what it is rather than its text, which is cut at preview
// characters, so that a long value is not formatted whole.
@(private)
row_at :: proc(m: ^rows.Model, r: int, preview := 1) -> (row: rows.Row, ok: bool) {
	found := rows.rows(m, r, 1, preview = preview)
	if len(found) == 0 do return {}, false
	return found[0], true
}

@(private)
is_expanded :: proc(m: ^rows.Model, r: int) -> bool {
	row, ok := row_at(m, r)
	return ok && row.expanded
}

// The columns of a line of width that row r's text takes: all of them, or
// those left of its offset, when that is shown.
@(private)
text_width :: proc(s: ^State, r: rows.Row, width: int) -> int {
	return offset_shown(s, r, width) ? width - (s.digits + 1) : width
}

// Whether row r shows its offset, in a line of width.
@(private)
offset_shown :: proc(s: ^State, r: rows.Row, width: int) -> bool {
	return s.digits > 0 && r.has_span && width >= 2 * (s.digits + 1)
}

// Draws row r in line of g: indent, marker, name, value or count, and the
// offset at the right; selected, in base, the selection's style.
@(private)
draw_row :: proc(g: ^grid.Grid, line: grid.Rect, s: ^State, r: rows.Row, base: grid.Style, selected: bool) {
	if selected do grid.fill(g, line, base)
	// when selected, the row's own styles give way to the selection's
	styled :: proc(st, base: grid.Style, selected: bool) -> grid.Style {
		return selected ? base : st
	}

	text_area := line
	if offset_shown(s, r, line.width) {
		offset_area: grid.Rect
		offset_area, text_area = grid.split_right(line, s.digits + 1)
		buf: [32]byte
		hex := hex_text(buf[:], r.span.offset, s.digits)
		grid.put(g, offset_area.x + 1, offset_area.y, hex, styled(MUTED, base, selected), offset_area.width - 1)
	}

	parts := make([dynamic]grid.Part, 0, 8, context.temp_allocator)
	for _ in 0 ..< r.depth do append(&parts, grid.Part{"  ", base})
	append(&parts, grid.Part{r.expanded ? "▾ " : r.expandable ? "▸ " : "  ", styled(ACCENT, base, selected)})
	idx: [32]byte
	if r.element {
		append(&parts, grid.Part{index_text(idx[:], r.index), styled(MUTED, base, selected)})
	} else {
		append(&parts, grid.Part{r.name, styled(r.kind == .Value ? TEXT : TITLE, base, selected)})
	}
	count: [32]byte
	switch r.kind {
	case .Value:
		append(&parts, grid.Part{" = ", styled(MUTED, base, selected)})
		append(&parts, grid.Part{r.text, base})
	case .Array:
		append(&parts, grid.Part{" ", base})
		append(&parts, grid.Part{count_text(count[:], r.count), styled(MUTED, base, selected)})
	case .Set:
	}
	grid.put_parts(g, text_area.x, text_area.y, parts[:], text_area.width)
}

// "[i]", in buf.
@(private)
index_text :: proc(buf: []byte, i: int) -> string {
	n := 0
	buf[n] = '['
	n += 1
	n += len(decimal(buf[n:], i))
	buf[n] = ']'
	return string(buf[:n + 1])
}

// "(n)", in buf.
@(private)
count_text :: proc(buf: []byte, count: int) -> string {
	n := 0
	buf[n] = '('
	n += 1
	n += len(decimal(buf[n:], count))
	buf[n] = ')'
	return string(buf[:n + 1])
}

@(private)
decimal :: proc(buf: []byte, x: int) -> string {
	tmp: [24]byte
	i := len(tmp)
	for v := x; i == len(tmp) || v > 0; v /= 10 {
		i -= 1
		tmp[i] = byte('0' + v % 10)
	}
	return string(buf[:copy(buf, tmp[i:])])
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
