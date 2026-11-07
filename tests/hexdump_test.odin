package tests

import "../view/grid"
import "../view/hexdump"
import "../view/outline"
import "../view/vt"
import "core:strings"
import "core:testing"

// The viewer's hex pane (view/hexdump), fed events and drawn into a grid.

// The pane's state, and a grid to draw it in.
@(private = "file")
Hex_Harness :: struct {
	pane: hexdump.State,
	g:    grid.Grid,
}

@(private = "file")
hex_harness :: proc(h: ^Hex_Harness, data: []byte, width, height: int) {
	h.pane = {data = data, digits = 4, follow = -1}
	grid.init(&h.g, width, height)
}

// Hands the pane events, each in turn, then draws it over the whole grid,
// highlighting hl, and returns its text.
@(private = "file")
hex_frame :: proc(h: ^Hex_Harness, hl: hexdump.Highlight, events: ..vt.Event) -> string {
	area := grid.Rect{0, 0, h.g.width, h.g.height}
	for e in events {
		#partial switch ev in e {
		case vt.Key:   hexdump.handle_key(&h.pane, ev, area, hl)
		case vt.Mouse: hexdump.handle_mouse(&h.pane, ev, area, hl)
		}
	}
	grid.clear(&h.g)
	hexdump.draw(&h.g, area, &h.pane, hl)
	return view_text(&h.g)
}

// One character per cell of row y: S for the selected value's style, O for
// the outer set's, M for a mark, . for none.
@(private = "file")
styles :: proc(g: ^grid.Grid, y: int) -> string {
	out := strings.builder_make(context.temp_allocator)
	for x in 0 ..< g.width {
		c := grid.cell(g, x, y)
		switch {
		case c.style.bg == outline.SELECTED.bg:           strings.write_byte(&out, 'S')
		case c.style.bg == outline.SELECTED_UNFOCUSED.bg: strings.write_byte(&out, 'O')
		case .Underlined in c.style.attrs:                strings.write_byte(&out, 'M')
		case:                                             strings.write_byte(&out, '.')
		}
	}
	return strings.trim_right(strings.to_string(out), ".")
}

@(private = "file")
seq :: proc(n: int) -> []byte {
	data := make([]byte, n, context.temp_allocator)
	for i in 0 ..< n do data[i] = byte(i)
	return data
}

// 40 bytes, 16 of them text, with a value of 4 bytes highlighted in a set
// of 20, at 16 bytes a line and at 4.
@(test)
hexdump_lines_and_highlights :: proc(t: ^testing.T) {
	data := seq(40)
	copy(data[16:], "Hello, world!")
	hl := hexdump.Highlight{value = {3, 4}, has_value = true, outer = {0, 20}, has_outer = true}

	h: Hex_Harness
	hex_harness(&h, data, 72, 4)
	defer grid.destroy(&h.g)
	expect_text(t, hex_frame(&h, hl), `0000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  ................
0010  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 1d 1e 1f  Hello, world!...
0020  20 21 22 23 24 25 26 27                            !"#$%&'

`)
	// the value, joined with the set around it, in hex and as text
	testing.expect_value(t, styles(&h.g, 0), "......OOOOOOOOOSSSSSSSSSSSOOOOOOOOOOOOOOOOOOOOOOOOOOOO..OOOSSSSOOOOOOOOO")
	testing.expect_value(t, styles(&h.g, 1), "......OOOOOOOOOOO.......................................OOOO")
	testing.expect_value(t, styles(&h.g, 2), "")

	narrow: Hex_Harness
	hex_harness(&narrow, data, 26, 4)
	defer grid.destroy(&narrow.g)
	expect_text(t, hex_frame(&narrow, hl), `0000  00 01 02 03  ....  ┃
0004  04 05 06 07  ....  │
0008  08 09 0a 0b  ....  │
000C  0c 0d 0e 0f  ....  │
`)
	testing.expect_value(t, styles(&narrow.g, 0), "......OOOOOOOOOSS..OOOS")
	testing.expect_value(t, styles(&narrow.g, 1), "......SSSSSSSSOOO..SSSO")
}

// A value of no bytes, of bits left over, is a mark on the byte it starts in.
@(test)
hexdump_mark :: proc(t: ^testing.T) {
	h: Hex_Harness
	hex_harness(&h, seq(16), 72, 1)
	defer grid.destroy(&h.g)
	_ = hex_frame(&h, {value = {5, 0}, has_value = true})
	testing.expect_value(t, styles(&h.g, 0), strings.concatenate({strings.repeat(".", 21, context.temp_allocator), "MM", strings.repeat(".", 38, context.temp_allocator), "M"}, context.temp_allocator))

	// at the end of the data, where the next byte would be: on a line of
	// its own after a full one, and in data with no bytes
	end: Hex_Harness
	hex_harness(&end, seq(16), 72, 3)
	defer grid.destroy(&end.g)
	expect_text(t, hex_frame(&end, {value = {16, 0}, has_value = true}), `0000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  ................
0010

`)
	testing.expect_value(t, styles(&end.g, 1), strings.concatenate({"......MM", strings.repeat(".", 48, context.temp_allocator), "M"}, context.temp_allocator))
	_ = hex_frame(&end, {value = {12, 0}, has_value = true})
	testing.expect_value(t, styles(&end.g, 1), "") // no line for it when it is not at the end

	empty: Hex_Harness
	hex_harness(&empty, nil, 72, 2)
	defer grid.destroy(&empty.g)
	expect_text(t, hex_frame(&empty, {value = {0, 0}, has_value = true}), "0000\n\n")
	testing.expect_value(t, styles(&empty.g, 0), strings.concatenate({"......MM", strings.repeat(".", 48, context.temp_allocator), "M"}, context.temp_allocator))
	expect_text(t, hex_frame(&empty, {}), "\n\n")
}

// Following an offset, scrolling with keys, the wheel and the scrollbar,
// and a note at the bottom.
@(test)
hexdump_scrolling :: proc(t: ^testing.T) {
	h: Hex_Harness
	// 256 lines of 16, 8 on screen, beside a scrollbar
	hex_harness(&h, seq(4096), 73, 8)
	defer grid.destroy(&h.g)
	first :: proc(screen: string) -> string {
		return screen[:4]
	}
	h.pane.follow = 0x800
	testing.expect_value(t, first(hex_frame(&h, {})), "07E0") // a quarter down
	testing.expect_value(t, h.pane.follow, -1)
	h.pane.follow = 0x810 // on screen already
	testing.expect_value(t, first(hex_frame(&h, {})), "07E0")
	// an offset followed before a key, as a draw between them would
	h.pane.follow = 0x200
	testing.expect_value(t, first(hex_frame(&h, {}, view_key(.Down))), "01F0")
	// and before the wheel
	h.pane.follow = 0x400
	testing.expect_value(t, first(hex_frame(&h, {}, view_wheel(5, 2, true))), "0410")
	// the wheel outside the pane is not the pane's
	testing.expect(t, !hexdump.handle_mouse(&h.pane, vt.Mouse{kind = .Wheel_Down, x = 80, y = 2}, {0, 0, 73, 8}, {}), "a wheel outside the pane is the pane's")
	h.pane.follow = 0x800
	testing.expect_value(t, first(hex_frame(&h, {})), "07E0")

	testing.expect_value(t, first(hex_frame(&h, {}, view_key(.Down))), "07F0")
	testing.expect_value(t, first(hex_frame(&h, {}, view_key(.Page_Down))), "0860")
	testing.expect_value(t, first(hex_frame(&h, {}, view_key(.End), view_key(.Down))), "0F80")
	testing.expect_value(t, first(hex_frame(&h, {}, view_key(.Home), view_key(.Up), view_key(.Down))), "0010")
	testing.expect_value(t, first(hex_frame(&h, {}, view_wheel(5, 2, true))), "0040")
	// the scrollbar: a click at its bottom, then a drag of it to the top
	testing.expect_value(t, first(hex_frame(&h, {}, view_click(72, 7))), "0F80")
	testing.expect_value(t, first(hex_frame(&h, {}, view_drag(10, 0), view_release(10, 0))), "0000")
	testing.expect_value(t, first(hex_frame(&h, {}, view_drag(72, 7))), "0000") // released
	// a release lost: the next press of the left button lets go of the thumb
	testing.expect_value(t, first(hex_frame(&h, {}, view_click(72, 7))), "0F80")
	testing.expect_value(t, first(hex_frame(&h, {}, view_click(10, 2), view_drag(10, 0))), "0F80")
	testing.expect_value(t, first(hex_frame(&h, {}, view_key(.Home))), "0000")

	noted: Hex_Harness
	hex_harness(&noted, seq(64), 73, 3)
	defer grid.destroy(&noted.g)
	expect_text(t, hex_frame(&noted, {note = "a note"}), `0000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  ................┃
0010  10 11 12 13 14 15 16 17  18 19 1a 1b 1c 1d 1e 1f  ................│
a note
`)
}

// The bytes a line shows at each width, at the width each takes.
@(test)
hexdump_bytes_per_line :: proc(t: ^testing.T) {
	for c in ([?][2]int{{72, 16}, {71, 8}, {39, 8}, {38, 4}, {23, 4}, {22, 2}, {15, 2}, {14, 1}, {11, 1}, {3, 1}}) {
		testing.expectf(t, hexdump.bytes_per_line(c[0], 4) == c[1], "%v columns: %v a line, want %v", c[0], hexdump.bytes_per_line(c[0], 4), c[1])
	}
	for n in ([?]int{1, 2, 4, 8, 16}) do testing.expect_value(t, hexdump.bytes_per_line(hexdump.line_width(n, 4), 4), n)
}

@(private = "file")
expect_text :: proc(t: ^testing.T, got, want: string, loc := #caller_location) {
	testing.expectf(t, got == want, "the pane shows\n%s\nwant\n%s", got, want, loc = loc)
}
