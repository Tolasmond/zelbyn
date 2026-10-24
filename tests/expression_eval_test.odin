package tests

import arn "../zelbyn/arena"
import dat "../zelbyn/data"
import expr "../zelbyn/expression"
import mdata "../zelbyn/metadata"
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
	ff:              mdata.File_Format,
	root, hdr, data: ^mdata.Node,
}

// a = 5, b = 0x1234, hdr.n = 3, hdr.tag = ee ee, items.v = 0a 0b 0c, then 3
// bytes for data (1 or 2 of them) and later.
@(private)
EXPR_INPUT := []byte{0x05, 0x34, 0x12, 0x03, 0xee, 0xee, 0x0a, 0x0b, 0x0c, 0xd0, 0xd1, 0xff}

@(private)
DATA_POS :: 9 // where data starts in EXPR_INPUT

@(private)
plan_node :: proc(name: string, type: dat.Data_Type, a: mem.Allocator, children: ..^mdata.Node) -> ^mdata.Node {
	n := new(mdata.Node, a)
	n^ = {name = name, ref_name = name, type = type, count = mdata.Fixed_Count{n = 1}}
	if len(children) > 0 do n.children = slice_clone(children, a)
	n.slot_count = mdata.count_slots(n) // the children's bit fields must be set first
	return n
}

@(private = "file")
slice_clone :: proc(s: []^mdata.Node, a: mem.Allocator) -> []^mdata.Node {
	c := make([]^mdata.Node, len(s), a)
	copy(c, s)
	return c
}

// Compiles text as an Int in scope, into the plan's arena. Fails the test
// and returns nil on error.
@(private)
must_compile :: proc(t: ^testing.T, ff: ^mdata.File_Format, text: string, scope: ..^mdata.Node, in_repeat := false) -> ^mdata.Expr {
	e, err := expr.compile(text, {types = scope, in_repeat = in_repeat}, .Int, arn.arena_allocator(&ff.arena))
	defer expr.destroy_error(&err)
	testing.expectf(t, err.kind == .None, "%q: %v at %v: %s", text, err.kind, err.offset, err.message)
	return e
}

// Fills p, which must be zero; destroy with mdata.destroy_file_format(&p.ff).
@(private)
make_expr_plan :: proc(t: ^testing.T, p: ^Expr_Plan) {
	a := arn.arena_allocator(&p.ff.arena)

	tag := plan_node("tag", .Blob, a)
	p.hdr = plan_node("hdr", .Set, a, plan_node("n", .UInt8, a), tag)
	items := plan_node("items", .Set, a, plan_node("v", .UInt8, a))
	p.data = plan_node("data", .Blob, a)
	p.root = plan_node("r", .Set, a, plan_node("a", .UInt8, a), plan_node("b", .UInt16, a), p.hdr, items, p.data, plan_node("later", .UInt8, a))
	p.ff.name = "r"
	p.ff.root = p.root

	tag.length = mdata.Rule_Length{expr = must_compile(t, &p.ff, "_parent.a - 3", p.root, p.hdr)}
	items.count = mdata.Rule_Count{expr = must_compile(t, &p.ff, "hdr.n", p.root)}
}

@(test)
expression_field_references :: proc(t: ^testing.T) {
	p: Expr_Plan
	defer mdata.destroy_file_format(&p.ff)
	make_expr_plan(t, &p)
	p.data.length = mdata.Rule_Length{expr = must_compile(t, &p.ff, "items.size - hdr.tag.size", p.root)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&p.ff, EXPR_INPUT, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, DATA_POS + 2)

	r := root_instance(&p.ff, &d)
	testing.expect_value(t, len(field_values(r, "items")), 3) // items: hdr.n instances
	tag := field_values(field_instance(r, "hdr"), "tag")[0].([]byte)
	testing.expect(t, len(tag) == 2 && tag[0] == 0xee && tag[1] == 0xee, "hdr.tag is not the 2 bytes _parent.a - 3")
	testing.expect_value(t, len(field_values(r, "data")[0].([]byte)), 1) // data: 3 - 2
}

@(test)
expression_repeat_index :: proc(t: ^testing.T) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	a := arn.arena_allocator(&ff.arena)

	s := plan_node("s", .Blob, a)
	s.count = mdata.Fixed_Count{n = 3}
	ff.root = plan_node("r", .Set, a, s)
	s.length = mdata.Rule_Length{expr = must_compile(t, &ff, "_index", ff.root, in_repeat = true)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {1, 2, 3}, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return

	values := field_values(root_instance(&ff, &d), "s")
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
	{text = "2 << 62", want = "9223372036854775808"},

	// a result beyond an int is a u64, up to 2^64 - 1, as the operands are
	// ints or not, and in any context but a size, count, offset or index
	{text = "(9223372036854775807 + 1) == 9223372036854775808", want = "true"},
	{text = "a + 9223372036854775807", want = "9223372036854775812"},
	{text = "9223372036854775807 * 2 + 1", want = "18446744073709551615"},
	{text = "4294967296 * 2147483648", want = "9223372036854775808"},
	{text = "1 << 63", want = "9223372036854775808"},
	{text = "-1 << 63 == -9223372036854775807 - 1", want = "true"},
	{text = "0 - (-9223372036854775807 - 1)", want = "9223372036854775808"},
	{text = "(-9223372036854775807 - 1) / -1", want = "9223372036854775808"},
	{text = "(a + 9223372036854775807).to_s == '9223372036854775812'", want = "true"},
	{text = "[1, 2][9223372036854775807 + 1]", err = .Index_Out_Of_Range},

	// failures instead of wrapping
	{text = "-9223372036854775807 - 2", err = .Integer_Overflow},
	{text = "4294967296 * 4294967296", err = .Integer_Overflow},
	{text = "3 << 63", err = .Integer_Overflow},
	{text = "9223372036854775807 * 2 + 2", err = .Integer_Overflow},
	{text = "-(-9223372036854775807 - 1) == 9223372036854775808", want = "true"},
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
	{text = "_root._io.size + hdr._io.size * 100", want = "1212"},
	{text = "data.size", err = .Absent_Field}, // itself: not read yet

	// strings, compared byte by byte; .length counts code points
	{text = `("ab" + 'c').length`, want = "3"},
	{text = `"\303\251".length`, want = "1"},
	{text = "'abc' < 'abd' ? 1 : 0", want = "1"},
	{text = "'ab' < 'a' ? 1 : 0", want = "0"},
	{text = "'ab' == 'a' + 'b' ? 1 : 0", want = "1"},
	{text = "'-42'.to_i", want = "-42"},
	{text = "'+7'.to_i", want = "7"},
	{text = "'4x'.to_i", err = .Invalid_Number},
	{text = "''.to_i", err = .Invalid_Number},
	{text = "'9223372036854775808'.to_i", want = "9223372036854775808"},
	{text = "'18446744073709551615'.to_i", want = "18446744073709551615"},
	{text = "'18446744073709551616'.to_i", err = .Integer_Overflow},
	{text = "'-9223372036854775809'.to_i", err = .Integer_Overflow},
	{text = "'1000000000000000000000000000000000000000000'.to_i", err = .Integer_Overflow},
	{text = "'1000000000000000000000000000000000000000000x'.to_i", err = .Invalid_Number},
	{text = "'-9223372036854775808'.to_i == -9223372036854775807 - 1 ? 1 : 0", want = "1"},
	{text = "(a - 8).to_s.to_i", want = "-3"},
	{text = "(a * 100).to_s.length", want = "3"},
	{text = "(-9223372036854775807 - 1).to_s.length", want = "20"},

	// indexing
	{text = "items[1].v", want = "11"},
	{text = "items[2].v + items[0].v", want = "22"},
	{text = "items[3].v", err = .Index_Out_Of_Range},
	{text = "items[-1].v", err = .Index_Out_Of_Range},
	{text = "hdr.tag[1]", want = "238"},
	{text = "hdr.tag[2]", err = .Index_Out_Of_Range},
	{text = "later", err = .Absent_Field},

	// methods
	{text = "items.first.v + items.last.v * 100", want = "1210"},
	{text = "hdr.tag.first + hdr.tag.last + hdr.tag.min + hdr.tag.max", want = "952"},
	{text = "(a == 5).to_i * 2 + (a == 4).to_i", want = "2"},
	{text = "a.to_i + hdr.n.to_i", want = "8"},

	// floats: an operation with one is on floats, and / of a float divides
	// exactly; .to_i rounds toward zero
	{text = "1.5 + 1", want = "2.5"},
	{text = "(a + 0.0) / 2", want = "2.5"},
	{text = "a / 2", want = "2"},
	{text = "24000. * 2 - 1e3", want = "47000"},
	{text = "1.5e1 == 15 and 15 == 1.5e1", want = "true"},
	{text = "a < 5.5 and 5.5 > a and a >= 5.0 and a != 5.5", want = "true"},
	{text = "-(a * 0.5)", want = "-2.5"},
	{text = "a == 5 ? 0.5 : 1.5", want = "0.5"},
	{text = "1 / 0.0 > 1e308", want = "true"},
	{text = "2.9.to_i", want = "2"},
	{text = "(-2.9).to_i", want = "-2"},
	{text = "(a / 2.0).to_i * 2", want = "4"},
	{text = "1e19.to_i == 10000000000000000000", want = "true"},
	{text = "2e19.to_i", err = .Integer_Overflow},
	{text = "(0.0 / 0).to_i", err = .Integer_Overflow},
	{text = "(a == 5 ? hdr.tag : [1, 2, 3]).size", want = "2"},
	{text = "(a == 4 ? hdr.tag : [1, 2, 3]).size", want = "3"},
	{text = "[0.5, 2][1] / 4", want = "0.5"},

	// integers are exact up to 2^64 - 1, as Kaitai's u8 values are
	{text = "9223372036854775808 + 1 == 9223372036854775809 and 9223372036854775808 - 1 == 9223372036854775807", want = "true"},
	{text = "18446744073709551615 + 1", err = .Integer_Overflow},
	{text = "0x8000_0000_0000_0000 * 2", err = .Integer_Overflow},
	{text = "0x8000_0000_0000_0000 >> 62", want = "2"},
	{text = "(0x8000_0000_0000_0000 | 1) & 3", want = "1"},
	{text = "18446744073709551615 / 2 == 9223372036854775807 and 18446744073709551615 % 10 == 5", want = "true"},
	{text = "-1 < 0x8000_0000_0000_0000 and 0x8000_0000_0000_0000 > 9223372036854775807", want = "true"},
	{text = "~0x8000_0000_0000_0000", err = .Integer_Overflow},
	{text = "-0x8000_0000_0000_0000 == -9223372036854775807 - 1", want = "true"},
	{text = "0x8000_0000_0000_0000.to_s == '9223372036854775808'", want = "true"},
	{text = "a.as<u8> + 0xffff_ffff_ffff_fffa == 18446744073709551615", want = "true"},
	{text = "[0x8000_0000_0000_0000, 1][0] > 1", want = "true"},

	// substring counts code points, clamped to the string; as<bytes> makes
	// bytes of integers
	{text = "'abcd'.substring(1, 3) == 'bc'", want = "true"},
	{text = `"\303\251xy".substring(1, 3) == "xy"`, want = "true"},
	{text = "'abc'.substring(1, 10) == 'bc' and 'abc'.substring(2, 1) == '' and 'abc'.substring(5, 9) == ''", want = "true"},
	{text = "'abc'.substring(-1, 2).length", err = .Index_Out_Of_Range},
	{text = "[a + 60, 66].as<bytes>[0] + [a + 60, 66].as<bytes>.size", want = "67"},
	{text = "[1, 2].as<bytes>.size", want = "2"},
	{text = "[a + 251].as<bytes>.size", err = .Integer_Overflow},
	{text = "[0.5, 2.5][a - 4]", want = "2.5"},

	// an integer among floats is a float, wherever it is
	{text = "[a, 1.5][0].to_i", want = "5"},
	{text = "[a, 1.5][0] / 2", want = "2.5"},
	{text = "[1.5, a][1] / 2", want = "2.5"},
	{text = "[0.5, 2, a][a - 3] / 2", want = "2.5"},
	{text = "[a, 0.5].first / 2 + [0.5, a].last / 2", want = "5.0"},
	{text = "[18446744073709551615, 0.5][0] > 1.0e19", want = "true"},
}

@(test)
expression_eval :: proc(t: ^testing.T) {
	for c in EVAL_CASES {
		p: Expr_Plan
		defer mdata.destroy_file_format(&p.ff)
		make_expr_plan(t, &p)

		// data is 1 byte when text gives the expected value, 2 when it does not
		check := fmt.tprintf("(%s) == (%s) ? 1 : 2", c.text, c.err == .None ? c.want : "0")
		e := must_compile(t, &p.ff, check, p.root)
		if e == nil do continue
		p.data.length = mdata.Rule_Length{expr = e}

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

// expression.constant, with which the compiler folds a size and a count
// (_sizeof), gives what the evaluator gives: each text is folded, and
// evaluated in a decode. A text it folds evaluates to that value; one it
// does not either fails or is beyond an int, as a size must fit one. Both
// follow mdata.int_binary and int_unary, so steps beyond an int are exact.
@(test)
expression_constant_as_eval :: proc(t: ^testing.T) {
	Case :: struct {
		text:   string,
		folded: bool, // constant gives a value
	}
	cases := [?]Case {
		{"7 / 2", true},
		{"7 / -2", true},
		{"-7 % 3", true},
		{"7 % -3", true},
		{"~0", true},
		{"0xff & -1", true},
		{"-1 ^ 0", true},
		{"1 << 62 >> 1", true},
		{"-9223372036854775808", true},
		{"(9223372036854775807 + 1) - 1", true},
		{"0xffff_ffff_ffff_ffff - 0xffff_ffff_ffff_fff0", true},
		{"(-9223372036854775807 - 1) / -1 - 1", true},
		{"18446744073709551615 >> 1", true},
		{"9223372036854775807 + 1", false},
		{"1 << 63", false},
		{"18446744073709551615", false},
		{"18446744073709551615 + 1", false},
		{"~18446744073709551615", false},
		{"-(-9223372036854775807 - 2)", false},
		{"1 / 0", false},
		{"1 % 0", false},
		{"1 << 64", false},
		{"1 << -1", false},
		{"3 << 63", false},
	}
	for c in cases {
		p: Expr_Plan
		defer mdata.destroy_file_format(&p.ff)
		make_expr_plan(t, &p)

		parsed, parse_err := expr.parse(c.text, arn.arena_allocator(&p.ff.arena))
		if !testing.expectf(t, parse_err.kind == .None, "%q: %v", c.text, parse_err.kind) {
			expr.destroy_error(&parse_err)
			continue
		}
		v, folded := expr.constant(parsed)
		testing.expectf(t, folded == c.folded, "%q: constant gives %v (%v), want it folded: %v", c.text, v, folded, c.folded)

		// data is 1 byte when the evaluator agrees, 2 when it does not
		check := folded ? fmt.tprintf("(%s) == %v ? 1 : 2", c.text, v) : fmt.tprintf("(%s) > 9223372036854775807 ? 1 : 2", c.text)
		e := must_compile(t, &p.ff, check, p.root)
		if e == nil do continue
		p.data.length = mdata.Rule_Length{expr = e}
		d: Decoded
		defer destroy_decoded(&d)
		decode_bytes(&p.ff, EXPR_INPUT, &d)
		if folded {
			testing.expectf(t, d.err.kind == .None && d.consumed == DATA_POS + 2, "%q: constant gives %v, the evaluator %v (consumed %v)", c.text, v, d.err.kind, d.consumed)
		} else {
			testing.expectf(t, d.err.kind != .None || d.consumed == DATA_POS + 2, "%q: constant gives none, the evaluator a value within an int", c.text)
		}
	}
}

// A field read past the end of the input fails with the reader's error,
// and a reference to a field whose value is absent fails with Absent_Field.
@(test)
expression_absent_set :: proc(t: ^testing.T) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	a := arn.arena_allocator(&ff.arena)

	// opt: present only when the input starts with 0x21
	opt := plan_node("opt", .Set, a, plan_node("n", .UInt8, a))
	opt.count = mdata.Marker_Count{markers = slice_marker(mdata.Marker{0, .UInt8, 0x21, .Little}, a)}
	data := plan_node("data", .Blob, a)
	ff.root = plan_node("r", .Set, a, opt, data)
	data.length = mdata.Rule_Length{expr = must_compile(t, &ff, "opt.n - 0x21", ff.root)}

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
slice_marker :: proc(m: mdata.Marker, a: mem.Allocator) -> []mdata.Marker {
	s := make([]mdata.Marker, 1, a)
	s[0] = m
	return s
}

// The text of resolved expressions names their fields by path.
@(test)
expression_resolved_text :: proc(t: ^testing.T) {
	p: Expr_Plan
	defer mdata.destroy_file_format(&p.ff)
	make_expr_plan(t, &p)

	e := must_compile(t, &p.ff, "_root.hdr.n + hdr.tag.size + items.size", p.root)
	if e != nil do testing.expect_value(t, expr.to_string(e, context.temp_allocator), "((_root.hdr.n + hdr.tag.size) + items.size)")

	e = must_compile(t, &p.ff, "_parent.a + n", p.root, p.hdr)
	if e != nil do testing.expect_value(t, expr.to_string(e, context.temp_allocator), "(_parent.a + n)")

	e = must_compile(t, &p.ff, "(1.5 + 2. + 1e3 + 1e20 + 0.1).to_i", p.root)
	if e != nil do testing.expect_value(t, expr.to_string(e, context.temp_allocator), "((((1.5 + 2.0) + 1000.0) + 1e+20) + 0.1).to_i")

	tag := p.hdr.children[1].length.(mdata.Rule_Length).expr
	testing.expect_value(t, expr.to_string(tag, context.temp_allocator), "(_parent.a - 3)")
}
