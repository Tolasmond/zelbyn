package tests

import arn "../zelbyn/arena"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdat "../zelbyn/metadata"
import "core:mem"
import "core:testing"

// The layout of the arena and of the value tree, checked on the addresses
// themselves: what a leak or bad free check cannot see.

@(private = "file")
LAYOUT_HEAD :: "meta:\n  id: t\n  endian: le\n"

@(private = "file")
aligned :: proc(p: rawptr, alignment: int) -> bool {
	return uintptr(p) % uintptr(alignment) == 0
}

@(private = "file")
all_zero :: proc(b: []byte) -> bool {
	for x in b do if x != 0 do return false
	return true
}

@(private = "file")
Wide :: struct #align (16) {
	x: u8,
}

// arena_make gives each type its alignment, whatever came before it, and
// the allocator the alignment asked for, up to a page; the memory is zero,
// also in a block made for an allocation, after the first.
@(test)
layout_arena_alignment :: proc(t: ^testing.T) {
	a: arn.Arena
	defer arn.arena_destroy(&a)

	for round in 0 ..< 3 {
		b := arn.arena_make(&a, u8, 3)
		testing.expect(t, all_zero(b))
		h := arn.arena_make(&a, u16, 1)
		testing.expectf(t, aligned(raw_data(h), align_of(u16)), "round %v: u16 at %p", round, raw_data(h))
		_ = arn.arena_make(&a, u8, 1)
		q := arn.arena_make(&a, u64, 2)
		testing.expectf(t, aligned(raw_data(q), align_of(u64)), "round %v: u64 at %p", round, raw_data(q))
		_ = arn.arena_make(&a, u8, 1)
		w := arn.arena_make(&a, Wide, 1)
		testing.expectf(t, aligned(raw_data(w), 16), "round %v: a 16-aligned struct at %p", round, raw_data(w))
		testing.expect(t, all_zero(mem.slice_to_bytes(w)))
		v := arn.arena_make(&a, fld.Value, 2)
		testing.expectf(t, aligned(raw_data(v), align_of(fld.Value)), "round %v: Value at %p", round, raw_data(v))
	}

	allocator := arn.arena_allocator(&a)
	for alignment := 1; alignment <= 4096; alignment *= 2 {
		_, _ = mem.alloc_bytes(1, 1, allocator) // the next one does not start aligned by chance
		p, err := mem.alloc_bytes(24, alignment, allocator)
		testing.expectf(t, err == nil && aligned(raw_data(p), alignment) && all_zero(p), "alignment %v: %p, %v", alignment, raw_data(p), err)
	}

	// in a block made for an allocation larger than the block left
	before := a.block
	big, err := mem.alloc_bytes(2 * arn.ARENA_BLOCK_SIZE, 64, allocator)
	testing.expectf(t, err == nil && a.block != before && aligned(raw_data(big), 64), "a block of its own: %v, aligned: %v", err, aligned(raw_data(big), 64))
	testing.expect(t, all_zero(big[:4096]) && all_zero(big[len(big) - 4096:]))
}

// The most recent allocation grows in place while its block has room,
// committing more as it needs, and shrinks in place; any other allocation,
// and the most recent once its block is full, moves, with its bytes, and
// what came after it is left as it was. A dynamic array, as the decoder's
// slots grow, so stays where it was.
@(test)
layout_arena_growth :: proc(t: ^testing.T) {
	a: arn.Arena
	defer arn.arena_destroy(&a)
	allocator := arn.arena_allocator(&a)

	p, _ := mem.alloc_bytes(16, 8, allocator)
	for &x, i in p do x = byte(i + 1)
	used := arn.arena_used(&a)
	grown, err := mem.resize_bytes(p, 64, 8, allocator)
	testing.expectf(t, err == nil && raw_data(grown) == raw_data(p), "grown in place: %p from %p, %v", raw_data(grown), raw_data(p), err)
	testing.expect_value(t, arn.arena_used(&a), used + 48)
	for i in 0 ..< 16 do testing.expect(t, grown[i] == byte(i + 1))
	testing.expect(t, all_zero(grown[16:]))

	// shrinking keeps it, and what it used
	shrunk, _ := mem.resize_bytes(grown, 8, 8, allocator)
	testing.expect(t, raw_data(shrunk) == raw_data(p) && arn.arena_used(&a) == used + 48)

	// past the first commit of its block, in place
	big, _ := mem.resize_bytes(grown, 3 * arn.COMMIT_SIZE, 8, allocator)
	testing.expectf(t, raw_data(big) == raw_data(p), "grown past a commit in place: %p from %p", raw_data(big), raw_data(p))
	for i in 0 ..< 16 do testing.expect(t, big[i] == byte(i + 1))

	// not the most recent: moved, with its bytes, leaving the next one be
	q, _ := mem.alloc_bytes(8, 8, allocator)
	for &x in q do x = 0xaa
	moved, _ := mem.resize_bytes(big, 3 * arn.COMMIT_SIZE + 8, 8, allocator)
	testing.expect(t, raw_data(moved) != raw_data(p))
	for i in 0 ..< 16 do testing.expect(t, moved[i] == byte(i + 1))
	for x in q do testing.expect(t, x == 0xaa)

	// the most recent, beyond what its block reserves: moved to a new block
	block := a.block
	last, _ := mem.alloc_bytes(32, 8, allocator)
	for &x, i in last do x = byte(100 + i)
	beyond, _ := mem.resize_bytes(last, int(block.reserved), 8, allocator)
	testing.expect(t, raw_data(beyond) != raw_data(last) && a.block != block && a.block.prev == block)
	for i in 0 ..< 32 do testing.expect(t, beyond[i] == byte(100 + i))

	// a dynamic array, appended to as a repeat is read, stays in place
	b: arn.Arena
	defer arn.arena_destroy(&b)
	values := make([dynamic]int, 0, 8, arn.arena_allocator(&b))
	first := raw_data(values)
	for i in 0 ..< 10_000 do append(&values, i)
	testing.expectf(t, raw_data(values) == first, "the array moved: %p from %p", raw_data(values), first)
	for v, i in values do if v != i do testing.expectf(t, false, "values[%v] = %v", i, v)
}

// A block full, the next reserves the target, which doubles with each
// block; an allocation larger than the target gets a block of its own
// size, larger than the block after it. Earlier blocks keep their bytes,
// arena_used counts every block, and arena_destroy frees them all.
@(test)
layout_arena_rollover :: proc(t: ^testing.T) {
	a: arn.Arena
	FIRST :: 64 * mem.Kilobyte
	arn.arena_init(&a, FIRST)

	first := arn.arena_make(&a, u8, 40 * mem.Kilobyte)
	for &x, i in first do x = byte(i)
	b1 := a.block
	testing.expectf(t, b1 != nil && b1.reserved >= FIRST && b1.prev == nil, "first block: %v", b1.reserved)
	testing.expect_value(t, a.block_size, uint(2 * FIRST))

	second := arn.arena_make(&a, u8, 40 * mem.Kilobyte)
	b2 := a.block
	testing.expectf(t, b2 != b1 && b2.prev == b1 && b2.reserved >= 2 * FIRST, "second block: %v", b2.reserved)
	testing.expect_value(t, a.block_size, uint(4 * FIRST))

	// one larger than the target, 256 KB: its own size
	large := arn.arena_make(&a, u8, mem.Megabyte)
	b3 := a.block
	testing.expectf(t, b3.prev == b2 && b3.reserved >= mem.Megabyte, "large block: %v", b3.reserved)
	testing.expect_value(t, a.block_size, uint(8 * FIRST))

	// the next is the target, 512 KB, smaller than the large one
	rest := int(b3.reserved - b3.used)
	_ = arn.arena_make(&a, u8, rest + 1)
	b4 := a.block
	testing.expectf(t, b4.prev == b3 && b4.reserved >= 8 * FIRST && b4.reserved < b3.reserved, "after the large block: %v, the large one %v", b4.reserved, b3.reserved)

	for x, i in first do if x != byte(i) do testing.expectf(t, false, "first[%v] = %v after the rollovers", i, x)
	testing.expect(t, raw_data(second) != nil && raw_data(large) != nil)
	testing.expect_value(t, arn.arena_used(&a), b1.used + b2.used + b3.used + b4.used)

	arn.arena_destroy(&a)
	testing.expect(t, a.block == nil && a.block_size == 0)
}

// make_instance lays an instance out in one block: the Instance, its slots,
// a cell for each, and with spans a span for each cell, all empty and
// zero, in that order, and nothing more. In a decoded tree, a field that
// was not read has an empty slot, one read no times (repeat-expr: 0) an
// empty view of its cell, and a parse instance whose if is false a slot
// that is empty but not nil, as one that has been read.
@(test)
layout_instance_slots :: proc(t: ^testing.T) {
	a: arn.Arena
	defer arn.arena_destroy(&a)

	for spans in ([]bool{false, true}) {
		for n in ([]int{0, 1, 3}) {
			used := arn.arena_used(&a)
			instance: ^fld.Instance
			cells: []fld.Value
			if spans {
				instance, cells = fld.make_instance(&a, n, 2, true)
			} else {
				instance, cells = fld.make_instance(&a, n, 2, false)
			}
			span_size := spans ? size_of(fld.Span) : 0
			testing.expect_value(t, int(arn.arena_used(&a) - used), size_of(fld.Instance) + n * (size_of([]fld.Value) + size_of(fld.Value) + span_size))
			testing.expect(t, aligned(instance, align_of(fld.Instance)))
			testing.expect_value(t, instance.choice, 2)
			testing.expect_value(t, len(instance.slots), n)
			testing.expect_value(t, len(cells), n)
			if n == 0 do continue
			testing.expect(t, uintptr(raw_data(instance.slots)) == uintptr(instance) + size_of(fld.Instance))
			testing.expect(t, uintptr(raw_data(cells)) == uintptr(raw_data(instance.slots)) + uintptr(n * size_of([]fld.Value)))
			testing.expect(t, raw_data(fld.instance_cells(instance)) == raw_data(cells))
			for slot in instance.slots do testing.expect(t, slot == nil)
			for c in cells do testing.expect(t, c == nil)
			if spans {
				s := fld.cell_spans(instance)
				testing.expect(t, uintptr(raw_data(s)) == uintptr(raw_data(cells)) + uintptr(n * size_of(fld.Value)))
				for x in s do testing.expect(t, x == fld.Span{})
			}
		}
	}

	src := LAYOUT_HEAD + `seq:
  - id: skipped
    type: u1
    if: false
  - id: none
    type: u1
    repeat: expr
    repeat-expr: 0
  - id: one
    type: u1
instances:
  never:
    pos: 0
    type: u1
    if: false
  read:
    pos: 0
    type: u1
`
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v: %s", err.kind, err.message) do return
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {7}, &d)
	if !testing.expectf(t, d.err.kind == .None, "%v", d.err.kind) do return
	root := root_instance(&ff, &d)
	cells := fld.instance_cells(root.instance)
	skipped := root.instance.slots[field_slot(root, "skipped")]
	testing.expect(t, len(skipped) == 0 && raw_data(skipped) == nil)
	k := field_slot(root, "none")
	none := root.instance.slots[k]
	testing.expect(t, len(none) == 0 && raw_data(none) == &cells[k])
	k = field_slot(root, "one")
	one := root.instance.slots[k]
	testing.expect(t, len(one) == 1 && raw_data(one) == &cells[k] && variant_equal(one[0], fld.Value(u8(7))))
	never := root.instance.slots[field_slot(root, "never")]
	testing.expect(t, len(never) == 0 && raw_data(never) != nil)
	read := root.instance.slots[field_slot(root, "read")]
	testing.expect(t, len(read) == 1 && variant_equal(read[0], fld.Value(u8(7))))
}

// The spans of an array that grew, from 8 values by doubling, as a count
// not known in advance grows (repeat: eos), and one above the bytes left
// (repeat-expr: 100 with 80 left), are those of the values read before it grew too, as the
// elements of a repeated set and the values in their cells, and as the
// -bits fields beside an integer, whose slots grow with its slot.
@(test)
layout_spans_after_growth :: proc(t: ^testing.T) {
	N :: 40
	src := LAYOUT_HEAD + `seq:
  - id: head
    type: u1
  - id: nothing
    size: 0
    repeat: expr
    repeat-expr: 100
  - id: recs
    type: rec
    repeat: expr
    repeat-expr: 20
  - id: items
    type: u1
    repeat: eos
    -bits:
      - id: low
        low: 0
        high: 3
types:
  rec:
    seq:
      - id: v
        type: u2
`
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v: %s", err.kind, err.message) do return

	input := make([dynamic]byte, context.temp_allocator)
	append(&input, 0xab)
	for i in 0 ..< 20 do append(&input, byte(i), 0)
	for i in 0 ..< N do append(&input, byte(i))
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, input[:], &d, spans = true)
	if !testing.expectf(t, d.err.kind == .None, "%v", d.err.kind) do return

	testing.expect_value(t, fld.root_span(&d.tree, 0), fld.Span{0, len(input)})
	root := root_instance(&ff, &d)
	testing.expect_value(t, fld.value_span(root.instance, field_slot(root, "head"), 0), fld.Span{0, 1})

	// 100 empty elements with 80 bytes left, more than can be reserved
	// exactly (reader.read_values), so grown: 8, 16, 32, 64, 128
	COUNT :: 100
	testing.expectf(t, COUNT > len(input) - 1, "nothing's count, %v, must be above the %v bytes left, to grow", COUNT, len(input) - 1)
	k := field_slot(root, "nothing")
	testing.expect_value(t, len(root.instance.slots[k]), COUNT)
	for i in 0 ..< COUNT do testing.expectf(t, fld.value_span(root.instance, k, i) == fld.Span{1, 0}, "nothing[%v]: %v", i, fld.value_span(root.instance, k, i))

	k = field_slot(root, "recs")
	for i in 0 ..< 20 {
		testing.expectf(t, fld.value_span(root.instance, k, i) == fld.Span{1 + 2 * i, 2}, "recs[%v]: %v", i, fld.value_span(root.instance, k, i))
		rec := field_instance(root, "recs", i)
		testing.expectf(t, fld.value_span(rec.instance, field_slot(rec, "v"), 0) == fld.Span{1 + 2 * i, 2}, "recs[%v].v", i)
	}

	items, low := field_slot(root, "items"), field_slot(root, "low")
	testing.expect_value(t, len(root.instance.slots[items]), N)
	testing.expect_value(t, len(root.instance.slots[low]), N)
	for i in 0 ..< N {
		want := fld.Span{41 + i, 1}
		testing.expectf(t, fld.value_span(root.instance, items, i) == want && fld.value_span(root.instance, low, i) == want, "items[%v]: %v, low: %v", i, fld.value_span(root.instance, items, i), fld.value_span(root.instance, low, i))
		testing.expect(t, variant_equal(root.instance.slots[low][i], fld.Value(u8(i & 0xf))))
	}
}
