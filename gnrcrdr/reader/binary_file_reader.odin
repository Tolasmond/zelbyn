package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:os"
import "core:slice"

@(require_results)
read :: proc(name: string, format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> (consumed: int, err: Parse_Error) {
	data, os_err := os.read_entire_file(name, context.allocator)
	if os_err != nil {
		return 0, Parse_Error{kind = .File_Read_Failed, os_error = os_err}
	}
	defer delete(data)
	return read_from_bytes(data, format, tree)
}

// Decodes data into tree, which must be zero or destroyed. Strings and blobs are copied into the tree's arena, so the tree references neither data nor the schema.
@(require_results)
read_from_bytes :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> (consumed: int, err: Parse_Error) {
	assert(tree.arena.block == nil && tree.root == nil, "read_from_bytes: tree must be zero or destroyed")
	// one block, reserved and committed as it is used, holds every sample's
	// tree (at most about 6 times its input)
	fld.tree_arena_init(&tree.arena, max(16 * uint(len(data)), fld.TREE_ARENA_BLOCK_SIZE))
	allocator := fld.tree_arena_allocator(&tree.arena)
	tree.root = make([dynamic]fld.Value, allocator)

	d := Decoder{allocator = allocator}
	d.path = make([dynamic]Path_Segment, allocator)
	d.frames = make([dynamic]^map[int][dynamic]fld.Value, allocator)
	dat.reader_init(&d.r, data)

	rerr := read_values(&d, &tree.root, nil, format.root)
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}

	return d.r.pos, d.err
}

// Appends every value of node to values: the instances of a set, or the
// elements of any other field. instance is the set instance that holds
// values, which receives the bit fields of each element; nil for the root.
// Every key of node is already in instance.
@(private = "file", require_results)
read_values :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, instance: ^map[int][dynamic]fld.Value, node: ^mdata.Node) -> dat.Read_Error {
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
		return read_repeat(d, values, instance, node, c)
	case mdata.Eos_Count:
		for i := 0; d.r.pos < len(d.r.data); i += 1 {
			read_element(d, values, instance, node, i, must_progress = true) or_return
		}
		return .None
	case mdata.Until_Count:
		for i := 0;; i += 1 {
			start := d.r.pos
			read_element(d, values, instance, node, i) or_return

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
	for bit in node.bits {
		reserve(&instance[bit.id], count)
	}
	for i in 0 ..< count {
		read_element(d, values, instance, node, i) or_return
	}
	return .None
}

// Reads elements of node while its continuator is present or until its
// terminator is found. The terminator is required, the repeat count is
// limited, and every element must consume input.
@(private = "file", require_results)
read_repeat :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, instance: ^map[int][dynamic]fld.Value, node: ^mdata.Node, repeat: mdata.Repeat_Count) -> dat.Read_Error {
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

		read_element(d, values, instance, node, len(values), must_progress = true) or_return
	}
}

// Reads element index of node and appends it to values (an instance of a
// set, or a value of any other field and its bit fields). With
// must_progress, an element that consumes no input is an error.
@(private = "file", require_results)
read_element :: proc(
	d: ^Decoder,
	values: ^[dynamic]fld.Value,
	instance: ^map[int][dynamic]fld.Value,
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

	for bit in node.bits {
		bit_value := bit_field_value(value, bit)
		append(&instance[bit.id], bit_value)

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
	if sw := node.switch_on; sw != nil {
		on, err := eval_int(d, sw.on, index)
		if err != .None do return fail(d, err, d.r.pos)
		set = sw.default
		for c in sw.cases {
			if c.value == on {
				set = c.node
				break
			}
		}
		if set == nil do return .None
	}

	if node.length == nil do return read_set_instance(d, values, set)

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

	return read_set_instance(d, values, set)
}

// Appends one instance of set node to values and reads its children into it.
@(private = "file", require_results)
read_set_instance :: proc(d: ^Decoder, values: ^[dynamic]fld.Value, node: ^mdata.Node) -> dat.Read_Error {
	append(values, make(map[int][dynamic]fld.Value, len(node.children), d.allocator))
	instance := &values[len(values) - 1].(map[int][dynamic]fld.Value)

	// on error the frame is left pushed, like the path segment
	append(&d.frames, instance)

	for child in node.children {
		// every key of child is inserted before a pointer into instance is
		// taken, and reading child inserts no other key
		instance[child.id] = make([dynamic]fld.Value, d.allocator)
		for bit in child.bits {
			instance[bit.id] = make([dynamic]fld.Value, d.allocator)
		}
		read_values(d, &instance[child.id], instance, child) or_return
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
		if node.drop_nul {
			value, err = to_value(dat.read_string(&d.r, n, d.allocator))
		} else {
			src: []byte
			src, err = dat.read_bytes(&d.r, n)
			if err == .None do value = fld.Value(string(slice.clone(src, d.allocator)))
		}
	case .Blob:
		n: int
		n, err = byte_length(d, node.length, index)
		if err != .None do return nil, fail(d, err, start)
		src: []byte
		src, err = dat.read_bytes(&d.r, n)
		if err != .None do return nil, fail(d, err, start)
		value = fld.Value(slice.clone(src, d.allocator))
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
