package tests

import arn "../gnrcrdr/arena"
import dat "../gnrcrdr/data"
import expr "../gnrcrdr/expression"
import mdat "../gnrcrdr/metadata"
import "core:fmt"
import "core:mem"
import "core:testing"

// A hand-built plan whose fields expressions can refer to:
//   r:   a: u1, b: u2, hdr, items (hdr.n instances), data: blob, later: u1
//   hdr: n: u1, tag: blob (_parent.a - 3 bytes)
//   items: v: u1
// data's length is set by each test.
@(private)
Expr_Plan :: struct {
	ff:              mdat.File_Format,
	root, hdr, data: ^mdat.Node,
}

// a = 5, b = 0x1234, hdr.n = 3, hdr.tag = ee ee, items.v = 0a 0b 0c, then 3
// bytes for data (1 or 2 of them) and later.
@(private)
EXPR_INPUT := []byte{0x05, 0x34, 0x12, 0x03, 0xee, 0xee, 0x0a, 0x0b, 0x0c, 0xd0, 0xd1, 0xff}

@(private)
DATA_POS :: 9 // where data starts in EXPR_INPUT

@(private)
plan_node :: proc(id: int, name: string, type: dat.Data_Type, a: mem.Allocator, children: ..^mdat.Node) -> ^mdat.Node {
	n := new(mdat.Node, a)
	n^ = {id = id, name = name, ref_name = name, type = type, count = mdat.Fixed_Count{1}}
	if len(children) > 0 do n.children = slice_clone(children, a)
	n.slot_count = mdat.count_slots(n) // the children's bit fields must be set first
	return n
}

@(private = "file")
slice_clone :: proc(s: []^mdat.Node, a: mem.Allocator) -> []^mdat.Node {
	c := make([]^mdat.Node, len(s), a)
	copy(c, s)
	return c
}

// Compiles text as an Int in scope, into the plan's arena. Fails the test
// and returns nil on error.
@(private)
must_compile :: proc(t: ^testing.T, ff: ^mdat.File_Format, text: string, scope: ..^mdat.Node, in_repeat := false) -> ^mdat.Expr {
	e, err := expr.compile(text, {types = scope, in_repeat = in_repeat}, .Int, arn.arena_allocator(&ff.arena))
	defer expr.destroy_error(&err)
	testing.expectf(t, err.kind == .None, "%q: %v at %v: %s", text, err.kind, err.offset, err.message)
	return e
}

// Fills p, which must be zero; destroy with mdat.destroy_file_format(&p.ff).
@(private)
make_expr_plan :: proc(t: ^testing.T, p: ^Expr_Plan) {
	a := arn.arena_allocator(&p.ff.arena)

	tag := plan_node(12, "tag", .Blob, a)
	p.hdr = plan_node(10, "hdr", .Set, a, plan_node(11, "n", .UInt8, a), tag)
	items := plan_node(20, "items", .Set, a, plan_node(21, "v", .UInt8, a))
	p.data = plan_node(30, "data", .Blob, a)
	p.root = plan_node(1, "r", .Set, a, plan_node(2, "a", .UInt8, a), plan_node(3, "b", .UInt16, a), p.hdr, items, p.data, plan_node(31, "later", .UInt8, a))
	p.ff.name = "r"
	p.ff.root = p.root

	tag.length = mdat.Rule_Length{expr = must_compile(t, &p.ff, "_parent.a - 3", p.root, p.hdr)}
	items.count = mdat.Rule_Count{expr = must_compile(t, &p.ff, "hdr.n", p.root)}
}

@(test)
expression_field_references :: proc(t: ^testing.T) {
	p: Expr_Plan
	defer mdat.destroy_file_format(&p.ff)
	make_expr_plan(t, &p)
	p.data.length = mdat.Rule_Length{expr = must_compile(t, &p.ff, "items.size - hdr.tag.size", p.root)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&p.ff, EXPR_INPUT, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, DATA_POS + 2)

	r := root_instance(&p.ff, &d)
	testing.expect_value(t, len(field_values(r, 20)), 3) // items: hdr.n instances
	tag := field_values(field_instance(r, 10), 12)[0].([]byte)
	testing.expect(t, len(tag) == 2 && tag[0] == 0xee && tag[1] == 0xee, "hdr.tag is not the 2 bytes _parent.a - 3")
	testing.expect_value(t, len(field_values(r, 30)[0].([]byte)), 1) // data: 3 - 2
}

@(test)
expression_repeat_index :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	a := arn.arena_allocator(&ff.arena)

	s := plan_node(2, "s", .Blob, a)
	s.count = mdat.Fixed_Count{3}
	ff.root = plan_node(1, "r", .Set, a, s)
	s.length = mdat.Rule_Length{expr = must_compile(t, &ff, "_index", ff.root, in_repeat = true)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {1, 2, 3}, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return

	values := field_values(root_instance(&ff, &d), 2)
	for v, i in values {
		testing.expectf(t, len(v.([]byte)) == i, "s[%v] has %v bytes, want %v", i, len(v.([]byte)), i)
	}
	testing.expect_value(t, d.consumed, 3)
}

@(private = "file")
Eval_Case :: struct {
	text: string,
	want: string,         // an expression giving the expected value; "" when err is set
	err:  dat.Read_Error, // the error evaluating text must give
}

// Evaluated in r's scope, after a, b, hdr and items and before data.
@(private = "file")
EVAL_CASES := [?]Eval_Case {
	// precedence and grouping
	{text = "1 + 2 * 3", want = "7"},
	{text = "(1 + 2) * 3", want = "9"},
	{text = "10 - 4 - 3", want = "3"},
	{text = "1 << 2 + 1", want = "8"},
	{text = "a & 4 == 4", want = "true"},
	{text = "6 | 1 ^ 3 & 2", want = "7"},
	{text = "-2 * 3", want = "-6"},
	{text = "~0", want = "-1"},
	{text = "not a == 5", want = "false"},
	{text = "false ? 1 : true ? 2 : 3", want = "2"},
	{text = "0x1_0 + 0b11 + 0o7", want = "26"},

	// division rounds toward negative infinity, % takes the divisor's sign
	{text = "7 / 2", want = "3"},
	{text = "-7 / 2", want = "-4"},
	{text = "7 / -2", want = "-4"},
	{text = "7 % 3", want = "1"},
	{text = "-7 % 3", want = "2"},
	{text = "7 % -3", want = "-2"},
	{text = "(-9223372036854775807 - 1) % -1", want = "0"},

	// the old Pow(2, [x]+1), now 2 << x, is exact above 2^24
	{text = "2 << 24", want = "33554432"},
	{text = "2 << 30", want = "2147483648"},
	{text = "(2 << 52) + 1", want = "9007199254740993"},
	{text = "2 << 61", want = "4611686018427387904"},
	{text = "2 << 62", err = .Integer_Overflow},

	// failures instead of wrapping
	{text = "9223372036854775807 + 1", err = .Integer_Overflow},
	{text = "-9223372036854775807 - 2", err = .Integer_Overflow},
	{text = "4294967296 * 4294967296", err = .Integer_Overflow},
	{text = "-(-9223372036854775807 - 1)", err = .Integer_Overflow},
	{text = "(-9223372036854775807 - 1) / -1", err = .Integer_Overflow},
	{text = "a / 0", err = .Division_By_Zero},
	{text = "a % 0", err = .Division_By_Zero},
	{text = "1 << 64", err = .Invalid_Shift},
	{text = "1 >> -1", err = .Invalid_Shift},
	{text = "-8 >> 1", want = "-4"},

	// and, or and ?: evaluate only what they need
	{text = "a == 5 or a / 0 == 1", want = "true"},
	{text = "a != 5 and a / 0 == 1", want = "false"},
	{text = "a > 4 ? 10 : a / 0", want = "10"},
	{text = "a < 4 ? 10 : a / 0", err = .Division_By_Zero},

	// field references and _io
	{text = "a + b", want = "4665"},
	{text = "hdr.n * 2", want = "6"},
	{text = "_root.hdr.n", want = "3"},
	{text = "items.size", want = "3"},
	{text = "hdr.tag.size", want = "2"},
	{text = "_io.pos", want = "9"},
	{text = "_io.size", want = "12"},
	{text = "_io.eof", want = "false"},
	{text = "data.size", err = .Absent_Field}, // itself: not read yet
	{text = "later", err = .Absent_Field},
}

@(test)
expression_eval :: proc(t: ^testing.T) {
	for c in EVAL_CASES {
		p: Expr_Plan
		defer mdat.destroy_file_format(&p.ff)
		make_expr_plan(t, &p)

		// data is 1 byte when text gives the expected value, 2 when it does not
		check := fmt.tprintf("(%s) == (%s) ? 1 : 2", c.text, c.err == .None ? c.want : "0")
		e := must_compile(t, &p.ff, check, p.root)
		if e == nil do continue
		p.data.length = mdat.Rule_Length{expr = e}

		d: Decoded
		defer destroy_decoded(&d)
		decode_bytes(&p.ff, EXPR_INPUT, &d)

		if c.err != .None {
			testing.expectf(t, d.err.kind == c.err && d.err.path == "r[0].data[0]", "%q: got %v at %s, want %v", c.text, d.err.kind, d.err.path, c.err)
		} else if testing.expectf(t, d.err.kind == .None, "%q: %v at %s", c.text, d.err.kind, d.err.path) {
			testing.expectf(t, d.consumed == DATA_POS + 2, "%q: not %s", c.text, c.want)
		}
	}
}

// A field read past the end of the input fails with the reader's error,
// and a reference to a field whose value is absent fails with Absent_Field.
@(test)
expression_absent_set :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	a := arn.arena_allocator(&ff.arena)

	// opt: present only when the input starts with 0x21
	opt := plan_node(2, "opt", .Set, a, plan_node(3, "n", .UInt8, a))
	opt.count = mdat.Marker_Count{markers = slice_marker(mdat.Marker{0, .UInt8, 0x21, .Little}, a)}
	data := plan_node(4, "data", .Blob, a)
	ff.root = plan_node(1, "r", .Set, a, opt, data)
	data.length = mdat.Rule_Length{expr = must_compile(t, &ff, "opt.n - 0x21", ff.root)}

	present: Decoded
	defer destroy_decoded(&present)
	decode_bytes(&ff, {0x21, 0xaa}, &present)
	testing.expectf(t, present.err.kind == .None && present.consumed == 1, "present: %v, consumed %v", present.err.kind, present.consumed)

	absent: Decoded
	defer destroy_decoded(&absent)
	decode_bytes(&ff, {0x00}, &absent)
	testing.expect_value(t, absent.err.kind, dat.Read_Error.Absent_Field)
	testing.expect_value(t, absent.err.path, "r[0].data[0]")
}

@(private = "file")
slice_marker :: proc(m: mdat.Marker, a: mem.Allocator) -> []mdat.Marker {
	s := make([]mdat.Marker, 1, a)
	s[0] = m
	return s
}

// The text of resolved expressions names their fields by path.
@(test)
expression_resolved_text :: proc(t: ^testing.T) {
	p: Expr_Plan
	defer mdat.destroy_file_format(&p.ff)
	make_expr_plan(t, &p)

	e := must_compile(t, &p.ff, "_root.hdr.n + hdr.tag.size + items.size", p.root)
	if e != nil do testing.expect_value(t, expr.to_string(e, context.temp_allocator), "((_root.hdr.n + hdr.tag.size) + items.size)")

	e = must_compile(t, &p.ff, "_parent.a + n", p.root, p.hdr)
	if e != nil do testing.expect_value(t, expr.to_string(e, context.temp_allocator), "(_parent.a + n)")

	tag := p.hdr.children[1].length.(mdat.Rule_Length).expr
	testing.expect_value(t, expr.to_string(tag, context.temp_allocator), "(_parent.a - 3)")
}
