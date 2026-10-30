package tests

import fld "../../zelbyn/field"
import ksy "../../zelbyn/ksy"
import mdata "../../zelbyn/metadata"
import rdr "../../zelbyn/reader"
import "../hnoss/buffer"
import "../hnoss/input"
import "../hnoss/widgets"
import "../outline"
import "../rows"
import "core:fmt"
import "core:strings"
import "core:testing"

// A schema with what the outline shows: values, a set, an array of sets, a
// blob and a parse instance.
SCHEMA :: `meta:
  id: demo
  endian: le
seq:
  - id: magic
    contents: DEMO
  - id: header
    type: header
  - id: items
    type: item
    repeat: expr
    repeat-expr: header.count
instances:
  last:
    pos: _io.size - 1
    type: u1
types:
  header:
    seq:
      - id: version
        type: u1
      - id: count
        type: u1
  item:
    seq:
      - id: id
        type: u2
      - id: data
        size: 2
`

INPUT :: "DEMO\x01\x03\x01\x00ab\x02\x00cd\x03\x00ef"

// A decoded tree, its rows, and a buffer to draw the pane in, with the
// widget memory that lasts across frames, as hnoss's own tests make them.
Harness :: struct {
	ff:     mdata.File_Format,
	tree:   fld.Value_Tree,
	model:  rows.Model,
	pane:   outline.State,
	buf:    buffer.Buffer,
	mem:    widgets.Memory,
	cursor: widgets.Cursor,
}

harness :: proc(t: ^testing.T, h: ^Harness, width, height: int) -> bool {
	err := ksy.compile(SCHEMA, &h.ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v %s", err.kind, err.message) do return false
	_, derr := rdr.read_from_bytes(transmute([]byte)string(INPUT), &h.ff, &h.tree, spans = true)
	defer rdr.destroy_parse_error(&derr)
	if !testing.expectf(t, derr.kind == .None, "decode: %v in %s", derr.kind, derr.path) do return false
	rows.init(&h.model, &h.ff, &h.tree)
	h.pane = {model = &h.model, digits = outline.offset_digits(len(INPUT))}
	buffer.init(&h.buf, {0, 0, width, height})
	h.mem.focus = &h.pane
	return true
}

destroy :: proc(h: ^Harness) {
	buffer.destroy(&h.buf)
	rows.destroy(&h.model)
	fld.destroy_value_tree(&h.tree)
	mdata.destroy_file_format(&h.ff)
}

// Draws one frame of the pane over the whole buffer, with events, and
// returns its text, a line per row, trailing spaces trimmed.
frame :: proc(h: ^Harness, events: ..input.Event) -> string {
	buffer.reset(&h.buf)
	h.cursor = {}
	evs := make([]input.Event, len(events), context.temp_allocator)
	copy(evs, events)
	ui := widgets.begin(&h.buf, evs, &h.mem, &h.cursor)
	outline.draw(ui, h.buf.area, &h.pane)
	b := strings.builder_make(context.temp_allocator)
	for y in 0 ..< h.buf.area.height {
		line := strings.builder_make(context.temp_allocator)
		for x := 0; x < h.buf.area.width; {
			c := buffer.get(&h.buf, x, y)
			strings.write_string(&line, buffer.cell_symbol(c))
			x += max(int(c.width), 1)
		}
		strings.write_string(&b, strings.trim_right(strings.to_string(line), " "))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

key :: proc(code: input.Key_Code) -> input.Event {
	return input.Key{code = code}
}

ch :: proc(r: rune) -> input.Event {
	return input.Key{code = .Char, char = r}
}

click :: proc(x, y: int) -> input.Event {
	return input.Mouse{kind = .Press, button = .Left, x = x, y = y}
}

wheel :: proc(x, y: int, down: bool) -> input.Event {
	return input.Mouse{kind = .Scroll, button = down ? .Wheel_Down : .Wheel_Up, x = x, y = y}
}

expect_screen :: proc(t: ^testing.T, got, want: string, what: string, loc := #caller_location) {
	testing.expectf(t, got == want, "%s: the pane shows\n%s\nwant\n%s", what, got, want, loc = loc)
}

Step :: struct {
	events:   []input.Event,
	selected: int,
	offset:   int,
	want:     string,
}

run_steps :: proc(t: ^testing.T, h: ^Harness, steps: []Step, loc := #caller_location) {
	for st, i in steps {
		got := frame(h, ..st.events)
		what := fmt.tprintf("step %v", i)
		expect_screen(t, got, st.want, what, loc)
		testing.expectf(t, h.pane.selected == st.selected, "%s: row %v selected, want %v", what, h.pane.selected, st.selected, loc = loc)
		testing.expectf(t, h.pane.offset == st.offset, "%s: row %v first, want %v", what, h.pane.offset, st.offset, loc = loc)
	}
}

// Moving, expanding and collapsing with keys: into items and its first
// value, out of a value to its set, and up from a collapsed row.
@(test)
outline_keys :: proc(t: ^testing.T) {
	h: Harness
	defer destroy(&h)
	if !harness(t, &h, 48, 8) do return

	top := `▾ demo                                      0000
    magic = <4 bytes> 44 45 4d 4f           0000
  ▸ header                                  0004
  ▸ items (3)                               0006
    last = 102                              0011



`
	items := `▾ demo                                      0000
    magic = <4 bytes> 44 45 4d 4f           0000
  ▸ header                                  0004
  ▾ items (3)                               0006
    ▸ [0]                                   0006
    ▸ [1]                                   000A
    ▸ [2]                                   000E
    last = 102                              0011
`
	first := `▾ demo                                     0000┃
    magic = <4 bytes> 44 45 4d 4f          0000┃
  ▸ header                                 0004┃
  ▾ items (3)                              0006┃
    ▾ [0]                                  0006┃
        id = 1                             0006┃
        data = <2 bytes> 61 62             0008│
    ▸ [1]                                  000A│
`
	run_steps(t, &h, {
		{nil, 0, 0, top},
		{{key(.Down), key(.Down), key(.Down)}, 3, 0, top},
		{{ch('l')}, 3, 0, items},             // expands items
		{{ch('l')}, 4, 0, items},             // into its first value
		{{key(.Enter)}, 4, 0, first},         // expands it
		{{key(.Down), key(.Down)}, 6, 0, first},
		{{ch('h')}, 4, 0, first},             // from a value to its set
		{{ch('h')}, 4, 0, items},             // collapses it
		{{key(.End)}, 7, 0, items},
		{{key(.Up), key(.Left)}, 3, 0, items}, // from a collapsed set to its array
		{{key(.Home), key(.Right)}, 1, 0, items},
	})
}

// A click selects a row, and on its marker expands it; the wheel scrolls;
// keys keep the selection on screen; and without focus, keys do nothing.
@(test)
outline_mouse_scroll_focus :: proc(t: ^testing.T) {
	h: Harness
	defer destroy(&h)
	if !harness(t, &h, 48, 4) do return

	top := `▾ demo                                     0000┃
    magic = <4 bytes> 44 45 4d 4f          0000┃
  ▸ header                                 0004┃
  ▸ items (3)                              0006│
`
	expanded := `▾ demo                                     0000┃
    magic = <4 bytes> 44 45 4d 4f          0000┃
  ▸ header                                 0004│
  ▾ items (3)                              0006│
`
	end := `    ▸ [0]                                  0006│
    ▸ [1]                                  000A│
    ▸ [2]                                  000E┃
    last = 102                             0011┃
`
	run_steps(t, &h, {
		{nil, 0, 0, top},
		{{click(10, 3)}, 3, 0, top},
		{{click(2, 3)}, 3, 0, expanded}, // on its marker
		{{wheel(5, 1, true)}, 3, 3, `  ▾ items (3)                              0006│
    ▸ [0]                                  0006│
    ▸ [1]                                  000A┃
    ▸ [2]                                  000E┃
`},
		{{wheel(5, 1, false)}, 3, 0, expanded},
		{{key(.End)}, 7, 4, end},
		{{key(.Page_Up)}, 4, 4, end},
	})
	h.mem.focus = nil
	run_steps(t, &h, {{{key(.Home)}, 4, 4, end}})
}
