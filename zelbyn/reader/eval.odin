package reader

import arn "../arena"
import dat "../data"
import fld "../field"
import mdata "../metadata"
import "base:intrinsics"
import "core:math"
import "core:slice"
import "core:unicode/utf8"

// The value of an expression, by its type: Int (an int, or a u64 for one
// above max(int)), Float, Bool, Bytes, String, Array and Struct in that
// order.
@(private)
Eval_Value :: union {
	int,
	u64,
	f64,
	bool,
	[]byte,
	string,
	[]fld.Value,
	^fld.Instance,
}

// What _index and _ are, and the set instance whose value instance is
// being evaluated: index is -1 when the expression is not evaluated for an
// element of a repeat, element nil outside repeat-until and valid, and
// self nil outside a value instance. In a value instance, base is the
// expression that gave self, in the context caller, through which the
// instances enclosing self are found (ancestor).
@(private = "file")
Eval_Context :: struct {
	index:   int,
	element: fld.Value,
	self:    ^fld.Instance,
	base:    ^mdata.Expr,
	caller:  ^Eval_Context,
}

// Evaluates e, an Int expression, in the set instance being decoded. index
// is _index, or -1 when e is not evaluated for an element of a repeat.
@(private, require_results)
eval_int :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1) -> (n: int, err: dat.Read_Error) {
	assert(e.type == .Int)
	if value, ok := eval_direct(d, e.direct, nil); ok do return value, .None
	v := eval(d, e, {index = index}) or_return
	// one above max(int) is no size, count or offset
	i, is_int := v.(int)
	if !is_int do return 0, .Integer_Overflow
	return i, .None
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

// Evaluates e, a String expression, as eval_int does.
@(private, require_results)
eval_string :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1) -> (s: string, err: dat.Read_Error) {
	assert(e.type == .String)
	v := eval(d, e, {index = index}) or_return
	return v.(string), .None
}

// Evaluates e, an Int, Float, Bool, Bytes, String or Struct expression, as
// eval_int does, as a value of the tree: an Int is an i64, and a String is
// copied into the tree's arena, as it can be a literal of the schema, or
// part of one, which the tree outlives. Copying here, where a value enters
// the tree, rather than in the String_Literal case, spares the comparisons
// that use a literal a copy each time they are evaluated.
@(private, require_results)
eval_value :: proc(d: ^Decoder, e: ^mdata.Expr, index := -1) -> (value: fld.Value, err: dat.Read_Error) {
	v := eval(d, e, {index = index}) or_return
	if s, is_string := v.(string); is_string {
		copied := arn.arena_make(d.arena, byte, len(s))
		copy(copied, s)
		return string(copied), .None
	}
	return tree_value(v), .None
}

// v, an Int, Float, Bool, String, Bytes or Struct value, as a value of the
// tree: an Int is an i64.
@(private = "file")
tree_value :: proc(v: Eval_Value) -> fld.Value {
	#partial switch x in v {
	case int:
		return i64(x)
	case u64:
		return x
	case f64:
		return x
	case bool:
		return x
	case string:
		return x
	case []byte:
		return x
	case ^fld.Instance:
		return x
	case []fld.Value:
		// an item of an array literal of arrays
		return x
	}
	panic("tree_value: not a value")
}

// operand[index], when operand is a constant array literal
// (Array_Literal.constant), directly or as the expression of a value
// instance without an if: the item at index, evaluated alone rather than
// with the whole array, which gives the same value or error, as no item
// can fail. found is false for any other operand, which is made whole.
@(private = "file", require_results)
literal_item :: proc(d: ^Decoder, x: mdata.Index, ctx: Eval_Context) -> (v: Eval_Value, found: bool, err: dat.Read_Error) {
	e := x.operand
	item_ctx := ctx
	caller := ctx
	if ref, is_ref := e.variant.(mdata.Value_Ref); is_ref && ref.instance.cond == nil && !ref.instance.cached {
		if lit, is_literal := ref.instance.expr.variant.(mdata.Array_Literal); !is_literal || !lit.constant do return
		base, base_err := eval(d, ref.base, ctx)
		if base_err != .None do return nil, true, base_err
		item_ctx = Eval_Context{index = -1, self = base.(^fld.Instance), base = ref.base, caller = &caller}
		e = ref.instance.expr
	}
	literal, is_literal := e.variant.(mdata.Array_Literal)
	if !is_literal || !literal.constant do return
	index, index_err := eval(d, x.index, ctx)
	if index_err != .None do return nil, true, index_err
	i, is_int := index.(int)
	if !is_int || i < 0 || i >= len(literal.items) do return nil, true, .Index_Out_Of_Range
	v, err = eval(d, literal.items[i], item_ctx)
	return v, true, err
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
	case f32, f64, string, []byte, bool, ^fld.Instance, []fld.Value:
	}
	return
}

@(private = "file", require_results)
eval :: proc(d: ^Decoder, e: ^mdata.Expr, ctx: Eval_Context) -> (v: Eval_Value, err: dat.Read_Error) {
	switch x in e.variant {
	case mdata.Int_Literal:
		return x.value, .None
	case mdata.Big_Literal:
		return x.value, .None
	case mdata.Float_Literal:
		return x.value, .None
	case mdata.Bool_Literal:
		return x.value, .None
	case mdata.String_Literal:
		return x.value, .None
	case mdata.Index:
		if item, found, item_err := literal_item(d, x, ctx); found do return item, item_err
		operand := eval(d, x.operand, ctx) or_return
		index := eval(d, x.index, ctx) or_return
		// an index above max(int) is beyond any array
		i, is_int := index.(int)
		if !is_int do return nil, .Index_Out_Of_Range
		#partial switch o in operand {
		case []byte:
			if i < 0 || i >= len(o) do return nil, .Index_Out_Of_Range
			return int(o[i]), .None
		case []fld.Value:
			if i < 0 || i >= len(o) do return nil, .Index_Out_Of_Range
			return single_value(o[i])
		}
		panic("eval: indexing neither an array nor bytes")
	case mdata.String_Length:
		operand := eval(d, x.operand, ctx) or_return
		return utf8.rune_count_in_string(operand.(string)), .None
	case mdata.To_S:
		operand := eval(d, x.operand, ctx) or_return
		n, _ := as_wide(operand)
		return int_to_string(d, n), .None
	case mdata.Decode:
		operand := eval(d, x.operand, ctx) or_return
		bytes := operand.([]byte)
		return x.encoding == .None ? string(bytes) : decode_text(d, bytes, x.encoding), .None
	case mdata.Substring:
		operand := eval(d, x.operand, ctx) or_return
		from := eval(d, x.from, ctx) or_return
		to := eval(d, x.to, ctx) or_return
		return substring(operand.(string), clamp_int(from), clamp_int(to))
	case mdata.To_Bytes:
		operand := eval(d, x.operand, ctx) or_return
		return values_to_bytes(d, operand.([]fld.Value))
	case mdata.Root_Arg:
		return single_value(d.args[x.index])
	case mdata.To_I:
		operand := eval(d, x.operand, ctx) or_return
		#partial switch o in operand {
		case bool:
			return int(o), .None
		case f64:
			return float_to_int(o)
		}
		return string_to_int(operand.(string))
	case mdata.Array_Method:
		operand := eval(d, x.operand, ctx) or_return
		return array_method(operand, x.method)
	case mdata.Unary:
		operand := eval(d, x.operand, ctx) or_return
		switch x.op {
		case .Neg:
			if f, is_float := operand.(f64); is_float do return -f, .None
			n, _ := as_wide(operand)
			return from_wide(-n)
		case .Bit_Not:
			n, _ := as_wide(operand)
			return from_wide(~n)
		case .Not:
			return !operand.(bool), .None
		}
	case mdata.Binary:
		return eval_binary(d, x, ctx)
	case mdata.Ternary:
		cond := eval(d, x.cond, ctx) or_return
		return eval(d, cond.(bool) ? x.then : x.otherwise, ctx)
	case mdata.Instance:
		if x.root {
			if len(d.frames) == 0 do return nil, .Absent_Field
			return d.frames[0].instance, .None
		}
		if x.imported_root && ctx.self == nil do return imported_root(d, x.node)
		return ancestor(d, ctx, x.up)
	case mdata.Field_Ref:
		slot := field_slot(d, x, ctx) or_return
		values := slot^
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
		r := stream_reader(d, x.stream, ctx) or_return
		return r.pos, .None
	case mdata.Io_Size:
		r := stream_reader(d, x.stream, ctx) or_return
		return len(r.data), .None
	case mdata.Io_Eof:
		r := stream_reader(d, x.stream, ctx) or_return
		return dat.at_eof(r), .None
	case mdata.Repeat_Index:
		assert(ctx.index >= 0, "eval: _index outside a repeat")
		return ctx.index, .None
	case mdata.Repeat_Element:
		// nil after an element of a switch-on that chose no case, which has
		// no value
		if ctx.element == nil do return nil, .Absent_Field
		return single_value(ctx.element)
	case mdata.Value_Ref:
		kept := eval_value_ref(d, x, ctx) or_return
		if kept.slot != nil do return kept.slot^, .None
		return kept.value, .None
	case mdata.Bytes_Literal:
		// in the tree's arena, which may keep it, as an argument
		bytes := arn.arena_make(d.arena, byte, len(x.value))
		copy(bytes, x.value)
		return bytes, .None
	case mdata.Array_Literal:
		values := arn.arena_make(d.arena, fld.Value, len(x.items))
		for item, i in x.items {
			value := eval(d, item, ctx) or_return
			values[i] = tree_value(value)
		}
		return values, .None
	case mdata.Switch_Cast:
		operand := eval(d, x.operand, ctx) or_return
		instance, is_instance := operand.(^fld.Instance)
		if !is_instance || !slice.contains(x.choices, instance.choice) do return nil, .Wrong_Type
		return instance, .None
	case mdata.Io:
		panic("eval: a Stream expression (eval_stream)")
	case mdata.Name, mdata.Member, mdata.Enum_Constant, mdata.Size_Of, mdata.Cast, mdata.Call:
		panic("eval: unresolved expression")
	}
	panic("eval: invalid expression")
}

// The instance up levels above that of ctx (_parent is 1), from the
// frames, each of which has its _parent's, or in a value instance, through
// base: the instances enclosing self are the values of the expressions
// base is made of, innermost first, then those enclosing the instance it
// starts from, in caller. A set of a type that contains itself has several
// places in the tree, but its expressions reach only the levels between
// them (members), unless those have the same _parent (parent).
@(private = "file", require_results)
ancestor :: proc(d: ^Decoder, ctx: Eval_Context, up: int) -> (instance: ^fld.Instance, err: dat.Read_Error) {
	if ctx.self == nil {
		i := len(d.frames) - 1
		for _ in 0 ..< up {
			if i < 0 do break
			i = d.frames[i].parent
		}
		if i < 0 do return nil, .Absent_Field
		return d.frames[i].instance, .None
	}
	if up == 0 do return ctx.self, .None
	return enclosing(d, ctx.base, ctx.caller^, up)
}

// The instance being decoded of set, the top-level type of an imported
// schema, which that schema's _root is: the frame read as set, found at any
// depth, as inside a set reused for its own type (Node.recursive) a fixed
// number of levels out would not be. Only one frame is read as set, as a
// set of the type inside it is another node.
@(private = "file", require_results)
imported_root :: proc(d: ^Decoder, set: ^mdata.Node) -> (instance: ^fld.Instance, err: dat.Read_Error) {
	for f in d.frames {
		if f.set == set || (set.order_switch != nil && f.set == set.order_switch.big) do return f.instance, .None
	}
	return nil, .Absent_Field
}

// The instance up levels above the one that e, a Struct expression
// evaluated in ctx, gives.
@(private = "file", require_results)
enclosing :: proc(d: ^Decoder, e: ^mdata.Expr, ctx: Eval_Context, up: int) -> (instance: ^fld.Instance, err: dat.Read_Error) {
	up := up
	e := e
	for {
		#partial switch x in e.variant {
		case mdata.Field_Ref:
			// a field's instance is in the instance of its base, which is its
			// _parent, or with a parent, is parent_up levels inside it
			up += x.node.parent_up - 1
			if up == 0 {
				v := eval(d, x.base, ctx) or_return
				return v.(^fld.Instance), .None
			}
			e = x.base
		case mdata.Index:
			// an element is in the instance of its array's field
			e = x.operand
		case mdata.Array_Method:
			e = x.operand
		case mdata.Switch_Cast:
			e = x.operand
		case mdata.Ternary:
			cond := eval(d, x.cond, ctx) or_return
			e = cond.(bool) ? x.then : x.otherwise
		case mdata.Value_Ref:
			// the instance a value instance gives is reached through its
			// expression, evaluated for the instance of its base
			base := eval(d, x.base, ctx) or_return
			caller := ctx
			return enclosing(d, x.instance.expr, Eval_Context{index = -1, self = base.(^fld.Instance), base = x.base, caller = &caller}, up)
		case mdata.Instance:
			if x.root do return nil, .Absent_Field
			return ancestor(d, ctx, x.up + up)
		case mdata.Repeat_Element:
			// _ is in the instance being decoded
			return ancestor(d, ctx, up - 1)
		case:
			panic("enclosing: not a set instance")
		}
	}
}

// Evaluates e, a Stream expression, in the set instance being decoded.
@(private, require_results)
eval_stream :: proc(d: ^Decoder, e: ^mdata.Expr) -> (stream: Stream, err: dat.Read_Error) {
	assert(e.type == .Stream)
	#partial switch x in e.variant {
	case mdata.Ternary:
		cond := eval_bool(d, x.cond) or_return
		return eval_stream(d, cond ? x.then : x.otherwise)
	case mdata.Io:
		v := eval(d, x.instance, {index = -1}) or_return
		instance := v.(^fld.Instance)
		#reverse for f in d.frames {
			if f.instance != instance do continue
			if f.stream < len(d.streams) do return d.streams[f.stream], .None
			return {d.r, d.base}, .None
		}
		// an instance that is not being decoded is of a set whose stream an
		// io expression refers to, and so was kept
		kept, ok := d.kept[instance]
		assert(ok, "eval_stream: the stream of the instance was not kept")
		return kept, .None
	}
	panic("eval_stream: not a Stream expression")
}

// The stream that _io refers to in an expression of instance, or of the
// set instance being decoded when instance is nil: that of its frame, r
// unless a parse instance of it is being read from another stream, or, once
// it is no longer decoded, the stream kept for its set (keeps_stream), as
// it was once the instance was read.
@(private = "file")
stream_of :: proc(d: ^Decoder, instance: ^fld.Instance) -> ^dat.Reader {
	#reverse for f in d.frames {
		if instance != nil && f.instance != instance do continue
		if f.stream < len(d.streams) do return &d.streams[f.stream].r
		return &d.r
	}
	if instance == nil do return &d.r
	kept, ok := &d.kept[instance]
	assert(ok, "stream_of: the stream of the instance was not kept")
	return &kept.r
}

// The reader of stream, a Stream expression evaluated in ctx (Io_Pos), or
// when it is nil, of _io (stream_of).
@(private = "file", require_results)
stream_reader :: proc(d: ^Decoder, stream: ^mdata.Expr, ctx: Eval_Context) -> (r: ^dat.Reader, err: dat.Read_Error) {
	if stream == nil do return stream_of(d, ctx.self), .None
	#partial switch x in stream.variant {
	case mdata.Ternary:
		cond := eval(d, x.cond, ctx) or_return
		return stream_reader(d, cond.(bool) ? x.then : x.otherwise, ctx)
	case mdata.Io:
		v := eval(d, x.instance, ctx) or_return
		return stream_of(d, v.(^fld.Instance)), .None
	}
	panic("stream_reader: not a Stream expression")
}

// The slot of x's field in the instance its base gives, the field read
// first when it is a parse instance that has not been.
@(private = "file", require_results)
field_slot :: #force_inline proc(d: ^Decoder, x: mdata.Field_Ref, ctx: Eval_Context) -> (slot: ^[]fld.Value, err: dat.Read_Error) {
	base := eval(d, x.base, ctx) or_return
	instance := base.(^fld.Instance)
	if x.node.pos != nil && raw_data(instance.slots[x.slot]) == nil {
		if d.spans do read_parse_instance(d, instance, x.node, x.slot, true) or_return
		else do read_parse_instance(d, instance, x.node, x.slot, false) or_return
	}
	return &instance.slots[x.slot], .None
}

// The value of the value instance x refers to, for the instance its base
// gives, as eval_kept gives it: kept from its first evaluation when it is
// cached.
@(private = "file", require_results)
eval_value_ref :: proc(d: ^Decoder, x: mdata.Value_Ref, ctx: Eval_Context) -> (v: Kept_Value, err: dat.Read_Error) {
	base := eval(d, x.base, ctx) or_return
	caller := ctx
	self := Eval_Context{index = -1, self = base.(^fld.Instance), base = x.base, caller = &caller}
	if x.instance.cached do return eval_cached(d, x.instance, self)
	if x.instance.cond != nil {
		cond := eval(d, x.instance.cond, self) or_return
		if !cond.(bool) do return {}, .Absent_Field
	}
	return eval_kept(d, x.instance.expr, self)
}

// Evaluates value instance inst, which is cached, in self, its context: the
// value it had when first evaluated, when it had one.
@(private = "file", require_results)
eval_cached :: proc(d: ^Decoder, inst: ^mdata.Value_Instance, self: Eval_Context) -> (v: Kept_Value, err: dat.Read_Error) {
	key := Cached{self.self, inst}
	if cached, found := d.cache[key]; found do return cached, .None
	if inst.cond != nil {
		cond := eval(d, inst.cond, self) or_return
		if !cond.(bool) do return {}, .Absent_Field
	}
	v = eval_kept(d, inst.expr, self) or_return
	// as in Kaitai, a value instance that has no value is evaluated again
	if d.cache == nil do d.cache = make(map[Cached]Kept_Value, d.allocator)
	d.cache[key] = v
	return v, .None
}

// The value of e as a value instance keeps it: an Array that is the values
// of a field, directly or through ?: or another value instance, as the slot
// that holds them, so that it is the field's array also once the field has
// grown, as Kaitai keeps a reference to it; anything else as its value,
// such as the field's .size, which keeps the size it had.
@(private = "file", require_results)
eval_kept :: proc(d: ^Decoder, e: ^mdata.Expr, ctx: Eval_Context) -> (v: Kept_Value, err: dat.Read_Error) {
	if e.type == .Array {
		#partial switch x in e.variant {
		case mdata.Field_Ref:
			slot := field_slot(d, x, ctx) or_return
			return {slot = slot}, .None
		case mdata.Ternary:
			cond := eval(d, x.cond, ctx) or_return
			return eval_kept(d, cond.(bool) ? x.then : x.otherwise, ctx)
		case mdata.Value_Ref:
			return eval_value_ref(d, x, ctx)
		}
	}
	value := eval(d, e, ctx) or_return
	return {value = value}, .None
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
		if v > u64(max(int)) do return v, .None
		return int(v), .None
	case []byte:
		return v, .None
	case string:
		return v, .None
	case bool:
		return v, .None
	case ^fld.Instance:
		return v, .None
	case []fld.Value:
		return v, .None
	case f32:
		return f64(v), .None
	case f64:
		return v, .None
	}
	panic("eval: a field value of an unsupported type")
}

// .first, .last, .min or .max of operand, an array or bytes.
@(private = "file", require_results)
array_method :: proc(operand: Eval_Value, method: mdata.Array_Method_Kind) -> (v: Eval_Value, err: dat.Read_Error) {
	#partial switch o in operand {
	case []byte:
		if len(o) == 0 do return nil, .Index_Out_Of_Range
		switch method {
		case .First:
			return int(o[0]), .None
		case .Last:
			return int(o[len(o) - 1]), .None
		case .Min:
			return int(slice.min(o)), .None
		case .Max:
			return int(slice.max(o)), .None
		}
	case []fld.Value:
		if len(o) == 0 do return nil, .Index_Out_Of_Range
		switch method {
		case .First:
			return single_value(o[0])
		case .Last:
			return single_value(o[len(o) - 1])
		case .Min, .Max:
			best := single_value(o[0]) or_return
			b, _ := as_wide(best)
			for value in o[1:] {
				item := single_value(value) or_return
				n, _ := as_wide(item)
				if method == .Min ? n < b : n > b do best, b = item, n
			}
			return best, .None
		}
	}
	panic("eval: a method of neither an array nor bytes")
}

// Integer operations fail rather than wrap, and / and % round toward
// negative infinity (as Python does, and so Kaitai's Python runtime); one
// with an integer above max(int), or whose result does not fit an int, is
// exact (eval_binary_wide), so that every result from min(int) to
// max(u64) is reached. and and or evaluate their right operand only when
// they need it.
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

	// integers first: they are what the decoder evaluates per element
	a, a_is_int := left.(int)
	b, b_is_int := right.(int)
	if !a_is_int || !b_is_int {
		if l, is_wide := as_wide(left); is_wide {
			if r, r_is_wide := as_wide(right); r_is_wide do return eval_binary_wide(x.op, l, r)
		}
		return eval_binary_other(d, x.op, left, right), .None
	}
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
		// 2^63, a u64
		if a == min(int) && b == -1 do return eval_binary_wide(x.op, i128(a), i128(b))
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

	// a result beyond an int may still be a u64; in i128, two ints cannot
	// overflow
	if overflow do return eval_binary_wide(x.op, i128(a), i128(b))
	return n, .None
}

// x op y for two integers of which one is above max(int), or whose result
// does not fit an int, exactly, with the integer rules of eval_binary: a
// result beyond min(int) to max(u64) is Integer_Overflow.
@(private = "file", require_results)
eval_binary_wide :: proc(op: mdata.Binary_Op, a, b: i128) -> (v: Eval_Value, err: dat.Read_Error) {
	n: i128
	overflow: bool
	switch op {
	case .Mul:
		n, overflow = intrinsics.overflow_mul(a, b)
	case .Add:
		n = a + b
	case .Sub:
		n = a - b
	case .Div:
		if b == 0 do return nil, .Division_By_Zero
		n = a / b
		if a % b != 0 && (a < 0) != (b < 0) do n -= 1
	case .Mod:
		if b == 0 do return nil, .Division_By_Zero
		n = b == -1 ? 0 : a %% b
	case .Shl:
		if b < 0 || b > 63 do return nil, .Invalid_Shift
		n = a << uint(b)
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
	return from_wide(n)
}

// v, an Int, as an i128.
@(private = "file")
as_wide :: proc(v: Eval_Value) -> (n: i128, is_int: bool) {
	#partial switch x in v {
	case int:
		return i128(x), true
	case u64:
		return i128(x), true
	}
	return
}

// n as an Int: an int, or a u64 above max(int), and Integer_Overflow
// beyond.
@(private = "file", require_results)
from_wide :: proc(n: i128) -> (v: Eval_Value, err: dat.Read_Error) {
	switch {
	case n >= i128(min(int)) && n <= i128(max(int)):
		return int(n), .None
	case n > 0 && n <= i128(max(u64)):
		return u64(n), .None
	}
	return nil, .Integer_Overflow
}

// v, an Int, as an int, with one above max(int) as max(int).
@(private = "file")
clamp_int :: proc(v: Eval_Value) -> int {
	n, is_int := v.(int)
	return is_int ? n : max(int)
}

// x op y for two strings, two booleans, or two numbers of which one is a
// float.
@(private = "file")
eval_binary_other :: proc(d: ^Decoder, op: mdata.Binary_Op, x, y: Eval_Value) -> Eval_Value {
	if l, is_number := as_float(x); is_number {
		r, _ := as_float(y)
		#partial switch op {
		case .Mul:
			return l * r
		case .Div:
			return l / r
		case .Add:
			return l + r
		case .Sub:
			return l - r
		case .Eq:
			return l == r
		case .Ne:
			return l != r
		case .Lt:
			return l < r
		case .Le:
			return l <= r
		case .Gt:
			return l > r
		case .Ge:
			return l >= r
		}
		panic("eval: invalid operator on floats")
	}
	// byte arrays compare byte by byte, as strings do
	if l, is_bytes := x.([]byte); is_bytes do return eval_binary_other(d, op, string(l), string(y.([]byte)))
	if l, is_bool := x.(bool); is_bool {
		r := y.(bool)
		#partial switch op {
		case .Eq:
			return l == r
		case .Ne:
			return l != r
		}
		panic("eval: invalid operator on booleans")
	}

	l, r := x.(string), y.(string)
	#partial switch op {
	case .Add:
		joined := arn.arena_make(d.arena, byte, len(l) + len(r))
		copy(joined, l)
		copy(joined[len(l):], r)
		return string(joined)
	case .Eq:
		return l == r
	case .Ne:
		return l != r
	case .Lt:
		return l < r
	case .Le:
		return l <= r
	case .Gt:
		return l > r
	case .Ge:
		return l >= r
	}
	panic("eval: invalid operator on strings")
}

// The code points of s from from up to to (mdata.Substring), a view of s.
@(private = "file", require_results)
substring :: proc(s: string, from, to: int) -> (v: Eval_Value, err: dat.Read_Error) {
	if from < 0 || to < 0 do return nil, .Index_Out_Of_Range
	if to <= from do return "", .None
	start, end := len(s), len(s)
	n := 0
	for _, i in s {
		if n == from do start = i
		if n == to {
			end = i
			break
		}
		n += 1
	}
	return s[start:end], .None
}

// values, Int values of an array, as bytes in the tree's arena
// (mdata.To_Bytes).
@(private = "file", require_results)
values_to_bytes :: proc(d: ^Decoder, values: []fld.Value) -> (v: Eval_Value, err: dat.Read_Error) {
	bytes := arn.arena_make(d.arena, byte, len(values))
	for value, i in values {
		item := single_value(value) or_return
		n, is_int := item.(int)
		if !is_int || n < 0 || n > 255 do return nil, .Integer_Overflow
		bytes[i] = byte(n)
	}
	return bytes, .None
}

// v as a float, when it is a number.
@(private = "file")
as_float :: proc(v: Eval_Value) -> (f: f64, is_number: bool) {
	#partial switch x in v {
	case int:
		return f64(x), true
	case u64:
		return f64(x), true
	case f64:
		return x, true
	}
	return
}

// The integer part of f, rounded toward zero, an int or a u64:
// Integer_Overflow when it is beyond min(int) to max(u64), or f is not a
// number.
@(private = "file", require_results)
float_to_int :: proc(f: f64) -> (v: Eval_Value, err: dat.Read_Error) {
	t := math.trunc(f)
	// -2^63 fits, and so does any below 2^64; NaN fails both
	if !(t >= -9223372036854775808.0 && t < 18446744073709551616.0) do return nil, .Integer_Overflow
	if t >= 9223372036854775808.0 do return u64(t), .None
	return int(t), .None
}

// The decimal digits of n, with a - when it is negative, in the tree's
// arena: like a string that + makes, it lasts as long as the tree.
@(private = "file")
int_to_string :: proc(d: ^Decoder, n: i128) -> string {
	buf: [20]byte // the digits of min(int), and its -, or of max(u64)
	i := len(buf)
	u := u64(n < 0 ? -n : n)
	for {
		i -= 1
		buf[i] = '0' + byte(u % 10)
		u /= 10
		if u == 0 do break
	}
	if n < 0 {
		i -= 1
		buf[i] = '-'
	}
	out := arn.arena_make(d.arena, byte, len(buf) - i)
	copy(out, buf[i:])
	return string(out)
}

// The decimal integer s is, with an optional + or -: Invalid_Number when it
// is not one, and Integer_Overflow when it is beyond min(int) to max(u64),
// as any other integer is.
@(private = "file", require_results)
string_to_int :: proc(s: string) -> (v: Eval_Value, err: dat.Read_Error) {
	digits := s
	negative := false
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {
		negative = digits[0] == '-'
		digits = digits[1:]
	}
	if len(digits) == 0 do return nil, .Invalid_Number
	n: i128
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' do return nil, .Invalid_Number
		// once beyond max(u64), n stays beyond it, and so within an i128
		if n <= i128(max(u64)) do n = n * 10 + i128(c - '0')
	}
	return from_wide(negative ? -n : n)
}
