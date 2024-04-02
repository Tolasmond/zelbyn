package metadata

import "../data"

FieldMetadata :: struct {
  id: i32,
  name: string,
  dataTypeId: i32,
  packedFields: []^PackedRecord
}
