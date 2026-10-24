package metadata

// A node of a parsed expression (doc/arch.md, "expression: parsing,
// resolution and direct forms", and in the plan, "Checks and expressions").
// The parser (package expression) gives every node a syntax variant; resolving the expression replaces the
// names and member accesses with the resolved variants and sets type. The
// decoder only sees resolved expressions.
Expr :: struct {
	type:    Expr_Type,
	offset:  int, // byte offset in the source text, for errors; -1 when built by a front end
	variant: Expr_Variant,
	direct:  Direct, // set on a whole expression by expression.compile; nil on its subexpressions
}

Expr_Type :: enum {
	Unresolved,
	Int,
	Float,  // an f64: a float literal, a float field, or an operation on one
	Bool,
	Bytes,  // a Blob value
	String, // a String value, or a string made by an expression; kept as bytes, as the input has them
	Array,  // every value of a repeated field
	Struct, // an instance of a set
	Stream, // the stream a set instance is read from (Kaitai's _io); only io and ?: have this type
}

Expr_Variant :: union {
	// syntax and resolved
	Int_Literal,
	Big_Literal,
	Float_Literal,
	Bool_Literal,
	String_Literal,
	Unary,
	Binary,
	Ternary,
	Index,
	Array_Literal,

	// syntax only
	Name,
	Member,
	Enum_Constant,
	Size_Of,
	Cast,
	Call,

	// resolved only
	Instance,
	Field_Ref,
	Size,
	String_Length,
	To_S,
	To_I,
	Array_Method,
	Io,
	Io_Pos,
	Io_Size,
	Io_Eof,
	Repeat_Index,
	Repeat_Element,
	Value_Ref,
	Switch_Cast,
	Bytes_Literal,
	Decode,
	Substring,
	To_Bytes,
	Root_Arg,
}

Int_Literal :: struct {
	value: int,
}

// An Int literal above max(int), up to max(u64): an integer expression is
// exact from min(int) to max(u64), and fails with Integer_Overflow beyond.
Big_Literal :: struct {
	value: u64,
}

// 1.5, 2., 1e3 or 1.5e-3.
Float_Literal :: struct {
	value: f64,
}

Bool_Literal :: struct {
	value: bool,
}

// A string in quotes: '...' as it is, or "..." with Kaitai's escapes
// (\a \b \t \n \v \f \r \e \" \' \\, octal \0 to \377, and \uXXXX in
// UTF-8) replaced.
String_Literal :: struct {
	value: string,
}

Unary_Op :: enum {
	Neg,     // -
	Bit_Not, // ~
	Not,     // not
}

Unary :: struct {
	op:      Unary_Op,
	operand: ^Expr,
}

// The arithmetic operators and the comparisons also apply to a Float and
// an Int, or two Floats, as Kaitai's runtimes apply them: the Int is made
// a Float, and the result is a Float as IEEE 754 gives it, with no error,
// for a division by zero too.
Binary_Op :: enum {
	Mul, // *
	Div, // /, of Ints rounding toward negative infinity
	Mod, // %, with the sign of the divisor; Ints only
	Add, // +, which also joins two strings
	Sub, // -
	Shl, // <<
	Shr, // >>, arithmetic
	And, // &
	Xor, // ^
	Or,  // |
	Eq,  // ==; this and the other comparisons also compare two strings, or two byte arrays, byte by byte
	Ne,  // !=
	Lt,  // <
	Le,  // <=
	Gt,  // >
	Ge,  // >=
	Logical_And, // and
	Logical_Or,  // or
}

Binary :: struct {
	op:          Binary_Op,
	left, right: ^Expr,
}

Ternary :: struct {
	cond, then, otherwise: ^Expr,
}

// operand[index]: an element of an Array, with the type of one value of
// its field, or a byte of Bytes, as an Int. index is an Int expression;
// one outside the array or bytes is Index_Out_Of_Range.
Index :: struct {
	operand, index: ^Expr,
}

// [a, b, ...]: an Array of the items, which resolution makes all of one
// type, item_type, an Int, Float, Bool, String or Bytes, or an Array whose
// items, array literals, are all of one type; one of integer literals from
// 0 to 255 is a Bytes_Literal instead, as in Kaitai. Each evaluation makes
// the array in the tree's arena.
Array_Literal :: struct {
	items:     []^Expr,
	item_type: Expr_Type,
}

// An array literal of bytes, [0x50, 0x4b], a Bytes value, copied into the
// tree's arena when it is evaluated, so that the tree never refers to the
// plan.
Bytes_Literal :: struct {
	value: []byte,
}

// An identifier: a field name, or one of _root, _parent, _io, _ and _index.
Name :: struct {
	name: string,
}

// operand.name
Member :: struct {
	operand: ^Expr,
	name:    string,
}

// enum_name::value_name, where enum_name can be a path of types to the
// enum (a::b::e)
Enum_Constant :: struct {
	enum_name, value_name: string,
}

// sizeof<type_name>, or bitsizeof<type_name> when bits is set. Resolving
// it, like _sizeof, gives an Int_Literal: the size of the type in bytes or
// bits.
Size_Of :: struct {
	type_name: string,
	bits:      bool,
}

// operand.as<type_name>. Resolving it gives the operand itself for an
// integer type, as the values of all integer types are Ints, and a
// Switch_Cast for a user type.
Cast :: struct {
	operand:   ^Expr,
	type_name: string,
}

// operand.as<type_name>: operand, a switch-on field read once, as the
// instance of the case of user type type_name that it was read as. node is
// the set of the first of those cases, whose fields the others share, and
// choices are their indexes in the Switch, as field.Instance.choice
// records them. An instance read as another case, or a value that is not
// an instance, is Wrong_Type.
Switch_Cast :: struct {
	operand:   ^Expr,
	type_name: string,
	node:      ^Node,
	choices:   []int,
}

// operand.name(args): a method call, which resolving makes a Decode or a
// Substring.
Call :: struct {
	operand: ^Expr,
	name:    string,
	args:    []^Expr,
}

// .to_s(encoding) of Bytes: the String its bytes are in encoding,
// decoded as a str field's are (ASCII and UTF-8 kept as they are). name
// is the encoding as the schema gives it.
Decode :: struct {
	operand:  ^Expr,
	encoding: Encoding,
	name:     string,
}

// .substring(from, to) of a String: its code points from from up to to,
// both Int expressions, clamped to its length; empty when to is not after
// from, and Index_Out_Of_Range when either is negative.
Substring :: struct {
	operand, from, to: ^Expr,
}

// .as<bytes> of an Array of Ints: Bytes of its values, each of which must
// fit in a byte, else Integer_Overflow.
To_Bytes :: struct {
	operand: ^Expr,
}

// The argument given to the decoder (reader.read's args) for param index
// of the top-level type of the schema decoded: the root's args are these,
// as nothing in the schema gives them. For a param of a user type, the
// argument is bytes, which the decoder reads, in a stream of their own, as
// an instance of set, before the root.
Root_Arg :: struct {
	index: int,
	set:   ^Node,
}

// The set instance being decoded (up = 0), one of its enclosing instances
// (up > 0, _parent, and _root in an imported schema, which sets
// imported_root), or the outermost one (root, _root). node is its set.
Instance :: struct {
	root:          bool,
	up:            int,
	node:          ^Node,
	imported_root: bool,
}

// The values of field node in the instance base, from its slot there. A
// field read once gives its value (type Int, Bytes or Struct), any other
// field all of its values (Array). node can be a parse instance, which is
// read first if it has not been.
Field_Ref :: struct {
	base: ^Expr,
	node: ^Node,
	slot: int,
}

// The number of elements of an Array, or of bytes of Bytes.
Size :: struct {
	operand: ^Expr,
}

// The stream that the set instance instance is read from: its substream,
// if it has one, else that of the instance it belongs to. _io is the
// stream of the instance being decoded.
Io :: struct {
	instance: ^Expr,
}

// .length of a String: its characters, the code points of its UTF-8.
String_Length :: struct {
	operand: ^Expr,
}

// .to_s of an Int: its decimal digits, with a - when it is negative.
To_S :: struct {
	operand: ^Expr,
}

// .to_i of a String: the decimal integer it is, with an optional sign;
// Invalid_Number when it is not one, Integer_Overflow when it does not fit.
// Of a Bool: 1 or 0. Of a Float: its integer part, rounded toward zero, an
// integer from -2^63 to 2^64 - 1 as any Int expression; Integer_Overflow
// beyond them, or when it is not a number. As a size, count or offset, the
// result must also fit an int.
To_I :: struct {
	operand: ^Expr,
}

// .first, .last, .min and .max of an Array or of Bytes: one of its values,
// or of its bytes as an Int; Index_Out_Of_Range when it has none. min and
// max are of Int values.
Array_Method :: struct {
	operand: ^Expr,
	method:  Array_Method_Kind,
}

Array_Method_Kind :: enum {
	First,
	Last,
	Min,
	Max,
}

// .pos, .size and .eof of stream, a Stream expression (X._io, or a ?: of
// those): the position in it, its length, and whether the position is at
// the end. stream is nil for _io itself, the stream of the set instance
// being decoded, or in a value instance, of the instance it is evaluated
// for.
Io_Pos :: struct {
	stream: ^Expr,
}
Io_Size :: struct {
	stream: ^Expr,
}
Io_Eof :: struct {
	stream: ^Expr,
}

// _index: the index of the element being read.
Repeat_Index :: struct {}

// _ in repeat-until: the element of node just read.
Repeat_Element :: struct {
	node: ^Node,
}

// The value instance instance, evaluated for the set instance base.
Value_Ref :: struct {
	base:     ^Expr,
	instance: ^Value_Instance,
}

// A form of a whole expression that the decoder evaluates without walking
// the tree, kept alongside it (doc/arch.md, "expression: parsing,
// resolution and direct forms", and how the decoder evaluates it,
// "Expression evaluation"). It gives what the tree gives
// whenever the field it reads has a value that fits an int; otherwise the
// decoder evaluates the tree, which reports the error.
Direct :: union {
	Direct_Constant,
	Direct_Field,
	Direct_Compare,
}

// An Int literal, or a Bool one as 0 or 1.
Direct_Constant :: struct {
	value: int,
}

// An Int: the value of an integer field read at most once, in slot of the
// set instance being decoded, or of _ (the element of a repeat-until just
// read) when of_element is set.
Direct_Field :: struct {
	slot:       int,
	of_element: bool,
}

// A Bool: field op constant, where op is a comparison (.Eq to .Ge). A
// constant on the left is moved to the right, and op reversed.
Direct_Compare :: struct {
	field:    Direct_Field,
	op:       Binary_Op,
	constant: int,
}

// True when the field is read at most once in each instance of its parent,
// so that a reference to it gives its value rather than an array: a fixed
// count of 1 that is not a repeat, or a marker count of 0 or 1 (either with
// or without a cond). A repeat is an array however many elements it has,
// even when its count is a literal 1.
is_single :: proc(node: ^Node) -> bool {
	switch c in node.count {
	case Fixed_Count:
		return c.n == 1 && !c.repeat
	case Marker_Count:
		return true
	case Rule_Count, Repeat_Count, Eos_Count, Until_Count:
		return false
	}
	return false
}
