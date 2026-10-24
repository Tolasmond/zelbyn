package expression

import mdata "../metadata"
import "base:intrinsics"
import "core:fmt"
import "core:mem"

// Where an expression is evaluated: in an instance of the last of types,
// whose enclosing instances are of the types before it, outermost (_root)
// first. Names refer to fields of the last type.
Scope :: struct {
	types:     []^mdata.Node,
	own_root:  bool,        // types[0] is the top level of an imported schema, its _root, but not the root of the decoded tree
	no_root:   bool,        // types[0] is a type declared in a schema other than the one it is used from, which has no _root there, as in Kaitai
	in_repeat: bool,        // the expression is evaluated for each element of a repeated field, so _index is defined
	element:   ^mdata.Node, // repeat-until and valid: the field whose element _ is; nil elsewhere
	instance:  ^mdata.Value_Instance, // in a value instance's expression, the instance, marked cached when its value can change or it refers to another (mark_cached)

	// Called when an expression refers to a value instance whose expr is
	// nil, or a parse instance whose pos is nil, to compile it; on failure
	// the callback reports its own error. set is the set the expression
	// reaches it through, whose members it is of (mdata.members). When nil,
	// such a reference is an error. With type_only, the reference is in the
	// operand of _sizeof, which needs only the parse instance's type, so its
	// pos can be left nil, as it can be the expression being compiled.
	compile_instance:       proc(data: rawptr, set: ^mdata.Node, instance: ^mdata.Value_Instance) -> bool,
	compile_parse_instance: proc(data: rawptr, set: ^mdata.Node, instance: ^mdata.Node, type_only: bool) -> bool,

	// Called for _sizeof, sizeof<t> and bitsizeof<t>: the size in bits that
	// Kaitai's compiler gives the attribute or parse instance called name
	// of set, or set's own type when name is "", or with of_type, the type
	// called name, as set's type names it. On failure it returns the error,
	// whose offset the resolver sets. When nil, these are an error.
	size_of: proc(data: rawptr, set: ^mdata.Node, name: string, of_type: bool) -> (bits: int, err: Error),

	// The enum called name, a name or a path (a::b::e), as set's type
	// names it, for enum constants; nil when there is none. When nil, no
	// enum is.
	find_enum: proc(data: rawptr, set: ^mdata.Node, name: string) -> ^Enum,

	// Whether sets a and b are of the same type, for ?: on sets. When nil,
	// they are not.
	same_type: proc(data: rawptr, a, b: ^mdata.Node) -> bool,

	// The encoding that name, an encoding of .to_s(encoding), is; ok is
	// false for one that is not supported. When nil, .to_s(encoding) is an
	// error.
	encoding: proc(name: string) -> (e: mdata.Encoding, ok: bool),
	data:     rawptr,
}

// A schema's enum: its values, by name. An enum constant (name::value) is
// the value's integer.
Enum :: struct {
	name:   string,
	values: []Enum_Value,
}

Enum_Value :: struct {
	name:  string,
	value: int,
}

// Parses text and resolves it in scope. The result must have type want,
// unless want is .Unresolved.
@(require_results)
compile :: proc(text: string, scope: Scope, want: mdata.Expr_Type, allocator: mem.Allocator) -> (e: ^mdata.Expr, err: Error) {
	e, err = parse(text, allocator)
	if err.kind != .None do return nil, err

	r := Resolver{scope = scope, allocator = allocator}
	if resolve(&r, e) && want != .Unresolved && e.type != want {
		fail(&r, .Invalid, e.offset, "expected %s, found %s", type_name(want), type_name(e.type))
	}
	if r.err.kind != .None do return nil, r.err
	e.direct = direct_form(e)
	return e, {}
}

// Parses text as parse_list does, and resolves each expression in scope,
// whatever its type.
@(require_results)
compile_list :: proc(text: string, scope: Scope, allocator: mem.Allocator) -> (list: []^mdata.Expr, err: Error) {
	list, err = parse_list(text, allocator)
	if err.kind != .None do return nil, err

	r := Resolver{scope = scope, allocator = allocator}
	for e in list {
		if !resolve(&r, e) do return nil, r.err
		e.direct = direct_form(e)
	}
	return list, {}
}

// The direct form of e, a resolved expression, or nil when it has none
// (mdata.Direct).
direct_form :: proc(e: ^mdata.Expr) -> mdata.Direct {
	#partial switch x in e.variant {
	case mdata.Int_Literal:
		return mdata.Direct_Constant{x.value}
	case mdata.Bool_Literal:
		return mdata.Direct_Constant{int(x.value)}
	case mdata.Field_Ref:
		if f, ok := direct_field(e); ok do return f
	case mdata.Binary:
		REVERSED := #partial [mdata.Binary_Op]mdata.Binary_Op {
			.Eq = .Eq,
			.Ne = .Ne,
			.Lt = .Gt,
			.Le = .Ge,
			.Gt = .Lt,
			.Ge = .Le,
		}
		if x.op < .Eq || x.op > .Ge do return nil
		if f, ok := direct_field(x.left); ok {
			if c, is_literal := x.right.variant.(mdata.Int_Literal); is_literal do return mdata.Direct_Compare{f, x.op, c.value}
		}
		if f, ok := direct_field(x.right); ok {
			if c, is_literal := x.left.variant.(mdata.Int_Literal); is_literal do return mdata.Direct_Compare{f, REVERSED[x.op], c.value}
		}
	}
	return nil
}

// The value of e, a parsed or resolved expression, when it is made of
// integer literals and the integer operators; ok is false for any other,
// when the decoder would fail on it (division by zero, an invalid shift),
// and when its value or a step towards it does not fit an int, which the
// decoder evaluates exactly up to max(u64).
constant :: proc(e: ^mdata.Expr) -> (v: int, ok: bool) {
	#partial switch x in e.variant {
	case mdata.Int_Literal:
		return x.value, true
	case mdata.Unary:
		n := constant(x.operand) or_return
		#partial switch x.op {
		case .Neg:
			if n == min(int) do return
			return -n, true
		case .Bit_Not:
			return ~n, true
		}
	case mdata.Binary:
		a := constant(x.left) or_return
		b := constant(x.right) or_return
		overflow := false
		#partial switch x.op {
		case .Mul:
			v, overflow = intrinsics.overflow_mul(a, b)
		case .Add:
			v, overflow = intrinsics.overflow_add(a, b)
		case .Sub:
			v, overflow = intrinsics.overflow_sub(a, b)
		case .Div:
			if b == 0 || (a == min(int) && b == -1) do return
			v = a / b
			if a % b != 0 && (a < 0) != (b < 0) do v -= 1
		case .Mod:
			if b == 0 do return
			v = b == -1 ? 0 : a %% b
		case .Shl:
			if b < 0 || b > 63 do return
			v = a << uint(b)
			overflow = v >> uint(b) != a
		case .Shr:
			if b < 0 || b > 63 do return
			v = a >> uint(b)
		case .And:
			v = a & b
		case .Xor:
			v = a ~ b
		case .Or:
			v = a | b
		case:
			return
		}
		return v, !overflow
	}
	return
}

// e as a Direct_Field: an Int field read at most once, of the set instance
// being decoded or of _.
@(private = "file")
direct_field :: proc(e: ^mdata.Expr) -> (f: mdata.Direct_Field, ok: bool) {
	ref := e.variant.(mdata.Field_Ref) or_return
	if e.type != .Int do return
	#partial switch b in ref.base.variant {
	case mdata.Instance:
		// an imported schema's _root is found among the frames (reader.imported_root)
		if b.root || b.up != 0 || b.imported_root do return
		return {slot = ref.slot}, true
	case mdata.Repeat_Element:
		return {slot = ref.slot, of_element = true}, true
	}
	return
}

@(private = "file")
Resolver :: struct {
	scope:     Scope,
	allocator: mem.Allocator,
	err:       Error,
	type_only: bool, // resolving the operand of _sizeof, which only types are needed for (Scope.compile_parse_instance)
}

@(private = "file")
fail :: proc(r: ^Resolver, kind: Error_Kind, offset: int, format: string, args: ..any) -> bool {
	if r.err.kind == .None {
		r.err = Error{kind = kind, offset = offset, message = fmt.aprintf(format, ..args)}
	}
	return false
}

// An expression type in words, for errors: "an integer", "a set".
type_name :: proc(t: mdata.Expr_Type) -> string {
	switch t {
	case .Unresolved:
		return "an unresolved expression"
	case .Int:
		return "an integer"
	case .Float:
		return "a float"
	case .Bool:
		return "a boolean"
	case .Bytes:
		return "a byte array"
	case .String:
		return "a string"
	case .Array:
		return "an array"
	case .Struct:
		return "a set"
	case .Stream:
		return "a stream"
	}
	return ""
}

// Replaces every syntax-only variant below e with a resolved one, and sets
// every node's type.
@(private = "file")
resolve :: proc(r: ^Resolver, e: ^mdata.Expr) -> bool {
	switch x in e.variant {
	case mdata.Int_Literal, mdata.Big_Literal:
		e.type = .Int
	case mdata.Float_Literal:
		e.type = .Float
	case mdata.Bool_Literal:
		e.type = .Bool
	case mdata.String_Literal:
		e.type = .String
	case mdata.Unary:
		resolve(r, x.operand) or_return
		want: mdata.Expr_Type = x.op == .Not ? .Bool : .Int
		if x.op == .Neg && x.operand.type == .Float do want = .Float
		expect(r, x.operand, want) or_return
		e.type = want
	case mdata.Binary:
		resolve(r, x.left) or_return
		resolve(r, x.right) or_return
		e.type = binary_type(r, e, x) or_return
	case mdata.Ternary:
		resolve(r, x.cond) or_return
		resolve(r, x.then) or_return
		resolve(r, x.otherwise) or_return
		expect(r, x.cond, .Bool) or_return
		// a float and an integer give a float, as in Kaitai
		if x.then.type == .Float && x.otherwise.type == .Int do as_float(r, x.otherwise)
		if x.then.type == .Int && x.otherwise.type == .Float do as_float(r, x.then)
		#partial switch x.then.type {
		case .Int, .Float, .Bool, .String, .Bytes, .Stream:
		case .Struct:
			// as in Kaitai, of one type, whose members expressions find in the
			// set of then (struct_node), with the same slots in both
			expect(r, x.otherwise, .Struct) or_return
			if r.scope.same_type == nil || !r.scope.same_type(r.scope.data, struct_node(x.then), struct_node(x.otherwise)) {
				return fail(r, .Unsupported, e.offset, "?: on sets of different types is not supported")
			}
		case .Array:
			// of one item type, which array_item_type finds in then
			expect(r, x.otherwise, .Array) or_return
			t := array_item_type(r, e, x.then) or_return
			u := array_item_type(r, e, x.otherwise) or_return
			if t == .Struct || t == .Array do return fail(r, .Unsupported, x.then.offset, "?: on an array of %s is not supported; only of integers, floats, booleans, strings and byte arrays", type_name(t))
			if u != t do return fail(r, .Invalid, x.otherwise.offset, "the branches of ?: must have one type: an array of %s, not of %s", type_name(t), type_name(u))
		case:
			return fail(r, .Unsupported, x.then.offset, "?: on %s is not supported", type_name(x.then.type))
		}
		expect(r, x.otherwise, x.then.type) or_return
		e.type = x.then.type
	case mdata.Index:
		resolve(r, x.operand) or_return
		resolve(r, x.index) or_return
		expect(r, x.index, .Int) or_return
		#partial switch x.operand.type {
		case .Bytes:
			e.type = .Int
		case .Array:
			e.type = array_item_type(r, e, x.operand) or_return
		case:
			return fail(r, .Invalid, e.offset, "%s cannot be indexed; only an array and a byte array can", type_name(x.operand.type))
		}
	case mdata.Name:
		return resolve_name(r, e, x.name)
	case mdata.Member:
		return resolve_member(r, e, x)
	case mdata.Enum_Constant:
		return resolve_enum_constant(r, e, x)
	case mdata.Size_Of:
		return resolve_size_of(r, e, r.scope.types[len(r.scope.types) - 1], x.type_name, true, x.bits)
	case mdata.Cast:
		return resolve_cast(r, e, x)
	case mdata.Call:
		return resolve_call(r, e, x)
	case mdata.Array_Literal:
		return resolve_array_literal(r, e, x)
	case mdata.Instance, mdata.Field_Ref, mdata.Size, mdata.String_Length, mdata.Decode, mdata.Substring, mdata.To_Bytes, mdata.Root_Arg, mdata.To_S, mdata.To_I, mdata.Array_Method, mdata.Io, mdata.Io_Pos, mdata.Io_Size, mdata.Io_Eof, mdata.Repeat_Index, mdata.Repeat_Element, mdata.Value_Ref, mdata.Switch_Cast, mdata.Bytes_Literal:
		assert(e.type != .Unresolved, "resolve: a resolved variant without a type")
	case:
		panic("resolve: empty expression")
	}
	return true
}

@(private = "file")
resolve_enum_constant :: proc(r: ^Resolver, e: ^mdata.Expr, x: mdata.Enum_Constant) -> bool {
	en: ^Enum
	if r.scope.find_enum != nil do en = r.scope.find_enum(r.scope.data, r.scope.types[len(r.scope.types) - 1], x.enum_name)
	if en == nil do return fail(r, .Invalid, e.offset, "no enum %s", x.enum_name)
	for v in en.values {
		if v.name == x.value_name {
			e.variant = mdata.Int_Literal{v.value}
			e.type = .Int
			return true
		}
	}
	return fail(r, .Invalid, e.offset, "enum %s has no value %s", x.enum_name, x.value_name)
}

@(private = "file")
expect :: proc(r: ^Resolver, e: ^mdata.Expr, want: mdata.Expr_Type) -> bool {
	if e.type != want do return fail(r, .Invalid, e.offset, "expected %s, found %s", type_name(want), type_name(e.type))
	return true
}

@(private = "file")
binary_type :: proc(r: ^Resolver, e: ^mdata.Expr, x: mdata.Binary) -> (t: mdata.Expr_Type, ok: bool) {
	switch x.op {
	case .Add:
		if x.left.type == .String {
			expect(r, x.right, .String) or_return
			return .String, true
		}
		if is_float(r, x) or_return do return .Float, true
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Mul, .Div, .Sub:
		if is_float(r, x) or_return do return .Float, true
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Mod:
		if x.left.type == .Float || x.right.type == .Float do return .Unresolved, fail(r, .Unsupported, e.offset, "%% of a float is not supported")
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Shl, .Shr, .And, .Xor, .Or:
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Lt, .Le, .Gt, .Ge:
		if is_float(r, x) or_return do return .Bool, true
		if x.left.type != .String && x.left.type != .Bytes do expect(r, x.left, .Int) or_return
		expect(r, x.right, x.left.type) or_return
		return .Bool, true
	case .Eq, .Ne:
		if is_float(r, x) or_return do return .Bool, true
		if x.left.type != .Int && x.left.type != .Bool && x.left.type != .String && x.left.type != .Bytes {
			return .Unresolved, fail(r, .Unsupported, e.offset, "comparing %s is not supported", type_name(x.left.type))
		}
		expect(r, x.right, x.left.type) or_return
		return .Bool, true
	case .Logical_And, .Logical_Or:
		expect(r, x.left, .Bool) or_return
		expect(r, x.right, .Bool) or_return
		return .Bool, true
	}
	return .Unresolved, false
}

// Makes e, an Int expression, a Float: a literal, or a negated one, its
// float, else e + 0.0, which the decoder evaluates as a float.
@(private = "file")
as_float :: proc(r: ^Resolver, e: ^mdata.Expr) {
	negated: Maybe(int)
	if neg, is_neg := e.variant.(mdata.Unary); is_neg && neg.op == .Neg {
		if lit, is_literal := neg.operand.variant.(mdata.Int_Literal); is_literal do negated = -lit.value
	}
	if lit, is_literal := e.variant.(mdata.Int_Literal); is_literal {
		e.variant = mdata.Float_Literal{f64(lit.value)}
	} else if n, is_negated := negated.?; is_negated {
		// negated as an integer first, so that -0 is 0.0, as -0 + 0.0 is
		e.variant = mdata.Float_Literal{f64(n)}
	} else {
		operand := new(mdata.Expr, r.allocator)
		operand^ = e^
		zero := new(mdata.Expr, r.allocator)
		zero^ = {type = .Float, offset = e.offset, variant = mdata.Float_Literal{0}}
		e.variant = mdata.Binary{.Add, operand, zero}
	}
	e.type = .Float
}

// True when x, an arithmetic operation or a comparison, is on a Float and
// a number, an Int or a Float, which the decoder makes a Float first.
@(private = "file")
is_float :: proc(r: ^Resolver, x: mdata.Binary) -> (float: bool, ok: bool) {
	if x.left.type != .Float && x.right.type != .Float do return false, true
	for side in ([]^mdata.Expr{x.left, x.right}) {
		if side.type != .Int && side.type != .Float do return false, fail(r, .Invalid, side.offset, "expected a number, found %s", type_name(side.type))
	}
	return true, true
}

@(private = "file")
resolve_name :: proc(r: ^Resolver, e: ^mdata.Expr, name: string) -> bool {
	types := r.scope.types
	assert(len(types) > 0, "resolve: empty scope")

	switch name {
	case "_root":
		if r.scope.no_root do return fail(r, .Invalid, e.offset, "_root: %s is of a type of another schema, which has no _root here, as in Kaitai", types[0].ref_name)
		if r.scope.own_root {
			e.variant = mdata.Instance{up = len(types) - 1, node = types[0], imported_root = true}
		} else {
			e.variant = mdata.Instance{root = true, node = types[0]}
		}
		e.type = .Struct
	case "_parent":
		if len(types) < 2 do return fail(r, .Invalid, e.offset, "_parent: %s has no enclosing set here", types[0].ref_name)
		e.variant = mdata.Instance{up = 1, node = types[len(types) - 2]}
		e.type = .Struct
	case "_index":
		if !r.scope.in_repeat do return fail(r, .Invalid, e.offset, "_index is only defined for a repeated field")
		e.variant = mdata.Repeat_Index{}
		e.type = .Int
	case "_io":
		instance := new(mdata.Expr, r.allocator)
		instance^ = {type = .Struct, offset = e.offset, variant = mdata.Instance{node = types[len(types) - 1]}}
		e.variant = mdata.Io{instance}
		e.type = .Stream
	case "_sizeof":
		return resolve_size_of(r, e, types[len(types) - 1], "", false, false)
	case "_":
		if r.scope.element == nil do return fail(r, .Invalid, e.offset, "_ is only defined in repeat-until")
		e.type = value_type(r, e, r.scope.element, "_") or_return
		e.variant = mdata.Repeat_Element{r.scope.element}
	case:
		return resolve_field(r, e, current_instance(r, e.offset), name)
	}
	return true
}

// The set instance being decoded, as an expression at offset.
@(private = "file")
current_instance :: proc(r: ^Resolver, offset: int) -> ^mdata.Expr {
	types := r.scope.types
	base := new(mdata.Expr, r.allocator)
	base^ = {type = .Struct, offset = offset, variant = mdata.Instance{node = types[len(types) - 1]}}
	return base
}

// Makes e a reference to the field, parse instance, param or value
// instance called name in the set instance base. With any_switch, a
// switch-on field is a Struct, or an Array, whatever its cases, for a
// cast to find the case it names (resolve_cast).
@(private = "file")
resolve_field :: proc(r: ^Resolver, e: ^mdata.Expr, base: ^mdata.Expr, name: string, any_switch := false) -> bool {
	set := mdata.members(struct_node(base))
	// an attribute without an id, _unnamed and its index, has no name that
	// expressions can use, as in Kaitai
	if len(name) > 0 && name[0] == '_' do return fail(r, .Invalid, e.offset, "%s has no field %s", set.ref_name, name)
	field: ^mdata.Node
	slot: int
	for child, i in set.children {
		if child.ref_name == name {
			field, slot = child, mdata.slot_of(set, i)
			break
		}
	}
	if field == nil {
		for p, k in set.parse_instances {
			if p.ref_name != name do continue
			if p.pos == nil {
				if r.scope.compile_parse_instance == nil do return fail(r, .Invalid, e.offset, "instance %s cannot be used here", name)
				if !r.scope.compile_parse_instance(r.scope.data, struct_node(base), p, r.type_only) do return fail(r, .Invalid, e.offset, "instance %s is not valid", name)
				assert(r.type_only || p.pos != nil, "resolve: compile_parse_instance left the instance uncompiled")
			}
			field, slot = p, k
			break
		}
	}
	if field == nil {
		for p, k in set.params {
			if p.ref_name == name {
				field, slot = p, mdata.param_slot(set, k)
				break
			}
		}
	}
	if field == nil {
		for inst in set.instances {
			if inst.name == name do return resolve_value_ref(r, e, base, struct_node(base), inst)
		}
		return fail(r, .Invalid, e.offset, "%s has no field %s", set.ref_name, name)
	}
	// a field is visible to its own expressions, but its if and count are
	// evaluated before it has any value
	if field.count == nil do return fail(r, .Invalid, e.offset, "%s cannot be used in its own if or repeat-expr; it has no value there", name)

	switch {
	case any_switch && field.switch_on != nil:
		e.type = mdata.is_single(field) ? .Struct : .Array
	case !mdata.is_single(field):
		// the type of its values is checked as an Array's is used
		if field.switch_on != nil do value_type(r, e, field, name) or_return
		e.type = .Array
	case:
		e.type = value_type(r, e, field, name) or_return
	}

	// a repeated field grows while it is read, and its values can be used
	// before it is done
	if !mdata.is_single(field) do mark_cached(r)
	e.variant = mdata.Field_Ref{base = base, node = field, slot = slot}
	return true
}

// Marks the value instance whose expression is resolved, if any, cached,
// so that the decoder keeps the value it first has (reader.eval_cached),
// as Kaitai keeps every value instance's: when it uses _io.pos or _io.eof,
// or a repeated field, whose values change as decoding goes on, and when
// it refers to another value instance, so that a chain of them is
// evaluated once for each link rather than once for each path through it.
// Any other is evaluated each time it is used, which gives the same value,
// at the cost of an operation or two rather than a map lookup.
@(private = "file")
mark_cached :: proc(r: ^Resolver) {
	// the operand of _sizeof is not evaluated
	if r.scope.instance != nil && !r.type_only do r.scope.instance.cached = true
}

// The type of one value of field.
@(private = "file")
value_type :: proc(r: ^Resolver, e: ^mdata.Expr, field: ^mdata.Node, name: string) -> (t: mdata.Expr_Type, ok: bool) {
	#partial switch field.type {
	case .Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64, .Bits:
		return .Int, true
	case .Blob:
		return .Bytes, true
	case .String:
		return .String, true
	case .Bool:
		return .Bool, true
	case .Float32, .Float64:
		return .Float, true
	case .Set:
		if field.switch_on != nil do return switch_type(r, e, field, name)
		return .Struct, true
	}
	panic("value_type: a field of no type")
}

// The type of one value of field, a switch-on: the type of the values of
// every case, and with a length and no _ case, of the bytes that an
// element no case chooses has. Cases of other types, as in Kaitai, give a
// value of no type that expressions can use but as a whole, which zelbyn
// does not support. Nor does it support cases of user types, which in
// Kaitai have fields only when they are all the same type.
@(private = "file")
switch_type :: proc(r: ^Resolver, e: ^mdata.Expr, field: ^mdata.Node, name: string) -> (t: mdata.Expr_Type, ok: bool) {
	sw := field.switch_on
	t = sw.default == nil && field.length != nil ? .Bytes : .Unresolved
	for i in -1 ..< len(sw.cases) {
		node := i < 0 ? sw.default : sw.cases[i].node
		if node == nil do continue
		if node.type == .Set do return .Unresolved, fail(r, .Unsupported, e.offset, "%s is a switch-on field whose cases are user types; it cannot be used in expressions", name)
		u := value_type(r, e, node, name) or_return
		if t != .Unresolved && u != t do return .Unresolved, fail(r, .Unsupported, e.offset, "%s is a switch-on field whose values can be %s or %s; it cannot be used in expressions", name, type_name(t), type_name(u))
		t = u
	}
	if t == .Unresolved do return .Unresolved, fail(r, .Invalid, e.offset, "%s is a switch-on field with no cases; it has no value", name)
	return t, true
}

@(private = "file")
resolve_value_ref :: proc(r: ^Resolver, e: ^mdata.Expr, base: ^mdata.Expr, set: ^mdata.Node, inst: ^mdata.Value_Instance) -> bool {
	if inst.expr == nil {
		if r.scope.compile_instance == nil do return fail(r, .Invalid, e.offset, "value instance %s cannot be used here", inst.name)
		if !r.scope.compile_instance(r.scope.data, set, inst) do return fail(r, .Invalid, e.offset, "value instance %s is not valid", inst.name)
		assert(inst.expr != nil, "resolve: compile_instance left the instance uncompiled")
	}
	// the instances enclosing an argument's are not those that hold the
	// param, which is all the decoder can reach them through
	// nor through ?: on sets, as it is compiled for the set of the then
	// branch, whose enclosing sets need not be the other branch's
	if levels, via := through_indirect(base); via != "" && reach(inst) > levels {
		return fail(r, .Unsupported, e.offset, "value instance %s refers to the sets that enclose its instance, which it cannot through %s", inst.name, via)
	}
	mark_cached(r)
	e.variant = mdata.Value_Ref{base = base, instance = inst}
	e.type = inst.expr.type
	return true
}

// Whether e, a Struct expression, gives an instance reached through a param
// of a user type, and levels, the fields between that param and it.
@(private = "file")
through_param :: proc(e: ^mdata.Expr) -> (levels: int, through: bool) {
	e := e
	for {
		#partial switch x in e.variant {
		case mdata.Field_Ref:
			if x.node.is_param && x.node.type == .Set do return levels, true
			levels += 1
			e = x.base
		case mdata.Index:
			e = x.operand
		case mdata.Array_Method:
			e = x.operand
		case mdata.Switch_Cast:
			e = x.operand
		case mdata.Value_Ref:
			l, found := through_param(x.instance.expr)
			return levels + l, found
		case mdata.Ternary:
			// the fewer levels of the branches that are through one
			l, found := through_param(x.then)
			if m, other := through_param(x.otherwise); other && (!found || m < l) do l, found = m, true
			return levels + l, found
		case:
			return 0, false
		}
	}
}

// What e, a Struct expression, gives an instance through, the nearest of a
// param of a user type ("a param") and a ?: of sets ("?:"), or "" for
// neither, and levels, the fields between that and the instance.
@(private = "file")
through_indirect :: proc(e: ^mdata.Expr) -> (levels: int, via: string) {
	e := e
	for {
		#partial switch x in e.variant {
		case mdata.Ternary:
			return levels, "?:"
		case mdata.Field_Ref:
			if x.node.is_param && x.node.type == .Set do return levels, "a param"
			levels += 1
			e = x.base
		case mdata.Index:
			e = x.operand
		case mdata.Array_Method:
			e = x.operand
		case mdata.Switch_Cast:
			e = x.operand
		case mdata.Value_Ref:
			l: int
			l, via = through_indirect(x.instance.expr)
			return levels + l, via
		case:
			return 0, ""
		}
	}
}

// The most levels above the instance it is evaluated for that value
// instance inst reaches, through _parent (decoder.ancestor).
@(private = "file")
reach :: proc(inst: ^mdata.Value_Instance) -> int {
	n := reach_of(inst.expr)
	if inst.cond != nil do n = max(n, reach_of(inst.cond))
	return n
}

@(private = "file")
reach_of :: proc(e: ^mdata.Expr) -> int {
	switch x in e.variant {
	case mdata.Instance:
		return x.root ? 0 : x.up
	case mdata.Value_Ref:
		// its instance's levels count from the instance its base gives
		return max(reach_of(x.base), reach(x.instance) - depth(x.base))
	case mdata.Field_Ref:
		return reach_of(x.base)
	case mdata.Unary:
		return reach_of(x.operand)
	case mdata.Binary:
		return max(reach_of(x.left), reach_of(x.right))
	case mdata.Ternary:
		return max(reach_of(x.cond), reach_of(x.then), reach_of(x.otherwise))
	case mdata.Index:
		return max(reach_of(x.operand), reach_of(x.index))
	case mdata.Array_Literal:
		n := 0
		for item in x.items do n = max(n, reach_of(item))
		return n
	case mdata.Size:
		return reach_of(x.operand)
	case mdata.String_Length:
		return reach_of(x.operand)
	case mdata.To_S:
		return reach_of(x.operand)
	case mdata.To_I:
		return reach_of(x.operand)
	case mdata.Decode:
		return reach_of(x.operand)
	case mdata.To_Bytes:
		return reach_of(x.operand)
	case mdata.Substring:
		return max(reach_of(x.operand), reach_of(x.from), reach_of(x.to))
	case mdata.Array_Method:
		return reach_of(x.operand)
	case mdata.Io:
		return reach_of(x.instance)
	case mdata.Switch_Cast:
		return reach_of(x.operand)
	case mdata.Io_Pos:
		return x.stream == nil ? 0 : reach_of(x.stream)
	case mdata.Io_Size:
		return x.stream == nil ? 0 : reach_of(x.stream)
	case mdata.Io_Eof:
		return x.stream == nil ? 0 : reach_of(x.stream)
	case mdata.Int_Literal, mdata.Big_Literal, mdata.Float_Literal, mdata.Bool_Literal, mdata.String_Literal, mdata.Bytes_Literal, mdata.Root_Arg, mdata.Repeat_Index, mdata.Repeat_Element:
		return 0
	case mdata.Name, mdata.Member, mdata.Enum_Constant, mdata.Size_Of, mdata.Cast, mdata.Call:
		panic("reach_of: unresolved expression")
	}
	return 0
}

// The levels below the instance an expression is evaluated for that e, a
// Struct expression, gives an instance at: 1 for a field of it, -1 for
// _parent; the root is above every level an expression reaches.
@(private = "file")
depth :: proc(e: ^mdata.Expr) -> int {
	#partial switch x in e.variant {
	case mdata.Instance:
		return x.root ? max(int) / 2 : -x.up
	case mdata.Field_Ref:
		return depth(x.base) + 1
	case mdata.Index:
		return depth(x.operand)
	case mdata.Array_Method:
		return depth(x.operand)
	case mdata.Switch_Cast:
		return depth(x.operand)
	case mdata.Repeat_Element:
		return 1
	case mdata.Value_Ref:
		return depth(x.base) + depth(x.instance.expr)
	case mdata.Ternary:
		// the shallower branch, which reaches further out
		return min(depth(x.then), depth(x.otherwise))
	}
	panic("depth: not a set instance")
}

// The type of one item of array, an expression of type Array: all the
// values of a field (a Field_Ref), an array literal, a value instance whose
// expression is one of those, a ?: of those, or an item of an array of
// arrays.
@(private = "file")
array_item_type :: proc(r: ^Resolver, e: ^mdata.Expr, array: ^mdata.Expr) -> (t: mdata.Expr_Type, ok: bool) {
	#partial switch x in array.variant {
	case mdata.Field_Ref:
		return value_type(r, e, x.node, x.node.ref_name)
	case mdata.Array_Literal:
		return x.item_type, true
	case mdata.Value_Ref:
		return array_item_type(r, e, x.instance.expr)
	case mdata.Ternary:
		return array_item_type(r, e, x.then)
	case mdata.Index:
		return array_item_type(r, e, first_item(x.operand))
	case mdata.Array_Method:
		return array_item_type(r, e, first_item(x.operand))
	}
	panic("array_item_type: not an array")
}

// The first item of array, an array of arrays, which are all array
// literals of one type: of an array literal, of a value instance whose
// expression is one, or of an item of an array of those.
@(private = "file")
first_item :: proc(array: ^mdata.Expr) -> ^mdata.Expr {
	#partial switch x in array.variant {
	case mdata.Array_Literal:
		return x.items[0]
	case mdata.Value_Ref:
		return first_item(x.instance.expr)
	case mdata.Index:
		return first_item(first_item(x.operand))
	case mdata.Array_Method:
		return first_item(first_item(x.operand))
	}
	panic("first_item: not an array of arrays")
}

// [a, b, ...]: integer literals from 0 to 255 make a Bytes_Literal, as in
// Kaitai; other items make an Array of their type, which must be one of
// Int, Float, Bool, String and Bytes, the same for all, but that among
// floats an integer is made a float (as_float), as in Kaitai, or array
// literals whose items are all of one type.
@(private = "file")
resolve_array_literal :: proc(r: ^Resolver, e: ^mdata.Expr, x: mdata.Array_Literal) -> bool {
	if len(x.items) == 0 do return fail(r, .Invalid, e.offset, "an array literal cannot be empty; its type would be unknown")
	bytes := true
	for item in x.items {
		resolve(r, item) or_return
		lit, is_literal := item.variant.(mdata.Int_Literal)
		bytes &&= is_literal && lit.value >= 0 && lit.value <= 255
	}
	if bytes {
		value := make([]byte, len(x.items), r.allocator)
		for item, i in x.items do value[i] = byte(item.variant.(mdata.Int_Literal).value)
		e.variant = mdata.Bytes_Literal{value}
		e.type = .Bytes
		return true
	}

	t := x.items[0].type
	for item in x.items {
		if item.type == .Float do t = .Float
	}
	#partial switch t {
	case .Int, .Float, .Bool, .String, .Bytes:
	case .Array:
		inner := array_item_type(r, e, x.items[0]) or_return
		for item in x.items {
			if _, is_literal := item.variant.(mdata.Array_Literal); !is_literal do return fail(r, .Unsupported, item.offset, "an array literal of arrays is only supported of array literals")
			if u := array_item_type(r, e, item) or_return; u != inner do return fail(r, .Invalid, item.offset, "the items of an array literal must have one type: an array of %s, not of %s", type_name(inner), type_name(u))
		}
	case:
		return fail(r, .Unsupported, x.items[0].offset, "an array literal of %s is not supported; only of integers, floats, booleans, strings, byte arrays and arrays", type_name(t))
	}
	// the first item, too, may differ from t, which a later float decides
	for item in x.items {
		if item.type == .Int && t == .Float do as_float(r, item)
		if item.type != t do return fail(r, .Invalid, item.offset, "the items of an array literal must have one type: %s, not %s", type_name(t), type_name(item.type))
	}
	constant := true
	for item in x.items do constant &&= is_constant(item)
	e.variant = mdata.Array_Literal{x.items, t, constant}
	e.type = .Array
	return true
}

// Whether e, resolved, is a constant that evaluates without fail, as
// Array_Literal.constant says.
@(private = "file")
is_constant :: proc(e: ^mdata.Expr) -> bool {
	#partial switch x in e.variant {
	case mdata.Int_Literal, mdata.Big_Literal, mdata.Float_Literal, mdata.Bool_Literal, mdata.String_Literal, mdata.Bytes_Literal:
		return true
	case mdata.Array_Literal:
		return x.constant
	case mdata.Unary:
		// a negated Big_Literal can be beyond min(int)
		if x.op != .Neg do return false
		#partial switch _ in x.operand.variant {
		case mdata.Int_Literal, mdata.Float_Literal:
			return true
		}
	}
	return false
}

// The set of an expression of type Struct.
struct_node :: proc(e: ^mdata.Expr) -> ^mdata.Node {
	#partial switch x in e.variant {
	case mdata.Instance:
		return x.node
	case mdata.Field_Ref:
		return x.node
	case mdata.Repeat_Element:
		return x.node
	case mdata.Index:
		return struct_node(x.operand)
	case mdata.Array_Method:
		return struct_node(x.operand)
	case mdata.Value_Ref:
		return struct_node(x.instance.expr)
	case mdata.Switch_Cast:
		return x.node
	case mdata.Ternary:
		return struct_node(x.then)
	}
	panic("struct_node: not a set")
}

@(private = "file")
resolve_member :: proc(r: ^Resolver, e: ^mdata.Expr, m: mdata.Member) -> bool {
	if name, is_name := m.operand.variant.(mdata.Name); is_name && name.name == "_io" do return resolve_stream_member(r, e, nil, m.name)

	if m.name == "_sizeof" do return resolve_member_size_of(r, e, m.operand)

	resolve(r, m.operand) or_return
	operand := m.operand

	switch m.name {
	case "_parent":
		inst, is_instance := operand.variant.(mdata.Instance)
		if !is_instance || inst.root {
			return fail(r, .Unsupported, e.offset, "._parent is only supported after _parent")
		}
		inst.up += 1
		types := r.scope.types
		if inst.up >= len(types) do return fail(r, .Invalid, e.offset, "_parent: %s has no enclosing set here", types[0].ref_name)
		inst.node = types[len(types) - 1 - inst.up]
		e.variant = inst
		e.type = .Struct
		return true
	case "_io":
		if operand.type != .Struct do return fail(r, .Invalid, e.offset, "%s has no _io; only a set has", type_name(operand.type))
		// the decoder finds the stream of an instance being decoded in its
		// frame, and keeps that of the instances of any other set; that of a
		// param is its argument's, whose set the compiler marks
		if _, is_instance := operand.variant.(mdata.Instance); !is_instance do keep_stream_of(operand)
		e.variant = mdata.Io{operand}
		e.type = .Stream
		return true
	case "_root":
		return fail(r, .Unsupported, e.offset, "._root is not supported")
	}

	#partial switch operand.type {
	case .Struct:
		return resolve_field(r, e, operand, m.name)
	case .Stream:
		return resolve_stream_member(r, e, operand, m.name)
	case .Array, .Bytes:
		switch m.name {
		case "size":
			e.variant = mdata.Size{operand}
			e.type = .Int
			return true
		case "first", "last", "min", "max":
			return resolve_array_method(r, e, operand, m.name)
		}
	case .String:
		switch m.name {
		case "length":
			e.variant = mdata.String_Length{operand}
			e.type = .Int
			return true
		case "to_i":
			e.variant = mdata.To_I{operand}
			e.type = .Int
			return true
		}
	case .Int:
		switch m.name {
		case "to_s":
			e.variant = mdata.To_S{operand}
			e.type = .String
			return true
		case "to_i":
			// an enum's value is its integer
			e.variant = operand.variant
			e.type = .Int
			return true
		}
	case .Bool, .Float:
		if m.name == "to_i" {
			e.variant = mdata.To_I{operand}
			e.type = .Int
			return true
		}
	}
	return fail(r, .Unsupported, e.offset, "%s has no member %s (of methods, only _sizeof, .size, .length, .first, .last, .min, .max, .to_i and .to_s are supported)", type_name(operand.type), m.name)
}

// stream.name, where name is pos, size or eof, of stream, a Stream
// expression, or of _io itself when it is nil.
@(private = "file")
resolve_stream_member :: proc(r: ^Resolver, e: ^mdata.Expr, stream: ^mdata.Expr, name: string) -> bool {
	if r.scope.instance != nil {
		// a value instance is evaluated also once its set instance is
		// decoded, in the stream the decoder then keeps; the position
		// changes as the stream is read, so a value that depends on it is
		// the one it had when first used, as in Kaitai
		if stream == nil do r.scope.types[len(r.scope.types) - 1].keeps_stream = true
		else do keep_streams(stream)
		if name == "pos" || name == "eof" do mark_cached(r)
	}
	switch name {
	case "pos":
		e.variant = mdata.Io_Pos{stream}
	case "size":
		e.variant = mdata.Io_Size{stream}
	case "eof":
		e.variant = mdata.Io_Eof{stream}
		e.type = .Bool
		return true
	case:
		return fail(r, .Unsupported, e.offset, "%s of a stream is not supported; only .pos, .size and .eof are", name)
	}
	e.type = .Int
	return true
}

// Marks the set of e, a Struct expression that is not an Instance,
// keeps_stream, or both sets of a ?:.
@(private = "file")
keep_stream_of :: proc(e: ^mdata.Expr) {
	if x, is_ternary := e.variant.(mdata.Ternary); is_ternary {
		keep_stream_of(x.then)
		keep_stream_of(x.otherwise)
		return
	}
	struct_node(e).keeps_stream = true
}

// Marks the sets whose streams stream, a Stream expression in a value
// instance, gives keeps_stream: those of _parent and the like too, as the
// value instance can be evaluated once they are no longer decoded. A
// field's is marked as its _io is resolved; the root's is always found.
@(private = "file")
keep_streams :: proc(stream: ^mdata.Expr) {
	#partial switch x in stream.variant {
	case mdata.Io:
		if inst, is_instance := x.instance.variant.(mdata.Instance); is_instance && !inst.root do inst.node.keeps_stream = true
	case mdata.Ternary:
		keep_streams(x.then)
		keep_streams(x.otherwise)
	}
}

// operand.name, where name is first, last, min or max, and operand an
// Array or Bytes.
@(private = "file")
resolve_array_method :: proc(r: ^Resolver, e: ^mdata.Expr, operand: ^mdata.Expr, name: string) -> bool {
	method: mdata.Array_Method_Kind
	switch name {
	case "first":
		method = .First
	case "last":
		method = .Last
	case "min":
		method = .Min
	case "max":
		method = .Max
	}
	t := mdata.Expr_Type.Int
	if operand.type == .Array do t = array_item_type(r, e, operand) or_return
	if (method == .Min || method == .Max) && t != .Int do return fail(r, .Unsupported, e.offset, ".%s of an array is only supported when its values are integers, not %s", name, type_name(t))
	e.variant = mdata.Array_Method{operand, method}
	e.type = t
	return true
}

// operand._sizeof: the size of an attribute or parse instance, a field
// name or base.name, or of the type of _root or _parent. It is known
// from the schema, so the attribute need not come before the expression.
@(private = "file")
resolve_member_size_of :: proc(r: ^Resolver, e: ^mdata.Expr, operand: ^mdata.Expr) -> bool {
	#partial switch x in operand.variant {
	case mdata.Name:
		if !is_special(x.name) {
			types := r.scope.types
			return resolve_size_of(r, e, types[len(types) - 1], x.name, false, false)
		}
	case mdata.Member:
		if !is_special(x.name) {
			// the operand is not evaluated, as the size replaces it
			type_only := r.type_only
			r.type_only = true
			resolved := resolve(r, x.operand)
			r.type_only = type_only
			if !resolved do return false
			if x.operand.type != .Struct do return fail(r, .Invalid, operand.offset, "%s has no field %s", type_name(x.operand.type), x.name)
			return resolve_size_of(r, e, struct_node(x.operand), x.name, false, false)
		}
	}
	resolve(r, operand) or_return
	if inst, is_instance := operand.variant.(mdata.Instance); is_instance {
		return resolve_size_of(r, e, inst.node, "", false, false)
	}
	return fail(r, .Unsupported, e.offset, "_sizeof is only supported of an attribute, a parse instance, _root and _parent")
}

// True for the names Kaitai gives special meanings: _root, _parent, _io,
// _ and _index.
@(private = "file")
is_special :: proc(name: string) -> bool {
	switch name {
	case "_root", "_parent", "_io", "_", "_index":
		return true
	}
	return false
}

// Makes e the Int_Literal of a size found with scope.size_of (Scope): in
// bytes, rounded up from the bits, unless bits is set.
@(private = "file")
resolve_size_of :: proc(r: ^Resolver, e: ^mdata.Expr, set: ^mdata.Node, name: string, of_type, bits: bool) -> bool {
	if r.scope.size_of == nil do return fail(r, .Invalid, e.offset, "sizes cannot be used here")
	n, err := r.scope.size_of(r.scope.data, set, name, of_type)
	if err.kind != .None {
		if r.err.kind == .None {
			err.offset = e.offset
			r.err = err
		} else {
			destroy_error(&err)
		}
		return false
	}
	e.variant = mdata.Int_Literal{bits ? n : (n + 7) / 8}
	e.type = .Int
	return true
}

// operand.as<type_name>. To an integer type, it is the operand, an Int, as
// it is: as in Kaitai's JavaScript and Python runtimes, a cast changes the
// type the compiler gives a value, not the value, and every integer is an
// Int. To a user type, the operand must be a switch-on field read once,
// which the cast gives as the instance of its cases of that type
// (Switch_Cast); the field is found whatever the types of its cases.
@(private = "file")
resolve_cast :: proc(r: ^Resolver, e: ^mdata.Expr, x: mdata.Cast) -> bool {
	if x.type_name == "bytes" {
		resolve(r, x.operand) or_return
		#partial switch x.operand.type {
		case .Bytes:
			e.variant = x.operand.variant
		case .Array:
			t := array_item_type(r, e, x.operand) or_return
			if t != .Int do return fail(r, .Invalid, e.offset, "an array of %s cannot be cast to bytes; only one of integers can", type_name(t))
			e.variant = mdata.To_Bytes{x.operand}
		case:
			return fail(r, .Invalid, e.offset, "%s cannot be cast to bytes; only an array of integers or a byte array can", type_name(x.operand.type))
		}
		e.type = .Bytes
		return true
	}
	if is_integer_type(x.type_name) {
		resolve(r, x.operand) or_return
		expect(r, x.operand, .Int) or_return
		e.variant = x.operand.variant
		e.type = .Int
		return true
	}

	#partial switch op in x.operand.variant {
	case mdata.Name:
		if !is_special(op.name) {
			resolve_field(r, x.operand, current_instance(r, x.operand.offset), op.name, any_switch = true) or_return
		} else {
			resolve(r, x.operand) or_return
		}
	case mdata.Member:
		if !is_special(op.name) && op.name != "_sizeof" {
			resolve(r, op.operand) or_return
			if op.operand.type != .Struct do return fail(r, .Invalid, x.operand.offset, "%s has no field %s", type_name(op.operand.type), op.name)
			resolve_field(r, x.operand, op.operand, op.name, any_switch = true) or_return
		} else {
			resolve(r, x.operand) or_return
		}
	case:
		resolve(r, x.operand) or_return
	}

	ref, is_ref := x.operand.variant.(mdata.Field_Ref)
	if !is_ref || ref.node.switch_on == nil || !mdata.is_single(ref.node) {
		return fail(r, .Unsupported, e.offset, "a cast to a user type (%s) is only supported of a switch-on field read once", x.type_name)
	}
	sw := ref.node.switch_on
	choices := make([dynamic]int, r.allocator)
	node: ^mdata.Node
	for c, i in sw.cases {
		if c.type != x.type_name do continue
		append(&choices, i)
		if node == nil do node = c.node
	}
	if sw.default_type == x.type_name && sw.default_type != "" {
		append(&choices, mdata.DEFAULT_CASE)
		if node == nil do node = sw.default
	}
	if node == nil do return fail(r, .Invalid, e.offset, "%s has no case of type %s", ref.node.ref_name, x.type_name)
	e.variant = mdata.Switch_Cast{x.operand, x.type_name, node, choices[:]}
	e.type = .Struct
	return true
}

// operand.name(args): .to_s(encoding) of a byte array, with a string
// literal, or .substring(from, to) of a string.
@(private = "file")
resolve_call :: proc(r: ^Resolver, e: ^mdata.Expr, x: mdata.Call) -> bool {
	resolve(r, x.operand) or_return
	for a in x.args do resolve(r, a) or_return
	switch {
	case x.name == "to_s" && x.operand.type == .Bytes:
		if len(x.args) != 1 do return fail(r, .Invalid, e.offset, ".to_s of a byte array takes 1 argument, its encoding, not %v", len(x.args))
		lit, is_literal := x.args[0].variant.(mdata.String_Literal)
		if !is_literal do return fail(r, .Unsupported, x.args[0].offset, "the encoding of .to_s must be a string literal")
		if r.scope.encoding == nil do return fail(r, .Invalid, e.offset, "encodings cannot be used here")
		enc, known := r.scope.encoding(lit.value)
		if !known do return fail(r, .Unsupported, x.args[0].offset, "encoding %q is not supported", lit.value)
		e.variant = mdata.Decode{x.operand, enc, lit.value}
		e.type = .String
	case x.name == "substring" && x.operand.type == .String:
		if len(x.args) != 2 do return fail(r, .Invalid, e.offset, ".substring takes 2 arguments, not %v", len(x.args))
		for a in x.args do expect(r, a, .Int) or_return
		e.variant = mdata.Substring{x.operand, x.args[0], x.args[1]}
		e.type = .String
	case:
		return fail(r, .Unsupported, e.offset, "%s has no method %s(...); only .to_s(encoding) of a byte array and .substring(from, to) of a string are supported", type_name(x.operand.type), x.name)
	}
	return true
}

// Whether name is an integer type, u1-u8 or s1-s8, with le or be or not.
@(private = "file")
is_integer_type :: proc(name: string) -> bool {
	base := name
	if len(base) == 4 && (base[2:] == "le" || base[2:] == "be") do base = base[:2]
	switch base {
	case "u1", "u2", "u4", "u8", "s1", "s2", "s4", "s8":
		return true
	}
	return false
}
