package tests

import dat "../zelbyn/data"
import "core:encoding/endian"
import "core:slice"
import "core:testing"

@(test)
reads_little_endian :: proc(t: ^testing.T) {
	data := []byte{0x34, 0x12, 0x78, 0x56, 0x34, 0x12}
	r: dat.Reader
	dat.reader_init(&r, data)

	v16, e16 := dat.read(&r, u16, .Little)
	testing.expect_value(t, e16, dat.Read_Error.None)
	testing.expect_value(t, v16, u16(0x1234))

	v32, e32 := dat.read(&r, u32, .Little)
	testing.expect_value(t, e32, dat.Read_Error.None)
	testing.expect_value(t, v32, u32(0x12345678))

	testing.expect_value(t, r.pos, 6)
	testing.expect_value(t, dat.remaining(&r), 0)
}

@(test)
reads_big_endian :: proc(t: ^testing.T) {
	data := []byte{0x34, 0x12, 0x78, 0x56, 0x34, 0x12}
	r: dat.Reader
	dat.reader_init(&r, data)

	v, err := dat.read(&r, u16, .Big)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, v, u16(0x3412))
}

@(test)
signed_values :: proc(t: ^testing.T) {
	data := []byte{0xFF, 0xFE, 0xFF}
	r: dat.Reader
	dat.reader_init(&r, data)

	v8, e8 := dat.read(&r, i8, .Little)
	testing.expect_value(t, e8, dat.Read_Error.None)
	testing.expect_value(t, v8, i8(-1))

	v16, e16 := dat.read(&r, i16, .Little)
	testing.expect_value(t, e16, dat.Read_Error.None)
	testing.expect_value(t, v16, i16(-2))
}

@(test)
eof_is_error_and_pos_unchanged :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3}
	r: dat.Reader
	dat.reader_init(&r, data)
	r.pos = 2

	_, err := dat.read(&r, u16, .Little)
	testing.expect_value(t, err, dat.Read_Error.Unexpected_EOF)
	testing.expect_value(t, r.pos, 2)

	v, err2 := dat.read(&r, u8, .Little)
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

	_, e2 := dat.read(&r, u8, .Little)
	testing.expect_value(t, e2, dat.Read_Error.Unexpected_EOF)

	r.pos = 0
	v, e3 := dat.read(&r, u8, .Little)
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
		v, err := dat.read_integer(&r, c.type, .Little)
		testing.expectf(t, err == .None, "%v: err = %v", c.type, err)
		testing.expectf(t, v == c.value, "%v: value = %v, want %v", c.type, v, c.value)
		testing.expectf(t, r.pos == c.size, "%v: pos = %v, want %v", c.type, r.pos, c.size)
	}

	unsupported := []dat.Data_Type{.UInt64, .Float32, .Float64, .String, .Blob, .Set}
	for type in unsupported {
		r: dat.Reader
		dat.reader_init(&r, data)
		_, err := dat.read_integer(&r, type, .Little)
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

	v, err := dat.peek_integer_at(&r, 3, .UInt8, .Little)
	testing.expect_value(t, err, dat.Read_Error.None)
	testing.expect_value(t, v, int(data[3]))
	testing.expect_value(t, r.pos, 1)
}

@(test)
peek_out_of_range :: proc(t: ^testing.T) {
	data := []byte{10, 20, 30, 40}
	r: dat.Reader
	dat.reader_init(&r, data)

	_, e1 := dat.peek_integer_at(&r, -1, .UInt8, .Little)
	testing.expect_value(t, e1, dat.Read_Error.Offset_Out_Of_Range)

	_, e2 := dat.peek_integer_at(&r, 4, .UInt8, .Little)
	testing.expect_value(t, e2, dat.Read_Error.Offset_Out_Of_Range)

	_, e3 := dat.peek_integer_at(&r, 3, .UInt16, .Little)
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

// Reads a T from le (little-endian bytes), and from its reverse as .Big;
// both must give want and consume exactly size_of(T) bytes.
@(private = "file")
check_read :: proc(t: ^testing.T, le: []byte, want: $T, loc := #caller_location) {
	for order in ([]endian.Byte_Order{.Little, .Big}) {
		buf: [8]byte
		n := copy(buf[:], le)
		if order == .Big do slice.reverse(buf[:n])

		r: dat.Reader
		dat.reader_init(&r, buf[:n])
		v, err := dat.read(&r, T, order)
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
	_, err := dat.read(&r, T, .Little)
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

// read_bits as Kaitai's C++ runtime reads them, in both orders: a 64-bit
// read with bits left over takes 8 more bytes; the bits a byte read skips
// stay for the next bit read; align_to_byte discards them.
@(test)
read_bits_both_orders :: proc(t: ^testing.T) {
	data := []byte{0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xff, 0x5a, 0x0f}
	Step :: struct {
		n:         int,
		want:      u64,
		pos, left: int,
	}
	Case :: struct {
		order:    endian.Byte_Order,
		steps:    []Step,
		leftover: u64, // the 5 bits of 0x5a left after the last step
	}
	for c in ([?]Case {
		{.Big, {{4, 0xa, 1, 4}, {64, 0xbcde_f012_3456_789f, 9, 4}, {4, 0xf, 9, 0}, {3, 0x2, 10, 5}}, 0x1a},
		{.Little, {{4, 0xb, 1, 4}, {64, 0xf896_7452_301e_fcda, 9, 4}, {4, 0xf, 9, 0}, {3, 0x2, 10, 5}}, 0x0b},
	}) {
		r: dat.Reader
		dat.reader_init(&r, data)
		for s in c.steps {
			v, err := dat.read_bits(&r, s.n, c.order)
			testing.expectf(t, err == .None && v == s.want && r.pos == s.pos && r.bits_left == s.left, "%v, %v bits: %x (%v) at %v with %v left, want %x at %v with %v left", c.order, s.n, v, err, r.pos, r.bits_left, s.want, s.pos, s.left)
		}

		// a byte read leaves the bits, and the next bit read uses them
		b, err := dat.read(&r, u8, .Little)
		testing.expect(t, err == .None && b == 0x0f && r.bits_left == 5, "a byte read used the bits left over")
		v, _ := dat.read_bits(&r, 5, c.order)
		testing.expectf(t, v == c.leftover, "%v: the bits left over gave %x, want %x", c.order, v, c.leftover)
		testing.expect(t, dat.at_eof(&r), "not at the end once every bit is read")
	}

	// past the end: an error, and the reader is unchanged
	r: dat.Reader
	dat.reader_init(&r, data[10:])
	_, _ = dat.read_bits(&r, 4, .Big)
	testing.expect(t, !dat.at_eof(&r), "at the end with 4 bits left")
	_, err := dat.read_bits(&r, 9, .Big)
	testing.expect(t, err == .Unexpected_EOF && r.pos == 1 && r.bits_left == 4 && r.bits == 0xf, "a failed bit read changed the reader")
	dat.align_to_byte(&r)
	testing.expect(t, dat.at_eof(&r) && dat.bit_pos(&r) == 8, "align_to_byte kept bits")
}
