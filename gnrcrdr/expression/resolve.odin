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
	in_repeat: bool,        // the expression is evaluated for each element of a repeated field, so _index is defined
	element:   ^mdata.Node, // repeat-until and valid: the field whose element _ is; nil elsewhere
	enums:     []Enum,      // the enums enum constants may name; the first with a name is used
	instance:  bool,        // a value instance's expression, which cannot use _io

	// Called when an expression refers to a value instance whose expr is
	// nil, or a parse instance whose pos is nil, to compile it; on failure
	// the callback reports its own error. set is the set the expression
	// reaches it through, whose members it is of (mdata.members). When nil,
	// such a reference is an error.
	compile_instance:       proc(data: rawptr, set: ^mdata.Node, instance: ^mdata.Value_Instance) -> bool,
	compile_parse_instance: proc(data: rawptr, set: ^mdata.Node, instance: ^mdata.Node) -> bool,

	// Called for _sizeof, sizeof<t> and bitsizeof<t>: the size in bits that
	// Kaitai's compiler gives the attribute or parse instance called name
	// of set, or set's own type when name is "", or with of_type, the type
	// called name, as set's type names it. On failure it returns the error,
	// whose offset the resolver sets. When nil, these are an error.
	size_of: proc(data: rawptr, set: ^mdata.Node, name: string, of_type: bool) -> (bits: int, err: Error),
	data:    rawptr,
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
// and when the decoder would fail on it (overflow, division by zero).
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
		if b.root || b.up != 0 do return
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
	case mdata.Int_Literal:
		e.type = .Int
	case mdata.Bool_Literal:
		e.type = .Bool
	case mdata.String_Literal:
		e.type = .String
	case mdata.Unary:
		resolve(r, x.operand) or_return
		want: mdata.Expr_Type = x.op == .Not ? .Bool : .Int
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
		if x.then.type != .Int && x.then.type != .Bool && x.then.type != .String && x.then.type != .Stream do return fail(r, .Unsupported, x.then.offset, "?: on %s is not supported", type_name(x.then.type))
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
			// an Array is only ever all the values of a field
			field := x.operand.variant.(mdata.Field_Ref).node
			e.type = value_type(r, e, field, field.ref_name) or_return
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
	case mdata.Instance, mdata.Field_Ref, mdata.Size, mdata.String_Length, mdata.To_S, mdata.To_I, mdata.Array_Method, mdata.Io, mdata.Io_Pos, mdata.Io_Size, mdata.Io_Eof, mdata.Repeat_Index, mdata.Repeat_Element, mdata.Value_Ref:
		assert(e.type != .Unresolved, "resolve: a resolved variant without a type")
	case:
		panic("resolve: empty expression")
	}
	return true
}

@(private = "file")
resolve_enum_constant :: proc(r: ^Resolver, e: ^mdata.Expr, x: mdata.Enum_Constant) -> bool {
	for en in r.scope.enums {
		if en.name != x.enum_name do continue
		for v in en.values {
			if v.name == x.value_name {
				e.variant = mdata.Int_Literal{v.value}
				e.type = .Int
				return true
			}
		}
		return fail(r, .Invalid, e.offset, "enum %s has no value %s", x.enum_name, x.value_name)
	}
	return fail(r, .Invalid, e.offset, "no enum %s", x.enum_name)
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
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Mul, .Div, .Mod, .Sub, .Shl, .Shr, .And, .Xor, .Or:
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Lt, .Le, .Gt, .Ge:
		if x.left.type != .String do expect(r, x.left, .Int) or_return
		expect(r, x.right, x.left.type) or_return
		return .Bool, true
	case .Eq, .Ne:
		if x.left.type != .Int && x.left.type != .Bool && x.left.type != .String {
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

@(private = "file")
resolve_name :: proc(r: ^Resolver, e: ^mdata.Expr, name: string) -> bool {
	types := r.scope.types
	assert(len(types) > 0, "resolve: empty scope")

	// a value instance is evaluated for instances that may no longer be
	// decoded, whose streams are not kept
	if r.scope.instance && name == "_io" do return fail(r, .Unsupported, e.offset, "_io in a value instance is not supported")

	switch name {
	case "_root":
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
		base := new(mdata.Expr, r.allocator)
		base^ = {type = .Struct, offset = e.offset, variant = mdata.Instance{node = types[len(types) - 1]}}
		return resolve_field(r, e, base, name)
	}
	return true
}

// Makes e a reference to the field, parse instance, param or value
// instance called name in the set instance base.
@(private = "file")
resolve_field :: proc(r: ^Resolver, e: ^mdata.Expr, base: ^mdata.Expr, name: string) -> bool {
	set := mdata.members(struct_node(base))
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
				if !r.scope.compile_parse_instance(r.scope.data, struct_node(base), p) do return fail(r, .Invalid, e.offset, "instance %s is not valid", name)
				assert(p.pos != nil, "resolve: compile_parse_instance left the instance uncompiled")
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

	if !mdata.is_single(field) {
		// the type of its values is checked as an Array's is used
		if field.switch_on != nil do value_type(r, e, field, name) or_return
		e.type = .Array
	} else {
		e.type = value_type(r, e, field, name) or_return
	}

	e.variant = mdata.Field_Ref{base = base, node = field, slot = slot}
	return true
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
	case .Set:
		if field.switch_on != nil do return switch_type(r, e, field, name)
		return .Struct, true
	}
	return .Unresolved, fail(r, .Unsupported, e.offset, "%s is a %v; only integer, boolean, blob, string and set fields can be used in expressions", name, field.type)
}

// The type of one value of field, a switch-on: the type of the values of
// every case, and with a length and no _ case, of the bytes that an
// element no case chooses has. Cases of other types, as in Kaitai, give a
// value of no type that expressions can use but as a whole, which gnrcrdr
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
	e.variant = mdata.Value_Ref{base = base, instance = inst}
	e.type = inst.expr.type
	return true
}

// The set of an expression of type Struct.
@(private = "file")
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
	}
	panic("struct_node: not a set")
}

@(private = "file")
resolve_member :: proc(r: ^Resolver, e: ^mdata.Expr, m: mdata.Member) -> bool {
	if name, is_name := m.operand.variant.(mdata.Name); is_name && name.name == "_io" && !r.scope.instance {
		switch m.name {
		case "pos":
			e.variant = mdata.Io_Pos{}
		case "size":
			e.variant = mdata.Io_Size{}
		case "eof":
			e.variant = mdata.Io_Eof{}
			e.type = .Bool
			return true
		case:
			return fail(r, .Unsupported, e.offset, "_io.%s is not supported; only _io.pos, _io.size and _io.eof are", m.name)
		}
		e.type = .Int
		return true
	}

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
		// frame, and keeps that of the instances of any other set
		if _, is_instance := operand.variant.(mdata.Instance); !is_instance do struct_node(operand).keeps_stream = true
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
		return fail(r, .Unsupported, e.offset, "%s of a stream other than _io is not supported", m.name)
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
	case .Bool:
		if m.name == "to_i" {
			e.variant = mdata.To_I{operand}
			e.type = .Int
			return true
		}
	}
	return fail(r, .Unsupported, e.offset, "%s has no member %s (of methods, only _sizeof, .size, .length, .first, .last, .min, .max, .to_i and .to_s are supported)", type_name(operand.type), m.name)
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
	if operand.type == .Array {
		// an Array is only ever all the values of a field
		field := operand.variant.(mdata.Field_Ref).node
		t = value_type(r, e, field, field.ref_name) or_return
	}
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
			resolve(r, x.operand) or_return
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
