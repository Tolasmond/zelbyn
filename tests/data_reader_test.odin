package tests

import dat "../gnrcrdr/data"
import "core:encoding/endian"
import "core:slice"
import "core:testing"

@(test)
reads_little_endian :: proc(t: ^testing.T) {
	data := []byte{0x34, 0x12, 0x78, 0x56, 0x34, 0x12}
	r: dat.Reader
	dat.reader_init(&r, data)

	v16, e16 := dat.read(&r, u16)
	testing.expect_value(t, e16, dat.Read_Error.None)
	testing.expect_value(t, v16, u16(0x1234))

	v32, e32 := dat.read(&r, u32)
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

	v, err := dat.read(&r, u16)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, v, u16(0x3412))
}

@(test)
signed_values :: proc(t: ^testing.T) {
	data := []byte{0xFF, 0xFE, 0xFF}
	r: dat.Reader
	dat.reader_init(&r, data)

	v8, e8 := dat.read(&r, i8)
	testing.expect_value(t, e8, dat.Read_Error.None)
	testing.expect_value(t, v8, i8(-1))

	v16, e16 := dat.read(&r, i16)
	testing.expect_value(t, e16, dat.Read_Error.None)
	testing.expect_value(t, v16, i16(-2))
}

@(test)
eof_is_error_and_pos_unchanged :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3}
	r: dat.Reader
	dat.reader_init(&r, data)
	r.pos = 2

	_, err := dat.read(&r, u16)
	testing.expect_value(t, err, dat.Read_Error.Unexpected_EOF)
	testing.expect_value(t, r.pos, 2)

	v, err2 := dat.read(&r, u8)
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

	_, e2 := dat.read(&r, u8)
	testing.expect_value(t, e2, dat.Read_Error.Unexpected_EOF)

	r.pos = 0
	v, e3 := dat.read(&r, u8)
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

// Reads a T from le (little-endian bytes) and from its reverse in a .Big reader;
// both must give want and consume exactly size_of(T) bytes.
@(private = "file")
check_read :: proc(t: ^testing.T, le: []byte, want: $T, loc := #caller_location) {
	for order in ([]endian.Byte_Order{.Little, .Big}) {
		buf: [8]byte
		n := copy(buf[:], le)
		if order == .Big do slice.reverse(buf[:n])

		r: dat.Reader
		dat.reader_init(&r, buf[:n], order)
		v, err := dat.read(&r, T)
		testing.expectf(t, err == .None, "%v %v: err = %v", typeid_of(T), order, err, loc = loc)
		testing.expectf(t, v == want, "%v %v: value = %v, want %v", typeid_of(T), order, v, want, loc = loc)
		testing.expectf(t, r.pos == size_of(T), "%v %v: pos = %v, want %v", typeid_of(T), order, r.pos, size_of(T), loc = loc)
	}
}

// One byte short of a T: must fail with .Unexpected_EOF and leave pos unchanged.
@(private = "file")
check_read_eof :: proc(t: ^testing.T, $T: typeid, loc := #caller_location) {
	buf: [8]byte
	r: dat.Reader
	dat.reader_init(&r, buf[:size_of(T) - 1])
	_, err := dat.read(&r, T)
	testing.expectf(t, err == .Unexpected_EOF, "%v: err = %v", typeid_of(T), err, loc = loc)
	testing.expectf(t, r.pos == 0, "%v: pos = %v, want 0", typeid_of(T), r.pos, loc = loc)
}

@(test)
read_numeric_types :: proc(t: ^testing.T) {
	check_read(t, {0xFE}, i8(-2))
	check_read(t, {0xFE}, u8(0xFE))
	check_read(t, {0xFE, 0xFF}, i16(-2))
	check_read(t, {0x34, 0x12}, u16(0x1234))
	check_read(t, {0xFE, 0xFF, 0xFF, 0xFF}, i32(-2))
	check_read(t, {0x78, 0x56, 0x34, 0x12}, u32(0x1234_5678))
	check_read(t, {0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}, i64(-2))
	check_read(t, {0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01}, u64(0x0123_4567_89AB_CDEF))
	check_read(t, {0x00, 0x00, 0xC0, 0x3F}, f32(1.5))
	check_read(t, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xC0}, f64(-2.25))
}

@(test)
read_eof_each_type :: proc(t: ^testing.T) {
	check_read_eof(t, i8)
	check_read_eof(t, u8)
	check_read_eof(t, i16)
	check_read_eof(t, u16)
	check_read_eof(t, i32)
	check_read_eof(t, u32)
	check_read_eof(t, i64)
	check_read_eof(t, u64)
	check_read_eof(t, f32)
	check_read_eof(t, f64)
}
