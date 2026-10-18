package data

import "base:intrinsics"
import "core:encoding/endian"

Read_Error :: enum {
	None,
	Unexpected_EOF,        // a read needs more bytes than remain
	Offset_Out_Of_Range,   // a computed absolute/relative peek offset is outside [0, len(data))
	Unsupported_Type,      // the data type cannot be read as an integer (Set, UInt64, floats, String, Blob)
	Invalid_Length,        // a computed count/length is negative, or outside [MinBufferLength, MaxBufferLength]
	Repeat_Limit_Exceeded, // a set count exceeds the set's MaxArrayLength
	No_Progress,           // a repeated (grow-as-needed) set instance consumed zero bytes
	Division_By_Zero,      // an expression divides by zero, or takes a remainder by zero
	Integer_Overflow,      // an expression's result, or an integer field it reads, does not fit in an int
	Invalid_Shift,         // an expression shifts by a negative amount or by 64 or more
	Absent_Field,          // an expression refers to a field that has no value (not read yet, or absent)
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
@(private, require_results)
take :: proc(r: ^Reader, n: int) -> (b: []byte, err: Read_Error) {
	if n < 0 do return nil, .Invalid_Length
	if n > len(r.data) - r.pos do return nil, .Unexpected_EOF
	b = r.data[r.pos:][:n]
	r.pos += n
	return
}

// Reads a value of type T in r.order. Leaves r unchanged on error.
@(require_results)
read :: proc(r: ^Reader, $T: typeid) -> (value: T, err: Read_Error)
	where intrinsics.type_is_integer(T) || intrinsics.type_is_float(T), intrinsics.type_is_endian_platform(T) {
	b := take(r, size_of(T)) or_return
	value = intrinsics.unaligned_load((^T)(raw_data(b)))
	when size_of(T) > 1 {
		if r.order != endian.PLATFORM_BYTE_ORDER do value = intrinsics.byte_swap(value)
	}
	return
}

// Reads an integer-typed value as int. Non-integer types return
// .Unsupported_Type without consuming anything.
@(require_results)
read_integer :: proc(r: ^Reader, data_type: Data_Type) -> (value: int, err: Read_Error) {
	switch data_type {
	case .Int8:
		v := read(r, i8) or_return
		value = int(v)
	case .UInt8:
		v := read(r, u8) or_return
		value = int(v)
	case .Int16:
		v := read(r, i16) or_return
		value = int(v)
	case .UInt16:
		v := read(r, u16) or_return
		value = int(v)
	case .Int32:
		v := read(r, i32) or_return
		value = int(v)
	case .UInt32:
		v := read(r, u32) or_return
		value = int(v)
	case .Int64:
		v := read(r, i64) or_return
		value = int(v)
	case .Set, .UInt64, .Float32, .Float64, .String, .Blob:
		err = .Unsupported_Type
	}
	return
}

// Returns a view of the next n bytes; nothing is allocated. Clone the result
// to keep it beyond the lifetime of r.data.
@(require_results)
read_bytes :: proc(r: ^Reader, n: int) -> ([]byte, Read_Error) {
	return take(r, n)
}

// Reads n bytes as a string, dropping every 0x00 byte. The result is owned
// and allocated with allocator.
@(require_results)
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
@(require_results)
peek_integer_at :: proc(r: ^Reader, pos: int, data_type: Data_Type) -> (int, Read_Error) {
	if pos < 0 || pos >= len(r.data) do return 0, .Offset_Out_Of_Range
	tmp := r^
	tmp.pos = pos
	return read_integer(&tmp, data_type)
}
