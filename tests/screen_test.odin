package tests

import "../view/grid"
import "../view/hexdump"
import "../view/outline"
import "../view/screen"
import "../view/session"
import "../view/vt"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The viewer's whole screen (view/screen), for a session, fed events and
// drawn into a grid.

// A schema whose items are each checked, so that an input can fail part way.
@(private = "file")
CHECKED :: `meta:
  id: chk
seq:
  - id: count
    type: u1
  - id: items
    type: item
    repeat: expr
    repeat-expr: count
types:
  item:
    seq:
      - id: kind
        type: u1
        valid:
          max: 3
      - id: value
        type: u1
`

// Writes data to a new temporary file with extension ext and returns its
// path, in context.temp_allocator, or "" when it cannot.
@(private = "file")
temp_file :: proc(t: ^testing.T, ext, data: string, loc := #caller_location) -> string {
	f, err := os.create_temp_file("", fmt.tprintf("zelbyn_view_%s_*%s", loc.procedure, ext))
	if !testing.expectf(t, err == nil, "creating a temporary file: %v", err) do return ""
	path := strings.clone(os.name(f), context.temp_allocator)
	_, write_err := os.write(f, transmute([]byte)data)
	os.close(f)
	if !testing.expectf(t, write_err == nil, "writing %s: %v", path, write_err) do return ""
	return path
}

// Makes the session of args, after the program's name, hands its screen
// events, each in turn, and draws it into g, of width by height, which the
// caller destroys; returns the screen's text.
@(private = "file")
draw_screen :: proc(t: ^testing.T, s: ^session.Session, app: ^screen.App, g: ^grid.Grid, args: []string, width, height: int, events: ..vt.Event) -> (text: string, ok: bool) {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "zelbyn-view")
	append(&all, ..args)
	errs := strings.builder_make(context.temp_allocator)
	out := strings.builder_make(context.temp_allocator)
	code, made := session.make_session(s, all[:], strings.to_writer(&out), strings.to_writer(&errs))
	if !testing.expectf(t, made, "the session failed, %v: %s", code, strings.to_string(errs)) do return
	screen.init(app, s)
	grid.init(g, width, height)
	return frame_screen(g, app, ..events), true
}

// Hands the screen events, each in turn, then draws it; returns its text.
@(private = "file")
frame_screen :: proc(g: ^grid.Grid, app: ^screen.App, events: ..vt.Event) -> string {
	for e in events do screen.handle(app, e, g.width, g.height)
	screen.draw(g, app)
	return view_text(g)
}

// The cell at x, y has the error's style.
@(private = "file")
is_error_cell :: proc(g: ^grid.Grid, x, y: int) -> bool {
	return grid.cell(g, x, y).style.bg == hexdump.ERROR_STYLE.bg
}

// After a failed decode: the error on a line of its own, the tree read up
// to it, with the rows along its path expanded and its value selected,
// its byte marked in the hex pane, and the status line.
@(test)
screen_failed_decode :: proc(t: ^testing.T) {
	schema := temp_file(t, ".ksy", CHECKED)
	// the third item's kind, 9, fails its check
	data := temp_file(t, ".bin", "\x04\x01\x0a\x02\x0b\x09\x0c\x03\x0d")
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	s: session.Session
	defer session.destroy(&s)
	app: screen.App
	defer screen.destroy(&app)
	g: grid.Grid
	defer grid.destroy(&g)
	got, ok := draw_screen(t, &s, &app, &g, {schema, data}, 110, 12)
	if !ok do return
	lines := strings.split_lines(got, context.temp_allocator)
	testing.expect_value(t, lines[0], "decoding stopped: Greater_Than_Max at 0x00000005 in chk[0].items[2].kind[0]: read 9, expected at most 3")
	tree := make([dynamic]string, context.temp_allocator)
	for l in lines[2:9] do append(&tree, strings.trim_right(l[:strings.index(l, "╮╭") if strings.contains(l, "╮╭") else strings.index(l, "││")], " "))
	want := []string {
		"│▾ chk                        0000",
		"│    count = 4                0000",
		"│  ▾ items (3)                0001",
		"│    ▸ [0]                    0001",
		"│    ▸ [1]                    0003",
		"│    ▾ [2]                    0005",
		"│        kind = 9             0005",
	}
	for w, i in want do testing.expectf(t, tree[i] == w, "tree line %v: %q, want %q", i, tree[i], w)
	testing.expect_value(t, app.tree.selected, 6)
	testing.expect(t, strings.has_prefix(lines[10], "zelbyn_view_"), "the status line names the file")
	testing.expect(t, strings.contains(lines[10], ", 9 bytes · chk[0].items[2].kind[0] · 0x5, 1 byte"), "the status line gives the size, path, offset and size")

	// the error's byte, 5, marked over the selected value that failed
	testing.expectf(t, is_error_cell(&g, hex_x(110, 5), 2), "byte 5 is not marked as the error")
	testing.expect(t, !is_error_cell(&g, hex_x(110, 4), 2), "byte 4 is marked as the error")
	testing.expect_value(t, error_cells(&g, 2), 3) // its two hex digits and its text
}

// The column of byte i's hex, on the hex pane's lines of 16, in a screen
// width columns wide: past the pane's border and the offset.
@(private = "file")
hex_x :: proc(width, i: int) -> int {
	right := width - (hexdump.line_width(16, 4) + 3)
	return right + 1 + 6 + 3 * i + (i >= 8 ? 1 : 0)
}

// The cells of row y marked as the error.
@(private = "file")
error_cells :: proc(g: ^grid.Grid, y: int) -> (n: int) {
	for x in 0 ..< g.width do if is_error_cell(g, x, y) do n += 1
	return
}

// An error deep in the tree: its row selected, and on screen.
@(test)
screen_error_row_on_screen :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "meta:\n  id: many\nseq:\n")
	for i in 0 ..< 30 do fmt.sbprintf(&b, "  - id: f%d\n    type: u1\n", i)
	strings.write_string(&b, "  - id: last\n    type: u1\n    valid: 0\n")
	schema := temp_file(t, ".ksy", strings.to_string(b))
	data := temp_file(t, ".bin", strings.repeat("\x01", 31, context.temp_allocator))
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	s: session.Session
	defer session.destroy(&s)
	app: screen.App
	defer screen.destroy(&app)
	g: grid.Grid
	defer grid.destroy(&g)
	got, ok := draw_screen(t, &s, &app, &g, {schema, data}, 110, 12)
	if !ok do return
	testing.expect_value(t, app.tree.selected, 31)
	testing.expectf(t, strings.contains(got, "last = 1"), "the error's row is not on screen:\n%s", got)
}

// An error in decompressed bytes marks the bytes they came from; one in a
// param's bytes, read before the root, marks none.
@(test)
screen_error_not_in_file :: proc(t: ^testing.T) {
	zlib := temp_file(t, ".ksy", "meta:\n  id: z\nseq:\n  - id: len\n    type: u1\n  - id: body\n    type: body\n    size: len\n    process: zlib\ntypes:\n  body:\n    seq:\n      - id: a\n        type: u1\n      - id: b\n        type: u1\n        valid: 65\n")
	// "AB", compressed: b, 66, fails at its offset in them, 1 + 1
	zdata := temp_file(t, ".bin", "\x0a\x78\x9c\x73\x74\x02\x00\x00\xc6\x00\x84")
	param := temp_file(t, ".ksy", "meta:\n  id: p\n  endian: le\nparams:\n  - id: h\n    type: hdr\nseq:\n  - id: a\n    type: u1\ntypes:\n  hdr:\n    seq:\n      - id: x\n        type: u2\n")
	pdata := temp_file(t, ".bin", "\x05")
	defer for p in ([]string{zlib, zdata, param, pdata}) do if p != "" do os.remove(p)
	if zlib == "" || zdata == "" || param == "" || pdata == "" do return

	{
		s: session.Session
		defer session.destroy(&s)
		app: screen.App
		defer screen.destroy(&app)
		g: grid.Grid
		defer grid.destroy(&g)
		_, ok := draw_screen(t, &s, &app, &g, {zlib, zdata}, 110, 10)
		if !ok do return
		testing.expect_value(t, s.err.offset, 2)
		for i in 0 ..< 11 do testing.expectf(t, is_error_cell(&g, hex_x(110, i), 2) == (i >= 1), "byte %v marked %v", i, is_error_cell(&g, hex_x(110, i), 2))
	}
	{
		s: session.Session
		defer session.destroy(&s)
		app: screen.App
		defer screen.destroy(&app)
		g: grid.Grid
		defer grid.destroy(&g)
		got, ok := draw_screen(t, &s, &app, &g, {param, pdata, "--param", "h=07"}, 110, 10)
		if !ok do return
		testing.expectf(t, strings.has_prefix(got, "decoding stopped: Unexpected_EOF at 0x00000000 in h[0].x[0]"), "the error line: %q", got[:min(len(got), 80)])
		for y in 1 ..< 10 do testing.expectf(t, error_cells(&g, y) == 0, "row %v has cells marked as the error", y)
	}
}

// A decode that reaches a limit says which, and one that succeeds has no
// error line.
@(test)
screen_limit_and_success :: proc(t: ^testing.T) {
	schema := temp_file(t, ".ksy", CHECKED)
	data := temp_file(t, ".bin", "\x02\x01\x0a\x02\x0b")
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	{
		s: session.Session
		defer session.destroy(&s)
		app: screen.App
		defer screen.destroy(&app)
		g: grid.Grid
		defer grid.destroy(&g)
		got, ok := draw_screen(t, &s, &app, &g, {schema, data, "--max-steps=3"}, 200, 8)
		if !ok do return
		first := strings.split_lines(got, context.temp_allocator)[0]
		testing.expectf(t, strings.has_prefix(first, "decoding stopped: Step_Limit at") && strings.has_suffix(first, "the decode took more than 3 steps (--max-steps)"), "the error line: %q", first)
	}
	{
		s: session.Session
		defer session.destroy(&s)
		app: screen.App
		defer screen.destroy(&app)
		g: grid.Grid
		defer grid.destroy(&g)
		got, ok := draw_screen(t, &s, &app, &g, {schema, data}, 110, 8)
		if !ok do return
		testing.expectf(t, strings.has_prefix(got, "╭ zelbyn_view_"), "no error line, the tree first: %q", got[:min(len(got), 40)])
	}
}

// Tab moves the focus, which the frames show; a key goes to the pane with
// focus only; a click gives a pane focus; and q, Esc and Ctrl+C quit.
@(test)
screen_focus_and_keys :: proc(t: ^testing.T) {
	schema := temp_file(t, ".ksy", CHECKED)
	data := temp_file(t, ".bin", strings.concatenate({"\x02\x01\x0a\x02\x0b", strings.repeat("\x00", 300, context.temp_allocator)}, context.temp_allocator))
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	s: session.Session
	defer session.destroy(&s)
	app: screen.App
	defer screen.destroy(&app)
	g: grid.Grid
	defer grid.destroy(&g)
	_, ok := draw_screen(t, &s, &app, &g, {schema, data}, 110, 10)
	if !ok do return
	l := screen.layout(&app, 110, 10)
	frame_color :: proc(g: ^grid.Grid, r: grid.Rect) -> grid.Color {
		return grid.cell(g, r.x, r.y).style.fg
	}
	testing.expect_value(t, app.focus, screen.Focus.Tree)
	testing.expect_value(t, frame_color(&g, l.tree_frame), grid.Color.Cyan)
	testing.expect_value(t, frame_color(&g, l.bytes_frame), grid.Color.Bright_Black)

	_ = frame_screen(&g, &app, view_key(.Down))
	testing.expect_value(t, app.tree.selected, 1)
	testing.expect_value(t, app.bytes.line, 0)
	_ = frame_screen(&g, &app, view_key(.Tab), view_key(.Down), view_key(.Down))
	testing.expect_value(t, app.focus, screen.Focus.Bytes)
	testing.expect_value(t, app.tree.selected, 1)
	testing.expect_value(t, app.bytes.line, 2)
	testing.expect_value(t, frame_color(&g, l.tree_frame), grid.Color.Bright_Black)
	testing.expect_value(t, frame_color(&g, l.bytes_frame), grid.Color.Cyan)
	_ = frame_screen(&g, &app, view_key(.Tab, {.Shift}))
	testing.expect_value(t, app.focus, screen.Focus.Tree)
	_ = frame_screen(&g, &app, view_click(l.bytes.x + 2, l.bytes.y + 1))
	testing.expect_value(t, app.focus, screen.Focus.Bytes)
	_ = frame_screen(&g, &app, view_click(l.tree.x + 10, l.tree.y))
	testing.expect_value(t, app.focus, screen.Focus.Tree)
	testing.expect_value(t, app.tree.selected, 0)

	for e in ([]vt.Event{view_char('q'), view_key(.Esc), view_char('c', {.Ctrl})}) {
		testing.expectf(t, screen.handle(&app, e, 110, 10) == .Quit, "%v does not quit", e)
	}
	for e in ([]vt.Event{view_char('Q'), view_key(.Esc, {.Alt}), view_char('c'), vt.Resize{}}) {
		testing.expectf(t, screen.handle(&app, e, 110, 10) == .None, "%v quits", e)
	}
}

// A drag of the bytes' scrollbar that goes over the tree still scrolls the
// bytes, and leaves the tree as it was.
@(test)
screen_drag_across_panes :: proc(t: ^testing.T) {
	schema := temp_file(t, ".ksy", CHECKED)
	data := temp_file(t, ".bin", strings.concatenate({"\x02\x01\x0a\x02\x0b", strings.repeat("\x00", 300, context.temp_allocator)}, context.temp_allocator))
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	s: session.Session
	defer session.destroy(&s)
	app: screen.App
	defer screen.destroy(&app)
	g: grid.Grid
	defer grid.destroy(&g)
	_, ok := draw_screen(t, &s, &app, &g, {schema, data}, 110, 10)
	if !ok do return
	l := screen.layout(&app, 110, 10)
	bar_x := l.bytes.x + l.bytes.width - 1
	_ = frame_screen(&g, &app, view_click(bar_x, l.bytes.y), view_drag(l.tree.x + 5, l.bytes.y + l.bytes.height - 1))
	testing.expect(t, app.bytes.line > 0, "the drag over the tree does not scroll the bytes")
	testing.expect_value(t, app.tree.selected, 0)
	testing.expect_value(t, app.tree.offset, 0)
	_ = frame_screen(&g, &app, view_release(l.tree.x + 5, 0), view_click(l.tree.x + 5, l.tree.y + 1))
	testing.expect_value(t, app.tree.selected, 1)
}

// Many keys, clicks and wheel events in one read give the screen they give
// one a frame: each is handled against the state the one before left.
@(test)
screen_events_in_one_read :: proc(t: ^testing.T) {
	schema := temp_file(t, ".ksy", CHECKED)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, 40)
	for i in 0 ..< 40 do strings.write_string(&b, i % 2 == 0 ? "\x01\x05" : "\x02\x06")
	strings.write_string(&b, strings.repeat("\x00", 400, context.temp_allocator)) // bytes past the tree, for the bytes to scroll
	data := temp_file(t, ".bin", strings.to_string(b))
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	// a read of many keys and the wheel: items expanded, the selection moved
	// down it, a page and more, an item expanded and collapsed; the wheel
	// over each pane; the focus moved to the bytes and back; a click on a
	// row; and keys past the last row and back
	read := "jjljjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj\x1b[6~l\rl\x1b[A" +
		"\x1b[<65;10;5M\x1b[<65;10;5M\x1b[<64;10;5M\x1b[<65;45;5M\x1b[<65;45;5M" +
		"\t\x1b[B\x1b[B\x1b[A\t\x1b[<0;10;4M\x1b[<0;10;4mjjjjj\x1b[F\x1b[Bk\x1b[5~jj"
	d: vt.Decoder
	events := make([dynamic]vt.Event, context.temp_allocator)
	pending := vt.decode(&d, transmute([]u8)read, &events)
	testing.expect(t, !pending, "the read ends in a sequence")
	testing.expect(t, len(events) > 60, "few events decoded")

	ss: [2]session.Session
	defer for &x in ss do session.destroy(&x)
	apps: [2]screen.App
	defer for &x in apps do screen.destroy(&x)
	grids: [2]grid.Grid
	defer for &x in grids do grid.destroy(&x)
	// the bytes 4 a line: the selection's go off screen, and are followed
	_, ok0 := draw_screen(t, &ss[0], &apps[0], &grids[0], {schema, data}, 60, 14, ..events[:])
	_, ok1 := draw_screen(t, &ss[1], &apps[1], &grids[1], {schema, data}, 60, 14)
	if !ok0 || !ok1 do return
	for e in events do _ = frame_screen(&grids[1], &apps[1], e)
	testing.expect_value(t, view_text(&grids[0]), view_text(&grids[1]))
	same := true
	for c, i in grids[0].cells do if c != grids[1].cells[i] do same = false
	testing.expect(t, same, "the cells' styles differ")
	testing.expect_value(t, apps[0].tree.selected, apps[1].tree.selected)
	testing.expect_value(t, apps[0].tree.offset, apps[1].tree.offset)
	testing.expect_value(t, apps[0].bytes.line, apps[1].bytes.line)
	testing.expect_value(t, apps[0].focus, apps[1].focus)
	// the events moved the screen: the test is not of a screen left as it was
	testing.expectf(t, apps[0].tree.selected > 0 && apps[0].bytes.line > 0, "the events moved nothing: row %v, line %v\n%s", apps[0].tree.selected, apps[0].bytes.line, view_text(&grids[0]))
}

// A row newly selected brings its bytes on screen, a quarter down, also
// after keys that moved the bytes away; and the selected row is in the
// style of a pane with focus, or of one without.
@(test)
screen_bytes_follow_selection :: proc(t: ^testing.T) {
	schema := temp_file(t, ".ksy", CHECKED)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, 40)
	for _ in 0 ..< 40 do strings.write_string(&b, "\x01\x05")
	// bytes past the tree, so that its last rows' are not on the last screen
	strings.write_string(&b, strings.repeat("\x00", 200, context.temp_allocator))
	data := temp_file(t, ".bin", strings.to_string(b))
	defer for p in ([]string{schema, data}) do if p != "" do os.remove(p)
	if schema == "" || data == "" do return

	s: session.Session
	defer session.destroy(&s)
	app: screen.App
	defer screen.destroy(&app)
	g: grid.Grid
	defer grid.destroy(&g)
	// the bytes 4 a line, beside their scrollbar, 6 lines on screen
	_, ok := draw_screen(t, &s, &app, &g, {schema, data}, 60, 10)
	if !ok do return
	l := screen.layout(&app, 60, 10)
	testing.expect_value(t, hexdump.bytes_per_line(l.bytes.width - 1, app.bytes.digits), 4)
	testing.expect_value(t, l.bytes.height, 6)

	// items, expanded, and its last: at 0x4F, line 19
	_ = frame_screen(&g, &app, view_key(.Down), view_key(.Down), view_key(.Right), view_key(.End))
	testing.expect_value(t, app.tree.selected, 42)
	testing.expect_value(t, app.bytes.line, 19 - 6 / 4)
	// the bytes moved away, then a row selected: its bytes come back
	_ = frame_screen(&g, &app, view_key(.Tab), view_key(.Home), view_key(.Tab), view_key(.Up))
	testing.expect_value(t, app.bytes.line, 0x4D / 4 - 6 / 4)

	selected_style :: proc(g: ^grid.Grid, l: screen.Layout, app: ^screen.App) -> grid.Style {
		return grid.cell(g, l.tree.x, l.tree.y + app.tree.selected - app.tree.offset).style
	}
	testing.expect_value(t, selected_style(&g, l, &app), outline.SELECTED)
	_ = frame_screen(&g, &app, view_key(.Tab))
	testing.expect_value(t, selected_style(&g, l, &app), outline.SELECTED_UNFOCUSED)
}
