// Package screen draws the viewer's whole screen for a session (view/
// session): a line with the decode's error, when it failed, the tree
// (view/outline) beside the file's bytes (view/hexdump), the selected row's
// highlighted, a status line, and the keys. Tab moves the focus between the
// panes. It draws into a hnoss buffer, so it is tested without a terminal.
package screen

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import fld "../../zelbyn/field"
import "../hexdump"
import "../hnoss/layout"
import "../hnoss/pen"
import "../hnoss/widgets"
import "../outline"
import "../rows"
import "../session"

// The screen's state, which lasts across frames.
App :: struct {
	session:   ^session.Session,
	tree:      outline.State,
	bytes:     hexdump.State,
	shown_row: int,    // the row selected in the frame before, -1 at first
	title:     string, // the file's name, as markup
	error:     string, // the decode's error, "" when it succeeded
	// where in the file the error is: its byte, or the bytes of the field
	// it was decompressed from; none when it cannot be placed
	error_at:  hexdump.Range,
	has_error: bool,
}

// Makes the screen of s. After a failed decode, the rows along the error's
// path are expanded and its deepest row selected, and the bytes start at
// the error's offset.
init :: proc(app: ^App, s: ^session.Session) {
	digits := outline.offset_digits(len(s.data))
	app^ = {
		session   = s,
		tree      = {model = &s.model, digits = digits},
		bytes     = {data = s.data, digits = digits, follow = 0},
		shown_row = -1,
	}
	// the title is markup, in which [[ is a literal [; owned either way
	title, allocated := strings.replace_all(filepath.base(s.file_path), "[", "[[")
	app.title = allocated ? title : strings.clone(title)
	app.error = session.error_text(s, context.allocator)
	if s.err.kind != .None {
		r, exact := rows.reveal(&s.model, s.err.path)
		if r >= 0 {
			app.tree.selected = r
			app.tree.show_selection = true
		}
		// the error is in the stream of its value, when it is a row, else
		// in that of the values of the deepest row of its path; an error
		// in no row, as in a param read before the root, is not placed
		stream: rows.Stream = .Unknown
		source: fld.Span
		if exact {
			if row := rows.rows(&s.model, r, 1, preview = 1); len(row) > 0 do stream, source = row[0].stream, row[0].source
		} else if r >= 0 {
			stream, source = rows.stream_within(&s.model, r)
		}
		switch stream {
		case .File:
			app.error_at, app.has_error = {s.err.offset, 1}, true
		case .Decompressed:
			app.error_at, app.has_error = {source.offset, source.size}, true
		case .Unknown:
		}
		// the selection's bytes, followed in the first frame, give way to
		// the error's
		app.shown_row = app.tree.selected
		if app.has_error do app.bytes.follow = app.error_at.offset
	}
}

destroy :: proc(app: ^App) {
	delete(app.title)
	delete(app.error)
	app^ = {}
}

// Draws the screen in area, the whole frame, and handles the panes' input,
// with the tree focused at first.
draw :: proc(ui: ^widgets.Ui, area: layout.Rect, app: ^App) {
	widgets.focus_order(ui, {&app.tree, &app.bytes})
	s := app.session
	t := ui.theme
	area := area
	if app.error != "" {
		banner := layout.cut_top(&area, 1)
		p := pen.begin(ui.buf, banner, .Ellipsis, base = hexdump.ERROR_STYLE)
		pen.write(&p, "decoding stopped: ")
		pen.write(&p, app.error)
		pen.finish(&p)
	}
	keys := layout.cut_bottom(&area, 1)
	status := layout.cut_bottom(&area, 1)

	// the bytes at 16 a line when they fit beside 30 columns of tree
	hex_width := hexdump.line_width(16, app.bytes.digits) + 3
	right := area.width >= hex_width + 30 ? layout.cut_right(&area, hex_width) : layout.cut_right(&area, area.width / 2)

	// the panes first, whose clicks move the focus, then their borders
	outline.draw(ui, layout.inset(area, 1), &app.tree)
	h, place := highlight(app)
	// a row newly selected brings its bytes on screen, even the same bytes
	// as the row before, which they are for two decompressed values
	if app.tree.selected != app.shown_row && h.has_value do app.bytes.follow = h.value.offset
	app.shown_row = app.tree.selected
	hexdump.draw(ui, layout.inset(right, 1), &app.bytes, h)
	widgets.box(ui, area, app.title, {focused = widgets.focused(ui, &app.tree)})
	widgets.box(ui, right, "bytes", {focused = widgets.focused(ui, &app.bytes)})

	path := rows.path(&s.model, app.tree.selected)
	line := fmt.tprintf("%s, %s · %s%s", filepath.base(s.file_path), byte_count(len(s.data)), path == "" ? "no rows" : path, place)
	p := pen.begin(ui.buf, status, .Ellipsis, base = t.text)
	pen.write(&p, line)
	pen.finish(&p)
	k := pen.begin(ui.buf, keys, .Ellipsis, base = t.muted)
	pen.write(&k, "↑↓ jk PgUp PgDn Home End move · → l ← h Enter expand, collapse · Tab pane · q quit")
	pen.finish(&k)
}

// What the hex pane highlights for the selected row: its bytes, shaded
// around them those of the row it is under; for a value read from
// decompressed bytes, those in the file it came from, with a note; for one
// in a stream that cannot be placed, none, with a note; and after a failed
// decode, the error's offset. And for the status line, the row's offset
// and size, in temp memory.
@(private)
highlight :: proc(app: ^App) -> (h: hexdump.Highlight, place: string) {
	s := app.session
	h.error, h.has_error = app.error_at, app.has_error
	row, ok := outline.selected_row(&app.tree)
	if !ok || !row.has_span do return
	switch row.stream {
	case .Decompressed:
		h.value = {row.source.offset, row.source.size}
		h.has_value = true
		h.note = fmt.tprintf("at 0x%X in decompressed bytes, from those highlighted", row.span.offset)
		return h, fmt.tprintf(" · 0x%X, %s, decompressed", row.span.offset, byte_count(row.span.size))
	case .Unknown:
		h.note = fmt.tprintf("at 0x%X in the stream of an io, which is not placed in the file", row.span.offset)
		return h, fmt.tprintf(" · 0x%X, %s, in another stream", row.span.offset, byte_count(row.span.size))
	case .File:
	}
	h.value = {row.span.offset, row.span.size}
	h.has_value = true
	if p := rows.parent(&s.model, app.tree.selected); p >= 0 {
		if found := rows.rows(&s.model, p, 1, preview = 1); len(found) > 0 && found[0].has_span && found[0].stream == .File {
			h.outer = {found[0].span.offset, found[0].span.size}
			h.has_outer = true
		}
	}
	return h, fmt.tprintf(" · 0x%X, %s", row.span.offset, byte_count(row.span.size))
}

// "1 byte", or "n bytes", in temp memory.
@(private)
byte_count :: proc(n: int) -> string {
	return n == 1 ? "1 byte" : fmt.tprintf("%d bytes", n)
}
