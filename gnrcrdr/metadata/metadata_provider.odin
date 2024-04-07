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
  parent_map: map[int][dynamic]^dat.Parent_Record
}

destroy_metadata_provider :: proc(metadata: ^Field_Metadata_Provider) {
  for _, record in metadata.data_type_map {
    dat.destroy_data_type_record(record)
  }
  delete(metadata.data_type_map)

  for _, field_metadata in metadata.field_metadata_map {
    destroy_field_metadata(field_metadata)
  }
  delete(metadata.field_metadata_map)
  
  for _, record in metadata.set_helper_map {
    free(record)
  }
  delete(metadata.set_helper_map)
  
  for _, record in metadata.set_length_map {
    dat.destroy_length_record(record)
  }
  delete(metadata.set_length_map)
  
  for _, marker_records in metadata.marker_offset_map {
    for record in marker_records {
      free(record)
    }
    delete(marker_records)
  }
  delete(metadata.marker_offset_map)
  
  for record in metadata.packed_records {
    free(record)
  }
  delete(metadata.packed_records)

  delete(metadata.format_record.name)

  for _, parent_records in metadata.parent_map {
    for record in parent_records {
      free(record)
    }
    delete(parent_records)
  }
  delete(metadata.parent_map)
}
