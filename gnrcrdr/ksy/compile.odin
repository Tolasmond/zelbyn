package ksy

import arn "../arena"
import dat "../data"
import expr "../expression"
import "../file"
import mdata "../metadata"
import yml "../yaml"
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
//     license and tags (ignored); seq, types, instances, enums and doc,
//     doc-ref
//   - imported schemas, whose top-level types are used by their meta id,
//     each with its own meta
//   - attributes: id, type, size, size-eos, terminator with consume, include
//     and eos-error, pad-right, contents, if, enum, valid, repeat (expr,
//     eos, until) with repeat-expr and repeat-until, encoding, doc, doc-ref
//   - types u1-u8, s1-s8, f4, f8 (le/be suffixes or meta endian), str and
//     byte arrays (no type) with size, size-eos or terminator, strz, user
//     types (with size, size-eos or terminator, read from a substream), and
//     switch-on whose cases are user types
//   - value instances, and parse instances: instances with pos and the
//     keys of an attribute
//   - enums whose values are names (enum constants in expressions)
//   - the extensions -orig-id, -peek, -while-peek, -until-peek and -bits
//
// Not supported yet (Unsupported): bit types (b1-b64), instances without
// pos or value, io, size, size-eos and terminator on a switch-on field,
// and any valid constant that is not an integer or string literal.

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
	next_id:         int,
	schema:          ^Schema,              // the one whose types are being compiled
	imported:        map[string]^Type_Def, // the top-level type of each schema read from a file, by its cleaned path; in scratch
	import_paths:    []string,
	root:            ^mdata.Node,          // the root of the plan
	instances:       map[^mdata.Value_Instance]^Instance_Source, // in scratch
	parse_instances: map[^mdata.Node]^Parse_Source,              // in scratch
	err:             Error,
}

// A .ksy file: the schema being compiled, or one it imports.
@(private = "file")
Schema :: struct {
	path:     string,                   // the file it was read from; "" for source compiled without one
	endian:   Maybe(endian.Byte_Order), // meta endian
	encoding: string,                   // meta encoding; "" when absent
	imports:  []^Type_Def,              // the top-level type of each schema in meta imports, in order
}

@(private = "file")
new_schema :: proc(c: ^Compiler, path: string) -> ^Schema {
	s := new(Schema, c.scratch)
	s.path = path
	return s
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
	value:     ^yml.Node, // its value: key
	td:        ^Type_Def,
	set:       ^mdata.Node,
	compiling: bool,
}

// Where a parse instance of a set comes from, to compile it when an
// expression first refers to it; as for Instance_Source.
@(private = "file")
Parse_Source :: struct {
	entry:     yml.Entry, // its key and spec in instances
	td:        ^Type_Def,
	scope:     expr.Scope, // that of the set's fields
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
	types:       []^Type_Def,
	instances:   []yml.Entry, // the entries of instances, each checked
	enums:       []expr.Enum,
	in_progress: bool, // its attributes are being compiled
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
TYPE_ALLOWED :: []string{"seq", "types", "instances", "enums", "doc", "doc-ref"}

@(private = "file")
TOP_ALLOWED :: []string{"meta", "seq", "types", "instances", "enums", "doc", "doc-ref"}

@(private = "file")
TYPE_UNSUPPORTED :: []string{"params", "to-string"}

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
	allowed     = {"value", "doc", "doc-ref"},
	unsupported = {"if", "enum"},
	extensions  = {"-orig-id"},
}

@(private = "file")
PARSE_INSTANCE_KEYS :: Keys {
	allowed     = {"pos", "type", "size", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right", "contents", "if", "enum", "valid", "repeat", "repeat-expr", "repeat-until", "encoding", "doc", "doc-ref"},
	unsupported = {"io", "process", "parent"},
	extensions  = {"-orig-id"},
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

	name := display_name(c, get(root, "meta"), top.name) or_return
	node := new_node(c, name, top.name)
	node.type = .Set
	node.count = mdata.Fixed_Count{1}

	ff.name = node.name
	ff.root = node
	c.root = node
	return compile_fields(c, top, node, {node})
}

// Checks the top level and meta of c.schema, whose document's root is root,
// reads the schemas it imports, and builds its types. Returns its top-level
// type.
@(private = "file")
load_schema :: proc(c: ^Compiler, root: ^yml.Node) -> (top: ^Type_Def, ok: bool) {
	expect_map(c, root, "a schema") or_return
	check_keys(c, root, {what = "the top level", allowed = TOP_ALLOWED, unsupported = TYPE_UNSUPPORTED}) or_return

	meta := get(root, "meta")
	if meta == nil do return nil, fail(c, .Invalid, root, "the schema has no meta")
	expect_map(c, meta, "meta") or_return
	check_keys(c, meta, META_KEYS) or_return

	id_node := get(meta, "id")
	if id_node == nil do return nil, fail(c, .Invalid, meta, "meta has no id")
	id := identifier(c, id_node, "meta id") or_return

	if n := get(meta, "endian"); n != nil {
		c.schema.endian = byte_order(c, n, "endian") or_return
	}
	if n := get(meta, "bit-endian"); n != nil {
		// nothing reads bit types yet; the value is still checked
		_ = byte_order(c, n, "bit-endian") or_return
	}
	if n := get(meta, "encoding"); n != nil {
		c.schema.encoding = encoding(c, n) or_return
	}
	if n := get(meta, "ks-version"); n != nil {
		check_ks_version(c, n) or_return
	}

	top = build_type(c, id, root, nil) or_return
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
	if n.kind == .Map && get(n, "switch-on") != nil do return .Little, fail(c, .Unsupported, n, "%s: switch-on is not supported", what)
	text := expect_scalar(c, n, what) or_return
	switch text {
	case "le":
		return .Little, true
	case "be":
		return .Big, true
	}
	return .Little, fail(c, .Invalid, n, "%s must be le or be, not %q", what, text)
}

// Strings are kept as their bytes, so the encodings supported are those
// whose bytes need no decoding.
@(private = "file")
encoding :: proc(c: ^Compiler, n: ^yml.Node) -> (name: string, ok: bool) {
	name = expect_scalar(c, n, "encoding") or_return
	switch strings.to_upper(name, c.scratch) {
	case "ASCII", "UTF-8", "UTF8":
		return name, true
	}
	return "", fail(c, .Unsupported, n, "encoding %q is not supported; only ASCII and UTF-8 are", name)
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
	c.next_id += 1
	node := new(mdata.Node, c.allocator)
	node^ = {id = c.next_id, name = name, ref_name = ref_name, order = c.schema.endian.? or_else .Little}
	return node
}

// Builds the type spec (the top level when parent is nil) and the types
// declared in it, and checks the keys of every attribute, so that a key
// outside the subset is rejected even in a type nothing uses.
@(private = "file")
build_type :: proc(c: ^Compiler, name: string, spec: ^yml.Node, parent: ^Type_Def) -> (td: ^Type_Def, ok: bool) {
	td = new(Type_Def, c.scratch)
	td^ = {name = name, spec = spec, schema = c.schema, parent = parent}

	if parent != nil {
		if spec.kind != .Map do return nil, fail(c, .Invalid, spec, "type %s must be a mapping", name)
		if k := get_key(spec, "meta"); k != nil do return nil, fail(c, .Unsupported, k, "type %s: meta in a type is not supported", name)
		// -orig-id on a type documents its original name; nothing shows it
		check_keys(c, spec, {what = "type %s", name = name, allowed = TYPE_ALLOWED, unsupported = TYPE_UNSUPPORTED, extensions = {"-orig-id"}}) or_return
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
			if get(e.value, "value") == nil && get(e.value, "pos") == nil {
				return nil, fail(c, .Unsupported, e.key, "instance %s: an instance without pos or value is not supported", inst_name)
			}
		}
		td.instances = instances.entries
	}

	if enums := get(spec, "enums"); enums != nil {
		td.enums = build_enums(c, enums) or_return
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
			if v.value.kind == .Map do return nil, fail(c, .Unsupported, v.value, "enum %s: values with id and doc are not supported", name)
			value_name := identifier(c, v.value, "enum value name") or_return

			for prev in values[:j] {
				if prev.name == value_name do return nil, fail(c, .Invalid, v.value, "enum %s: %s appears twice", name, value_name)
				if prev.value == int(n) do return nil, fail(c, .Invalid, v.key, "enum %s: value %v appears twice", name, v.key.text)
			}
			values[j] = {value_name, int(n)}
		}
		enums[i] = {name, values}
	}
	return enums, true
}

// The type called name, looked up from td outward, then among the schemas
// that td's schema imports.
@(private = "file")
find_type :: proc(td: ^Type_Def, name: string) -> ^Type_Def {
	for t := td; t != nil; t = t.parent {
		for sub in t.types {
			if sub.name == name do return sub
		}
	}
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
// and to any instance whose expressions refer only to those.
@(private = "file")
compile_fields :: proc(c: ^Compiler, td: ^Type_Def, set: ^mdata.Node, chain: []^mdata.Node) -> bool {
	schema := c.schema
	defer c.schema = schema
	c.schema = td.schema
	if td.in_progress do return fail(c, .Unsupported, td.spec, "type %s contains itself; recursive types are not supported", td.name)
	td.in_progress = true
	defer td.in_progress = false

	ids := make([dynamic]^yml.Node, c.scratch) // the id nodes of the attributes, bit fields and instances

	// each instance is compiled when an expression first refers to it, or
	// after the attributes
	scope := scope_of(c, td, chain)
	instances := make([dynamic]^mdata.Value_Instance, c.allocator)
	parse_instances := make([dynamic]^mdata.Node, c.allocator)
	for e in td.instances {
		if value := get(e.value, "value"); value != nil {
			inst := new(mdata.Value_Instance, c.allocator)
			inst.name = e.key.text
			src := new(Instance_Source, c.scratch)
			src^ = {value = value, td = td, set = set}
			c.instances[inst] = src
			append(&instances, inst)
		} else {
			p := new_node(c, display_name(c, e.value, e.key.text) or_return, e.key.text)
			src := new(Parse_Source, c.scratch)
			src^ = {entry = e, td = td, scope = scope}
			c.parse_instances[p] = src
			append(&parse_instances, p)
		}
	}
	set.instances = instances[:]
	set.parse_instances = parse_instances[:]
	if seq := get(td.spec, "seq"); seq != nil {
		children := make([dynamic]^mdata.Node, c.allocator)
		for attr in seq.items {
			child := compile_attr(c, td, attr, scope, &ids) or_return
			append(&children, child)
			set.children = children[:]
		}
	}
	set.slot_count = mdata.count_slots(set)

	next_value, next_parse := 0, 0
	for e in td.instances {
		claim_id(c, &ids, e.key.text, e.key) or_return
		if get(e.value, "value") != nil {
			inst := instances[next_value]
			next_value += 1
			if inst.expr == nil do compile_instance(c, set, inst) or_return
		} else {
			p := parse_instances[next_parse]
			next_parse += 1
			if p.pos == nil do compile_parse_instance(c, set, p) or_return
		}
	}
	return true
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

// Compiles inst, a parse instance of set, as an attribute, then its pos. It
// can use the fields of set compiled so far, and its instances. pos is
// compiled last: until it is set, a reference to inst compiles it, so
// that one from inst itself is found.
@(private = "file")
compile_parse_instance :: proc(c: ^Compiler, set: ^mdata.Node, inst: ^mdata.Node) -> bool {
	src := c.parse_instances[inst]
	schema := c.schema
	defer c.schema = schema
	c.schema = src.td.schema
	if src.compiling do return fail(c, .Invalid, src.entry.key, "instance %s refers to itself", inst.ref_name)
	src.compiling = true
	defer src.compiling = false

	spec := src.entry.value
	compile_field(c, src.td, spec, inst, src.scope, nil) or_return
	inst.pos = compile_expr(c, get(spec, "pos"), "pos", src.scope, .Int) or_return
	return true
}

// Compiles the expression of inst, a value instance of set. It can use the
// fields of set compiled so far and its other value instances.
@(private = "file")
compile_instance :: proc(c: ^Compiler, set: ^mdata.Node, inst: ^mdata.Value_Instance) -> bool {
	src := c.instances[inst]
	schema := c.schema
	defer c.schema = schema
	c.schema = src.td.schema
	if src.compiling do return fail(c, .Invalid, src.value, "value instance %s refers to itself", inst.name)
	src.compiling = true
	defer src.compiling = false

	types := make([]^mdata.Node, 1, c.scratch)
	types[0] = set
	scope := scope_of(c, src.td, types)
	scope.instance = true

	e := compile_expr(c, src.value, "value", scope, .Unresolved) or_return
	if e.type != .Int && e.type != .Bool {
		return fail(c, .Unsupported, src.value, "value instance %s: only integer and boolean values are supported", inst.name)
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

// b1 to b64, with an optional le or be.
@(private = "file")
is_bit_type :: proc(name: string) -> bool {
	s := strings.trim_suffix(strings.trim_suffix(name, "le"), "be")
	if len(s) < 2 || s[0] != 'b' do return false
	for ch in transmute([]byte)s[1:] {
		if ch < '0' || ch > '9' do return false
	}
	return true
}

// A seq attribute: its id, then the rest as compile_field compiles it.
@(private = "file")
compile_attr :: proc(c: ^Compiler, td: ^Type_Def, attr: ^yml.Node, scope: expr.Scope, ids: ^[dynamic]^yml.Node) -> (node: ^mdata.Node, ok: bool) {
	id_node := get(attr, "id")
	if id_node == nil do return nil, fail(c, .Unsupported, attr, "an attribute in type %s has no id; attributes without one are not supported", td.name)
	id := identifier(c, id_node, "id") or_return
	claim_id(c, ids, id, id_node) or_return

	name := display_name(c, attr, id) or_return
	node = new_node(c, name, id)
	compile_field(c, td, attr, node, scope, ids) or_return
	return node, true
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
		if bytes_key != nil do return fail(c, .Unsupported, bytes_key, "%s: %s on a switch-on field is not supported", id, bytes_key.text)
	case:
		type_name := expect_scalar(c, type_node, "type") or_return
		sizes := TYPE_SIZE
		if prim, order, is_primitive := primitive(type_name); is_primitive {
			node.type = prim
			if o, has_order := order.?; has_order {
				node.order = o
			} else if sizes[prim] > 1 && c.schema.endian == nil {
				return fail(c, .Invalid, type_node, "%s: %s needs le or be, or meta endian", id, type_name)
			}
			if bytes_key != nil do return fail(c, .Invalid, bytes_key, "%s: %s does not apply to %s", id, bytes_key.text, type_name)
		} else if type_name == "str" || type_name == "strz" {
			node.type = .String
			strz = type_name == "strz"
			if !strz && !ends do return fail(c, .Invalid, type_node, "%s: str needs size, size-eos or terminator", id)
		} else if is_bit_type(type_name) {
			return fail(c, .Unsupported, type_node, "%s: type %s is not supported", id, type_name)
		} else {
			user = find_type(td, type_name)
			if user == nil && strings.contains(type_name, "::") do return fail(c, .Unsupported, type_node, "%s: a type of another type (%s) is not supported", id, type_name)
			if user == nil do return fail(c, .Invalid, type_node, "%s: unknown type %s", id, type_name)
			node.type = .Set
		}
	}

	if n := get(attr, "encoding"); n != nil {
		if node.type != .String do return fail(c, .Invalid, get_key(attr, "encoding"), "%s: encoding applies only to str", id)
		_ = encoding(c, n) or_return
	} else if node.type == .String && c.schema.encoding == "" {
		return fail(c, .Invalid, type_node, "%s: str needs an encoding, or meta encoding", id)
	}

	if n := get(attr, "enum"); n != nil {
		if node.type not_in INTEGER_TYPES do return fail(c, .Invalid, get_key(attr, "enum"), "%s: enum applies only to integer types", id)
		enum_name := expect_scalar(c, n, "enum") or_return
		if strings.contains(enum_name, "::") do return fail(c, .Unsupported, n, "%s: an enum of another type (%s) is not supported", id, enum_name)
		// the field keeps its integer, which the enum's constants are
		found := false
		for e in scope.enums {
			if e.name == enum_name do found = true
		}
		if !found do return fail(c, .Invalid, n, "%s: no enum %s", id, enum_name)
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
	compile_terminator(c, attr, id, node, strz) or_return

	if valid != nil {
		node.valid = compile_valid(c, valid, id, node.type) or_return
	}

	if bits := get(attr, "-bits"); bits != nil {
		node.bits = compile_bits(c, bits, id, node.type, ids) or_return
	}

	if user != nil {
		compile_fields(c, user, node, chain_of(c, scope.types, user, node)) or_return
	}
	if switch_node != nil {
		compile_switch(c, td, switch_node, id, node, element_scope) or_return
	}

	// repeat-until refers to the element just read, so it is compiled after
	// the element's fields
	if _, is_until := node.count.(mdata.Until_Count); is_until {
		until_scope := scope
		until_scope.element = node
		node.count = mdata.Until_Count{compile_expr(c, get(attr, "repeat-until"), "repeat-until", until_scope, .Bool) or_return}
	}
	return true
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

// type: switch-on and cases, on node, a set. Each case is a user type,
// compiled as a set with node's names; a case value is an integer or enum
// constant, or _ for the default.
@(private = "file")
compile_switch :: proc(c: ^Compiler, td: ^Type_Def, n: ^yml.Node, id: string, node: ^mdata.Node, scope: expr.Scope) -> bool {
	keys := SWITCH_KEYS
	keys.what, keys.name = "%s: type", id
	check_keys(c, n, keys) or_return
	on := get(n, "switch-on")
	if on == nil do return fail(c, .Invalid, n, "%s: a type mapping needs switch-on", id)
	cases := get(n, "cases")
	if cases == nil do return fail(c, .Invalid, n, "%s: switch-on needs cases", id)
	expect_map(c, cases, "cases") or_return

	sw := new(mdata.Switch, c.allocator)
	sw.on = compile_expr(c, on, "switch-on", scope, .Int) or_return

	list := make([dynamic]mdata.Switch_Case, c.allocator)
	seen := make(map[int]^yml.Node, c.scratch)
	default_key: ^yml.Node
	for e in cases.entries {
		is_default := e.key.text == "_" && e.key.style == .Plain
		value: int
		if is_default {
			default_key = e.key
		} else {
			key := compile_expr(c, e.key, "a case", scope, .Int) or_return
			lit, is_literal := key.variant.(mdata.Int_Literal)
			if !is_literal do return fail(c, .Unsupported, e.key, "%s: a case must be an integer or an enum constant", id)
			value = lit.value
			if prev, dup := seen[value]; dup do return fail(c, .Invalid, e.key, "%s: case %v is already given (line %v, column %v)", id, value, prev.line, prev.column)
			seen[value] = e.key
		}

		type_name := expect_scalar(c, e.value, "a case type") or_return
		user := find_type(td, type_name)
		if user == nil {
			if _, _, is_primitive := primitive(type_name); is_primitive || type_name == "str" || type_name == "strz" || is_bit_type(type_name) {
				return fail(c, .Unsupported, e.value, "%s: a case of type %s is not supported; only user types are", id, type_name)
			}
			if strings.contains(type_name, "::") do return fail(c, .Unsupported, e.value, "%s: a type of another type (%s) is not supported", id, type_name)
			return fail(c, .Invalid, e.value, "%s: unknown type %s", id, type_name)
		}

		case_node := new_node(c, node.name, node.ref_name)
		case_node.type = .Set
		case_node.count = mdata.Fixed_Count{1}
		compile_fields(c, user, case_node, chain_of(c, scope.types, user, case_node)) or_return

		if is_default {
			sw.default = case_node
		} else {
			append(&list, mdata.Switch_Case{value, case_node})
		}
	}
	sw.cases = list[:]

	if default_key == nil && !mdata.is_single(node) {
		return fail(c, .Unsupported, on, "%s: a repeated switch-on without a _ case is not supported", id)
	}
	node.switch_on = sw
	return true
}

// The count from repeat (with repeat-expr or repeat-until), or from -peek,
// -while-peek or -until-peek. A repeat-until count is returned without
// its expression, which compile_attr compiles.
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
	if err.kind == .None do return e, true
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
	simple := !strings.contains_any(text, "\n'\"\\") && (n.style == .Plain || n.style == .Single_Quoted || n.style == .Double_Quoted)
	if first && simple && err.offset >= 0 {
		c.err.column += strings.rune_count(text[:err.offset]) + (n.style == .Plain ? 0 : 1)
	}
	return nil, false
}

// terminator, or strz's 0, with consume, include and eos-error, and
// pad-right, on node, whose length is compiled. consume and eos-error
// apply only without a length, and pad-right only with one; each defaults
// as in Kaitai.
@(private = "file")
compile_terminator :: proc(c: ^Compiler, attr: ^yml.Node, id: string, node: ^mdata.Node, strz: bool) -> bool {
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

	if !terminated {
		if flag_key != nil do return fail(c, .Invalid, flag_key, "%s: %s applies only with terminator or strz", id, flag_key.text)
		return true
	}
	if sized && sized_key != nil do return fail(c, .Invalid, sized_key, "%s: %s does not apply with a size", id, sized_key.text)
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

// valid: a constant (eq), or a mapping of eq, min and max, or any-of.
@(private = "file")
compile_valid :: proc(c: ^Compiler, n: ^yml.Node, id: string, type: dat.Data_Type) -> (valid: mdata.Valid, ok: bool) {
	if type == .Set do return nil, fail(c, .Invalid, n, "%s: valid does not apply to a user type", id)

	switch n.kind {
	case .Scalar:
		return mdata.Valid_Eq{constant(c, n, id, type) or_return}, true
	case .Seq:
		return nil, fail(c, .Invalid, n, "%s: valid must be a constant or a mapping", id)
	case .Map:
	}

	check_keys(c, n, {what = "%s: valid", name = id, allowed = {"eq", "min", "max", "any-of"}, unsupported = {"expr", "in-enum"}}) or_return

	eq, lo, hi, any_of := get(n, "eq"), get(n, "min"), get(n, "max"), get(n, "any-of")
	forms := int(eq != nil) + int(lo != nil || hi != nil) + int(any_of != nil)
	if forms != 1 do return nil, fail(c, .Invalid, n, "%s: valid needs exactly one of eq, min and max, or any-of", id)

	switch {
	case eq != nil:
		return mdata.Valid_Eq{constant(c, eq, id, type) or_return}, true
	case any_of != nil:
		if any_of.kind != .Seq do return nil, fail(c, .Invalid, any_of, "%s: any-of must be a sequence", id)
		values := make([]mdata.Scalar, len(any_of.items), c.allocator)
		for item, i in any_of.items {
			values[i] = constant(c, item, id, type) or_return
		}
		return mdata.Valid_Any_Of{values}, true
	}

	if type not_in INTEGER_TYPES do return nil, fail(c, .Unsupported, n, "%s: min and max are only supported on integer types", id)
	r: mdata.Valid_Range
	if lo != nil do r.min = constant(c, lo, id, type) or_return
	if hi != nil do r.max = constant(c, hi, id, type) or_return
	if lo != nil && hi != nil && int_of(r.min) > int_of(r.max) do return nil, fail(c, .Invalid, n, "%s: min is above max", id)
	return r, true
}

// A valid constant, as type: an integer literal for an integer type, or a
// string literal ("text" or 'text', without escapes) for a str.
@(private = "file")
constant :: proc(c: ^Compiler, n: ^yml.Node, id: string, type: dat.Data_Type) -> (value: mdata.Scalar, ok: bool) {
	text := expect_scalar(c, n, "a valid constant") or_return
	text = strings.trim_space(text)

	#partial switch type {
	case .String:
		if len(text) >= 2 && (text[0] == '"' || text[0] == '\'') && text[len(text) - 1] == text[0] {
			inner := text[1:len(text) - 1]
			if strings.contains_any(inner, "\\\"'") do return nil, fail(c, .Unsupported, n, "%s: escapes and quotes in a string literal are not supported", id)
			return inner, true
		}
		return nil, fail(c, .Unsupported, n, "%s: a valid constant for a str must be a string literal (\"text\")", id)
	case .Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64:
		v, is_int := parse_int(text)
		if !is_int do return nil, fail(c, .Unsupported, n, "%s: a valid constant for an integer must be an integer literal, not %q", id, text)
		value, ok = int_scalar(type, v)
		if !ok do return nil, fail(c, .Invalid, n, "%s: %s does not fit in a %v", id, text, type)
		return value, true
	}
	return nil, fail(c, .Unsupported, n, "%s: valid on a %v is not supported", id, type)
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

		c.next_id += 1
		name := display_name(c, item, bit_id) or_return
		bits[i] = {id = c.next_id, name = name, low = low, high = high}
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
