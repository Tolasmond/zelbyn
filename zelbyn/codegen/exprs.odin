package codegen

import expr "../expression"
import mdata "../metadata"
import "core:fmt"
import "core:strings"

// The procedures that evaluate expressions. Each expression of the plan
// that is not a literal has one, which follows the decoder's eval
// (reader/eval.odin) for its variant: it evaluates its operands in the
// same order, in an Eval_Context as the decoder's, and fails with the same
// error. The values are, by type: Int an i128 (from min(int) to max(u64),
// as data's integer operations keep them), Float an f64, Bool, Bytes a
// []byte, String a string, Array a data.Array, Struct an instance's
// address, and Stream a data.Stream.

// The Odin type of the values of an expression of type t.
@(private)
expr_type :: proc(t: mdata.Expr_Type) -> string {
	switch t {
	case .Int:
		return "i128"
	case .Float:
		return "f64"
	case .Bool:
		return "bool"
	case .Bytes:
		return "[]byte"
	case .String:
		return "string"
	case .Array:
		return "dat.Array"
	case .Struct:
		return "rawptr"
	case .Stream:
		return "dat.Stream"
	case .Unresolved:
	}
	panic("expr_type: an unresolved expression")
}

// The procedure that evaluates e: ev_N(d, ctx) -> (value, err).
@(private)
ev_proc :: proc(g: ^Generator, e: ^mdata.Expr) -> string {
	return need(g, {name = fmt.tprintf("ev_%d", id_of(g, e)), write = write_ev, expr = e})
}

// The procedure that gives the instance up levels above the one e, a
// Struct expression, gives: enc_N(d, ctx, up), the decoder's enclosing.
@(private = "file")
enc_proc :: proc(g: ^Generator, e: ^mdata.Expr) -> string {
	return need(g, {name = fmt.tprintf("enc_%d", id_of(g, e)), write = write_enc, expr = e})
}

// The procedure that evaluates value instance v in the context of the
// instance it is evaluated for: vi_N(d, ctx) -> (value, err).
@(private = "file")
vi_proc :: proc(g: ^Generator, v: ^mdata.Value_Instance) -> string {
	return need(g, {name = fmt.tprintf("vi_%d", id_of(g, v)), write = write_vi, value = v})
}

// The procedure that gives the stream of e, a Stream expression in the set
// instance being decoded, as the decoder's eval_stream: a copy, which a
// parse instance with io is read from.
@(private)
stream_value_proc :: proc(g: ^Generator, e: ^mdata.Expr) -> string {
	return need(g, {name = fmt.tprintf("stream_value_%d", id_of(g, e)), write = write_stream_value, expr = e})
}

// The procedure that gives the reader of e, a Stream expression, in ctx, as
// the decoder's stream_reader, for .pos, .size and .eof.
@(private = "file")
stream_reader_proc :: proc(g: ^Generator, e: ^mdata.Expr) -> string {
	return need(g, {name = fmt.tprintf("stream_reader_%d", id_of(g, e)), write = write_stream_reader, expr = e})
}

// e as an Odin literal of its value, when it is a literal; ok is false
// otherwise.
@(private)
literal :: proc(e: ^mdata.Expr) -> (code: string, ok: bool) {
	#partial switch x in e.variant {
	case mdata.Int_Literal:
		return fmt.tprintf("i128(%d)", x.value), true
	case mdata.Big_Literal:
		return fmt.tprintf("i128(%d)", x.value), true
	case mdata.Float_Literal:
		return float_literal(x.value), true
	case mdata.Bool_Literal:
		return x.value ? "true" : "false", true
	case mdata.String_Literal:
		return quoted(x.value), true
	}
	return "", false
}

// f exactly, by its bits.
@(private)
float_literal :: proc(f: f64) -> string {
	return fmt.tprintf("transmute(f64)u64(0x%016x)", transmute(u64)f)
}

// The value of e, in the procedure being written: a literal, or a
// temporary that the lines written for it hold it in.
@(private = "file")
operand :: proc(g: ^Generator, depth: int, e: ^mdata.Expr) -> string {
	if code, ok := literal(e); ok do return code
	t := temp(g, "t")
	line(g, depth, "%s := %s(d, ctx) or_return", t, ev_proc(g, e))
	return t
}

@(private = "file")
write_ev :: proc(g: ^Generator, w: Work) {
	e := w.expr
	text := expr.to_string(e, context.temp_allocator)
	line(g, 0, "// %s", one_line(text))
	line(g, 0, "%s :: proc(d: ^dat.Decoder, ctx: ^dat.Eval_Context) -> (v: %s, err: dat.Read_Error) {", w.name, expr_type(e.type))
	if code, ok := literal(e); ok {
		line(g, 1, "return %s, .None", code)
		line(g, 0, "}")
		line(g, 0, "")
		return
	}
	switch x in e.variant {
	case mdata.Int_Literal, mdata.Big_Literal, mdata.Float_Literal, mdata.Bool_Literal, mdata.String_Literal:
		unreachable()
	case mdata.Index:
		write_index(g, e, x)
	case mdata.String_Length:
		o := operand(g, 1, x.operand)
		line(g, 1, "return i128(utf8.rune_count_in_string(%s)), .None", o)
	case mdata.To_S:
		o := operand(g, 1, x.operand)
		line(g, 1, "return dat.int_to_string(%s, context.allocator)", o)
	case mdata.Decode:
		o := operand(g, 1, x.operand)
		if x.encoding == .None {
			line(g, 1, "return string(%s), .None", o)
		} else {
			line(g, 1, "return dat.decode_text(%s, .%v, context.allocator)", o, x.encoding)
		}
	case mdata.Substring:
		o := operand(g, 1, x.operand)
		from := operand(g, 1, x.from)
		to := operand(g, 1, x.to)
		// an index above max(int) is max(int)
		line(g, 1, "return dat.substring(%s, int(min(%s, i128(max(int)))), int(min(%s, i128(max(int)))))", o, from, to)
	case mdata.To_Bytes:
		o := operand(g, 1, x.operand)
		line(g, 1, "return dat.array_to_bytes(%s, context.allocator)", o)
	case mdata.Root_Arg:
		fail(g, "an argument of the top-level type outside its params")
	case mdata.To_I:
		o := operand(g, 1, x.operand)
		#partial switch x.operand.type {
		case .Bool:
			line(g, 1, "return i128(int(%s)), .None", o)
		case .Float:
			line(g, 1, "return dat.float_to_int(%s)", o)
		case:
			line(g, 1, "return dat.string_to_int(%s)", o)
		}
	case mdata.Array_Method:
		o := operand(g, 1, x.operand)
		if x.operand.type == .Bytes {
			switch x.method {
			case .First:
				line(g, 1, "return dat.bytes_item(%s, 0)", o)
			case .Last:
				line(g, 1, "return dat.bytes_item(%s, i128(len(%s)) - 1)", o, o)
			case .Min, .Max:
				line(g, 1, "return dat.bytes_min_max(%s, %v)", o, x.method == .Max)
			}
		} else {
			switch x.method {
			case .First:
				line(g, 1, "return %s(%s, 0)", array_item_proc(e.type), o)
			case .Last:
				line(g, 1, "return %s(%s, dat.array_last(%s))", array_item_proc(e.type), o, o)
			case .Min, .Max:
				line(g, 1, "return dat.array_min_max(%s, %v)", o, x.method == .Max)
			}
		}
	case mdata.Unary:
		o := operand(g, 1, x.operand)
		switch x.op {
		case .Neg:
			if x.operand.type == .Float {
				line(g, 1, "return -%s, .None", o)
			} else {
				line(g, 1, "return dat.int_neg(%s)", o)
			}
		case .Bit_Not:
			line(g, 1, "return dat.int_not(%s)", o)
		case .Not:
			line(g, 1, "return !%s, .None", o)
		}
	case mdata.Binary:
		write_binary(g, e, x)
	case mdata.Ternary:
		c := operand(g, 1, x.cond)
		line(g, 1, "if %s {", c)
		then := operand(g, 2, x.then)
		line(g, 2, "return %s, .None", then)
		line(g, 1, "}")
		otherwise := operand(g, 1, x.otherwise)
		line(g, 1, "return %s, .None", otherwise)
	case mdata.Instance:
		if x.root {
			line(g, 1, "return dat.root_instance(d)")
		} else {
			if x.imported_root {
				set, found := g.set_ids[x.node]
				if !found {
					fail(g, "the _root of an imported schema that is not read")
					return
				}
				big := -1
				if x.node.order_switch != nil do big = g.set_ids[x.node.order_switch.big]
				line(g, 1, "if ctx.self == nil do return dat.imported_root(d, %d, %d)", set, big)
			}
			line(g, 1, "return dat.ancestor(d, ctx, %d)", x.up)
		}
	case mdata.Field_Ref:
		write_field_ref(g, e, x)
	case mdata.Size:
		o := operand(g, 1, x.operand)
		if x.operand.type == .Bytes {
			line(g, 1, "return i128(len(%s)), .None", o)
		} else {
			line(g, 1, "return i128(dat.array_len(%s)), .None", o)
		}
	case mdata.Io_Pos:
		r := reader(g, x.stream)
		line(g, 1, "return i128(%s.pos), .None", r)
	case mdata.Io_Size:
		r := reader(g, x.stream)
		line(g, 1, "return i128(len(%s.data)), .None", r)
	case mdata.Io_Eof:
		r := reader(g, x.stream)
		line(g, 1, "return dat.at_eof(%s), .None", r)
	case mdata.Repeat_Index:
		line(g, 1, `assert(ctx.index >= 0, "_index outside a repeat")`)
		line(g, 1, "return i128(ctx.index), .None")
	case mdata.Repeat_Element:
		// nil after an element of a switch-on that chose no case, which has
		// no value
		line(g, 1, "if ctx.element == nil do return {}, .Absent_Field")
		elem := elem_type(g, x.node) or_else ""
		line(g, 1, "element := (^%s)(ctx.element)^", elem)
		write_converted(g, 1, x.node, elem, "element", e.type)
	case mdata.Value_Ref:
		base := operand(g, 1, x.base)
		line(g, 1, "self := dat.Eval_Context{index = -1, self = %s, base = %s, caller = ctx}", base, enc_proc(g, x.base))
		line(g, 1, "return %s(d, &self)", vi_proc(g, x.instance))
	case mdata.Bytes_Literal:
		line(g, 1, "return %s[:], .None", bytes_constant(g, x.value))
	case mdata.Array_Literal:
		item := expr_type(x.item_type)
		line(g, 1, "items, alloc_err := make([]%s, %d)", item, len(x.items))
		line(g, 1, "if alloc_err != nil do return {}, .Memory_Limit")
		for item_expr, i in x.items {
			v := operand(g, 1, item_expr)
			line(g, 1, "items[%d] = %s", i, v)
		}
		line(g, 1, "return dat.array_from(items), .None")
	case mdata.Switch_Cast:
		write_switch_cast(g, e, x)
	case mdata.Io:
		fail(g, "a stream where a value is needed")
	case mdata.Name, mdata.Member, mdata.Enum_Constant, mdata.Size_Of, mdata.Cast, mdata.Call:
		fail(g, "an unresolved expression")
	}
	line(g, 0, "}")
	line(g, 0, "")
}

// The reader of stream, a Stream expression or nil for _io, in the lines
// being written.
@(private = "file")
reader :: proc(g: ^Generator, stream: ^mdata.Expr) -> string {
	r := temp(g, "r")
	if stream == nil {
		line(g, 1, "%s := dat.stream_of(d, ctx.self)", r)
	} else {
		line(g, 1, "%s := %s(d, ctx) or_return", r, stream_reader_proc(g, stream))
	}
	return r
}

// The data procedure that gives item i of an Array whose items have type t.
@(private = "file")
array_item_proc :: proc(t: mdata.Expr_Type) -> string {
	#partial switch t {
	case .Int:
		return "dat.array_int"
	case .Float:
		return "dat.array_float"
	case .Bool:
		return "dat.array_bool"
	case .Bytes:
		return "dat.array_bytes"
	case .String:
		return "dat.array_string"
	case .Struct:
		return "dat.array_struct"
	case .Array:
		return "dat.array_array"
	}
	panic("array_item_proc: not an item type")
}

// operand[index]: of a constant array literal, directly or as the
// expression of a value instance without an if, only the item it gives, as
// the decoder's literal_item; of any other, the whole operand.
@(private = "file")
write_index :: proc(g: ^Generator, e: ^mdata.Expr, x: mdata.Index) {
	operand_expr := x.operand
	if ref, is_ref := operand_expr.variant.(mdata.Value_Ref); is_ref && ref.instance.cond == nil && !ref.instance.cached {
		if lit, is_literal := ref.instance.expr.variant.(mdata.Array_Literal); is_literal && lit.constant {
			base := operand(g, 1, ref.base)
			line(g, 1, "_ = %s", base)
			operand_expr = ref.instance.expr
		}
	}
	if lit, is_literal := operand_expr.variant.(mdata.Array_Literal); is_literal && lit.constant {
		i := operand(g, 1, x.index)
		line(g, 1, "if %s < 0 || %s >= %d do return {}, .Index_Out_Of_Range", i, i, len(lit.items))
		line(g, 1, "switch %s {", i)
		for item, k in lit.items {
			line(g, 1, "case %d:", k)
			v := operand(g, 2, item)
			line(g, 2, "return %s, .None", v)
		}
		line(g, 1, "}")
		line(g, 1, "unreachable()")
		return
	}
	o := operand(g, 1, x.operand)
	i := operand(g, 1, x.index)
	if x.operand.type == .Bytes {
		line(g, 1, "return dat.bytes_item(%s, %s)", o, i)
	} else {
		line(g, 1, "return %s(%s, %s)", array_item_proc(e.type), o, i)
	}
}

// Integer operations fail rather than wrap, through data's (eval_binary);
// and and or evaluate their right operand only when they need it; an
// operation with a float makes the integer a float (as_float).
@(private = "file")
write_binary :: proc(g: ^Generator, e: ^mdata.Expr, x: mdata.Binary) {
	l := operand(g, 1, x.left)
	#partial switch x.op {
	case .Logical_And:
		line(g, 1, "if !%s do return false, .None", l)
		r := operand(g, 1, x.right)
		line(g, 1, "return %s, .None", r)
		return
	case .Logical_Or:
		line(g, 1, "if %s do return true, .None", l)
		r := operand(g, 1, x.right)
		line(g, 1, "return %s, .None", r)
		return
	}
	r := operand(g, 1, x.right)
	lt, rt := x.left.type, x.right.type
	comparison := ""
	#partial switch x.op {
	case .Eq: comparison = "=="
	case .Ne: comparison = "!="
	case .Lt: comparison = "<"
	case .Le: comparison = "<="
	case .Gt: comparison = ">"
	case .Ge: comparison = ">="
	}

	if lt == .Float || rt == .Float {
		lf := lt == .Float ? l : fmt.tprintf("f64(%s)", l)
		rf := rt == .Float ? r : fmt.tprintf("f64(%s)", r)
		op := comparison
		#partial switch x.op {
		case .Mul: op = "*"
		case .Div: op = "/"
		case .Add: op = "+"
		case .Sub: op = "-"
		}
		if op == "" {
			fail(g, "operator %v on floats", x.op)
			return
		}
		line(g, 1, "return %s %s %s, .None", lf, op, rf)
		return
	}
	#partial switch lt {
	case .Int:
		if comparison != "" {
			line(g, 1, "return %s %s %s, .None", l, comparison, r)
			return
		}
		name: string
		#partial switch x.op {
		case .Mul: name = "int_mul"
		case .Div: name = "int_div"
		case .Mod: name = "int_mod"
		case .Add: name = "int_add"
		case .Sub: name = "int_sub"
		case .Shl: name = "int_shl"
		case .Shr: name = "int_shr"
		case .And: name = "int_and"
		case .Xor: name = "int_xor"
		case .Or:  name = "int_or"
		case:
			fail(g, "operator %v on integers", x.op)
			return
		}
		line(g, 1, "return dat.%s(%s, %s)", name, l, r)
	case .String:
		if x.op == .Add {
			line(g, 1, "return dat.join_strings(%s, %s, context.allocator)", l, r)
			return
		}
		line(g, 1, "return %s %s %s, .None", l, comparison, r)
	case .Bytes:
		// byte arrays compare byte by byte, as strings do
		line(g, 1, "return string(%s) %s string(%s), .None", l, comparison, r)
	case .Bool:
		line(g, 1, "return %s %s %s, .None", l, comparison, r)
	case:
		fail(g, "operator %v on %v", x.op, lt)
	}
}

// The values of x's field in the instance its base gives, the field read
// first when it is a parse instance that has not been: all of them for an
// Array, else its value, and Absent_Field when it has none.
@(private = "file")
write_field_ref :: proc(g: ^Generator, e: ^mdata.Expr, x: mdata.Field_Ref) {
	s, f := field_of(g, x.node)
	base := operand(g, 1, x.base)
	line(g, 1, "base := (^%s)(%s)", s.name, base)
	if f.parse >= 0 {
		word, mask := bit_of(f.parse)
		line(g, 1, "if base._read[%d] & %s == 0 do dat.read_parse_instance(d, base, %d, %s, %v) or_return", word, mask, f.parse, parse_dispatch(s), x.node.io != nil)
	}
	if e.type == .Array {
		if f.storage != .Array {
			fail(g, "%s: an array of a field read once", x.node.name)
			return
		}
		if strings.has_prefix(f.elem, "^") || !is_switch_union(g, f) {
			line(g, 1, "return dat.array_of(&base.%s), .None", f.name)
			return
		}
		// the values of a switch-on field of cases of several types, made
		// one type
		item := expr_type(node_expr_type(x.node))
		line(g, 1, "items, alloc_err := make([]%s, len(base.%s))", item, f.name)
		line(g, 1, "if alloc_err != nil do return {}, .Memory_Limit")
		line(g, 1, "for value, i in base.%s {", f.name)
		write_union_item(g, 2, x.node, f.elem, "value", "items[i]")
		line(g, 1, "}")
		line(g, 1, "return dat.array_from(items), .None")
		return
	}
	switch f.storage {
	case .Plain:
		line(g, 1, "if !(%s) do return {}, .Absent_Field", present(f, "base"))
		write_converted(g, 1, x.node, f.elem, fmt.tprintf("base.%s", f.name), e.type)
	case .Maybe:
		line(g, 1, "value, ok := base.%s.?", f.name)
		line(g, 1, "if !ok do return {}, .Absent_Field")
		write_converted(g, 1, x.node, f.elem, "value", e.type)
	case .Pointer, .Union:
		line(g, 1, "if base.%s == nil do return {}, .Absent_Field", f.name)
		write_converted(g, 1, x.node, f.elem, fmt.tprintf("base.%s", f.name), e.type)
	case .Param:
		write_converted(g, 1, x.node, f.elem, fmt.tprintf("base.%s", f.name), e.type)
	case .Array:
		fail(g, "%s: one value of a repeated field", x.node.name)
	}
}

// Whether f holds the values of a switch-on field in a union.
@(private = "file")
is_switch_union :: proc(g: ^Generator, f: ^Field) -> bool {
	return f.node.switch_on != nil && is_union(g, f.node)
}

// The type of the expression values of node's values.
@(private)
node_expr_type :: proc(node: ^mdata.Node) -> mdata.Expr_Type {
	#partial switch node.type {
	case .Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64, .Bits:
		return .Int
	case .Float32, .Float64:
		return .Float
	case .Bool:
		return .Bool
	case .String:
		return .String
	case .Blob:
		return .Bytes
	case .Set:
		if sw := node.switch_on; sw != nil {
			// the cases' type, which the compiler made one
			if len(sw.cases) > 0 do return node_expr_type(sw.cases[0].node)
			if sw.default != nil do return node_expr_type(sw.default)
			return .Bytes
		}
		return .Struct
	}
	panic("node_expr_type: no type")
}

// Writes the return of value, a value of node of Odin type elem, as an
// expression value of type t (the decoder's single_value).
@(private = "file")
write_converted :: proc(g: ^Generator, depth: int, node: ^mdata.Node, elem, value: string, t: mdata.Expr_Type) {
	if node.switch_on != nil && is_union(g, node) {
		line(g, depth, "switch x in %s {", value)
		for variant in switch_variants(g, node) {
			line(g, depth, "case %s:", variant)
			line(g, depth + 1, "return %s, .None", convert(variant, "x", t))
		}
		line(g, depth, "}")
		line(g, depth, "return {}, .Absent_Field")
		return
	}
	line(g, depth, "return %s, .None", convert(elem, value, t))
}

// Writes the line that sets target, an item of type node's expression
// type, to value, a value of node's union.
@(private = "file")
write_union_item :: proc(g: ^Generator, depth: int, node: ^mdata.Node, elem, value, target: string) {
	t := node_expr_type(node)
	line(g, depth, "switch x in %s {", value)
	for variant in switch_variants(g, node) {
		line(g, depth, "case %s:", variant)
		line(g, depth + 1, "%s = %s", target, convert(variant, "x", t))
	}
	line(g, depth, "}")
}

// value, of Odin type elem, as an expression value of type t.
@(private = "file")
convert :: proc(elem, value: string, t: mdata.Expr_Type) -> string {
	#partial switch t {
	case .Int:
		return fmt.tprintf("i128(%s)", value)
	case .Float:
		return fmt.tprintf("f64(%s)", value)
	case .Struct:
		return fmt.tprintf("rawptr(%s)", value)
	}
	return value
}

// operand.as<t>: operand, a switch-on field read once, as an instance of a
// case of t; Wrong_Type when it was read as another case, or is not an
// instance.
@(private = "file")
write_switch_cast :: proc(g: ^Generator, e: ^mdata.Expr, x: mdata.Switch_Cast) {
	ref, is_ref := x.operand.variant.(mdata.Field_Ref)
	if !is_ref {
		fail(g, "a cast of an expression that is not a switch-on field")
		return
	}
	s, f := field_of(g, ref.node)
	base := operand(g, 1, ref.base)
	line(g, 1, "base := (^%s)(%s)", s.name, base)
	if f.parse >= 0 {
		word, mask := bit_of(f.parse)
		line(g, 1, "if base._read[%d] & %s == 0 do dat.read_parse_instance(d, base, %d, %s, %v) or_return", word, mask, f.parse, parse_dispatch(s), ref.node.io != nil)
	}
	line(g, 1, "instance: rawptr")
	switch f.storage {
	case .Maybe:
		line(g, 1, "value, ok := base.%s.?", f.name)
		line(g, 1, "if !ok do return {}, .Absent_Field")
		line(g, 1, "_ = value")
		line(g, 1, "return {}, .Wrong_Type")
		return
	case .Plain:
		line(g, 1, "if !(%s) do return {}, .Absent_Field", present(f, "base"))
		line(g, 1, "return {}, .Wrong_Type")
		return
	case .Pointer:
		line(g, 1, "if base.%s == nil do return {}, .Absent_Field", f.name)
		line(g, 1, "instance = base.%s", f.name)
	case .Union:
		line(g, 1, "if base.%s == nil do return {}, .Absent_Field", f.name)
		line(g, 1, "#partial switch x in base.%s {", f.name)
		for variant in switch_variants(g, ref.node) {
			if !strings.has_prefix(variant, "^") do continue
			line(g, 1, "case %s:", variant)
			line(g, 2, "instance = x")
		}
		line(g, 1, "}")
		line(g, 1, "if instance == nil do return {}, .Wrong_Type")
	case .Array, .Param:
		fail(g, "%s: a cast of a field that is not read once", ref.node.name)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for c, i in x.choices {
		if i > 0 do strings.write_string(&b, " && ")
		fmt.sbprintf(&b, "choice != %d", c)
	}
	line(g, 1, "choice := (^dat.Header)(instance).choice")
	line(g, 1, "if %s do return {}, .Wrong_Type", len(x.choices) > 0 ? strings.to_string(b) : "true")
	line(g, 1, "return instance, .None")
}

// The constant that holds bytes, a Bytes literal, declared the first time.
@(private = "file")
bytes_constant :: proc(g: ^Generator, bytes: []byte) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x, i in bytes {
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "0x%02x", x)
	}
	items := strings.to_string(b)
	if found, ok := g.constants[items]; ok do return found
	name := fmt.tprintf("BYTES_%d", len(g.constants))
	g.constants[items] = name
	decl(g, 0, "@(private = \"file\", rodata)")
	decl(g, 0, "%s := [%d]byte{%s}", name, len(bytes), items)
	decl(g, 0, "")
	return name
}

// enclosing: the instance up levels above the one that e, a Struct
// expression evaluated in ctx, gives. Each variant does as one turn of the
// decoder's loop.
@(private = "file")
write_enc :: proc(g: ^Generator, w: Work) {
	e := w.expr
	line(g, 0, "%s :: proc(d: ^dat.Decoder, ctx: ^dat.Eval_Context, up: int) -> (instance: rawptr, err: dat.Read_Error) {", w.name)
	#partial switch x in e.variant {
	case mdata.Field_Ref:
		// a field's instance is in the instance of its base, which is its
		// _parent, or with a parent, is parent_up levels inside it
		line(g, 1, "level := up + %d", x.node.parent_up - 1)
		line(g, 1, "if level == 0 do return %s(d, ctx)", ev_proc(g, x.base))
		line(g, 1, "return %s(d, ctx, level)", enc_proc(g, x.base))
	case mdata.Index:
		// an element is in the instance of its array's field
		line(g, 1, "return %s(d, ctx, up)", enc_proc(g, x.operand))
	case mdata.Array_Method:
		line(g, 1, "return %s(d, ctx, up)", enc_proc(g, x.operand))
	case mdata.Switch_Cast:
		line(g, 1, "return %s(d, ctx, up)", enc_proc(g, x.operand))
	case mdata.Ternary:
		line(g, 1, "cond := %s(d, ctx) or_return", ev_proc(g, x.cond))
		line(g, 1, "if cond do return %s(d, ctx, up)", enc_proc(g, x.then))
		line(g, 1, "return %s(d, ctx, up)", enc_proc(g, x.otherwise))
	case mdata.Value_Ref:
		// the instance a value instance gives is reached through its
		// expression, evaluated for the instance of its base
		line(g, 1, "base := %s(d, ctx) or_return", ev_proc(g, x.base))
		line(g, 1, "self := dat.Eval_Context{index = -1, self = base, base = %s, caller = ctx}", enc_proc(g, x.base))
		line(g, 1, "return %s(d, &self, up)", enc_proc(g, x.instance.expr))
	case mdata.Instance:
		if x.root {
			line(g, 1, "return nil, .Absent_Field")
		} else {
			line(g, 1, "return dat.ancestor(d, ctx, %d + up)", x.up)
		}
	case mdata.Repeat_Element:
		// _ is in the instance being decoded
		line(g, 1, "return dat.ancestor(d, ctx, up - 1)")
	case:
		// never called: only an expression that reaches out of a value
		// instance walks its base, and the compiler finds such a base
		line(g, 1, `panic("%s: not a set instance")`, w.name)
	}
	line(g, 0, "}")
	line(g, 0, "")
}

// eval_value_ref, eval_cached and eval_kept: the value of value instance v,
// for the instance ctx is of, kept from its first evaluation when it is
// cached. A field's values are kept as the field (data.array_of), which
// they are as it grows.
@(private = "file")
write_vi :: proc(g: ^Generator, w: Work) {
	v := w.value
	t := expr_type(v.expr.type)
	id := id_of(g, v)
	line(g, 0, "// the value instance %s", v.name)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, ctx: ^dat.Eval_Context) -> (v: %s, err: dat.Read_Error) {", w.name, t)
	if v.cached do line(g, 1, "if cell := dat.cached(d, ctx.self, %d); cell != nil do return (^%s)(cell)^, .None", id, t)
	if v.cond != nil {
		line(g, 1, "cond := %s(d, ctx) or_return", ev_proc(g, v.cond))
		line(g, 1, "if !cond do return {}, .Absent_Field")
	}
	line(g, 1, "v = %s(d, ctx) or_return", ev_proc(g, v.expr))
	// as in Kaitai, a value instance that has no value is evaluated again
	if v.cached do line(g, 1, "dat.keep_cached(d, ctx.self, %d, v) or_return", id)
	line(g, 1, "return v, .None")
	line(g, 0, "}")
	line(g, 0, "")
}

@(private = "file")
write_stream_value :: proc(g: ^Generator, w: Work) {
	e := w.expr
	line(g, 0, "%s :: proc(d: ^dat.Decoder) -> (stream: dat.Stream, err: dat.Read_Error) {", w.name)
	#partial switch x in e.variant {
	case mdata.Ternary:
		line(g, 1, "ctx := dat.Eval_Context{index = -1}")
		line(g, 1, "cond := %s(d, &ctx) or_return", ev_proc(g, x.cond))
		line(g, 1, "if cond do return %s(d)", stream_value_proc(g, x.then))
		line(g, 1, "return %s(d)", stream_value_proc(g, x.otherwise))
	case mdata.Io:
		line(g, 1, "ctx := dat.Eval_Context{index = -1}")
		line(g, 1, "instance := %s(d, &ctx) or_return", ev_proc(g, x.instance))
		line(g, 1, "return dat.stream_value(d, instance), .None")
	case:
		fail(g, "a stream that is neither _io nor ?:")
	}
	line(g, 0, "}")
	line(g, 0, "")
}

@(private = "file")
write_stream_reader :: proc(g: ^Generator, w: Work) {
	e := w.expr
	line(g, 0, "%s :: proc(d: ^dat.Decoder, ctx: ^dat.Eval_Context) -> (r: ^dat.Reader, err: dat.Read_Error) {", w.name)
	#partial switch x in e.variant {
	case mdata.Ternary:
		line(g, 1, "cond := %s(d, ctx) or_return", ev_proc(g, x.cond))
		line(g, 1, "if cond do return %s(d, ctx)", stream_reader_proc(g, x.then))
		line(g, 1, "return %s(d, ctx)", stream_reader_proc(g, x.otherwise))
	case mdata.Io:
		line(g, 1, "instance := %s(d, ctx) or_return", ev_proc(g, x.instance))
		line(g, 1, "return dat.stream_of(d, instance), .None")
	case:
		fail(g, "a stream that is neither _io nor ?:")
	}
	line(g, 0, "}")
	line(g, 0, "")
}

// s on one line, for a comment.
@(private)
one_line :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", " ", context.temp_allocator)
	return out
}
