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
	map[int][dynamic]fld.Value,
}

// Evaluates e, an Int expression, in the set instance being decoded. index
// is _index, or -1 when e is not evaluated for an element of a repeat.
@(private, require_results)
eval_int :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1) -> (n: int, err: dat.Read_Error) {
	assert(e.type == .Int)
	v := eval(d, e, index) or_return
	return v.(int), .None
}

@(private = "file", require_results)
eval :: proc(d: ^Decoder, e: ^mdata.Expr, index: int) -> (v: Eval_Value, err: dat.Read_Error) {
	switch x in e.variant {
	case mdata.Int_Literal:
		return x.value, .None
	case mdata.Bool_Literal:
		return x.value, .None
	case mdata.Unary:
		operand := eval(d, x.operand, index) or_return
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
		return eval_binary(d, x, index)
	case mdata.Ternary:
		cond := eval(d, x.cond, index) or_return
		return eval(d, cond.(bool) ? x.then : x.otherwise, index)
	case mdata.Instance:
		i := x.root ? 0 : len(d.frames) - 1 - x.up
		if i < 0 || i >= len(d.frames) do return nil, .Absent_Field
		return d.frames[i]^, .None
	case mdata.Field_Ref:
		base := eval(d, x.base, index) or_return
		values, found := base.(map[int][dynamic]fld.Value)[x.node.id]
		if !found do return nil, .Absent_Field
		if e.type == .Array do return values[:], .None
		if len(values) == 0 do return nil, .Absent_Field
		return single_value(values[0])
	case mdata.Size:
		operand := eval(d, x.operand, index) or_return
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
		return d.r.pos >= len(d.r.data), .None
	case mdata.Repeat_Index:
		assert(index >= 0, "eval: _index outside a repeat")
		return index, .None
	case mdata.Peek:
		pos := eval(d, x.pos, index) or_return
		return dat.peek_integer_at(&d.r, pos.(int), x.type, x.order)
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
	case map[int][dynamic]fld.Value:
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
eval_binary :: proc(d: ^Decoder, x: mdata.Binary, index: int) -> (v: Eval_Value, err: dat.Read_Error) {
	left := eval(d, x.left, index) or_return

	#partial switch x.op {
	case .Logical_And:
		if !left.(bool) do return false, .None
		return eval(d, x.right, index)
	case .Logical_Or:
		if left.(bool) do return true, .None
		return eval(d, x.right, index)
	}

	right := eval(d, x.right, index) or_return

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
