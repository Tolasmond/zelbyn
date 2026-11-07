package tests

import "../view/grid"
import "../view/outline"
import "../view/rows"
import "../view/vt"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// The viewer's tree pane (view/outline), fed events and drawn into a grid.

// A schema with what the outline shows: values, a set, an array of sets, a
// blob and a parse instance.
@(private = "file")
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

@(private = "file")
INPUT :: "DEMO\x01\x03\x01\x00ab\x02\x00cd\x03\x00ef"

// A decoded tree, its rows, the pane's state, and a grid to draw it in.
@(private = "file")
Harness :: struct {
	ff:    mdata.File_Format,
	tree:  fld.Value_Tree,
	model: rows.Model,
	pane:  outline.State,
	g:     grid.Grid,
}

@(private = "file")
harness :: proc(t: ^testing.T, h: ^Harness, width, height: int, schema := SCHEMA, input := INPUT) -> bool {
	err := ksy.compile(schema, &h.ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v %s", err.kind, err.message) do return false
	_, derr := rdr.read_from_bytes(transmute([]byte)input, &h.ff, &h.tree, spans = true)
	defer rdr.destroy_parse_error(&derr)
	if !testing.expectf(t, derr.kind == .None, "decode: %v in %s", derr.kind, derr.path) do return false
	rows.init(&h.model, &h.ff, &h.tree)
	h.pane = {model = &h.model, digits = outline.offset_digits(len(input))}
	grid.init(&h.g, width, height)
	return true
}

@(private = "file")
destroy :: proc(h: ^Harness) {
	grid.destroy(&h.g)
	rows.destroy(&h.model)
	fld.destroy_value_tree(&h.tree)
	mdata.destroy_file_format(&h.ff)
}

// Hands the pane events, each in turn, then draws it over the whole grid,
// and returns its text.
@(private = "file")
frame :: proc(h: ^Harness, events: ..vt.Event) -> string {
	area := grid.Rect{0, 0, h.g.width, h.g.height}
	for e in events {
		#partial switch ev in e {
		case vt.Key:   outline.handle_key(&h.pane, ev, area)
		case vt.Mouse: outline.handle_mouse(&h.pane, ev, area)
		}
	}
	grid.clear(&h.g)
	outline.draw(&h.g, area, &h.pane, true)
	return view_text(&h.g)
}

@(private = "file")
expect_screen :: proc(t: ^testing.T, got, want: string, what: string, loc := #caller_location) {
	testing.expectf(t, got == want, "%s: the pane shows\n%s\nwant\n%s", what, got, want, loc = loc)
}

@(private = "file")
Step :: struct {
	events:   []vt.Event,
	selected: int,
	offset:   int,
	want:     string,
}

@(private = "file")
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
		{{view_key(.Down), view_key(.Down), view_key(.Down)}, 3, 0, top},
		{{view_char('l')}, 3, 0, items},             // expands items
		{{view_char('l')}, 4, 0, items},             // into its first value
		{{view_key(.Enter)}, 4, 0, first},         // expands it
		{{view_key(.Down), view_key(.Down)}, 6, 0, first},
		{{view_char('h')}, 4, 0, first},             // from a value to its set
		{{view_char('h')}, 4, 0, items},             // collapses it
		{{view_key(.End)}, 7, 0, items},
		{{view_key(.Up), view_key(.Left)}, 3, 0, items}, // from a collapsed set to its array
		{{view_key(.Home), view_key(.Right)}, 1, 0, items},
	})
}

// A click selects a row, and on its marker expands it; the wheel scrolls;
// and keys keep the selection on screen.
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
		{{view_click(10, 3)}, 3, 0, top},
		{{view_click(2, 3)}, 3, 0, expanded}, // on its marker
		// rows 3 to 6 of 8: the thumb is at the bottom only when the last is shown
		{{view_wheel(5, 1, true)}, 3, 3, `  ▾ items (3)                              0006│
    ▸ [0]                                  0006┃
    ▸ [1]                                  000A┃
    ▸ [2]                                  000E│
`},
		{{view_wheel(5, 1, false)}, 3, 0, expanded},
		{{view_key(.End)}, 7, 4, end},
		{{view_key(.Page_Up)}, 4, 4, end},
	})
}

// Several events before a draw, each from where the one before left the
// pane: keys and the wheel past the first and last rows, then a move or a
// click, which lands where it would in a frame of its own.
@(test)
outline_events_in_one_frame :: proc(t: ^testing.T) {
	h: Harness
	defer destroy(&h)
	if !harness(t, &h, 48, 4) do return
	_ = frame(&h, view_key(.Up), view_key(.Down))
	testing.expect_value(t, h.pane.selected, 1)
	_ = frame(&h, view_key(.End), view_key(.Down), view_key(.Up))
	testing.expect_value(t, h.pane.selected, 3)
	_ = frame(&h, view_key(.Home), view_key(.Page_Up), view_key(.Down))
	testing.expect_value(t, h.pane.selected, 1)

	_ = frame(&h, view_key(.Home), view_key(.Right)) // root already expanded: into it
	_ = frame(&h, view_wheel(5, 1, false), view_click(10, 3))
	testing.expect_value(t, h.pane.offset, 0)
	testing.expect_value(t, h.pane.selected, 3)

	_ = frame(&h, view_click(2, 3)) // expands items: 8 rows, 4 on screen
	_ = frame(&h, view_wheel(5, 1, true), view_wheel(5, 1, true), view_click(10, 0))
	testing.expect_value(t, h.pane.offset, 4)
	testing.expect_value(t, h.pane.selected, 4)
	_ = frame(&h, view_wheel(5, 1, false))
	testing.expect_value(t, h.pane.offset, 1)
	_ = frame(&h)
	testing.expect_value(t, h.pane.offset, 1)
}

// A marker cut off by the offset column is not there to click.
@(test)
outline_hidden_marker :: proc(t: ^testing.T) {
	h: Harness
	defer destroy(&h)
	// 10 columns: 5 of text, then the offset's space and 4 digits
	if !harness(t, &h, 10, 9) do return
	_ = frame(&h, view_click(2, 3)) // items, at depth 1, whose marker shows
	testing.expect_value(t, rows.count(&h.model), 8)
	before := frame(&h)
	// [0], at depth 2: its marker would be at columns 4 and 5, under the
	// offset column's space
	_ = frame(&h, view_click(5, 4))
	testing.expect_value(t, h.pane.selected, 4)
	testing.expect_value(t, rows.count(&h.model), 8)
	expect_screen(t, frame(&h), before, "after a click on the offset column")
}

// A value of a megabyte is formatted only as far as it shows, also for a
// click or a key that only needs to know what its row is, and not at all
// when the pane is as narrow as its scrollbar.
@(test)
outline_long_value :: proc(t: ^testing.T) {
	N :: 1 << 20
	long := strings.repeat("x", N + 1)
	defer delete(long)
	schema := "meta:\n  id: long\nseq:\n  - id: n\n    type: u1\n  - id: s\n    type: str\n    size-eos: true\n    encoding: ASCII\n"
	for c in ([?]struct {
			width, height: int,
			events:        []vt.Event,
		}{{48, 4, {view_click(10, 2)}}, {48, 4, {view_key(.Down), view_key(.Down), view_key(.Right), view_key(.Enter)}}, {1, 1, {view_key(.End)}}}) {
		h: Harness
		defer destroy(&h)
		if !harness(t, &h, c.width, c.height, schema, long) do return
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.temp_allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.temp_allocator = mem.tracking_allocator(&track)
			_ = frame(&h, ..c.events)
		}
		testing.expectf(t, track.total_memory_allocated < N / 16, "%vx%v, %v events: %v bytes allocated", c.width, c.height, len(c.events), track.total_memory_allocated)
	}
}

// A click on the scrollbar, and a drag of it, also past the pane, scroll to
// where it is; the release ends the drag.
@(test)
outline_scrollbar :: proc(t: ^testing.T) {
	h: Harness
	defer destroy(&h)
	if !harness(t, &h, 48, 4) do return
	_ = frame(&h, view_click(2, 3)) // expands items: 8 rows, 4 on screen
	bar := grid.Rect{47, 0, 1, 4}
	_ = frame(&h, view_click(47, 3))
	testing.expect_value(t, h.pane.offset, grid.scrollbar_line(bar, 8, 4, 3))
	testing.expect(t, h.pane.offset > 0, "a click at the bar's bottom scrolls")
	_ = frame(&h, view_drag(20, 0))
	testing.expect_value(t, h.pane.offset, 0)
	_ = frame(&h, view_drag(20, 9), view_release(20, 9))
	testing.expect_value(t, h.pane.offset, 4)
	// released: a drag no longer scrolls, nor is the pane's out of it
	testing.expect(t, !outline.handle_mouse(&h.pane, vt.Mouse{kind = .Drag, button = .Left, x = 60, y = 0}, {0, 0, 48, 4}), "a drag outside, after the release, is the pane's")
	testing.expect_value(t, h.pane.offset, 4)
	testing.expect_value(t, h.pane.selected, 3)
}
