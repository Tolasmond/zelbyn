package metadata

import dat "../data"
import fld "../field"
import "core:encoding/endian"

// One field of a compiled format. Every rule is resolved and validated when
// the format is loaded, so decoding needs no lookups. Each field has its
// own node, even when several fields have the same type. The plan has no
// cycles but for a type that contains itself (recursive).
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
	encoding:        Encoding,          // String only: how its bytes are decoded
	children:        []^Node,           // Set only, in order; nil when switch_on is set
	slot_count:      int,               // Set only: the slots in each instance (count_slots), recorded when children is set
	switch_on:       ^Switch,           // Set only: the type of each instance is chosen by a value; nil when it is fixed
	recursive:       ^Node,             // Set only: for a field of a type inside the same type (a recursive type), the set of that type that encloses it, whose children, instances, parse instances, params and slot count it is given, once that set is compiled (members); nil otherwise
	instances:       []^Value_Instance, // Set only: Kaitai's value instances, which expressions can refer to
	parse_instances: []^Node,           // Set only: Kaitai's instances with pos, each read at an offset (see pos)
	params:          []^Node,           // Set only: Kaitai's params, each a field read once, of type Int64 (any integer type), Bool or Blob, whose value is its argument (see args)
	args:            []^Expr,           // a Set with params: an Int, Bool or Bytes expression for each, evaluated where each instance is read, after the bytes of its substream
	pos:             ^Expr,             // a parse instance only: an Int expression, the offset it is read at (see below); nil for every other field
	io:              ^Expr,             // a parse instance only: a Stream expression, the stream it is read from (Kaitai's io); nil for that of the set instance it belongs to
	keeps_stream:    bool,              // Set only: an io expression refers to the stream of its instances, which the decoder then keeps while it decodes (Io)
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
// as the value is read, after it is in the tree. Every constant has the
// field's type. A value that fails it is a decode error: .Not_Equal,
// .Less_Than_Min, .Greater_Than_Max, .Not_Any_Of, .Not_In_Enum or
// .Expr_False.
Valid :: union {
	Valid_Eq,
	Valid_Range,
	Valid_Any_Of,
	Valid_In_Enum,
	Valid_Expr,
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

// An integer field with an enum: the value is one of the enum's (Kaitai's
// in-enum). values is sorted.
Valid_In_Enum :: struct {
	values: []int,
}

// A check that needs expressions: valid: expr, or eq, min, max or any-of
// with a value that is not a literal. Each cond is a Bool expression in
// which _ is the value (Repeat_Element), evaluated in order; the first
// that is false fails the value with its err.
Valid_Expr :: struct {
	checks: []Valid_Check,
}

Valid_Check :: struct {
	cond: ^Expr,
	err:  dat.Read_Error,
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
// element is read as the first case whose value equals on, or as default
// when none does. Each case is a node with the field's name: a set, with
// its own children, whose instances record which case they were read as
// (field.Instance.choice), or a field of any other type, whose element is
// a value of that type where an instance would be. That field has its own
// length, terminator and pad_right: as the official compiler reads them,
// a String has those of the switch-on field, and the other types none, so
// that their values are read in the field's stream whatever its length.
// With no match and no default, the element is not read and adds no
// value, so a repeated field can have fewer values than elements, as in
// Kaitai, unless the field has a length: then, as the official compiler
// does, the bytes of the length are read, without removing pad_right or
// cutting them at a terminator, and are its value, a []byte where an
// instance would be.
Switch :: struct {
	on:      ^Expr, // an Int, Bool or String expression
	cases:   []Switch_Case,
	default: ^Node, // nil when there is no _ case
}

// value for a Switch whose on is an Int, or a Bool as 0 or 1; text for one
// whose on is a String.
Switch_Case :: struct {
	value: int,
	text:  string,
	node:  ^Node,
}

// A parse instance of a set (Kaitai's instances with pos) is a field read
// at offset pos, an Int expression, in the stream that the set instance it
// belongs to is read from, or the one io gives; reading it does not move
// that stream. Its expressions, io and pos among them, are evaluated in the
// set instance, where _io is still that instance's stream. Each is
// read when an expression first refers to it, which can be from any field
// of the set, or else after the set's children, in order, so that every
// one is in the decoded tree. Its cond is evaluated before pos. Its values
// are in its own slot of the set instance: those of the parse instances
// come first, in order, before the children's.

// The encoding of a String's bytes. None is ASCII or UTF-8, whose bytes
// are kept as they are, so that the tree holds a view of the input; the
// others are decoded, into UTF-8 (reader.decode_text).
Encoding :: enum u8 {
	None,
	UTF_16LE,
	UTF_16BE,
	UTF_32LE,
	UTF_32BE,
	ISO_8859_1,
	Windows_1251,
	Windows_1252,
	IBM437,
}

// The set instance was read as: node itself, or for a switch-on field the
// case it records.
instance_set :: proc(node: ^Node, instance: ^fld.Instance) -> ^Node {
	sw := node.switch_on
	if sw == nil do return node
	if instance.choice == fld.DEFAULT_CASE do return sw.default
	return sw.cases[instance.choice].node
}

// The set that holds the children, instances, parse instances, params and
// slot count of set: the set of its type that encloses it, for a field of a
// type inside the same type (Node.recursive), else set itself. A front end
// needs it while that set is compiled; set has them once it is. The
// expressions in that set are evaluated in the instances of both, so none
// of them refers to the members of the instances that enclose it, other
// than the root's.
members :: proc(set: ^Node) -> ^Node {
	return set.recursive != nil ? set.recursive : set
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
// child, bit field and param. A front end records it in set.slot_count.
count_slots :: proc(set: ^Node) -> int {
	n := len(set.parse_instances) + len(set.children) + len(set.params)
	for child in set.children do n += len(child.bits)
	return n
}

// The slot of param k of set: the params come last, after the children
// and their bit fields.
param_slot :: proc(set: ^Node, k: int) -> int {
	return set.slot_count - len(set.params) + k
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
// it, and is not read, so it has no values in the decoded tree. When cond
// is false it has no value, and a reference to it fails as one to a field
// with none does (Absent_Field).
Value_Instance :: struct {
	name: string, // the .ksy id
	cond: ^Expr,  // a Bool expression over the same fields, evaluated first; nil when it always has a value (Kaitai's if)
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
	valid:     Valid, // as for Node, but only Valid_Eq, Valid_Range or Valid_Any_Of
}
