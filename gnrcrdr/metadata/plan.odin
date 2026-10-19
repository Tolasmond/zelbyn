package metadata

import dat "../data"
import fld "../field"
import "core:encoding/endian"

// One field of a compiled format. Every rule is resolved and validated when
// the format is loaded, so decoding needs no lookups. Each field has its
// own node, even when several fields have the same type, and the plan has
// no cycles.
Node :: struct {
	name:            string,            // shown in the dump and in error paths: the .ksy -orig-id, or else the id
	ref_name:        string,            // what expressions call it: the .ksy id
	type:            dat.Data_Type,
	order:           endian.Byte_Order, // integer and float types: the byte order they are read in; bit types: the bit order (data.read_bits)
	width:           u8,                // a bit type (Kaitai's b1-b64): the bits each element is read from; 0 for every other field
	align:           bool,              // the bits left over from the fields before are discarded first, before cond (Kaitai's alignToByte)
	cond:            ^Expr,             // a Bool expression: the field is read only when it is true; nil when always read (Kaitai's if)
	count:           Count,             // instances of a set, or elements of any other field
	length:          Length,            // String and Blob: the byte length of each element; Set: the length of the substream each instance is read from. nil for a terminator alone, or for a Set read from its parent's stream
	terminator:      Maybe(Terminator), // String, Blob and Set: the byte that ends each element's bytes (Kaitai's terminator, and strz)
	pad_right:       Maybe(u8),         // String, Blob and Set with a length: removed from the end of each element's bytes (Kaitai's pad-right)
	children:        []^Node,           // Set only, in order; nil when switch_on is set
	slot_count:      int,               // Set only: the slots in each instance (count_slots), recorded when children is set
	switch_on:       ^Switch,           // Set only: the type of each instance is chosen by a value; nil when it is fixed
	instances:       []^Value_Instance, // Set only: Kaitai's value instances, which expressions can refer to
	parse_instances: []^Node,           // Set only: Kaitai's instances with pos, each read at an offset (see pos)
	pos:             ^Expr,             // a parse instance only: an Int expression, the offset it is read at (see below); nil for every other field
	bits:            []Bit_Field,       // integer types only: packed subfields, decoded from each element
	valid:           Valid,             // checked on every element; nil when there is no check
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
	Eos_Count,
	Until_Count,
}

Fixed_Count :: struct {
	n: int,
}

// The value of expr, an Int expression.
Rule_Count :: struct {
	expr: ^Expr,
}

// 1 when every marker matches the input at the reader's position, else 0. A
// marker that cannot be read (outside the input) does not match.
Marker_Count :: struct {
	markers: []Marker,
}

// Instances are read while (until = false) or until (until = true) the
// integer of type, in order, at the reader's position equals value. It is
// peeked, never consumed. With until, reaching the end of the input first
// is an error; without it, the repeat stops there. Each instance must
// consume input.
Repeat_Count :: struct {
	type:  dat.Data_Type,
	value: int,
	until: bool,
	order: endian.Byte_Order,
}

// Elements are read until the end of the stream (Kaitai's repeat: eos).
// Each must consume input.
Eos_Count :: struct {}

// Elements are read until expr, a Bool expression evaluated after each
// element with _ the element just read, is true (Kaitai's repeat: until).
// At least one element is read, and each but the last must consume input.
Until_Count :: struct {
	expr: ^Expr,
}

Marker :: struct {
	offset: int, // from the reader's position
	type:   dat.Data_Type,
	value:  int,
	order:  endian.Byte_Order,
}

// The byte length of each String or Blob element, or of the substream of
// each Set instance.
Length :: union {
	Fixed_Length,
	Rule_Length,
	Eos_Length,
}

Fixed_Length :: struct {
	n: int,
}

// The value of expr, an Int expression evaluated for each element.
Rule_Length :: struct {
	expr: ^Expr,
}

// The rest of the stream being read (Kaitai's size-eos).
Eos_Length :: struct {}

// The byte that ends each element of a String or Blob, or the substream
// of each instance of a Set (Kaitai's terminator). Without a length, the
// bytes run up to the terminator, and consume moves past it; when the
// stream ends first, that is an error with eos_error, else the bytes run
// to the end. With a length, its bytes are read, pad_right is removed
// from their end, and they are cut at the first terminator, if any.
// include keeps the terminator in the bytes.
Terminator :: struct {
	value:     u8,
	include:   bool,
	consume:   bool,
	eos_error: bool,
}

// A field whose type is chosen by a value (Kaitai's switch-on): each
// instance is one of the set of the first case whose value equals on, or of
// default when none does. Each case's set has the field's name and its own
// children, and each instance records which case it was read as
// (field.Instance.choice). With no match and no default, the field is not
// read: the compiler allows that only when it is read at most once.
Switch :: struct {
	on:      ^Expr, // an Int expression
	cases:   []Switch_Case,
	default: ^Node, // nil when there is no _ case
}

Switch_Case :: struct {
	value: int,
	node:  ^Node,
}

// A parse instance of a set (Kaitai's instances with pos) is a field read
// at offset pos, an Int expression, in the stream that the set instance it
// belongs to is read from; reading it does not move that stream. Each is
// read when an expression first refers to it, which can be from any field
// of the set, or else after the set's children, in order, so that every
// one is in the decoded tree. Its cond is evaluated before pos. Its values
// are in its own slot of the set instance: those of the parse instances
// come first, in order, before the children's.

// The set instance was read as: node itself, or for a switch-on field the
// case it records.
instance_set :: proc(node: ^Node, instance: ^fld.Instance) -> ^Node {
	sw := node.switch_on
	if sw == nil do return node
	if instance.choice == fld.DEFAULT_CASE do return sw.default
	return sw.cases[instance.choice].node
}

// The type of the values of a field of type Bits whose elements are width
// bits: the smallest unsigned integer type that holds them.
bits_type :: proc(width: int) -> dat.Data_Type {
	switch {
	case width <= 8:
		return .UInt8
	case width <= 16:
		return .UInt16
	case width <= 32:
		return .UInt32
	}
	return .UInt64
}

// The number of slots in an instance of set: one for each parse instance,
// child and bit field. A front end records it in set.slot_count.
count_slots :: proc(set: ^Node) -> int {
	n := len(set.parse_instances) + len(set.children)
	for child in set.children do n += len(child.bits)
	return n
}

// The slot of child index of set; its bit fields follow it, in order. Parse
// instance k of set is in slot k.
slot_of :: proc(set: ^Node, index: int) -> int {
	slot := len(set.parse_instances) + index
	for child in set.children[:index] do slot += len(child.bits)
	return slot
}

// A value instance of a set (Kaitai's instances with value:): an
// expression over the set's fields and other value instances. It is
// evaluated for an instance of the set each time an expression refers to
// it, and is not read, so it has no values in the decoded tree.
Value_Instance :: struct {
	name: string, // the .ksy id
	expr: ^Expr,  // Int or Bool; nil only while the schema is being compiled
}

// Bits low through high (inclusive; 0 is the least significant) of an
// integer field, as an unsigned number of type, an integer type wide
// enough to hold it. Its values, one for each element of the integer
// field, are in their own slot of the set instance that holds that field,
// after the field's slot (slot_of), and are dumped right after it.
Bit_Field :: struct {
	name:      string,
	type:      dat.Data_Type,
	low, high: int,
	valid:     Valid, // as for Node
}
