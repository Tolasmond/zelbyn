package metadata

import "../data"

Field_Metadata_Provider :: struct {
  data_type_map: map[int]^data.Data_Type_Record,
  field_metadata_map: map[int]^Field_Metadata,
  set_helper_map: map[int]^data.Set_Helper_Record,
  set_length_map: map[int]^data.Length_Record,
  marker_offset_map: map[int][dynamic]^data.Marker_Offset_Record,
  packed_records: [dynamic]^data.Packed_Record,
  format_record: data.Format_Record,
  parent_map: map[int][dynamic]^data.Parent_Record
}
