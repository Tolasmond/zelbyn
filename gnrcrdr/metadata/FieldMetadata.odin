package metadata

import "../data"

Field_Metadata :: struct {
  id: int,
  name: string,
  data_type: ^data.Data_Type_Record,
  packed_fields: []^data.Packed_Record
}
