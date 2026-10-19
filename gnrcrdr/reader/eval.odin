package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "base:intrinsics"

// The value of an expression, by its type: Int, Bool, Bytes, Array and
// Struct in that order.
@(private = "file")
Eval_Value :: union {
	int,
	bool,
	[]byte,
	[]fld.Value,
	^fld.Instance,
}

// What _index and _ are, and the set instance whose value instance is
// being evaluated: index is -1 when the expression is not evaluated for an
// element of a repeat, element nil outside repeat-until, and self nil
// outside a value instance.
@(private = "file")
Eval_Context :: struct {
	index:   int,
	element: fld.Value,
	self:    ^fld.Instance,
}

// Evaluates e, an Int expression, in the set instance being decoded. index
// is _index, or -1 when e is not evaluated for an element of a repeat.
@(private, require_results)
eval_int :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1) -> (n: int, err: dat.Read_Error) {
	assert(e.type == .Int)
	if value, ok := eval_direct(d, e.direct, nil); ok do return value, .None
	v := eval(d, e, {index = index}) or_return
	return v.(int), .None
}

// Evaluates e, a Bool expression, as eval_int does. element is _, the
// element of a repeat-until just read.
@(private, require_results)
eval_bool :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1, element: fld.Value = nil) -> (b: bool, err: dat.Read_Error) {
	assert(e.type == .Bool)
	if n, ok := eval_direct(d, e.direct, element); ok do return n != 0, .None
	v := eval(d, e, {index = index, element = element}) or_return
	return v.(bool), .None
}

// Evaluates e, an Int, Bool or Bytes expression, as eval_int does, as a
// value of the tree: an Int is an i64.
@(private, require_results)
eval_value :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1) -> (value: fld.Value, err: dat.Read_Error) {
	v := eval(d, e, {index = index}) or_return
	#partial switch x in v {
	case int:
		return i64(x), .None
	case bool:
		return x, .None
	case []byte:
		return x, .None
	}
	panic("eval_value: not an Int, Bool or Bytes expression")
}

// The value of a direct form, a Bool as 0 or 1. ok is false when there is
// none, or when the field it reads has no value or one that does not fit
// an int: the tree is then evaluated, and gives the error.
@(private = "file", require_results)
eval_direct :: #force_inline proc(d: ^Decoder, direct: mdata.Direct, element: fld.Value) -> (n: int, ok: bool) {
	switch x in direct {
	case mdata.Direct_Constant:
		return x.value, true
	case mdata.Direct_Field:
		return direct_field(d, x, element)
	case mdata.Direct_Compare:
		v := direct_field(d, x.field, element) or_return
		result: bool
		#partial switch x.op {
		case .Eq:
			result = v == x.constant
		case .Ne:
			result = v != x.constant
		case .Lt:
			result = v < x.constant
		case .Le:
			result = v <= x.constant
		case .Gt:
			result = v > x.constant
		case .Ge:
			result = v >= x.constant
		case:
			panic("eval_direct: not a comparison")
		}
		return int(result), true
	}
	return
}

// The value of f's field, as single_value would give it; ok is false when
// the field has no value, or one that does not fit an int.
@(private = "file", require_results)
direct_field :: #force_inline proc(d: ^Decoder, f: mdata.Direct_Field, element: fld.Value) -> (n: int, ok: bool) {
	instance: ^fld.Instance
	if f.of_element {
		instance = element.(^fld.Instance) or_return
	} else {
		if len(d.frames) == 0 do return
		instance = d.frames[len(d.frames) - 1].instance
	}
	values := instance.slots[f.slot]
	if len(values) == 0 do return

	switch v in values[0] {
	case i8:
		return int(v), true
	case i16:
		return int(v), true
	case i32:
		return int(v), true
	case i64:
		return int(v), true
	case u8:
		return int(v), true
	case u16:
		return int(v), true
	case u32:
		return int(v), true
	case u64:
		if v > u64(max(int)) do return
		return int(v), true
	case f32, f64, string, []byte, bool, ^fld.Instance:
	}
	return
}

@(private = "file", require_results)
eval :: proc(d: ^Decoder, e: ^mdata.Expr, ctx: Eval_Context) -> (v: Eval_Value, err: dat.Read_Error) {
	switch x in e.variant {
	case mdata.Int_Literal:
		return x.value, .None
	case mdata.Bool_Literal:
		return x.value, .None
	case mdata.Unary:
		operand := eval(d, x.operand, ctx) or_return
		switch x.op {
		case .Neg:
			n := operand.(int)
			if n == min(int) do return nil, .Integer_Overflow
			return -n, .None
		case .Bit_Not:
			return ~operand.(int), .None
		case .Not:
			return !operand.(bool), .None
		}
	case mdata.Binary:
		return eval_binary(d, x, ctx)
	case mdata.Ternary:
		cond := eval(d, x.cond, ctx) or_return
		return eval(d, cond.(bool) ? x.then : x.otherwise, ctx)
	case mdata.Instance:
		// a value instance's expression refers only to its own instance
		if ctx.self != nil do return ctx.self, .None
		i := x.root ? 0 : len(d.frames) - 1 - x.up
		if i < 0 || i >= len(d.frames) do return nil, .Absent_Field
		return d.frames[i].instance, .None
	case mdata.Field_Ref:
		base := eval(d, x.base, ctx) or_return
		instance := base.(^fld.Instance)
		values := instance.slots[x.slot]
		if x.node.pos != nil && raw_data(values) == nil {
			read_parse_instance(d, instance, x.node, x.slot) or_return
			values = instance.slots[x.slot]
		}
		if e.type == .Array do return values[:], .None
		if len(values) == 0 do return nil, .Absent_Field
		return single_value(values[0])
	case mdata.Size:
		operand := eval(d, x.operand, ctx) or_return
		#partial switch o in operand {
		case []byte:
			return len(o), .None
		case []fld.Value:
			return len(o), .None
		}
	case mdata.Io_Pos:
		return d.r.pos, .None
	case mdata.Io_Size:
		return len(d.r.data), .None
	case mdata.Io_Eof:
		return dat.at_eof(&d.r), .None
	case mdata.Repeat_Index:
		assert(ctx.index >= 0, "eval: _index outside a repeat")
		return ctx.index, .None
	case mdata.Repeat_Element:
		assert(ctx.element != nil, "eval: _ outside repeat-until")
		return single_value(ctx.element)
	case mdata.Value_Ref:
		base := eval(d, x.base, ctx) or_return
		return eval(d, x.instance.expr, {index = -1, self = base.(^fld.Instance)})
	case mdata.Name, mdata.Member, mdata.Enum_Constant:
		panic("eval: unresolved expression")
	}
	panic("eval: invalid expression")
}

// The value of a field read once, as its expression type.
@(private = "file", require_results)
single_value :: proc(value: fld.Value) -> (Eval_Value, dat.Read_Error) {
	switch v in value {
	case i8:
		return int(v), .None
	case i16:
		return int(v), .None
	case i32:
		return int(v), .None
	case i64:
		return int(v), .None
	case u8:
		return int(v), .None
	case u16:
		return int(v), .None
	case u32:
		return int(v), .None
	case u64:
		if v > u64(max(int)) do return nil, .Integer_Overflow
		return int(v), .None
	case []byte:
		return v, .None
	case bool:
		return v, .None
	case ^fld.Instance:
		return v, .None
	case f32, f64, string:
		// the resolver rejects references to these
	}
	panic("eval: a field value of an unsupported type")
}

// Integer operations fail rather than wrap, and / and % round toward
// negative infinity (as Python does, and so Kaitai's Python runtime).
// and and or evaluate their right operand only when they need it.
@(private = "file", require_results)
eval_binary :: proc(d: ^Decoder, x: mdata.Binary, ctx: Eval_Context) -> (v: Eval_Value, err: dat.Read_Error) {
	left := eval(d, x.left, ctx) or_return

	#partial switch x.op {
	case .Logical_And:
		if !left.(bool) do return false, .None
		return eval(d, x.right, ctx)
	case .Logical_Or:
		if left.(bool) do return true, .None
		return eval(d, x.right, ctx)
	}

	right := eval(d, x.right, ctx) or_return

	if l, is_bool := left.(bool); is_bool {
		r := right.(bool)
		#partial switch x.op {
		case .Eq:
			return l == r, .None
		case .Ne:
			return l != r, .None
		}
		panic("eval: invalid operator on booleans")
	}

	a, b := left.(int), right.(int)
	n: int
	overflow: bool
	switch x.op {
	case .Mul:
		n, overflow = intrinsics.overflow_mul(a, b)
	case .Add:
		n, overflow = intrinsics.overflow_add(a, b)
	case .Sub:
		n, overflow = intrinsics.overflow_sub(a, b)
	case .Div:
		if b == 0 do return nil, .Division_By_Zero
		if a == min(int) && b == -1 do return nil, .Integer_Overflow
		n = a / b
		if a % b != 0 && (a < 0) != (b < 0) do n -= 1
	case .Mod:
		if b == 0 do return nil, .Division_By_Zero
		n = b == -1 ? 0 : a %% b
	case .Shl:
		if b < 0 || b > 63 do return nil, .Invalid_Shift
		n = a << uint(b)
		overflow = n >> uint(b) != a
	case .Shr:
		if b < 0 || b > 63 do return nil, .Invalid_Shift
		n = a >> uint(b)
	case .And:
		n = a & b
	case .Xor:
		n = a ~ b
	case .Or:
		n = a | b
	case .Eq:
		return a == b, .None
	case .Ne:
		return a != b, .None
	case .Lt:
		return a < b, .None
	case .Le:
		return a <= b, .None
	case .Gt:
		return a > b, .None
	case .Ge:
		return a >= b, .None
	case .Logical_And, .Logical_Or:
		unreachable()
	}

	if overflow do return nil, .Integer_Overflow
	return n, .None
}
