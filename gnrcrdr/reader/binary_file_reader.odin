package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:os"

// Reads the file name into tree's arena, closes it, and decodes it into
// tree, which must be zero or destroyed. Strings and blobs are views of that
// copy, so the tree owns its input: it needs neither the file nor the
// schema once read returns.
@(require_results)
read :: proc(name: string, format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> (consumed: int, err: Parse_Error) {
	assert(tree.arena.block == nil && tree.root == nil, "read: tree must be zero or destroyed")
	f, open_err := os.open(name)
	if open_err != nil {
		return 0, Parse_Error{kind = .File_Read_Failed, os_error = open_err}
	}
	// a size that cannot be found leaves the arena at its default first block
	size, _ := os.file_size(f)
	init_arena(tree, int(size))
	data, read_err := os.read_entire_file(f, fld.tree_arena_allocator(&tree.arena))
	os.close(f)
	if read_err != nil {
		return 0, Parse_Error{kind = .File_Read_Failed, os_error = read_err}
	}
	return decode(data, format, tree)
}

// Decodes data into tree, which must be zero or destroyed. Strings and
// blobs are views of data, which the tree borrows: keep data alive and
// unchanged for as long as the tree is used. The tree references nothing
// in the schema.
@(require_results)
read_from_bytes :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> (consumed: int, err: Parse_Error) {
	assert(tree.arena.block == nil && tree.root == nil, "read_from_bytes: tree must be zero or destroyed")
	init_arena(tree, len(data))
	return decode(data, format, tree)
}

// Sizes the first block of tree's arena for an input of input_size bytes.
// The block is reserved, and committed only as it is used; it holds the
// tree of every sample, and the input too when read put it there.
@(private = "file")
init_arena :: proc(tree: ^fld.Value_Tree, input_size: int) {
	fld.tree_arena_init(&tree.arena, max(16 * uint(max(input_size, 0)), fld.TREE_ARENA_BLOCK_SIZE))
}

// Decodes data into tree, whose arena init_arena has sized.
@(private = "file", require_results)
decode :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> (consumed: int, err: Parse_Error) {
	allocator := fld.tree_arena_allocator(&tree.arena)
	tree.root = make([dynamic]fld.Value, allocator)

	d := Decoder{allocator = allocator}
	d.path = make([dynamic]Path_Segment, allocator)
	d.frames = make([dynamic]^fld.Instance, allocator)
	dat.reader_init(&d.r, data)

	rerr := read_values(&d, &tree.root, nil, 0, format.root)
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}

	return d.r.pos, d.err
}

// Appends every value of node to values: the instances of a set, or the
// elements of any other field. instance is the set instance that holds
// values, in slot; the bit fields of each element go to the slots after
// it. instance is nil for the root.
@(private = "file", require_results)
read_values :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, instance: ^fld.Instance, slot: int, node: ^mdata.Node) -> dat.Read_Error {
	if node.cond != nil {
		read_it, err := eval_bool(d, node.cond)
		if err != .None do return fail(d, err, d.r.pos)
		if !read_it do return .None
	}

	count: int
	switch c in node.count {
	case mdata.Fixed_Count:
		count = c.n
	case mdata.Rule_Count:
		n, err := eval_int(d, c.expr)
		if err == .None do err = check_count(n, c.max)
		if err != .None do return fail(d, err, d.r.pos)
		count = n
	case mdata.Marker_Count:
		count = markers_match(&d.r, c.markers) ? 1 : 0
	case mdata.Repeat_Count:
		return read_repeat(d, values, instance, slot, node, c)
	case mdata.Eos_Count:
		for i := 0; d.r.pos < len(d.r.data); i += 1 {
			read_element(d, values, instance, slot, node, i, must_progress = true) or_return
		}
		return .None
	case mdata.Until_Count:
		for i := 0;; i += 1 {
			start := d.r.pos
			read_element(d, values, instance, slot, node, i) or_return

			done, err := eval_bool(d, c.expr, element = values[len(values) - 1])
			if err != .None do return fail(d, err, d.r.pos)
			if done do return .None

			if d.r.pos == start {
				append(&d.path, Path_Segment{node.name, i})
				return fail(d, .No_Progress, start)
			}
		}
	}

	// a known count is allocated once: appending to an empty array would
	// reserve room for 8 values, and grow by copying
	reserve(values, len(values) + count)
	for _, b in node.bits {
		reserve(&instance.slots[slot + 1 + b], count)
	}
	for i in 0 ..< count {
		read_element(d, values, instance, slot, node, i) or_return
	}
	return .None
}

// Reads elements of node while its continuator is present or until its
// terminator is found. The terminator is required, the repeat count is
// limited, and every element must consume input.
@(private = "file", require_results)
read_repeat :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, instance: ^fld.Instance, slot: int, node: ^mdata.Node, repeat: mdata.Repeat_Count) -> dat.Read_Error {
	for {
		value, peek_err := dat.peek_integer_at(&d.r, d.r.pos, repeat.type, repeat.order)

		if repeat.until {
			if peek_err != .None do return fail(d, .Unexpected_EOF, d.r.pos)
			if value == repeat.value do return .None
		} else {
			if peek_err != .None || value != repeat.value do return .None
		}

		if e := check_count(len(values) + 1, repeat.max); e != .None {
			return fail(d, e, d.r.pos)
		}

		read_element(d, values, instance, slot, node, len(values), must_progress = true) or_return
	}
}

// Reads element index of node and appends it to values (an instance of a
// set, or a value of any other field and its bit fields). With
// must_progress, an element that consumes no input is an error.
@(private = "file", require_results)
read_element :: proc(
	d: ^Decoder,
	values: ^[dynamic]fld.Value,
	instance: ^fld.Instance,
	slot: int,
	node: ^mdata.Node,
	index: int,
	must_progress := false,
) -> dat.Read_Error {
	// on error the segment is left pushed; fail has already copied the path
	append(&d.path, Path_Segment{node.name, index})
	start := d.r.pos

	if node.type == .Set {
		read_instance(d, values, node, index) or_return
		if must_progress && d.r.pos == start do return fail(d, .No_Progress, start)
		pop(&d.path)
		return .None
	}

	value := read_scalar(d, node, index) or_return
	append(values, value)
	pop(&d.path)

	for bit, b in node.bits {
		bit_value := bit_field_value(value, bit)
		append(&instance.slots[slot + 1 + b], bit_value)

		if e := check_valid(bit_value, bit.valid); e != .None {
			append(&d.path, Path_Segment{bit.name, index})
			return fail(d, e, start)
		}
	}

	if must_progress && d.r.pos == start {
		append(&d.path, Path_Segment{node.name, index})
		return fail(d, .No_Progress, start)
	}
	return .None
}

// Reads instance index of set node and appends it to values: from a
// substream when node has a length, and as the set its switch-on chooses.
// A switch-on that chooses no set reads nothing.
@(private = "file", require_results)
read_instance :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, node: ^mdata.Node, index: int) -> dat.Read_Error {
	set := node
	choice := 0
	if sw := node.switch_on; sw != nil {
		on, err := eval_int(d, sw.on, index)
		if err != .None do return fail(d, err, d.r.pos)
		set, choice = sw.default, fld.DEFAULT_CASE
		for c, i in sw.cases {
			if c.value == on {
				set, choice = c.node, i
				break
			}
		}
		if set == nil do return .None
	}

	if node.length == nil do return read_set_instance(d, values, set, choice)

	start := d.r.pos
	n, err := byte_length(d, node.length, index)
	if err != .None do return fail(d, err, start)
	bytes: []byte
	bytes, err = dat.read_bytes(&d.r, n)
	if err != .None do return fail(d, err, start)

	// the parent's stream is already past the substream, whatever the
	// instance consumes
	parent, parent_base := d.r, d.base
	defer {
		d.r = parent
		d.base = parent_base
	}
	dat.reader_init(&d.r, bytes)
	d.base += start

	return read_set_instance(d, values, set, choice)
}

// Appends one instance of set node to values, read as choice (see
// field.Instance), and reads its children into it.
@(private = "file", require_results)
read_set_instance :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, node: ^mdata.Node, choice: int) -> dat.Read_Error {
	instance := new(fld.Instance, d.allocator)
	instance.choice = choice
	instance.slots = make([][dynamic]fld.Value, mdata.slot_count(node), d.allocator)
	for &s in instance.slots {
		s = make([dynamic]fld.Value, d.allocator)
	}
	append(values, instance)

	// on error the frame is left pushed, like the path segment
	append(&d.frames, instance)

	slot := 0
	for child in node.children {
		read_values(d, &instance.slots[slot], instance, slot, child) or_return
		slot += 1 + len(child.bits)
	}

	pop(&d.frames)
	return .None
}

// Reads element index of node, a field that is not a set, and checks it.
@(private = "file", require_results)
read_scalar :: proc(d: ^Decoder, node: ^mdata.Node, index: int) -> (value: fld.Value, err: dat.Read_Error) {
	start := d.r.pos

	switch node.type {
	case .Int8:
		value, err = to_value(dat.read(&d.r, i8, node.order))
	case .UInt8:
		value, err = to_value(dat.read(&d.r, u8, node.order))
	case .Int16:
		value, err = to_value(dat.read(&d.r, i16, node.order))
	case .UInt16:
		value, err = to_value(dat.read(&d.r, u16, node.order))
	case .Int32:
		value, err = to_value(dat.read(&d.r, i32, node.order))
	case .UInt32:
		value, err = to_value(dat.read(&d.r, u32, node.order))
	case .Int64:
		value, err = to_value(dat.read(&d.r, i64, node.order))
	case .UInt64:
		value, err = to_value(dat.read(&d.r, u64, node.order))
	case .Float32:
		value, err = to_value(dat.read(&d.r, f32, node.order))
	case .Float64:
		value, err = to_value(dat.read(&d.r, f64, node.order))
	case .String:
		n: int
		n, err = byte_length(d, node.length, index)
		if err != .None do return nil, fail(d, err, start)
		src: []byte
		src, err = dat.read_bytes(&d.r, n)
		if err == .None do value = fld.Value(string(src))
	case .Blob:
		n: int
		n, err = byte_length(d, node.length, index)
		if err != .None do return nil, fail(d, err, start)
		src: []byte
		src, err = dat.read_bytes(&d.r, n)
		if err != .None do return nil, fail(d, err, start)
		value = fld.Value(src)
	case .Set:
		panic("read_scalar: called for a set")
	}

	if err == .None do err = check_valid(value, node.valid)
	if err != .None do return nil, fail(d, err, start)
	return value, .None
}

@(private = "file", require_results)
to_value :: proc(v: $T, err: dat.Read_Error) -> (fld.Value, dat.Read_Error) {
	return fld.Value(v), err
}
