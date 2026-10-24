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
import "core:slice"
import "core:strings"


// The .ksy front end: a subset of Kaitai Struct, compiled into the plan.
// Anything outside the subset is an error naming its key and location; keys
// starting with - that zelbyn does not know are ignored, as the official
// tools ignore them.
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
//   - types and enums by path (a::b, a::e), also of an imported schema; a
//     type of another schema has no _parent there, and but at its top
//     level, it and the types inside it have no _root, as in Kaitai
//   - attributes: id (without one, named _unnamed and their index in seq, as
//     in Kaitai), type, size, size-eos, terminator with consume, include and
//     eos-error, pad-right, process (zlib), contents (whose size, if any,
//     is ignored, as in Kaitai), parent (on a user type, _parent,
//     _parent._parent and so on), if, enum, valid (eq, min, max, any-of,
//     in-enum, expr), repeat (expr, eos, until) with repeat-expr and
//     repeat-until, encoding, doc, doc-ref
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
//     and the keys of an attribute, or without pos when they read nothing,
//     as a switch-on whose cases' types read nothing does
//   - .pos, .size and .eof of _io and of the _io of another set instance
//   - ?: of sets of one type, and of arrays of one item type but sets and
//     arrays
//   - integers in expressions exact from -2^63 to 2^64 - 1
//   - float literals and float fields in expressions, with + - * / and the
//     comparisons, also with integers
//   - casts, .as<t>, to an integer type, to bytes of an array of integers,
//     and, of a switch-on field, to the user type of a case; array
//     literals, [a, b], also of array literals; and the methods
//     .to_s(encoding) of bytes and
//     .substring(from, to) of a string
//   - params of integer types, bool, bytes, str and user types, in types
//     and at the top level of an imported schema, given as t(a, b), and on
//     the top-level type of the schema compiled, whose arguments the
//     decoder is given (Root_Arg), for a user type as bytes it reads one
//     from (root_arg_sets)
//   - enums, whose values are names or mappings of id, doc and doc-ref
//     (enum constants in expressions, a::e::v by path)
//   - the extensions -orig-id (a list of names leaves the id), -peek,
//     -while-peek, -until-peek and -bits
//
// Not supported yet (Unsupported): other encodings, instances without pos or
// value that read bytes, params of other types (struct, io, any), and of a
// user type with params on the top-level type of the schema compiled, % of a
// float, ?: of arrays of sets or arrays, valid on a float other than its
// expr (eq, min, max and any-of), min and max on a
// type other than an integer, an endian that is a switch-on on the top-level
// type or in a type that contains itself, a bit-endian that is a switch-on,
// imports in a type, parent other than _parent, _parent._parent and so on,
// in a type that contains itself, the members of the sets enclosing it,
// other than through _root (in a value instance, only that of the schema
// compiled), unless a parent gives its fields inside it the same ones, and
// an instance that refers to itself through a field of its type.

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
	c.stack_start = uintptr(&c)
	c.instances = make(map[^mdata.Value_Instance]^Instance_Source, c.scratch)
	c.parse_instances = make(map[^mdata.Node]^Parse_Source, c.scratch)
	c.type_defs = make([dynamic]Set_Type, c.scratch)
	c.deferred = make([dynamic]Deferred, c.scratch)
	c.rootless = make([dynamic]^mdata.Node, c.scratch)
	c.param_args = make([dynamic]Param_Arg, c.scratch)
	c.imported = make(map[string]^Type_Def, c.scratch)

	c.schema = new_schema(&c, path)
	if root, ok := parse_schema(&c, src); ok {
		compile_schema(&c, root, file_format)
	}
	return c.err
}

@(private)
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
	rootless:        [dynamic]^mdata.Node,                       // the sets of types declared in another schema than the field's, not at its top level, which have no _root (chain_of); in scratch
	current:         ^mdata.Node,                                // the set whose fields or parse instance are being compiled, which a set compiled now is inside (Set_Type.outer)
	param_args:      [dynamic]Param_Arg,                         // each param of a user type, with the set of its argument; in scratch
	err:             Error,
	nesting:         int,     // the types, instances, sizes and imports being compiled inside each other, at most MAX_NESTING
	stack_start:     uintptr, // the address of a local of compile, from which enter measures the stack used
	too_deep:        bool,    // a size was not found, as types nested more than MAX_NESTING deep (type_bits)
}

// The deepest that the compile of a type, an instance found by a
// reference, a size found through a type (type_bits) or an import nests
// inside another: some eight times the deepest of the corpus (8), and few enough
// that compiling, which recurses through each, cannot use the stack up. A
// deeper chain of them, a type whose field is of a type whose field is
// ..., or a value instance that uses one that uses ..., is Unsupported.
MAX_NESTING :: 64

// The stack that compiling may use before a level of nesting is
// Unsupported, measured from compile: each level resolves expressions
// expression.MAX_DEPTH deep at most, which a few levels of MAX_NESTING
// would take beyond a thread's stack (1 MB for Windows' main thread) in a
// debug build. One level more stays below it.
MAX_STACK :: 512 * 1024

// Enters a level of nesting (MAX_NESTING) for what, at n; false, after an
// Unsupported error, when it is one too many, or compiling has used
// MAX_STACK. leave leaves it.
@(private)
enter :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> bool {
	c.nesting += 1
	if c.nesting > MAX_NESTING do return fail(c, .Unsupported, n, "%s: types, instances and imports compiled inside each other more than %v deep are not supported", what, MAX_NESTING)
	here: u8
	if int(c.stack_start - uintptr(&here)) > MAX_STACK do return fail(c, .Unsupported, n, "%s: types, instances and expressions nested this deep are not supported, as compiling them would use more than %v KB of stack", what, MAX_STACK / 1024)
	return true
}

@(private)
leave :: proc(c: ^Compiler) {
	c.nesting -= 1
}

// A value instance or a parse instance of set whose compile is put off
// until every set is compiled (Compiler.deferred); the other is nil.
@(private)
Deferred :: struct {
	set:   ^mdata.Node,
	value: ^mdata.Value_Instance,
	parse: ^mdata.Node,
}

// A param of a user type, and the set of its argument, which keeps the
// stream of its instances when the param's _io is used (keeps_stream).
@(private)
Param_Arg :: struct {
	param, set: ^mdata.Node,
}

// A set compiled, and its type. Sizes are rare, so the sets are searched
// rather than hashed, which would cost every compile more. reused_by holds
// the fields of its type inside it (Node.recursive), which are given its
// members once it is compiled. When one of them is read with other
// instances enclosing it than the set (reused_deeper), escape is an error:
// the first expression in it, or in the sets inside it, that refers to an
// instance enclosing it (note_escapes), with what it is.
@(private)
Set_Type :: struct {
	set:           ^mdata.Node,
	td:            ^Type_Def,
	chain:         []^mdata.Node,        // its scope (compile_fields)
	outer:         ^mdata.Node,          // the set it is inside, of the field or parse instance it is of, whatever its chain; nil for the root
	done:          bool,                 // its attributes and instances are compiled, but for value instances put off
	reused_by:     [dynamic]^mdata.Node, // in scratch; nil until one
	reused_deeper: bool,                 // a field of reused_by has other sets enclosing it in its chain than set has
	escape:        ^yml.Node,
	escape_what:   string,
	escape_schema: ^Schema, // the schema escape is in
}

// A .ksy file: the schema being compiled, or one it imports.
@(private)
Schema :: struct {
	path:    string,      // the file it was read from; "" for source compiled without one
	imports: []^Type_Def, // the top-level type of each schema in meta imports, in order
}

// The keys of meta that apply to the attributes of a type: those of the
// schema's meta at the top level, and in a type, those of its own meta
// over those of the type it is declared in, as in Kaitai.
@(private)
Meta :: struct {
	bit_endian:    endian.Byte_Order,        // bit-endian; .Big when absent, as in Kaitai
	endian:        Maybe(endian.Byte_Order), // endian
	endian_switch: ^yml.Node,                // endian when it is a switch-on, chosen as each instance of the type that declares it is read; nil otherwise
	endian_owner:  string,                   // the type that declares endian_switch
	encoding:      Maybe(mdata.Encoding),    // encoding
}

// Where a value instance of a set comes from, to compile it when an
// expression first refers to it. Each is its own allocation, since
// compiling one can add others to the map.
@(private)
Instance_Source :: struct {
	spec:      ^yml.Node, // its mapping in instances, which has a value key
	td:        ^Type_Def,
	scope:     expr.Scope, // that of the set's fields
	compiling: bool,
}

// Where a parse instance of a set comes from, to compile it when an
// expression first refers to it; as for Instance_Source.
@(private)
Parse_Source :: struct {
	entry:     yml.Entry, // its key and spec in instances
	td:        ^Type_Def,
	scope:     expr.Scope, // that of the set's fields
	order:     Maybe(endian.Byte_Order), // Compiler.order for the set
	compiling: bool,
	typed:     bool, // its type is compiled (compile_field), but maybe not its io and pos
}

// A type: the top level of a schema, or an entry of types. Its attributes
// are compiled for each field of the type, so that names resolve in the
// field's scope.
@(private)
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
@(private)
Param_Def :: struct {
	id:        ^yml.Node, // its id's node
	type:      dat.Data_Type, // of its value: Int64 for any integer type, Bool, Blob, String, or Set for a user type
	type_name: string, // a Set: the user type, looked up from the type the param is of
}

// Records the first error, at n (or nowhere when n is nil); always returns
// false.
@(private)
fail :: proc(c: ^Compiler, kind: Error_Kind, n: ^yml.Node, format: string, args: ..any) -> bool {
	if c.err.kind == .None {
		c.err = Error{kind = kind, message = fmt.aprintf(format, ..args)}
		if n != nil do c.err.line, c.err.column = n.line, n.column
		if c.schema != nil && c.schema.path != "" do c.err.path = strings.clone(c.schema.path)
	}
	return false
}

// The value of key in the mapping m; nil when absent.
@(private)
get :: proc(m: ^yml.Node, key: string) -> ^yml.Node {
	for e in m.entries {
		if e.key.text == key do return e.value
	}
	return nil
}

@(private)
get_key :: proc(m: ^yml.Node, key: string) -> ^yml.Node {
	for e in m.entries {
		if e.key.text == key do return e.key
	}
	return nil
}

// The first key of the mapping m that is one of keys; nil when none is.
@(private)
first_key :: proc(m: ^yml.Node, keys: []string) -> ^yml.Node {
	for e in m.entries {
		if slice.contains(keys, e.key.text) do return e.key
	}
	return nil
}

@(private)
expect_map :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> bool {
	if n.kind != .Map do return fail(c, .Invalid, n, "%s must be a mapping", what)
	return true
}

@(private)
expect_scalar :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (text: string, ok: bool) {
	if n.kind != .Scalar do return "", fail(c, .Invalid, n, "%s must be a scalar", what)
	return n.text, true
}

// The keys a mapping may have. Kaitai keys outside the subset are
// Unsupported, other keys Invalid. Keys starting with - are allowed when in
// extensions; any other - key is ignored unless zelbyn uses it elsewhere.
@(private)
Keys :: struct {
	what:        string, // for errors: "meta", or a format of name, "attribute %s", formatted only for an error
	name:        string,
	allowed:     []string,
	unsupported: []string, // Kaitai keys outside the subset
	extensions:  []string,
}

@(private)
EXTENSIONS :: []string{"-orig-id", "-peek", "-while-peek", "-until-peek", "-bits"}

@(private)
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
			// an extension zelbyn does not know
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

@(private)
META_KEYS :: Keys {
	what        = "meta",
	allowed     = {"id", "endian", "bit-endian", "encoding", "ks-version", "imports", "title", "application", "file-extension", "xref", "license", "tags"},
	unsupported = {"ks-debug", "ks-opaque-types"},
	extensions  = {"-orig-id"},
}

@(private)
TYPE_ALLOWED :: []string{"meta", "seq", "types", "instances", "enums", "doc", "doc-ref", "params", "to-string"}

@(private)
TOP_ALLOWED :: []string{"meta", "seq", "types", "instances", "enums", "doc", "doc-ref", "params", "to-string"}

@(private)
ATTR_ALLOWED :: []string{"id", "type", "size", "contents", "if", "enum", "valid", "repeat", "repeat-expr", "repeat-until", "encoding", "doc", "doc-ref", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right", "process", "parent"}

@(private)
ATTR_UNSUPPORTED :: []string{"io", "pos", "value"}

// The keys of an attribute that say where the bytes of each element end.
@(private)
BYTES_KEYS :: []string{"size", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right"}

// The keys of a value instance, and of a parse instance: those of an
// attribute, with pos instead of id.
@(private)
VALUE_INSTANCE_KEYS :: Keys {
	allowed    = {"value", "if", "enum", "doc", "doc-ref"},
	extensions = {"-orig-id"},
}

@(private)
PARSE_INSTANCE_KEYS :: Keys {
	allowed    = {"pos", "io", "type", "size", "size-eos", "terminator", "consume", "include", "eos-error", "pad-right", "process", "contents", "if", "enum", "valid", "repeat", "repeat-expr", "repeat-until", "encoding", "doc", "doc-ref", "parent"},
	extensions = {"-orig-id"},
}

@(private)
PARAM_KEYS :: Keys {
	what    = "a param",
	allowed = {"id", "type", "enum", "doc", "doc-ref"},
}

@(private)
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

@(private)
identifier :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (id: string, ok: bool) {
	id = expect_scalar(c, n, what) or_return
	if !is_identifier(id) do return "", fail(c, .Invalid, n, "%s %q is not an identifier (lowercase letters, digits and _, starting with a letter)", what, id)
	return id, true
}

@(private)
new_node :: proc(c: ^Compiler, name, ref_name: string) -> ^mdata.Node {
	node := new(mdata.Node, c.allocator)
	node^ = {name = name, ref_name = ref_name}
	return node
}

// Parses and resolves the expression n in scope. An error points at the
// character it is about when the expression is on one line.
@(private)
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
@(private)
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

// A resolved expression made by the compiler, with no text.
@(private)
new_expr :: proc(c: ^Compiler, type: mdata.Expr_Type, variant: mdata.Expr_Variant) -> ^mdata.Expr {
	e := new(mdata.Expr, c.allocator)
	e^ = {type = type, offset = -1, variant = variant}
	return e
}
