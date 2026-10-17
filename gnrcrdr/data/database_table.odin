package data

Data_Type_Record :: struct {
	id: int,
	type: int,
	min_value: Maybe(string),
	max_value: Maybe(string),
	default_value: Maybe(string),
	units: Maybe(string),
	min_array_length: Maybe(int),
	max_array_length: Maybe(int),
	is_grow_as_needed: Maybe(int),
	pattern: Maybe(string),
	comparison_tolerance: Maybe(f64),
	min_buffer_length: Maybe(int),
	max_buffer_length: Maybe(int),
}

Field_Record :: struct {
	id: int,
	name: string,
	data_type_id: int,
}

Set_Helper_Record :: struct {
	format_id: int,
	field_id: int,
	length_id: Maybe(int),
	marker_id: Maybe(int),
}

Length_Record :: struct {
	id: int,
	data_type_id: int,
	flag_absoute_offset_from_beginning: Maybe(int),
	flag_relative_offset_from_field: Maybe(int),
	value_absolute_offset_from_beginning: Maybe(int),
	value_relative_offset_from_field: Maybe(int),
	continuator: Maybe(int),
	terminator: Maybe(int),
	flag_mask: Maybe(int),
	flag_shift: Maybe(int),
	value_mask: Maybe(int),
	value_shift: Maybe(int),
	flag_expression: Maybe(string),
	value_expression: Maybe(string),
}

Marker_Offset_Record :: struct {
	marker_id: int,
	byte_offset: int,
	data_type_id: int,
	marker: int,
}

Packed_Record :: struct {
	id: int,
	field_id: int,
	low_bit: int,
	high_bit: int,
}

Format_Record :: struct {
	id: int,
	name: string,
	root_field: int,
}

Parent_Record :: struct {
	format_id: int,
	parent_id: int,
	child_id: int,
	child_index: int,
}

sort_parent_records_by_child_index :: proc(i, j: ^Parent_Record) -> bool {
	return i.child_index < j.child_index
}
