package tests

import dmp "../zelbyn/dump"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "../view/rows"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

// After every decode of the tests (decode_bytes and decode_file), checks
// that the viewer's rows of its tree, every one expanded, give the text
// dump line for line, with offsets when the tree has spans: each row of a
// value is a line, its path made of the rows above it. A difference is
// logged as an error, which fails the test. Nothing of it is in the test's
// allocators, which the memory tests check.
check_rows :: proc(ff: ^mdata.File_Format, tree: ^fld.Value_Tree) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("check_rows: no memory")
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator

	want := strings.builder_make()
	_ = dmp.write_text(strings.to_writer(&want), ff, tree, offsets = tree.spans)

	m: rows.Model
	rows.init(&m, ff, tree)
	rows.expand_all(&m)
	got := rows_as_dump(rows.rows(&m, 0, rows.count(&m)))
	if got != strings.to_string(want) {
		log.errorf("%s: the rows, all expanded, give\n%s\nnot the dump\n%s", ff.name, got, strings.to_string(want))
	}
}

// The lines of the text dump that rs give: one for each value, its path
// made of the rows above it, as the dump makes it, and its offset when it
// has a span.
@(private = "file")
rows_as_dump :: proc(rs: []rows.Row) -> string {
	b := strings.builder_make()
	segments := make([dynamic]string)
	for r in rs {
		resize(&segments, r.depth + 1)
		// an array's own row adds nothing: its values are name[i]
		segments[r.depth] = r.kind == .Array ? "" : fmt.tprintf("%s[%d]", r.name, r.index)
		if r.kind != .Value do continue
		first := true
		for s in segments {
			if s == "" do continue
			if !first do strings.write_byte(&b, '.')
			strings.write_string(&b, s)
			first = false
		}
		fmt.sbprintf(&b, " = %s", r.text)
		if r.has_span do fmt.sbprintf(&b, " @0x%X", r.span.offset)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// One line for each row: its depth as indent, a marker (+ collapsed, -
// expanded, . neither), its name with [index] for an element, and its text
// or its count.
@(private = "file")
outline :: proc(rs: []rows.Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rs {
		for _ in 0 ..< r.depth do strings.write_string(&b, "  ")
		strings.write_string(&b, r.expanded ? "- " : r.expandable ? "+ " : ". ")
		strings.write_string(&b, r.name)
		if r.element do fmt.sbprintf(&b, "[%d]", r.index)
		switch r.kind {
		case .Value:
			fmt.sbprintf(&b, " = %s", r.text)
		case .Array:
			fmt.sbprintf(&b, " (%d)", r.count)
		case .Set:
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// The rows of SAMPLE_KSY's tree as they are expanded and collapsed, and
// moving between them: parent, next and previous sibling.
@(test)
rows_sample :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return
	data := sample_input(4)
	defer delete(data)
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, data[:], &d, spans = true)
	if !testing.expect_value(t, d.err.kind, nil) do return

	m: rows.Model
	rows.init(&m, &ff, &d.tree)
	defer rows.destroy(&m)

	expect_outline :: proc(t: ^testing.T, m: ^rows.Model, want: string, loc := #caller_location) {
		got := outline(rows.rows(m, 0, rows.count(m)))
		testing.expectf(t, got == want, "rows\n%s\nwant\n%s", got, want, loc = loc)
	}
	expect_outline(t, &m, `- sample
  . magic = <4 bytes> 53 4d 50 4c
  . name = "sample"
  . num_colors = 3
  + colors (3)
  + records (4)
  . last = 51
`)

	testing.expect(t, rows.expand(&m, 5), "expanding records")
	testing.expect(t, !rows.expand(&m, 5), "expanding records again")
	testing.expect(t, !rows.expand(&m, 1), "expanding magic")
	testing.expect(t, rows.expand(&m, 7), "expanding records[1]")
	expect_outline(t, &m, `- sample
  . magic = <4 bytes> 53 4d 50 4c
  . name = "sample"
  . num_colors = 3
  + colors (3)
  - records (4)
    + records[0]
    - records[1]
      . kind = 2
      . len = 3
      + body
    + records[2]
    + records[3]
  . last = 51
`)

	testing.expect_value(t, rows.parent(&m, 0), -1)
	testing.expect_value(t, rows.parent(&m, 5), 0)
	testing.expect_value(t, rows.parent(&m, 8), 7)
	testing.expect_value(t, rows.parent(&m, 11), 5)
	testing.expect_value(t, rows.next_sibling(&m, 5), 13) // past the rows under records
	testing.expect_value(t, rows.next_sibling(&m, 7), 11) // past those under records[1]
	testing.expect_value(t, rows.next_sibling(&m, 12), -1)
	testing.expect_value(t, rows.next_sibling(&m, 13), -1)
	testing.expect_value(t, rows.prev_sibling(&m, 13), 5)
	testing.expect_value(t, rows.prev_sibling(&m, 11), 7)
	testing.expect_value(t, rows.prev_sibling(&m, 7), 6)
	testing.expect_value(t, rows.prev_sibling(&m, 6), -1)
	testing.expect_value(t, rows.prev_sibling(&m, 10), 9)

	// a window, the span of an array and of a set, and the text of a string
	// cut short
	window := rows.rows(&m, 5, 3, preview = 3)
	if testing.expect_value(t, len(window), 3) {
		testing.expect_value(t, window[0].span, fld.Span{21, 30})
		testing.expect_value(t, window[2].span, fld.Span{31, 5})
	}
	window = rows.rows(&m, 2, 1, preview = 3)
	if testing.expect_value(t, len(window), 1) do testing.expect_value(t, window[0].text, `"sam" ...`)
	testing.expect_value(t, len(rows.rows(&m, 13, 10)), 1)
	testing.expect_value(t, len(rows.rows(&m, 14, 10)), 0)

	testing.expect(t, rows.collapse(&m, 5), "collapsing records")
	testing.expect(t, !rows.collapse(&m, 5), "collapsing records again")
	testing.expect(t, rows.expand(&m, 5), "expanding records again, after collapsing it")
	// collapsing forgets which rows under it were expanded
	testing.expect_value(t, rows.count(&m), 11)
	testing.expect(t, rows.collapse(&m, 0), "collapsing the root")
	testing.expect_value(t, rows.count(&m), 1)
}

// An array of a million values, scalars and sets: a window at its start,
// middle and end formats only the window's values, and finds them in steps
// that do not grow with the array, as do expanding, collapsing and moving.
@(test)
rows_million :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	N :: 1_000_000
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile("meta:\n  id: m\nseq:\n  - id: n\n    type: u4le\n  - id: bytes\n    type: u1\n    repeat: expr\n    repeat-expr: n\n  - id: pairs\n    type: pair\n    repeat: expr\n    repeat-expr: n / 2\ntypes:\n  pair:\n    seq:\n      - id: a\n        type: u1\n      - id: b\n        type: u1\n", &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %s", err.message) do return

	data := make([]byte, 4 + 2 * N)
	defer delete(data)
	n := u32(N)
	data[0], data[1], data[2], data[3] = byte(n), byte(n >> 8), byte(n >> 16), byte(n >> 24)
	for i in 4 ..< len(data) do data[i] = byte(i)
	d: Decoded
	defer destroy_decoded(&d)
	// not decode_bytes, whose check_rows would expand every one of its rows
	d.consumed, d.err = rdr.read_from_bytes(data, &ff, &d.tree)
	if !testing.expect_value(t, d.err.kind, nil) do return

	m: rows.Model
	rows.init(&m, &ff, &d.tree)
	defer rows.destroy(&m)
	testing.expect_value(t, rows.count(&m), 4)
	testing.expect(t, rows.expand(&m, 2), "expanding bytes")
	testing.expect(t, rows.expand(&m, 3 + N), "expanding pairs")
	testing.expect_value(t, rows.count(&m), 4 + N + N / 2)

	// steps and values formatted by each call: a few for each row of the
	// window, to find whether a set has fields, and none for each row before
	STEPS :: 200
	check :: proc(t: ^testing.T, m: ^rows.Model, what: string, formatted: int, loc := #caller_location) {
		testing.expectf(t, m.steps <= STEPS, "%s: %v steps", what, m.steps, loc = loc)
		testing.expectf(t, m.formatted == formatted, "%s: %v values formatted, want %v", what, m.formatted, formatted, loc = loc)
		m.steps, m.formatted = 0, 0
	}
	m.steps = 0
	for first in ([?]int{3, 3 + N / 2, 3 + N - 20}) {
		window := rows.rows(&m, first, 20)
		check(t, &m, fmt.tprintf("bytes from row %v", first), 20)
		if testing.expect_value(t, len(window), 20) {
			i := first - 3
			testing.expect_value(t, window[0].index, i)
			testing.expect_value(t, window[0].text, fmt.tprint(byte(4 + i)))
		}
	}

	// a pair in the middle of pairs, expanded: the rows around it
	mid := 4 + N + N / 4
	testing.expect(t, rows.expand(&m, mid), "expanding a pair")
	check(t, &m, "expanding a pair", 0)
	window := rows.rows(&m, mid - 1, 5)
	check(t, &m, "the rows around the pair", 2)
	if testing.expect_value(t, len(window), 5) {
		testing.expect_value(t, window[1].kind, rows.Kind.Set)
		testing.expect_value(t, window[2].name, "a")
		testing.expect_value(t, window[2].depth, 3)
		testing.expect_value(t, window[4].index, N / 4 + 1)
	}
	testing.expect_value(t, rows.parent(&m, mid + 2), mid)
	testing.expect_value(t, rows.parent(&m, mid), 3 + N)
	testing.expect_value(t, rows.next_sibling(&m, mid), mid + 3)
	testing.expect_value(t, rows.prev_sibling(&m, mid + 3), mid)
	window = rows.rows(&m, rows.count(&m) - 20, 40)
	check(t, &m, "the last rows", 0)
	testing.expect_value(t, len(window), 20)
	testing.expect(t, rows.collapse(&m, 2), "collapsing bytes")
	check(t, &m, "collapsing bytes", 0)
	testing.expect_value(t, rows.count(&m), 4 + N / 2 + 2)

	// every pair expanded: half a million expanded rows under one, which
	// are found, added and removed in steps of their logarithm, far fewer
	// than there are
	many: rows.Model
	rows.init(&many, &ff, &d.tree)
	defer rows.destroy(&many)
	testing.expect(t, rows.expand(&many, 3), "expanding pairs")
	// from the last, so that the rows of those before do not move
	for i := N / 2 - 1; i >= 0; i -= 1 do rows.expand(&many, 4 + i)
	total := rows.count(&many)
	testing.expect_value(t, total, 4 + 3 * (N / 2))
	MANY_STEPS :: 10_000
	check_many :: proc(t: ^testing.T, m: ^rows.Model, what: string, loc := #caller_location) {
		testing.expectf(t, m.steps <= MANY_STEPS, "%s: %v steps", what, m.steps, loc = loc)
		m.steps = 0
	}
	many.steps = 0
	window = rows.rows(&many, total - 20, 20)
	check_many(t, &many, "the last rows")
	if testing.expect_value(t, len(window), 20) {
		testing.expect_value(t, window[19].name, "b")
		testing.expect_value(t, window[18].name, "a")
		testing.expect_value(t, window[17].index, N / 2 - 1)
	}
	testing.expect_value(t, rows.parent(&many, total - 1), total - 3)
	check_many(t, &many, "the parent of the last row")
	testing.expect_value(t, rows.prev_sibling(&many, total - 3), total - 6)
	check_many(t, &many, "the pair before the last")
	window = rows.rows(&many, 4 + 3 * (N / 4), 3)
	check_many(t, &many, "the middle rows")
	if testing.expect_value(t, len(window), 3) do testing.expect_value(t, window[0].index, N / 4)
	testing.expect(t, rows.collapse(&many, total - 3), "collapsing the last pair")
	check_many(t, &many, "collapsing the last pair")
	testing.expect(t, rows.collapse(&many, 4), "collapsing the first pair")
	check_many(t, &many, "collapsing the first pair")
	testing.expect_value(t, rows.count(&many), total - 4)
	testing.expect_value(t, rows.next_sibling(&many, 4), 5)
	check_many(t, &many, "the pair after the first")
}

// Random expands and collapses of SAMPLE_KSY's rows, and moves from random
// rows, against an outline that makes every row: the rows of a model with
// every one expanded, of which those under a row not expanded are hidden.
@(test)
rows_random :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return
	data := sample_input(300)
	defer delete(data)
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, data[:], &d)

	full_model: rows.Model
	rows.init(&full_model, &ff, &d.tree)
	defer rows.destroy(&full_model)
	rows.expand_all(&full_model)
	// not in the temp allocator, which each op frees
	full := rows.rows(&full_model, 0, rows.count(&full_model), allocator = context.allocator)
	defer {
		for r in full do delete(r.text)
		delete(full)
	}
	expanded := make([]bool, len(full))
	defer delete(expanded)
	expanded[0] = true // as init leaves the root

	m: rows.Model
	rows.init(&m, &ff, &d.tree)
	defer rows.destroy(&m)

	// the rows of full that are shown
	visible :: proc(full: []rows.Row, expanded: []bool) -> []int {
		shown := make([dynamic]int, context.temp_allocator)
		for i := 0; i < len(full); {
			append(&shown, i)
			j := i + 1
			if !expanded[i] do for j < len(full) && full[j].depth > full[i].depth do j += 1
			i = j
		}
		return shown[:]
	}
	seed := u64(0x2545f4914f6cdd1d)
	random :: proc(seed: ^u64, n: int) -> int {
		seed^ ~= seed^ << 13
		seed^ ~= seed^ >> 7
		seed^ ~= seed^ << 17
		return int(seed^ % u64(n))
	}
	for op in 0 ..< 3000 {
		shown := visible(full, expanded)
		got := rows.rows(&m, 0, rows.count(&m))
		if !testing.expectf(t, len(got) == len(shown), "op %v: %v rows, want %v", op, len(got), len(shown)) do return
		for r, k in got {
			w := full[shown[k]]
			if !testing.expectf(t, r.depth == w.depth && r.name == w.name && r.index == w.index && r.expanded == expanded[shown[k]], "op %v, row %v: %v %s[%v] expanded %v, want %v %s[%v] expanded %v", op, k, r.depth, r.name, r.index, r.expanded, w.depth, w.name, w.index, expanded[shown[k]]) do return
		}

		k := random(&seed, len(shown))
		depth := full[shown[k]].depth
		want_parent, want_next, want_prev := -1, -1, -1
		for j := k - 1; j >= 0; j -= 1 {
			if full[shown[j]].depth < depth {
				want_parent = j
				break
			}
		}
		for j := k + 1; j < len(shown) && full[shown[j]].depth >= depth; j += 1 {
			if full[shown[j]].depth == depth {
				want_next = j
				break
			}
		}
		for j := k - 1; j >= 0 && full[shown[j]].depth >= depth; j -= 1 {
			if full[shown[j]].depth == depth {
				want_prev = j
				break
			}
		}
		testing.expectf(t, rows.parent(&m, k) == want_parent, "op %v: parent of %v is %v, want %v", op, k, rows.parent(&m, k), want_parent)
		testing.expectf(t, rows.next_sibling(&m, k) == want_next, "op %v: next sibling of %v is %v, want %v", op, k, rows.next_sibling(&m, k), want_next)
		testing.expectf(t, rows.prev_sibling(&m, k) == want_prev, "op %v: previous sibling of %v is %v, want %v", op, k, rows.prev_sibling(&m, k), want_prev)

		i := shown[k]
		if expanded[i] {
			testing.expectf(t, rows.collapse(&m, k), "op %v: collapsing row %v", op, k)
			// collapsing forgets the rows under it that were expanded
			expanded[i] = false
			for j := i + 1; j < len(full) && full[j].depth > full[i].depth; j += 1 do expanded[j] = false
		} else {
			testing.expectf(t, rows.expand(&m, k) == full[i].expandable, "op %v: expanding row %v", op, k)
			expanded[i] = full[i].expandable
		}
		free_all(context.temp_allocator)
	}
}

// A preview cuts a string at that many characters and a blob at that many
// bytes, never more than the dump's.
@(test)
rows_preview :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile("meta:\n  id: p\nseq:\n  - id: b\n    size: 32\n", &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %s", err.message) do return
	data: [32]byte
	for i in 0 ..< len(data) do data[i] = byte(i)
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, data[:], &d)

	m: rows.Model
	rows.init(&m, &ff, &d.tree)
	defer rows.destroy(&m)
	for c in ([?]struct {
			preview: int,
			want:    string,
		}{{0, "<32 bytes> 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f ..."}, {3, "<32 bytes> 00 01 02 ..."}, {40, "<32 bytes> 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f ..."}}) {
		got := rows.rows(&m, 1, 1, preview = c.preview)
		if testing.expect_value(t, len(got), 1) do testing.expectf(t, got[0].text == c.want, "preview %v: %s, want %s", c.preview, got[0].text, c.want)
	}
}

// Once made, a model allocates through context.allocator nowhere: it
// expands and collapses in its own allocator, and gives rows in the one
// rows is given.
@(test)
rows_allocate_only_where_given :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return
	data := sample_input(10)
	defer delete(data)
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, data[:], &d, spans = true)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("no memory")
	defer virtual.arena_destroy(&arena)
	m: rows.Model
	rows.init(&m, &ff, &d.tree, virtual.arena_allocator(&arena))

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		_ = rows.expand(&m, 5)
		_ = rows.expand(&m, 7)
		_ = rows.rows(&m, 0, rows.count(&m))
		_ = rows.parent(&m, 8)
		_ = rows.next_sibling(&m, 7)
		_ = rows.prev_sibling(&m, 8)
		_ = rows.collapse(&m, 5)
		rows.expand_all(&m)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	free_all(context.temp_allocator)

	// rows in an allocator that frees: what it gives is all it keeps
	out: mem.Tracking_Allocator
	mem.tracking_allocator_init(&out, context.allocator)
	defer mem.tracking_allocator_destroy(&out)
	{
		given := mem.tracking_allocator(&out)
		for _ in 0 ..< 10 {
			rs := rows.rows(&m, 0, 5, allocator = given)
			for r in rs do delete(r.text, given)
			delete(rs, given)
		}
	}
	testing.expect_value(t, len(out.allocation_map), 0)
}
