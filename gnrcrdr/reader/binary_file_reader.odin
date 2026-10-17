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
	fld.init_field_value_array(&tree.root, &format.root_metadata_node, allocator)

	d := Decoder{metadata = &format.metadata, allocator = allocator}
	d.path = make([dynamic]Path_Segment, allocator)
	dat.reader_init(&d.r, data, .Little)

	rerr := read_set(&d, &tree.root, &format.root_metadata_node)
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}

	return d.r.pos, d.err
}

@(private = "file", require_results)
read_set :: proc(d: ^Decoder, field: ^[dynamic]fld.Value, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	count, err := fld.adjust_count(field, node, d.metadata, &d.r, d.allocator)
	if err != .None do return fail(d, err, d.r.pos)

	for set_index in 0 ..< count {
		// on error the segment is left pushed; fail has already copied the path
		append(&d.path, Path_Segment{node.metadata.name, set_index})
		read_set_instance(d, field, set_index, node) or_return
		pop(&d.path)
	}

	return .None
}

// Reads instances of a grow-as-needed set until its continuator is absent or
// its terminator is found. The terminator is required, the repeat count is
// limited by MaxArrayLength, and every instance must consume input.
@(private = "file", require_results)
read_growing_set :: proc(d: ^Decoder, set_field: ^[dynamic]fld.Value, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	metadata := d.metadata

	set_helper_rec := metadata.set_helper_map[node.metadata.id]
	if set_helper_rec == nil do return fail(d, .Invalid_Schema, d.r.pos)

	length_id, length_id_exists := set_helper_rec.length_id.?
	if !length_id_exists do return fail(d, .Invalid_Schema, d.r.pos)

	length_rec := metadata.set_length_map[length_id]
	if length_rec == nil do return fail(d, .Invalid_Schema, d.r.pos)

	data_type_rec := metadata.data_type_map[length_rec.data_type_id]
	if data_type_rec == nil do return fail(d, .Invalid_Schema, d.r.pos)

	data_type := dat.Data_Type(data_type_rec.type)

	continuator, continuator_exists := length_rec.continuator.?
	terminator, terminator_exists := length_rec.terminator.?
	if !continuator_exists && !terminator_exists do return fail(d, .Invalid_Schema, d.r.pos)

	for {
		value, peek_err := dat.peek_integer_at(&d.r, d.r.pos, data_type)

		if continuator_exists {
			if peek_err != .None || value != continuator do return .None
		} else {
			if peek_err != .None do return fail(d, .Unexpected_EOF, d.r.pos)
			if value == terminator do return .None
		}

		if e := fld.check_count(len(set_field) + 1, node.metadata.data_type.max_array_length); e != .None {
			return fail(d, e, d.r.pos)
		}

		append(set_field, make(map[int][dynamic]fld.Value, d.allocator))
		set_index := len(set_field) - 1
		fld.initialize_set_map(&set_field[set_index].(map[int][dynamic]fld.Value), node, d.allocator)

		start := d.r.pos
		append(&d.path, Path_Segment{node.metadata.name, set_index})
		read_set_instance(d, set_field, set_index, node) or_return

		if d.r.pos == start do return fail(d, .No_Progress, start)

		pop(&d.path)
	}
}

@(private = "file", require_results)
read_set_instance :: proc(d: ^Decoder, set_field: ^[dynamic]fld.Value, set_index: int, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	parent_map := &set_field[set_index].(map[int][dynamic]fld.Value)

	for child_node in node.children {
		child_metadata := child_node.metadata

		if dat.Data_Type(child_metadata.data_type.type) == .Set {
			if child_metadata.data_type.is_grow_as_needed == 1 {
				read_growing_set(d, &parent_map[child_metadata.id], child_node) or_return
			} else {
				read_set(d, &parent_map[child_metadata.id], child_node) or_return
			}

		} else {
			read_field(d, &parent_map[child_metadata.id], child_node) or_return
		}
	}

	return .None
}

@(private = "file", require_results)
read_field :: proc(d: ^Decoder, set_field: ^[dynamic]fld.Value, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	count := fld.get_count(set_field, nil)

	for i in 0 ..< count {
		append(&d.path, Path_Segment{node.metadata.name, i})

		start := d.r.pos
		value: fld.Value
		err: dat.Read_Error

		data_type := dat.Data_Type(node.metadata.data_type.type)

		switch data_type {
		case .Int8:
			value, err = to_value(dat.read(&d.r, i8))
		case .UInt8:
			value, err = to_value(dat.read(&d.r, u8))
		case .Int16:
			value, err = to_value(dat.read(&d.r, i16))
		case .UInt16:
			value, err = to_value(dat.read(&d.r, u16))
		case .Int32:
			value, err = to_value(dat.read(&d.r, i32))
		case .UInt32:
			value, err = to_value(dat.read(&d.r, u32))
		case .Int64:
			value, err = to_value(dat.read(&d.r, i64))
		case .UInt64:
			value, err = to_value(dat.read(&d.r, u64))
		case .Float32:
			value, err = to_value(dat.read(&d.r, f32))
		case .Float64:
			value, err = to_value(dat.read(&d.r, f64))
		case .String:
			n, ok := node.metadata.data_type.max_buffer_length.?
			if !ok do return fail(d, .Invalid_Schema, start)
			value, err = to_value(dat.read_string(&d.r, n, d.allocator))
		case .Blob:
			buffer_length: int
			buffer_length, err = fld.get_buffer_length(node, d.metadata, &d.r)
			if err != .None do return fail(d, err, start)
			src: []byte
			src, err = dat.read_bytes(&d.r, buffer_length)
			if err != .None do return fail(d, err, start)
			value = fld.Value(slice.clone(src, d.allocator))
		case .Set:
			return fail(d, .Invalid_Schema, start)
		}

		if err != .None do return fail(d, err, start)

		fld.set_value(node, set_field, nil, i, value)

		pop(&d.path)
	}

	return .None
}

@(private = "file", require_results)
to_value :: proc(v: $T, err: dat.Read_Error) -> (fld.Value, dat.Read_Error) {
	return fld.Value(v), err
}
