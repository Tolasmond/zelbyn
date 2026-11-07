// Package screen is the viewer's whole screen for a session (view/session):
// a line with the decode's error, when it failed, the tree (view/outline)
// beside the file's bytes (view/hexdump), the selected row's highlighted, a
// status line, and the keys. It handles an event at a time (view/vt), each
// against the state the one before left: a key goes to the pane with
// focus, which Tab moves, and a mouse event to the pane it is in, which a
// click gives focus. It draws into a grid (view/grid), so it is tested
// without a terminal, on every platform.
package screen

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import fld "../../zelbyn/field"
import "../grid"
import "../hexdump"
import "../outline"
import "../rows"
import "../session"
import "../vt"

Focus :: enum {
	Tree,
	Bytes,
}

// The screen's state.
App :: struct {
	session:   ^session.Session,
	tree:      outline.State,
	bytes:     hexdump.State,
	focus:     Focus,
	shown_row: int,    // the row whose bytes were last brought on screen, -1 at first
	title:     string, // the file's name
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
	app.title = strings.clone(filepath.base(s.file_path))
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

// Where each part of the screen is, in a grid of width × height: the
// error's line, when the decode failed; the tree's frame and the bytes'
// frame, and the panes inside them; the status line; and the keys.
Layout :: struct {
	banner:            grid.Rect,
	tree_frame, tree:  grid.Rect,
	bytes_frame, bytes: grid.Rect,
	status, keys:      grid.Rect,
}

layout :: proc(app: ^App, width, height: int) -> (l: Layout) {
	area := grid.Rect{0, 0, max(width, 0), max(height, 0)}
	if app.error != "" do l.banner, area = grid.split_top(area, 1)
	l.keys, area = grid.split_bottom(area, 1)
	l.status, area = grid.split_bottom(area, 1)
	// the bytes at 16 a line when they fit beside 30 columns of tree
	hex_width := hexdump.line_width(16, app.bytes.digits) + 3
	l.bytes_frame, l.tree_frame = grid.split_right(area, area.width >= hex_width + 30 ? hex_width : area.width / 2)
	l.tree, l.bytes = grid.inner(l.tree_frame), grid.inner(l.bytes_frame)
	return
}

// What handle tells the viewer to do.
Action :: enum {
	None,
	Quit,
}

// Handles event e on a screen of width × height: a key goes to the pane
// with focus, and Tab moves the focus; a mouse event goes to the pane it is
// in, and a click gives that pane focus; q, Esc and Ctrl+C, when the pane
// does not take them, quit. Each event is handled against the state the one
// before left, as it would be with a draw between them.
handle :: proc(app: ^App, e: vt.Event, width, height: int) -> Action {
	l := layout(app, width, height)
	// the state as a draw of the last event would have left it, on this
	// screen, which a resize may have changed
	settle(app, l)
	switch ev in e {
	case vt.Key:
		if ev.code == .Tab && (ev.mods == {} || ev.mods == {.Shift}) {
			app.focus = app.focus == .Tree ? .Bytes : .Tree
			break
		}
		used: bool
		switch app.focus {
		case .Tree:  used = outline.handle_key(&app.tree, ev, l.tree)
		case .Bytes: used = hexdump.handle_key(&app.bytes, ev, l.bytes, highlight_only(app))
		}
		if used do break
		if ev.code == .Esc && ev.mods == {} do return .Quit
		if ev.code == .Char && (ev.char == 'q' && ev.mods == {} || ev.char == 'c' && ev.mods == {.Ctrl}) do return .Quit
	case vt.Mouse:
		if ev.kind == .Press {
			if grid.contains(l.tree_frame, ev.x, ev.y) do app.focus = .Tree
			if grid.contains(l.bytes_frame, ev.x, ev.y) do app.focus = .Bytes
		}
		// a held thumb is its pane's wherever the pointer goes
		switch {
		case app.tree.dragging || !app.bytes.dragging && grid.contains(l.tree, ev.x, ev.y):
			outline.handle_mouse(&app.tree, ev, l.tree)
		case app.bytes.dragging || grid.contains(l.bytes, ev.x, ev.y):
			hexdump.handle_mouse(&app.bytes, ev, l.bytes, highlight_only(app))
		}
	case vt.Resize:
	}
	return .None
}

// Keeps the screen whole after an event, as a draw would: the panes on a
// row and a line, and a row newly selected brings its bytes on screen, even
// the same bytes as the row before, which they are for two decompressed
// values.
@(private)
settle :: proc(app: ^App, l: Layout) {
	outline.settle(&app.tree, l.tree)
	h := highlight_only(app)
	if app.tree.selected != app.shown_row && h.has_value do app.bytes.follow = h.value.offset
	app.shown_row = app.tree.selected
	hexdump.settle(&app.bytes, l.bytes, h)
}

// Draws the screen into g, the whole of it.
draw :: proc(g: ^grid.Grid, app: ^App) {
	grid.clear(g)
	s := app.session
	l := layout(app, g.width, g.height)
	settle(app, l)
	if app.error != "" do grid.put_parts(g, l.banner.x, l.banner.y, {{"decoding stopped: ", hexdump.ERROR_STYLE}, {app.error, hexdump.ERROR_STYLE}}, l.banner.width)

	h, place := highlight(app)
	outline.draw(g, l.tree, &app.tree, app.focus == .Tree)
	hexdump.draw(g, l.bytes, &app.bytes, h)
	frame(g, l.tree_frame, app.title, app.focus == .Tree)
	frame(g, l.bytes_frame, "bytes", app.focus == .Bytes)

	path := rows.path(&s.model, app.tree.selected)
	line := fmt.tprintf("%s, %s · %s%s", filepath.base(s.file_path), byte_count(len(s.data)), path == "" ? "no rows" : path, place)
	grid.put(g, l.status.x, l.status.y, line, outline.TEXT, l.status.width)
	grid.put(g, l.keys.x, l.keys.y, "↑↓ jk PgUp PgDn Home End move · → l ← h Enter expand, collapse · Tab pane · q quit", outline.MUTED, l.keys.width)
}

// A pane's frame, with its title, in the accent's style when it has focus.
@(private)
frame :: proc(g: ^grid.Grid, r: grid.Rect, title: string, focused: bool) {
	st := focused ? outline.ACCENT : outline.MUTED
	title_style := st
	title_style.attrs += {.Bold}
	grid.frame(g, r, title, st, title_style)
}

// The highlight of highlight, without the status line's place.
@(private)
highlight_only :: proc(app: ^App) -> hexdump.Highlight {
	h, _ := highlight(app)
	return h
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
