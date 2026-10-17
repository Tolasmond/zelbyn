package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:log"

read :: proc(name: string, format: ^mdata.File_Format, root_field: ^[dynamic]fld.Value) {
	buf: dat.Byte_Buffer
	dat.read_file_into_buffer(&buf, name)
	read_set(root_field, &format.root_metadata_node, &format.metadata, &buf)
	delete(buf.data.buf)
}

@(private = "file")
read_set :: proc(
	field: ^[dynamic]fld.Value,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	buf: ^dat.Byte_Buffer) {

	count := fld.adjust_count(field, node, metadata, buf)

	for set_index in 0 ..< count {
		read_set_instance(field, set_index, node, metadata, buf)
	}
}

@(private = "file")
read_growing_set :: proc(
	set_field: ^[dynamic]fld.Value,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	buf: ^dat.Byte_Buffer) {

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
						pos := buf.data.off
						continuator_data_type_rec :=
							metadata.data_type_map[length_rec.data_type_id]
						value, _ := dat.get_integer(
							buf,
							dat.Data_Type(continuator_data_type_rec.type),
						)
						buf.data.off = pos
						if continuator != value {
							return
						}

						append(set_field, make(map[int][dynamic]fld.Value))
						fld.initialize_set_map(
							&set_field[len(set_field) - 1].(map[int][dynamic]fld.Value),
							node,
						)

						read_set_instance(set_field, set_index, node, metadata, buf)
						set_index += 1
					}
				}

				terminator, terminator_exists := length_rec.terminator.?

				if terminator_exists {
					set_index := 0
					for {
						pos := buf.data.off
						terminator_data_type_rec := metadata.data_type_map[length_rec.data_type_id]
						value, _ := dat.get_integer(
							buf,
							dat.Data_Type(terminator_data_type_rec.type),
						)
						buf.data.off = pos
						if terminator == value {
							return
						}

						append(set_field, make(map[int][dynamic]fld.Value))
						fld.initialize_set_map(
							&set_field[len(set_field) - 1].(map[int][dynamic]fld.Value),
							node,
						)

						read_set_instance(set_field, set_index, node, metadata, buf)
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
	buf: ^dat.Byte_Buffer) {

	log.debugf(
		"0x%08X Set: %v (%v), set_index = %v, set_field len = %v",
		buf.data.off,
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
				read_growing_set(&parent_map[child_metadata.id], child_node, metadata, buf)
			} else {
				read_set(&parent_map[child_metadata.id], child_node, metadata, buf)
			}

		} else {
			read_field(&parent_map[child_metadata.id], child_node, metadata, buf, nil)
		}
	}
}

@(private = "file")
read_field :: proc(
	set_field: ^[dynamic]fld.Value,
	node: ^mdata.Field_Metadata_Tree_Node,
	metadata: ^mdata.Field_Metadata_Provider,
	buf: ^dat.Byte_Buffer,
	path_pair: ^fld.Path_Pair) {

	count := fld.get_count(set_field, path_pair)

	for i in 0 ..< count {
		pos := buf.data.off
		value: fld.Value

		data_type := dat.Data_Type(node.metadata.data_type.type)

		#partial switch data_type {
		case .Int8:
			value = fld.Value(dat.get_i8(buf))
		case .UInt8:
			value = fld.Value(dat.get_u8(buf))
		case .Int16:
			value = fld.Value(dat.get_i16(buf))
		case .UInt16:
			value = fld.Value(dat.get_u16(buf))
		case .Int32:
			value = fld.Value(dat.get_i32(buf))
		case .UInt32:
			value = fld.Value(dat.get_u32(buf))
		case .Int64:
			value = fld.Value(dat.get_i64(buf))
		case .UInt64:
			value = fld.Value(dat.get_u64(buf))
		case .Float32:
			value = fld.Value(dat.get_f32(buf))
		case .Float64:
			value = fld.Value(dat.get_f64(buf))
		case .String:
			len, _ := node.metadata.data_type.max_buffer_length.?
			//log.debugf("String length = %v", len)
			value = fld.Value(dat.get_string(buf, len))
		case .Blob:
			buffer_length := fld.get_buffer_length(node, metadata, buf)
			dest := make([]byte, buffer_length)
			dat.get_bytes(buf, &dest)
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
