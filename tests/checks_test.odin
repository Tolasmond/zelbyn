package tests

import arn "../zelbyn/arena"
import dat "../zelbyn/data"
import dmp "../zelbyn/dump"
import fld "../zelbyn/field"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

// A node's order is the byte order of its values, and expressions see the
// value as read in that order.
@(test)
decode_byte_order :: proc(t: ^testing.T) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	a := arn.arena_allocator(&ff.arena)

	// n: u2be; le: u2le; data: n bytes
	n := plan_node("n", .UInt16, a)
	n.order = .Big
	le := plan_node("le", .UInt16, a)
	data := plan_node("data", .Blob, a)
	ff.root = plan_node("r", .Set, a, n, le, data)
	data.length = mdata.Rule_Length{expr = must_compile(t, &ff, "n", ff.root)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {0x00, 0x02, 0x34, 0x12, 0xaa, 0xbb}, &d)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, 6)

	r := root_instance(&ff, &d)
	testing.expect_value(t, field_values(r, "n")[0].(u16), 2)
	testing.expect_value(t, field_values(r, "le")[0].(u16), 0x1234)
	testing.expect_value(t, len(field_values(r, "data")[0].([]byte)), 2)
}

// One field f of type, with count elements, a fixed length for String and
// Blob, and check valid, decoded from input, and the error it gives.
@(private = "file")
Check_Case :: struct {
	name:     string,
	type:     dat.Data_Type,
	count:    int,
	length:   int,
	valid:    mdata.Valid,
	input:    []byte,
	err:      dat.Read_Error,
	path:     string, // where err is reported, at the start of the element
	offset:   int,
	value:    string, // what the error shows as read (Parse_Error.value)
	expected: string, // and as expected
}

@(private = "file")
CHECK_CASES := [?]Check_Case {
	{"eq", .UInt8, 1, 0, mdata.Valid_Eq{u8(33)}, {33}, .None, "", 0, ``, ``},
	{"not eq", .UInt8, 1, 0, mdata.Valid_Eq{u8(33)}, {34}, .Not_Equal, "r[0].f[0]", 0, `34`, `33`},
	{"second element", .UInt8, 2, 0, mdata.Valid_Eq{u8(7)}, {7, 8}, .Not_Equal, "r[0].f[1]", 1, `8`, `7`},
	{"min", .Int16, 1, 0, mdata.Valid_Range{i16(-5), i16(5)}, {0xfb, 0xff}, .None, "", 0, ``, ``},
	{"below min", .Int16, 1, 0, mdata.Valid_Range{i16(-5), i16(5)}, {0xfa, 0xff}, .Less_Than_Min, "r[0].f[0]", 0, `-6`, `-5`},
	{"above max", .Int16, 1, 0, mdata.Valid_Range{i16(-5), i16(5)}, {0x06, 0x00}, .Greater_Than_Max, "r[0].f[0]", 0, `6`, `5`},
	{"min only", .UInt32, 1, 0, mdata.Valid_Range{min = u32(10)}, {9, 0, 0, 0}, .Less_Than_Min, "r[0].f[0]", 0, `9`, `10`},
	{"max only", .UInt32, 1, 0, mdata.Valid_Range{max = u32(10)}, {0xff, 0, 0, 0}, .Greater_Than_Max, "r[0].f[0]", 0, `255`, `10`},
	{"any of", .UInt8, 1, 0, mdata.Valid_Any_Of{{u8(1), u8(3)}}, {3}, .None, "", 0, ``, ``},
	{"none of", .UInt8, 1, 0, mdata.Valid_Any_Of{{u8(1), u8(3)}}, {2}, .Not_Any_Of, "r[0].f[0]", 0, `2`, `1, 3`},
	{"float in range", .Float32, 1, 0, mdata.Valid_Range{f32(0), f32(1)}, {0x00, 0x00, 0x00, 0x3f}, .None, "", 0, ``, ``}, // 0.5
	{"NaN in no range", .Float32, 1, 0, mdata.Valid_Range{f32(0), f32(1)}, {0x00, 0x00, 0xc0, 0x7f}, .Less_Than_Min, "r[0].f[0]", 0, `NaN`, `0`},
	{"string eq", .String, 1, 3, mdata.Valid_Eq{"ABC"}, {'A', 'B', 'C'}, .None, "", 0, ``, ``},
	{"string not eq", .String, 1, 3, mdata.Valid_Eq{"ABC"}, {'A', 'B', 'D'}, .Not_Equal, "r[0].f[0]", 0, `"ABD"`, `"ABC"`},
	{"contents", .Blob, 1, 2, mdata.Valid_Eq{[]byte{1, 2}}, {1, 2}, .None, "", 0, ``, ``},
	{"not contents", .Blob, 1, 2, mdata.Valid_Eq{[]byte{1, 2}}, {1, 3}, .Not_Equal, "r[0].f[0]", 0, `<2 bytes> 01 03`, `<2 bytes> 01 02`},
	{"blob any of", .Blob, 1, 1, mdata.Valid_Any_Of{{[]byte{1}, []byte{2}}}, {2}, .None, "", 0, ``, ``},
	{"blob none of", .Blob, 1, 1, mdata.Valid_Any_Of{{[]byte{1}, []byte{2}}}, {3}, .Not_Any_Of, "r[0].f[0]", 0, `<1 bytes> 03`, `<1 bytes> 01, <1 bytes> 02`},
	{"in enum", .UInt8, 1, 0, mdata.Valid_In_Enum{{0, 5}}, {5}, .None, "", 0, ``, ``},
	{"not in enum", .UInt8, 1, 0, mdata.Valid_In_Enum{{0, 5}}, {2}, .Not_In_Enum, "r[0].f[0]", 0, `2`, `0, 5`},
}

@(test)
decode_checks :: proc(t: ^testing.T) {
	for c in CHECK_CASES {
		ff: mdata.File_Format
		defer mdata.destroy_file_format(&ff)
		a := arn.arena_allocator(&ff.arena)

		f := plan_node("f", c.type, a)
		f.count = mdata.Fixed_Count{n = c.count}
		f.valid = c.valid
		if c.type == .String || c.type == .Blob do f.length = mdata.Fixed_Length{c.length}
		ff.root = plan_node("r", .Set, a, f)

		d: Decoded
		defer destroy_decoded(&d)
		decode_bytes(&ff, c.input, &d)

		testing.expectf(
			t,
			d.err.kind == c.err && d.err.path == c.path && d.err.offset == c.offset && d.err.value == c.value && d.err.expected == c.expected,
			"%s: %v at %v (%q), read %q, expected %q; want %v at %v (%q), read %q, expected %q",
			c.name, d.err.kind, d.err.offset, d.err.path, d.err.value, d.err.expected, c.err, c.offset, c.path, c.value, c.expected,
		)
	}
}

// A failed check shows a string's first STRING_PREVIEW characters, a
// blob's first BLOB_PREVIEW bytes and a list's first LIST_PREVIEW values,
// each followed by " ..." or ", ..." when there are more, and only those.
@(test)
decode_check_values_shortened :: proc(t: ^testing.T) {
	long_string := strings.repeat("é", rdr.STRING_PREVIEW + 1, context.temp_allocator)
	long_blob := make([]byte, fld.BLOB_PREVIEW + 1, context.temp_allocator)
	for &b, i in long_blob do b = byte(i)
	list := make([]mdata.Scalar, rdr.LIST_PREVIEW + 1, context.temp_allocator)
	for &x, i in list do x = u8(i)
	exact := make([]mdata.Scalar, rdr.LIST_PREVIEW, context.temp_allocator)
	for &x, i in exact do x = u8(i)
	digits := make([]string, rdr.LIST_PREVIEW, context.temp_allocator)
	for &x, i in digits do x = fmt.tprint(i)

	Case :: struct {
		name:            string,
		type:            dat.Data_Type,
		valid:           mdata.Valid,
		input:           []byte,
		value, expected: string,
	}
	cases := [?]Case {
		{"a string", .String, mdata.Valid_Eq{"x"}, transmute([]byte)long_string, fmt.tprintf("%q ...", long_string[:2 * rdr.STRING_PREVIEW]), `"x"`},
		{"a blob", .Blob, mdata.Valid_Eq{[]byte{1}}, long_blob, "<17 bytes> 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f ...", "<1 bytes> 01"},
		{"a list", .UInt8, mdata.Valid_Any_Of{list}, {200}, "200", strings.concatenate({strings.join(digits, ", ", context.temp_allocator), ", ..."}, context.temp_allocator)},
		{"a list of LIST_PREVIEW", .UInt8, mdata.Valid_Any_Of{exact}, {200}, "200", strings.join(digits, ", ", context.temp_allocator)},
	}
	for c in cases {
		ff: mdata.File_Format
		defer mdata.destroy_file_format(&ff)
		a := arn.arena_allocator(&ff.arena)
		f := plan_node("f", c.type, a)
		f.count = mdata.Fixed_Count{n = 1}
		f.valid = c.valid
		if c.type != .UInt8 do f.length = mdata.Fixed_Length{len(c.input)}
		ff.root = plan_node("r", .Set, a, f)

		d: Decoded
		defer destroy_decoded(&d)
		decode_bytes(&ff, c.input, &d)
		testing.expectf(t, d.err.value == c.value && d.err.expected == c.expected, "%s: read %q, expected %q; want %q and %q", c.name, d.err.value, d.err.expected, c.value, c.expected)
	}
}

// p (an i8, two elements) has the bit fields lo (bits 0-3, a u1) and hi
// (bits 4-7, an s4), and w (a u8) has top (bits 60-63) and all (0-63).
@(private = "file")
make_bits_plan :: proc(ff: ^mdata.File_Format) -> (p: ^mdata.Node) {
	a := arn.arena_allocator(&ff.arena)

	p = plan_node("p", .Int8, a)
	p.count = mdata.Fixed_Count{n = 2}
	p.bits = slice.clone([]mdata.Bit_Field{{name = "lo", type = .UInt8, low = 0, high = 3}, {name = "hi", type = .Int32, low = 4, high = 7}}, a)

	w := plan_node("w", .UInt64, a)
	w.bits = slice.clone([]mdata.Bit_Field{{name = "top", type = .UInt8, low = 60, high = 63}, {name = "all", type = .UInt64, low = 0, high = 63}}, a)

	ff.name = "r"
	ff.root = plan_node("r", .Set, a, p, w)
	return
}

@(private = "file")
BITS_INPUT :: []byte{0xa5, 0x0f, 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0xf1}

@(test)
decode_bit_fields :: proc(t: ^testing.T) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	make_bits_plan(&ff)

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, BITS_INPUT, &d)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return

	r := root_instance(&ff, &d)
	Want :: struct {
		name:   string,
		values: []fld.Value,
	}
	for w in ([?]Want {
		{"p", {i8(-91), i8(0x0f)}},
		{"lo", {u8(0x5), u8(0xf)}},
		{"hi", {i32(0xa), i32(0)}},
		{"top", {u8(0xf)}},
		{"all", {u64(0xf123_4567_89ab_cdef)}},
	}) {
		got := field_values(r, w.name)
		if !testing.expectf(t, len(got) == len(w.values), "field %v: %v values, want %v", w.name, len(got), len(w.values)) do continue
		for v, i in got {
			testing.expectf(t, variant_equal(v, w.values[i]), "field %v[%v] = %v (%T), want %v (%T)", w.name, i, v, v, w.values[i], w.values[i])
		}
	}

	// bit fields follow their integer field in both dumps
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	testing.expect(t, dmp.write_text(strings.to_writer(&text), &ff, &d.tree) == .None, "write_text failed")
	testing.expect_value(
		t,
		strings.to_string(text),
		"r[0].p[0] = -91\nr[0].p[1] = 15\nr[0].lo[0] = 5\nr[0].lo[1] = 15\nr[0].hi[0] = 10\nr[0].hi[1] = 0\n" +
		"r[0].w[0] = 17375808098319191535\nr[0].top[0] = 15\nr[0].all[0] = 17375808098319191535\n",
	)

	json := strings.builder_make()
	defer strings.builder_destroy(&json)
	testing.expect(t, dmp.write_json(strings.to_writer(&json), &ff, &d.tree) == .None, "write_json failed")
	testing.expect_value(
		t,
		strings.to_string(json),
		`{"r":[{"p":[-91,15],"lo":[5,15],"hi":[10,0],"w":[17375808098319191535],"top":[15],"all":[17375808098319191535]}]}` + "\n",
	)
}

// A bit field's check fails at the start of the integer it is part of,
// with the bit field's value.
@(test)
decode_bit_field_check :: proc(t: ^testing.T) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	p := make_bits_plan(&ff)
	p.bits[0].valid = mdata.Valid_Range{max = u8(14)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, BITS_INPUT, &d)

	testing.expect_value(t, d.err.kind, dat.Read_Error.Greater_Than_Max)
	testing.expect_value(t, d.err.offset, 1)
	testing.expect_value(t, d.err.path, "r[0].lo[1]")
	testing.expect_value(t, d.err.value, "15")
	testing.expect_value(t, d.err.expected, "14")
}
