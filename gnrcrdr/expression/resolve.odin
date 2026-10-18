package expression

import dat "../data"
import mdata "../metadata"
import "core:fmt"
import "core:mem"

// Where an expression is evaluated: in an instance of the last of types,
// whose enclosing instances are of the types before it, outermost (_root)
// first. Names refer to fields of the last type.
Scope :: struct {
	types:     []^mdata.Node,
	in_repeat: bool, // the expression is evaluated for each element of a repeated field, so _index is defined
}

// Parses text and resolves it in scope. The result must have type want.
@(require_results)
compile :: proc(text: string, scope: Scope, want: mdata.Expr_Type, allocator: mem.Allocator) -> (e: ^mdata.Expr, err: Error) {
	e, err = parse(text, allocator)
	if err.kind != .None do return nil, err

	r := Resolver{scope = scope, allocator = allocator}
	if resolve(&r, e) && e.type != want {
		fail(&r, .Invalid, e.offset, "expected %s, found %s", type_name(want), type_name(e.type))
	}
	if r.err.kind != .None do return nil, r.err
	return e, {}
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
		return fail(r, .Unsupported, e.offset, "enum constants (%s::%s) are not supported yet", x.enum_name, x.value_name)
	case mdata.Instance, mdata.Field_Ref, mdata.Size, mdata.Io_Pos, mdata.Io_Size, mdata.Io_Eof, mdata.Repeat_Index, mdata.Peek:
		assert(e.type != .Unresolved, "resolve: a resolved variant without a type")
	case:
		panic("resolve: empty expression")
	}
	return true
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

	switch name {
	case "_root":
		e.variant = mdata.Instance{root = true, node = types[0]}
		e.type = .Struct
	case "_parent":
		if len(types) < 2 do return fail(r, .Invalid, e.offset, "_parent: %s has no enclosing set here", types[0].name)
		e.variant = mdata.Instance{up = 1, node = types[len(types) - 2]}
		e.type = .Struct
	case "_index":
		if !r.scope.in_repeat do return fail(r, .Invalid, e.offset, "_index is only defined for a repeated field")
		e.variant = mdata.Repeat_Index{}
		e.type = .Int
	case "_io":
		return fail(r, .Unsupported, e.offset, "only _io.pos, _io.size and _io.eof are supported")
	case "_":
		return fail(r, .Unsupported, e.offset, "_ is only defined in repeat-until, which is not supported yet")
	case:
		base := new(mdata.Expr, r.allocator)
		base^ = {type = .Struct, offset = e.offset, variant = mdata.Instance{node = types[len(types) - 1]}}
		return resolve_field(r, e, base, name)
	}
	return true
}

// Makes e a reference to the field called name in the set instance base.
@(private = "file")
resolve_field :: proc(r: ^Resolver, e: ^mdata.Expr, base: ^mdata.Expr, name: string) -> bool {
	set := struct_node(base)
	field: ^mdata.Node
	for child in set.children {
		if child.name == name {
			field = child
			break
		}
	}
	if field == nil do return fail(r, .Invalid, e.offset, "%s has no field %s", set.name, name)

	if !mdata.is_single(field) {
		e.type = .Array
	} else {
		#partial switch field.type {
		case .Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64:
			e.type = .Int
		case .Blob:
			e.type = .Bytes
		case .Set:
			e.type = .Struct
		case:
			return fail(r, .Unsupported, e.offset, "%s is a %v; only integer, blob and set fields can be used in expressions", name, field.type)
		}
	}

	e.variant = mdata.Field_Ref{base = base, node = field}
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
	}
	panic("struct_node: not a set")
}

@(private = "file")
resolve_member :: proc(r: ^Resolver, e: ^mdata.Expr, m: mdata.Member) -> bool {
	if name, is_name := m.operand.variant.(mdata.Name); is_name && name.name == "_io" {
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
		if inst.up >= len(types) do return fail(r, .Invalid, e.offset, "_parent: %s has no enclosing set here", types[0].name)
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

// Constructors for front ends that build expressions without text (the
// SQLite schema). Each returns a resolved node allocated with allocator;
// its offset is -1.

int_literal :: proc(value: int, allocator: mem.Allocator) -> ^mdata.Expr {
	return built(.Int, mdata.Int_Literal{value}, allocator)
}

// left and right must have the types the operator takes.
binary :: proc(op: mdata.Binary_Op, left, right: ^mdata.Expr, allocator: mem.Allocator) -> ^mdata.Expr {
	t: mdata.Expr_Type
	switch op {
	case .Mul, .Div, .Mod, .Add, .Sub, .Shl, .Shr, .And, .Xor, .Or:
		assert(left.type == .Int && right.type == .Int)
		t = .Int
	case .Lt, .Le, .Gt, .Ge:
		assert(left.type == .Int && right.type == .Int)
		t = .Bool
	case .Eq, .Ne:
		assert(left.type == right.type && (left.type == .Int || left.type == .Bool))
		t = .Bool
	case .Logical_And, .Logical_Or:
		assert(left.type == .Bool && right.type == .Bool)
		t = .Bool
	}
	return built(t, mdata.Binary{op, left, right}, allocator)
}

// cond must be Bool, and then and otherwise of one type, Int or Bool.
ternary :: proc(cond, then, otherwise: ^mdata.Expr, allocator: mem.Allocator) -> ^mdata.Expr {
	assert(cond.type == .Bool && then.type == otherwise.type && (then.type == .Int || then.type == .Bool))
	return built(then.type, mdata.Ternary{cond, then, otherwise}, allocator)
}

io_pos :: proc(allocator: mem.Allocator) -> ^mdata.Expr {
	return built(.Int, mdata.Io_Pos{}, allocator)
}

// type must be an integer type the reader can peek (not UInt64), and pos an
// Int.
peek :: proc(type: dat.Data_Type, pos: ^mdata.Expr, allocator: mem.Allocator) -> ^mdata.Expr {
	assert(type in bit_set[dat.Data_Type]{.Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64} && pos.type == .Int)
	return built(.Int, mdata.Peek{type, pos}, allocator)
}

@(private = "file")
built :: proc(t: mdata.Expr_Type, variant: mdata.Expr_Variant, allocator: mem.Allocator) -> ^mdata.Expr {
	e := new(mdata.Expr, allocator)
	e^ = {type = t, offset = -1, variant = variant}
	return e
}
