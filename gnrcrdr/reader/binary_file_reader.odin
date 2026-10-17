package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:log"
import "core:os"
import "core:slice"

read :: proc(name: string, format: ^mdata.File_Format, root_field: ^[dynamic]fld.Value) -> (consumed: int, err: Parse_Error) {
	data, os_err := os.read_entire_file(name, context.allocator)
	if os_err != nil {
		return 0, Parse_Error{kind = .File_Read_Failed, os_error = os_err}
	}
	defer delete(data)
	return read_from_bytes(data, format, root_field)
}

// Decodes data into root_field. Nothing in the value tree references data
// afterwards; strings and blobs are copied.
read_from_bytes :: proc(data: []byte, format: ^mdata.File_Format, root_field: ^[dynamic]fld.Value) -> (consumed: int, err: Parse_Error) {
	d := Decoder{metadata = &format.metadata}
	dat.reader_init(&d.r, data, .Little)

	rerr := read_set(&d, root_field, &format.root_metadata_node)
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}

	delete(d.path)
	return d.r.pos, d.err
}

@(private = "file")
read_set :: proc(d: ^Decoder, field: ^[dynamic]fld.Value, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	count, err := fld.adjust_count(field, node, d.metadata, &d.r)
	if err != .None do return fail(d, err, d.r.pos)

	for set_index in 0 ..< count {
		read_set_instance(d, field, set_index, node) or_return
	}

	return .None
}

@(private = "file")
read_growing_set :: proc(d: ^Decoder, set_field: ^[dynamic]fld.Value, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	metadata := d.metadata

	set_helper_rec, set_helper_exists := metadata.set_helper_map[node.metadata.id]

	if set_helper_exists {
		length_id, length_id_exists := set_helper_rec.length_id.?

		if length_id_exists {
			length_rec, length_exists := metadata.set_length_map[length_id]

			if length_exists {
				continuator, continuator_exists := length_rec.continuator.?

				if continuator_exists {
					set_index := 0
					for {
						continuator_data_type_rec := metadata.data_type_map[length_rec.data_type_id]
						value, _ := dat.peek_integer_at(&d.r, d.r.pos, dat.Data_Type(continuator_data_type_rec.type))
						if continuator != value {
							return .None
						}

						append(set_field, make(map[int][dynamic]fld.Value))
						fld.initialize_set_map(
							&set_field[len(set_field) - 1].(map[int][dynamic]fld.Value),
							node,
						)

						read_set_instance(d, set_field, set_index, node) or_return
						set_index += 1
					}
				}

				terminator, terminator_exists := length_rec.terminator.?

				if terminator_exists {
					set_index := 0
					for {
						terminator_data_type_rec := metadata.data_type_map[length_rec.data_type_id]
						value, _ := dat.peek_integer_at(&d.r, d.r.pos, dat.Data_Type(terminator_data_type_rec.type))
						if terminator == value {
							return .None
						}

						append(set_field, make(map[int][dynamic]fld.Value))
						fld.initialize_set_map(
							&set_field[len(set_field) - 1].(map[int][dynamic]fld.Value),
							node,
						)

						read_set_instance(d, set_field, set_index, node) or_return
						set_index += 1
					}
				}
			}
		}
	}

	return .None
}

@(private = "file")
read_set_instance :: proc(d: ^Decoder, set_field: ^[dynamic]fld.Value, set_index: int, node: ^mdata.Field_Metadata_Tree_Node) -> dat.Read_Error {
	log.debugf(
		"0x%08X Set: %v (%v), set_index = %v, set_field len = %v",
		d.r.pos,
		node.metadata.name,
		node.metadata.id,
		set_index,
		len(set_field),
	)

	parent := set_field[set_index]
	parent_map := parent.(map[int][dynamic]fld.Value)

	for child_node in node.children {
		child_metadata := child_node.metadata

		if dat.Data_Type(child_metadata.data_type.type) == .Set {
			if child_metadata.data_type.is_grow_as_needed == 1 {
				read_growing_set(d, &parent_map[child_metadata.id], child_node) or_return
			} else {
				read_set(d, &parent_map[child_metadata.id], child_node) or_return
			}

		} else {
			read_field(d, &parent_map[child_metadata.id], child_node, nil) or_return
		}
	}

	return .None
}

@(private = "file")
read_field :: proc(d: ^Decoder, set_field: ^[dynamic]fld.Value, node: ^mdata.Field_Metadata_Tree_Node, path_pair: ^fld.Path_Pair) -> dat.Read_Error {
	count := fld.get_count(set_field, path_pair)

	for i in 0 ..< count {
		start := d.r.pos
		value: fld.Value
		err: dat.Read_Error

		data_type := dat.Data_Type(node.metadata.data_type.type)

		switch data_type {
		case .Int8:
			value, err = to_value(dat.read_i8(&d.r))
		case .UInt8:
			value, err = to_value(dat.read_u8(&d.r))
		case .Int16:
			value, err = to_value(dat.read_i16(&d.r))
		case .UInt16:
			value, err = to_value(dat.read_u16(&d.r))
		case .Int32:
			value, err = to_value(dat.read_i32(&d.r))
		case .UInt32:
			value, err = to_value(dat.read_u32(&d.r))
		case .Int64:
			value, err = to_value(dat.read_i64(&d.r))
		case .UInt64:
			value, err = to_value(dat.read_u64(&d.r))
		case .Float32:
			value, err = to_value(dat.read_f32(&d.r))
		case .Float64:
			value, err = to_value(dat.read_f64(&d.r))
		case .String:
			n, ok := node.metadata.data_type.max_buffer_length.?
			if !ok do return fail(d, .Invalid_Schema, start)
			value, err = to_value(dat.read_string(&d.r, n))
		case .Blob:
			buffer_length: int
			buffer_length, err = fld.get_buffer_length(node, d.metadata, &d.r)
			if err != .None do return fail(d, err, start)
			src: []byte
			src, err = dat.read_bytes(&d.r, buffer_length)
			if err != .None do return fail(d, err, start)
			value = fld.Value(slice.clone(src))
			log.debugf(
				"0x%08X Read %v = byte[%v], Field = %v",
				start,
				data_type,
				buffer_length,
				node.metadata.name,
			)
		case .Set:
			return fail(d, .Invalid_Schema, start)
		}

		if err != .None do return fail(d, err, start)

		if data_type != .Blob {
			log.debugf(
				"0x%08X Read %v = %v, Field = %v",
				start,
				data_type,
				value,
				node.metadata.name,
			)
		}

		fld.set_value(node, set_field, path_pair, i, value)
	}

	return .None
}

@(private = "file")
to_value :: proc(v: $T, err: dat.Read_Error) -> (fld.Value, dat.Read_Error) {
	return fld.Value(v), err
}
