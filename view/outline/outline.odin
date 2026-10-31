// Package outline draws the rows of a decoded tree (view/rows) as a pane of
// hnoss widgets, and handles its keys and mouse: an outline of the tree,
// each row indented by its depth, with a marker for a set or array that can
// be expanded, its name, its value, and its offset in the file.
package outline

import "../hnoss/buffer"
import "../hnoss/layout"
import "../hnoss/pen"
import "../hnoss/style"
import "../hnoss/widgets"
import "../rows"

// The pane's state, which the caller keeps across frames. Its address is
// the pane's identity for focus.
State :: struct {
	model:    ^rows.Model,
	selected: int, // the selected row
	offset:   int, // the first row on screen
	digits:   int, // the hex digits each offset is shown with (offset_digits); 0 shows none
	// set to bring the selection on screen at the next draw, as a key that
	// moves it does, when it is set from outside
	show_selection: bool,
}

// The hex digits that show every offset of an input of size bytes, at
// least 4.
offset_digits :: proc(size: int) -> int {
	n := 4
	for x := size >> 16; x > 0; x >>= 4 do n += 1
	return n
}

// Draws the rows of s.model in area, with a scrollbar when they do not fit,
// and handles their input. While the pane has focus: ↑ ↓ (or k j), PgUp
// PgDn, Home End move the selection; → (or l) expands the selected row, or
// moves to its first row when it is expanded; ← (or h) collapses it, or
// moves to the row it is under; Enter expands or collapses it. A click
// selects a row, and on its marker expands or collapses it too; the wheel
// scrolls. The selection is kept on screen when a key moves it. Returns
// true when the selection, the rows, or the first row on screen changed.
draw :: proc(ui: ^widgets.Ui, area: layout.Rect, s: ^State) -> (changed: bool) {
	if area.width <= 0 || area.height <= 0 do return false
	m := s.model
	old_selected, old_count, old_offset := s.selected, rows.count(m), s.offset
	// the scrollbar's column, while the rows did not fit, is its own
	clicks := area
	if old_count > area.height do layout.cut_right(&clicks, 1)
	by_key := handle_keys(ui, s, area.height)
	handle_mouse(ui, s, clicks)

	// the rows may fit now, or no longer, once expanded or collapsed
	n := rows.count(m)
	body := area
	bar: layout.Rect
	if n > area.height do bar = layout.cut_right(&body, 1)
	s.selected = clamp(s.selected, 0, max(n - 1, 0))
	if by_key || s.show_selection {
		s.show_selection = false
		if s.selected < s.offset do s.offset = s.selected
		if s.selected >= s.offset + body.height do s.offset = s.selected - body.height + 1
	}
	s.offset = clamp(s.offset, 0, max(n - body.height, 0))
	if bar.width > 0 do widgets.scrollbar(ui, bar, n, body.height, &s.offset)

	// only a scrollbar fits: no row is drawn, nor formatted
	if body.width > 0 {
		for r, i in rows.rows(m, s.offset, body.height, preview = body.width) {
			draw_row(ui, {body.x, body.y + i, body.width, 1}, s, r, s.offset + i == s.selected)
		}
	}
	return s.selected != old_selected || n != old_count || s.offset != old_offset
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

// Handles the keys meant for the pane, which has height rows; returns
// whether one moved the selection.
@(private)
handle_keys :: proc(ui: ^widgets.Ui, s: ^State, height: int) -> (moved: bool) {
	m := s.model
	page := max(height - 1, 1)
	it: widgets.Key_Iter
	for k, i in widgets.next_key(ui, s, &it) {
		used := true
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
			used = false
		}
		if used {
			widgets.consume(ui, i)
			moved = true
			// each key moves from a row there is, also in one frame
			s.selected = clamp(s.selected, 0, max(rows.count(m) - 1, 0))
		}
	}
	return
}

// Handles the mouse in body, where the rows are drawn: a click selects a
// row and gives the pane focus, and on a row's marker, where it is drawn,
// expands or collapses it; the wheel scrolls.
@(private)
handle_mouse :: proc(ui: ^widgets.Ui, s: ^State, body: layout.Rect) {
	m := s.model
	it: widgets.Key_Iter
	for e, i in widgets.next_mouse(ui, nil, body, &it) {
		#partial switch e.kind {
		case .Press:
			widgets.focus(ui, s)
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
			widgets.consume(ui, i)
		case .Scroll:
			#partial switch e.button {
			case .Wheel_Up:   s.offset -= 3
			case .Wheel_Down: s.offset += 3
			}
			// each event scrolls from rows there are, also in one frame
			s.offset = clamp(s.offset, 0, max(rows.count(m) - body.height, 0))
			widgets.consume(ui, i)
		}
	}
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

// Draws row r in line: indent, marker, name, value or count, and the offset
// at the right.
@(private)
draw_row :: proc(ui: ^widgets.Ui, line: layout.Rect, s: ^State, r: rows.Row, selected: bool) {
	t := ui.theme
	base: style.Style
	if selected {
		base = widgets.focused(ui, s) ? t.selected : t.selected_unfocused
		buffer.fill(ui.buf, line, base)
	}
	// when selected, the row's own styles give way to the selection's
	styled :: proc(st: style.Style, selected: bool) -> style.Style {
		return selected ? {} : st
	}

	text_area := line
	if offset_shown(s, r, line.width) {
		offset_area := layout.cut_right(&text_area, s.digits + 1)
		buf: [32]byte
		hex := hex_text(buf[:], r.span.offset, s.digits)
		buffer.set_string(ui.buf, offset_area.x + 1, offset_area.y, hex, selected ? base : t.muted)
	}

	p := pen.begin(ui.buf, text_area, .Ellipsis, base = base)
	for _ in 0 ..< r.depth do pen.write(&p, "  ")
	pen.write(&p, r.expanded ? "▾ " : r.expandable ? "▸ " : "  ", styled(t.accent, selected))
	if r.element {
		buf: [32]byte
		pen.write(&p, index_text(buf[:], r.index), styled(t.muted, selected))
	} else {
		pen.write(&p, r.name, styled(r.kind == .Value ? t.text : t.title, selected))
	}
	switch r.kind {
	case .Value:
		pen.write(&p, " = ", styled(t.muted, selected))
		pen.write(&p, r.text)
	case .Array:
		buf: [32]byte
		pen.write(&p, " ", {})
		pen.write(&p, count_text(buf[:], r.count), styled(t.muted, selected))
	case .Set:
	}
	pen.finish(&p)
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
