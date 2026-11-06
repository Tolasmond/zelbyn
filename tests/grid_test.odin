package tests

import "../view/grid"
import "core:strings"
import "core:testing"

// The lines of g, each joined to the next by a line break.
@(private = "file")
grid_text :: proc(g: ^grid.Grid) -> string {
	b := strings.builder_make(context.temp_allocator)
	for y in 0 ..< g.height {
		if y > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, grid.line(g, y))
	}
	return strings.to_string(b)
}

// What render writes to turn old into new.
@(private = "file")
rendered :: proc(old, new: ^grid.Grid) -> string {
	b := strings.builder_make(context.temp_allocator)
	grid.render(old, new, &b)
	return strings.to_string(b)
}

@(private = "file")
RED :: grid.Style{fg = .Red}
@(private = "file")
BOLD_ON_BLUE :: grid.Style{bg = .Blue, attrs = {.Bold}}

@(test)
grid_put :: proc(t: ^testing.T) {
	g: grid.Grid
	grid.init(&g, 8, 1)
	defer grid.destroy(&g)

	testing.expect_value(t, grid.put(&g, 1, 0, "abc", RED, 10), 3)
	testing.expect_value(t, grid.line(&g, 0), " abc    ")
	testing.expect_value(t, grid.cell(&g, 1, 0).style, RED)
	testing.expect_value(t, grid.cell(&g, 4, 0).style, grid.Style{})

	// cut by the limit, with "…" in its last column, and fitting exactly
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "hello", {}, 3), 3)
	testing.expect_value(t, grid.line(&g, 0), "he…     ")
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "abc", {}, 3), 3)
	testing.expect_value(t, grid.line(&g, 0), "abc     ")

	// cut by the grid's edge
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 5, 0, "abcdef", {}, 100), 3)
	testing.expect_value(t, grid.line(&g, 0), "     ab…")

	// nothing outside the grid, nor in no columns
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 8, 0, "a", {}, 5), 0)
	testing.expect_value(t, grid.put(&g, -1, 0, "a", {}, 5), 0)
	testing.expect_value(t, grid.put(&g, 0, 1, "a", {}, 5), 0)
	testing.expect_value(t, grid.put(&g, 0, 0, "a", {}, 0), 0)
	testing.expect_value(t, grid.line(&g, 0), "        ")
	testing.expect_value(t, grid.line(&g, 1), "")
}

@(test)
grid_put_parts :: proc(t: ^testing.T) {
	g: grid.Grid
	grid.init(&g, 8, 1)
	defer grid.destroy(&g)

	testing.expect_value(t, grid.put_parts(&g, 0, 0, {{"ab", RED}, {"cd", BOLD_ON_BLUE}}, 8), 4)
	testing.expect_value(t, grid.line(&g, 0), "abcd    ")
	testing.expect_value(t, grid.cell(&g, 1, 0).style, RED)
	testing.expect_value(t, grid.cell(&g, 2, 0).style, BOLD_ON_BLUE)

	// cut in the second part: "…" in its style
	grid.clear(&g)
	testing.expect_value(t, grid.put_parts(&g, 0, 0, {{"ab", RED}, {"cdef", BOLD_ON_BLUE}}, 4), 4)
	testing.expect_value(t, grid.line(&g, 0), "abc…    ")
	testing.expect_value(t, grid.cell(&g, 3, 0).style, BOLD_ON_BLUE)

	// a first part that fits exactly, before one that does not: cut in the
	// first, which shows that more follows
	grid.clear(&g)
	testing.expect_value(t, grid.put_parts(&g, 0, 0, {{"abc", RED}, {"de", BOLD_ON_BLUE}}, 3), 3)
	testing.expect_value(t, grid.line(&g, 0), "ab…     ")
	testing.expect_value(t, grid.cell(&g, 2, 0).style, RED)

	// empty parts take nothing
	grid.clear(&g)
	testing.expect_value(t, grid.put_parts(&g, 0, 0, {{"", RED}, {"x", {}}, {"", RED}}, 8), 1)
	testing.expect_value(t, grid.put_parts(&g, 0, 0, {}, 8), 0)
	testing.expect_value(t, grid.line(&g, 0), "x       ")
}

@(test)
grid_wide_graphemes :: proc(t: ^testing.T) {
	g: grid.Grid
	grid.init(&g, 6, 1)
	defer grid.destroy(&g)

	// each two columns wide: a grapheme and its second column
	testing.expect_value(t, grid.put(&g, 0, 0, "日本", {}, 6), 4)
	testing.expect_value(t, grid.line(&g, 0), "日本  ")
	testing.expect_value(t, grid.cell(&g, 0, 0).width, 2)
	testing.expect_value(t, grid.cell(&g, 1, 0).width, 0)
	testing.expect_value(t, grid.cell(&g, 4, 0).width, 1)

	// cut: "…" where the next fits no longer, and a space where half of one
	// would have been
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "日本語", {}, 5), 5)
	testing.expect_value(t, grid.line(&g, 0), "日本… ")
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "日本", {}, 3), 3)
	testing.expect_value(t, grid.line(&g, 0), "日…   ")
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "a日本", {}, 4), 4)
	testing.expect_value(t, grid.line(&g, 0), "a日…  ")
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "日本", {}, 2), 2)
	testing.expect_value(t, grid.line(&g, 0), "…     ")
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "日本", {}, 1), 1)
	testing.expect_value(t, grid.line(&g, 0), "…     ")

	// at the grid's edge, where its second column is not
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 5, 0, "日", {}, 10), 1)
	testing.expect_value(t, grid.line(&g, 0), "     …")

	// a grapheme that covers half of a wide one leaves a space of the other
	grid.clear(&g)
	grid.put(&g, 0, 0, "日本", RED, 6)
	grid.put(&g, 1, 0, "x", {}, 1)
	testing.expect_value(t, grid.line(&g, 0), " x本  ")
	testing.expect_value(t, grid.cell(&g, 0, 0).style, RED)
	grid.put(&g, 2, 0, "y", {}, 1)
	testing.expect_value(t, grid.line(&g, 0), " xy   ")
	testing.expect_value(t, grid.cell(&g, 3, 0).width, 1)
	grid.clear(&g)
	grid.put(&g, 1, 0, "日", {}, 2)
	grid.put(&g, 0, 0, "本", {}, 2)
	testing.expect_value(t, grid.line(&g, 0), "本    ")
	testing.expect_value(t, grid.cell(&g, 2, 0).width, 1)

	// two regional indicators, a flag, and an emoji sequence joined
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "\U0001F1EF\U0001F1F5\U0001F469\u200D\U0001F4BB", {}, 6), 4)
	testing.expect_value(t, grid.line(&g, 0), "\U0001F1EF\U0001F1F5\U0001F469\u200D\U0001F4BB  ")
	testing.expect_value(t, grid.cell(&g, 2, 0).width, 2)
}

@(test)
grid_graphemes_shown :: proc(t: ^testing.T) {
	g: grid.Grid
	grid.init(&g, 10, 1)
	defer grid.destroy(&g)

	// a combining mark joins the grapheme it follows, in one cell
	testing.expect_value(t, grid.put(&g, 0, 0, "e\u0301x", {}, 10), 2)
	c := grid.cell(&g, 0, 0)
	testing.expect_value(t, grid.cell_text(&c), "e\u0301")

	// one at the start joins a dotted circle, not the cell before
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 1, 0, "\u0301a", {}, 9), 2)
	c = grid.cell(&g, 1, 0)
	testing.expect_value(t, grid.cell_text(&c), "\u25CC\u0301")
	testing.expect_value(t, grid.line(&g, 0), " \u25CC\u0301a       ")

	// control characters, C0 and C1, and bytes that are not UTF-8, as
	// U+FFFD, so that nothing put reaches the terminal as an escape
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "a\tb\e[1m\u009B\xff", {}, 10), 9)
	testing.expect_value(t, grid.line(&g, 0), "a\uFFFDb\uFFFD[1m\uFFFD\uFFFD ")
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "\r\n", {}, 10), 1)
	testing.expect_value(t, grid.line(&g, 0), "\uFFFD         ")

	// a grapheme of no columns is not shown
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, "a\u200Bb", {}, 10), 2)
	testing.expect_value(t, grid.line(&g, 0), "ab        ")

	// one longer than a cell holds, as U+FFFD
	grid.clear(&g)
	long := strings.concatenate({"e", strings.repeat("\u0301", 20, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, grid.put(&g, 0, 0, long, {}, 10), 1)
	testing.expect_value(t, grid.line(&g, 0), "\uFFFD         ")

	// a long text, cut at the limit
	grid.clear(&g)
	testing.expect_value(t, grid.put(&g, 0, 0, strings.repeat("x", 1 << 20, context.temp_allocator), {}, 4), 4)
	testing.expect_value(t, grid.line(&g, 0), "xxx…      ")
}

@(test)
grid_fill_and_frame :: proc(t: ^testing.T) {
	g: grid.Grid
	grid.init(&g, 8, 4)
	defer grid.destroy(&g)

	grid.put(&g, 0, 1, "abcdefgh", {}, 8)
	grid.fill(&g, {2, 1, 3, 2}, RED)
	testing.expect_value(t, grid_text(&g), "        \nab   fgh\n        \n        ")
	testing.expect_value(t, grid.cell(&g, 2, 2).style, RED)
	testing.expect_value(t, grid.cell(&g, 5, 2).style, grid.Style{})

	// a fill over half of a wide grapheme leaves a space of the other
	grid.clear(&g)
	grid.put(&g, 0, 0, "日本語", {}, 8)
	grid.fill(&g, {1, 0, 2, 1}, RED)
	testing.expect_value(t, grid.line(&g, 0), "    語  ")

	grid.clear(&g)
	grid.frame(&g, {0, 0, 8, 4}, "ab", RED, BOLD_ON_BLUE)
	testing.expect_value(t, grid_text(&g), "┌ ab ──┐\n│      │\n│      │\n└──────┘")
	testing.expect_value(t, grid.cell(&g, 0, 0).style, RED)
	testing.expect_value(t, grid.cell(&g, 2, 0).style, BOLD_ON_BLUE)

	// a title cut to fit, and none where it does not
	grid.clear(&g)
	grid.frame(&g, {0, 0, 8, 2}, "abcdefgh", {}, {})
	testing.expect_value(t, grid_text(&g), "┌ abcd…┐\n└──────┘\n        \n        ")
	grid.clear(&g)
	grid.frame(&g, {0, 0, 4, 2}, "ab", {}, {})
	testing.expect_value(t, grid_text(&g), "┌──┐    \n└──┘    \n        \n        ")
	grid.clear(&g)
	grid.frame(&g, {0, 0, 1, 4}, "ab", {}, {})
	testing.expect_value(t, grid_text(&g), "        \n        \n        \n        ")

	testing.expect_value(t, grid.inner({0, 0, 8, 4}), grid.Rect{1, 1, 6, 2})
	testing.expect_value(t, grid.inner({0, 0, 1, 1}), grid.Rect{1, 1, 0, 0})
}

@(test)
grid_rects :: proc(t: ^testing.T) {
	r := grid.Rect{2, 3, 10, 6}
	top, rest := grid.split_top(r, 2)
	testing.expect_value(t, top, grid.Rect{2, 3, 10, 2})
	testing.expect_value(t, rest, grid.Rect{2, 5, 10, 4})
	bottom, above := grid.split_bottom(r, 1)
	testing.expect_value(t, bottom, grid.Rect{2, 8, 10, 1})
	testing.expect_value(t, above, grid.Rect{2, 3, 10, 5})
	right, left := grid.split_right(r, 4)
	testing.expect_value(t, right, grid.Rect{8, 3, 4, 6})
	testing.expect_value(t, left, grid.Rect{2, 3, 6, 6})
	// cut to what there is
	top, rest = grid.split_top(r, 10)
	testing.expect_value(t, top, r)
	testing.expect_value(t, rest, grid.Rect{2, 9, 10, 0})
	right, left = grid.split_right(r, -1)
	testing.expect_value(t, right, grid.Rect{12, 3, 0, 6})
	testing.expect_value(t, left, r)

	testing.expect(t, grid.contains(r, 2, 3))
	testing.expect(t, grid.contains(r, 11, 8))
	testing.expect(t, !grid.contains(r, 12, 8))
	testing.expect(t, !grid.contains(r, 2, 9))
	testing.expect(t, !grid.contains(r, 1, 3))
}

@(test)
grid_scrollbar :: proc(t: ^testing.T) {
	Case :: struct {
		height, total, visible, first: int,
		start, size:                   int,
	}
	cases := []Case {
		{10, 100, 10, 0, 0, 1},
		{10, 100, 10, 90, 9, 1},
		{10, 100, 10, 45, 4, 1},
		// at an end only when the line there is shown
		{10, 100, 10, 1, 1, 1},
		{10, 100, 10, 89, 8, 1},
		{10, 20, 10, 0, 0, 5},
		{10, 20, 10, 10, 5, 5},
		{10, 20, 10, 5, 2, 5},
		// past the end, as at it
		{10, 20, 10, 50, 5, 5},
		// all shown: the whole column
		{10, 5, 10, 0, 0, 10},
		{10, 10, 10, 0, 0, 10},
		{0, 100, 10, 0, 0, 0},
	}
	for c in cases {
		start, size := grid.thumb(c.height, c.total, c.visible, c.first)
		testing.expectf(t, start == c.start && size == c.size, "%v: thumb at %d, of %d", c, start, size)
	}

	g: grid.Grid
	grid.init(&g, 2, 4)
	defer grid.destroy(&g)
	grid.scrollbar(&g, {1, 0, 1, 4}, 8, 4, 4, RED)
	testing.expect_value(t, grid_text(&g), " │\n │\n █\n █")
	testing.expect_value(t, grid.cell(&g, 1, 2).style, RED)
	testing.expect_value(t, grid.cell(&g, 1, 0).style, grid.Style{fg = .Red, attrs = {.Dim}})

	// a click puts the thumb's middle where it is
	bar := grid.Rect{0, 2, 1, 10}
	testing.expect_value(t, grid.scrollbar_line(bar, 20, 10, 2), 0)
	testing.expect_value(t, grid.scrollbar_line(bar, 20, 10, 11), 10)
	testing.expect_value(t, grid.scrollbar_line(bar, 20, 10, 9), 10)
	testing.expect_value(t, grid.scrollbar_line(bar, 20, 10, 6), 4)
	testing.expect_value(t, grid.scrollbar_line(bar, 110, 10, 2), 0)
	testing.expect_value(t, grid.scrollbar_line(bar, 110, 10, 11), 100)
	testing.expect_value(t, grid.scrollbar_line(bar, 110, 10, 7), 56)
	testing.expect_value(t, grid.scrollbar_line(bar, 5, 10, 7), 0)
	testing.expect_value(t, grid.scrollbar_line(bar, 110, 10, -5), 0)
	testing.expect_value(t, grid.scrollbar_line(bar, 110, 10, 50), 100)
}

@(test)
grid_render :: proc(t: ^testing.T) {
	old, new: grid.Grid
	grid.init(&old, 4, 2)
	defer grid.destroy(&old)
	grid.init(&new, 4, 2)
	defer grid.destroy(&new)

	// with nothing before, every cell
	grid.put(&new, 0, 0, "ab", {}, 4)
	testing.expect_value(t, rendered(nil, &new), "\e[1;1Hab  \e[2;1H    ")

	// nothing changed, nothing written
	testing.expect_value(t, rendered(&new, &new), "")

	// a cell, and a run of them, each after a cursor move; the style set
	// where it changes, and the default at the end
	grid.put(&new, 3, 1, "z", {}, 1)
	testing.expect_value(t, rendered(&old, &new), "\e[1;1Hab\e[2;4Hz")
	grid.copy_from(&old, &new)
	grid.put(&new, 1, 0, "XY", RED, 2)
	grid.put(&new, 0, 1, "w", BOLD_ON_BLUE, 1)
	testing.expect_value(t, rendered(&old, &new), "\e[1;2H\e[0;31mXY\e[2;1H\e[0;1;44mw\e[0m")
	grid.copy_from(&old, &new)

	// a style back to the default
	grid.put(&new, 1, 0, "c", {}, 1)
	testing.expect_value(t, rendered(&old, &new), "\e[1;2Hc")
	grid.copy_from(&old, &new)

	// a wide grapheme: its second column not written, and the cursor past it
	grid.put(&new, 0, 1, "日x", {}, 4)
	testing.expect_value(t, rendered(&old, &new), "\e[2;1H日x")
	grid.copy_from(&old, &new)
	// a cell written over its second column: the first, now a space, too
	grid.put(&new, 1, 1, "q", {}, 1)
	testing.expect_value(t, rendered(&old, &new), "\e[2;1H q")
	grid.copy_from(&old, &new)

	// another size: every cell
	grid.resize(&new, 3, 1)
	grid.put(&new, 0, 0, "abc", {}, 3)
	testing.expect_value(t, rendered(&old, &new), "\e[1;1Habc")

	// each color and attribute
	grid.resize(&new, 1, 1)
	colors := []struct {
		style: grid.Style,
		sgr:   string,
	} {
		{{fg = .Black}, "\e[0;30m"},
		{{fg = .White}, "\e[0;37m"},
		{{fg = .Bright_Black}, "\e[0;90m"},
		{{fg = .Bright_White}, "\e[0;97m"},
		{{bg = .Black}, "\e[0;40m"},
		{{bg = .Bright_White}, "\e[0;107m"},
		{{attrs = {.Bold, .Dim, .Underlined, .Reversed}}, "\e[0;1;2;4;7m"},
		{{fg = .Yellow, bg = .Cyan, attrs = {.Underlined}}, "\e[0;4;33;46m"},
	}
	for c in colors {
		grid.put(&new, 0, 0, "a", c.style, 1)
		testing.expect_value(t, rendered(nil, &new), strings.concatenate({"\e[1;1H", c.sgr, "a\e[0m"}, context.temp_allocator))
	}
}

@(test)
grid_resize :: proc(t: ^testing.T) {
	g: grid.Grid
	grid.init(&g, 2, 2)
	defer grid.destroy(&g)
	grid.put(&g, 0, 0, "ab", RED, 2)
	grid.resize(&g, 3, 1)
	testing.expect_value(t, g.width, 3)
	testing.expect_value(t, g.height, 1)
	testing.expect_value(t, grid_text(&g), "   ")
	// the same size: cleared
	grid.put(&g, 0, 0, "ab", RED, 2)
	grid.resize(&g, 3, 1)
	testing.expect_value(t, grid_text(&g), "   ")
	testing.expect_value(t, grid.cell(&g, 0, 0), grid.BLANK)
	grid.resize(&g, 0, -1)
	testing.expect_value(t, len(g.cells), 0)
	testing.expect_value(t, grid.line(&g, 0), "")
}
