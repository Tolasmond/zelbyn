package ksy

import arn "../arena"
import dat "../data"
import expr "../expression"
import "../file"
import mdata "../metadata"
import yml "../yaml"
import "base:intrinsics"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The .ksy front end (decision record §5, §6): a subset of Kaitai Struct,
// compiled into the plan. Anything outside the subset is an error naming
// its key and location; keys starting with - that gnrcrdr does not know are
// ignored, as the official tools ignore them.
//
// Supported:
//   - meta: id, endian, bit-endian, encoding, ks-version (checked against
//     KS_VERSION), imports, and title, application, file-extension, xref,
//     license and tags (ignored); seq, types, instances, enums, doc,
//     doc-ref and to-string (parsed, and otherwise ignored)
//   - meta in a type, with the same keys but imports, whose endian,
//     bit-endian and encoding apply in it and the types declared in it; its
//     endian can be a switch-on, chosen as each instance is read
//   - imported schemas, whose top-level types are used by their meta id,
//     each with its own meta
//   - attributes: id (without one, named _unnamed and their index in seq,
//     as in Kaitai), type, size, size-eos, terminator with consume, include
//     and eos-error, pad-right, contents, if, enum, valid (eq, min, max,
//     any-of, in-enum, expr), repeat (expr, eos, until) with repeat-expr
//     and repeat-until, encoding, doc, doc-ref
//   - types u1-u8, s1-s8, f4, f8 (le/be suffixes or meta endian), b1-b64
//     (le/be suffixes or meta bit-endian), str and byte arrays (no type)
//     with size, size-eos or terminator, strz (in ENCODINGS), user types
//     (with size, size-eos or terminator, read from a substream; also
//     inside themselves, and the schema's top-level type, by its meta id),
//     and switch-on over an integer, a boolean or a string, also with size,
//     size-eos or terminator, whose cases are user types or any of those
//     types
//   - value instances, with if and enum, of integers, floats, booleans,
//     strings, byte arrays, set instances and arrays, over their type, its
//     _io, and through _parent and _root those enclosing it, and parse
//     instances: instances with pos, io (_io or the _io of a set instance)
//     and the keys of an attribute, or without pos when they read nothing
//   - float literals and float fields in expressions, with + - * / and the
//     comparisons, also with integers
//   - casts, .as<t>, to an integer type and, of a switch-on field, to the
//     user type of a case, and array literals, [a, b]
//   - params of integer types, bool, bytes, str and user types, in types
//     and at the top level of an imported schema, given as t(a, b)
//   - enums, whose values are names or mappings of id, doc and doc-ref
//     (enum constants in expressions)
//   - the extensions -orig-id, -peek, -while-peek, -until-peek and -bits
//
// Not supported yet (Unsupported): other encodings, instances without pos or
// value that read bytes, params of other types (struct, io, any) and on the
// top-level type of the schema compiled, % of a float, array literals of
// arrays, valid on a float, min and max on a type other than an integer, an
// endian that is a switch-on on the top-level type or in a type that
// contains itself, a bit-endian that is a switch-on, imports in a type, and
// in a type that contains itself, the members of the sets enclosing it,
// other than through the schema's _root, and an instance that refers to
// itself through a field of its type.

Error_Kind :: enum {
	None,
	Read_Failed, // the file could not be read; os_error says why
	Syntax,      // not valid YAML, or an expression that does not parse
	Unsupported, // valid YAML or Kaitai outside the supported subset
	Invalid,     // not a valid schema: an unknown key or type, a bad value, a duplicate key or id
}

Error :: struct {
	kind:         Error_Kind,
	line, column: int,      // 1-based; 0 for Read_Failed
	message:      string,   // owned (context.allocator); free with destroy_error
	path:         string,   // the file the error is in: the schema, or one it imports; "" for source compiled without a path. Owned, as message is
	os_error:     os.Error, // Read_Failed only
}

destroy_error :: proc(err: ^Error) {
	delete(err.message)
	delete(err.path)
	err^ = {}
}

// Reads the .ksy file at path and compiles it into file_format, which must
// be zero or destroyed. A schema it imports is found relative to the
// directory of the schema that imports it, or for an absolute import
// (/a/b), in the first of import_paths that has it. On error file_format
// may be partly filled; destroy it either way.
@(require_results)
read_file_format :: proc(path: string, file_format: ^mdata.File_Format, import_paths: []string = nil) -> Error {
	data, err := file.read_entire_file(path, context.allocator)
	if err != nil do return Error{kind = .Read_Failed, path = strings.clone(path), os_error = err}
	defer delete(data)
	return compile(string(data), file_format, path, import_paths)
}

// Compiles the .ksy text src into file_format, as read_file_format does.
// path is the file src was read from, for errors and relative imports; when
// it is "", relative imports are found in the current directory.
@(require_results)
compile :: proc(src: string, file_format: ^mdata.File_Format, path := "", import_paths: []string = nil) -> Error {
	// what only compiling needs goes in the plan's arena too: a second arena
	// would cost a mapping, and its first pages, in every compile
	plan := arn.arena_allocator(&file_format.arena)
	c := Compiler{allocator = plan, scratch = plan, import_paths = import_paths}
	c.instances = make(map[^mdata.Value_Instance]^Instance_Source, c.scratch)
	c.parse_instances = make(map[^mdata.Node]^Parse_Source, c.scratch)
	c.type_defs = make([dynamic]Set_Type, c.scratch)
	c.deferred = make([dynamic]Deferred, c.scratch)
	c.imported = make(map[string]^Type_Def, c.scratch)

	c.schema = new_schema(&c, path)
	if root, ok := parse_schema(&c, src); ok {
		compile_schema(&c, root, file_format)
	}
	return c.err
}

@(private = "file")
Compiler :: struct {
	allocator:       mem.Allocator, // the File_Format's arena
	scratch:         mem.Allocator, // for what only compiling needs: the YAML documents, types, maps; the File_Format's arena too, freed with it, so the plan uses the documents' strings as they are
	schema:          ^Schema,              // the one whose types are being compiled
	imported:        map[string]^Type_Def, // the top-level type of each schema read from a file, by its cleaned path; in scratch
	import_paths:    []string,
	root:            ^mdata.Node,          // the root of the plan
	instances:       map[^mdata.Value_Instance]^Instance_Source, // in scratch
	parse_instances: map[^mdata.Node]^Parse_Source,              // in scratch
	type_defs:       [dynamic]Set_Type,                          // the type of each set compiled, for sizes; in scratch
	order:           Maybe(endian.Byte_Order),                   // the byte order of the set of a type whose endian is a switch-on being compiled (compile_type), which the types declared in it take
	deferred:        [dynamic]Deferred,                          // the instances that nothing referred to by the end of their set, compiled once every set is; in scratch
	err:             Error,
}

// A value instance or a parse instance of set whose compile is put off
// until every set is compiled (Compiler.deferred); the other is nil.
@(private = "file")
Deferred :: struct {
	set:   ^mdata.Node,
	value: ^mdata.Value_Instance,
	parse: ^mdata.Node,
}

// A set compiled, and its type. Sizes are rare, so the sets are searched
// rather than hashed, which would cost every compile more. reused_by holds
// the fields of its type inside it (Node.recursive), which are given its
// members once it is compiled; escape is then an error: the first
// expression in it, or in the sets inside it, that refers to an instance
// enclosing it (note_escapes), with what it is.
@(private = "file")
Set_Type :: struct {
	set:           ^mdata.Node,
	td:            ^Type_Def,
	done:          bool,                 // its attributes and instances are compiled, but for value instances put off
	reused_by:     [dynamic]^mdata.Node, // in scratch; nil until one
	escape:        ^yml.Node,
	escape_what:   string,
	escape_schema: ^Schema, // the schema escape is in
}

// A .ksy file: the schema being compiled, or one it imports.
@(private = "file")
Schema :: struct {
	path:    string,      // the file it was read from; "" for source compiled without one
	imports: []^Type_Def, // the top-level type of each schema in meta imports, in order
}

@(private = "file")
new_schema :: proc(c: ^Compiler, path: string) -> ^Schema {
	s := new(Schema, c.scratch)
	s.path = path
	return s
}

// The keys of meta that apply to the attributes of a type: those of the
// schema's meta at the top level, and in a type, those of its own meta
// over those of the type it is declared in, as in Kaitai.
@(private = "file")
Meta :: struct {
	bit_endian:    endian.Byte_Order,        // bit-endian; .Big when absent, as in Kaitai
	endian:        Maybe(endian.Byte_Order), // endian
	endian_switch: ^yml.Node,                // endian when it is a switch-on, chosen as each instance of the type that declares it is read; nil otherwise
	endian_owner:  string,                   // the type that declares endian_switch
	encoding:      Maybe(mdata.Encoding),    // encoding
}

// Parses src, the text of c.schema, in scratch, and returns the root of its
// document.
@(private = "file")
parse_schema :: proc(c: ^Compiler, src: string) -> (root: ^yml.Node, ok: bool) {
	yerr: yml.Error
	root, yerr = yml.parse_into(src, c.scratch)
	defer yml.destroy_error(&yerr)
	kind: Error_Kind
	switch yerr.kind {
	case .None:
		if root == nil do return nil, fail(c, .Invalid, nil, "the schema is empty")
		return root, true
	case .Syntax:
		kind = .Syntax
	case .Unsupported:
		kind = .Unsupported
	case .Duplicate_Key:
		kind = .Invalid
	}
	if c.err.kind == .None {
		fail(c, kind, nil, "%s", yerr.message)
		c.err.line, c.err.column = yerr.line, yerr.column
	}
	return nil, false
}

// Where a value instance of a set comes from, to compile it when an
// expression first refers to it. Each is its own allocation, since
// compiling one can add others to the map.
@(private = "file")
Instance_Source :: struct {
	spec:      ^yml.Node, // its mapping in instances, which has a value key
	td:        ^Type_Def,
	scope:     expr.Scope, // that of the set's fields
	compiling: bool,
}

// Where a parse instance of a set comes from, to compile it when an
// expression first refers to it; as for Instance_Source.
@(private = "file")
Parse_Source :: struct {
	entry:     yml.Entry, // its key and spec in instances
	td:        ^Type_Def,
	scope:     expr.Scope, // that of the set's fields
	order:     Maybe(endian.Byte_Order), // Compiler.order for the set
	compiling: bool,
}

// A type: the top level of a schema, or an entry of types. Its attributes
// are compiled for each field of the type, so that names resolve in the
// field's scope.
@(private = "file")
Type_Def :: struct {
	name:        string,    // the meta id at the top level
	spec:        ^yml.Node,
	schema:      ^Schema,   // the schema it is in
	parent:      ^Type_Def, // the type it is declared in; nil at the top level
	meta:        Meta,
	types:       []^Type_Def,
	instances:   []yml.Entry, // the entries of instances, each checked
	enums:       []expr.Enum,
	params:      []Param_Def,
	compiling:   ^mdata.Node, // the set its attributes are being compiled into; nil when they are not
	sizing:      bool, // its size is being found (type_bits)
}

// A param of a type, checked.
@(private = "file")
Param_Def :: struct {
	id:        ^yml.Node, // its id's node
	type:      dat.Data_Type, // of its value: Int64 for any integer type, Bool, Blob, String, or Set for a user type
	type_name: string, // a Set: the user type, looked up from the type the param is of
}

// Records the first error, at n (or nowhere when n is nil); always returns
// false.
@(private = "file")
fail :: proc(c: ^Compiler, kind: Error_Kind, n: ^yml.Node, format: string, args: ..any) -> bool {
	if c.err.kind == .None {
		c.err = Error{kind = kind, message = fmt.aprintf(format, ..args)}
		if n != nil do c.err.line, c.err.column = n.line, n.column
		if c.schema != nil && c.schema.path != "" do c.err.path = strings.clone(c.schema.path)
	}
	return false
}

// The value of key in the mapping m; nil when absent.
@(private = "file")
get :: proc(m: ^yml.Node, key: string) -> ^yml.Node {
	for e in m.entries {
		if e.key.text == key do return e.value
	}
	return nil
}

@(private = "file")
get_key :: proc(m: ^yml.Node, key: string) -> ^yml.Node {
	for e in m.entries {
		if e.key.text == key do return e.key
	}
	return nil
}

// The first key of the mapping m that is one of keys; nil when none is.
@(private = "file")
first_key :: proc(m: ^yml.Node, keys: []string) -> ^yml.Node {
	for e in m.entries {
		if slice.contains(keys, e.key.text) do return e.key
	}
	return nil
}

@(private = "file")
expect_map :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> bool {
	if n.kind != .Map do return fail(c, .Invalid, n, "%s must be a mapping", what)
	return true
}

@(private = "file")
expect_scalar :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (text: string, ok: bool) {
	if n.kind != .Scalar do return "", fail(c, .Invalid, n, "%s must be a scalar", what)
	return n.text, true
}

// The keys a mapping may have. Kaitai keys outside the subset are
// Unsupported, other keys Invalid. Keys starting with - are allowed when in
// extensions; any other - key is ignored unless gnrcrdr uses it elsewhere.
@(private = "file")
Keys :: struct {
	what:        string, // for errors: "meta", or a format of name, "attribute %s", formatted only for an error
	name:        string,
	allowed:     []string,
	unsupported: []string, // Kaitai keys outside the subset
	extensions:  []string,
}

@(private = "file")
EXTENSIONS :: []string{"-orig-id", "-peek", "-while-peek", "-until-peek", "-bits"}

@(private = "file")
check_keys :: proc(c: ^Compiler, m: ^yml.Node, keys: Keys) -> bool {
	for e in m.entries {
		k := e.key.text
		switch {
		case slice.contains(keys.allowed, k), slice.contains(keys.extensions, k):
		case slice.contains(keys.unsupported, k):
			return fail(c, .Unsupported, e.key, "%s: %s is not supported", keys_what(keys), k)
		case slice.contains(EXTENSIONS, k):
			return fail(c, .Invalid, e.key, "%s: the extension %s does not apply here", keys_what(keys), k)
		case strings.has_prefix(k, "-"):
			// an extension gnrcrdr does not know
		case:
			return fail(c, .Invalid, e.key, "%s: unknown key %q", keys_what(keys), k)
		}
	}
	return true
}

@(private = "file")
keys_what :: proc(keys: Keys) -> string {
	return strings.contains_rune(keys.what, '%') ? fmt.tprintf(keys.what, keys.name) : keys.what
}

@(private = "file")
META_KEYS :: Keys {
	what        = "meta",
	allowed     = {"id", "endian", "bit-endian", "encoding", "ks-version", "imports", "title", "application", "file-extension", "xref", "license", "tags"},
	unsupported = {"ks-debug", "ks-opaque-types"},
	extensions  = {"-orig-id"},
}

@(private = "file")
TYPE_ALLOWED :: []string{"meta", "seq", "types", "instances", "enums", "doc", "doc-ref", "params", "to-string"}

@(private = "file")
TOP_ALLOWED :: []string{"meta", "seq", "types", "instances", "enums", "doc", "doc-ref", "params", "to-string"}

@(private = "file")
ATTR_ALLOWED :: []string{"id", "type", "size", "contents", "if", "enum", "valid", "repeat", "repeat-expr", "repeat-until", "encoding", "doc", "doc-ref", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right"}

@(private = "file")
ATTR_UNSUPPORTED :: []string{"process", "io", "pos", "value", "parent"}

// The keys of an attribute that say where the bytes of each element end.
@(private = "file")
BYTES_KEYS :: []string{"size", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right"}

// The keys of a value instance, and of a parse instance: those of an
// attribute, with pos instead of id.
@(private = "file")
VALUE_INSTANCE_KEYS :: Keys {
	allowed    = {"value", "if", "enum", "doc", "doc-ref"},
	extensions = {"-orig-id"},
}

@(private = "file")
PARSE_INSTANCE_KEYS :: Keys {
	allowed     = {"pos", "io", "type", "size", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right", "contents", "if", "enum", "valid", "repeat", "repeat-expr", "repeat-until", "encoding", "doc", "doc-ref"},
	unsupported = {"process", "parent"},
	extensions  = {"-orig-id"},
}

@(private = "file")
PARAM_KEYS :: Keys {
	what    = "a param",
	allowed = {"id", "type", "enum", "doc", "doc-ref"},
}

@(private = "file")
SWITCH_KEYS :: Keys {
	what    = "switch-on",
	allowed = {"switch-on", "cases"},
}

@(private = "file")
is_identifier :: proc(s: string) -> bool {
	if len(s) == 0 || s[0] < 'a' || s[0] > 'z' do return false
	for ch in transmute([]byte)s {
		if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_') do return false
	}
	return true
}

@(private = "file")
identifier :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (id: string, ok: bool) {
	id = expect_scalar(c, n, what) or_return
	if !is_identifier(id) do return "", fail(c, .Invalid, n, "%s %q is not an identifier (lowercase letters, digits and _, starting with a letter)", what, id)
	return id, true
}

@(private = "file")
compile_schema :: proc(c: ^Compiler, root: ^yml.Node, ff: ^mdata.File_Format) -> bool {
	top := load_schema(c, root) or_return
	if len(top.params) > 0 do return fail(c, .Unsupported, get_key(root, "params"), "params on the top-level type are not supported, except in an imported schema")

	name := display_name(c, get(root, "meta"), top.name) or_return
	node := new_node(c, name, top.name)
	node.type = .Set
	node.count = mdata.Fixed_Count{1}

	ff.name = node.name
	ff.root = node
	c.root = node
	// nothing is read before the root that its order could depend on
	if declares_endian_switch(top) do return fail(c, .Unsupported, top.meta.endian_switch, "endian: switch-on is not supported on the top-level type of the schema compiled, except in an imported schema")
	compile_fields(c, top, node, {node}) or_return

	// the instances that nothing referred to, now that every field they
	// can refer to is compiled, as in Kaitai, where any instance can refer
	// to any field; compiling them can put off others
	for i := 0; i < len(c.deferred); i += 1 {
		item := c.deferred[i]
		pending := item.value != nil ? item.value.expr == nil : item.parse.pos == nil
		if pending do compile_deferred(c, item) or_return
	}

	// a reused set's expressions are all compiled; its fields inside it
	// are read as it is
	for st in c.type_defs {
		if st.set.keeps_stream do for field in st.reused_by do field.keeps_stream = true
		if len(st.reused_by) > 0 && st.escape != nil {
			c.schema = st.escape_schema
			return fail(c, .Unsupported, st.escape, "%s: type %s contains itself, so neither it nor the types in it can refer to the members of the sets enclosing it, other than through the _root of the schema decoded, or to an imported schema's _root", st.escape_what, st.td.name)
		}
	}
	return true
}

// Checks the top level and meta of c.schema, whose document's root is root,
// reads the schemas it imports, and builds its types. Returns its top-level
// type.
@(private = "file")
load_schema :: proc(c: ^Compiler, root: ^yml.Node) -> (top: ^Type_Def, ok: bool) {
	expect_map(c, root, "a schema") or_return
	check_keys(c, root, {what = "the top level", allowed = TOP_ALLOWED}) or_return

	meta := get(root, "meta")
	if meta == nil do return nil, fail(c, .Invalid, root, "the schema has no meta")
	expect_map(c, meta, "meta") or_return
	check_keys(c, meta, META_KEYS) or_return

	id_node := get(meta, "id")
	if id_node == nil do return nil, fail(c, .Invalid, meta, "meta has no id")
	id := identifier(c, id_node, "meta id") or_return

	m := meta_of(c, meta, {bit_endian = .Big}) or_return
	top = build_type(c, id, root, nil, m) or_return
	// registered before its imports, which may import it in turn
	if c.schema.path != "" {
		path, _ := filepath.clean(c.schema.path, c.scratch)
		c.imported[path] = top
	}
	if n := get(meta, "imports"); n != nil {
		c.schema.imports = load_imports(c, n) or_return
	}
	return top, true
}

// The Meta that meta, the meta of a schema or of a type, gives over
// inherited, and checks its ks-version.
@(private = "file")
meta_of :: proc(c: ^Compiler, meta: ^yml.Node, inherited: Meta) -> (m: Meta, ok: bool) {
	m = inherited
	if n := get(meta, "endian"); n != nil {
		if n.kind == .Map {
			check_endian_switch(c, n) or_return
			m.endian, m.endian_switch = nil, n
		} else {
			m.endian = byte_order(c, n, "endian") or_return
			m.endian_switch = nil
		}
	}
	if n := get(meta, "bit-endian"); n != nil {
		if n.kind == .Map do return m, fail(c, .Unsupported, n, "bit-endian: switch-on is not supported")
		m.bit_endian = byte_order(c, n, "bit-endian") or_return
	}
	if n := get(meta, "encoding"); n != nil {
		m.encoding = encoding(c, n) or_return
	}
	if n := get(meta, "ks-version"); n != nil {
		check_ks_version(c, n) or_return
	}
	return m, true
}

// meta imports: each a schema file named without its .ksy, relative to the
// directory of the schema that imports it, or when it starts with /, to the
// first of the import paths that has it. A schema already read is not read
// again. The imported schemas' top-level types are found by their meta id.
@(private = "file")
load_imports :: proc(c: ^Compiler, n: ^yml.Node) -> (imports: []^Type_Def, ok: bool) {
	if n.kind != .Seq do return nil, fail(c, .Invalid, n, "imports must be a sequence")
	imports = make([]^Type_Def, len(n.items), c.scratch)
	for item, i in n.items {
		name := expect_scalar(c, item, "an import") or_return
		path := import_path(c, item, name) or_return
		top, seen := c.imported[path]
		if !seen do top = load_import(c, item, path) or_return
		for prev in imports[:i] {
			if prev != top && prev.name == top.name do return nil, fail(c, .Invalid, item, "imports: two schemas have the id %s", top.name)
		}
		imports[i] = top
	}
	return imports, true
}

// The cleaned path of the schema imported as name by item.
@(private = "file")
import_path :: proc(c: ^Compiler, item: ^yml.Node, name: string) -> (path: string, ok: bool) {
	if name == "" do return "", fail(c, .Invalid, item, "imports: an import is empty")
	file := strings.concatenate({name, ".ksy"}, c.scratch)
	if file[0] != '/' {
		path, _ = filepath.join({filepath.dir(c.schema.path), file}, c.scratch)
		return path, true
	}
	for dir in c.import_paths {
		path, _ = filepath.join({dir, file[1:]}, c.scratch)
		if os.is_file(path) do return path, true
	}
	return "", fail(c, .Invalid, item, "imports: %s is in none of the import paths", name)
}

// Reads the schema at path, imported by item, and loads it as
// load_schema does.
@(private = "file")
load_import :: proc(c: ^Compiler, item: ^yml.Node, path: string) -> (top: ^Type_Def, ok: bool) {
	data, err := file.read_entire_file(path, c.scratch)
	if err != nil do return nil, fail(c, .Invalid, item, "imports: cannot read %s: %v", path, err)

	importer := c.schema
	defer c.schema = importer
	c.schema = new_schema(c, path)
	root := parse_schema(c, string(data)) or_return
	return load_schema(c, root)
}

@(private = "file")
byte_order :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (order: endian.Byte_Order, ok: bool) {
	text := expect_scalar(c, n, what) or_return
	switch text {
	case "le":
		return .Little, true
	case "be":
		return .Big, true
	}
	return .Little, fail(c, .Invalid, n, "%s must be le or be, not %q", what, text)
}

// Checks n, an endian that is a switch-on: its keys, and that each case is
// le or be. The expressions are compiled with the type (compile_type).
@(private = "file")
check_endian_switch :: proc(c: ^Compiler, n: ^yml.Node) -> bool {
	check_keys(c, n, {what = "endian", allowed = {"switch-on", "cases"}}) or_return
	if get(n, "switch-on") == nil do return fail(c, .Invalid, n, "endian: a mapping needs switch-on")
	cases := get(n, "cases")
	if cases == nil do return fail(c, .Invalid, n, "endian: switch-on needs cases")
	expect_map(c, cases, "cases") or_return
	for e in cases.entries do byte_order(c, e.value, "endian") or_return
	return true
}

// An encoding the decoder supports: its canonical name and its aliases,
// as the official compiler lists them (its EncodingList), and how its
// strings are decoded.
@(private = "file")
Encoding_Name :: struct {
	names:    []string, // the canonical name first
	encoding: mdata.Encoding,
}

@(private = "file")
ENCODINGS :: [?]Encoding_Name {
	{{"ASCII", "US-ASCII", "US_ASCII", "IBM367", "cp367", "csASCII", "iso-ir-6"}, .None},
	{{"UTF-8", "UTF8", "UTF_8", "ISO-10646/UTF-8", "ISO-10646/UTF8", "cp65001", "csUTF8", "unicode-1-1-utf-8", "unicode-2-0-utf-8"}, .None},
	{{"UTF-16BE", "UTF16BE", "UTF16-BE", "UTF-16-BE", "UTF_16BE", "UTF16_BE", "UTF_16_BE", "csUTF16BE"}, .UTF_16BE},
	{{"UTF-16LE", "UTF16LE", "UTF16-LE", "UTF-16-LE", "UTF_16LE", "UTF16_LE", "UTF_16_LE", "csUTF16LE"}, .UTF_16LE},
	{{"UTF-32BE", "UTF32BE", "UTF32-BE", "UTF-32-BE", "UTF_32BE", "UTF32_BE", "UTF_32_BE", "csUTF32BE"}, .UTF_32BE},
	{{"UTF-32LE", "UTF32LE", "UTF32-LE", "UTF-32-LE", "UTF_32LE", "UTF32_LE", "UTF_32_LE", "csUTF32LE"}, .UTF_32LE},
	{{"ISO-8859-1", "ISO8859-1", "ISO_8859-1", "ISO88591", "ISO_8859_1", "ISO8859_1", "8859_1", "8859-1", "88591", "latin1", "latin-1", "latin_1", "L1", "csISOLatin1", "iso-ir-100", "IBM819", "cp819", "windows-28591"}, .ISO_8859_1},
	{{"windows-1251", "cp1251", "cswindows1251"}, .Windows_1251},
	{{"windows-1252", "cp1252", "cswindows1252"}, .Windows_1252},
	{{"IBM437", "cp437", "437", "csPC8CodePage437"}, .IBM437},
}

// The encoding n names, by any of its names, in any case, as the official
// compiler finds it. ASCII and UTF-8 strings are kept as their bytes, and
// the others decoded into UTF-8 when they are read.
@(private = "file")
encoding :: proc(c: ^Compiler, n: ^yml.Node) -> (e: mdata.Encoding, ok: bool) {
	name := expect_scalar(c, n, "encoding") or_return
	for known in ENCODINGS {
		for alias in known.names {
			if strings.equal_fold(alias, name) do return known.encoding, true
		}
	}
	return .None, fail(c, .Unsupported, n, "encoding %q is not supported; only ASCII, UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ISO-8859-1, windows-1251, windows-1252 and IBM437 are", name)
}

// The Kaitai Struct version gnrcrdr follows: that of the official compiler
// tools/kaitai_compare checks it against.
@(private = "file")
KS_VERSION :: [3]int{0, 11, 0}

// ks-version is the oldest Kaitai compiler a schema needs, as one to three
// numbers separated by dots (0.9, 0.10.1). A schema that needs a newer one
// than KS_VERSION is Unsupported, as the official compiler rejects it.
@(private = "file")
check_ks_version :: proc(c: ^Compiler, n: ^yml.Node) -> bool {
	text := expect_scalar(c, n, "ks-version") or_return
	version: [3]int
	count, digits := 1, 0
	for ch in transmute([]byte)text {
		switch {
		case ch == '.' && digits > 0 && count < len(version):
			count += 1
			digits = 0
		// a number past max(int) is not a version, as in Kaitai
		case ch >= '0' && ch <= '9' && version[count - 1] <= (max(int) - 9) / 10:
			version[count - 1] = version[count - 1] * 10 + int(ch - '0')
			digits += 1
		case:
			return fail(c, .Invalid, n, "ks-version %q is not a version", text)
		}
	}
	if digits == 0 do return fail(c, .Invalid, n, "ks-version %q is not a version", text)

	follows := KS_VERSION
	for v, i in version {
		if v < follows[i] do break
		if v > follows[i] do return fail(c, .Unsupported, n, "ks-version %s is newer than %v.%v, the Kaitai version gnrcrdr follows", text, follows[0], follows[1])
	}
	return true
}

// -orig-id when the mapping has one, else id.
@(private = "file")
display_name :: proc(c: ^Compiler, m: ^yml.Node, id: string) -> (name: string, ok: bool) {
	n := get(m, "-orig-id")
	if n == nil do return id, true
	name = expect_scalar(c, n, "-orig-id") or_return
	if name == "" do return "", fail(c, .Invalid, n, "-orig-id is empty")
	return name, true
}

@(private = "file")
new_node :: proc(c: ^Compiler, name, ref_name: string) -> ^mdata.Node {
	node := new(mdata.Node, c.allocator)
	node^ = {name = name, ref_name = ref_name}
	return node
}

// Builds the type spec (the top level when parent is nil, whose meta is
// top_meta) and the types declared in it, and checks the keys of every
// attribute, so that a key outside the subset is rejected even in a type
// nothing uses.
@(private = "file")
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
// which nothing gnrcrdr writes shows: it is parsed, so that a schema that
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
		for v, j in e.value.entries {
			n, is_int := parse_int(v.key.text)
			if !is_int || v.key.style != .Plain do return nil, fail(c, .Invalid, v.key, "enum %s: %q is not an integer", name, v.key.text)
			if n > i128(max(int)) || n < i128(min(int)) do return nil, fail(c, .Unsupported, v.key, "enum %s: %v does not fit in a 64-bit signed integer", name, v.key.text)
			value_name := enum_value_name(c, name, v.value) or_return

			for prev in values[:j] {
				at := v.value.kind == .Map ? get(v.value, "id") : v.value
				if prev.name == value_name do return nil, fail(c, .Invalid, at, "enum %s: %s appears twice", name, value_name)
				if prev.value == int(n) do return nil, fail(c, .Invalid, v.key, "enum %s: value %v appears twice", name, v.key.text)
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
			} else if is_primitive || strings.contains(type_name, "::") || strings.contains(type_name, "[") {
				return nil, fail(c, .Unsupported, type_node, "param %s: type %s is not supported; only integer types, bool, bytes, str and user types are", name, type_name)
			} else {
				type, user = .Set, type_name
			}
		}

		if e := get(item, "enum"); e != nil {
			if type != .Int64 do return nil, fail(c, .Invalid, get_key(item, "enum"), "param %s: enum applies only to integer types", name)
			check_enum(c, e, name, visible_enums(c, td)) or_return
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

// The value of an enum key, of id, which must name one of enums.
@(private = "file")
check_enum :: proc(c: ^Compiler, n: ^yml.Node, id: string, enums: []expr.Enum) -> bool {
	enum_name := expect_scalar(c, n, "enum") or_return
	if strings.contains(enum_name, "::") do return fail(c, .Unsupported, n, "%s: an enum of another type (%s) is not supported", id, enum_name)
	for e in enums {
		if e.name == enum_name do return true
	}
	return fail(c, .Invalid, n, "%s: no enum %s", id, enum_name)
}

// The type called name, looked up from td outward, then as the top-level
// type of td's schema, by its meta id, and among the schemas that td's
// schema imports.
@(private = "file")
find_type :: proc(td: ^Type_Def, name: string) -> ^Type_Def {
	t := td
	for {
		for sub in t.types {
			if sub.name == name do return sub
		}
		if t.parent == nil do break
		t = t.parent
	}
	if t.name == name do return t
	for top in td.schema.imports {
		if top.name == name do return top
	}
	return nil
}

// The enums visible in td, innermost first.
@(private = "file")
visible_enums :: proc(c: ^Compiler, td: ^Type_Def) -> []expr.Enum {
	list := make([dynamic]expr.Enum, c.scratch)
	for t := td; t != nil; t = t.parent {
		append(&list, ..t.enums)
	}
	return list[:]
}

// Compiles the attributes and instances of td as those of set, an instance
// of td. chain is the scope: the sets enclosing set, outermost first, then
// set. Each attribute's expressions can refer to the attributes before it,
// and to any instance whose expressions refer only to those. When set is
// inside a set of td being compiled, a type that contains itself, set is
// read as that set (Node.recursive), whose expressions must then not refer
// to the instances enclosing it. Once that set is compiled, set gets its
// members, so that the decoder and the dumps need not look for them.
@(private = "file")
compile_fields :: proc(c: ^Compiler, td: ^Type_Def, set: ^mdata.Node, chain: []^mdata.Node, arg_sets: []^mdata.Node = nil) -> bool {
	if td.compiling != nil {
		set.recursive = td.compiling
		st := set_type(c, td.compiling)
		if st.reused_by == nil do st.reused_by = make([dynamic]^mdata.Node, c.scratch)
		append(&st.reused_by, set)
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
	append(&c.type_defs, Set_Type{set = set, td = td})

	ids := make([dynamic]^yml.Node, c.scratch) // the id nodes of the attributes, bit fields and instances

	// each instance is compiled when an expression first refers to it, or
	// else once every set is (compile_schema)
	scope := scope_of(c, td, chain)
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
			params[i].count = mdata.Fixed_Count{1}
			params[i].is_param = true
			// its value is the instance its argument gives, of a set of its
			// type compiled elsewhere, whose members it has
			if p.type == .Set do copy_members(params[i], mdata.members(arg_sets[i]))
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

// Compiles item, an instance put off. The types of the sets enclosing it
// are marked as being compiled again while it is, so that its type, or a
// parse instance or a type it compiles on demand, finds that a type inside
// one of them contains itself, as when it is compiled with its set.
@(private = "file")
compile_deferred :: proc(c: ^Compiler, item: Deferred) -> bool {
	marked := make([dynamic]^Type_Def, c.scratch)
	defer for td in marked do td.compiling = nil
	types := item.value != nil ? c.instances[item.value].scope.types : c.parse_instances[item.parse].scope.types
	for set in types {
		st := set_type(c, set)
		if st.td.compiling != nil do continue
		st.td.compiling = set
		append(&marked, st.td)
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
// enclosing, through _parent, or to the _root of an imported schema, which
// up reaches too. In a set that is reused (Node.recursive), such an
// instance is of another set for the set's other instances, and for the
// instances of the set that reuses it, which are inside it, that root is
// the nearest instance of it, not the outermost. The _io of an enclosing
// instance is found from the instance the decoder reaches, and so is right
// in each of them.
@(private = "file")
note_escapes :: proc(c: ^Compiler, n: ^yml.Node, what: string, e: ^mdata.Expr, scope: expr.Scope) {
	if e == nil do return
	switch x in e.variant {
	case mdata.Instance:
		if x.root || (x.up == 0 && !x.imported_root) do return
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
	case mdata.Int_Literal, mdata.Float_Literal, mdata.Bool_Literal, mdata.String_Literal, mdata.Bytes_Literal, mdata.Io_Pos, mdata.Io_Size, mdata.Io_Eof, mdata.Repeat_Index, mdata.Repeat_Element:
	case mdata.Name, mdata.Member, mdata.Enum_Constant, mdata.Size_Of, mdata.Cast:
		panic("note_escapes: unresolved expression")
	}
}

// The scope of expressions in td, whose instance is the last of chain.
@(private = "file")
scope_of :: proc(c: ^Compiler, td: ^Type_Def, chain: []^mdata.Node) -> expr.Scope {
	return {
		types                  = chain,
		own_root               = chain[0] != c.root,
		enums                  = visible_enums(c, td),
		compile_instance       = compile_instance_callback,
		compile_parse_instance = compile_parse_instance_callback,
		size_of                = size_of_callback,
		data                   = c,
	}
}

@(private = "file")
compile_instance_callback :: proc(data: rawptr, set: ^mdata.Node, inst: ^mdata.Value_Instance) -> bool {
	return compile_instance((^Compiler)(data), set, inst)
}

@(private = "file")
compile_parse_instance_callback :: proc(data: rawptr, set: ^mdata.Node, inst: ^mdata.Node) -> bool {
	return compile_parse_instance((^Compiler)(data), set, inst)
}

// The size in bits of the attribute or parse instance name of set, or of
// set's type, or with of_type, of the type name (expr.Scope.size_of).
@(private = "file")
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
		if strings.contains(name, "::") do return 0, size_error(.Unsupported, "a type of another type (%s) is not supported", name)
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
	if size := get(attr, "size"); size != nil {
		n, ok := constant_int(c, size)
		if !ok || n < 0 || n > max(int) / 8 do return 0, id
		element = n * 8
	} else if contents := get(attr, "contents"); contents != nil {
		element = contents_length(contents) * 8
	} else {
		if type_node == nil do return 0, id
		name := strings.trim_space(type_node.text)
		if open := strings.index_byte(name, '('); open >= 0 do name = strings.trim_space(name[:open])
		if prim, _, is_primitive := primitive(name); is_primitive {
			sizes := TYPE_SIZE
			element = sizes[prim] * 8
		} else if width, _, is_bits := bit_type(name); is_bits {
			element = width
		} else {
			user := find_type(td, name)
			// a type that contains itself has no fixed size
			if user == nil || user.sizing do return 0, id
			n, why := type_bits(c, user)
			if why != "" do return 0, fmt.aprintf("%s.%s", id, why, allocator = c.scratch)
			element = n
		}
	}
	overflow: bool
	bits, overflow = intrinsics.overflow_mul(element, count)
	if overflow do return 0, id
	return bits, ""
}

// The number of bytes of contents, a string or a sequence of bytes and
// strings (byte_list).
@(private = "file")
contents_length :: proc(contents: ^yml.Node) -> int {
	if contents.kind != .Seq do return len(contents.text)
	n := 0
	for item in contents.items {
		_, is_int := parse_int(item.text)
		n += is_int && item.style == .Plain ? 1 : len(item.text)
	}
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

// Compiles inst, a parse instance of set (of its members), as an attribute,
// then its io and pos. It can use the fields of set compiled so far, and its
// instances, and once every set is, any field. pos is compiled last: until it is set, a reference to inst
// compiles it, so that one from inst itself is found, also through a field
// of its type inside it (set.recursive), which is another instance, but
// whose type is not known yet.
@(private = "file")
compile_parse_instance :: proc(c: ^Compiler, set: ^mdata.Node, inst: ^mdata.Node) -> bool {
	src := c.parse_instances[inst]
	schema := c.schema
	defer c.schema = schema
	c.schema = src.td.schema
	if src.compiling && set.recursive != nil do return fail(c, .Unsupported, src.entry.key, "instance %s refers to itself in a field of its type; a type that contains itself cannot be compiled that way", inst.ref_name)
	if src.compiling do return fail(c, .Invalid, src.entry.key, "instance %s refers to itself", inst.ref_name)
	src.compiling = true
	defer src.compiling = false
	order := c.order
	defer c.order = order
	c.order = src.order

	spec := src.entry.value
	pos := get(spec, "pos")
	if pos == nil {
		// Kaitai reads it where its stream is when it is first used, and
		// moves the stream past it, which is known only for one that reads
		// nothing
		bits, unsized := attr_bits(c, src.td, spec, inst.ref_name, element_only = true)
		if unsized != "" || bits != 0 {
			return fail(c, .Unsupported, src.entry.key, "instance %s: an instance without pos or value that reads bytes is not supported; only one whose type or size reads none is", inst.ref_name)
		}
	}
	compile_field(c, src.td, spec, inst, src.scope, nil) or_return
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
		check_enum(c, n, inst.name, scope.enums) or_return
	}
	inst.expr = e
	return true
}

@(private = "file")
claim_id :: proc(c: ^Compiler, ids: ^[dynamic]^yml.Node, id: string, n: ^yml.Node) -> bool {
	// a type has few ids, and searching them costs less than hashing
	for prev in ids {
		if prev.text != id do continue
		return fail(c, .Invalid, n, "id %s is already used (line %v, column %v)", id, prev.line, prev.column)
	}
	append(ids, n)
	return true
}

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

@(private = "file")
INTEGER_TYPES :: bit_set[dat.Data_Type]{.Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64}

@(private = "file")
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
@(private = "file")
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
@(private = "file")
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
@(private = "file")
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
@(private = "file")
unnamed :: proc(c: ^Compiler, index: int) -> string {
	return fmt.aprintf("_unnamed%d", index, allocator = c.allocator)
}

// Compiles the keys of attr, an attribute or a parse instance, other than
// its id and pos, into node, in scope. ids holds the ids of the type, which
// bit fields claim; nil for a parse instance, which has none.
@(private = "file")
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
		if bytes_key != nil do return fail(c, .Invalid, bytes_key, "%s: contents cannot have %s", id, bytes_key.text)
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
			if user == nil && strings.contains(type_name, "::") do return fail(c, .Unsupported, type_node, "%s: a type of another type (%s) is not supported", id, type_name)
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

	if n := get(attr, "enum"); n != nil {
		if node.type not_in INTEGER_TYPES && node.type != .Bits do return fail(c, .Invalid, get_key(attr, "enum"), "%s: enum applies only to integer types", id)
		// the field keeps its integer, which the enum's constants are
		check_enum(c, n, id, scope.enums) or_return
	}

	if n := get(attr, "if"); n != nil {
		node.cond = compile_expr(c, n, "if", scope, .Bool) or_return
	}

	node.count = compile_count(c, attr, id, scope) or_return

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
	}
	// after the type's fields, which an expr can refer to through _
	if valid != nil {
		node.valid = compile_valid(c, attr, valid, id, node, scope) or_return
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

// The chain of node, a field of type user in a type whose chain is types:
// types followed by node, or node alone when user is the top level of an
// imported schema. As in Kaitai, that is the root of its own types (its
// _root), and has no _parent.
@(private = "file")
chain_of :: proc(c: ^Compiler, types: []^mdata.Node, user: ^Type_Def, node: ^mdata.Node) -> []^mdata.Node {
	return chain_with(c, user.parent == nil ? nil : types, node)
}

// types followed by node.
@(private = "file")
chain_with :: proc(c: ^Compiler, types: []^mdata.Node, node: ^mdata.Node) -> []^mdata.Node {
	chain := make([]^mdata.Node, len(types) + 1, c.scratch)
	copy(chain, types)
	chain[len(types)] = node
	return chain
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
	seen := make(map[int]^yml.Node, c.scratch)
	seen_text := make(map[string]^yml.Node, c.scratch)
	for e in cases.entries {
		is_default := e.key.text == "_" && e.key.style == .Plain
		value: int
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
			value = int(lit.value)
			if prev, dup := seen[value]; dup do return fail(c, .Invalid, e.key, "%s: case %s is already given (line %v, column %v)", id, e.key.text, prev.line, prev.column)
			seen[value] = e.key
		} else {
			key := compile_expr(c, e.key, "a case", scope, .Int) or_return
			lit, is_literal := key.variant.(mdata.Int_Literal)
			if !is_literal do return fail(c, .Unsupported, e.key, "%s: a case must be an integer or an enum constant", id)
			value = lit.value
			if prev, dup := seen[value]; dup do return fail(c, .Invalid, e.key, "%s: case %v is already given (line %v, column %v)", id, value, prev.line, prev.column)
			seen[value] = e.key
		}

		type_name := expect_scalar(c, e.value, "a case type") or_return
		call: Call
		type_name, call = split_call(c, e.value, id, type_name) or_return
		case_node := new_node(c, node.name, node.ref_name)
		case_node.count = mdata.Fixed_Count{1}
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
			if user == nil && strings.contains(type_name, "::") do return fail(c, .Unsupported, e.value, "%s: a type of another type (%s) is not supported", id, type_name)
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
			return mdata.Fixed_Count{lit.value}, true
		}
		return mdata.Rule_Count{expr = e}, true
	}

	if peek_key == nil do return mdata.Fixed_Count{1}, true

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

// Parses and resolves the expression n in scope. An error points at the
// character it is about when the expression is on one line.
@(private = "file")
compile_expr :: proc(c: ^Compiler, n: ^yml.Node, what: string, scope: expr.Scope, want: mdata.Expr_Type) -> (e: ^mdata.Expr, ok: bool) {
	text := expect_scalar(c, n, what) or_return
	err: expr.Error
	e, err = expr.compile(text, scope, want, c.allocator)
	if err.kind != .None do return nil, expr_error(c, n, what, err, 0)
	note_escapes(c, n, what, e, scope)
	return e, true
}

// Records err, the error of the expression at byte start of the scalar n,
// and frees it. Always returns false.
@(private = "file")
expr_error :: proc(c: ^Compiler, n: ^yml.Node, what: string, err: expr.Error, start: int) -> bool {
	err := err
	defer expr.destroy_error(&err)

	kind: Error_Kind
	switch err.kind {
	case .None:
		unreachable()
	case .Syntax:
		kind = .Syntax
	case .Unsupported:
		kind = .Unsupported
	case .Invalid:
		kind = .Invalid
	}
	// an instance compiled while resolving it may have recorded the error
	first := c.err.kind == .None
	fail(c, kind, n, "%s: %s", what, err.message)

	// the escapes of a quoted scalar and the folds of a multi-line one move
	// characters; only a plain or simple quoted scalar maps offsets exactly
	simple := !strings.contains_any(n.text, "\n'\"\\") && (n.style == .Plain || n.style == .Single_Quoted || n.style == .Double_Quoted)
	if first && simple && err.offset >= 0 {
		c.err.column += strings.rune_count(n.text[:start + err.offset]) + (n.style == .Plain ? 0 : 1)
	}
	return false
}

// The arguments of a type, t(a, b): the text between the parentheses, and
// the byte it starts at in the type's scalar. given is false for a type
// without parentheses.
@(private = "file")
Call :: struct {
	args:  string,
	start: int,
	given: bool,
}

// Splits text, the type of id in n, into its name and its arguments. The
// whitespace around them is ignored, such as the line break at the end of
// a block scalar.
@(private = "file")
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
@(private = "file")
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
@(private = "file")
compile_type :: proc(c: ^Compiler, user: ^Type_Def, node: ^mdata.Node, field_scope: expr.Scope, arg_sets: []^mdata.Node = nil) -> bool {
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
	scope := scope_of(c, user, chain)
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
@(private = "file")
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

// A byte: an integer from 0 to 255.
@(private = "file")
byte_value :: proc(c: ^Compiler, n: ^yml.Node, id, what: string) -> (b: u8, ok: bool) {
	text := expect_scalar(c, n, what) or_return
	v, is_int := parse_int(text)
	if !is_int || n.style != .Plain || v < 0 || v > 255 do return 0, fail(c, .Invalid, n, "%s: %s must be a byte, 0 to 255, not %q", id, what, text)
	return u8(v), true
}

// A boolean: true or false.
@(private = "file")
boolean :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (value: bool, ok: bool) {
	text := expect_scalar(c, n, what) or_return
	if n.style == .Plain {
		switch text {
		case "true":
			return true, true
		case "false":
			return false, true
		}
	}
	return false, fail(c, .Invalid, n, "%s must be true or false, not %q", what, text)
}

// contents (and the peek extensions): a string, whose UTF-8 bytes are
// meant, or a sequence of bytes (0 to 255) and strings.
@(private = "file")
byte_list :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (bytes: []byte, ok: bool) {
	b := make([dynamic]byte, c.allocator)
	switch n.kind {
	case .Scalar:
		if _, is_int := parse_int(n.text); is_int && n.style == .Plain {
			return nil, fail(c, .Invalid, n, "%s: write a byte as a sequence, [%s]", what, n.text)
		}
		append(&b, n.text)
	case .Seq:
		for item in n.items {
			if item.kind != .Scalar do return nil, fail(c, .Invalid, item, "%s: an element must be a byte or a string", what)
			if v, is_int := parse_int(item.text); is_int && item.style == .Plain {
				if v < 0 || v > 255 do return nil, fail(c, .Invalid, item, "%s: %s is not a byte (0 to 255)", what, item.text)
				append(&b, byte(v))
			} else {
				append(&b, item.text)
			}
		}
	case .Map:
		return nil, fail(c, .Invalid, n, "%s must be a string or a sequence", what)
	}
	return b[:], true
}

// valid on node, an attribute or a parse instance attr, in scope: a
// constant (eq), or a mapping of eq, min and max, any-of, expr or in-enum.
// A constant is a literal of the value's type (an integer or an enum
// constant, a string literal, or a list of bytes, [0x50, 0x4b], for a
// blob), or an expression of that type; in it and in expr, _ is the
// value. The check keeps Scalars when every constant is a literal, as
// most are, and is a Valid_Expr otherwise.
@(private = "file")
compile_valid :: proc(c: ^Compiler, attr, n: ^yml.Node, id: string, node: ^mdata.Node, scope: expr.Scope) -> (valid: mdata.Valid, ok: bool) {
	// the constants of a bit type have the type of its values
	type := node.type == .Bits ? mdata.bits_type(int(node.width)) : node.type
	scope := scope
	scope.element = node
	scope.in_repeat = !mdata.is_single(node)

	eq, lo, hi, any_of, ex, in_enum: ^yml.Node
	switch n.kind {
	case .Scalar:
		eq = n
	case .Seq:
		return nil, fail(c, .Invalid, n, "%s: valid must be a constant or a mapping", id)
	case .Map:
		check_keys(c, n, {what = "%s: valid", name = id, allowed = {"eq", "min", "max", "any-of", "expr", "in-enum"}}) or_return
		eq, lo, hi, any_of, ex, in_enum = get(n, "eq"), get(n, "min"), get(n, "max"), get(n, "any-of"), get(n, "expr"), get(n, "in-enum")
		forms := int(eq != nil) + int(lo != nil || hi != nil) + int(any_of != nil) + int(ex != nil) + int(in_enum != nil)
		if forms != 1 do return nil, fail(c, .Invalid, n, "%s: valid needs exactly one of eq, min and max, any-of, expr and in-enum", id)
	}

	switch {
	case ex != nil:
		cond := compile_expr(c, ex, "valid", scope, .Bool) or_return
		checks := make([]mdata.Valid_Check, 1, c.allocator)
		checks[0] = {cond, .Expr_False}
		return mdata.Valid_Expr{checks}, true
	case in_enum != nil:
		return compile_in_enum(c, attr, in_enum, id, scope.enums)
	}
	if type == .Set do return nil, fail(c, .Invalid, n, "%s: valid on a user type must be an expr", id)
	if type != .Bool && type != .String && type != .Blob && type not_in INTEGER_TYPES {
		return nil, fail(c, .Unsupported, n, "%s: valid on a %v is not supported", id, type)
	}
	if (lo != nil || hi != nil) && type not_in INTEGER_TYPES {
		return nil, fail(c, .Unsupported, n, "%s: min and max are only supported on integer types", id)
	}

	nodes := []^yml.Node{eq}
	if lo != nil || hi != nil do nodes = []^yml.Node{lo, hi}
	if any_of != nil {
		if any_of.kind != .Seq do return nil, fail(c, .Invalid, any_of, "%s: any-of must be a sequence", id)
		nodes = any_of.items
	}
	bounds := make([]Bound, len(nodes), c.scratch)
	literal := true
	for x, i in nodes {
		if x == nil do continue
		bounds[i] = compile_bound(c, x, id, type, scope) or_return
		literal &&= bounds[i].value != nil
	}

	if literal {
		switch {
		case eq != nil:
			return mdata.Valid_Eq{bounds[0].value}, true
		case any_of != nil:
			values := make([]mdata.Scalar, len(bounds), c.allocator)
			for b, i in bounds do values[i] = b.value
			return mdata.Valid_Any_Of{values}, true
		}
		r := mdata.Valid_Range{bounds[0].value, bounds[1].value}
		if lo != nil && hi != nil && int_of(r.min) > int_of(r.max) do return nil, fail(c, .Invalid, n, "%s: min is above max", id)
		return r, true
	}

	for b, i in bounds {
		if nodes[i] != nil && b.e == nil do return nil, fail(c, .Unsupported, nodes[i], "%s: %s cannot be compared with an expression", id, nodes[i].text)
	}
	checks := make([dynamic]mdata.Valid_Check, c.allocator)
	value_type: mdata.Expr_Type
	#partial switch type {
	case .Bool:
		value_type = .Bool
	case .String:
		value_type = .String
	case .Blob:
		value_type = .Bytes
	case:
		value_type = .Int
	}
	value := new_expr(c, value_type, mdata.Repeat_Element{node})
	switch {
	case eq != nil:
		append(&checks, mdata.Valid_Check{new_expr(c, .Bool, mdata.Binary{.Eq, value, bounds[0].e}), .Not_Equal})
	case any_of != nil:
		cond: ^mdata.Expr
		for b in bounds {
			x := new_expr(c, .Bool, mdata.Binary{.Eq, value, b.e})
			cond = cond == nil ? x : new_expr(c, .Bool, mdata.Binary{.Logical_Or, cond, x})
		}
		append(&checks, mdata.Valid_Check{cond, .Not_Any_Of})
	case:
		if lo != nil do append(&checks, mdata.Valid_Check{new_expr(c, .Bool, mdata.Binary{.Ge, value, bounds[0].e}), .Less_Than_Min})
		if hi != nil do append(&checks, mdata.Valid_Check{new_expr(c, .Bool, mdata.Binary{.Le, value, bounds[1].e}), .Greater_Than_Max})
	}
	return mdata.Valid_Expr{checks[:]}, true
}

// A constant of valid: value when it is a literal, and e when it can be
// compared in an expression; at least one is set.
@(private = "file")
Bound :: struct {
	value: mdata.Scalar,
	e:     ^mdata.Expr,
}

// The constant n of valid, on a value of type, in scope.
@(private = "file")
compile_bound :: proc(c: ^Compiler, n: ^yml.Node, id: string, type: dat.Data_Type, scope: expr.Scope) -> (b: Bound, ok: bool) {
	text := strings.trim_space(expect_scalar(c, n, "a valid constant") or_return)

	#partial switch type {
	case .Blob:
		// a list of bytes, as contents takes one, or a Bytes expression
		if bytes, is_list := byte_literal(c, text); is_list {
			return {value = bytes, e = new_expr(c, .Bytes, mdata.Bytes_Literal{bytes})}, true
		}
		return {e = compile_expr(c, n, "valid", scope, .Bytes) or_return}, true
	case .Bool:
		return {e = compile_expr(c, n, "valid", scope, .Bool) or_return}, true
	case .String:
		b.e = compile_expr(c, n, "valid", scope, .String) or_return
		if lit, is_literal := b.e.variant.(mdata.String_Literal); is_literal do b.value = lit.value
		return b, true
	}

	// an integer literal is read here too, since one beyond an int does
	// not parse as an expression
	v, is_int := parse_int(text)
	if !is_int {
		b.e = compile_expr(c, n, "valid", scope, .Int) or_return
		v, is_int = int_literal(b.e)
		if !is_int do return b, true
	} else if v >= i128(min(int)) && v <= i128(max(int)) {
		b.e = new_expr(c, .Int, mdata.Int_Literal{int(v)})
	}
	b.value, ok = int_scalar(type, v)
	if !ok do return {}, fail(c, .Invalid, n, "%s: %s does not fit in a %v", id, text, type)
	return b, true
}

// The value of e when it is an integer literal or a negated one; enum
// constants are already literals.
@(private = "file")
int_literal :: proc(e: ^mdata.Expr) -> (v: i128, ok: bool) {
	#partial switch x in e.variant {
	case mdata.Int_Literal:
		return i128(x.value), true
	case mdata.Unary:
		if x.op != .Neg do return
		lit := x.operand.variant.(mdata.Int_Literal) or_return
		return -i128(lit.value), true
	}
	return
}

// text as a list of bytes, [0x50, 0x4b]: integer literals from 0 to 255.
@(private = "file")
byte_literal :: proc(c: ^Compiler, text: string) -> (bytes: []byte, ok: bool) {
	if len(text) < 2 || text[0] != '[' || text[len(text) - 1] != ']' do return
	b := make([dynamic]byte, c.allocator)
	for item in strings.split(text[1:len(text) - 1], ",", c.scratch) {
		v := parse_int(strings.trim_space(item)) or_return
		if v < 0 || v > 255 do return
		append(&b, byte(v))
	}
	return b[:], true
}

// valid: in-enum: true, on attr, whose enum is among enums: its value is
// one of the enum's. in-enum: false checks nothing.
@(private = "file")
compile_in_enum :: proc(c: ^Compiler, attr, n: ^yml.Node, id: string, enums: []expr.Enum) -> (valid: mdata.Valid, ok: bool) {
	if !(boolean(c, n, "in-enum") or_return) do return nil, true
	enum_node := get(attr, "enum")
	if enum_node == nil do return nil, fail(c, .Invalid, n, "%s: in-enum needs an enum", id)
	// the enum key is checked first, so the enum is found
	for e in enums {
		if e.name != enum_node.text do continue
		values := make([]int, len(e.values), c.allocator)
		for v, i in e.values do values[i] = v.value
		slice.sort(values)
		return mdata.Valid_In_Enum{values}, true
	}
	panic("compile_in_enum: no enum")
}

// A resolved expression made by the compiler, with no text.
@(private = "file")
new_expr :: proc(c: ^Compiler, type: mdata.Expr_Type, variant: mdata.Expr_Variant) -> ^mdata.Expr {
	e := new(mdata.Expr, c.allocator)
	e^ = {type = type, offset = -1, variant = variant}
	return e
}

@(private = "file")
int_scalar :: proc(type: dat.Data_Type, v: i128) -> (value: mdata.Scalar, ok: bool) {
	#partial switch type {
	case .Int8:
		if v >= i128(min(i8)) && v <= i128(max(i8)) do return i8(v), true
	case .UInt8:
		if v >= 0 && v <= i128(max(u8)) do return u8(v), true
	case .Int16:
		if v >= i128(min(i16)) && v <= i128(max(i16)) do return i16(v), true
	case .UInt16:
		if v >= 0 && v <= i128(max(u16)) do return u16(v), true
	case .Int32:
		if v >= i128(min(i32)) && v <= i128(max(i32)) do return i32(v), true
	case .UInt32:
		if v >= 0 && v <= i128(max(u32)) do return u32(v), true
	case .Int64:
		if v >= i128(min(i64)) && v <= i128(max(i64)) do return i64(v), true
	case .UInt64:
		if v >= 0 && v <= i128(max(u64)) do return u64(v), true
	}
	return nil, false
}

// An integer Scalar as an i128, for comparing bounds.
@(private = "file")
int_of :: proc(s: mdata.Scalar) -> i128 {
	#partial switch v in s {
	case i8:  return i128(v)
	case i16: return i128(v)
	case i32: return i128(v)
	case i64: return i128(v)
	case u8:  return i128(v)
	case u16: return i128(v)
	case u32: return i128(v)
	case u64: return i128(v)
	}
	panic("int_of: not an integer")
}

// An integer literal as Kaitai writes them: an optional sign, then decimal,
// 0x hex, 0b binary or 0o octal digits, with _ allowed between digits.
// Values beyond 64 bits are rejected.
@(private = "file")
parse_int :: proc(text: string) -> (v: i128, ok: bool) {
	s := text
	negative := false
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		negative = s[0] == '-'
		s = s[1:]
	}

	base: i128 = 10
	if len(s) > 2 && s[0] == '0' {
		switch s[1] {
		case 'x', 'X':
			base = 16
		case 'b', 'B':
			base = 2
		case 'o', 'O':
			base = 8
		}
		if base != 10 do s = s[2:]
	}
	if len(s) == 0 || s[0] == '_' || s[len(s) - 1] == '_' do return 0, false

	for ch in transmute([]byte)s {
		d: i128
		switch ch {
		case '_':
			continue
		case '0' ..= '9':
			d = i128(ch - '0')
		case 'a' ..= 'f':
			d = i128(ch - 'a' + 10)
		case 'A' ..= 'F':
			d = i128(ch - 'A' + 10)
		case:
			return 0, false
		}
		if d >= base do return 0, false
		v = v * base + d
		if v > i128(max(u64)) do return 0, false
	}
	return negative ? -v : v, true
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
