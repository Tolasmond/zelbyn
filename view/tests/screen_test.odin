package tests

import "../hexdump"
import "../hnoss/buffer"
import "../hnoss/input"
import "../hnoss/widgets"
import "../screen"
import "../session"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A schema whose items are each checked, so that an input can fail part way.
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
temp_file :: proc(t: ^testing.T, ext, data: string, loc := #caller_location) -> string {
	f, err := os.create_temp_file("", fmt.tprintf("zelbyn_view_%s_*%s", loc.procedure, ext))
	if !testing.expectf(t, err == nil, "creating a temporary file: %v", err) do return ""
	path := strings.clone(os.name(f), context.temp_allocator)
	_, write_err := os.write(f, transmute([]byte)data)
	os.close(f)
	if !testing.expectf(t, write_err == nil, "writing %s: %v", path, write_err) do return ""
	return path
}

// Makes the session of args, after the program's name, and draws its
// screen into a buffer of width by height, once; returns the screen's
// text, the buffer, which the caller destroys, and the session's error.
draw_screen :: proc(t: ^testing.T, s: ^session.Session, app: ^screen.App, buf: ^buffer.Buffer, mem: ^widgets.Memory, args: []string, width, height: int, events: ..input.Event) -> (text: string, ok: bool) {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "zelbyn-view")
	append(&all, ..args)
	errs := strings.builder_make(context.temp_allocator)
	out := strings.builder_make(context.temp_allocator)
	code, made := session.make_session(s, all[:], strings.to_writer(&out), strings.to_writer(&errs))
	if !testing.expectf(t, made, "the session failed, %v: %s", code, strings.to_string(errs)) do return
	screen.init(app, s)
	buffer.init(buf, {0, 0, width, height})
	return frame_screen(buf, mem, app, ..events), true
}

frame_screen :: proc(buf: ^buffer.Buffer, mem: ^widgets.Memory, app: ^screen.App, events: ..input.Event) -> string {
	buffer.reset(buf)
	cursor: widgets.Cursor
	evs := make([]input.Event, len(events), context.temp_allocator)
	copy(evs, events)
	ui := widgets.begin(buf, evs, mem, &cursor)
	screen.draw(ui, buf.area, app)
	return screen_text(buf)
}

// The cell at x, y has the error's style.
is_error_cell :: proc(buf: ^buffer.Buffer, x, y: int) -> bool {
	return buffer.get(buf, x, y).bg == hexdump.ERROR_STYLE.bg
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
	buf: buffer.Buffer
	defer buffer.destroy(&buf)
	mem: widgets.Memory
	got, ok := draw_screen(t, &s, &app, &buf, &mem, {schema, data}, 110, 12)
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

	// the error's byte, 5, is the selected value's; selecting the one
	// before shows it marked as the error
	_ = frame_screen(&buf, &mem, &app, key(.Up))
	_ = frame_screen(&buf, &mem, &app, key(.Up))
	// the hex pane, 16 bytes a line, at the right: past its border and the
	// offset, byte 5, on its first line, under the error line and the border
	right := 110 - (hexdump.line_width(16, 4) + 3)
	hex_x := right + 1 + 6 + 3 * 5
	testing.expectf(t, is_error_cell(&buf, hex_x, 2), "byte 5 at column %v is not marked as the error", hex_x)
	testing.expect(t, !is_error_cell(&buf, hex_x - 3, 2), "byte 4 is marked as the error")
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
		buf: buffer.Buffer
		defer buffer.destroy(&buf)
		mem: widgets.Memory
		got, ok := draw_screen(t, &s, &app, &buf, &mem, {schema, data, "--max-steps=3"}, 200, 8)
		if !ok do return
		first := strings.split_lines(got, context.temp_allocator)[0]
		testing.expectf(t, strings.has_prefix(first, "decoding stopped: Step_Limit at") && strings.has_suffix(first, "the decode took more than 3 steps (--max-steps)"), "the error line: %q", first)
	}
	{
		s: session.Session
		defer session.destroy(&s)
		app: screen.App
		defer screen.destroy(&app)
		buf: buffer.Buffer
		defer buffer.destroy(&buf)
		mem: widgets.Memory
		got, ok := draw_screen(t, &s, &app, &buf, &mem, {schema, data}, 110, 8)
		if !ok do return
		testing.expectf(t, strings.has_prefix(got, "╭ zelbyn_view_"), "no error line, the tree first: %q", got[:min(len(got), 40)])
	}
}
