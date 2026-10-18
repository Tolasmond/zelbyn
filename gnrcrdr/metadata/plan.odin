package metadata

import dat "../data"

// One field of a compiled format. Every rule is resolved and validated when
// the format is loaded, so decoding needs no lookups. A field contained in
// several sets has one node, shared by all of them; the plan has no cycles.
Node :: struct {
	id:            int, // the field's id: the key of its values in a decoded set instance
	name:          string,
	type:          dat.Data_Type,
	count:         Count,       // instances of a set, or elements of any other field
	length:        Length,      // String and Blob only: the byte length of each element
	children:      []^Node,     // Set only, in order
	bits:          []Bit_Field, // integer types only: packed subfields (not decoded yet)
	default_value: Scalar,      // DefaultValue as the field's type; nil when absent (not used by the decoder yet)
}

// A value given in the schema, as the type of the field it belongs to: one
// of the integer and float types, or string.
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

// The value of rule at the reader's position, at most max.
Rule_Count :: struct {
	rule: Length_Rule,
	max:  Maybe(int),
}

// 1 when every marker matches the input at the reader's position, else 0. A
// marker that cannot be read (outside the input) does not match.
Marker_Count :: struct {
	markers: []Marker,
}

// Instances are read while (until = false) or until (until = true) the
// integer of type at the reader's position equals value. It is peeked, never
// consumed. With until, reaching the end of the input first is an error;
// without it, the repeat stops there. At most max instances are read, and
// each must consume input.
Repeat_Count :: struct {
	type:  dat.Data_Type,
	value: int,
	until: bool,
	max:   Maybe(int),
}

Marker :: struct {
	offset: int, // from the reader's position
	type:   dat.Data_Type,
	value:  int,
}

// A length or count computed from integers peeked at the reader's position.
// When flag is present and reads as zero, the result is 0. Otherwise it is
// value (0 when absent), with expression applied when present.
Length_Rule :: struct {
	type:       dat.Data_Type, // integer type of both peeks
	flag:       Maybe(Peek),
	value:      Maybe(Peek),
	expression: Maybe(string),
}

// An integer read at offset, from the start of the input when absolute, else
// from the reader's position, then masked and shifted right.
Peek :: struct {
	offset:   int,
	absolute: bool,
	mask:     Maybe(int),
	shift:    uint,
}

// The byte length of each String or Blob element.
Length :: union {
	Fixed_Length,
	Rule_Length,
}

Fixed_Length :: struct {
	n: int,
}

// The value of rule at the reader's position, which must lie within
// [min, max] (either bound may be absent).
Rule_Length :: struct {
	rule:     Length_Rule,
	min, max: Maybe(int),
}

// Bits low through high (inclusive; 0 is the least significant) of an
// integer field.
Bit_Field :: struct {
	id:            int,
	name:          string,
	low, high:     int,
	default_value: Scalar, // as for Node
}
