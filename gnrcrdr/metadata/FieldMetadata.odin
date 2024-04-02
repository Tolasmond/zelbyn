package metadata

import "../datatype"

FieldMetadata :: struct {
  id: i32,
  name: string,
  dataTypeId: i32,
  packedFields: []^PackedRecord
}
