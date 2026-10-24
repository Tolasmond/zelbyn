package ksy

import expr "../expression"
import mdata "../metadata"
import yml "../yaml"
import "base:intrinsics"
import "core:fmt"
import "core:strings"

// The size in bits of the attribute or parse instance name of set, or of
// set's type, or with of_type, of the type name (expr.Scope.size_of).
@(private)
size_of_callback :: proc(data: rawptr, set: ^mdata.Node, name: string, of_type: bool) -> (bits: int, err: expr.Error) {
	c := (^Compiler)(data)
	td: ^Type_Def
	for st in c.type_defs {
		if st.set == mdata.members(set) {
			td = st.td
			break
		}
	}
	assert(td != nil, "size_of_callback: a set that was not compiled")
	unsized: string

	switch {
	case of_type:
		if prim, _, is_primitive := primitive(name); is_primitive {
			sizes := TYPE_SIZE
			return sizes[prim] * 8, {}
		}
		if width, _, is_bits := bit_type(name); is_bits do return width, {}
		if name == "str" || name == "strz" do return 0, size_error(.Invalid, "%s has no fixed size", name)
		user := find_type(td, name)
		if user == nil do return 0, size_error(.Invalid, "unknown type %s", name)
		bits, unsized = type_bits(c, user)
		return bits, unsized_error(name, unsized)
	case name == "":
		bits, unsized = type_bits(c, td)
		return bits, unsized_error(td.name, unsized)
	}

	if seq := get(td.spec, "seq"); seq != nil {
		for attr in seq.items {
			if id := get(attr, "id"); id == nil || id.text != name do continue
			if get(attr, "repeat") != nil do return 0, size_error(.Unsupported, "%s is repeated; _sizeof of a repeated attribute is not supported", name)
			bits, unsized = attr_bits(c, td, attr, name)
			return bits, unsized_error(name, unsized)
		}
	}
	for e in td.instances {
		if e.key.text != name do continue
		if get(e.value, "value") != nil do return 0, size_error(.Invalid, "%s is a value instance, which has no _sizeof", name)
		if get(e.value, "repeat") != nil do return 0, size_error(.Unsupported, "%s is repeated; _sizeof of a repeated attribute is not supported", name)
		bits, unsized = attr_bits(c, td, e.value, name)
		return bits, unsized_error(name, unsized)
	}
	for p in td.params {
		if p.id.text == name do return 0, size_error(.Invalid, "%s is a param, which has no _sizeof", name)
	}
	return 0, size_error(.Invalid, "%s has no field %s", set.ref_name, name)
}

@(private = "file")
size_error :: proc(kind: expr.Error_Kind, format: string, args: ..any) -> expr.Error {
	return {kind = kind, offset = -1, message = fmt.aprintf(format, ..args)}
}

// The error for what, whose size type_bits or attr_bits gave with unsized;
// none when it is "".
@(private = "file")
unsized_error :: proc(what, unsized: string) -> expr.Error {
	if unsized == "" do return {}
	if unsized == what do return size_error(.Invalid, "%s has no fixed size", what)
	return size_error(.Invalid, "%s has no fixed size: %s has none", what, unsized)
}

// The size in bits that Kaitai's compiler gives a value of td, for sizeof
// and _sizeof: the sum of its attributes' sizes (attr_bits), with no
// alignment after bit fields, though they are read with it. When an
// attribute has no fixed size, unsized is its path from td (a or a.b).
@(private = "file")
type_bits :: proc(c: ^Compiler, td: ^Type_Def) -> (bits: int, unsized: string) {
	assert(!td.sizing, "type_bits: a type that contains itself")
	td.sizing = true
	defer td.sizing = false

	seq := get(td.spec, "seq")
	if seq == nil do return 0, ""
	for attr, i in seq.items {
		id := get(attr, "id")
		n, why := attr_bits(c, td, attr, id == nil ? unnamed(c, i) : id.text)
		if why != "" do return 0, why
		overflow: bool
		bits, overflow = intrinsics.overflow_add(bits, n)
		if overflow do return 0, id.text
	}
	return bits, ""
}

// The size in bits of attr, of id in td, as Kaitai's compiler gives it: a
// constant size or the size of its type, times a constant repeat-expr.
// if is ignored, and any other repeat, the peek extensions, switch-on (even
// with a size), terminator without size, and size-eos have no fixed size:
// unsized is then id, or the path of the attribute inside id's type that
// has none.
@(private = "file")
attr_bits :: proc(c: ^Compiler, td: ^Type_Def, attr: ^yml.Node, id: string, element_only := false) -> (bits: int, unsized: string) {
	count := 1
	if repeat := get(attr, "repeat"); repeat != nil && !element_only {
		if repeat.text != "expr" do return 0, id
		ok: bool
		count, ok = constant_int(c, get(attr, "repeat-expr"))
		if !ok || count < 0 do return 0, id
	}
	for k in ([]string{"-peek", "-while-peek", "-until-peek"}) {
		if get(attr, k) != nil do return 0, id
	}

	type_node := get(attr, "type")
	if type_node != nil && type_node.kind != .Scalar do return 0, id
	element: int
	// as the official compiler does, contents reads its own length, whatever
	// the size
	if contents := get(attr, "contents"); contents != nil {
		element = contents_length(contents) * 8
	} else if size := get(attr, "size"); size != nil {
		n, ok := constant_int(c, size)
		if !ok || n < 0 || n > max(int) / 8 do return 0, id
		element = n * 8
	} else {
		if type_node == nil do return 0, id
		element, unsized = type_name_bits(c, td, type_node.text, id)
		if unsized != "" do return
	}
	overflow: bool
	bits, overflow = intrinsics.overflow_mul(element, count)
	if overflow do return 0, id
	return bits, ""
}

// The size in bits of the type that type_text names in td (with arguments,
// t(a, b)), for attr_bits of id.
@(private = "file")
type_name_bits :: proc(c: ^Compiler, td: ^Type_Def, type_text, id: string) -> (bits: int, unsized: string) {
	name := strings.trim_space(type_text)
	if open := strings.index_byte(name, '('); open >= 0 do name = strings.trim_space(name[:open])
	if prim, _, is_primitive := primitive(name); is_primitive {
		sizes := TYPE_SIZE
		return sizes[prim] * 8, ""
	}
	if width, _, is_bits := bit_type(name); is_bits do return width, ""
	user := find_type(td, name)
	// a type that contains itself has no fixed size
	if user == nil || user.sizing do return 0, id
	n, why := type_bits(c, user)
	if why != "" do return 0, fmt.aprintf("%s.%s", id, why, allocator = c.scratch)
	return n, ""
}

// Whether an element of attr, of id in td, reads no bytes: its size is 0,
// or without a size, its type is a switch-on whose cases' types all read
// none, which is no size for attr_bits, as for the official compiler.
@(private)
reads_nothing :: proc(c: ^Compiler, td: ^Type_Def, attr: ^yml.Node, id: string) -> bool {
	if type_node := get(attr, "type"); type_node != nil && type_node.kind == .Map && get(attr, "size") == nil {
		if cases := get(type_node, "cases"); cases != nil && cases.kind == .Map {
			for e in cases.entries {
				if e.value.kind != .Scalar do return false
				bits, unsized := type_name_bits(c, td, e.value.text, id)
				if unsized != "" || bits != 0 do return false
			}
		}
		return true
	}
	bits, unsized := attr_bits(c, td, attr, id, element_only = true)
	return unsized == "" && bits == 0
}

// The number of bytes of contents, a string or a sequence of bytes and
// strings (byte_list), its items told apart as byte_list does.
@(private = "file")
contents_length :: proc(contents: ^yml.Node) -> int {
	if contents.kind != .Seq do return len(contents.text)
	n := 0
	for item in contents.items do n += is_byte_item(item) ? 1 : len(item.text)
	return n
}

// The value of n when it is an expression of integer literals and
// operators, which Kaitai's compiler computes; ok is false for any other.
@(private = "file")
constant_int :: proc(c: ^Compiler, n: ^yml.Node) -> (v: int, ok: bool) {
	if n == nil || n.kind != .Scalar do return
	e, err := expr.parse(n.text, c.scratch)
	if err.kind != .None {
		expr.destroy_error(&err)
		return
	}
	return expr.constant(e)
}
