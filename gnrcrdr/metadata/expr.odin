package metadata

import dat "../data"
import "core:encoding/endian"

// A node of a parsed expression (§6.3). The parser (package expression)
// gives every node a syntax variant; resolving the expression replaces the
// names and member accesses with the resolved variants and sets type. The
// decoder only sees resolved expressions.
Expr :: struct {
	type:    Expr_Type,
	offset:  int, // byte offset in the source text, for errors; -1 when built by a front end
	variant: Expr_Variant,
}

Expr_Type :: enum {
	Unresolved,
	Int,
	Bool,
	Bytes,  // a Blob value
	Array,  // every value of a repeated field
	Struct, // an instance of a set
}

Expr_Variant :: union {
	// syntax and resolved
	Int_Literal,
	Bool_Literal,
	Unary,
	Binary,
	Ternary,

	// syntax only
	Name,
	Member,
	Enum_Constant,

	// resolved only
	Instance,
	Field_Ref,
	Size,
	Io_Pos,
	Io_Size,
	Io_Eof,
	Repeat_Index,
	Repeat_Element,
	Value_Ref,
	Peek,
}

Int_Literal :: struct {
	value: int,
}

Bool_Literal :: struct {
	value: bool,
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

Binary_Op :: enum {
	Mul, // *
	Div, // /, rounding toward negative infinity
	Mod, // %, with the sign of the divisor
	Add, // +
	Sub, // -
	Shl, // <<
	Shr, // >>, arithmetic
	And, // &
	Xor, // ^
	Or,  // |
	Eq,  // ==
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

// An identifier: a field name, or one of _root, _parent, _io, _ and _index.
Name :: struct {
	name: string,
}

// operand.name
Member :: struct {
	operand: ^Expr,
	name:    string,
}

// enum_name::value_name
Enum_Constant :: struct {
	enum_name, value_name: string,
}

// The set instance being decoded (up = 0), one of its enclosing instances
// (up > 0, _parent), or the outermost one (root, _root). node is its set.
Instance :: struct {
	root: bool,
	up:   int,
	node: ^Node,
}

// The values of field node (whose id is node.id) in the instance base. A
// field read once gives its value (type Int, Bytes or Struct), any other
// field all of its values (Array).
Field_Ref :: struct {
	base: ^Expr,
	node: ^Node,
}

// The number of elements of an Array, or of bytes of Bytes.
Size :: struct {
	operand: ^Expr,
}

// _io.pos, _io.size and _io.eof: the reader's position, the input's length,
// and whether the position is at the end.
Io_Pos :: struct {}
Io_Size :: struct {}
Io_Eof :: struct {}

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

// The integer of type, in order, at position pos (from the start of the
// input), read without moving the reader. No .ksy syntax yet: front ends
// build it.
Peek :: struct {
	type:  dat.Data_Type,
	order: endian.Byte_Order,
	pos:   ^Expr,
}

// True when the field is read at most once in each instance of its parent,
// so that a reference to it gives its value rather than an array: a fixed
// count of 1, or a marker count of 0 or 1 (either with or without a cond).
is_single :: proc(node: ^Node) -> bool {
	switch c in node.count {
	case Fixed_Count:
		return c.n == 1
	case Marker_Count:
		return true
	case Rule_Count, Repeat_Count, Eos_Count, Until_Count:
		return false
	}
	return false
}
