package tests

import arn "../gnrcrdr/arena"
import dat "../gnrcrdr/data"
import dmp "../gnrcrdr/dump"
import fld "../gnrcrdr/field"
import mdat "../gnrcrdr/metadata"
import "core:slice"
import "core:strings"
import "core:testing"

// A node's order is the byte order of its values, and expressions see the
// value as read in that order.
@(test)
decode_byte_order :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	a := arn.arena_allocator(&ff.arena)

	// n: u2be; le: u2le; data: n bytes
	n := plan_node(2, "n", .UInt16, a)
	n.order = .Big
	le := plan_node(3, "le", .UInt16, a)
	data := plan_node(4, "data", .Blob, a)
	ff.root = plan_node(1, "r", .Set, a, n, le, data)
	data.length = mdat.Rule_Length{expr = must_compile(t, &ff, "n", ff.root)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {0x00, 0x02, 0x34, 0x12, 0xaa, 0xbb}, &d)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, 6)

	r := root_instance(&ff, &d)
	testing.expect_value(t, field_values(r, 2)[0].(u16), 2)
	testing.expect_value(t, field_values(r, 3)[0].(u16), 0x1234)
	testing.expect_value(t, len(field_values(r, 4)[0].([]byte)), 2)
}

// One field f of type, with count elements, a fixed length for String and
// Blob, and check valid, decoded from input.
@(private = "file")
Check_Case :: struct {
	name:   string,
	type:   dat.Data_Type,
	count:  int,
	length: int,
	valid:  mdat.Valid,
	input:  []byte,
	err:    dat.Read_Error,
	path:   string, // where err is reported, at the start of the element
	offset: int,
}

@(private = "file")
CHECK_CASES := [?]Check_Case {
	{"eq", .UInt8, 1, 0, mdat.Valid_Eq{u8(33)}, {33}, .None, "", 0},
	{"not eq", .UInt8, 1, 0, mdat.Valid_Eq{u8(33)}, {34}, .Not_Equal, "r[0].f[0]", 0},
	{"second element", .UInt8, 2, 0, mdat.Valid_Eq{u8(7)}, {7, 8}, .Not_Equal, "r[0].f[1]", 1},
	{"min", .Int16, 1, 0, mdat.Valid_Range{i16(-5), i16(5)}, {0xfb, 0xff}, .None, "", 0},
	{"below min", .Int16, 1, 0, mdat.Valid_Range{i16(-5), i16(5)}, {0xfa, 0xff}, .Less_Than_Min, "r[0].f[0]", 0},
	{"above max", .Int16, 1, 0, mdat.Valid_Range{i16(-5), i16(5)}, {0x06, 0x00}, .Greater_Than_Max, "r[0].f[0]", 0},
	{"min only", .UInt32, 1, 0, mdat.Valid_Range{min = u32(10)}, {9, 0, 0, 0}, .Less_Than_Min, "r[0].f[0]", 0},
	{"max only", .UInt32, 1, 0, mdat.Valid_Range{max = u32(10)}, {0xff, 0, 0, 0}, .Greater_Than_Max, "r[0].f[0]", 0},
	{"any of", .UInt8, 1, 0, mdat.Valid_Any_Of{{u8(1), u8(3)}}, {3}, .None, "", 0},
	{"none of", .UInt8, 1, 0, mdat.Valid_Any_Of{{u8(1), u8(3)}}, {2}, .Not_Any_Of, "r[0].f[0]", 0},
	{"float in range", .Float32, 1, 0, mdat.Valid_Range{f32(0), f32(1)}, {0x00, 0x00, 0x00, 0x3f}, .None, "", 0}, // 0.5
	{"NaN in no range", .Float32, 1, 0, mdat.Valid_Range{f32(0), f32(1)}, {0x00, 0x00, 0xc0, 0x7f}, .Less_Than_Min, "r[0].f[0]", 0},
	{"string eq", .String, 1, 3, mdat.Valid_Eq{"GIF"}, {'G', 'I', 'F'}, .None, "", 0},
	{"string not eq", .String, 1, 3, mdat.Valid_Eq{"GIF"}, {'G', 'I', 'G'}, .Not_Equal, "r[0].f[0]", 0},
	{"contents", .Blob, 1, 2, mdat.Valid_Eq{[]byte{1, 2}}, {1, 2}, .None, "", 0},
	{"not contents", .Blob, 1, 2, mdat.Valid_Eq{[]byte{1, 2}}, {1, 3}, .Not_Equal, "r[0].f[0]", 0},
	{"blob any of", .Blob, 1, 1, mdat.Valid_Any_Of{{[]byte{1}, []byte{2}}}, {2}, .None, "", 0},
	{"blob none of", .Blob, 1, 1, mdat.Valid_Any_Of{{[]byte{1}, []byte{2}}}, {3}, .Not_Any_Of, "r[0].f[0]", 0},
}

@(test)
decode_checks :: proc(t: ^testing.T) {
	for c in CHECK_CASES {
		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		a := arn.arena_allocator(&ff.arena)

		f := plan_node(2, "f", c.type, a)
		f.count = mdat.Fixed_Count{c.count}
		f.valid = c.valid
		if c.type == .String || c.type == .Blob do f.length = mdat.Fixed_Length{c.length}
		ff.root = plan_node(1, "r", .Set, a, f)

		d: Decoded
		defer destroy_decoded(&d)
		decode_bytes(&ff, c.input, &d)

		testing.expectf(
			t,
			d.err.kind == c.err && d.err.path == c.path && d.err.offset == c.offset,
			"%s: %v at %v (%q), want %v at %v (%q)",
			c.name, d.err.kind, d.err.offset, d.err.path, c.err, c.offset, c.path,
		)
	}
}

// p (an i8, two elements) has the bit fields lo (bits 0-3, a u1) and hi
// (bits 4-7, an s4), and w (a u8) has top (bits 60-63) and all (0-63).
@(private = "file")
make_bits_plan :: proc(ff: ^mdat.File_Format) -> (p: ^mdat.Node) {
	a := arn.arena_allocator(&ff.arena)

	p = plan_node(2, "p", .Int8, a)
	p.count = mdat.Fixed_Count{2}
	p.bits = slice.clone([]mdat.Bit_Field{{id = 3, name = "lo", type = .UInt8, low = 0, high = 3}, {id = 4, name = "hi", type = .Int32, low = 4, high = 7}}, a)

	w := plan_node(5, "w", .UInt64, a)
	w.bits = slice.clone([]mdat.Bit_Field{{id = 6, name = "top", type = .UInt8, low = 60, high = 63}, {id = 7, name = "all", type = .UInt64, low = 0, high = 63}}, a)

	ff.name = "r"
	ff.root = plan_node(1, "r", .Set, a, p, w)
	return
}

@(private = "file")
BITS_INPUT :: []byte{0xa5, 0x0f, 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0xf1}

@(test)
decode_bit_fields :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	make_bits_plan(&ff)

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, BITS_INPUT, &d)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v (%s)", d.err.kind, d.err.offset, d.err.path) do return

	r := root_instance(&ff, &d)
	Want :: struct {
		id:     int,
		values: []fld.Value,
	}
	for w in ([?]Want {
		{2, {i8(-91), i8(0x0f)}},
		{3, {u8(0x5), u8(0xf)}},
		{4, {i32(0xa), i32(0)}},
		{6, {u8(0xf)}},
		{7, {u64(0xf123_4567_89ab_cdef)}},
	}) {
		got := field_values(r, w.id)
		if !testing.expectf(t, len(got) == len(w.values), "field %v: %v values, want %v", w.id, len(got), len(w.values)) do continue
		for v, i in got {
			testing.expectf(t, variant_equal(v, w.values[i]), "field %v[%v] = %v (%T), want %v (%T)", w.id, i, v, v, w.values[i], w.values[i])
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

// A bit field's check fails at the start of the integer it is part of.
@(test)
decode_bit_field_check :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	p := make_bits_plan(&ff)
	p.bits[0].valid = mdat.Valid_Range{max = u8(14)}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, BITS_INPUT, &d)

	testing.expect_value(t, d.err.kind, dat.Read_Error.Greater_Than_Max)
	testing.expect_value(t, d.err.offset, 1)
	testing.expect_value(t, d.err.path, "r[0].lo[1]")
}
