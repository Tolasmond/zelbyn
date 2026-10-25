// Generates Odin source from a compiled plan: a package with a struct for
// each type of the schema and procedures that read them, as the decoder
// (package reader) reads the plan, which the generated code follows step
// for step, through package data, so that the two decode a schema and an
// input to the same values, or fail with the same error at the same offset
// and path, but for the limits that generated code leaves out
// (doc/usage.md, "Generating code"; doc/arch.md, "Code generation").
package codegen

import dat "../data"
import mdata "../metadata"
import "core:fmt"
import "core:strings"

// How generate writes the package.
Options :: struct {
	package_name: string, // "" for the meta id of the schema's top-level type
	runtime:      string, // the import path of package data, which generated code imports; "" for DEFAULT_RUNTIME
}

// The import path of package data that generated code has unless
// Options.runtime gives another: zelbyn's directory of packages as the
// collection zelbyn (odin build -collection:zelbyn=<repository>/zelbyn).
DEFAULT_RUNTIME :: "zelbyn:data"

// A plan that generate cannot write code for. message is owned
// (context.allocator); free it with destroy_error.
Error :: struct {
	message: string,
}

destroy_error :: proc(err: ^Error) {
	delete(err.message)
	err^ = {}
}

// The source of a package that decodes format's schema, one file, in
// allocator. The package declares a struct for each type of the schema,
// Args for the params of its top-level type, read, which decodes bytes
// into an instance of that type, and write_text, which writes an instance
// as zelbyn's text dump does.
@(require_results)
generate :: proc(format: ^mdata.File_Format, options: Options, allocator := context.allocator) -> (code: string, err: Error) {
	g := Generator{format = format, options = options}
	g.builder = strings.builder_make(context.temp_allocator)
	g.ids = make(map[rawptr]int, context.temp_allocator)
	g.structs = make(map[^mdata.Type_Info]^Struct_Info, context.temp_allocator)
	g.struct_list = make([dynamic]^Struct_Info, context.temp_allocator)
	g.set_ids = make(map[^mdata.Node]int, context.temp_allocator)
	g.set_list = make([dynamic]^mdata.Node, context.temp_allocator)
	g.owners = make(map[^mdata.Node]^Struct_Info, context.temp_allocator)
	g.names = make(map[string]bool, context.temp_allocator)
	g.union_names = make(map[^mdata.Node]string, context.temp_allocator)
	g.constants = make(map[string]string, context.temp_allocator)
	g.untyped = make(map[^mdata.Node]^mdata.Type_Info, context.temp_allocator)
	g.emitted = make(map[string]bool, context.temp_allocator)
	g.work = make([dynamic]Work, context.temp_allocator)
	g.decls = strings.builder_make(context.temp_allocator)
	g.procs = make([dynamic]Proc, context.temp_allocator)
	for name in RESERVED do g.names[name] = true

	if !generate_package(&g) {
		return "", Error{message = strings.clone(g.err, allocator)}
	}
	return strings.clone(strings.to_string(g.builder), allocator), {}
}

// Names generated code declares for itself, which no type takes.
@(private = "file")
RESERVED := [?]string{"Args"}

@(private)
Generator :: struct {
	format:      ^mdata.File_Format,
	options:     Options,
	builder:     strings.Builder, // the whole file
	decls:       strings.Builder, // types and constants
	procs:       [dynamic]Proc,   // the procedures written
	out:         strings.Builder, // the procedure being written
	ids:         map[rawptr]int,  // the number of each node, expression and value instance that has code of its own
	next_id:     int,
	structs:     map[^mdata.Type_Info]^Struct_Info,
	struct_list: [dynamic]^Struct_Info,
	set_ids:     map[^mdata.Node]int, // the number of each set, as Header.set records it
	set_list:    [dynamic]^mdata.Node,
	owners:      map[^mdata.Node]^Struct_Info, // the struct each member of a set (child, parse instance, param) is a field of
	names:       map[string]bool,  // the type names taken
	union_names: map[^mdata.Node]string, // the union of each switch-on field with values of more than one type
	constants:   map[string]string,      // the constant of each Bytes literal, by its bytes
	kept:        map[string]string,      // the procedure kept for each written (merge)
	untyped:     map[^mdata.Node]^mdata.Type_Info, // the type given each set that has none
	emitted:     map[string]bool,  // the procedures and constants written or queued
	work:        [dynamic]Work,    // those still to write
	temps:       int,              // the temporaries of the procedure being written
	uses_utf8:   bool,             // the code uses core:unicode/utf8
	err:         string,
}

// A procedure to write, which code written so far calls.
@(private)
Work :: struct {
	name:  string,
	write: proc(g: ^Generator, w: Work),
	node:  ^mdata.Node,
	expr:  ^mdata.Expr,
	value: ^mdata.Value_Instance,
	info:  ^Struct_Info,
	k:     int,
}

// The struct of a type, and what each of its fields holds.
@(private)
Struct_Info :: struct {
	info:       ^mdata.Type_Info,
	name:       string,
	set:        ^mdata.Node, // the first set of the type, whose members the fields are
	sets:       [dynamic]^mdata.Node,
	fields:     [dynamic]Field,
	have_words: int, // the words of _have, the presence of the fields read once that have no nil
	read_words: int, // the words of _read, whether each parse instance has been read
}

// How a field of a struct holds its values.
@(private)
Storage :: enum {
	Plain,   // a value, present when its bit of _have is set
	Maybe,   // Maybe(elem), for a field read at most once that can have no value
	Pointer, // ^T, nil when there is none
	Union,   // a union, nil when there is none
	Array,   // [dynamic]elem
	Param,   // a param's value, always present
}

@(private)
Field :: struct {
	node:    ^mdata.Node,       // the member: a child, a parse instance or a param; for a bit field, its child
	bit:     int,               // the index of the bit field in node.bits, or -1
	name:    string,            // the Odin name
	display: string,            // the name in the dumps and paths
	elem:    string,            // the Odin type of one value
	storage: Storage,
	have:    int,               // Plain: the bit of _have
	parse:   int,               // a parse instance: its index, also the bit of _read; else -1
}

// Records the first error; always returns false.
@(private)
fail :: proc(g: ^Generator, format: string, args: ..any) -> bool {
	if g.err == "" do g.err = fmt.tprintf(format, ..args)
	return false
}

// The number of p, a node, expression or value instance, given the first
// time it is asked for.
@(private)
id_of :: proc(g: ^Generator, p: rawptr) -> int {
	if id, found := g.ids[p]; found do return id
	g.next_id += 1
	g.ids[p] = g.next_id
	return g.next_id
}

// Queues w, unless a procedure of its name is written or queued, and
// returns a reference to it (ref).
@(private)
need :: proc(g: ^Generator, w: Work) -> string {
	if !g.emitted[w.name] {
		g.emitted[w.name] = true
		append(&g.work, w)
	}
	return ref(w.name)
}

// A reference to the procedure called name, as the code being written calls
// it: marked, so that merge can call the procedure it keeps of those that
// are the same.
@(private)
ref :: proc(name: string) -> string {
	return fmt.tprintf("\x01%s\x02", name)
}

@(private = "file")
generate_package :: proc(g: ^Generator) -> bool {
	root := g.format.root
	visit_set(g, root) or_return
	for p in root.params {
		if p.type != .Set do continue
		visit_set(g, mdata.members(root.args[slot_index(root, p)].variant.(mdata.Root_Arg).set)) or_return
	}
	for s in g.struct_list do layout(g, s) or_return

	write_api(g) or_return
	for s in g.struct_list do write_struct(g, s) or_return
	for set in g.set_list do need(g, {name = set_proc_name(g, set), write = write_set, node = set})
	for s in g.struct_list {
		need(g, {name = dump_proc_name(s), write = write_dump, info = s})
		if len(s.set.parse_instances) > 0 do need(g, {name = parse_dispatch_name(s), write = write_parse_dispatch, info = s})
	}
	for i := 0; i < len(g.work); i += 1 {
		w := g.work[i]
		g.temps = 0
		g.out = strings.builder_make(context.temp_allocator)
		w.write(g, w)
		if g.err != "" do return false
		append(&g.procs, Proc{name = w.name, text = strings.to_string(g.out)})
	}
	procs := merge(g)

	name := g.options.package_name
	if name == "" do name = identifier(root.ref_name)
	runtime := g.options.runtime
	if runtime == "" do runtime = DEFAULT_RUNTIME
	b := &g.builder
	r := struct_of(g, type_of(g, root)).name
	write_comment(b, 0, fmt.tprintf("Package %s decodes the format of the Kaitai Struct schema %s: generated by zelbyn (zelbyn gen) from it, which it should be generated from again rather than edited.\n\nread decodes bytes as an instance of %s, the schema's top-level type, and write_text writes one as zelbyn's text dump does. Each type of the schema is a struct, of the type's fields in order, each followed by its -bits fields, then its parse instances, then its params. A field read at most once holds its value, or when it can have none (an if, a -peek, or a switch-on with neither a default nor a size), is a Maybe, or a pointer or a union that is nil. A repeated field is a [dynamic] array of its values. An integer param is an i128, as Kaitai's expressions range from -2^63 to 2^64 - 1. Value instances are evaluated as the decode needs them, and are not kept. _zr, _have and _read are the decoder's.", name, root.ref_name, r))
	write_line(b, 0, "package %s", name)
	write_line(b, 0, "")
	write_line(b, 0, "import dat %s", quoted(runtime))
	write_line(b, 0, `import "core:io"`)
	write_line(b, 0, `import "core:strings"`)
	if g.uses_utf8 do write_line(b, 0, `import "core:unicode/utf8"`)
	write_line(b, 0, "")
	strings.write_string(b, resolve_refs(g, strings.to_string(g.decls)))
	strings.write_string(b, procs)
	return true
}

// The index of param p among the params of set.
@(private)
slot_index :: proc(set: ^mdata.Node, p: ^mdata.Node) -> int {
	for q, k in set.params do if q == p do return k
	panic("slot_index: not a param of the set")
}

// Records set, a set that is not a switch-on field, and the sets inside it,
// with the struct of its type.
@(private = "file")
visit_set :: proc(g: ^Generator, set: ^mdata.Node) -> bool {
	if set in g.set_ids do return true
	assert(set.type == .Set && set.switch_on == nil)
	g.set_ids[set] = len(g.set_list)
	append(&g.set_list, set)
	s := struct_of(g, type_of(g, set))
	if s.set == nil do s.set = set
	append(&s.sets, set)
	if !same_layout(s.set, set) do return fail(g, "the sets of type %s have different fields", s.info.name)

	for c in set.children {
		g.owners[c] = s
		visit_field(g, c) or_return
	}
	for p in set.parse_instances {
		g.owners[p] = s
		visit_field(g, p) or_return
	}
	for p in set.params do g.owners[p] = s
	if set.order_switch != nil do visit_set(g, set.order_switch.big) or_return
	return true
}

// Records the sets that field, a member of a set, is read as.
@(private = "file")
visit_field :: proc(g: ^Generator, field: ^mdata.Node) -> bool {
	if field.type != .Set do return true
	sw := field.switch_on
	if sw == nil do return visit_set(g, field)
	for c in sw.cases do if c.node.type == .Set do visit_set(g, c.node) or_return
	if sw.default != nil && sw.default.type == .Set do visit_set(g, sw.default) or_return
	return true
}

// Whether two sets of one type have the same members, by name and kind, as
// sets compiled from one type have.
@(private = "file")
same_layout :: proc(a, b: ^mdata.Node) -> bool {
	if len(a.children) != len(b.children) || len(a.parse_instances) != len(b.parse_instances) || len(a.params) != len(b.params) do return false
	for c, i in a.children {
		d := b.children[i]
		if c.ref_name != d.ref_name || c.name != d.name || c.type != d.type || len(c.bits) != len(d.bits) || mdata.is_single(c) != mdata.is_single(d) do return false
	}
	for p, i in a.parse_instances {
		if p.ref_name != b.parse_instances[i].ref_name do return false
	}
	return true
}

// The type set is compiled from: its Type_Info, or for a set of a plan
// made by hand, which has none, a type of its own, named for it.
@(private)
type_of :: proc(g: ^Generator, set: ^mdata.Node) -> ^mdata.Type_Info {
	if set.type_info != nil do return set.type_info
	if t, found := g.untyped[set]; found do return t
	t := new(mdata.Type_Info, context.temp_allocator)
	t.name = set.ref_name
	g.untyped[set] = t
	return t
}

// The struct of type info, named the first time.
@(private)
struct_of :: proc(g: ^Generator, info: ^mdata.Type_Info) -> ^Struct_Info {
	if s, found := g.structs[info]; found do return s
	s := new(Struct_Info, context.temp_allocator)
	s.info = info
	s.sets = make([dynamic]^mdata.Node, context.temp_allocator)
	s.fields = make([dynamic]Field, context.temp_allocator)
	s.name = unique_name(g, type_name(g, info))
	g.structs[info] = s
	append(&g.struct_list, s)
	return s
}

// A name for the struct of info: its path of types, in Ada_Case, without
// the top-level type of the schema compiled but for that type itself, and
// with that of an imported schema.
@(private = "file")
type_name :: proc(g: ^Generator, info: ^mdata.Type_Info) -> string {
	path := make([dynamic]string, context.temp_allocator)
	for t := info; t != nil; t = t.outer {
		if t.outer == nil && t == type_of(g, g.format.root) && t != info do break
		append(&path, ada_case(t.name))
	}
	b := strings.builder_make(context.temp_allocator)
	#reverse for part, i in path {
		if i < len(path) - 1 do strings.write_byte(&b, '_')
		strings.write_string(&b, part)
	}
	return strings.to_string(b)
}

// name, or with a number after it when it is taken.
@(private)
unique_name :: proc(g: ^Generator, name: string) -> string {
	n := name
	for i := 2; g.names[n]; i += 1 do n = fmt.tprintf("%s_%d", name, i)
	g.names[n] = true
	return n
}

// snake_case as Ada_Case: each word capitalized.
@(private = "file")
ada_case :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	start := true
	for c in transmute([]byte)s {
		switch {
		case c == '_':
			if !start do strings.write_byte(&b, '_')
			start = true
		case start && c >= 'a' && c <= 'z':
			strings.write_byte(&b, c - 'a' + 'A')
			start = false
		case:
			strings.write_byte(&b, c)
			start = false
		}
	}
	name := strings.to_string(b)
	if len(name) == 0 || !(name[0] >= 'A' && name[0] <= 'Z') do name = fmt.tprintf("T%s", name)
	return name
}

// The name generated code gives a field, a param or a member of Args whose
// id in the schema is name: the id, or with _ after it when it is one of
// Odin's keywords.
field_name :: proc(name: string) -> string {
	return identifier(name)
}

// name, an id of the schema, or the name of a bit field, as an Odin
// identifier: a character that cannot be in one made _, and with _ after
// it when it is one of Odin's keywords.
@(private)
identifier :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c, i in transmute([]byte)name {
		ok := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && c >= '0' && c <= '9')
		strings.write_byte(&b, ok ? c : '_')
	}
	id := strings.to_string(b)
	if id == "" do id = "_"
	for k in KEYWORDS do if id == k do return fmt.tprintf("%s_", id)
	return id
}

@(private = "file")
KEYWORDS := [?]string {
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer", "distinct",
	"do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix",
	"not_in", "or_break", "or_continue", "or_else", "or_return", "package", "proc", "return", "struct", "switch",
	"transmute", "typeid", "union", "using", "when", "where", "nil", "true", "false",
}

// The fields of s, from its first set: each child, followed by each of its
// bit fields, then each parse instance, then each param.
@(private = "file")
layout :: proc(g: ^Generator, s: ^Struct_Info) -> bool {
	set := s.set
	have := 0
	for c in set.children {
		f := Field{node = c, bit = -1, name = identifier(c.ref_name), display = c.name, parse = -1}
		storage(g, &f, &have) or_return
		append(&s.fields, f)
		for bit, b in c.bits {
			bf := Field{node = c, bit = b, name = identifier(bit.name), display = bit.name, parse = -1}
			bf.elem = scalar_type(bit.type)
			if !mdata.is_single(c) {
				bf.storage = .Array
			} else if can_be_absent(c) {
				bf.storage = .Maybe
			} else {
				bf.storage, bf.have = .Plain, have
				have += 1
			}
			append(&s.fields, bf)
		}
	}
	for p, k in set.parse_instances {
		if len(p.bits) > 0 do return fail(g, "parse instance %s has bit fields", p.name)
		f := Field{node = p, bit = -1, name = identifier(p.ref_name), display = p.name, parse = k}
		storage(g, &f, &have) or_return
		append(&s.fields, f)
	}
	for p in set.params {
		f := Field{node = p, bit = -1, name = identifier(p.ref_name), display = p.name, parse = -1, storage = .Param}
		#partial switch p.type {
		case .Int64:
			f.elem = "i128"
		case .Bool:
			f.elem = "bool"
		case .Blob:
			f.elem = "[]byte"
		case .String:
			f.elem = "string"
		case .Set:
			f.elem = fmt.tprintf("^%s", struct_of(g, type_of(g, p)).name)
		case:
			return fail(g, "param %s has an unknown type", p.name)
		}
		append(&s.fields, f)
	}
	// names made identifiers can meet, and the bit fields' are not ids
	taken := make(map[string]bool, context.temp_allocator)
	for &f in s.fields {
		name := f.name
		for i := 2; taken[name] || name == "_zr" || name == "_have" || name == "_read"; i += 1 do name = fmt.tprintf("%s_%d", f.name, i)
		taken[name] = true
		f.name = name
	}
	s.have_words = (have + 63) / 64
	s.read_words = (len(set.parse_instances) + 63) / 64
	return true
}

// Whether node, a field read at most once, can have no value once it is
// read: with an if, a -peek count, or as a switch-on with neither a default
// nor a length.
@(private)
can_be_absent :: proc(node: ^mdata.Node) -> bool {
	if node.cond != nil do return true
	if _, is_marker := node.count.(mdata.Marker_Count); is_marker do return true
	if sw := node.switch_on; sw != nil && sw.default == nil && node.length == nil do return true
	return false
}

// Sets the element type and storage of f, a child or parse instance.
@(private = "file")
storage :: proc(g: ^Generator, f: ^Field, have: ^int) -> bool {
	node := f.node
	f.elem = elem_type(g, node) or_return
	if !mdata.is_single(node) {
		f.storage = .Array
		return true
	}
	switch {
	case node.type == .Set && node.switch_on == nil:
		f.storage = .Pointer
	case node.switch_on != nil && strings.has_prefix(f.elem, "^"):
		f.storage = .Pointer
	case node.switch_on != nil && is_union(g, node):
		f.storage = .Union
	case can_be_absent(node):
		f.storage = .Maybe
	case:
		f.storage, f.have = .Plain, have^
		have^ += 1
	}
	return true
}

// The Odin type of one value of node, a field.
@(private)
elem_type :: proc(g: ^Generator, node: ^mdata.Node) -> (string, bool) {
	if node.type != .Set do return value_type(node), true
	if node.switch_on == nil do return fmt.tprintf("^%s", struct_of(g, type_of(g, node)).name), true
	variants := switch_variants(g, node)
	if len(variants) == 1 do return variants[0], true
	return union_name(g, node), true
}

// The Odin types of the values of node, a switch-on field, each once, in
// the order of its cases: each case's, then the default's, or without one,
// with a length, the bytes of an element that no case chose.
@(private)
switch_variants :: proc(g: ^Generator, node: ^mdata.Node) -> []string {
	sw := node.switch_on
	variants := make([dynamic]string, context.temp_allocator)
	add :: proc(variants: ^[dynamic]string, t: string) {
		for v in variants do if v == t do return
		append(variants, t)
	}
	case_type :: proc(g: ^Generator, n: ^mdata.Node) -> string {
		if n.type == .Set do return fmt.tprintf("^%s", struct_of(g, type_of(g, n)).name)
		return value_type(n)
	}
	for c in sw.cases do add(&variants, case_type(g, c.node))
	if sw.default != nil {
		add(&variants, case_type(g, sw.default))
	} else if node.length != nil {
		add(&variants, "[]byte")
	}
	return variants[:]
}

// Whether node, a switch-on field, has values of more than one Odin type,
// which a union holds.
@(private)
is_union :: proc(g: ^Generator, node: ^mdata.Node) -> bool {
	return len(switch_variants(g, node)) > 1
}

// The name of the union of the values of node, a switch-on field, declared
// the first time.
@(private = "file")
union_name :: proc(g: ^Generator, node: ^mdata.Node) -> string {
	key := fmt.tprintf("union %d", id_of(g, node))
	owner := g.owners[node]
	name := fmt.tprintf("%s_%s", owner != nil ? owner.name : "T", ada_case(node.ref_name))
	if !g.emitted[key] {
		g.emitted[key] = true
		name = unique_name(g, name)
		g.union_names[node] = name
		fmt.sbprintfln(&g.decls, "// The values of %s, a switch-on field: one of its cases' types.", node.name)
		fmt.sbprintf(&g.decls, "%s :: union {{", name)
		for v, i in switch_variants(g, node) {
			if i > 0 do strings.write_string(&g.decls, ", ")
			strings.write_string(&g.decls, v)
		}
		fmt.sbprintln(&g.decls, "}")
		fmt.sbprintln(&g.decls)
	}
	return g.union_names[node]
}

// The Odin type of the values of node, a field that is not a set.
@(private)
value_type :: proc(node: ^mdata.Node) -> string {
	#partial switch node.type {
	case .String:
		return "string"
	case .Blob:
		return "[]byte"
	case .Bool:
		return "bool"
	case .Bits:
		return scalar_type(mdata.bits_type(int(node.width)))
	}
	return scalar_type(node.type)
}

// The Odin type of an integer or float Data_Type.
@(private)
scalar_type :: proc(t: dat.Data_Type) -> string {
	#partial switch t {
	case .Int8:    return "i8"
	case .UInt8:   return "u8"
	case .Int16:   return "i16"
	case .UInt16:  return "u16"
	case .Int32:   return "i32"
	case .UInt32:  return "u32"
	case .Int64:   return "i64"
	case .UInt64:  return "u64"
	case .Float32: return "f32"
	case .Float64: return "f64"
	case .String:  return "string"
	case .Blob:    return "[]byte"
	case .Bool:    return "bool"
	}
	panic("scalar_type: not a scalar type")
}

// A procedure written, whose references to the others are marked (ref).
@(private)
Proc :: struct {
	name: string,
	text: string,
}

// The procedures written, with each set of them that are the same kept once:
// two are the same when their text is, but for their own names, and the
// procedures they call at each place are the same. Each type is compiled
// once for each field of it (doc/arch.md, "The compiler"), and the code of
// most of those fields is the same. The same are found as a partition is
// refined: by text first, then by the classes of the procedures called,
// until no class splits.
@(private = "file")
merge :: proc(g: ^Generator) -> string {
	n := len(g.procs)
	index := make(map[string]int, n, context.temp_allocator)
	for p, i in g.procs do index[p.name] = i
	calls := make([][]int, n, context.temp_allocator)
	class := make([]int, n, context.temp_allocator)
	{
		classes := make(map[string]int, context.temp_allocator)
		for p, i in g.procs {
			list := make([dynamic]int, context.temp_allocator)
			skeleton := strings.builder_make(context.temp_allocator)
			own := fmt.tprintf("%s :: ", p.name)
			text := p.text
			if at := strings.index(text, own); at >= 0 {
				strings.write_string(&skeleton, text[:at])
				strings.write_string(&skeleton, "\x03 :: ")
				text = text[at + len(own):]
			}
			for {
				start := strings.index_byte(text, 0x01)
				if start < 0 do break
				end := start + strings.index_byte(text[start:], 0x02)
				strings.write_string(&skeleton, text[:start])
				strings.write_string(&skeleton, "\x01\x02")
				callee, found := index[text[start + 1:end]]
				assert(found, "merge: a reference to no procedure written")
				append(&list, callee)
				text = text[end + 1:]
			}
			strings.write_string(&skeleton, text)
			calls[i] = list[:]
			key := strings.to_string(skeleton)
			if c, found := classes[key]; found {
				class[i] = c
			} else {
				class[i] = len(classes)
				classes[key] = class[i]
			}
		}
	}
	count := -1
	for {
		classes := make(map[string]int, context.temp_allocator)
		next := make([]int, n, context.temp_allocator)
		for i in 0 ..< n {
			key := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&key, "%d", class[i])
			for c in calls[i] do fmt.sbprintf(&key, ",%d", class[c])
			k := strings.to_string(key)
			if c, found := classes[k]; found {
				next[i] = c
			} else {
				next[i] = len(classes)
				classes[k] = next[i]
			}
		}
		class = next
		if len(classes) == count do break
		count = len(classes)
	}

	// the first of each class is kept
	kept := make([]int, count, context.temp_allocator)
	for &k in kept do k = -1
	for i in 0 ..< n do if kept[class[i]] < 0 do kept[class[i]] = i
	g.kept = make(map[string]string, n, context.temp_allocator)
	for p, i in g.procs do g.kept[p.name] = g.procs[kept[class[i]]].name
	b := strings.builder_make(context.temp_allocator)
	for p, i in g.procs {
		if kept[class[i]] != i do continue
		strings.write_string(&b, resolve_refs(g, p.text))
	}
	return strings.to_string(b)
}

// text with each reference to a procedure (ref) made the name of the one
// kept of those the same as it (merge).
@(private = "file")
resolve_refs :: proc(g: ^Generator, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	text := text
	for {
		start := strings.index_byte(text, 0x01)
		if start < 0 do break
		end := start + strings.index_byte(text[start:], 0x02)
		strings.write_string(&b, text[:start])
		strings.write_string(&b, g.kept[text[start + 1:end]])
		text = text[end + 1:]
	}
	strings.write_string(&b, text)
	return strings.to_string(b)
}
