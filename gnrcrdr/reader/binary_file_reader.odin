package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:log"
import "core:os"
import "core:slice"

read :: proc(name: string, format: ^mdata.File_Format, root_field: ^[dynamic]fld.Value) {
	data, _ := os.read_entire_file(name, context.allocator)
	defer delete(data)
	r: dat.Reader
	dat.reader_init(&r, data, .Little)
	read_set(root_field, &format.root_metadata_node, &format.metadata, &r)
}

@(private = "file")
read_set :: proc(
	field: ^[dynamic]fld.Value,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	r: ^dat.Reader) {

	count := fld.adjust_count(field, node, metadata, r)

	for set_index in 0 ..< count {
		read_set_instance(field, set_index, node, metadata, r)
	}
}

@(private = "file")
read_growing_set :: proc(
	set_field: ^[dynamic]fld.Value,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	r: ^dat.Reader) {

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
						value, _ := dat.peek_integer_at(r, r.pos, dat.Data_Type(continuator_data_type_rec.type))
						if continuator != value {
							return
						}

						append(set_field, make(map[int][dynamic]fld.Value))
						fld.initialize_set_map(
							&set_field[len(set_field) - 1].(map[int][dynamic]fld.Value),
							node,
						)

						read_set_instance(set_field, set_index, node, metadata, r)
						set_index += 1
					}
				}

				terminator, terminator_exists := length_rec.terminator.?

				if terminator_exists {
					set_index := 0
					for {
						terminator_data_type_rec := metadata.data_type_map[length_rec.data_type_id]
						value, _ := dat.peek_integer_at(r, r.pos, dat.Data_Type(terminator_data_type_rec.type))
						if terminator == value {
							return
						}

						append(set_field, make(map[int][dynamic]fld.Value))
						fld.initialize_set_map(
							&set_field[len(set_field) - 1].(map[int][dynamic]fld.Value),
							node,
						)

						read_set_instance(set_field, set_index, node, metadata, r)
						set_index += 1
					}
				}
			}
		}
	}
}

@(private = "file")
read_set_instance :: proc(
	set_field: ^[dynamic]fld.Value,
	set_index: int,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	r: ^dat.Reader) {

	log.debugf(
		"0x%08X Set: %v (%v), set_index = %v, set_field len = %v",
		r.pos,
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
				read_growing_set(&parent_map[child_metadata.id], child_node, metadata, r)
			} else {
				read_set(&parent_map[child_metadata.id], child_node, metadata, r)
			}

		} else {
			read_field(&parent_map[child_metadata.id], child_node, metadata, r, nil)
		}
	}
}

@(private = "file")
read_field :: proc(
	set_field: ^[dynamic]fld.Value,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	r: ^dat.Reader,
	path_pair: ^fld.Path_Pair) {

	count := fld.get_count(set_field, path_pair)

	for i in 0 ..< count {
		pos := r.pos
		value: fld.Value

		data_type := dat.Data_Type(node.metadata.data_type.type)

		#partial switch data_type {
		case .Int8:
			value = fld.Value(dat.read_i8(r) or_else 0)
		case .UInt8:
			value = fld.Value(dat.read_u8(r) or_else 0)
		case .Int16:
			value = fld.Value(dat.read_i16(r) or_else 0)
		case .UInt16:
			value = fld.Value(dat.read_u16(r) or_else 0)
		case .Int32:
			value = fld.Value(dat.read_i32(r) or_else 0)
		case .UInt32:
			value = fld.Value(dat.read_u32(r) or_else 0)
		case .Int64:
			value = fld.Value(dat.read_i64(r) or_else 0)
		case .UInt64:
			value = fld.Value(dat.read_u64(r) or_else 0)
		case .Float32:
			value = fld.Value(dat.read_f32(r) or_else 0)
		case .Float64:
			value = fld.Value(dat.read_f64(r) or_else 0)
		case .String:
			len, _ := node.metadata.data_type.max_buffer_length.?
			//log.debugf("String length = %v", len)
			value = fld.Value(dat.read_string(r, len) or_else "")
		case .Blob:
			buffer_length := fld.get_buffer_length(node, metadata, r)
			src, _ := dat.read_bytes(r, buffer_length)
			dest := slice.clone(src)
			value = fld.Value(dest)
			log.debugf(
				"0x%08X Read %v = byte[%v], Field = %v",
				pos,
				data_type,
				buffer_length,
				node.metadata.name,
			)
		}

		if data_type != .Blob {
			log.debugf(
				"0x%08X Read %v = %v, Field = %v",
				pos,
				data_type,
				value,
				node.metadata.name,
			)
		}

		fld.set_value(node, set_field, path_pair, i, value)
	}
}
