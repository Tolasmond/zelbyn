package data

import "core:encoding/endian"

Read_Error :: enum {
	None,
	Unexpected_EOF,        // a read needs more bytes than remain
	Offset_Out_Of_Range,   // a computed absolute/relative peek offset is outside [0, len(data))
	Unsupported_Type,      // the data type cannot be read as an integer (Set, UInt64, floats, String, Blob)
	Invalid_Length,        // a computed count/length is negative, or outside [MinBufferLength, MaxBufferLength]
	Repeat_Limit_Exceeded, // a set count exceeds the set's MaxArrayLength
	No_Progress,           // a repeated (grow-as-needed) set instance consumed zero bytes
	Invalid_Schema,        // metadata needed for decoding is missing (nil lookup, String without MaxBufferLength)
	File_Read_Failed,      // the input file could not be read
}

// Bounds-checked cursor over a byte slice. Every read either succeeds and
// advances pos, or fails and leaves the reader unchanged.
Reader :: struct {
	data:  []byte,
	pos:   int,
	order: endian.Byte_Order,
}

reader_init :: proc(r: ^Reader, data: []byte, order := endian.Byte_Order.Little) {
	r^ = Reader{data = data, order = order}
}

remaining :: proc(r: ^Reader) -> int {
	return len(r.data) - r.pos
}

// Advances past n bytes and returns them. Leaves r unchanged on error.
@(private)
take :: proc(r: ^Reader, n: int) -> (b: []byte, err: Read_Error) {
	if n < 0 do return nil, .Invalid_Length
	if n > len(r.data) - r.pos do return nil, .Unexpected_EOF
	b = r.data[r.pos:][:n]
	r.pos += n
	return
}

read_i8 :: proc(r: ^Reader) -> (value: i8, err: Read_Error) {
	b := take(r, 1) or_return
	return i8(b[0]), .None
}

read_u8 :: proc(r: ^Reader) -> (value: u8, err: Read_Error) {
	b := take(r, 1) or_return
	return b[0], .None
}

read_i16 :: proc(r: ^Reader) -> (value: i16, err: Read_Error) {
	b := take(r, 2) or_return
	value, _ = endian.get_i16(b, r.order)
	return
}

read_u16 :: proc(r: ^Reader) -> (value: u16, err: Read_Error) {
	b := take(r, 2) or_return
	value, _ = endian.get_u16(b, r.order)
	return
}

read_i32 :: proc(r: ^Reader) -> (value: i32, err: Read_Error) {
	b := take(r, 4) or_return
	value, _ = endian.get_i32(b, r.order)
	return
}

read_u32 :: proc(r: ^Reader) -> (value: u32, err: Read_Error) {
	b := take(r, 4) or_return
	value, _ = endian.get_u32(b, r.order)
	return
}

read_i64 :: proc(r: ^Reader) -> (value: i64, err: Read_Error) {
	b := take(r, 8) or_return
	value, _ = endian.get_i64(b, r.order)
	return
}

read_u64 :: proc(r: ^Reader) -> (value: u64, err: Read_Error) {
	b := take(r, 8) or_return
	value, _ = endian.get_u64(b, r.order)
	return
}

read_f32 :: proc(r: ^Reader) -> (value: f32, err: Read_Error) {
	b := take(r, 4) or_return
	value, _ = endian.get_f32(b, r.order)
	return
}

read_f64 :: proc(r: ^Reader) -> (value: f64, err: Read_Error) {
	b := take(r, 8) or_return
	value, _ = endian.get_f64(b, r.order)
	return
}

// Reads an integer-typed value as int. Non-integer types return
// .Unsupported_Type without consuming anything.
read_integer :: proc(r: ^Reader, data_type: Data_Type) -> (value: int, err: Read_Error) {
	switch data_type {
	case .Int8:
		v := read_i8(r) or_return
		value = int(v)
	case .UInt8:
		v := read_u8(r) or_return
		value = int(v)
	case .Int16:
		v := read_i16(r) or_return
		value = int(v)
	case .UInt16:
		v := read_u16(r) or_return
		value = int(v)
	case .Int32:
		v := read_i32(r) or_return
		value = int(v)
	case .UInt32:
		v := read_u32(r) or_return
		value = int(v)
	case .Int64:
		v := read_i64(r) or_return
		value = int(v)
	case .Set, .UInt64, .Float32, .Float64, .String, .Blob:
		err = .Unsupported_Type
	}
	return
}

// Returns a view of the next n bytes; nothing is allocated. Clone the result
// to keep it beyond the lifetime of r.data.
read_bytes :: proc(r: ^Reader, n: int) -> ([]byte, Read_Error) {
	return take(r, n)
}

// Reads n bytes as a string, dropping every 0x00 byte. The result is owned
// and allocated with allocator.
read_string :: proc(r: ^Reader, n: int, allocator := context.allocator) -> (value: string, err: Read_Error) {
	b := take(r, n) or_return

	non_nul := 0
	for c in b {
		if c != 0 do non_nul += 1
	}

	if non_nul == 0 do return "", .None

	buf := make([]byte, non_nul, allocator)
	i := 0
	for c in b {
		if c != 0 {
			buf[i] = c
			i += 1
		}
	}

	return string(buf), .None
}

// Reads an integer at absolute position pos without changing r.
peek_integer_at :: proc(r: ^Reader, pos: int, data_type: Data_Type) -> (int, Read_Error) {
	if pos < 0 || pos >= len(r.data) do return 0, .Offset_Out_Of_Range
	tmp := r^
	tmp.pos = pos
	return read_integer(&tmp, data_type)
}
