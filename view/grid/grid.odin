// Package grid is the screen the viewer draws, as a grid of cells, each a
// grapheme and its style: text put in it, cut with "…" where it does not
// fit and measured in the columns a terminal gives it; a frame; a
// scrollbar; and the escapes that turn a terminal showing one grid into one
// showing another (render). It takes no terminal, so it is tested on every
// platform (doc/arch.md §15).
package grid

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// A color of the terminal's palette, or its default.
Color :: enum u8 {
	Default,
	Black,
	Red,
	Green,
	Yellow,
	Blue,
	Magenta,
	Cyan,
	White,
	Bright_Black,
	Bright_Red,
	Bright_Green,
	Bright_Yellow,
	Bright_Blue,
	Bright_Magenta,
	Bright_Cyan,
	Bright_White,
}

Attribute :: enum u8 {
	Bold,
	Dim,
	Underlined,
	Reversed,
}

Style :: struct {
	fg, bg: Color,
	attrs:  bit_set[Attribute; u8],
}

// The bytes a cell holds its grapheme in. A longer grapheme, of many
// combining marks, is shown as U+FFFD.
CELL_BYTES :: 30

// One cell: a grapheme one or two columns wide, or, with width 0, the
// second column of the wide grapheme before it.
Cell :: struct {
	text:  [CELL_BYTES]u8,
	len:   u8,
	width: u8,
	style: Style,
}

// A cell of a space in the default style, which a grid is made of.
BLANK :: Cell{text = {0 = ' '}, len = 1, width = 1}

Grid :: struct {
	width, height: int,
	cells:         []Cell, // by line, from the top left
	allocator:     mem.Allocator,
}

// A rectangle of cells, from its top left.
Rect :: struct {
	x, y, width, height: int,
}

// Text in a style, as put_parts puts it.
Part :: struct {
	text:  string,
	style: Style,
}

// Makes g width × height cells, all BLANK, in allocator. When they cannot
// be allocated, g is as it was.
init :: proc(g: ^Grid, width, height: int, allocator := context.allocator) -> mem.Allocator_Error {
	w, h := max(width, 0), max(height, 0)
	cells := make([]Cell, w * h, allocator) or_return
	g^ = {width = w, height = h, cells = cells, allocator = allocator}
	clear(g)
	return nil
}

destroy :: proc(g: ^Grid) {
	delete(g.cells, g.allocator)
	g^ = {}
}

// Makes g width × height cells, all BLANK, keeping its cells when it is
// that size already. When the new cells cannot be allocated, g is as it
// was.
resize :: proc(g: ^Grid, width, height: int) -> mem.Allocator_Error {
	if g.width == max(width, 0) && g.height == max(height, 0) {
		clear(g)
		return nil
	}
	allocator := g.allocator
	if allocator.procedure == nil do allocator = context.allocator
	next: Grid
	init(&next, width, height, allocator) or_return
	destroy(g)
	g^ = next
	return nil
}

// Makes dst a copy of src, of its size and cells: the grid on screen, which
// the next is rendered against.
copy_from :: proc(dst, src: ^Grid) -> mem.Allocator_Error {
	if dst.width != src.width || dst.height != src.height do resize(dst, src.width, src.height) or_return
	copy(dst.cells, src.cells)
	return nil
}

// Sets every cell of g to BLANK.
clear :: proc(g: ^Grid) {
	for &c in g.cells do c = BLANK
}

// The cell at x, y, or BLANK outside g.
cell :: proc(g: ^Grid, x, y: int) -> Cell {
	if x < 0 || y < 0 || x >= g.width || y >= g.height do return BLANK
	return g.cells[y * g.width + x]
}

// A cell's grapheme; "" for the second column of a wide one.
cell_text :: proc(c: ^Cell) -> string {
	return string(c.text[:c.len])
}

// The text of line y of g, a grapheme a cell, in allocator.
line :: proc(g: ^Grid, y: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if y >= 0 && y < g.height {
		for &c in g.cells[y * g.width:][:g.width] do strings.write_string(&b, cell_text(&c))
	}
	return strings.to_string(b)
}

// Puts text in style at x, y, in at most limit columns, and returns the
// columns it took. Text that does not fit is cut, with "…" after the last
// grapheme that fits (put_parts).
put :: proc(g: ^Grid, x, y: int, text: string, style: Style, limit: int) -> (columns: int) {
	return put_parts(g, x, y, {{text, style}}, limit)
}

// Puts parts one after the other at x, y, in at most limit columns and in
// the grid, and returns the columns they took. When they do not fit, they
// are cut: "…", in the style of the part cut, follows the last grapheme
// that fits before the last column, and a space fills the column after it
// that a grapheme two columns wide left. Each grapheme takes the columns
// it is shown in (shown), so that the cells after it are where the
// terminal shows them. Each pass over the parts looks at most at
// 2 × limit + 64 graphemes, so long text costs no more than short, also
// text of graphemes of no columns, which is cut there.
put_parts :: proc(g: ^Grid, x, y: int, parts: []Part, limit: int) -> (columns: int) {
	if y < 0 || y >= g.height || x < 0 || x >= g.width do return 0
	most := min(limit, g.width - x)
	if most <= 0 do return 0
	budget := 2 * most + 64
	buf: [CELL_BYTES]u8

	fits := true
	total, looked := 0, 0
	measure: for p in parts {
		it := utf8.decode_grapheme_iterator_make(p.text)
		for text, _ in utf8.decode_grapheme_iterate(&it) {
			_, w := shown(text, &buf)
			total += w
			looked += 1
			if total > most || looked > budget {
				fits = false
				break measure
			}
		}
	}

	room := fits ? most : most - 1
	cut_style := len(parts) > 0 ? parts[0].style : Style{}
	looked = 0
	write: for p in parts {
		cut_style = p.style
		it := utf8.decode_grapheme_iterator_make(p.text)
		for text, _ in utf8.decode_grapheme_iterate(&it) {
			looked += 1
			if looked > budget do break write
			s, w := shown(text, &buf)
			if w == 0 do continue
			if columns + w > room do break write
			set(g, x + columns, y, s, w, p.style)
			columns += w
		}
	}
	if !fits {
		set(g, x + columns, y, "…", 1, cut_style)
		columns += 1
		if columns < most {
			set(g, x + columns, y, " ", 1, cut_style)
			columns += 1
		}
	}
	return
}

// Sets every cell of r, in g, to a space in style.
fill :: proc(g: ^Grid, r: Rect, style: Style) {
	c := BLANK
	c.style = style
	for y in max(r.y, 0) ..< min(r.y + r.height, g.height) {
		for x in max(r.x, 0) ..< min(r.x + r.width, g.width) {
			at := &g.cells[y * g.width + x]
			// the half of a wide grapheme left outside r is a space
			if x == r.x && at.width == 0 && x > 0 do g.cells[y * g.width + x - 1] = blank_in(g.cells[y * g.width + x - 1].style)
			if x == r.x + r.width - 1 && at.width == 2 && x + 1 < g.width do g.cells[y * g.width + x + 1] = blank_in(g.cells[y * g.width + x + 1].style)
			at^ = c
		}
	}
}

// Draws a border around r, of box-drawing characters, in style, with title
// in the top line, between spaces, all in title_style, cut to fit. A
// rectangle less than 2 cells wide or high has none.
frame :: proc(g: ^Grid, r: Rect, title: string, style, title_style: Style) {
	if r.width < 2 || r.height < 2 do return
	right, bottom := r.x + r.width - 1, r.y + r.height - 1
	for x in r.x + 1 ..< right {
		set(g, x, r.y, "─", 1, style)
		set(g, x, bottom, "─", 1, style)
	}
	for y in r.y + 1 ..< bottom {
		set(g, r.x, y, "│", 1, style)
		set(g, right, y, "│", 1, style)
	}
	set(g, r.x, r.y, "╭", 1, style)
	set(g, right, r.y, "╮", 1, style)
	set(g, r.x, bottom, "╰", 1, style)
	set(g, right, bottom, "╯", 1, style)
	if title != "" && r.width >= 5 do put_parts(g, r.x + 1, r.y, {{" ", title_style}, {title, title_style}, {" ", title_style}}, r.width - 2)
}

// Where a scrollbar of a column of height lines shows lines first to first
// + visible of total: its thumb's first line and its lines, at least one.
// The thumb fills the column when total fits in it.
thumb :: proc(height, total, visible, first: int) -> (start, size: int) {
	if height <= 0 do return 0, 0
	if total <= visible || visible <= 0 do return 0, height
	size = clamp(height * visible / total, 1, height)
	last := total - visible
	start = (height - size) * clamp(first, 0, last) / last
	// the thumb is at the top only when the first line is shown, as it is at
	// the bottom only when the last is
	if first > 0 && start == 0 && height > size do start = 1
	return
}

// Draws, in the first column of r, a scrollbar for lines first to first +
// visible of total: a thumb, a heavy line in thumb_style, on a track, a
// light one in track_style.
scrollbar :: proc(g: ^Grid, r: Rect, total, visible, first: int, thumb_style, track_style: Style) {
	if r.width <= 0 do return
	start, size := thumb(r.height, total, visible, first)
	for i in 0 ..< r.height {
		if i >= start && i < start + size {
			set(g, r.x, r.y + i, "┃", 1, thumb_style)
		} else {
			set(g, r.x, r.y + i, "│", 1, track_style)
		}
	}
}

// The first line that a click at y, on the scrollbar of r for visible of
// total lines, shows: the one that puts the thumb's middle at y.
scrollbar_line :: proc(r: Rect, total, visible, y: int) -> (first: int) {
	last := max(total - visible, 0)
	_, size := thumb(r.height, total, visible, 0)
	if r.height <= size do return 0
	at := y - r.y - size / 2
	return clamp((at * last + (r.height - size) / 2) / (r.height - size), 0, last)
}

// The first lines of r, and the rest; lines is cut to r's height.
split_top :: proc(r: Rect, lines: int) -> (top, rest: Rect) {
	n := clamp(lines, 0, r.height)
	return {r.x, r.y, r.width, n}, {r.x, r.y + n, r.width, r.height - n}
}

// The last lines of r, and the rest.
split_bottom :: proc(r: Rect, lines: int) -> (bottom, rest: Rect) {
	n := clamp(lines, 0, r.height)
	return {r.x, r.y + r.height - n, r.width, n}, {r.x, r.y, r.width, r.height - n}
}

// The last columns of r, and the rest.
split_right :: proc(r: Rect, columns: int) -> (right, rest: Rect) {
	n := clamp(columns, 0, r.width)
	return {r.x + r.width - n, r.y, n, r.height}, {r.x, r.y, r.width - n, r.height}
}

// The cells of r inside a frame drawn around it.
inner :: proc(r: Rect) -> Rect {
	return {r.x + 1, r.y + 1, max(r.width - 2, 0), max(r.height - 2, 0)}
}

contains :: proc(r: Rect, x, y: int) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// Writes to b the escapes and text that turn a terminal showing old into
// one showing new, which is the terminal's size: only the cells that
// differ, with the cursor moved to the first of each run of them and the
// style set where it changes, and at the end the default style. With old
// nil, or of another size, every cell is written. The terminal is taken to
// be in the default style at the start, as render leaves it. When b cannot
// grow, it does not hold all of it, and the error says so.
render :: proc(old, new: ^Grid, b: ^strings.Builder) -> mem.Allocator_Error {
	start := len(b.buf)
	wanted := 0 // the bytes written to b, which it holds when none failed
	full := old == nil || old.width != new.width || old.height != new.height
	current: Style
	for y in 0 ..< new.height {
		// the column the cursor is at on line y, -1 when not on it
		cursor := -1
		for x := 0; x < new.width; x += 1 {
			c := &new.cells[y * new.width + x]
			if c.width == 0 do continue // written with the grapheme before
			if !full && c^ == old.cells[y * new.width + x] {
				if c.width == 2 do x += 1
				continue
			}
			if cursor != x {
				buf: [24]byte
				emit(b, "\e[", &wanted)
				emit(b, strconv.write_int(buf[:], i64(y + 1), 10), &wanted)
				emit(b, ";", &wanted)
				emit(b, strconv.write_int(buf[:], i64(x + 1), 10), &wanted)
				emit(b, "H", &wanted)
			}
			if c.style != current {
				write_style(b, c.style, &wanted)
				current = c.style
			}
			emit(b, cell_text(c), &wanted)
			cursor = x + int(c.width)
			if c.width == 2 do x += 1
		}
	}
	if current != {} do emit(b, "\e[0m", &wanted)
	return len(b.buf) - start == wanted ? nil : .Out_Of_Memory
}

// Writes s to b, and counts its bytes in wanted, whether b took them or not.
@(private)
emit :: proc(b: ^strings.Builder, s: string, wanted: ^int) {
	strings.write_string(b, s)
	wanted^ += len(s)
}

// Writes the SGR sequence that sets style, from the default.
@(private)
write_style :: proc(b: ^strings.Builder, style: Style, wanted: ^int) {
	buf: [8]byte
	emit(b, "\e[0", wanted)
	for a in Attribute {
		if a not_in style.attrs do continue
		switch a {
		case .Bold:       emit(b, ";1", wanted)
		case .Dim:        emit(b, ";2", wanted)
		case .Underlined: emit(b, ";4", wanted)
		case .Reversed:   emit(b, ";7", wanted)
		}
	}
	if style.fg != .Default {
		emit(b, ";", wanted)
		emit(b, strconv.write_int(buf[:], i64(color_code(style.fg, 30)), 10), wanted)
	}
	if style.bg != .Default {
		emit(b, ";", wanted)
		emit(b, strconv.write_int(buf[:], i64(color_code(style.bg, 40)), 10), wanted)
	}
	emit(b, "m", wanted)
}

// The SGR code of c, a foreground's from base 30 or a background's from 40:
// base + 0–7, and the bright colors base + 60 + 0–7.
@(private)
color_code :: proc(c: Color, base: int) -> int {
	i := int(c) - int(Color.Black)
	return i < 8 ? base + i : base + 60 + i - 8
}

// How a grapheme is shown, in buf, and the columns it takes, at most 2:
// one with a control character, C0 or C1, or a byte that is not UTF-8, as
// U+FFFD, so that nothing put can move the cursor or change the terminal,
// or reach it as anything but UTF-8; one that starts with a combining
// mark, after U+25CC, so that it does not join the cell before; one too
// long for a cell as U+FFFD; and any other without U+FE0F, the selector of
// emoji presentation, which some terminals show a column wider than
// others, so that each shows it in the columns of the character it
// follows. One of no columns, as U+200B, put_parts skips.
@(private)
shown :: proc(text: string, buf: ^[CELL_BYTES]u8) -> (s: string, width: int) {
	REPLACEMENT :: "\uFFFD"
	_, _, width = utf8.grapheme_count(text)
	n := 0
	for i := 0; i < len(text); {
		r, size := utf8.decode_rune(text[i:])
		if unicode.is_control(r) || (r == utf8.RUNE_ERROR && size == 1) do return REPLACEMENT, 1
		if i == 0 && (unicode.is_gcb_extend_class(r) || unicode.is_spacing_mark(r)) {
			n = copy(buf[:], "\u25CC")
			width = max(width, 1)
		}
		if r != 0xFE0F {
			if n + size > CELL_BYTES do return REPLACEMENT, 1
			n += copy(buf[n:], text[i:][:size])
		}
		i += size
	}
	return string(buf[:n]), min(width, 2)
}

// Sets the cell at x, y to s, width columns wide, in style, and the cell
// after it, for a wide one, to its second column. The other half of a wide
// grapheme it covers half of becomes a space.
@(private)
set :: proc(g: ^Grid, x, y: int, s: string, width: int, style: Style) {
	if y < 0 || y >= g.height || x < 0 || x + width > g.width do return
	i := y * g.width + x
	if g.cells[i].width == 0 && x > 0 do g.cells[i - 1] = blank_in(g.cells[i - 1].style)
	if end := x + width; end < g.width && g.cells[y * g.width + end].width == 0 do g.cells[y * g.width + end] = blank_in(g.cells[y * g.width + end].style)
	c := Cell{width = u8(width), style = style}
	c.len = u8(copy(c.text[:], s))
	g.cells[i] = c
	if width == 2 do g.cells[i + 1] = {style = style}
}

@(private)
blank_in :: proc(style: Style) -> Cell {
	c := BLANK
	c.style = style
	return c
}
