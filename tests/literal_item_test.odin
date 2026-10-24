package tests

import dmp "../zelbyn/dump"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:fmt"
import "core:strings"
import "core:testing"

// An index of a constant array literal evaluates only the item it gives
// (literal_item, doc/arch.md, "Expression evaluation"). That is a choice
// of how to evaluate, not of what an expression means: each schema is
// compiled twice, once with every array literal's constant flag cleared,
// so that each is made whole, and both decode the same inputs to the same
// error, or to the same dump. The schemas index tables of every item type,
// directly and as value instances, also of another set instance, nested,
// with indexes in and out of range, and with indexes that fail.

// Counts the array literals in the plan from node that are constant,
// clearing the flag when clear is set.
@(private = "file")
walk_constant :: proc(node: ^mdata.Node, count: ^int, clear: bool) {
	visit :: proc(e: ^mdata.Expr, count: ^int, clear: bool) {
		if e == nil do return
		#partial switch &x in e.variant {
		case mdata.Array_Literal:
			if x.constant do count^ += 1
			if clear do x.constant = false
			for item in x.items do visit(item, count, clear)
		case mdata.Index:
			visit(x.operand, count, clear)
			visit(x.index, count, clear)
		case mdata.Binary:
			visit(x.left, count, clear)
			visit(x.right, count, clear)
		case mdata.Unary:
			visit(x.operand, count, clear)
		case mdata.Ternary:
			visit(x.cond, count, clear)
			visit(x.then, count, clear)
			visit(x.otherwise, count, clear)
		case mdata.Size:
			visit(x.operand, count, clear)
		case mdata.Field_Ref:
			visit(x.base, count, clear)
		case mdata.Value_Ref:
			visit(x.base, count, clear)
		}
	}

	visit(node.cond, count, clear)
	#partial switch c in node.count {
	case mdata.Rule_Count:
		visit(c.expr, count, clear)
	}
	if l, ok := node.length.(mdata.Rule_Length); ok do visit(l.expr, count, clear)
	for inst in node.instances {
		visit(inst.cond, count, clear)
		visit(inst.expr, count, clear)
	}
	for child in node.children do walk_constant(child, count, clear)
	if sw := node.switch_on; sw != nil {
		visit(sw.on, count, clear)
		for c in sw.cases do walk_constant(c.node, count, clear)
	}
}

// Decodes input with src as compiled, and with its constant flags cleared,
// and checks that both give the same result. Returns the constant array
// literals src has.
@(private = "file")
check_same_literals :: proc(t: ^testing.T, src: string, input: []byte, loc := #caller_location) -> (constants: int) {
	item, whole: mdata.File_Format
	defer mdata.destroy_file_format(&item)
	defer mdata.destroy_file_format(&whole)
	for ff in ([?]^mdata.File_Format{&item, &whole}) {
		err := ksy.compile(src, ff)
		defer ksy.destroy_error(&err)
		if !testing.expectf(t, err.kind == .None, "%v at %v:%v: %s\n%s", err.kind, err.line, err.column, err.message, src, loc = loc) do return
	}
	walk_constant(item.root, &constants, false)
	left := 0
	walk_constant(whole.root, &left, true)

	a, b: Decoded
	defer destroy_decoded(&a)
	defer destroy_decoded(&b)
	decode_bytes(&item, input, &a)
	decode_bytes(&whole, input, &b)

	if !testing.expectf(
		t,
		a.err.kind == b.err.kind && a.err.offset == b.err.offset && a.err.path == b.err.path && a.consumed == b.consumed,
		"input %v: by item %v at %v in %s (consumed %v), whole %v at %v in %s (consumed %v)\n%s",
		input, a.err.kind, a.err.offset, a.err.path, a.consumed, b.err.kind, b.err.offset, b.err.path, b.consumed, src,
		loc = loc,
	) {
		return
	}
	if a.err.kind != .None do return

	da, db := strings.builder_make(), strings.builder_make()
	defer strings.builder_destroy(&da)
	defer strings.builder_destroy(&db)
	testing.expect(t, dmp.write_json(strings.to_writer(&da), &item, &a.tree) == .None, "write_json failed", loc = loc)
	testing.expect(t, dmp.write_json(strings.to_writer(&db), &whole, &b.tree) == .None, "write_json failed", loc = loc)
	testing.expectf(t, strings.to_string(da) == strings.to_string(db), "input %v: dumps differ\n  by item: %s\n  whole:   %s", input, strings.to_string(da), strings.to_string(db), loc = loc)
	return
}

// Each schema reads i and z, then fields whose count, condition, case or
// size an indexed table gives; i runs past the tables' ends, and z through
// 0, which some indexes divide by.
@(test)
literal_item_same_as_whole :: proc(t: ^testing.T) {
	Case :: struct {
		fields, instances: string,
	}
	cases := [?]Case {
		// integers, directly and as a value instance, of every size
		{"  - id: n\n    type: u1\n    repeat: expr\n    repeat-expr: ints[i] % 4\n  - id: m\n    type: u1\n    repeat: expr\n    repeat-expr: '[3, 1, 2, 0][i]'\n",
		 "  ints:\n    value: '[1, -30, 9223372036854775807, 18446744073709551615]'\n"},
		// floats, an integer among them, booleans and strings
		{"  - id: f\n    type: u1\n    if: floats[i] > 1.5\n  - id: b\n    type: u1\n    if: bools[i]\n  - id: s\n    type:\n      switch-on: names[i]\n      cases:\n        '\"a\"': u1\n        '\"bc\"': u2\n",
		 "  floats:\n    value: '[1, 2.5, -0.5, 1e300]'\n  bools:\n    value: '[true, false, true, false]'\n  names:\n    value: '[\"a\", \"bc\", \"\", \"a\"]'\n"},
		// byte arrays, and arrays of arrays, indexed twice
		{"  - id: blob\n    size: blobs[i].size\n  - id: g\n    type: u1\n    repeat: expr\n    repeat-expr: grid[i][z]\n  - id: h\n    type: u1\n    repeat: expr\n    repeat-expr: wide[i % 2][z % 2] % 3\n",
		 "  blobs:\n    value: '[[1, 2], [0x50, 0x4b, 3], [7], [255, 0]]'\n  grid:\n    value: '[[0, 1], [2, 0], [1, 1], [0, 0]]'\n  wide:\n    value: '[[1, 256], [2, 300]]'\n"},
		// indexes that fail: by zero, and beyond an int or an integer
		{"  - id: q\n    type: u1\n    if: '[1, 2, 3, 4][i / z] == 2'\n  - id: r\n    type: u1\n    if: '[1, 2][i * 0xffff_ffff_ffff_ffff] == 1'\n",
		 ""},
		// a table of another set instance, which can be absent
		{"  - id: child\n    type: holder\n    if: z != 1\n  - id: c\n    type: u1\n    repeat: expr\n    repeat-expr: child.table[i]\n",
		 ""},
	}
	constants := 0
	for c in cases {
		src := fmt.tprintf("meta:\n  id: l\n  endian: le\nseq:\n  - id: i\n    type: u1\n  - id: z\n    type: u1\n%s%s%stypes:\n  holder:\n    instances:\n      table:\n        value: '[2, 0, 1, 3]'\n",
			c.fields, c.instances == "" ? "" : "instances:\n", c.instances)
		for i in 0 ..< 6 {
			for z in 0 ..< 3 {
				input := make([dynamic]byte, context.temp_allocator)
				append(&input, byte(i), byte(z))
				for k in 0 ..< 32 do append(&input, byte(k % 3))
				constants += check_same_literals(t, src, input[:])
			}
		}
	}
	testing.expect(t, constants > 0, "no constant array literal was exercised")
}

// The decision literal_item rests on: an array literal is constant only
// when no item can fail or depends on the input, and one that is not is
// made whole, so that an error in an item the index does not give is the
// expression's, as making the array would give it.
@(test)
literal_item_only_of_constants :: proc(t: ^testing.T) {
	Case :: struct {
		value:    string, // a value instance
		constant: bool,
	}
	cases := [?]Case {
		{"[1, 300]", true},
		{"[-1, 2.5]", true},
		{"[[1, 300], [2, 400]]", true},
		{"[\"a\", \"b\"]", true},
		{"[true, false]", true},
		{"[n, 300]", false},
		{"[10 / 1, 300]", false},
		{"[-9223372036854775808, 1]", false},
		{"[[n, 300], [2, 400]]", false},
	}
	for c in cases {
		src := fmt.tprintf("meta:\n  id: l\nseq:\n  - id: n\n    type: u1\ninstances:\n  v:\n    value: '%s'\n", c.value)
		ff: mdata.File_Format
		err := ksy.compile(src, &ff)
		if testing.expectf(t, err.kind == .None, "%s: %v: %s", c.value, err.kind, err.message) {
			lit, is_literal := ff.root.instances[0].expr.variant.(mdata.Array_Literal)
			testing.expectf(t, is_literal && lit.constant == c.constant, "%s: constant is %v, want %v", c.value, lit.constant, c.constant)
		}
		ksy.destroy_error(&err)
		mdata.destroy_file_format(&ff)
	}

	// an error in an item the index does not give, of an array that is not
	// constant, fails the expression
	Fail :: struct {
		fields: string,
		want:   string,
	}
	fails := [?]Fail {
		{"  - id: c\n    type: u1\n    if: '[n, 10 / z][0] == 1'\n", "error: Division_By_Zero at 2 in l[0]"},
		{"  - id: a\n    type: u1\n    if: z == 1\n  - id: c\n    type: u1\n    if: '[n, a][0] == 1'\n", "error: Absent_Field at 2 in l[0]"},
	}
	for f in fails {
		src := fmt.tprintf("meta:\n  id: l\nseq:\n  - id: n\n    type: u1\n  - id: z\n    type: u1\n%s", f.fields)
		ff: mdata.File_Format
		err := ksy.compile(src, &ff)
		if testing.expectf(t, err.kind == .None, "%s: %v: %s", f.fields, err.kind, err.message) {
			d: Decoded
			decode_bytes(&ff, []byte{1, 0, 9}, &d)
			got := fmt.tprintf("error: %v at %v in %s", d.err.kind, d.err.offset, d.err.path)
			testing.expectf(t, got == f.want, "%s: got %s, want %s", f.fields, got, f.want)
			destroy_decoded(&d)
		}
		ksy.destroy_error(&err)
		mdata.destroy_file_format(&ff)
	}
}

// A negated integer literal among floats, in an array literal or a ?:,
// is made a float as the evaluator would negate it, in i128: -min(int),
// an enum constant's value, is 2^63, and -0 is 0.0, not -0.0, which the
// differential test above cannot tell, as both of its plans are resolved
// alike. Each check is a valid on a byte of the input.
@(test)
literal_item_negated_floats :: proc(t: ^testing.T) {
	checks := [?]string {
		"[-e::min_value, 0.5][0] == 9223372036854775808.0",
		"(true ? -e::min_value : 0.5) == 9223372036854775808.0",
		"(true ? -e::min_value : 0.5) > 0",
		"[-e::min_value, 0.5][0] > 0",
		"1 / [-0, 0.5][0] > 0",
		"1 / (true ? -0 : 0.5) > 0",
		"[-5, 0.5][0] == -5.0",
		"(false ? 0.5 : -5) == -5.0",
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "meta:\n  id: l\nenums:\n  e:\n    -9223372036854775808: min_value\nseq:\n")
	for c, i in checks do fmt.sbprintf(&b, "  - id: c%v\n    type: u1\n    valid:\n      expr: '%s'\n", i, c)

	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile(strings.to_string(b), &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return

	input: [len(checks)]byte
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, input[:], &d)
	failed := d.err.kind == .None ? "" : checks[d.err.offset]
	testing.expectf(t, d.err.kind == .None, "%v in %s: %s", d.err.kind, d.err.path, failed)
}
