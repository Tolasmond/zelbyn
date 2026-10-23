package expression

import mdata "../metadata"
import "core:strings"

// e as text, with every unary, binary and ?: operation parenthesized, so
// that the result shows how e was grouped. A resolved field reference is
// written as its path (_parent.a.b). Allocated with allocator.
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
ARRAY_METHOD_TEXT := [mdata.Array_Method_Kind]string {
	.First = ".first",
	.Last  = ".last",
	.Min   = ".min",
	.Max   = ".max",
}

@(private = "file")
write :: proc(b: ^strings.Builder, e: ^mdata.Expr) {
	switch x in e.variant {
	case mdata.Int_Literal:
		strings.write_int(b, x.value)
	case mdata.Bool_Literal:
		strings.write_string(b, x.value ? "true" : "false")
	case mdata.String_Literal:
		// double-quoted, with octal escapes for all but printable ASCII
		strings.write_byte(b, '"')
		for c in transmute([]byte)x.value {
			switch {
			case c == '"' || c == '\\':
				strings.write_byte(b, '\\')
				strings.write_byte(b, c)
			case c >= 0x20 && c < 0x7f:
				strings.write_byte(b, c)
			case:
				strings.write_byte(b, '\\')
				for shift := uint(6); ; shift -= 3 {
					strings.write_byte(b, '0' + (c >> shift) & 7)
					if shift == 0 do break
				}
			}
		}
		strings.write_byte(b, '"')
	case mdata.Index:
		write(b, x.operand)
		strings.write_byte(b, '[')
		write(b, x.index)
		strings.write_byte(b, ']')
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
	case mdata.Size_Of:
		strings.write_string(b, x.bits ? "bitsizeof<" : "sizeof<")
		strings.write_string(b, x.type_name)
		strings.write_byte(b, '>')
	case mdata.Cast:
		write_cast(b, x.operand, x.type_name)
	case mdata.Switch_Cast:
		write_cast(b, x.operand, x.type_name)
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
		write_member(b, x.base, x.node.ref_name)
	case mdata.Value_Ref:
		write_member(b, x.base, x.instance.name)
	case mdata.Size:
		write(b, x.operand)
		strings.write_string(b, ".size")
	case mdata.String_Length:
		write(b, x.operand)
		strings.write_string(b, ".length")
	case mdata.To_S:
		write(b, x.operand)
		strings.write_string(b, ".to_s")
	case mdata.To_I:
		write(b, x.operand)
		strings.write_string(b, ".to_i")
	case mdata.Array_Method:
		write(b, x.operand)
		strings.write_string(b, ARRAY_METHOD_TEXT[x.method])
	case mdata.Io:
		write_member(b, x.instance, "_io")
	case mdata.Io_Pos:
		strings.write_string(b, "_io.pos")
	case mdata.Io_Size:
		strings.write_string(b, "_io.size")
	case mdata.Io_Eof:
		strings.write_string(b, "_io.eof")
	case mdata.Repeat_Index:
		strings.write_string(b, "_index")
	case mdata.Repeat_Element:
		strings.write_string(b, "_")
	}
}

// base.name, or name alone when base is the instance being decoded.
@(private = "file")
write_member :: proc(b: ^strings.Builder, base: ^mdata.Expr, name: string) {
	write(b, base)
	if inst, is_instance := base.variant.(mdata.Instance); !is_instance || inst.root || inst.up > 0 {
		strings.write_byte(b, '.')
	}
	strings.write_string(b, name)
}

// operand.as<type_name>.
@(private = "file")
write_cast :: proc(b: ^strings.Builder, operand: ^mdata.Expr, type_name: string) {
	write(b, operand)
	strings.write_string(b, ".as<")
	strings.write_string(b, type_name)
	strings.write_byte(b, '>')
}
