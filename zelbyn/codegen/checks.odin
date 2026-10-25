package codegen

import dat "../data"
import mdata "../metadata"
import "core:fmt"
import "core:strings"

// The procedures that check a value against its field's valid, and record
// a failure, as the decoder's check_valid, check_constant and fail_check
// (reader/checks.odin) do.

// The procedure that checks a value of node, of Odin type elem, against
// node.valid: check_N(d, value, index) -> err.
@(private)
check_proc :: proc(g: ^Generator, node: ^mdata.Node, elem: string) -> string {
	return need(g, {name = fmt.tprintf("check_%d", id_of(g, node)), write = write_check, node = node, k = -1})
}

// The procedure that records kind, which checking a value of node gave:
// fail_check_N(d, kind, offset, value, index) -> kind.
@(private)
fail_check_proc :: proc(g: ^Generator, node: ^mdata.Node, elem: string) -> string {
	return need(g, {name = fmt.tprintf("fail_check_%d", id_of(g, node)), write = write_fail_check, node = node, k = -1})
}

// As check_proc, for bit field b of node.
@(private)
bit_check_proc :: proc(g: ^Generator, node: ^mdata.Node, b: int) -> string {
	return need(g, {name = fmt.tprintf("check_%d_bit_%d", id_of(g, node), b), write = write_check, node = node, k = b})
}

@(private)
bit_fail_check_proc :: proc(g: ^Generator, node: ^mdata.Node, b: int) -> string {
	return need(g, {name = fmt.tprintf("fail_check_%d_bit_%d", id_of(g, node), b), write = write_fail_check, node = node, k = b})
}

// The valid, and the Odin type of the values, that w checks: node's, or
// with k at least 0, its bit field k's.
@(private = "file")
checked :: proc(g: ^Generator, w: Work) -> (valid: mdata.Valid, elem: string) {
	if w.k >= 0 {
		bit := w.node.bits[w.k]
		return bit.valid, scalar_type(bit.type)
	}
	e, _ := elem_type(g, w.node)
	return w.node.valid, e
}

@(private = "file")
write_check :: proc(g: ^Generator, w: Work) {
	valid, elem := checked(g, w)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, value: %s, index: int) -> dat.Read_Error {", w.name, elem)
	switch c in valid {
	case mdata.Valid_In_Enum:
		// a u64 above max(int) is in no enum, whose values are ints
		line(g, 1, "switch i128(value) {")
		if len(c.values) > 0 {
			b := strings.builder_make(context.temp_allocator)
			for v, i in c.values {
				if i > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "%d", v)
			}
			line(g, 1, "case %s:", strings.to_string(b))
			line(g, 2, "return .None")
		}
		line(g, 1, "}")
		line(g, 1, "return .Not_In_Enum")
	case mdata.Valid_Expr:
		line(g, 1, "value := value")
		line(g, 1, "ctx := dat.Eval_Context{index = index, element = &value}")
		for check in c.checks {
			line(g, 1, "if !(%s(d, &ctx) or_return) do return .%v", ev_proc(g, check.cond), check.err)
		}
		line(g, 1, "return .None")
	case mdata.Valid_Eq:
		line(g, 1, "if %s do return .Not_Equal", compare(elem, "!=", c.value))
		line(g, 1, "return .None")
	case mdata.Valid_Range:
		// written !(lo <= v) and !(v <= hi), so that a NaN fails every range
		if c.min != nil do line(g, 1, "if !(%s) do return .Less_Than_Min", compare_bound(elem, c.min, true))
		if c.max != nil do line(g, 1, "if !(%s) do return .Greater_Than_Max", compare_bound(elem, c.max, false))
		line(g, 1, "return .None")
	case mdata.Valid_Any_Of:
		for x in c.values do line(g, 1, "if %s do return .None", compare(elem, "==", x))
		line(g, 1, "return .Not_Any_Of")
	case:
		line(g, 1, "return .None")
	}
	line(g, 0, "}")
	line(g, 0, "")
}

// value op x, a constant of the field's type, as Odin.
@(private = "file")
compare :: proc(elem, op: string, x: mdata.Scalar) -> string {
	#partial switch v in x {
	case []byte:
		return fmt.tprintf("string(value) %s %s", op, quoted(string(v)))
	case string:
		return fmt.tprintf("value %s %s", op, quoted(v))
	}
	return fmt.tprintf("value %s %s", op, scalar_code(elem, x))
}

// lo <= value (min) or value <= hi.
@(private = "file")
compare_bound :: proc(elem: string, x: mdata.Scalar, min: bool) -> string {
	if min do return fmt.tprintf("%s <= value", scalar_code(elem, x))
	return fmt.tprintf("value <= %s", scalar_code(elem, x))
}

// x, a constant of the type elem, as an Odin constant of it.
@(private = "file")
scalar_code :: proc(elem: string, x: mdata.Scalar) -> string {
	switch v in x {
	case i8:     return fmt.tprintf("%s(%d)", elem, v)
	case i16:    return fmt.tprintf("%s(%d)", elem, v)
	case i32:    return fmt.tprintf("%s(%d)", elem, v)
	case i64:    return fmt.tprintf("%s(%d)", elem, v)
	case u8:     return fmt.tprintf("%s(%d)", elem, v)
	case u16:    return fmt.tprintf("%s(%d)", elem, v)
	case u32:    return fmt.tprintf("%s(%d)", elem, v)
	case u64:    return fmt.tprintf("%s(%d)", elem, v)
	case f32:    return fmt.tprintf("transmute(f32)u32(0x%08x)", transmute(u32)v)
	case f64:    return float_literal(v)
	case string: return quoted(v)
	case []byte: return quoted(string(v))
	}
	return "nil"
}

// fail_check: records kind; when it is a check's failure, also the value
// read and what the check expected, an expression a Valid_Expr compares
// with evaluated again, which shows nothing if that fails.
@(private = "file")
write_fail_check :: proc(g: ^Generator, w: Work) {
	valid, elem := checked(g, w)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, kind: dat.Read_Error, offset: int, value: %s, index: int) -> dat.Read_Error {", w.name, elem)
	line(g, 1, "if !dat.is_check_error(kind) do return dat.fail(d, kind, offset)")
	line(g, 1, "if d.err.kind != .None do return kind")
	line(g, 1, "expected := strings.builder_make()")
	switch c in valid {
	case mdata.Valid_Eq:
		line(g, 1, "strings.write_string(&expected, %s)", quoted(shown(c.value)))
	case mdata.Valid_Range:
		line(g, 1, "strings.write_string(&expected, kind == .Less_Than_Min ? %s : %s)", quoted(shown(c.min)), quoted(shown(c.max)))
	case mdata.Valid_Any_Of:
		b := strings.builder_make(context.temp_allocator)
		for x, i in c.values {
			if !dat.write_list_item(&b, i) do break
			strings.write_string(&b, shown(x))
		}
		line(g, 1, "strings.write_string(&expected, %s)", quoted(strings.to_string(b)))
	case mdata.Valid_In_Enum:
		b := strings.builder_make(context.temp_allocator)
		for x, i in c.values {
			if !dat.write_list_item(&b, i) do break
			fmt.sbprintf(&b, "%d", x)
		}
		line(g, 1, "strings.write_string(&expected, %s)", quoted(strings.to_string(b)))
	case mdata.Valid_Expr:
		// the first check of the kind, but for expr, which expects nothing it
		// can show: the operands _ is compared with, as a list
		seen := make(map[dat.Read_Error]bool, context.temp_allocator)
		shown_checks := make([dynamic]mdata.Valid_Check, context.temp_allocator)
		for check in c.checks {
			if seen[check.err] do continue
			seen[check.err] = true
			if check.err == .Expr_False do continue
			leaves := make([dynamic]^mdata.Expr, context.temp_allocator)
			operands(check.cond, &leaves)
			if len(leaves) > 0 do append(&shown_checks, check)
		}
		if len(shown_checks) > 0 {
			line(g, 1, "value := value")
			line(g, 1, "ctx := dat.Eval_Context{index = index, element = &value}")
		}
		for check in shown_checks {
			leaves := make([dynamic]^mdata.Expr, context.temp_allocator)
			operands(check.cond, &leaves)
			label := temp(g, "list")
			line(g, 1, "if kind == .%v {", check.err)
			line(g, 2, "ok := true")
			line(g, 2, "%s: {", label)
			for leaf, i in leaves {
				line(g, 3, "if !dat.write_list_item(&expected, %d) do break %s", i, label)
				line(g, 3, "v, err := %s(d, &ctx)", ev_proc(g, leaf))
				line(g, 3, "if err != .None {")
				line(g, 4, "ok = false")
				line(g, 4, "break %s", label)
				line(g, 3, "}")
				show_value(g, 3, leaf.type, "v")
			}
			line(g, 2, "}")
			line(g, 2, "if !ok do strings.builder_reset(&expected)")
			line(g, 1, "}")
		}
	}
	line(g, 1, "read := strings.builder_make()")
	show_elem(g, 1, w, elem, "value")
	line(g, 1, "return dat.fail_check(d, kind, offset, strings.to_string(read), strings.to_string(expected))")
	line(g, 0, "}")
	line(g, 0, "")
}

// Appends the operands that cond, a check of a Valid_Expr, compares _ with
// to leaves: eq, min and max compare _ with theirs (_ == x, _ >= x,
// _ <= x), and any-of is an or of such comparisons.
@(private = "file")
operands :: proc(cond: ^mdata.Expr, leaves: ^[dynamic]^mdata.Expr) {
	x, is_binary := cond.variant.(mdata.Binary)
	if !is_binary do return
	if x.op == .Logical_Or {
		operands(x.left, leaves)
		operands(x.right, leaves)
		return
	}
	append(leaves, x.right)
}

// Writes the lines that append v, an expression value of type t, to the
// builder expected, as a Parse_Error shows it; nothing for a set or an
// array.
@(private = "file")
show_value :: proc(g: ^Generator, depth: int, t: mdata.Expr_Type, v: string) {
	#partial switch t {
	case .Int:
		line(g, depth, "dat.show_wide(&expected, %s)", v)
	case .Float:
		line(g, depth, "dat.show_f64(&expected, %s)", v)
	case .Bool:
		line(g, depth, "dat.show_bool(&expected, %s)", v)
	case .Bytes:
		line(g, depth, "dat.show_blob(&expected, %s)", v)
	case .String:
		line(g, depth, "dat.show_string(&expected, %s)", v)
	case:
		line(g, depth, "_ = %s", v)
	}
}

// Writes the lines that append value, a value of the Odin type elem that
// w's node holds, to the builder read, as a Parse_Error shows it; nothing
// for a set.
@(private = "file")
show_elem :: proc(g: ^Generator, depth: int, w: Work, elem, value: string) {
	if w.k < 0 && w.node.switch_on != nil && is_union(g, w.node) {
		line(g, depth, "switch x in %s {", value)
		for variant in switch_variants(g, w.node) {
			line(g, depth, "case %s:", variant)
			show_scalar(g, depth + 1, variant, "x")
		}
		line(g, depth, "}")
		return
	}
	show_scalar(g, depth, elem, value)
}

@(private = "file")
show_scalar :: proc(g: ^Generator, depth: int, elem, value: string) {
	switch elem {
	case "i8", "i16", "i32", "i64":
		line(g, depth, "dat.show_int(&read, i64(%s))", value)
	case "u8", "u16", "u32", "u64":
		line(g, depth, "dat.show_uint(&read, u64(%s))", value)
	case "f32":
		line(g, depth, "dat.show_f32(&read, %s)", value)
	case "f64":
		line(g, depth, "dat.show_f64(&read, %s)", value)
	case "bool":
		line(g, depth, "dat.show_bool(&read, %s)", value)
	case "string":
		line(g, depth, "dat.show_string(&read, %s)", value)
	case "[]byte":
		line(g, depth, "dat.show_blob(&read, %s)", value)
	case:
		// a set's value is not shown
		line(g, depth, "_ = %s", value)
	}
}

// x as a Parse_Error shows it, written now, as the decoder writes it.
@(private = "file")
shown :: proc(x: mdata.Scalar) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch v in x {
	case i8:     dat.show_int(&b, i64(v))
	case i16:    dat.show_int(&b, i64(v))
	case i32:    dat.show_int(&b, i64(v))
	case i64:    dat.show_int(&b, v)
	case u8:     dat.show_uint(&b, u64(v))
	case u16:    dat.show_uint(&b, u64(v))
	case u32:    dat.show_uint(&b, u64(v))
	case u64:    dat.show_uint(&b, v)
	case f32:    dat.show_f32(&b, v)
	case f64:    dat.show_f64(&b, v)
	case string: dat.show_string(&b, v)
	case []byte: dat.show_blob(&b, v)
	}
	return strings.to_string(b)
}
