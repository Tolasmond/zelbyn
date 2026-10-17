package metadata

import dat "../data"

Field_Metadata_Provider :: struct {
	data_type_map: map[int]^dat.Data_Type_Record,
	field_metadata_map: map[int]^Field_Metadata,
	set_helper_map: map[int]^dat.Set_Helper_Record,
	set_length_map: map[int]^dat.Length_Record,
	marker_offset_map: map[int][dynamic]^dat.Marker_Offset_Record,
	packed_records: [dynamic]^dat.Packed_Record,
	format_record: dat.Format_Record,
	parent_map: map[int][dynamic]^dat.Parent_Record,
}
