package data

import "base:intrinsics"
import "core:bytes"
import "core:encoding/endian"

Read_Error :: enum {
	None,
	Unexpected_EOF,        // a read needs more bytes than remain
	Offset_Out_Of_Range,   // a peek offset is outside [0, len(data)), or a parse instance's pos outside [0, len(data)]
	Unsupported_Type,      // the data type cannot be read as an integer (Set, UInt64, floats, String, Blob, Bool, Bits)
	Invalid_Length,        // a computed count or length is negative
	No_Progress,           // an element of a repeat that must consume input consumed none
	Division_By_Zero,      // an expression divides by zero, or takes a remainder by zero
	Integer_Overflow,      // an expression's result, or an integer field it reads, does not fit in an int
	Invalid_Shift,         // an expression shifts by a negative amount or by 64 or more
	Absent_Field,          // an expression refers to a field that has no value (not read yet, or absent), or to a value instance whose if is false
	Not_Equal,             // a value is not the one its field requires (Kaitai's contents, valid: eq)
	Less_Than_Min,         // a value is below its field's minimum (valid: min)
	Greater_Than_Max,      // a value is above its field's maximum (valid: max)
	Not_Any_Of,            // a value is none of those its field allows (valid: any-of)
	File_Read_Failed,      // the input file could not be read
}

// Bounds-checked cursor over a byte slice. Every read either succeeds and
// advances pos, or fails and leaves the reader unchanged. Each read of a
// number names its byte order.
//
// A bit read (read_bits) takes whole bytes and keeps the bits of the last
// one that it did not use, for the next bit read, as Kaitai's runtimes do.
// Other reads neither use nor discard them; align_to_byte does.
Reader :: struct {
	data:      []byte,
	pos:       int,
	bits:      u64, // the bits left over, in the low bits_left bits
	bits_left: int, // 0 to 7
}

reader_init :: proc(r: ^Reader, data: []byte) {
	r^ = Reader{data = data}
}

remaining :: proc(r: ^Reader) -> int {
	return len(r.data) - r.pos
}

// Whether every byte, and every bit left over, has been read (Kaitai's
// _io.eof).
at_eof :: proc(r: ^Reader) -> bool {
	return r.pos >= len(r.data) && r.bits_left == 0
}

// The bits read so far, for telling whether a read consumed any.
bit_pos :: proc(r: ^Reader) -> int {
	return 8 * r.pos - r.bits_left
}

// Discards the bits left over (Kaitai's alignToByte).
align_to_byte :: proc(r: ^Reader) {
	r.bits = 0
	r.bits_left = 0
}

// Reads an unsigned integer of n bits, 1 to 64: the bits left over, then
// those of as many more bytes as it needs. In byte order .Big the bits
// are taken from the most significant end of each byte, and the first
// taken are the most significant of the value; in .Little from the least
// significant end, and they are the least significant. The two orders
// share the bits left over, as in Kaitai's runtimes, whose
// read_bits_int_be and read_bits_int_le this follows. Leaves r unchanged
// on error.
@(require_results)
read_bits :: proc(r: ^Reader, n: int, order: endian.Byte_Order) -> (value: u64, err: Read_Error) {
	assert(n >= 1 && n <= 64, "read_bits: not 1 to 64 bits")
	needed := n - r.bits_left // at most 64
	bits_left := -needed & 7
	if needed <= 0 {
		// the bits left over are enough
		if order == .Big {
			value = r.bits >> uint(-needed)
			r.bits &= (1 << uint(bits_left)) - 1
		} else {
			value = r.bits & ((1 << uint(n)) - 1)
			r.bits >>= uint(n)
		}
		r.bits_left = bits_left
		return
	}

	b := take(r, (needed + 7) / 8) or_return
	raw: u64
	if order == .Big {
		for x in b do raw = raw << 8 | u64(x)
		// a shift by 64 or more gives 0
		value = raw >> uint(bits_left) | r.bits << uint(needed)
		r.bits = raw & ((1 << uint(bits_left)) - 1)
	} else {
		for x, i in b do raw |= u64(x) << uint(8 * i)
		value = raw << uint(r.bits_left) | r.bits
		if n < 64 do value &= (1 << uint(n)) - 1
		r.bits = raw >> uint(needed)
	}
	r.bits_left = bits_left
	return
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

// Reads a value of type T in byte order order. Leaves r unchanged on error.
@(require_results)
read :: proc(r: ^Reader, $T: typeid, order: endian.Byte_Order) -> (value: T, err: Read_Error)
	where intrinsics.type_is_integer(T) || intrinsics.type_is_float(T), intrinsics.type_is_endian_platform(T) {
	b := take(r, size_of(T)) or_return
	value = intrinsics.unaligned_load((^T)(raw_data(b)))
	when size_of(T) > 1 {
		if order != endian.PLATFORM_BYTE_ORDER do value = intrinsics.byte_swap(value)
	}
	return
}

// Reads an integer-typed value in byte order order as int. Non-integer
// types return .Unsupported_Type without consuming anything.
@(require_results)
read_integer :: proc(r: ^Reader, data_type: Data_Type, order: endian.Byte_Order) -> (value: int, err: Read_Error) {
	switch data_type {
	case .Int8:
		v := read(r, i8, order) or_return
		value = int(v)
	case .UInt8:
		v := read(r, u8, order) or_return
		value = int(v)
	case .Int16:
		v := read(r, i16, order) or_return
		value = int(v)
	case .UInt16:
		v := read(r, u16, order) or_return
		value = int(v)
	case .Int32:
		v := read(r, i32, order) or_return
		value = int(v)
	case .UInt32:
		v := read(r, u32, order) or_return
		value = int(v)
	case .Int64:
		v := read(r, i64, order) or_return
		value = int(v)
	case .Set, .UInt64, .Float32, .Float64, .String, .Blob, .Bool, .Bits:
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

// Returns a view of the bytes up to the first byte term, followed by term
// when include is set. consume moves past term; without it the reader
// stops at term. When the data ends first, that is .Unexpected_EOF with
// eos_error, and otherwise the bytes run to the end. Leaves r unchanged
// on error.
@(require_results)
read_bytes_term :: proc(r: ^Reader, term: byte, include, consume, eos_error: bool) -> ([]byte, Read_Error) {
	rest := r.data[r.pos:]
	i := bytes.index_byte(rest, term)
	if i < 0 {
		if eos_error do return nil, .Unexpected_EOF
		r.pos = len(r.data)
		return rest, .None
	}
	r.pos += i + int(consume)
	return rest[:i + int(include)], .None
}

// Reads an integer at absolute position pos without changing r.
@(require_results)
peek_integer_at :: proc(r: ^Reader, pos: int, data_type: Data_Type, order: endian.Byte_Order) -> (int, Read_Error) {
	if pos < 0 || pos >= len(r.data) do return 0, .Offset_Out_Of_Range
	tmp := r^
	tmp.pos = pos
	return read_integer(&tmp, data_type, order)
}
