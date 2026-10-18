package metadata

import dat "../data"
import "core:encoding/endian"

// One field of a compiled format. Every rule is resolved and validated when
// the format is loaded, so decoding needs no lookups. A field contained in
// several sets has one node, shared by all of them; the plan has no cycles.
Node :: struct {
	id:            int, // the field's id: the key of its values in a decoded set instance
	name:          string,
	type:          dat.Data_Type,
	order:         endian.Byte_Order, // integer and float types: the byte order they are read in
	count:         Count,             // instances of a set, or elements of any other field
	length:        Length,            // String and Blob only: the byte length of each element
	children:      []^Node,           // Set only, in order
	bits:          []Bit_Field,       // integer types only: packed subfields, decoded from each element
	default_value: Scalar,            // DefaultValue as the field's type; nil when absent (not used by the decoder yet)
	valid:         Valid,             // checked on every element; nil when there is no check
}

// A value given in the schema, as the type of the field it belongs to: one
// of the integer and float types, string, or []byte (a Blob).
Scalar :: union {
	i8,
	i16,
	i32,
	i64,
	u8,
	u16,
	u32,
	u64,
	f32,
	f64,
	string,
	[]byte,
}

// A check on every value of a field (Kaitai's contents and valid), applied
// as the value is read. Every constant has the field's type. A value that
// fails it is a decode error: .Not_Equal, .Less_Than_Min,
// .Greater_Than_Max or .Not_Any_Of.
Valid :: union {
	Valid_Eq,
	Valid_Range,
	Valid_Any_Of,
}

Valid_Eq :: struct {
	value: Scalar,
}

// Integer and float types only. Either bound may be nil; both are
// inclusive, and a NaN is within no range.
Valid_Range :: struct {
	min, max: Scalar,
}

Valid_Any_Of :: struct {
	values: []Scalar,
}

// How many instances (Set) or elements (other types) a field has in each
// instance of its parent.
Count :: union {
	Fixed_Count,
	Rule_Count,
	Marker_Count,
	Repeat_Count,
}

Fixed_Count :: struct {
	n: int,
}

// The value of expr, an Int expression, at most max.
Rule_Count :: struct {
	expr: ^Expr,
	max:  Maybe(int),
}

// 1 when every marker matches the input at the reader's position, else 0. A
// marker that cannot be read (outside the input) does not match.
Marker_Count :: struct {
	markers: []Marker,
}

// Instances are read while (until = false) or until (until = true) the
// integer of type, in order, at the reader's position equals value. It is
// peeked, never consumed. With until, reaching the end of the input first
// is an error; without it, the repeat stops there. At most max instances
// are read, and each must consume input.
Repeat_Count :: struct {
	type:  dat.Data_Type,
	value: int,
	until: bool,
	max:   Maybe(int),
	order: endian.Byte_Order,
}

Marker :: struct {
	offset: int, // from the reader's position
	type:   dat.Data_Type,
	value:  int,
	order:  endian.Byte_Order,
}

// The byte length of each String or Blob element.
Length :: union {
	Fixed_Length,
	Rule_Length,
}

Fixed_Length :: struct {
	n: int,
}

// The value of expr, an Int expression evaluated for each element, which
// must lie within [min, max] (either bound may be absent).
Rule_Length :: struct {
	expr:     ^Expr,
	min, max: Maybe(int),
}

// Bits low through high (inclusive; 0 is the least significant) of an
// integer field, as an unsigned number of type, an integer type wide
// enough to hold it. Its values are those of a field id in the set
// instance that holds the integer field, one for each element of it, and
// are dumped right after it.
Bit_Field :: struct {
	id:            int,
	name:          string,
	type:          dat.Data_Type,
	low, high:     int,
	default_value: Scalar, // as for Node
	valid:         Valid,  // as for Node
}
