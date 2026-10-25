package codegen

import mdata "../metadata"
import "core:fmt"
import "core:strings"

// The declarations a user of the package calls and reads: Args, read and
// write_text, the structs, and the procedures that dump them as package
// dump's write_text writes a tree.

@(private)
write_api :: proc(g: ^Generator) -> bool {
	root := g.format.root
	r := struct_of(g, root.type_info)
	decl(g, 0, "// The arguments of the params of %s, the schema's top-level type: an", r.name)
	decl(g, 0, "// integer, a bool, bytes or a string, as each param's type is, and for a")
	decl(g, 0, "// user type, the bytes that read reads an instance of it from.")
	decl(g, 0, "Args :: struct {")
	for p in root.params {
		t: string
		#partial switch p.type {
		case .Int64:
			t = "i64"
		case .Bool:
			t = "bool"
		case .Blob, .Set:
			t = "[]byte"
		case .String:
			t = "string"
		case:
			return fail(g, "param %s of the top-level type has an unknown type", p.name)
		}
		decl(g, 1, "%s: %s,", identifier(p.ref_name), t)
	}
	decl(g, 0, "}")
	decl(g, 0, "")

	decl(g, 0, "// Decodes data as an instance of %s, whose params args gives, as zelbyn", r.name)
	decl(g, 0, "// decodes it with the schema: the same values, or the same error, at the")
	decl(g, 0, "// same offset and path, but with no limit on nesting, memory or steps.")
	decl(g, 0, "// Strings and byte arrays are views of data, and of args, but for those")
	decl(g, 0, "// decoded or made by expressions; they, the instances and the arrays are")
	decl(g, 0, "// allocated with context.allocator, which an arena suits. On error, root")
	decl(g, 0, "// may be partly read, and err, which destroy_parse_error frees, says where.")
	decl(g, 0, "read :: proc(data: []byte, args := Args{}) -> (root: ^%s, err: dat.Parse_Error) {", r.name)
	decl(g, 1, "d: dat.Decoder")
	decl(g, 1, "dat.decoder_init(&d, data)")
	decl(g, 1, "defer dat.decoder_destroy(&d)")
	for p, k in root.params {
		if p.type != .Set do continue
		set := root.args[k].variant.(mdata.Root_Arg).set
		t := struct_of(g, set.type_info)
		// the bytes of the argument, read in a stream of their own, as an
		// instance of its type
		decl(g, 1, "arg%d: ^%s", k, t.name)
		decl(g, 1, "{")
		decl(g, 2, "r := d.r")
		decl(g, 2, "dat.reader_init(&d.r, args.%s)", identifier(p.ref_name))
		decl(g, 2, "e := %s(&d, &arg%d)", top_proc(g, set), k)
		decl(g, 2, "d.r = r")
		decl(g, 2, "if e != .None {")
		decl(g, 3, "if d.err.kind == .None do dat.fail(&d, e, d.r.pos)")
		decl(g, 3, "return nil, d.err")
		decl(g, 2, "}")
		decl(g, 1, "}")
	}
	decl(g, 1, "e := dat.push_path(&d, %s, 0)", quoted(root.name))
	decl(g, 1, "if e == .None {")
	decl(g, 2, "instance, alloc_err := new(%s)", r.name)
	decl(g, 2, "if alloc_err != nil {")
	decl(g, 3, "e = .Memory_Limit")
	decl(g, 2, "} else {")
	decl(g, 3, "root = instance")
	for p, k in root.params {
		_, f := field_of(g, p)
		value: string
		#partial switch p.type {
		case .Int64:
			value = fmt.tprintf("i128(args.%s)", identifier(p.ref_name))
		case .Set:
			value = fmt.tprintf("arg%d", k)
		case:
			value = fmt.tprintf("args.%s", identifier(p.ref_name))
		}
		decl(g, 3, "instance.%s = %s", f.name, value)
	}
	decl(g, 3, "e = %s(&d, instance)", set_proc(g, root))
	decl(g, 3, "if e == .None do dat.pop_path(&d)")
	decl(g, 2, "}")
	decl(g, 1, "}")
	decl(g, 1, "if e == .None do e = dat.read_pending(&d)")
	decl(g, 1, "if e != .None && d.err.kind == .None do dat.fail(&d, e, d.r.pos)")
	decl(g, 1, "return root, d.err")
	decl(g, 0, "}")
	decl(g, 0, "")

	decl(g, 0, "// Writes root as zelbyn's text dump (--dump tree) writes it: one line for")
	decl(g, 0, "// each value, its path, \" = \" and the value.")
	decl(g, 0, "write_text :: proc(w: io.Writer, root: ^%s) -> io.Error {", r.name)
	decl(g, 1, "path := strings.builder_make()")
	decl(g, 1, "defer strings.builder_destroy(&path)")
	decl(g, 1, "dat.dump_path(&path, 0, %s, 0)", quoted(root.name))
	decl(g, 1, "return %s(w, &path, root)", dump_proc(r))
	decl(g, 0, "}")
	decl(g, 0, "")
	return true
}

// The procedure that reads an instance of set, which has no params, as the
// root's argument of a user type is read, into out.
@(private = "file")
top_proc :: proc(g: ^Generator, set: ^mdata.Node) -> string {
	return need(g, {name = fmt.tprintf("read_top_%d", g.set_ids[set]), write = write_top, node = set})
}

@(private = "file")
write_top :: proc(g: ^Generator, w: Work) {
	set := w.node
	t := struct_of(g, set.type_info)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, out: ^^%s) -> dat.Read_Error {", w.name, t.name)
	line(g, 1, "dat.push_path(d, %s, 0) or_return", quoted(set.name))
	line(g, 1, "instance, alloc_err := new(%s)", t.name)
	line(g, 1, "if alloc_err != nil do return .Memory_Limit")
	line(g, 1, "out^ = instance")
	line(g, 1, "%s(d, instance) or_return", set_proc(g, set))
	line(g, 1, "dat.pop_path(d)")
	line(g, 1, "return .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// The Odin type of f.
@(private = "file")
field_type :: proc(f: Field) -> string {
	switch f.storage {
	case .Maybe:
		return fmt.tprintf("Maybe(%s)", f.elem)
	case .Array:
		return fmt.tprintf("[dynamic]%s", f.elem)
	case .Plain, .Pointer, .Union, .Param:
	}
	return f.elem
}

@(private)
write_struct :: proc(g: ^Generator, s: ^Struct_Info) -> bool {
	path := make([dynamic]string, context.temp_allocator)
	for t := s.info; t != nil; t = t.outer do append(&path, t.name)
	b := strings.builder_make(context.temp_allocator)
	#reverse for p, i in path {
		strings.write_string(&b, p)
		if i > 0 do strings.write_string(&b, "::")
	}
	decl(g, 0, "// An instance of the type %s. A field read once that can have no value is", strings.to_string(b))
	decl(g, 0, "// a Maybe, or nil; a repeated field is an array, of its values in order.")
	decl(g, 0, "%s :: struct {", s.name)
	decl(g, 1, "_zr: dat.Header,")
	for f in s.fields {
		comment := ""
		if f.parse >= 0 do comment = " // a parse instance"
		if f.storage == .Param do comment = " // a param"
		if f.display != f.name do comment = fmt.tprintf("%s (%s)", comment == "" ? " //" : comment, f.display)
		decl(g, 1, "%s: %s,%s", f.name, field_type(f), comment)
	}
	if s.have_words > 0 do decl(g, 1, "_have: [%d]u64, // which fields read once have a value", s.have_words)
	if s.read_words > 0 do decl(g, 1, "_read: [%d]u64, // which parse instances have been read", s.read_words)
	decl(g, 0, "}")
	decl(g, 0, "")
	return true
}

@(private)
dump_proc :: proc(s: ^Struct_Info) -> string {
	return ref(dump_proc_name(s))
}

@(private)
dump_proc_name :: proc(s: ^Struct_Info) -> string {
	return fmt.tprintf("dump_%s", s.name)
}

// write_text_array, for the fields of an instance of s: each child's
// values, followed by its bit fields', then each parse instance's.
@(private)
write_dump :: proc(g: ^Generator, w: Work) {
	s := w.info
	line(g, 0, "%s :: proc(w: io.Writer, path: ^strings.Builder, self: ^%s) -> io.Error {", w.name, s.name)
	line(g, 1, "n := strings.builder_len(path^)")
	line(g, 1, "defer resize(&path.buf, n)")
	for &f in s.fields {
		name := quoted(f.display)
		switch f.storage {
		case .Param:
			continue
		case .Array:
			line(g, 1, "for v, i in self.%s {", f.name)
			line(g, 2, "dat.dump_path(path, n, %s, i)", name)
			dump_value(g, 2, &f, "v")
			line(g, 1, "}")
		case .Plain:
			line(g, 1, "if %s {", present(&f, "self"))
			line(g, 2, "dat.dump_path(path, n, %s, 0)", name)
			dump_value(g, 2, &f, fmt.tprintf("self.%s", f.name))
			line(g, 1, "}")
		case .Maybe:
			line(g, 1, "if v, ok := self.%s.?; ok {", f.name)
			line(g, 2, "dat.dump_path(path, n, %s, 0)", name)
			dump_value(g, 2, &f, "v")
			line(g, 1, "}")
		case .Pointer, .Union:
			line(g, 1, "if self.%s != nil {", f.name)
			line(g, 2, "dat.dump_path(path, n, %s, 0)", name)
			dump_value(g, 2, &f, fmt.tprintf("self.%s", f.name))
			line(g, 1, "}")
		}
	}
	line(g, 1, "return .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// Writes the lines that dump v, a value of f, whose path is set: the
// fields of an instance, or a line.
@(private = "file")
dump_value :: proc(g: ^Generator, depth: int, f: ^Field, v: string) {
	if f.bit < 0 && f.node.switch_on != nil && is_union(g, f.node) {
		line(g, depth, "switch x in %s {", v)
		for variant in switch_variants(g, f.node) {
			line(g, depth, "case %s:", variant)
			dump_one(g, depth + 1, variant, "x")
		}
		line(g, depth, "}")
		return
	}
	dump_one(g, depth, f.elem, v)
}

@(private = "file")
dump_one :: proc(g: ^Generator, depth: int, elem, v: string) {
	if strings.has_prefix(elem, "^") {
		line(g, depth, "%s(w, path, %s) or_return", ref(fmt.tprintf("dump_%s", elem[1:])), v)
		return
	}
	line(g, depth, "dat.write_dump_start(w, path) or_return")
	switch elem {
	case "i8", "i16", "i32", "i64":
		line(g, depth, "dat.write_int(w, i64(%s)) or_return", v)
	case "u8", "u16", "u32", "u64":
		line(g, depth, "dat.write_uint(w, u64(%s)) or_return", v)
	case "f32":
		line(g, depth, "dat.write_f32(w, %s) or_return", v)
	case "f64":
		line(g, depth, "dat.write_f64(w, %s) or_return", v)
	case "bool":
		line(g, depth, "dat.write_bool(w, %s) or_return", v)
	case "string":
		line(g, depth, "dat.write_string(w, %s) or_return", v)
	case "[]byte":
		line(g, depth, "dat.write_blob(w, %s) or_return", v)
	case:
		fail(g, "a value of type %s cannot be dumped", elem)
	}
	line(g, depth, "io.write_byte(w, '\\n') or_return")
}
