package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:mem/virtual"
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
	assert(tree.arena.curr_block == nil && tree.root == nil, "read_from_bytes: tree must be zero or destroyed")
	allocator := virtual.arena_allocator(&tree.arena)
	tree.root = make([dynamic]fld.Value, allocator)

	d := Decoder{allocator = allocator}
	d.path = make([dynamic]Path_Segment, allocator)
	d.frames = make([dynamic]^map[int][dynamic]fld.Value, allocator)
	dat.reader_init(&d.r, data)

	rerr := read_set(&d, &tree.root, format.root)
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}

	return d.r.pos, d.err
}

// Appends every instance of set node to field.
@(private = "file", require_results)
read_set :: proc(d: ^Decoder, field: ^[dynamic]fld.Value, node: ^mdata.Node) -> dat.Read_Error {
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
		return read_repeat(d, field, node, c)
	}

	for set_index in 0 ..< count {
		// on error the segment is left pushed; fail has already copied the path
		append(&d.path, Path_Segment{node.name, set_index})
		read_set_instance(d, field, node) or_return
		pop(&d.path)
	}

	return .None
}

// Reads instances of a repeated set while its continuator is present or
// until its terminator is found. The terminator is required, the repeat
// count is limited, and every instance must consume input.
@(private = "file", require_results)
read_repeat :: proc(d: ^Decoder, field: ^[dynamic]fld.Value, node: ^mdata.Node, repeat: mdata.Repeat_Count) -> dat.Read_Error {
	for {
		value, peek_err := dat.peek_integer_at(&d.r, d.r.pos, repeat.type, repeat.order)

		if repeat.until {
			if peek_err != .None do return fail(d, .Unexpected_EOF, d.r.pos)
			if value == repeat.value do return .None
		} else {
			if peek_err != .None || value != repeat.value do return .None
		}

		if e := check_count(len(field) + 1, repeat.max); e != .None {
			return fail(d, e, d.r.pos)
		}

		start := d.r.pos
		append(&d.path, Path_Segment{node.name, len(field)})
		read_set_instance(d, field, node) or_return

		if d.r.pos == start do return fail(d, .No_Progress, start)

		pop(&d.path)
	}
}

// Appends one instance of set node to field and reads its children into it.
@(private = "file", require_results)
read_set_instance :: proc(d: ^Decoder, field: ^[dynamic]fld.Value, node: ^mdata.Node) -> dat.Read_Error {
	append(field, make(map[int][dynamic]fld.Value, len(node.children), d.allocator))
	instance := &field[len(field) - 1].(map[int][dynamic]fld.Value)

	// on error the frame is left pushed, like the path segment
	append(&d.frames, instance)

	for child in node.children {
		if child.type == .Set {
			values := map_insert(instance, child.id, make([dynamic]fld.Value, d.allocator))
			read_set(d, values, child) or_return
		} else {
			read_field(d, instance, child) or_return
		}
	}

	pop(&d.frames)
	return .None
}

// Appends every element of node, a field that is not a set, to its values
// in instance, and the bit fields of each element to theirs.
@(private = "file", require_results)
read_field :: proc(d: ^Decoder, instance: ^map[int][dynamic]fld.Value, node: ^mdata.Node) -> dat.Read_Error {
	// every key is inserted before any pointer into instance is taken
	instance[node.id] = make([dynamic]fld.Value, d.allocator)
	for bit in node.bits {
		instance[bit.id] = make([dynamic]fld.Value, d.allocator)
	}
	values := &instance[node.id]

	// the plan gives every field that is not a set a fixed count
	count := node.count.(mdata.Fixed_Count).n

	for i in 0 ..< count {
		append(&d.path, Path_Segment{node.name, i})

		start := d.r.pos
		value: fld.Value
		err: dat.Read_Error

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
			n, err = byte_length(d, node.length, i)
			if err != .None do return fail(d, err, start)
			if node.drop_nul {
				value, err = to_value(dat.read_string(&d.r, n, d.allocator))
			} else {
				src: []byte
				src, err = dat.read_bytes(&d.r, n)
				if err == .None do value = fld.Value(string(slice.clone(src, d.allocator)))
			}
		case .Blob:
			n: int
			n, err = byte_length(d, node.length, i)
			if err != .None do return fail(d, err, start)
			src: []byte
			src, err = dat.read_bytes(&d.r, n)
			if err != .None do return fail(d, err, start)
			value = fld.Value(slice.clone(src, d.allocator))
		case .Set:
			panic("read_field: called for a set")
		}

		if err == .None do err = check_valid(value, node.valid)
		if err != .None do return fail(d, err, start)

		append(values, value)

		pop(&d.path)

		for bit in node.bits {
			bit_value := bit_field_value(value, bit)
			append(&instance[bit.id], bit_value)

			if e := check_valid(bit_value, bit.valid); e != .None {
				append(&d.path, Path_Segment{bit.name, i})
				return fail(d, e, start)
			}
		}
	}

	return .None
}

@(private = "file", require_results)
to_value :: proc(v: $T, err: dat.Read_Error) -> (fld.Value, dat.Read_Error) {
	return fld.Value(v), err
}
