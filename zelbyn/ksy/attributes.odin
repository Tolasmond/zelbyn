package ksy

import dat "../data"
import expr "../expression"
import mdata "../metadata"
import yml "../yaml"
import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"

@(private = "file")
Primitive :: struct {
	name: string,
	type: dat.Data_Type,
}

@(private = "file")
PRIMITIVES :: [?]Primitive {
	{"u1", .UInt8},
	{"u2", .UInt16},
	{"u4", .UInt32},
	{"u8", .UInt64},
	{"s1", .Int8},
	{"s2", .Int16},
	{"s4", .Int32},
	{"s8", .Int64},
	{"f4", .Float32},
	{"f8", .Float64},
}

@(private)
INTEGER_TYPES :: bit_set[dat.Data_Type]{.Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64}

@(private)
TYPE_SIZE :: #partial [dat.Data_Type]int {
	.Int8    = 1,
	.UInt8   = 1,
	.Int16   = 2,
	.UInt16  = 2,
	.Int32   = 4,
	.UInt32  = 4,
	.Int64   = 8,
	.UInt64  = 8,
	.Float32 = 4,
	.Float64 = 8,
}

// A primitive type name: u1-u8, s1-s8, f4 or f8, with le or be after all
// but u1 and s1.
@(private)
primitive :: proc(name: string) -> (type: dat.Data_Type, order: Maybe(endian.Byte_Order), ok: bool) {
	for p in PRIMITIVES {
		if !strings.has_prefix(name, p.name) do continue
		switch name[len(p.name):] {
		case "":
			return p.type, nil, true
		case "le":
			if p.type != .UInt8 && p.type != .Int8 do return p.type, .Little, true
		case "be":
			if p.type != .UInt8 && p.type != .Int8 do return p.type, .Big, true
		}
	}
	return .Set, nil, false
}

// A bit type name: b1 to b64, with le or be after it or not.
@(private)
bit_type :: proc(name: string) -> (width: int, order: Maybe(endian.Byte_Order), ok: bool) {
	s := name
	switch {
	case strings.has_suffix(s, "le"):
		s, order = s[:len(s) - 2], .Little
	case strings.has_suffix(s, "be"):
		s, order = s[:len(s) - 2], .Big
	}
	if len(s) < 2 || len(s) > 3 || s[0] != 'b' || s[1] == '0' do return 0, nil, false
	for ch in transmute([]byte)s[1:] {
		if ch < '0' || ch > '9' do return 0, nil, false
		width = width * 10 + int(ch - '0')
	}
	return width, order, width <= 64
}

// The node of seq attribute index, with its id and name, for compile_field
// to compile the rest into. One without an id is named as in Kaitai
// (unnamed).
@(private)
new_attr :: proc(c: ^Compiler, td: ^Type_Def, attr: ^yml.Node, index: int, ids: ^[dynamic]^yml.Node) -> (node: ^mdata.Node, ok: bool) {
	id_node := get(attr, "id")
	if id_node == nil {
		id := unnamed(c, index)
		return new_node(c, display_name(c, attr, id) or_return, id), true
	}
	id := identifier(c, id_node, "id") or_return
	claim_id(c, ids, id, id_node) or_return

	name := display_name(c, attr, id) or_return
	return new_node(c, name, id), true
}

// The name Kaitai gives attribute index of a type, which has no id:
// _unnamed and its index in seq. No expression can refer to it.
@(private)
unnamed :: proc(c: ^Compiler, index: int) -> string {
	return fmt.aprintf("_unnamed%d", index, allocator = c.allocator)
}

// Compiles the keys of attr, an attribute or a parse instance, other than
// its id and pos, into node, in scope. ids holds the ids of the type, which
// bit fields claim; nil for a parse instance, which has none.
@(private)
compile_field :: proc(c: ^Compiler, td: ^Type_Def, attr: ^yml.Node, node: ^mdata.Node, scope: expr.Scope, ids: ^[dynamic]^yml.Node) -> bool {
	id := node.ref_name
	type_node := get(attr, "type")
	contents := get(attr, "contents")
	size := get(attr, "size")
	valid := get(attr, "valid")
	user: ^Type_Def
	call: Call // user's arguments
	switch_node: ^yml.Node

	strz := false

	// size-eos: false is the same as no size-eos
	size_eos := false
	if n := get(attr, "size-eos"); n != nil {
		size_eos = boolean(c, n, "size-eos") or_return
	}
	if size != nil && size_eos do return fail(c, .Invalid, get_key(attr, "size-eos"), "%s: size and size-eos cannot both be given", id)
	ends := size != nil || size_eos || get(attr, "terminator") != nil
	bytes_key := first_key(attr, BYTES_KEYS)

	switch {
	case contents != nil:
		if type_node != nil do return fail(c, .Invalid, get_key(attr, "type"), "%s: contents cannot have a type", id)
		// the official compiler reads the contents' length whatever the size,
		// which it does not compile; BYTES_KEYS starts with size
		keys := BYTES_KEYS
		if key := first_key(attr, keys[1:]); key != nil do return fail(c, .Invalid, key, "%s: contents cannot have %s", id, key.text)
		size = nil
		if valid != nil do return fail(c, .Invalid, get_key(attr, "valid"), "%s: contents already checks the value; it cannot have valid", id)
		bytes := byte_list(c, contents, "contents") or_return
		node.type = .Blob
		node.length = mdata.Fixed_Length{len(bytes)}
		node.valid = mdata.Valid_Eq{bytes}
	case type_node == nil:
		if !ends do return fail(c, .Invalid, attr, "%s needs a type, size, size-eos, terminator or contents", id)
		node.type = .Blob
	case type_node.kind == .Map:
		node.type = .Set
		switch_node = type_node
	case:
		type_name := expect_scalar(c, type_node, "type") or_return
		type_name, call = split_call(c, type_node, id, type_name) or_return
		// a type with arguments is a user type
		builtin := false
		if !call.given {
			builtin, strz = builtin_type(c, td, attr, type_node, id, type_name, ends, node) or_return
		}
		if builtin {
			if node.type != .String && bytes_key != nil do return fail(c, .Invalid, bytes_key, "%s: %s does not apply to %s", id, bytes_key.text, type_name)
		} else {
			user = find_type(td, type_name)
			if user == nil do return fail(c, .Invalid, type_node, "%s: unknown type %s", id, type_name)
			node.type = .Set
		}
	}

	if n := get(attr, "encoding"); n != nil {
		if node.type != .String do return fail(c, .Invalid, get_key(attr, "encoding"), "%s: encoding applies only to str", id)
		node.encoding = encoding(c, n) or_return
	} else if node.type == .String {
		meta, has_meta := td.meta.encoding.?
		if !has_meta do return fail(c, .Invalid, type_node, "%s: str needs an encoding, or meta encoding", id)
		node.encoding = meta
	}

	if n := get(attr, "process"); n != nil {
		text := expect_scalar(c, n, "process") or_return
		key := get_key(attr, "process")
		if node.type != .Blob && node.type != .Set do return fail(c, .Invalid, key, "%s: process applies only to a byte array or a user type", id)
		if contents != nil || !ends do return fail(c, .Invalid, key, "%s: process needs size, size-eos or terminator", id)
		if strings.trim_space(text) != "zlib" do return fail(c, .Unsupported, n, "%s: process %s is not supported; only zlib is", id, text)
		node.process = .Zlib
	}

	en: ^expr.Enum
	if n := get(attr, "enum"); n != nil {
		if node.type not_in INTEGER_TYPES && node.type != .Bits do return fail(c, .Invalid, get_key(attr, "enum"), "%s: enum applies only to integer types", id)
		// the field keeps its integer, which the enum's constants are
		en = check_enum(c, n, id, td) or_return
	}

	if n := get(attr, "if"); n != nil {
		node.cond = compile_expr(c, n, "if", scope, .Bool) or_return
	}

	node.count = compile_count(c, attr, id, scope) or_return

	if n := get(attr, "parent"); n != nil {
		if node.type != .Set do return fail(c, .Invalid, get_key(attr, "parent"), "%s: parent applies only to a user type", id)
		node.parent_up = compile_parent(c, n, id, scope) or_return
	}

	// size, switch-on and the bit fields are evaluated for each element
	element_scope := scope
	element_scope.in_repeat = !mdata.is_single(node)

	if size != nil {
		node.length = compile_length(c, size, id, element_scope) or_return
	} else if size_eos {
		node.length = mdata.Eos_Length{}
	}
	// a switch-on's strz cases take consume, include and eos-error
	compile_terminator(c, attr, id, node, strz, switch_node != nil && has_strz_case(switch_node)) or_return

	if bits := get(attr, "-bits"); bits != nil {
		if node.width > 0 do return fail(c, .Invalid, bits, "%s: -bits does not apply to a bit type", id)
		node.bits = compile_bits(c, bits, id, node.type, ids) or_return
	}

	if user != nil do compile_user(c, user, node, type_node, id, call, scope, element_scope) or_return
	if switch_node != nil {
		compile_switch(c, td, attr, switch_node, id, ends, node, element_scope) or_return
		if node.process != .None {
			for sc in node.switch_on.cases {
				if sc.node.type != .Set do return fail(c, .Unsupported, get_key(attr, "process"), "%s: process on a switch-on with a case that is not a user type is not supported", id)
			}
			if def := node.switch_on.default; def != nil && def.type != .Set {
				return fail(c, .Unsupported, get_key(attr, "process"), "%s: process on a switch-on with a case that is not a user type is not supported", id)
			}
		}
	}
	// after the type's fields, which an expr can refer to through _
	if valid != nil {
		node.valid = compile_valid(c, valid, id, node, en, scope) or_return
	}

	// repeat-until refers to the element just read, so it is compiled after
	// the element's fields
	if _, is_until := node.count.(mdata.Until_Count); is_until {
		until_scope := scope
		until_scope.element = node
		until_scope.in_repeat = true
		node.count = mdata.Until_Count{compile_expr(c, get(attr, "repeat-until"), "repeat-until", until_scope, .Bool) or_return}
	}
	return true
}

// Compiles type_name, the type of id given in n, into node when it is a
// primitive, bit or string type of an attribute attr of td: its type, and
// its byte or bit order. is_builtin is false for any other type, a user
// type. ends is set when attr has a size, size-eos or terminator, which a
// str needs. strz is set for strz, whose terminator compile_terminator adds.
@(private = "file")
builtin_type :: proc(c: ^Compiler, td: ^Type_Def, attr, n: ^yml.Node, id, type_name: string, ends: bool, node: ^mdata.Node) -> (is_builtin, strz, ok: bool) {
	if prim, order, is_primitive := primitive(type_name); is_primitive {
		sizes := TYPE_SIZE
		node.type = prim
		meta_order := td.meta.endian
		if meta_order == nil && td.meta.endian_switch != nil && sizes[prim] > 1 && order == nil {
			// the order of the instance of the type that declares the
			// switch-on, as the instance that reads this one gives it
			meta_order = c.order
			if meta_order == nil do return true, false, fail(c, .Unsupported, n, "%s: %s takes its byte order from the endian switch-on of type %s, but is read outside it", id, type_name, td.meta.endian_owner)
		}
		if order == nil && meta_order == nil && sizes[prim] > 1 {
			return true, false, fail(c, .Invalid, n, "%s: %s needs le or be, or meta endian", id, type_name)
		}
		node.order = order.? or_else (meta_order.? or_else .Little)
		return true, false, true
	}
	if type_name == "str" || type_name == "strz" {
		node.type = .String
		strz = type_name == "strz"
		if !strz && !ends do return true, strz, fail(c, .Invalid, n, "%s: str needs size, size-eos or terminator", id)
		return true, strz, true
	}
	if width, bit_order, is_bits := bit_type(type_name); is_bits {
		node.width = u8(width)
		node.order = bit_order.? or_else td.meta.bit_endian
		// b1 is a boolean, unless it has an enum
		node.type = width == 1 && get(attr, "enum") == nil ? .Bool : .Bits
		return true, false, true
	}
	return false, false, true
}

// type: switch-on and cases, n, of attr, on node, a set, whose length and
// terminator are already compiled. A case of a user type is compiled as a
// set with node's names, and one of a primitive, bit or string type as a
// field of that type. As the official compiler does, a string has node's
// length, terminator and pad-right, and the other types have none, so
// that their values are read whatever node's length. ends is as for
// builtin_type. switch-on is an integer, a boolean or a string; a case
// value is an integer or enum constant, true or false, or a string literal,
// or _ for the default. An element that no case chooses has no value, so a
// repeated field can have fewer values than elements, as in Kaitai.
@(private = "file")
compile_switch :: proc(c: ^Compiler, td: ^Type_Def, attr, n: ^yml.Node, id: string, ends: bool, node: ^mdata.Node, scope: expr.Scope) -> bool {
	keys := SWITCH_KEYS
	keys.what, keys.name = "%s: type", id
	check_keys(c, n, keys) or_return
	on := get(n, "switch-on")
	if on == nil do return fail(c, .Invalid, n, "%s: a type mapping needs switch-on", id)
	cases := get(n, "cases")
	if cases == nil do return fail(c, .Invalid, n, "%s: switch-on needs cases", id)
	expect_map(c, cases, "cases") or_return

	sw := new(mdata.Switch, c.allocator)
	// the cases are known as they are compiled, so that an expression can
	// cast the field to one of them (Switch_Cast)
	node.switch_on = sw
	sw.on = compile_expr(c, on, "switch-on", scope, .Unresolved) or_return
	by_text := sw.on.type == .String
	if !by_text && sw.on.type != .Int && sw.on.type != .Bool {
		return fail(c, .Unsupported, on, "%s: switch-on over %s is not supported; only over an integer, a boolean or a string", id, expr.type_name(sw.on.type))
	}

	list := make([dynamic]mdata.Switch_Case, c.allocator)
	seen := make(map[i128]^yml.Node, c.scratch)
	seen_text := make(map[string]^yml.Node, c.scratch)
	for e in cases.entries {
		is_default := e.key.text == "_" && e.key.style == .Plain
		value: i128
		text: string
		if is_default {
			// _ has no value to compare
		} else if by_text {
			key := compile_expr(c, e.key, "a case", scope, .String) or_return
			lit, is_literal := key.variant.(mdata.String_Literal)
			if !is_literal do return fail(c, .Unsupported, e.key, "%s: a case must be a string literal", id)
			text = lit.value
			if prev, dup := seen_text[text]; dup do return fail(c, .Invalid, e.key, "%s: case %s is already given (line %v, column %v)", id, e.key.text, prev.line, prev.column)
			seen_text[text] = e.key
		} else if sw.on.type == .Bool {
			// the value of a boolean case is 0 or 1, as the decoder compares it
			key := compile_expr(c, e.key, "a case", scope, .Bool) or_return
			lit, is_literal := key.variant.(mdata.Bool_Literal)
			if !is_literal do return fail(c, .Unsupported, e.key, "%s: a case must be true or false", id)
			value = i128(lit.value)
			if prev, dup := seen[value]; dup do return fail(c, .Invalid, e.key, "%s: case %s is already given (line %v, column %v)", id, e.key.text, prev.line, prev.column)
			seen[value] = e.key
		} else {
			key := compile_expr(c, e.key, "a case", scope, .Int) or_return
			// any integer an expression has, as the value is compared with
			// each in full
			v, is_literal := int_literal(key)
			if !is_literal do return fail(c, .Unsupported, e.key, "%s: a case must be an integer literal, from -2^63 to 2^64 - 1, or an enum constant", id)
			value = v
			if prev, dup := seen[value]; dup do return fail(c, .Invalid, e.key, "%s: case %v is already given (line %v, column %v)", id, value, prev.line, prev.column)
			seen[value] = e.key
		}

		type_name := expect_scalar(c, e.value, "a case type") or_return
		call: Call
		type_name, call = split_call(c, e.value, id, type_name) or_return
		case_node := new_node(c, node.name, node.ref_name)
		case_node.count = mdata.Fixed_Count{n = 1}
		case_node.parent_up = node.parent_up
		user_type := "" // for casts

		// a type with arguments is a user type
		builtin, strz := false, false
		if !call.given {
			builtin, strz = builtin_type(c, td, attr, e.value, id, type_name, ends, case_node) or_return
		}
		if builtin {
			if case_node.type == .String {
				meta, has_meta := td.meta.encoding.?
				if !has_meta do return fail(c, .Invalid, e.value, "%s: a case of type %s needs meta encoding", id, type_name)
				case_node.encoding = meta
				case_node.length = node.length
				compile_terminator(c, attr, id, case_node, strz) or_return
			}
		} else {
			user := find_type(td, type_name)
			if user == nil do return fail(c, .Invalid, e.value, "%s: unknown type %s", id, type_name)
			case_node.type = .Set
			compile_user(c, user, case_node, e.value, id, call, scope, scope) or_return
			user_type = type_name
		}

		if is_default {
			sw.default, sw.default_type = case_node, user_type
		} else {
			append(&list, mdata.Switch_Case{value, text, case_node, user_type})
			sw.cases = list[:]
		}
	}
	return true
}

// Whether a case of the switch-on n is strz.
@(private = "file")
has_strz_case :: proc(n: ^yml.Node) -> bool {
	cases := get(n, "cases")
	if cases == nil || cases.kind != .Map do return false
	for e in cases.entries {
		if e.value.kind == .Scalar && strings.trim_space(e.value.text) == "strz" do return true
	}
	return false
}

// The count from repeat (with repeat-expr or repeat-until), or from -peek,
// -while-peek or -until-peek. A repeat-until count is returned without
// its expression, which compile_field compiles.
@(private = "file")
compile_count :: proc(c: ^Compiler, attr: ^yml.Node, id: string, scope: expr.Scope) -> (count: mdata.Count, ok: bool) {
	repeat := get(attr, "repeat")
	repeat_expr := get(attr, "repeat-expr")
	repeat_until := get(attr, "repeat-until")

	peek_key: ^yml.Node
	for k in ([]string{"-peek", "-while-peek", "-until-peek"}) {
		key := get_key(attr, k)
		if key == nil do continue
		if peek_key != nil do return nil, fail(c, .Invalid, key, "%s: %s cannot be combined with %s", id, k, peek_key.text)
		if repeat != nil do return nil, fail(c, .Invalid, key, "%s: %s cannot be combined with repeat", id, k)
		peek_key = key
	}

	kind := ""
	if repeat != nil {
		kind = expect_scalar(c, repeat, "repeat") or_return
		switch kind {
		case "expr", "eos", "until":
		case:
			return nil, fail(c, .Invalid, repeat, "%s: repeat must be expr, eos or until, not %q", id, kind)
		}
	}
	if repeat_expr != nil && kind != "expr" do return nil, fail(c, .Invalid, get_key(attr, "repeat-expr"), "%s: repeat-expr needs repeat: expr", id)
	if repeat_until != nil && kind != "until" do return nil, fail(c, .Invalid, get_key(attr, "repeat-until"), "%s: repeat-until needs repeat: until", id)

	switch kind {
	case "eos":
		return mdata.Eos_Count{}, true
	case "until":
		if repeat_until == nil do return nil, fail(c, .Invalid, get_key(attr, "repeat"), "%s: repeat: until needs repeat-until", id)
		return mdata.Until_Count{}, true
	case "expr":
		if repeat_expr == nil do return nil, fail(c, .Invalid, get_key(attr, "repeat"), "%s: repeat: expr needs repeat-expr", id)
		e := compile_expr(c, repeat_expr, "repeat-expr", scope, .Int) or_return
		if lit, is_literal := e.variant.(mdata.Int_Literal); is_literal {
			if lit.value < 0 do return nil, fail(c, .Invalid, repeat_expr, "%s: repeat-expr is negative", id)
			return mdata.Fixed_Count{n = lit.value, repeat = true}, true
		}
		return mdata.Rule_Count{expr = e}, true
	}

	if peek_key == nil do return mdata.Fixed_Count{n = 1}, true

	value := get(attr, peek_key.text)
	bytes := byte_list(c, value, peek_key.text) or_return
	if len(bytes) == 0 do return nil, fail(c, .Invalid, value, "%s: %s needs at least one byte", id, peek_key.text)

	if peek_key.text == "-peek" {
		markers := make([]mdata.Marker, len(bytes), c.allocator)
		for b, i in bytes {
			markers[i] = {offset = i, type = .UInt8, value = int(b), order = .Little}
		}
		return mdata.Marker_Count{markers}, true
	}
	if len(bytes) > 1 do return nil, fail(c, .Unsupported, value, "%s: %s with more than one byte is not supported", id, peek_key.text)
	return mdata.Repeat_Count{type = .UInt8, value = int(bytes[0]), until = peek_key.text == "-until-peek", order = .Little}, true
}

@(private = "file")
compile_length :: proc(c: ^Compiler, size: ^yml.Node, id: string, scope: expr.Scope) -> (length: mdata.Length, ok: bool) {
	e := compile_expr(c, size, "size", scope, .Int) or_return
	if lit, is_literal := e.variant.(mdata.Int_Literal); is_literal {
		if lit.value < 0 do return nil, fail(c, .Invalid, size, "%s: size is negative", id)
		return mdata.Fixed_Length{lit.value}, true
	}
	return mdata.Rule_Length{expr = e}, true
}

// terminator, or strz's 0, with consume, include and eos-error, and
// pad-right, on node, whose length is compiled. consume and eos-error
// apply only without a length, and pad-right only with one; each defaults
// as in Kaitai. With strz_case, node is a switch-on with a strz case, which
// consume, include and eos-error apply to, so they are allowed without a
// terminator; node then has none.
@(private = "file")
compile_terminator :: proc(c: ^Compiler, attr: ^yml.Node, id: string, node: ^mdata.Node, strz: bool, strz_case := false) -> bool {
	sized := node.length != nil
	t := mdata.Terminator{consume = true, eos_error = true}
	terminated := strz
	flag_key, sized_key: ^yml.Node // the first of consume, include and eos-error, and of consume and eos-error
	for e in attr.entries {
		switch e.key.text {
		case "terminator":
			t.value = byte_value(c, e.value, id, "terminator") or_return
			terminated = true
		case "pad-right":
			if !sized do return fail(c, .Invalid, e.key, "%s: pad-right needs size or size-eos", id)
			node.pad_right = byte_value(c, e.value, id, "pad-right") or_return
		case "include":
			t.include = boolean(c, e.value, e.key.text) or_return
			if flag_key == nil do flag_key = e.key
		case "consume", "eos-error":
			v := boolean(c, e.value, e.key.text) or_return
			if e.key.text == "consume" do t.consume = v
			else do t.eos_error = v
			if flag_key == nil do flag_key = e.key
			if sized_key == nil do sized_key = e.key
		}
	}

	if sized && sized_key != nil && (terminated || strz_case) do return fail(c, .Invalid, sized_key, "%s: %s does not apply with a size", id, sized_key.text)
	if !terminated {
		if flag_key != nil && !strz_case do return fail(c, .Invalid, flag_key, "%s: %s applies only with terminator or strz", id, flag_key.text)
		return true
	}
	node.terminator = t
	return true
}

// -bits: packed subfields of an integer field, each a mapping of id,
// -orig-id (optional), low and high (inclusive bit numbers, 0 the least
// significant). Each is the unsigned number in those bits, of the smallest
// unsigned type that holds it. They are kept in order of their low bit.
@(private = "file")
compile_bits :: proc(c: ^Compiler, n: ^yml.Node, id: string, type: dat.Data_Type, ids: ^[dynamic]^yml.Node) -> (bits: []mdata.Bit_Field, ok: bool) {
	if type not_in INTEGER_TYPES do return nil, fail(c, .Invalid, n, "%s: -bits applies only to integer types", id)
	if n.kind != .Seq || len(n.items) == 0 do return nil, fail(c, .Invalid, n, "%s: -bits must be a non-empty sequence", id)

	sizes := TYPE_SIZE
	width := 8 * sizes[type]
	bits = make([]mdata.Bit_Field, len(n.items), c.allocator)

	for item, i in n.items {
		expect_map(c, item, "a -bits entry") or_return
		for e in item.entries {
			switch e.key.text {
			case "id", "-orig-id", "low", "high":
			case:
				return nil, fail(c, .Invalid, e.key, "%s: -bits: unknown key %q", id, e.key.text)
			}
		}

		id_node := get(item, "id")
		if id_node == nil do return nil, fail(c, .Invalid, item, "%s: a -bits entry has no id", id)
		bit_id := identifier(c, id_node, "id") or_return
		claim_id(c, ids, bit_id, id_node) or_return

		low := bit_number(c, item, "low", id) or_return
		high := bit_number(c, item, "high", id) or_return
		if low > high || high >= width {
			return nil, fail(c, .Invalid, item, "%s: %s has bits %v to %v, not within 0 to %v", id, bit_id, low, high, width - 1)
		}

		name := display_name(c, item, bit_id) or_return
		bits[i] = {name = name, low = low, high = high}
		switch count := high - low + 1; {
		case count <= 8:
			bits[i].type = .UInt8
		case count <= 16:
			bits[i].type = .UInt16
		case count <= 32:
			bits[i].type = .UInt32
		case:
			bits[i].type = .UInt64
		}
	}

	slice.stable_sort_by(bits, proc(a, b: mdata.Bit_Field) -> bool {return a.low < b.low})
	return bits, true
}

@(private = "file")
bit_number :: proc(c: ^Compiler, item: ^yml.Node, key, id: string) -> (n: int, ok: bool) {
	v := get(item, key)
	if v == nil do return 0, fail(c, .Invalid, item, "%s: a -bits entry has no %s", id, key)
	text := expect_scalar(c, v, key) or_return
	x, is_int := parse_int(text)
	if !is_int || x < 0 || x > 63 do return 0, fail(c, .Invalid, v, "%s: -bits %s must be a bit number, 0 to 63", id, key)
	return int(x), true
}
