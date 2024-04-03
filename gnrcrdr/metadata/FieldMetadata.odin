package metadata

import "../data"

FieldMetadata :: struct {
  id: int,
  name: string,
  dataType: ^data.DataTypeRecord,
  packedFields: []^data.PackedRecord
}
