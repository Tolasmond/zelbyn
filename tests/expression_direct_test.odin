package tests

import dmp "../gnrcrdr/dump"
import ksy "../gnrcrdr/ksy"
import mdat "../gnrcrdr/metadata"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// Direct forms (§10.5) give what the tree evaluator gives: each schema is
// compiled twice, once with its direct forms cleared, and both decode the
// same input to the same error, or to the same dump. The schemas use each
// form on every integer width, with values at the edges of the width,
// signed and unsigned, and with the field absent.

@(private = "file")
Width :: struct {
	name: string, // the unsigned type; the signed one starts with s
	size: int,
}

@(private = "file")
WIDTHS := [?]Width{{"u1", 1}, {"u2", 2}, {"u4", 4}, {"u8", 8}}

@(private = "file")
OPS := [?]string{"==", "!=", "<", "<=", ">", ">="}

@(private = "file")
CONSTANTS := [?]string{"0", "1", "255", "9223372036854775807"}

// The bit patterns tried in a width: 0, 1, the largest and smallest signed
// values, and all ones.
@(private = "file")
patterns :: proc(size: int) -> [5]u64 {
	bits := uint(8 * size)
	ones := bits == 64 ? max(u64) : (u64(1) << bits) - 1
	high := u64(1) << (bits - 1)
	return {0, 1, high - 1, high, ones}
}

@(private = "file")
append_le :: proc(b: ^[dynamic]byte, v: u64, size: int) {
	for i in 0 ..< size do append(b, byte(v >> (8 * uint(i))))
}

// Counts the direct forms in the plan from node, clearing them when clear
// is set.
@(private = "file")
Direct_Counts :: struct {
	constant, field, compare, element: int,
}

@(private = "file")
walk_direct :: proc(node: ^mdat.Node, counts: ^Direct_Counts, clear: bool) {
	visit :: proc(e: ^mdat.Expr, counts: ^Direct_Counts, clear: bool) {
		if e == nil do return
		switch x in e.direct {
		case mdat.Direct_Constant:
			counts.constant += 1
		case mdat.Direct_Field:
			counts.field += 1
		case mdat.Direct_Compare:
			counts.compare += 1
			if x.field.of_element do counts.element += 1
		}
		if clear do e.direct = nil
	}

	visit(node.cond, counts, clear)
	#partial switch c in node.count {
	case mdat.Rule_Count:
		visit(c.expr, counts, clear)
	case mdat.Until_Count:
		visit(c.expr, counts, clear)
	}
	if l, ok := node.length.(mdat.Rule_Length); ok do visit(l.expr, counts, clear)
	for inst in node.instances do visit(inst.expr, counts, clear)
	for child in node.children do walk_direct(child, counts, clear)
	if sw := node.switch_on; sw != nil {
		visit(sw.on, counts, clear)
		for c in sw.cases do walk_direct(c.node, counts, clear)
		if sw.default != nil do walk_direct(sw.default, counts, clear)
	}
}

// Decodes input with src as compiled, and with its direct forms cleared,
// and checks that both give the same result. Returns the direct forms src
// has.
@(private = "file")
check_same :: proc(t: ^testing.T, src: string, input: []byte, loc := #caller_location) -> (counts: Direct_Counts) {
	direct, tree: mdat.File_Format
	defer mdat.destroy_file_format(&direct)
	defer mdat.destroy_file_format(&tree)
	for ff in ([?]^mdat.File_Format{&direct, &tree}) {
		err := ksy.compile(src, ff)
		defer ksy.destroy_error(&err)
		if !testing.expectf(t, err.kind == .None, "%v at %v:%v: %s\n%s", err.kind, err.line, err.column, err.message, src, loc = loc) do return
	}
	walk_direct(direct.root, &counts, false)
	unused: Direct_Counts
	walk_direct(tree.root, &unused, true)

	a, b: Decoded
	defer destroy_decoded(&a)
	defer destroy_decoded(&b)
	decode_bytes(&direct, input, &a)
	decode_bytes(&tree, input, &b)

	if !testing.expectf(
		t,
		a.err.kind == b.err.kind && a.err.offset == b.err.offset && a.err.path == b.err.path && a.consumed == b.consumed,
		"input %v: direct gives %v at %v in %s (consumed %v), the tree %v at %v in %s (consumed %v)\n%s",
		input, a.err.kind, a.err.offset, a.err.path, a.consumed, b.err.kind, b.err.offset, b.err.path, b.consumed, src,
		loc = loc,
	) {
		return
	}
	if a.err.kind != .None do return

	da, db := strings.builder_make(), strings.builder_make()
	defer strings.builder_destroy(&da)
	defer strings.builder_destroy(&db)
	testing.expect(t, dmp.write_json(strings.to_writer(&da), &direct, &a.tree) == .None, "write_json failed", loc = loc)
	testing.expect(t, dmp.write_json(strings.to_writer(&db), &tree, &b.tree) == .None, "write_json failed", loc = loc)
	testing.expectf(t, strings.to_string(da) == strings.to_string(db), "input %v: dumps differ\n  direct: %s\n  tree:   %s", input, strings.to_string(da), strings.to_string(db), loc = loc)
	return
}

// A field f of each type, read when present is not 0, then each
// comparison of f with each constant, both ways round, each reading a
// byte when it holds; then a blob of f bytes and f bytes one by one.
@(test)
direct_field_and_compare :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	total: Direct_Counts

	for w in WIDTHS {
		for signed in ([?]bool{false, true}) {
			type := signed ? fmt.tprintf("s%s", w.name[1:]) : w.name

			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "meta:\n  id: d\n  endian: le\nseq:\n  - id: always\n    type: u1\n    if: true\n")
			fmt.sbprintf(&b, "  - id: present\n    type: u1\n  - id: f\n    type: %s\n    if: present != 0\n", type)
			conds := 0
			for op in OPS {
				for k in CONSTANTS {
					fmt.sbprintf(&b, "  - id: c%v\n    type: u1\n    if: f %s %s\n", conds, op, k)
					fmt.sbprintf(&b, "  - id: c%v\n    type: u1\n    if: %s %s f\n", conds + 1, k, op)
					conds += 2
				}
			}
			fmt.sbprintf(&b, "  - id: blob\n    size: f\n  - id: n\n    type: u1\n    repeat: expr\n    repeat-expr: f\n")
			src := strings.to_string(b)

			for present in ([?]byte{0, 1}) {
				for v in patterns(w.size) {
					input := make([dynamic]byte, context.temp_allocator)
					append(&input, 0x5a, present)
					if present != 0 do append_le(&input, v, w.size)
					for _ in 0 ..< conds + 4 do append(&input, 0xab)

					c := check_same(t, src, input[:])
					total.constant += c.constant
					total.field += c.field
					total.compare += c.compare
				}
			}
		}
	}

	testing.expect(t, total.constant > 0 && total.field > 0 && total.compare > 0, "a direct form was not exercised")
}

// repeat-until over items whose v has each type, with each comparison of
// _.v with each constant, both ways round, over every pattern in turn.
@(test)
direct_element_compare :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	element := 0

	for w in WIDTHS {
		for signed in ([?]bool{false, true}) {
			type := signed ? fmt.tprintf("s%s", w.name[1:]) : w.name
			input := make([dynamic]byte, context.temp_allocator)
			for v in patterns(w.size) do append_le(&input, v, w.size)

			for op in OPS {
				for k in CONSTANTS {
					for until in ([?]string{fmt.tprintf("_.v %s %s", op, k), fmt.tprintf("%s %s _.v", k, op)}) {
						src := fmt.tprintf(
							"meta:\n  id: d\n  endian: le\nseq:\n  - id: items\n    type: item\n    repeat: until\n    repeat-until: %s\ntypes:\n  item:\n    seq:\n      - id: v\n        type: %s\n",
							until, type,
						)
						element += check_same(t, src, input[:]).element
					}
				}
			}
		}
	}

	testing.expect(t, element > 0, "the direct form of _ was not exercised")
}
