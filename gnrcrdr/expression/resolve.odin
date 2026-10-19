package expression

import mdata "../metadata"
import "core:fmt"
import "core:mem"

// Where an expression is evaluated: in an instance of the last of types,
// whose enclosing instances are of the types before it, outermost (_root)
// first. Names refer to fields of the last type.
Scope :: struct {
	types:     []^mdata.Node,
	own_root:  bool,        // types[0] is the top level of an imported schema, its _root, but not the root of the decoded tree
	in_repeat: bool,        // the expression is evaluated for each element of a repeated field, so _index is defined
	element:   ^mdata.Node, // repeat-until: the field whose element _ is; nil elsewhere
	enums:     []Enum,      // the enums enum constants may name; the first with a name is used
	instance:  bool,        // a value instance's expression: it can use only the fields and value instances of the last type

	// Called when an expression refers to a value instance whose expr is
	// nil, or a parse instance whose pos is nil, to compile it; on failure
	// the callback reports its own error. When nil, such a reference is an
	// error.
	compile_instance:       proc(data: rawptr, set: ^mdata.Node, instance: ^mdata.Value_Instance) -> bool,
	compile_parse_instance: proc(data: rawptr, set: ^mdata.Node, instance: ^mdata.Node) -> bool,
	data:                   rawptr,
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

@(private = "file")
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
	case .Array:
		return "an array"
	case .Struct:
		return "a set"
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
		if x.then.type != .Int && x.then.type != .Bool do return fail(r, .Unsupported, x.then.offset, "?: on %s is not supported", type_name(x.then.type))
		expect(r, x.otherwise, x.then.type) or_return
		e.type = x.then.type
	case mdata.Name:
		return resolve_name(r, e, x.name)
	case mdata.Member:
		return resolve_member(r, e, x)
	case mdata.Enum_Constant:
		return resolve_enum_constant(r, e, x)
	case mdata.Instance, mdata.Field_Ref, mdata.Size, mdata.Io_Pos, mdata.Io_Size, mdata.Io_Eof, mdata.Repeat_Index, mdata.Repeat_Element, mdata.Value_Ref:
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
	case .Mul, .Div, .Mod, .Add, .Sub, .Shl, .Shr, .And, .Xor, .Or:
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Int, true
	case .Lt, .Le, .Gt, .Ge:
		expect(r, x.left, .Int) or_return
		expect(r, x.right, .Int) or_return
		return .Bool, true
	case .Eq, .Ne:
		if x.left.type != .Int && x.left.type != .Bool {
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

	if r.scope.instance && len(name) > 0 && name[0] == '_' {
		return fail(r, .Unsupported, e.offset, "%s in a value instance is not supported; it can use only the fields and value instances of its type", name)
	}

	switch name {
	case "_root":
		if r.scope.own_root {
			e.variant = mdata.Instance{up = len(types) - 1, node = types[0]}
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
		return fail(r, .Unsupported, e.offset, "only _io.pos, _io.size and _io.eof are supported")
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

// Makes e a reference to the field, parse instance or value instance
// called name in the set instance base.
@(private = "file")
resolve_field :: proc(r: ^Resolver, e: ^mdata.Expr, base: ^mdata.Expr, name: string) -> bool {
	set := struct_node(base)
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
				if !r.scope.compile_parse_instance(r.scope.data, set, p) do return fail(r, .Invalid, e.offset, "instance %s is not valid", name)
				assert(p.pos != nil, "resolve: compile_parse_instance left the instance uncompiled")
			}
			field, slot = p, k
			break
		}
	}
	if field == nil {
		for inst in set.instances {
			if inst.name == name do return resolve_value_ref(r, e, base, set, inst)
		}
		return fail(r, .Invalid, e.offset, "%s has no field %s", set.ref_name, name)
	}

	if !mdata.is_single(field) {
		if field.switch_on != nil do return fail(r, .Unsupported, e.offset, "%s is a switch-on field; it cannot be used in expressions", name)
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
	case .Bool:
		return .Bool, true
	case .Set:
		if field.switch_on != nil do return .Unresolved, fail(r, .Unsupported, e.offset, "%s is a switch-on field; it cannot be used in expressions", name)
		return .Struct, true
	}
	return .Unresolved, fail(r, .Unsupported, e.offset, "%s is a %v; only integer, boolean, blob and set fields can be used in expressions", name, field.type)
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
	case "_root", "_io":
		return fail(r, .Unsupported, e.offset, ".%s is not supported", m.name)
	}

	#partial switch operand.type {
	case .Struct:
		return resolve_field(r, e, operand, m.name)
	case .Array, .Bytes:
		if m.name == "size" {
			e.variant = mdata.Size{operand}
			e.type = .Int
			return true
		}
	}
	return fail(r, .Unsupported, e.offset, "%s has no member %s (of methods, only .size is supported)", type_name(operand.type), m.name)
}
