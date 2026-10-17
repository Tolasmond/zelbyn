package field

import dat  "../data"
import eval "../evaluate"
import fld  "../field"
import mdat "../metadata"

adjust_count :: proc(
	field: ^[dynamic]fld.Value,
	node: ^mdat.Field_Metadata_Tree_Node,
	metadata: ^mdat.Field_Metadata_Provider,
	r: ^dat.Reader) -> (count: int, err: dat.Read_Error) {

	set_helper_rec := metadata.set_helper_map[node.metadata.id]

	marker_id := 0
	length_id := 0
	marker_id_exists := false
	length_id_exists := false

	if set_helper_rec != nil {
		marker_id, marker_id_exists = set_helper_rec.marker_id.?
		length_id, length_id_exists = set_helper_rec.length_id.?
	}

	if marker_id_exists {

		marker_off_recs := metadata.marker_offset_map[marker_id]

		if len(marker_off_recs) == 0 do return 0, .Invalid_Schema

		marker_found := true

		// peek ahead to see if marker(s) exist; a mismatch or a failed peek
		// (e.g. past EOF) means the marker is absent
		for marker_off_rec in marker_off_recs {
			marker_data_type_rec := metadata.data_type_map[marker_off_rec.data_type_id]
			if marker_data_type_rec == nil do return 0, .Invalid_Schema

			marker, peek_err := dat.peek_integer_at(
				r,
				r.pos + marker_off_rec.byte_offset,
				dat.Data_Type(marker_data_type_rec.type),
			)

			if peek_err != .None || marker != marker_off_rec.marker {
				marker_found = false
				break
			}
		}

		count = marker_found ? 1 : 0

		set_count(count, node, field)
	} else if length_id_exists {

		count = eval_length_rule(metadata.set_length_map[length_id], metadata, r, true) or_return

		if e := check_count(count, node.metadata.data_type.max_array_length); e != .None {
			return 0, e
		}

		set_count(count, node, field)
	} else {
		count = len(field)
	}

	return
}

get_buffer_length :: proc(
	node: ^mdat.Field_Metadata_Tree_Node,
	metadata: ^mdat.Field_Metadata_Provider,
	r: ^dat.Reader) -> (length: int, err: dat.Read_Error) {

	data_type_rec := node.metadata.data_type

	length, _ = data_type_rec.max_buffer_length.?

	if data_type_rec.min_buffer_length != data_type_rec.max_buffer_length {

		set_helper_rec := metadata.set_helper_map[node.metadata.id]

		if set_helper_rec != nil {
			if length_id, length_id_exists := set_helper_rec.length_id.?; length_id_exists {
				length = eval_length_rule(metadata.set_length_map[length_id], metadata, r, false) or_return
			}
		}
	}

	if length < 0 do return 0, .Invalid_Length

	if max_length, ok := data_type_rec.max_buffer_length.?; ok && length > max_length {
		return 0, .Invalid_Length
	}

	if min_length, ok := data_type_rec.min_buffer_length.?; ok && length < min_length {
		return 0, .Invalid_Length
	}

	return
}

// Validates a set count: negative counts are invalid, and counts above the
// set's MaxArrayLength (when present) exceed the repeat limit.
check_count :: proc(count: int, max_array_length: Maybe(int)) -> dat.Read_Error {
	if count < 0 do return .Invalid_Length

	if max_count, ok := max_array_length.?; ok && count > max_count {
		return .Repeat_Limit_Exceeded
	}

	return .None
}

// Evaluates a Length rule at the reader's current position: an optional flag
// (zero means length 0), then the value with its mask, shift and, when
// apply_expression is set, its expression. Peeks never move the reader.
@(private = "file")
eval_length_rule :: proc(
	length_rec: ^dat.Length_Record,
	metadata: ^mdat.Field_Metadata_Provider,
	r: ^dat.Reader,
	apply_expression: bool) -> (value: int, err: dat.Read_Error) {

	if length_rec == nil do return 0, .Invalid_Schema

	length_data_type_rec := metadata.data_type_map[length_rec.data_type_id]

	if length_data_type_rec == nil do return 0, .Invalid_Schema

	data_type := dat.Data_Type(length_data_type_rec.type)

	flag_abs_pos, flag_abs_pos_exists := length_rec.flag_absoute_offset_from_beginning.?
	flag_rel_pos, flag_rel_pos_exists := length_rec.flag_relative_offset_from_field.?

	if flag_abs_pos_exists || flag_rel_pos_exists {
		flag_pos := flag_abs_pos_exists ? flag_abs_pos : r.pos + flag_rel_pos

		flag_value := dat.peek_integer_at(r, flag_pos, data_type) or_return

		if flag_mask, ok := length_rec.flag_mask.?; ok {
			flag_value &= flag_mask
		}

		if flag_shift, ok := length_rec.flag_shift.?; ok {
			flag_value >>= u32(flag_shift)
		}

		if flag_value == 0 do return 0, .None
	}

	if value_abs_pos, ok := length_rec.value_absolute_offset_from_beginning.?; ok {
		value = dat.peek_integer_at(r, value_abs_pos, data_type) or_return
	}

	if value_rel_pos, ok := length_rec.value_relative_offset_from_field.?; ok {
		value = dat.peek_integer_at(r, r.pos + value_rel_pos, data_type) or_return
	}

	if value_mask, ok := length_rec.value_mask.?; ok {
		value &= value_mask
	}

	if value_shift, ok := length_rec.value_shift.?; ok {
		value >>= u32(value_shift)
	}

	if apply_expression {
		if value_expr, ok := length_rec.value_expression.?; ok {
			param_map := make(map[string]int)
			defer delete(param_map)
			param_map["x"] = value
			value = eval.evaluate(value_expr, &param_map)
		}
	}

	return
}
