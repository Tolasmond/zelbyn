package tests

import dat "../gnrcrdr/data"
import "core:testing"

@(test)
reads_little_endian :: proc(t: ^testing.T) {
	data := []byte{0x34, 0x12, 0x78, 0x56, 0x34, 0x12}
	r: dat.Reader
	dat.reader_init(&r, data)

	v16, e16 := dat.read_u16(&r)
	testing.expect_value(t, e16, dat.Read_Error.None)
	testing.expect_value(t, v16, u16(0x1234))

	v32, e32 := dat.read_u32(&r)
	testing.expect_value(t, e32, dat.Read_Error.None)
	testing.expect_value(t, v32, u32(0x12345678))

	testing.expect_value(t, r.pos, 6)
	testing.expect_value(t, dat.remaining(&r), 0)
}

@(test)
reads_big_endian :: proc(t: ^testing.T) {
	data := []byte{0x34, 0x12, 0x78, 0x56, 0x34, 0x12}
	r: dat.Reader
	dat.reader_init(&r, data, .Big)

	v, err := dat.read_u16(&r)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, v, u16(0x3412))
}

@(test)
signed_values :: proc(t: ^testing.T) {
	data := []byte{0xFF, 0xFE, 0xFF}
	r: dat.Reader
	dat.reader_init(&r, data)

	v8, e8 := dat.read_i8(&r)
	testing.expect_value(t, e8, dat.Read_Error.None)
	testing.expect_value(t, v8, i8(-1))

	v16, e16 := dat.read_i16(&r)
	testing.expect_value(t, e16, dat.Read_Error.None)
	testing.expect_value(t, v16, i16(-2))
}

@(test)
eof_is_error_and_pos_unchanged :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3}
	r: dat.Reader
	dat.reader_init(&r, data)
	r.pos = 2

	_, err := dat.read_u16(&r)
	testing.expect_value(t, err, dat.Read_Error.Unexpected_EOF)
	testing.expect_value(t, r.pos, 2)

	v, err2 := dat.read_u8(&r)
	testing.expect_value(t, err2, dat.Read_Error.None)
	testing.expect_value(t, v, u8(3))
	testing.expect_value(t, r.pos, 3)
}

@(test)
eof_does_not_poison_reader :: proc(t: ^testing.T) {
	data := []byte{7, 8}
	r: dat.Reader
	dat.reader_init(&r, data)

	_, e1 := dat.read_bytes(&r, 2)
	testing.expect_value(t, e1, dat.Read_Error.None)

	_, e2 := dat.read_u8(&r)
	testing.expect_value(t, e2, dat.Read_Error.Unexpected_EOF)

	r.pos = 0
	v, e3 := dat.read_u8(&r)
	testing.expect_value(t, e3, dat.Read_Error.None)
	testing.expect_value(t, v, u8(7))
	testing.expect_value(t, len(r.data), 2)
}

@(test)
read_integer_types :: proc(t: ^testing.T) {
	data := []byte{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

	Case :: struct {
		type:  dat.Data_Type,
		value: int,
		size:  int,
	}
	cases := []Case {
		{.Int8, -1, 1},
		{.UInt8, 0xFF, 1},
		{.Int16, -1, 2},
		{.UInt16, 0xFFFF, 2},
		{.Int32, -1, 4},
		{.UInt32, 0xFFFF_FFFF, 4},
		{.Int64, -1, 8},
	}
	for c in cases {
		r: dat.Reader
		dat.reader_init(&r, data)
		v, err := dat.read_integer(&r, c.type)
		testing.expectf(t, err == .None, "%v: err = %v", c.type, err)
		testing.expectf(t, v == c.value, "%v: value = %v, want %v", c.type, v, c.value)
		testing.expectf(t, r.pos == c.size, "%v: pos = %v, want %v", c.type, r.pos, c.size)
	}

	unsupported := []dat.Data_Type{.UInt64, .Float32, .Float64, .String, .Blob, .Set}
	for type in unsupported {
		r: dat.Reader
		dat.reader_init(&r, data)
		_, err := dat.read_integer(&r, type)
		testing.expectf(t, err == .Unsupported_Type, "%v: err = %v", type, err)
		testing.expectf(t, r.pos == 0, "%v: pos = %v, want 0", type, r.pos)
	}
}

@(test)
peek_is_pure :: proc(t: ^testing.T) {
	data := []byte{10, 20, 30, 40}
	r: dat.Reader
	dat.reader_init(&r, data)
	r.pos = 1

	v, err := dat.peek_integer_at(&r, 3, .UInt8)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, v, int(data[3]))
	testing.expect_value(t, r.pos, 1)
}

@(test)
peek_out_of_range :: proc(t: ^testing.T) {
	data := []byte{10, 20, 30, 40}
	r: dat.Reader
	dat.reader_init(&r, data)

	_, e1 := dat.peek_integer_at(&r, -1, .UInt8)
	testing.expect_value(t, e1, dat.Read_Error.Offset_Out_Of_Range)

	_, e2 := dat.peek_integer_at(&r, 4, .UInt8)
	testing.expect_value(t, e2, dat.Read_Error.Offset_Out_Of_Range)

	_, e3 := dat.peek_integer_at(&r, 3, .UInt16)
	testing.expect_value(t, e3, dat.Read_Error.Unexpected_EOF)

	testing.expect_value(t, r.pos, 0)
}

@(test)
read_bytes_is_view :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3, 4}
	r: dat.Reader
	dat.reader_init(&r, data)

	b, err := dat.read_bytes(&r, 3)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, len(b), 3)
	testing.expect(t, raw_data(b) == raw_data(r.data), "read_bytes must return a view of r.data")

	_, e2 := dat.read_bytes(&r, 2)
	testing.expect_value(t, e2, dat.Read_Error.Unexpected_EOF)
	testing.expect_value(t, r.pos, 3)

	_, e3 := dat.read_bytes(&r, -1)
	testing.expect_value(t, e3, dat.Read_Error.Invalid_Length)
	testing.expect_value(t, r.pos, 3)
}

@(test)
read_string_drops_nul :: proc(t: ^testing.T) {
	data := []byte{'a', 0, 'b', 0}
	r: dat.Reader
	dat.reader_init(&r, data)

	s, err := dat.read_string(&r, 4)
	defer delete(s)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, s, "ab")
	testing.expect_value(t, r.pos, 4)

	r.pos = 0
	empty, e2 := dat.read_string(&r, 0)
	defer delete(empty)
	testing.expect_value(t, e2, dat.Read_Error.None)
	testing.expect_value(t, empty, "")
	testing.expect_value(t, r.pos, 0)
}
