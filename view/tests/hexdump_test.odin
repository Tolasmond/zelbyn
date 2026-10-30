package tests

import "../hexdump"
import "../hnoss/buffer"
import "../hnoss/input"
import "../hnoss/widgets"
import "core:strings"
import "core:testing"

// A buffer to draw the hex pane in, with the widget memory that lasts
// across frames.
Hex_Harness :: struct {
	pane:    hexdump.State,
	buf:     buffer.Buffer,
	mem:     widgets.Memory,
	cursor:  widgets.Cursor,
	changed: bool,
}

hex_harness :: proc(h: ^Hex_Harness, data: []byte, width, height: int) {
	h.pane = {data = data, digits = 4, follow = -1}
	buffer.init(&h.buf, {0, 0, width, height})
	h.mem.focus = &h.pane
}

// Draws one frame of the pane, highlighting hl, and returns its text.
hex_frame :: proc(h: ^Hex_Harness, hl: hexdump.Highlight, events: ..input.Event) -> string {
	buffer.reset(&h.buf)
	evs := make([]input.Event, len(events), context.temp_allocator)
	copy(evs, events)
	ui := widgets.begin(&h.buf, evs, &h.mem, &h.cursor)
	h.changed = hexdump.draw(ui, h.buf.area, &h.pane, hl)
	return screen_text(&h.buf)
}

// The buffer's text, a line per row, trailing spaces trimmed.
screen_text :: proc(b: ^buffer.Buffer) -> string {
	out := strings.builder_make(context.temp_allocator)
	for y in 0 ..< b.area.height {
		line := strings.builder_make(context.temp_allocator)
		for x := 0; x < b.area.width; {
			c := buffer.get(b, x, y)
			strings.write_string(&line, buffer.cell_symbol(c))
			x += max(int(c.width), 1)
		}
		strings.write_string(&out, strings.trim_right(strings.to_string(line), " "))
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// One character per cell of row y: S for the selected value's style, O for
// the outer set's, M for a mark, . for none.
styles :: proc(b: ^buffer.Buffer, y: int) -> string {
	t := widgets.DEFAULT_THEME
	out := strings.builder_make(context.temp_allocator)
	for x in 0 ..< b.area.width {
		c := buffer.get(b, x, y)
		switch {
		case c.bg == t.selected.bg && c.bg != nil:            strings.write_byte(&out, 'S')
		case c.bg == t.selected_unfocused.bg && c.bg != nil:  strings.write_byte(&out, 'O')
		case .Underlined in c.modifiers:                      strings.write_byte(&out, 'M')
		case:                                                 strings.write_byte(&out, '.')
		}
	}
	return strings.trim_right(strings.to_string(out), ".")
}

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
	defer buffer.destroy(&h.buf)
	expect_text(t, hex_frame(&h, hl), `0000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  ................
0010  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 1d 1e 1f  Hello, world!...
0020  20 21 22 23 24 25 26 27                            !"#$%&'

`)
	// the value, joined with the set around it, in hex and as text
	testing.expect_value(t, styles(&h.buf, 0), "......OOOOOOOOOSSSSSSSSSSSOOOOOOOOOOOOOOOOOOOOOOOOOOOO..OOOSSSSOOOOOOOOO")
	testing.expect_value(t, styles(&h.buf, 1), "......OOOOOOOOOOO.......................................OOOO")
	testing.expect_value(t, styles(&h.buf, 2), "")

	narrow: Hex_Harness
	hex_harness(&narrow, data, 26, 4)
	defer buffer.destroy(&narrow.buf)
	expect_text(t, hex_frame(&narrow, hl), `0000  00 01 02 03  ....  ┃
0004  04 05 06 07  ....  │
0008  08 09 0a 0b  ....  │
000C  0c 0d 0e 0f  ....  │
`)
	testing.expect_value(t, styles(&narrow.buf, 0), "......OOOOOOOOOSS..OOOS")
	testing.expect_value(t, styles(&narrow.buf, 1), "......SSSSSSSSOOO..SSSO")
}

// A value of no bytes, of bits left over, is a mark on the byte it starts in.
@(test)
hexdump_mark :: proc(t: ^testing.T) {
	h: Hex_Harness
	hex_harness(&h, seq(16), 72, 1)
	defer buffer.destroy(&h.buf)
	_ = hex_frame(&h, {value = {5, 0}, has_value = true})
	testing.expect_value(t, styles(&h.buf, 0), strings.concatenate({strings.repeat(".", 21, context.temp_allocator), "MM", strings.repeat(".", 38, context.temp_allocator), "M"}, context.temp_allocator))
}

// Following an offset, scrolling with keys and the wheel while focused,
// keys ignored without focus, and a note at the bottom.
@(test)
hexdump_scrolling :: proc(t: ^testing.T) {
	h: Hex_Harness
	// 256 lines of 16, 8 on screen, beside a scrollbar
	hex_harness(&h, seq(4096), 73, 8)
	defer buffer.destroy(&h.buf)
	first :: proc(screen: string) -> string {
		return screen[:4]
	}
	h.pane.follow = 0x800
	testing.expect_value(t, first(hex_frame(&h, {})), "07E0") // a quarter down
	testing.expect(t, h.changed, "following is a change")
	testing.expect_value(t, h.pane.follow, -1)
	h.pane.follow = 0x810 // on screen already
	testing.expect_value(t, first(hex_frame(&h, {})), "07E0")
	testing.expect(t, !h.changed, "following an offset on screen changes nothing")

	testing.expect_value(t, first(hex_frame(&h, {}, key(.Down))), "07F0")
	testing.expect_value(t, first(hex_frame(&h, {}, key(.Page_Down))), "0860")
	testing.expect_value(t, first(hex_frame(&h, {}, key(.End), key(.Down))), "0F80")
	testing.expect_value(t, first(hex_frame(&h, {}, key(.Home), key(.Up), key(.Down))), "0010")
	testing.expect_value(t, first(hex_frame(&h, {}, wheel(5, 2, true))), "0040")
	h.mem.focus = nil
	testing.expect_value(t, first(hex_frame(&h, {}, key(.Home))), "0040")
	_ = hex_frame(&h, {}, click(5, 2)) // a click focuses it
	testing.expect_value(t, first(hex_frame(&h, {}, key(.Home))), "0000")

	noted: Hex_Harness
	hex_harness(&noted, seq(64), 73, 3)
	defer buffer.destroy(&noted.buf)
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

expect_text :: proc(t: ^testing.T, got, want: string, loc := #caller_location) {
	testing.expectf(t, got == want, "the pane shows\n%s\nwant\n%s", got, want, loc = loc)
}
