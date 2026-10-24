package ksy

import "../file"
import mdata "../metadata"
import yml "../yaml"
import "core:encoding/endian"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private)
new_schema :: proc(c: ^Compiler, path: string) -> ^Schema {
	s := new(Schema, c.scratch)
	s.path = path
	return s
}

// Parses src, the text of c.schema, in scratch, and returns the root of its
// document.
@(private)
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

@(private)
compile_schema :: proc(c: ^Compiler, root: ^yml.Node, ff: ^mdata.File_Format) -> bool {
	top := load_schema(c, root) or_return
	name := display_name(c, get(root, "meta"), top.name) or_return
	node := new_node(c, name, top.name)
	node.type = .Set
	node.count = mdata.Fixed_Count{n = 1}

	ff.name = node.name
	ff.root = node
	c.root = node
	// nothing is read before the root that its order could depend on
	if declares_endian_switch(top) do return fail(c, .Unsupported, top.meta.endian_switch, "endian: switch-on is not supported on the top-level type of the schema compiled, except in an imported schema")
	arg_sets := root_arg_sets(c, top) or_return
	compile_fields(c, top, node, {node}, arg_sets) or_return
	if len(node.params) > 0 {
		args := make([]^mdata.Expr, len(node.params), c.allocator)
		for p, k in node.params {
			type: mdata.Expr_Type
			#partial switch p.type {
			case .Int64:
				type = .Int
			case .Bool:
				type = .Bool
			case .Blob:
				type = .Bytes
			case .String:
				type = .String
			case .Set:
				type = .Struct
			}
			args[k] = new_expr(c, type, mdata.Root_Arg{k, arg_sets == nil ? nil : arg_sets[k]})
		}
		node.args = args
	}

	// the instances that nothing referred to, now that every field they
	// can refer to is compiled, as in Kaitai, where any instance can refer
	// to any field; compiling them can put off others
	for i := 0; i < len(c.deferred); i += 1 {
		item := c.deferred[i]
		pending := item.value != nil ? item.value.expr == nil : item.parse.pos == nil
		if pending do compile_deferred(c, item) or_return
	}

	// _io of a param is the stream of its argument's instance
	for pa in c.param_args {
		if pa.param.keeps_stream do pa.set.keeps_stream = true
	}

	// a reused set's expressions are all compiled; its fields inside it
	// are read as it is
	for st in c.type_defs {
		if st.set.keeps_stream do for field in st.reused_by do field.keeps_stream = true
		if st.reused_deeper && st.escape != nil {
			c.schema = st.escape_schema
			return fail(c, .Unsupported, st.escape, "%s: type %s contains itself, so neither it nor the types in it can refer to the members of the sets enclosing it, other than through the _root of the schema decoded, or in a value instance, to an imported schema's _root, unless a parent gives its fields inside it the same ones (parent: _parent)", st.escape_what, st.td.name)
		}
	}
	return true
}

// The sets that the arguments of the params of top, the top-level type of
// the schema compiled, are read as (Root_Arg): for a param of a user type,
// its type, compiled as the instance the caller of Kaitai's runtimes makes
// of it from bytes would be, with no _parent, and no _root but at the top
// level of its schema; nil for any other param, or when there is none.
@(private = "file")
root_arg_sets :: proc(c: ^Compiler, top: ^Type_Def) -> (arg_sets: []^mdata.Node, ok: bool) {
	for p, k in top.params {
		if p.type != .Set do continue
		if arg_sets == nil do arg_sets = make([]^mdata.Node, len(top.params), c.allocator)
		user := find_type(top, p.type_name)
		if user == nil do return nil, fail(c, .Invalid, p.id, "param %s: unknown type %s", p.id.text, p.type_name)
		if len(user.params) > 0 do return nil, fail(c, .Unsupported, p.id, "param %s: its type %s has params, which nothing can give on the top-level type of the schema compiled", p.id.text, p.type_name)
		set := new_node(c, p.id.text, p.id.text)
		set.type = .Set
		set.count = mdata.Fixed_Count{n = 1}
		// a type of this schema too has no _root there (chain_of)
		if user.parent != nil && user.schema == c.schema do append(&c.rootless, set)
		compile_type(c, user, set, {}) or_return
		arg_sets[k] = set
	}
	return arg_sets, true
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
@(private)
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

@(private)
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
@(private)
encoding :: proc(c: ^Compiler, n: ^yml.Node) -> (e: mdata.Encoding, ok: bool) {
	name := expect_scalar(c, n, "encoding") or_return
	if e, ok = encoding_named(name); ok do return
	return .None, fail(c, .Unsupported, n, "encoding %q is not supported; only ASCII, UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ISO-8859-1, windows-1251, windows-1252 and IBM437 are", name)
}

// The encoding called name or one of its aliases, in any case
// (expr.Scope.encoding); ok is false for one the decoder does not support.
@(private)
encoding_named :: proc(name: string) -> (e: mdata.Encoding, ok: bool) {
	for known in ENCODINGS {
		for alias in known.names {
			if strings.equal_fold(alias, name) do return known.encoding, true
		}
	}
	return
}

// The Kaitai Struct version zelbyn follows: that of the official compiler
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
		if v > follows[i] do return fail(c, .Unsupported, n, "ks-version %s is newer than %v.%v, the Kaitai version zelbyn follows", text, follows[0], follows[1])
	}
	return true
}
