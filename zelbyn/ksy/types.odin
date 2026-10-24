package ksy

import dat "../data"
import expr "../expression"
import mdata "../metadata"
import yml "../yaml"
import "core:fmt"
import "core:slice"
import "core:strings"

// -orig-id when the mapping has one, else id, as when it is a list of the
// names of several original types (elf.ksy's Elf32_Versym, Elf64_Versym).
@(private)
display_name :: proc(c: ^Compiler, m: ^yml.Node, id: string) -> (name: string, ok: bool) {
	n := get(m, "-orig-id")
	if n == nil || n.kind == .Seq do return id, true
	name = expect_scalar(c, n, "-orig-id") or_return
	if name == "" do return "", fail(c, .Invalid, n, "-orig-id is empty")
	return name, true
}

// Builds the type spec (the top level when parent is nil, whose meta is
// top_meta) and the types declared in it, and checks the keys of every
// attribute, so that a key outside the subset is rejected even in a type
// nothing uses.
@(private)
build_type :: proc(c: ^Compiler, name: string, spec: ^yml.Node, parent: ^Type_Def, top_meta: Meta = {}) -> (td: ^Type_Def, ok: bool) {
	td = new(Type_Def, c.scratch)
	td^ = {name = name, spec = spec, schema = c.schema, parent = parent, meta = top_meta}

	if parent != nil {
		if spec.kind != .Map do return nil, fail(c, .Invalid, spec, "type %s must be a mapping", name)
		// -orig-id on a type documents its original name; nothing shows it
		check_keys(c, spec, {what = "type %s", name = name, allowed = TYPE_ALLOWED, extensions = {"-orig-id"}}) or_return
		td.meta = parent.meta
		if meta := get(spec, "meta"); meta != nil {
			td.meta = type_meta(c, name, meta, parent.meta) or_return
		}
	}
	// for the types declared in it, which inherit its meta
	if declares_endian_switch(td) do td.meta.endian_owner = name
	if n := get(spec, "to-string"); n != nil {
		check_to_string(c, n) or_return
	}

	if seq := get(spec, "seq"); seq != nil {
		if seq.kind != .Seq do return nil, fail(c, .Invalid, seq, "seq must be a sequence")
		for attr in seq.items {
			expect_map(c, attr, "an attribute") or_return
			keys := Keys{what = "an attribute", allowed = ATTR_ALLOWED, unsupported = ATTR_UNSUPPORTED, extensions = EXTENSIONS}
			if id := get(attr, "id"); id != nil && id.kind == .Scalar do keys.what, keys.name = "attribute %s", id.text
			check_keys(c, attr, keys) or_return
		}
	}

	if instances := get(spec, "instances"); instances != nil {
		expect_map(c, instances, "instances") or_return
		for e in instances.entries {
			inst_name := identifier(c, e.key, "instance name") or_return
			if e.value.kind != .Map do return nil, fail(c, .Invalid, e.value, "instance %s must be a mapping", inst_name)
			keys := get(e.value, "value") != nil ? VALUE_INSTANCE_KEYS : PARSE_INSTANCE_KEYS
			keys.what, keys.name = "instance %s", inst_name
			check_keys(c, e.value, keys) or_return
		}
		td.instances = instances.entries
	}

	if enums := get(spec, "enums"); enums != nil {
		td.enums = build_enums(c, enums) or_return
		if len(td.enums) >= INDEX_FROM {
			td.enum_index = make(map[string]^expr.Enum, len(td.enums), c.scratch)
			for &e in td.enums do td.enum_index[e.name] = &e
		}
	}
	if params := get(spec, "params"); params != nil {
		td.params = build_params(c, td, params) or_return
	}

	if types := get(spec, "types"); types != nil {
		expect_map(c, types, "types") or_return
		list := make([]^Type_Def, len(types.entries), c.scratch)
		for e, i in types.entries {
			type_name := identifier(c, e.key, "type name") or_return
			list[i] = build_type(c, type_name, e.value, td) or_return
		}
		td.types = list
		if len(list) >= INDEX_FROM {
			td.type_index = make(map[string]^Type_Def, len(list), c.scratch)
			for t in list do td.type_index[t.name] = t
		}
	}
	return td, true
}

// The meta of type name, over inherited, that of the type it is declared
// in. It has the keys of the schema's meta, as in Kaitai: an id, which
// names nothing, and the keys that document the schema, are checked and
// ignored.
@(private = "file")
type_meta :: proc(c: ^Compiler, name: string, meta: ^yml.Node, inherited: Meta) -> (m: Meta, ok: bool) {
	expect_map(c, meta, "meta") or_return
	keys := META_KEYS
	keys.what, keys.name = "type %s: meta", name
	check_keys(c, meta, keys) or_return
	if n := get(meta, "id"); n != nil {
		_ = identifier(c, n, "meta id") or_return
	}
	if k := get_key(meta, "imports"); k != nil do return {}, fail(c, .Unsupported, k, "type %s: imports in a type are not supported, only in the schema's meta", name)
	return meta_of(c, meta, inherited)
}

// to-string, which in Kaitai defines how a type's instances are shown, and
// which nothing zelbyn writes shows: it is parsed, so that a schema that
// is not valid Kaitai, or is outside the subset, is rejected, but not
// resolved, as the official compiler does not resolve its names either.
@(private = "file")
check_to_string :: proc(c: ^Compiler, n: ^yml.Node) -> bool {
	text := expect_scalar(c, n, "to-string") or_return
	_, err := expr.parse(text, c.scratch)
	if err.kind != .None do return expr_error(c, n, "to-string", err, 0)
	return true
}

@(private = "file")
build_enums :: proc(c: ^Compiler, n: ^yml.Node) -> (enums: []expr.Enum, ok: bool) {
	expect_map(c, n, "enums") or_return
	enums = make([]expr.Enum, len(n.entries), c.allocator)

	for e, i in n.entries {
		name := identifier(c, e.key, "enum name") or_return
		if e.value.kind != .Map do return nil, fail(c, .Invalid, e.value, "enum %s must be a mapping", name)

		values := make([]expr.Enum_Value, len(e.value.entries), c.allocator)
		// the index of each value before, by name and by integer, from
		// INDEX_FROM of them on
		names: map[string]int
		ints: map[int]int
		for v, j in e.value.entries {
			n, is_int := parse_int(v.key.text)
			if !is_int || v.key.style != .Plain do return nil, fail(c, .Invalid, v.key, "enum %s: %q is not an integer", name, v.key.text)
			if n > i128(max(int)) || n < i128(min(int)) do return nil, fail(c, .Unsupported, v.key, "enum %s: %v does not fit in a 64-bit signed integer", name, v.key.text)
			value_name := enum_value_name(c, name, v.value) or_return

			// the first value before with the same name or integer
			prev := -1
			if j < INDEX_FROM {
				for p, k in values[:j] {
					if p.name == value_name || p.value == int(n) {
						prev = k
						break
					}
				}
			} else {
				if j == INDEX_FROM {
					names = make(map[string]int, 2 * j, c.scratch)
					ints = make(map[int]int, 2 * j, c.scratch)
					for p, k in values[:j] do names[p.name], ints[p.value] = k, k
				}
				if k, seen := names[value_name]; seen do prev = k
				if k, seen := ints[int(n)]; seen && (prev < 0 || k < prev) do prev = k
				names[value_name], ints[int(n)] = j, j
			}
			if prev >= 0 {
				if values[prev].name == value_name do return nil, fail(c, .Invalid, v.value.kind == .Map ? get(v.value, "id") : v.value, "enum %s: %s appears twice", name, value_name)
				return nil, fail(c, .Invalid, v.key, "enum %s: value %v appears twice", name, v.key.text)
			}
			values[j] = {value_name, int(n)}
		}
		enums[i] = {name, values}
	}
	return enums, true
}

// params: each a mapping of id, type, enum, doc and doc-ref. A param holds
// an integer (of any integer type, whose value is kept as it is given), a
// boolean (bool), a byte array (bytes), a string (str), or an instance of
// a user type, which is checked where an argument is given for it
// (compile_args).
@(private = "file")
build_params :: proc(c: ^Compiler, td: ^Type_Def, n: ^yml.Node) -> (params: []Param_Def, ok: bool) {
	if n.kind != .Seq do return nil, fail(c, .Invalid, n, "params must be a sequence")
	params = make([]Param_Def, len(n.items), c.scratch)
	for item, i in n.items {
		expect_map(c, item, "a param") or_return
		keys := PARAM_KEYS
		if id := get(item, "id"); id != nil && id.kind == .Scalar do keys.what, keys.name = "param %s", id.text
		check_keys(c, item, keys) or_return
		id_node := get(item, "id")
		if id_node == nil do return nil, fail(c, .Invalid, item, "a param has no id")
		name := identifier(c, id_node, "param id") or_return

		type_node := get(item, "type")
		if type_node == nil do return nil, fail(c, .Unsupported, item, "param %s has no type; params of any type are not supported", name)
		type_name := expect_scalar(c, type_node, "type") or_return
		type: dat.Data_Type
		user := ""
		switch type_name {
		case "bool":
			type = .Bool
		case "bytes":
			type = .Blob
		case "str":
			type = .String
		case "struct", "io", "any":
			return nil, fail(c, .Unsupported, type_node, "param %s: type %s is not supported; only integer types, bool, bytes, str and user types are", name, type_name)
		case:
			prim, _, is_primitive := primitive(type_name)
			if is_primitive && prim in INTEGER_TYPES {
				type = .Int64
			} else if is_primitive || strings.contains(type_name, "[") {
				return nil, fail(c, .Unsupported, type_node, "param %s: type %s is not supported; only integer types, bool, bytes, str and user types are", name, type_name)
			} else {
				type, user = .Set, type_name
			}
		}

		if e := get(item, "enum"); e != nil {
			if type != .Int64 do return nil, fail(c, .Invalid, get_key(item, "enum"), "param %s: enum applies only to integer types", name)
			check_enum(c, e, name, td) or_return
		}
		params[i] = {id_node, type, user}
	}
	return params, true
}

// The name of a value of enum name: n itself, or the id of n in the long
// form, a mapping of id, doc and doc-ref.
@(private = "file")
enum_value_name :: proc(c: ^Compiler, name: string, n: ^yml.Node) -> (value_name: string, ok: bool) {
	if n.kind != .Map do return identifier(c, n, "enum value name")
	check_keys(c, n, {what = "enum %s", name = name, allowed = {"id", "doc", "doc-ref"}, extensions = {"-orig-id"}}) or_return
	id := get(n, "id")
	if id == nil do return "", fail(c, .Invalid, n, "enum %s: a value has no id", name)
	return identifier(c, id, "enum value name")
}

// The enum of an enum key, n, of id in td, which must name one.
@(private)
check_enum :: proc(c: ^Compiler, n: ^yml.Node, id: string, td: ^Type_Def) -> (en: ^expr.Enum, ok: bool) {
	enum_name := expect_scalar(c, n, "enum") or_return
	en = find_enum(td, enum_name)
	if en == nil do return nil, fail(c, .Invalid, n, "%s: no enum %s", id, enum_name)
	return en, true
}

// The type called name, looked up from td outward, then as the top-level
// type of td's schema, by its meta id, and among the schemas that td's
// schema imports. A path, a::b, is the type b declared in the type a.
@(private)
find_type :: proc(td: ^Type_Def, name: string) -> ^Type_Def {
	rest := name
	first := next_name(&rest)
	t := td
	for {
		if sub := nested_type(t, first); sub != nil {
			t = sub
			break
		}
		if t.parent == nil {
			t = t.name == first ? t : imported_type(td.schema, first)
			break
		}
		t = t.parent
	}
	for t != nil && rest != "" do t = nested_type(t, next_name(&rest))
	return t
}

// The type called name declared in td.
@(private = "file")
nested_type :: proc(td: ^Type_Def, name: string) -> ^Type_Def {
	if td.type_index != nil do return td.type_index[name]
	for sub in td.types {
		if sub.name == name do return sub
	}
	return nil
}

// The top-level type called name of a schema that schema imports.
@(private = "file")
imported_type :: proc(schema: ^Schema, name: string) -> ^Type_Def {
	for top in schema.imports {
		if top.name == name do return top
	}
	return nil
}

// The first name of the path rest (a::b), which it is then the rest of.
@(private = "file")
next_name :: proc(rest: ^string) -> string {
	name, _, after := strings.partition(rest^, "::")
	rest^ = after
	return name
}

// The enum called name in td: one declared in it or a type it is declared
// in, innermost first, or with a path (a::b::e), one declared in the type
// that find_type finds (a::b).
@(private = "file")
find_enum :: proc(td: ^Type_Def, name: string) -> ^expr.Enum {
	t := td
	if i := strings.last_index(name, "::"); i >= 0 {
		t = find_type(td, name[:i])
		if t == nil do return nil
		return own_enum(t, name[i + 2:])
	}
	for ; t != nil; t = t.parent {
		if e := own_enum(t, name); e != nil do return e
	}
	return nil
}

// The enum called name declared in td.
@(private = "file")
own_enum :: proc(td: ^Type_Def, name: string) -> ^expr.Enum {
	if td.enum_index != nil do return td.enum_index[name]
	for &e in td.enums {
		if e.name == name do return &e
	}
	return nil
}

// Compiles the attributes and instances of td as those of set, an instance
// of td. chain is the scope: the sets enclosing set, outermost first, then
// set. Each attribute's expressions can refer to the attributes before it,
// and to any instance whose expressions refer only to those. When set is
// inside a set of td being compiled, a type that contains itself, set is
// read as that set (Node.recursive), whose expressions must then not refer
// to the instances enclosing it, unless set has the same ones (parent:
// _parent). Once that set is compiled, set gets its members, so that the
// decoder and the dumps need not look for them.
@(private)
compile_fields :: proc(c: ^Compiler, td: ^Type_Def, set: ^mdata.Node, chain: []^mdata.Node, arg_sets: []^mdata.Node = nil) -> bool {
	if td.compiling != nil {
		set.recursive = td.compiling
		st := set_type(c, td.compiling)
		if st.reused_by == nil do st.reused_by = make([dynamic]^mdata.Node, c.scratch)
		append(&st.reused_by, set)
		if !slice.equal(chain[:len(chain) - 1], st.chain[:len(st.chain) - 1]) do st.reused_deeper = true
		// reused from a value instance compiled after the set (compile_deferred)
		if st.done do copy_members(set, td.compiling)
		return true
	}
	schema := c.schema
	defer c.schema = schema
	c.schema = td.schema
	td.compiling = set
	defer td.compiling = nil
	set_index := len(c.type_defs)
	append(&c.type_defs, Set_Type{set = set, td = td, chain = chain, outer = c.current})
	current := c.current
	defer c.current = current
	c.current = set

	ids := Ids{list = make([dynamic]^yml.Node, c.scratch)}

	// each instance is compiled when an expression first refers to it, or
	// else once every set is (compile_schema)
	scope := scope_of(c, chain)
	instances := make([dynamic]^mdata.Value_Instance, c.allocator)
	parse_instances := make([dynamic]^mdata.Node, c.allocator)
	for e in td.instances {
		if get(e.value, "value") != nil {
			inst := new(mdata.Value_Instance, c.allocator)
			inst.name = e.key.text
			src := new(Instance_Source, c.scratch)
			src^ = {spec = e.value, td = td, scope = scope}
			c.instances[inst] = src
			append(&instances, inst)
		} else {
			p := new_node(c, display_name(c, e.value, e.key.text) or_return, e.key.text)
			src := new(Parse_Source, c.scratch)
			src^ = {entry = e, td = td, scope = scope, order = c.order}
			c.parse_instances[p] = src
			append(&parse_instances, p)
		}
	}
	set.instances = instances[:]
	set.parse_instances = parse_instances[:]

	seq := get(td.spec, "seq")
	if len(td.params) > 0 {
		params := make([]^mdata.Node, len(td.params), c.allocator)
		for p, i in td.params {
			claim_id(c, &ids, p.id.text, p.id) or_return
			params[i] = new_node(c, p.id.text, p.id.text)
			params[i].type = p.type
			params[i].count = mdata.Fixed_Count{n = 1}
			params[i].is_param = true
			// its value is the instance its argument gives, of a set of its
			// type compiled elsewhere, whose members it has
			if p.type == .Set {
				copy_members(params[i], mdata.members(arg_sets[i]))
				append(&c.param_args, Param_Arg{params[i], mdata.members(arg_sets[i])})
			}
		}
		set.params = params

		// the params' slots follow the children's, and expressions in the
		// children refer to them (mdata.param_slot), so the slot count is
		// recorded first, from the attributes and their -bits
		set.slot_count = len(set.parse_instances) + len(set.params)
		if seq != nil {
			for attr in seq.items {
				set.slot_count += 1
				if bits := get(attr, "-bits"); bits != nil && bits.kind == .Seq do set.slot_count += len(bits.items)
			}
		}
	}

	if seq != nil {
		children := make([dynamic]^mdata.Node, c.allocator)
		after_bits := false
		for attr, i in seq.items {
			child := new_attr(c, td, attr, i, &ids) or_return
			// a field's own expressions can refer to it, as in Kaitai: in a
			// repeat, to the elements read so far
			append(&children, child)
			set.children = children[:]
			compile_field(c, td, attr, child, scope, &ids) or_return
			// as in Kaitai, a field that follows a bit type, and is not one,
			// starts at a byte
			child.align = after_bits && child.width == 0
			after_bits = child.width > 0
		}
	}
	slots := mdata.count_slots(set)
	assert(len(set.params) == 0 || set.slot_count == slots, "compile_fields: the slot count recorded first is wrong")
	set.slot_count = slots

	next_value, next_parse := 0, 0
	for e in td.instances {
		claim_id(c, &ids, e.key.text, e.key) or_return
		if get(e.value, "value") != nil {
			inst := instances[next_value]
			next_value += 1
			if inst.expr == nil do append(&c.deferred, Deferred{set = set, value = inst})
		} else {
			p := parse_instances[next_parse]
			next_parse += 1
			if p.pos == nil do append(&c.deferred, Deferred{set = set, parse = p})
		}
	}

	// the fields of td inside set are given its members, which are now
	// all made; their escapes are checked once every expression is compiled
	// (compile_schema)
	st := &c.type_defs[set_index]
	st.done = true
	for field in st.reused_by do copy_members(field, set)
	return true
}

// Gives field, a field of a type inside a set of that type (Node.recursive),
// the members of set.
@(private = "file")
copy_members :: proc(field, set: ^mdata.Node) {
	field.children = set.children
	field.slot_count = set.slot_count
	field.instances = set.instances
	field.parse_instances = set.parse_instances
	field.params = set.params
}

// Compiles item, an instance put off. The types of its set and the sets
// it is inside (Set_Type.outer), which its chain can skip (parent), are
// marked as being compiled again while it is, so that its type, or a parse
// instance or a type it compiles on demand, finds that a type inside one
// of them contains itself, as when it is compiled with its set.
@(private)
compile_deferred :: proc(c: ^Compiler, item: Deferred) -> bool {
	marked := make([dynamic]^Type_Def, c.scratch)
	defer for td in marked do td.compiling = nil
	for set := item.set; set != nil; {
		st := set_type(c, set)
		if st.td.compiling == nil {
			st.td.compiling = set
			append(&marked, st.td)
		}
		set = st.outer
	}
	if item.value != nil do return compile_instance(c, item.set, item.value)
	return compile_parse_instance(c, item.set, item.parse)
}

// The entry of c.type_defs for set, which was compiled.
@(private = "file")
set_type :: proc(c: ^Compiler, set: ^mdata.Node) -> ^Set_Type {
	#reverse for &st in c.type_defs {
		if st.set == set do return &st
	}
	panic("set_type: a set that was not compiled")
}

// Records e, the expression of n (what) compiled in scope, as the escape of
// each set of the scope that it refers to a member of an instance
// enclosing, through _parent, or in a value instance, to the _root of an
// imported schema, which up reaches there. In a set that is reused
// (Node.recursive), such an instance is of another set for the set's other
// instances, and for the instances of the set that reuses it, which are
// inside it, that root is the nearest instance of it, not the outermost.
// Elsewhere the decoder finds that root among its frames (imported_root),
// at any depth. The _io of an enclosing instance is found from the instance
// the decoder reaches, and so is right in each of them.
@(private)
note_escapes :: proc(c: ^Compiler, n: ^yml.Node, what: string, e: ^mdata.Expr, scope: expr.Scope) {
	if e == nil do return
	switch x in e.variant {
	case mdata.Instance:
		if x.root || (x.up == 0 && !x.imported_root) do return
		if x.imported_root && scope.instance == nil do return
		innermost := len(scope.types) - 1
		// the root of an imported schema is the outermost instance of it, not
		// the up-th enclosing instance of a reused set
		target := x.imported_root ? -1 : innermost - x.up
		for set in scope.types[target + 1:] {
			if st := set_type(c, set); st.escape == nil {
				st.escape, st.escape_what, st.escape_schema = n, what, c.schema
			}
		}
	case mdata.Unary:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.Binary:
		note_escapes(c, n, what, x.left, scope)
		note_escapes(c, n, what, x.right, scope)
	case mdata.Ternary:
		note_escapes(c, n, what, x.cond, scope)
		note_escapes(c, n, what, x.then, scope)
		note_escapes(c, n, what, x.otherwise, scope)
	case mdata.Index:
		note_escapes(c, n, what, x.operand, scope)
		note_escapes(c, n, what, x.index, scope)
	case mdata.Field_Ref:
		note_escapes(c, n, what, x.base, scope)
	case mdata.Size:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.String_Length:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.To_S:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.To_I:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.Decode:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.To_Bytes:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.Substring:
		note_escapes(c, n, what, x.operand, scope)
		note_escapes(c, n, what, x.from, scope)
		note_escapes(c, n, what, x.to, scope)
	case mdata.Array_Method:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.Io:
		if inst, is_instance := x.instance.variant.(mdata.Instance); is_instance && !inst.imported_root do return
		note_escapes(c, n, what, x.instance, scope)
	case mdata.Value_Ref:
		note_escapes(c, n, what, x.base, scope)
	case mdata.Switch_Cast:
		note_escapes(c, n, what, x.operand, scope)
	case mdata.Array_Literal:
		for item in x.items do note_escapes(c, n, what, item, scope)
	case mdata.Io_Pos:
		note_escapes(c, n, what, x.stream, scope)
	case mdata.Io_Size:
		note_escapes(c, n, what, x.stream, scope)
	case mdata.Io_Eof:
		note_escapes(c, n, what, x.stream, scope)
	case mdata.Int_Literal, mdata.Big_Literal, mdata.Float_Literal, mdata.Bool_Literal, mdata.String_Literal, mdata.Bytes_Literal, mdata.Root_Arg, mdata.Repeat_Index, mdata.Repeat_Element:
	case mdata.Name, mdata.Member, mdata.Enum_Constant, mdata.Size_Of, mdata.Cast, mdata.Call:
		panic("note_escapes: unresolved expression")
	}
}

// The scope of expressions in the set that is the last of chain.
@(private = "file")
scope_of :: proc(c: ^Compiler, chain: []^mdata.Node) -> expr.Scope {
	no_root := slice.contains(c.rootless[:], chain[0])
	return {
		types                  = chain,
		own_root               = chain[0] != c.root && !no_root,
		no_root                = no_root,
		find_enum              = find_enum_callback,
		compile_instance       = compile_instance_callback,
		compile_parse_instance = compile_parse_instance_callback,
		size_of                = size_of_callback,
		same_type              = same_type_callback,
		encoding               = encoding_named,
		data                   = c,
	}
}

@(private = "file")
compile_instance_callback :: proc(data: rawptr, set: ^mdata.Node, inst: ^mdata.Value_Instance) -> bool {
	return compile_instance((^Compiler)(data), set, inst)
}

@(private = "file")
compile_parse_instance_callback :: proc(data: rawptr, set: ^mdata.Node, inst: ^mdata.Node, type_only: bool) -> bool {
	return compile_parse_instance((^Compiler)(data), set, inst, type_only)
}

// The enum called name in the type of set, a set compiled
// (expr.Scope.find_enum).
@(private = "file")
find_enum_callback :: proc(data: rawptr, set: ^mdata.Node, name: string) -> ^expr.Enum {
	return find_enum(set_type((^Compiler)(data), set).td, name)
}

// Whether sets a and b, compiled, are of the same type (expr.Scope.same_type).
@(private = "file")
same_type_callback :: proc(data: rawptr, a, b: ^mdata.Node) -> bool {
	c := (^Compiler)(data)
	sa, sb := mdata.members(a), mdata.members(b)
	if sa == sb do return true
	ta, tb: ^Type_Def
	for st in c.type_defs {
		if st.set == sa do ta = st.td
		if st.set == sb do tb = st.td
	}
	return ta != nil && ta == tb
}

// Compiles inst, a parse instance of set (of its members), as an attribute,
// then its io and pos, or with type_only, for the operand of _sizeof, only
// as an attribute, once. It can use the fields of set compiled so far, and
// its instances, and once every set is, any field. pos is compiled last:
// until it is set, a reference to inst compiles it, so that one from inst
// itself is found, also through a field of its type inside it
// (set.recursive), which is another instance, but whose type is not known
// yet; one for its type alone is not to itself once that is compiled, as
// mcap.ksy's pos of footer uses footer.op._sizeof.
@(private = "file")
compile_parse_instance :: proc(c: ^Compiler, set: ^mdata.Node, inst: ^mdata.Node, type_only := false) -> bool {
	src := c.parse_instances[inst]
	schema := c.schema
	defer c.schema = schema
	c.schema = src.td.schema
	current := c.current
	defer c.current = current
	c.current = mdata.members(set)
	if type_only && src.typed do return true
	if src.compiling && set.recursive != nil do return fail(c, .Unsupported, src.entry.key, "instance %s refers to itself in a field of its type; a type that contains itself cannot be compiled that way", inst.ref_name)
	if src.compiling do return fail(c, .Invalid, src.entry.key, "instance %s refers to itself", inst.ref_name)
	enter(c, src.entry.key, inst.ref_name) or_return
	defer leave(c)
	src.compiling = true
	defer src.compiling = false
	order := c.order
	defer c.order = order
	c.order = src.order

	spec := src.entry.value
	pos := get(spec, "pos")
	if !src.typed {
		// Kaitai reads one without pos where its stream is when it is first
		// used, and moves the stream past it, which is known only for one
		// that reads nothing
		if pos == nil && !reads_nothing(c, src.td, spec, inst.ref_name) {
			return fail(c, .Unsupported, src.entry.key, "instance %s: an instance without pos or value that reads bytes is not supported; only one whose type or size reads none is", inst.ref_name)
		}
		compile_field(c, src.td, spec, inst, src.scope, nil) or_return
		src.typed = true
	}
	if type_only do return true
	if n := get(spec, "io"); n != nil {
		inst.io = compile_expr(c, n, "io", src.scope, .Stream) or_return
	}
	if pos == nil {
		inst.at_stream_pos = true
		inst.pos = new_expr(c, .Int, mdata.Io_Pos{})
		return true
	}
	inst.pos = compile_expr(c, pos, "pos", src.scope, .Int) or_return
	return true
}

// Compiles the if and the expression of inst, a value instance of set (of
// its members). They can use the fields of set compiled so far and its
// other value instances, and through _root and _parent, those of the sets
// enclosing it. An enum keeps the integer, as on an attribute. A reference
// to inst while it is compiled is to itself, or through a field of its
// type inside it (set.recursive), to that of another instance, whose type
// is not known yet.
@(private = "file")
compile_instance :: proc(c: ^Compiler, set: ^mdata.Node, inst: ^mdata.Value_Instance) -> bool {
	src := c.instances[inst]
	schema := c.schema
	defer c.schema = schema
	c.schema = src.td.schema
	value := get(src.spec, "value")
	if src.compiling && set.recursive != nil do return fail(c, .Unsupported, value, "value instance %s refers to itself in a field of its type; a type that contains itself cannot be compiled that way", inst.name)
	if src.compiling do return fail(c, .Invalid, value, "value instance %s refers to itself", inst.name)
	enter(c, value, inst.name) or_return
	defer leave(c)
	src.compiling = true
	defer src.compiling = false

	scope := src.scope
	scope.instance = inst

	if n := get(src.spec, "if"); n != nil {
		inst.cond = compile_expr(c, n, "if", scope, .Bool) or_return
	}
	e := compile_expr(c, value, "value", scope, .Unresolved) or_return
	#partial switch e.type {
	case .Int, .Float, .Bool, .String, .Bytes, .Struct, .Array:
	case:
		return fail(c, .Unsupported, value, "value instance %s: only integer, float, boolean, string, byte array, set and array values are supported, not %s", inst.name, expr.type_name(e.type))
	}
	if n := get(src.spec, "enum"); n != nil {
		if e.type != .Int do return fail(c, .Invalid, get_key(src.spec, "enum"), "value instance %s: enum applies only to integer values", inst.name)
		check_enum(c, n, inst.name, src.td) or_return
	}
	inst.expr = e
	return true
}

// How many names a type's ids, types, enums or an enum's values hold before
// they are looked up in a map. Most types have few, and searching them
// costs less than hashing, but n names, each checked against or looked up
// among the others, would take n^2 / 2 comparisons.
@(private)
INDEX_FROM :: 64

// The id nodes of a type's attributes, bit fields and instances, in list,
// and from INDEX_FROM of them on, by name in index too, which claim_id
// builds then.
@(private)
Ids :: struct {
	list:  [dynamic]^yml.Node,
	index: map[string]^yml.Node, // in c.scratch
}

@(private)
claim_id :: proc(c: ^Compiler, ids: ^Ids, id: string, n: ^yml.Node) -> bool {
	prev: ^yml.Node
	if len(ids.list) < INDEX_FROM {
		for p in ids.list {
			if p.text == id {
				prev = p
				break
			}
		}
	} else {
		if ids.index == nil {
			ids.index = make(map[string]^yml.Node, 2 * len(ids.list), c.scratch)
			for p in ids.list do ids.index[p.text] = p
		}
		if prev = ids.index[id]; prev == nil do ids.index[id] = n
	}
	if prev != nil do return fail(c, .Invalid, n, "id %s is already used (line %v, column %v)", id, prev.line, prev.column)
	append(&ids.list, n)
	return true
}

// The chain of node, a field of type user in a type whose chain is types:
// types followed by node, without the parent_up innermost of types when
// node has a parent, or node alone when user is declared in another schema
// than the field's (c.schema). As in Kaitai, node then has no _parent, and
// at the top level of its schema, is the root of its own types (their
// _root); elsewhere, it and the types in it have no _root (c.rootless).
@(private = "file")
chain_of :: proc(c: ^Compiler, types: []^mdata.Node, user: ^Type_Def, node: ^mdata.Node) -> []^mdata.Node {
	if user.schema == c.schema do return chain_with(c, types[:len(types) - node.parent_up], node)
	if user.parent != nil do append(&c.rootless, node)
	return chain_with(c, nil, node)
}

// types followed by node.
@(private = "file")
chain_with :: proc(c: ^Compiler, types: []^mdata.Node, node: ^mdata.Node) -> []^mdata.Node {
	chain := make([]^mdata.Node, len(types) + 1, c.scratch)
	copy(chain, types)
	chain[len(types)] = node
	return chain
}

// parent: n, of id, a user type: as in Kaitai, the _parent of its
// instances is the instance it gives, rather than the one each is read in.
// It must be one enclosing that instance (_parent, _parent._parent), whose
// levels out it returns (Node.parent_up).
@(private)
compile_parent :: proc(c: ^Compiler, n: ^yml.Node, id: string, scope: expr.Scope) -> (up: int, ok: bool) {
	e := compile_expr(c, n, "parent", scope, .Struct) or_return
	inst, is_instance := e.variant.(mdata.Instance)
	if !is_instance || inst.root || inst.imported_root do return 0, fail(c, .Unsupported, n, "%s: parent is only supported as _parent, _parent._parent and so on", id)
	return inst.up, true
}

// The arguments of a type, t(a, b): the text between the parentheses, and
// the byte it starts at in the type's scalar. given is false for a type
// without parentheses.
@(private)
Call :: struct {
	args:  string,
	start: int,
	given: bool,
}

// Splits text, the type of id in n, into its name and its arguments. The
// whitespace around them is ignored, such as the line break at the end of
// a block scalar.
@(private)
split_call :: proc(c: ^Compiler, n: ^yml.Node, id, text: string) -> (name: string, call: Call, ok: bool) {
	open := strings.index_byte(text, '(')
	if open < 0 do return text, {}, true
	end := len(strings.trim_right_space(text))
	if text[end - 1] != ')' do return "", {}, fail(c, .Invalid, n, "%s: type %s does not end with )", id, strings.trim_space(text))
	return strings.trim_space(text[:open]), {text[open + 1:end - 1], open + 1, true}, true
}

// Compiles node, of type user given in n with the arguments of call, in
// scope, for field id, whose scope is field_scope. The arguments come
// after the type's fields, which they can refer to: in a repeat, through
// the elements read so far. Of a type with a param of a user type they
// come first: the param has the members of the set of its argument
// (compile_args).
@(private)
compile_user :: proc(c: ^Compiler, user: ^Type_Def, node: ^mdata.Node, n: ^yml.Node, id: string, call: Call, field_scope, scope: expr.Scope) -> bool {
	for p in user.params {
		if p.type != .Set do continue
		arg_sets: []^mdata.Node
		node.args, arg_sets = compile_args(c, n, id, user, call, scope) or_return
		return compile_type(c, user, node, field_scope, arg_sets)
	}
	compile_type(c, user, node, field_scope) or_return
	node.args, _ = compile_args(c, n, id, user, call, scope) or_return
	return true
}

// Compiles the fields of user into node, a set of a field of scope. A type
// whose endian is a switch-on is compiled twice: little-endian into node,
// and big-endian into a set of its own, which node's Order_Switch chooses
// as each instance is read. The types declared in it take the order of the
// set they are compiled in (Compiler.order). Expressions refer to node's
// members, which have the same slots as the other set's.
@(private)
compile_type :: proc(c: ^Compiler, user: ^Type_Def, node: ^mdata.Node, field_scope: expr.Scope, arg_sets: []^mdata.Node = nil) -> bool {
	enter(c, user.spec, fmt.tprintf("type %s", user.name)) or_return
	defer leave(c)
	if !declares_endian_switch(user) do return compile_fields(c, user, node, chain_of(c, field_scope.types, user, node), arg_sets)

	sw_node := user.meta.endian_switch
	// inside itself, each instance would choose its own order, which a set
	// reused for it does not
	if user.compiling != nil do return fail(c, .Unsupported, sw_node, "type %s, whose endian is a switch-on, contains itself, which is not supported", user.name)
	order := c.order
	defer c.order = order

	c.order = .Little
	chain := chain_of(c, field_scope.types, user, node)
	compile_fields(c, user, node, chain, arg_sets) or_return
	big := new_node(c, node.name, node.ref_name)
	big.type = .Set
	c.order = .Big
	compile_fields(c, user, big, chain_of(c, field_scope.types, user, big), arg_sets) or_return

	// evaluated in the instance, before its fields are read
	schema := c.schema
	defer c.schema = schema
	c.schema = user.schema
	scope := scope_of(c, chain)
	on := compile_expr(c, get(sw_node, "switch-on"), "switch-on", scope, .Unresolved) or_return
	#partial switch on.type {
	case .Int, .Bool, .String, .Bytes:
	case:
		return fail(c, .Unsupported, get(sw_node, "switch-on"), "endian: switch-on over %s is not supported; only over an integer, a boolean, a string or a byte array", expr.type_name(on.type))
	}
	sw := new(mdata.Order_Switch, c.allocator)
	sw.big = big
	cases := make([dynamic]mdata.Order_Case, c.allocator)
	for e in get(sw_node, "cases").entries {
		case_order := byte_order(c, e.value, "endian") or_return
		if e.key.text == "_" && e.key.style == .Plain {
			sw.default = case_order
			continue
		}
		key := compile_expr(c, e.key, "a case", scope, on.type) or_return
		test := new_expr(c, .Bool, mdata.Binary{.Eq, on, key})
		append(&cases, mdata.Order_Case{test, case_order})
	}
	sw.cases = cases[:]
	node.order_switch = sw
	return true
}

// Whether td's own meta has an endian that is a switch-on.
@(private)
declares_endian_switch :: proc(td: ^Type_Def) -> bool {
	sw := td.meta.endian_switch
	meta := get(td.spec, "meta")
	return sw != nil && meta != nil && get(meta, "endian") == sw
}

// The arguments of call, of user, the type of id given in n, compiled in
// scope: one for each of user's params, of its type, and for each param of
// a user type, the set of its argument, compiled, of that type (nil for
// the others).
@(private = "file")
compile_args :: proc(c: ^Compiler, n: ^yml.Node, id: string, user: ^Type_Def, call: Call, scope: expr.Scope) -> (args: []^mdata.Expr, arg_sets: []^mdata.Node, ok: bool) {
	if !call.given && len(user.params) == 0 do return nil, nil, true
	err: expr.Error
	args, err = expr.compile_list(call.args, scope, c.allocator)
	if err.kind != .None do return nil, nil, expr_error(c, n, "type", err, call.start)
	for a in args do note_escapes(c, n, "type", a, scope)
	if len(args) != len(user.params) {
		return nil, nil, fail(c, .Invalid, n, "%s: type %s takes %v argument%s, not %v", id, user.name, len(user.params), len(user.params) == 1 ? "" : "s", len(args))
	}

	for a, i in args {
		p := user.params[i]
		want: mdata.Expr_Type
		#partial switch p.type {
		case .Int64:
			want = .Int
		case .Bool:
			want = .Bool
		case .Blob:
			want = .Bytes
		case .String:
			want = .String
		case .Set:
			want = .Struct
		}
		if a.type != want {
			message := fmt.aprintf("argument %v of %s, %s, must be %s, not %s", i + 1, user.name, p.id.text, expr.type_name(want), expr.type_name(a.type))
			return nil, nil, expr_error(c, n, "type", {kind = .Invalid, offset = a.offset, message = message}, call.start)
		}
		if p.type != .Set do continue

		if arg_sets == nil do arg_sets = make([]^mdata.Node, len(args), c.scratch)
		param_type := find_type(user, p.type_name)
		if param_type == nil do return nil, nil, fail(c, .Invalid, n, "%s: param %s of type %s has an unknown type %s", id, p.id.text, user.name, p.type_name)
		set := mdata.members(expr.struct_node(a))
		kind := expr.Error_Kind.Invalid
		message: string
		for st in c.type_defs {
			if st.set != set do continue
			if st.td != param_type {
				message = fmt.aprintf("argument %v of %s, %s, must be a %s, not a %s", i + 1, user.name, p.id.text, param_type.name, st.td.name)
			} else if !st.done {
				// its members are not all made yet
				kind = .Unsupported
				message = fmt.aprintf("argument %v of %s, %s, is an instance of a set that encloses this field, which is not supported", i + 1, user.name, p.id.text)
			}
			arg_sets[i] = set
			break
		}
		if arg_sets[i] == nil do message = fmt.aprintf("argument %v of %s, %s, must be a %s", i + 1, user.name, p.id.text, param_type.name)
		if message != "" do return nil, nil, expr_error(c, n, "type", {kind = kind, offset = a.offset, message = message}, call.start)
	}
	return args, arg_sets, true
}
