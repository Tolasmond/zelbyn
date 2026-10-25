package codegen

import mdata "../metadata"
import "core:fmt"
import "core:strings"

// The procedures that read the plan's sets and fields. Each follows the
// procedure of the decoder (reader/binary_file_reader.odin) that its
// comment names, for one node of the plan: the same reads, the same
// expressions evaluated in the same order, and the same errors recorded at
// the same offsets and paths (data.fail).

// Writes a line of code, indented by depth tabs, into the procedures.
// format is Odin source, whose braces are written as they are; %s, %d and
// %v are replaced by args.
@(private)
line :: proc(g: ^Generator, depth: int, format: string, args: ..any) {
	write_line(&g.out, depth, format, ..args)
}

// As line, into the declarations.
@(private)
decl :: proc(g: ^Generator, depth: int, format: string, args: ..any) {
	write_line(&g.decls, depth, format, ..args)
}

@(private)
write_line :: proc(b: ^strings.Builder, depth: int, format: string, args: ..any) {
	for _ in 0 ..< depth do strings.write_byte(b, '\t')
	escaped, _ := strings.replace_all(format, "{", "{{", context.temp_allocator)
	escaped, _ = strings.replace_all(escaped, "}", "}}", context.temp_allocator)
	fmt.sbprintfln(b, escaped, ..args)
}

// Writes text as // comment lines of at most 76 characters, indented by
// depth tabs; an empty line of text, between two \n, is an empty comment
// line.
@(private)
write_comment :: proc(b: ^strings.Builder, depth: int, text: string) {
	for paragraph, p in strings.split(text, "\n\n", context.temp_allocator) {
		if p > 0 {
			for _ in 0 ..< depth do strings.write_byte(b, '\t')
			strings.write_string(b, "//\n")
		}
		width := 0
		for word in strings.fields(paragraph, context.temp_allocator) {
			if width > 0 && width + 1 + len(word) > 76 {
				strings.write_byte(b, '\n')
				width = 0
			}
			if width == 0 {
				for _ in 0 ..< depth do strings.write_byte(b, '\t')
				strings.write_string(b, "//")
				width = 2
			}
			strings.write_byte(b, ' ')
			strings.write_string(b, word)
			width += 1 + len(word)
		}
		if width > 0 do strings.write_byte(b, '\n')
	}
}

// A new name for a temporary of the procedure being written.
@(private)
temp :: proc(g: ^Generator, prefix: string) -> string {
	g.temps += 1
	return fmt.tprintf("%s%d", prefix, g.temps)
}

// The procedure that reads an instance of set, once its parent has made it.
@(private)
set_proc :: proc(g: ^Generator, set: ^mdata.Node) -> string {
	return ref(set_proc_name(g, set))
}

@(private)
set_proc_name :: proc(g: ^Generator, set: ^mdata.Node) -> string {
	return fmt.tprintf("read_set_%d", g.set_ids[set])
}

@(private = "file")
members_proc :: proc(g: ^Generator, set: ^mdata.Node) -> string {
	return need(g, {name = fmt.tprintf("read_members_%d", g.set_ids[set]), write = write_members, node = set})
}

@(private)
field_proc :: proc(g: ^Generator, node: ^mdata.Node) -> string {
	return need(g, {name = fmt.tprintf("read_field_%d", id_of(g, node)), write = write_field, node = node})
}

@(private)
parse_dispatch :: proc(s: ^Struct_Info) -> string {
	return ref(parse_dispatch_name(s))
}

@(private)
parse_dispatch_name :: proc(s: ^Struct_Info) -> string {
	return fmt.tprintf("parse_%s", s.name)
}

// The struct and field that hold the values of node, a member of a set (a
// child, parse instance or param).
@(private)
field_of :: proc(g: ^Generator, node: ^mdata.Node) -> (s: ^Struct_Info, f: ^Field) {
	s = g.owners[node]
	assert(s != nil, "field_of: not a member of a set")
	for &x in s.fields {
		if x.bit < 0 && x.node.ref_name == node.ref_name && (x.parse >= 0) == (node.pos != nil) && (x.storage == .Param) == node.is_param do return s, &x
	}
	panic("field_of: no field of the member")
}

// The field of bit field b of node.
@(private = "file")
bit_field_of :: proc(s: ^Struct_Info, node: ^mdata.Node, b: int) -> ^Field {
	for &x in s.fields {
		if x.bit == b && x.node.ref_name == node.ref_name do return &x
	}
	panic("bit_field_of: no field of the bit field")
}

// The mask and word of bit i of _have or _read.
@(private)
bit_of :: proc(i: int) -> (word: int, mask: string) {
	return i / 64, fmt.tprintf("0x%x", u64(1) << uint(i % 64))
}

// An Odin expression: whether f, read once, of instance base, has a value.
@(private)
present :: proc(f: ^Field, base: string) -> string {
	switch f.storage {
	case .Plain:
		w, m := bit_of(f.have)
		return fmt.tprintf("%s._have[%d] & %s != 0", base, w, m)
	case .Maybe:
		return fmt.tprintf("%s.%s != nil", base, f.name)
	case .Pointer, .Union:
		return fmt.tprintf("%s.%s != nil", base, f.name)
	case .Param:
		return "true"
	case .Array:
		panic("present: an array")
	}
	unreachable()
}

// An Odin expression: the number of values f of instance base has.
@(private = "file")
value_count :: proc(f: ^Field, base: string) -> string {
	if f.storage == .Array do return fmt.tprintf("len(%s.%s)", base, f.name)
	return fmt.tprintf("(%s ? 1 : 0)", present(f, base))
}

// An Odin expression: the last value of f of instance base, which has one.
@(private = "file")
last_value :: proc(f: ^Field, base: string) -> string {
	switch f.storage {
	case .Array:
		return fmt.tprintf("%s.%s[len(%s.%s) - 1]", base, f.name, base, f.name)
	case .Maybe:
		return fmt.tprintf("%s.%s.?", base, f.name)
	case .Plain, .Pointer, .Union, .Param:
	}
	return fmt.tprintf("%s.%s", base, f.name)
}

// Writes the lines that append value to f of instance base, as the
// decoder's push does; an array that cannot grow is Memory_Limit, as
// reserving room for it is in the decoder.
@(private = "file")
push_value :: proc(g: ^Generator, depth: int, f: ^Field, base, value: string) {
	switch f.storage {
	case .Array:
		line(g, depth, "if _, e := append(&%s.%s, %s); e != nil do return .Memory_Limit", base, f.name, value)
	case .Plain:
		w, m := bit_of(f.have)
		line(g, depth, "%s.%s = %s", base, f.name, value)
		line(g, depth, "%s._have[%d] |= %s", base, w, m)
	case .Maybe, .Pointer, .Union, .Param:
		line(g, depth, "%s.%s = %s", base, f.name, value)
	}
}

// read_set_instance, from the frame on, and choose_order: reads the
// members of an instance of set, which its parent has made and holds.
@(private)
write_set :: proc(g: ^Generator, w: Work) {
	set := w.node
	s := struct_of(g, type_of(g, set))
	id := g.set_ids[set]
	line(g, 0, "// Reads an instance of %s (set %d), which its parent holds.", s.name, id)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, self: ^%s) -> dat.Read_Error {", w.name, s.name)
	line(g, 1, "self._zr.set = %d", id)
	line(g, 1, "dat.push_frame(d, self, %d, dat.parent_frame(d, %d)) or_return", id, set.parent_up)
	if sw := set.order_switch; sw != nil {
		default, has_default := sw.default.?
		line(g, 1, "ctx := dat.Eval_Context{index = -1}")
		line(g, 1, "big, decided := %v, %v", has_default && default == .Big, has_default)
		line(g, 1, "choose: {")
		for c in sw.cases {
			line(g, 2, "{")
			line(g, 3, "is, err := %s(d, &ctx)", ev_proc(g, c.test))
			line(g, 3, "if err != .None do return dat.fail(d, err, d.r.pos)")
			line(g, 3, "if is {")
			line(g, 4, "big, decided = %v, true", c.order == .Big)
			line(g, 4, "break choose")
			line(g, 3, "}")
			line(g, 2, "}")
		}
		line(g, 1, "}")
		line(g, 1, "if !decided do return dat.fail(d, .Undecided_Endianness, d.r.pos)")
		line(g, 1, "if big {")
		line(g, 2, "dat.set_frame_set(d, %d)", g.set_ids[sw.big])
		line(g, 2, "return %s(d, self)", members_proc(g, sw.big))
		line(g, 1, "}")
	}
	line(g, 1, "return %s(d, self)", members_proc(g, set))
	line(g, 0, "}")
	line(g, 0, "")
}

// read_set_instance, from the children on: reads them, keeps the parse
// instances that no expression has read and the stream, when the set keeps
// it, and pops the frame.
@(private = "file")
write_members :: proc(g: ^Generator, w: Work) {
	set := w.node
	s := struct_of(g, type_of(g, set))
	line(g, 0, "%s :: proc(d: ^dat.Decoder, self: ^%s) -> dat.Read_Error {", w.name, s.name)
	for c in set.children do line(g, 1, "%s(d, self) or_return", field_proc(g, c))
	for p, k in set.parse_instances {
		word, mask := bit_of(k)
		line(g, 1, "if self._read[%d] & %s == 0 do dat.keep_pending(d, self, %d, %s, %v, &self._read[%d], %s) or_return", word, mask, k, parse_dispatch(s), p.io != nil, word, mask)
	}
	if set.keeps_stream do line(g, 1, "dat.keep_stream(d, self) or_return")
	line(g, 1, "dat.pop_frame(d)")
	line(g, 1, "return .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// The dispatcher of the parse instances of s's sets, a data.Parse_Proc:
// reads parse instance k as the set the instance was read as.
@(private)
write_parse_dispatch :: proc(g: ^Generator, w: Work) {
	s := w.info
	line(g, 0, "%s :: proc(d: ^dat.Decoder, instance: rawptr, k: int, set: int) -> dat.Read_Error {", w.name)
	line(g, 1, "self := (^%s)(instance)", s.name)
	line(g, 1, "switch set {")
	for set in s.sets {
		line(g, 1, "case %d:", g.set_ids[set])
		line(g, 2, "switch k {")
		for p, k in set.parse_instances {
			word, mask := bit_of(k)
			line(g, 2, "case %d:", k)
			line(g, 3, "self._read[%d] |= %s", word, mask)
			line(g, 3, "return %s(d, self)", field_proc(g, p))
		}
		line(g, 2, "}")
	}
	line(g, 1, "}")
	line(g, 1, `panic("%s: no such parse instance")`, w.name)
	line(g, 0, "}")
	line(g, 0, "")
}

// read_values: reads every value of node, a member of a set, into its
// field.
@(private = "file")
write_field :: proc(g: ^Generator, w: Work) {
	node := w.node
	s, f := field_of(g, node)
	line(g, 0, "// %s", quoted(node.name))
	line(g, 0, "%s :: proc(d: ^dat.Decoder, self: ^%s) -> dat.Read_Error {", w.name, s.name)
	if node.align do line(g, 1, "dat.align_to_byte(&d.r)")
	if node.cond != nil {
		line(g, 1, "{")
		line(g, 2, "ctx := dat.Eval_Context{index = -1}")
		line(g, 2, "read_it, err := %s(d, &ctx)", ev_proc(g, node.cond))
		line(g, 2, "if err != .None do return dat.fail(d, err, d.r.pos)")
		line(g, 2, "if !read_it do return .None")
		line(g, 1, "}")
	}
	if node.pos != nil {
		// io, then pos, in the instance's stream; pos is in io's
		line(g, 1, "{")
		line(g, 2, "stream := dat.current_stream(d)")
		line(g, 2, "err: dat.Read_Error")
		if node.io != nil do line(g, 2, "stream, err = %s(d)", stream_value_proc(g, node.io))
		line(g, 2, "pos := stream.r.pos")
		if !node.at_stream_pos {
			line(g, 2, "if err == .None {")
			line(g, 3, "ctx := dat.Eval_Context{index = -1}")
			line(g, 3, "n: i128")
			line(g, 3, "n, err = %s(d, &ctx)", ev_proc(g, node.pos))
			line(g, 3, "if err == .None do pos, err = dat.int_size(n)")
			line(g, 2, "}")
		}
		line(g, 2, "if err == .None && (pos < 0 || pos > len(stream.r.data)) do err = .Offset_Out_Of_Range")
		line(g, 2, "if err != .None {")
		line(g, 3, "append(&d.path, dat.Path_Segment{%s, 0})", quoted(node.name))
		line(g, 3, "return dat.fail(d, err, d.r.pos)")
		line(g, 2, "}")
		if node.io != nil do line(g, 2, "dat.push_stream(d, stream) or_return")
		line(g, 2, "d.r.pos = pos")
		line(g, 2, "dat.align_to_byte(&d.r)")
		line(g, 1, "}")
	}

	element := need(g, {name = fmt.tprintf("read_element_%d", id_of(g, node)), write = write_element, node = node})
	switch c in node.count {
	case mdata.Fixed_Count:
		line(g, 1, "count := %d", c.n)
	case mdata.Rule_Count:
		line(g, 1, "count: int")
		line(g, 1, "{")
		line(g, 2, "ctx := dat.Eval_Context{index = -1}")
		line(g, 2, "v, err := %s(d, &ctx)", ev_proc(g, c.expr))
		line(g, 2, "n: int")
		line(g, 2, "if err == .None do n, err = dat.int_size(v)")
		line(g, 2, "if err != .None do return dat.fail(d, err, d.r.pos)")
		line(g, 2, "// a negative count reads no elements, as in Kaitai's runtimes")
		line(g, 2, "count = max(n, 0)")
		line(g, 1, "}")
	case mdata.Marker_Count:
		b := strings.builder_make(context.temp_allocator)
		for m, i in c.markers {
			if i > 0 do strings.write_string(&b, " && ")
			fmt.sbprintf(&b, "dat.marker_matches(&d.r, %d, .%v, .%v, %d)", m.offset, m.type, m.order, m.value)
		}
		if len(c.markers) == 0 do strings.write_string(&b, "true")
		line(g, 1, "count := %s ? 1 : 0", strings.to_string(b))
	case mdata.Repeat_Count:
		// read_repeat
		line(g, 1, "for {")
		line(g, 2, "value, peek_err := dat.peek_integer_at(&d.r, d.r.pos, .%v, .%v)", c.type, c.order)
		if c.until {
			line(g, 2, "if peek_err != .None do return dat.fail(d, .Unexpected_EOF, d.r.pos)")
			line(g, 2, "if value == %d do return .None", c.value)
		} else {
			line(g, 2, "if peek_err != .None || value != %d do return .None", c.value)
		}
		line(g, 2, "n := %s", value_count(f, "self"))
		line(g, 2, "start, start_bits := d.r.pos, dat.bit_pos(&d.r)")
		line(g, 2, "%s(d, self, n) or_return", element)
		line(g, 2, "if dat.bit_pos(&d.r) == start_bits {")
		line(g, 3, "append(&d.path, dat.Path_Segment{%s, n})", quoted(node.name))
		line(g, 3, "return dat.fail(d, .No_Progress, start)")
		line(g, 2, "}")
		line(g, 1, "}")
		line(g, 0, "}")
		line(g, 0, "")
		return
	case mdata.Eos_Count:
		line(g, 1, "for i := 0; !dat.at_eof(&d.r); i += 1 {")
		line(g, 2, "start, start_bits := d.r.pos, dat.bit_pos(&d.r)")
		line(g, 2, "%s(d, self, i) or_return", element)
		line(g, 2, "if dat.bit_pos(&d.r) == start_bits {")
		line(g, 3, "append(&d.path, dat.Path_Segment{%s, i})", quoted(node.name))
		line(g, 3, "return dat.fail(d, .No_Progress, start)")
		line(g, 2, "}")
		line(g, 1, "}")
		line(g, 1, "return .None")
		line(g, 0, "}")
		line(g, 0, "")
		return
	case mdata.Until_Count:
		// read is the count of elements read once element i is: _index, as
		// the official compiler's JavaScript, C++ and Java increment it
		// before the test; _ is the element just read, and has no value when
		// a switch-on chose no case
		elem := f.elem
		line(g, 1, "for read := 1;; read += 1 {")
		line(g, 2, "i := read - 1")
		line(g, 2, "start, start_bits := d.r.pos, dat.bit_pos(&d.r)")
		line(g, 2, "n := %s", value_count(f, "self"))
		line(g, 2, "%s(d, self, i) or_return", element)
		line(g, 2, "done: bool")
		line(g, 2, "err: dat.Read_Error")
		line(g, 2, "if %s > n {", value_count(f, "self"))
		line(g, 3, "element: %s = %s", elem, last_value(f, "self"))
		line(g, 3, "ctx := dat.Eval_Context{index = read, element = &element}")
		line(g, 3, "done, err = %s(d, &ctx)", ev_proc(g, c.expr))
		line(g, 2, "} else {")
		line(g, 3, "ctx := dat.Eval_Context{index = read}")
		line(g, 3, "done, err = %s(d, &ctx)", ev_proc(g, c.expr))
		line(g, 2, "}")
		line(g, 2, "if err != .None do return dat.fail(d, err, d.r.pos)")
		line(g, 2, "if done do return .None")
		line(g, 2, "if dat.bit_pos(&d.r) == start_bits {")
		line(g, 3, "append(&d.path, dat.Path_Segment{%s, i})", quoted(node.name))
		line(g, 3, "return dat.fail(d, .No_Progress, start)")
		line(g, 2, "}")
		line(g, 1, "}")
		line(g, 0, "}")
		line(g, 0, "")
		return
	}

	// elements that consume input cannot outnumber the bytes left, so room
	// is made for a larger count, which may come from the input, as it is
	// read
	if f.storage == .Array {
		line(g, 1, "if count <= len(d.r.data) - d.r.pos {")
		line(g, 2, "if e := reserve(&self.%s, count); e != nil do return .Memory_Limit", f.name)
		line(g, 1, "}")
	}
	line(g, 1, "for i in 0 ..< count do %s(d, self, i) or_return", element)
	line(g, 1, "return .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// read_element: reads element index of node, a member of a set, with its
// bit fields, and checks it.
@(private = "file")
write_element :: proc(g: ^Generator, w: Work) {
	node := w.node
	s, f := field_of(g, node)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, self: ^%s, index: int) -> dat.Read_Error {", w.name, s.name)
	line(g, 1, "// on error the segment is left pushed; fail has already copied the path")
	line(g, 1, "dat.push_path(d, %s, index) or_return", quoted(node.name))
	checked := node.valid != nil
	for bit in node.bits do checked ||= bit.valid != nil
	if checked do line(g, 1, "start := d.r.pos")
	if node.type == .Set {
		if node.valid != nil do line(g, 1, "n := %s", value_count(f, "self"))
		line(g, 1, "%s(d, self, index) or_return", need(g, {name = fmt.tprintf("read_instance_%d", id_of(g, node)), write = write_instance, node = node}))
		if node.valid != nil {
			// a switch-on that chooses no case adds no value
			line(g, 1, "if %s > n {", value_count(f, "self"))
			line(g, 2, "value := %s", last_value(f, "self"))
			line(g, 2, "if e := %s(d, value, index); e != .None do return %s(d, e, start, value, index)", check_proc(g, node, f.elem), fail_check_proc(g, node, f.elem))
			line(g, 1, "}")
		}
		line(g, 1, "dat.pop_path(d)")
		line(g, 1, "return .None")
		line(g, 0, "}")
		line(g, 0, "")
		return
	}

	line(g, 1, "value := %s(d, index) or_return", scalar_proc(g, node))
	push_value(g, 1, f, "self", "value")
	if node.valid != nil {
		line(g, 1, "if e := %s(d, value, index); e != .None do return %s(d, e, start, value, index)", check_proc(g, node, f.elem), fail_check_proc(g, node, f.elem))
	}
	line(g, 1, "dat.pop_path(d)")
	for bit, b in node.bits {
		bf := bit_field_of(s, node, b)
		line(g, 1, "{")
		line(g, 2, "bits := %s(dat.bits_of(%s, %d, %d))", bf.elem, raw_bits(f.elem, "value"), bit.low, bit.high)
		push_value(g, 2, bf, "self", "bits")
		if bit.valid != nil {
			line(g, 2, "if e := %s(d, bits, index); e != .None {", bit_check_proc(g, node, b))
			line(g, 3, "append(&d.path, dat.Path_Segment{%s, index})", quoted(bit.name))
			line(g, 3, "return %s(d, e, start, bits, index)", bit_fail_check_proc(g, node, b))
			line(g, 2, "}")
		}
		line(g, 1, "}")
	}
	line(g, 1, "return .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// value, of integer type t, reinterpreted as unsigned, as a u64.
@(private = "file")
raw_bits :: proc(t: string, value: string) -> string {
	switch t {
	case "i8":
		return fmt.tprintf("u64(u8(%s))", value)
	case "i16":
		return fmt.tprintf("u64(u16(%s))", value)
	case "i32":
		return fmt.tprintf("u64(u32(%s))", value)
	}
	return fmt.tprintf("u64(%s)", value)
}

// read_instance: reads instance index of node, a set field, as the set its
// switch-on chooses, if it has one: from a substream when node has a length
// or a terminator, with that set's arguments. A switch-on that chooses no
// set reads nothing, or with a length, its bytes; one that chooses a case
// that is not a set reads a value of the case's type.
@(private = "file")
write_instance :: proc(g: ^Generator, w: Work) {
	node := w.node
	s, f := field_of(g, node)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, self: ^%s, index: int) -> dat.Read_Error {", w.name, s.name)
	sw := node.switch_on
	if sw == nil {
		line(g, 1, "return %s(d, self, index)", into_proc(g, node, node, 0))
		line(g, 0, "}")
		line(g, 0, "")
		return
	}

	line(g, 1, "choice := %d", mdata.DEFAULT_CASE)
	line(g, 1, "{")
	line(g, 2, "ctx := dat.Eval_Context{index = index}")
	line(g, 2, "on, err := %s(d, &ctx)", ev_proc(g, sw.on))
	line(g, 2, "if err != .None do return dat.fail(d, err, d.r.pos)")
	// the first case whose value equals on
	line(g, 2, "switch on {")
	seen := make(map[string]bool, context.temp_allocator)
	for c, i in sw.cases {
		key: string
		#partial switch sw.on.type {
		case .String:
			key = quoted(c.text)
		case .Bool:
			key = c.value != 0 ? "true" : "false"
		case:
			key = fmt.tprintf("%v", c.value)
		}
		if seen[key] do continue
		seen[key] = true
		line(g, 2, "case %s:", key)
		line(g, 3, "choice = %d", i)
	}
	line(g, 2, "}")
	line(g, 1, "}")

	read_case :: proc(g: ^Generator, f: ^Field, node, c: ^mdata.Node, choice: int) {
		if c.type == .Set {
			line(g, 2, "return %s(d, self, index)", into_proc(g, node, c, choice))
			return
		}
		// read_case_value
		line(g, 2, "value := %s(d, index) or_return", scalar_proc(g, c))
		push_value(g, 2, f, "self", "value")
		line(g, 2, "return .None")
	}
	line(g, 1, "switch choice {")
	for c, i in sw.cases {
		line(g, 1, "case %d:", i)
		read_case(g, f, node, c.node, i)
	}
	line(g, 1, "}")
	if sw.default != nil {
		read_case(g, f, node, sw.default, mdata.DEFAULT_CASE)
	} else if node.length != nil {
		// read_unchosen: the bytes of the length, as they are
		line(g, 1, "start := d.r.pos")
		line(g, 1, "n, err := %s(d, index)", length_proc(g, node))
		line(g, 1, "if err != .None do return dat.fail(d, err, start)")
		line(g, 1, "bytes: []byte")
		line(g, 1, "bytes, err = dat.read_bytes(&d.r, n)")
		line(g, 1, "if err != .None do return dat.fail(d, err, start)")
		if node.process == .Zlib {
			line(g, 1, "bytes, err = dat.inflate(bytes, context.allocator)")
			line(g, 1, "if err != .None do return dat.fail(d, err, start)")
		}
		push_value(g, 1, f, "self", "bytes")
		line(g, 1, "return .None")
	} else {
		line(g, 1, "return .None")
	}
	line(g, 0, "}")
	line(g, 0, "")
}

// The procedure that reads instance index of node, a set field, as set,
// recording choice, with set's arguments, and from a substream when node
// has a length or a terminator.
@(private = "file")
into_proc :: proc(g: ^Generator, node, set: ^mdata.Node, choice: int) -> string {
	return need(g, {name = fmt.tprintf("read_into_%d_%d", id_of(g, node), g.set_ids[set]), write = write_into, node = node, expr = nil, k = choice, info = struct_of(g, type_of(g, set))}) if set in g.set_ids else ""
}

@(private = "file")
write_into :: proc(g: ^Generator, w: Work) {
	node := w.node
	s, f := field_of(g, node)
	set: ^mdata.Node
	// the set of the case, or node itself
	if sw := node.switch_on; sw != nil {
		set = w.k == mdata.DEFAULT_CASE ? sw.default : sw.cases[w.k].node
	} else {
		set = node
	}
	t := struct_of(g, type_of(g, set))
	line(g, 0, "%s :: proc(d: ^dat.Decoder, self: ^%s, index: int) -> dat.Read_Error {", w.name, s.name)
	substream := node.length != nil || node.terminator != nil
	if substream {
		line(g, 1, "start := d.r.pos")
		line(g, 1, "bytes := %s(d, index) or_return", bytes_proc(g, node))
	}
	// as in Kaitai, evaluated in node's stream, after the bytes of the
	// substream
	for a, k in set.args {
		line(g, 1, "arg%d: %s", k, expr_type(a.type))
		line(g, 1, "{")
		line(g, 2, "ctx := dat.Eval_Context{index = index}")
		line(g, 2, "err: dat.Read_Error")
		line(g, 2, "arg%d, err = %s(d, &ctx)", k, ev_proc(g, a))
		line(g, 2, "if err != .None do return dat.fail(d, err, d.r.pos)")
		line(g, 1, "}")
	}
	if substream {
		line(g, 1, "// the parent's stream is already past the substream, whatever the instance consumes")
		line(g, 1, "dat.push_substream(d, bytes, start) or_return")
		line(g, 1, "defer dat.pop_stream(d)")
	}
	line(g, 1, "instance, alloc_err := new(%s)", t.name)
	line(g, 1, "if alloc_err != nil do return .Memory_Limit")
	line(g, 1, "instance._zr.choice = %d", w.k)
	push_value(g, 1, f, "self", "instance")
	for p, k in set.params {
		_, pf := field_of(g, p)
		value := fmt.tprintf("arg%d", k)
		if p.type == .Set do value = fmt.tprintf("(%s)(arg%d)", pf.elem, k)
		line(g, 1, "instance.%s = %s", pf.name, value)
	}
	line(g, 1, "return %s(d, instance)", set_proc(g, set))
	line(g, 0, "}")
	line(g, 0, "")
}

// read_scalar: the procedure that reads element index of node, a field
// that is not a set.
@(private)
scalar_proc :: proc(g: ^Generator, node: ^mdata.Node) -> string {
	return need(g, {name = fmt.tprintf("read_scalar_%d", id_of(g, node)), write = write_scalar, node = node})
}

@(private = "file")
write_scalar :: proc(g: ^Generator, w: Work) {
	node := w.node
	t := value_type(node)
	line(g, 0, "%s :: proc(d: ^dat.Decoder, index: int) -> (value: %s, err: dat.Read_Error) {", w.name, t)
	#partial switch node.type {
	case .Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64, .UInt64, .Float32, .Float64:
		line(g, 1, "start := d.r.pos")
		line(g, 1, "value, err = dat.read(&d.r, %s, .%v)", t, node.order)
	case .String:
		line(g, 1, "bytes := %s(d, index) or_return", bytes_proc(g, node))
		if node.encoding == .None {
			line(g, 1, "return string(bytes), .None")
		} else {
			line(g, 1, "return dat.decode_text(bytes, .%v, context.allocator)", node.encoding)
		}
		line(g, 0, "}")
		line(g, 0, "")
		return
	case .Blob:
		line(g, 1, "return %s(d, index)", bytes_proc(g, node))
		line(g, 0, "}")
		line(g, 0, "")
		return
	case .Bool, .Bits:
		line(g, 1, "start := d.r.pos")
		line(g, 1, "bits: u64")
		line(g, 1, "bits, err = dat.read_bits(&d.r, %d, .%v)", node.width, node.order)
		line(g, 1, "value = %s", node.type == .Bool ? "bits != 0" : fmt.tprintf("%s(bits)", t))
	case:
		fail(g, "%s: a field of type %v cannot be read as a value", node.name, node.type)
	}
	line(g, 1, "if err != .None do return {}, dat.fail(d, err, start)")
	line(g, 1, "return value, .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// element_bytes: the procedure that reads the bytes of element index of
// node, a String or Blob, or of the substream of instance index of a set:
// those of its length, without the pad_right at their end and cut at its
// terminator, or else those up to its terminator.
@(private = "file")
bytes_proc :: proc(g: ^Generator, node: ^mdata.Node) -> string {
	return need(g, {name = fmt.tprintf("read_bytes_%d", id_of(g, node)), write = write_bytes, node = node})
}

@(private = "file")
write_bytes :: proc(g: ^Generator, w: Work) {
	node := w.node
	line(g, 0, "%s :: proc(d: ^dat.Decoder, index: int) -> (bytes: []byte, err: dat.Read_Error) {", w.name)
	line(g, 1, "start := d.r.pos")
	if node.length == nil {
		t := node.terminator.?
		line(g, 1, "bytes, err = dat.read_bytes_term(&d.r, %d, %v, %v, %v)", t.value, t.include, t.consume, t.eos_error)
		line(g, 1, "if err != .None do return nil, dat.fail(d, err, start)")
	} else {
		line(g, 1, "n: int")
		line(g, 1, "n, err = %s(d, index)", length_proc(g, node))
		line(g, 1, "if err != .None do return nil, dat.fail(d, err, start)")
		line(g, 1, "bytes, err = dat.read_bytes(&d.r, n)")
		line(g, 1, "if err != .None do return nil, dat.fail(d, err, start)")
		t, terminated := node.terminator.?
		if node.pad_right != nil || terminated {
			pad := "nil"
			if p, padded := node.pad_right.?; padded do pad = fmt.tprintf("%d", p)
			term := terminated ? fmt.tprintf("%d", t.value) : "nil"
			line(g, 1, "bytes = dat.trim(bytes, %s, %s, %v)", pad, term, terminated && t.include)
		}
	}
	if node.process == .Zlib {
		line(g, 1, "bytes, err = dat.inflate(bytes, context.allocator)")
		line(g, 1, "if err != .None do return nil, dat.fail(d, err, start)")
	}
	line(g, 1, "return bytes, .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// byte_length: the procedure that gives the byte length of element index
// of node: Invalid_Length when it is negative.
@(private = "file")
length_proc :: proc(g: ^Generator, node: ^mdata.Node) -> string {
	return need(g, {name = fmt.tprintf("length_%d", id_of(g, node)), write = write_length, node = node})
}

@(private = "file")
write_length :: proc(g: ^Generator, w: Work) {
	node := w.node
	line(g, 0, "%s :: proc(d: ^dat.Decoder, index: int) -> (n: int, err: dat.Read_Error) {", w.name)
	switch l in node.length {
	case mdata.Fixed_Length:
		line(g, 1, "n = %d", l.n)
	case mdata.Rule_Length:
		line(g, 1, "ctx := dat.Eval_Context{index = index}")
		line(g, 1, "v := %s(d, &ctx) or_return", ev_proc(g, l.expr))
		line(g, 1, "n = dat.int_size(v) or_return")
	case mdata.Eos_Length:
		line(g, 1, "n = len(d.r.data) - d.r.pos")
	}
	line(g, 1, "if n < 0 do return 0, .Invalid_Length")
	line(g, 1, "return n, .None")
	line(g, 0, "}")
	line(g, 0, "")
}

// node's name as an Odin string literal.
@(private)
quoted :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]byte)s {
		switch {
		case c == '"' || c == '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case c >= 0x20 && c < 0x7f:
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "\\x%02x", c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
