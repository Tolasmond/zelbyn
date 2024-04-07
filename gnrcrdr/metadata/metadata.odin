package metadata

import dat "../data"

Field_Metadata :: struct {
  id: int,
  name: string,
  data_type: ^dat.Data_Type_Record,
  packed_fields: []^dat.Packed_Record
}

destroy_field_metadata :: proc(metadata: ^Field_Metadata) {
  delete(metadata.name)
  free(metadata)
}