package expression

import dat "../data"
import mdata "../metadata"
import "core:strings"

// e as text, with every unary, binary and ?: operation parenthesized, so
// that the result shows how e was grouped. A resolved field reference is
// written as its path (_parent.a.b), and a peek as peek(<type>, <pos>), with
// the Kaitai name of the type (u1, u2le, s4be). Allocated with allocator.
to_string :: proc(e: ^mdata.Expr, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write(&b, e)
	return strings.to_string(b)
}

@(private = "file")
UNARY_TEXT := [mdata.Unary_Op]string {
	.Neg     = "-",
	.Bit_Not = "~",
	.Not     = "not ",
}

@(private = "file")
BINARY_TEXT := [mdata.Binary_Op]string {
	.Mul         = "*",
	.Div         = "/",
	.Mod         = "%",
	.Add         = "+",
	.Sub         = "-",
	.Shl         = "<<",
	.Shr         = ">>",
	.And         = "&",
	.Xor         = "^",
	.Or          = "|",
	.Eq          = "==",
	.Ne          = "!=",
	.Lt          = "<",
	.Le          = "<=",
	.Gt          = ">",
	.Ge          = ">=",
	.Logical_And = "and",
	.Logical_Or  = "or",
}

@(private = "file")
KAITAI_TYPE := #partial [dat.Data_Type]string {
	.Int8   = "s1",
	.UInt8  = "u1",
	.Int16  = "s2",
	.UInt16 = "u2",
	.Int32  = "s4",
	.UInt32 = "u4",
	.Int64  = "s8",
	.UInt64 = "u8",
}

@(private = "file")
write :: proc(b: ^strings.Builder, e: ^mdata.Expr) {
	switch x in e.variant {
	case mdata.Int_Literal:
		strings.write_int(b, x.value)
	case mdata.Bool_Literal:
		strings.write_string(b, x.value ? "true" : "false")
	case mdata.Unary:
		strings.write_byte(b, '(')
		strings.write_string(b, UNARY_TEXT[x.op])
		write(b, x.operand)
		strings.write_byte(b, ')')
	case mdata.Binary:
		strings.write_byte(b, '(')
		write(b, x.left)
		strings.write_byte(b, ' ')
		strings.write_string(b, BINARY_TEXT[x.op])
		strings.write_byte(b, ' ')
		write(b, x.right)
		strings.write_byte(b, ')')
	case mdata.Ternary:
		strings.write_byte(b, '(')
		write(b, x.cond)
		strings.write_string(b, " ? ")
		write(b, x.then)
		strings.write_string(b, " : ")
		write(b, x.otherwise)
		strings.write_byte(b, ')')
	case mdata.Name:
		strings.write_string(b, x.name)
	case mdata.Member:
		write(b, x.operand)
		strings.write_byte(b, '.')
		strings.write_string(b, x.name)
	case mdata.Enum_Constant:
		strings.write_string(b, x.enum_name)
		strings.write_string(b, "::")
		strings.write_string(b, x.value_name)
	case mdata.Instance:
		if x.root {
			strings.write_string(b, "_root")
		} else {
			for i in 0 ..< x.up {
				if i > 0 do strings.write_byte(b, '.')
				strings.write_string(b, "_parent")
			}
		}
	case mdata.Field_Ref:
		write(b, x.base)
		if inst, is_instance := x.base.variant.(mdata.Instance); !is_instance || inst.root || inst.up > 0 {
			strings.write_byte(b, '.')
		}
		strings.write_string(b, x.node.name)
	case mdata.Size:
		write(b, x.operand)
		strings.write_string(b, ".size")
	case mdata.Io_Pos:
		strings.write_string(b, "_io.pos")
	case mdata.Io_Size:
		strings.write_string(b, "_io.size")
	case mdata.Io_Eof:
		strings.write_string(b, "_io.eof")
	case mdata.Repeat_Index:
		strings.write_string(b, "_index")
	case mdata.Peek:
		strings.write_string(b, "peek(")
		strings.write_string(b, KAITAI_TYPE[x.type])
		if x.type != .Int8 && x.type != .UInt8 do strings.write_string(b, x.order == .Little ? "le" : "be")
		strings.write_string(b, ", ")
		write(b, x.pos)
		strings.write_byte(b, ')')
	}
}
