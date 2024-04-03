package metadata

import "../data"

FieldMetadataProvider :: struct {
  dataTypeMap: map[int]^data.DataTypeRecord,
  fieldMetadataMap: map[int]^FieldMetadata,
  setHelperMap: map[int]^data.SetHelperRecord,
  setLengthMap: map[int]^data.LengthRecord,
  markerOffsetMap: map[int]^data.MarkerOffsetRecord,
  packedRecords: [dynamic]^data.PackedRecord,
  formatRecord: data.FormatRecord,
  parentMap: map[int][dynamic]^data.ParentRecord
}

// @(private="file")
// createSetMap :: proc(fieldMetadataTreeNode: FieldMetadataTreeNode) -> ^map[i32]data.FieldValueArray {

// }
