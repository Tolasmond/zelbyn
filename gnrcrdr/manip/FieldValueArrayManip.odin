package manip

import "../data"
import "../metadata"
import "core:fmt"
import "core:strconv"

populateFieldValueArray :: proc(
  fieldValueArray: ^[dynamic]data.FieldValue,
  fieldMetadataTreeNode: ^metadata.FieldMetadataTreeNode) {

  metadata := fieldMetadataTreeNode.fieldMetadata

  minLength := metadata.dataType.minArrayLength.? or_else 1

  for i in 0 ..< minLength {
    defaultValue: data.FieldValue

    switch (data.DataType(metadata.dataType.type)) {
    case .Set:
      append(fieldValueArray, make(map[int][dynamic]data.FieldValue))
      populateSetMap(
        &fieldValueArray[len(fieldValueArray) - 1].(map[int][dynamic]data.FieldValue),
        fieldMetadataTreeNode)
    case .Int8:
      v, ok := strconv.parse_int(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = i8(v)
      else do defaultValue = i8(0)
    case .UInt8:
      v, ok := strconv.parse_uint(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = u8(v)
      else do defaultValue = u8(0)
    case .Int16:
      v, ok := strconv.parse_int(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = i16(v)
      else do defaultValue = i16(0)
    case .UInt16:
      v, ok := strconv.parse_uint(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = u16(v)
      else do defaultValue = u16(0)
    case .Int32:
      v, ok := strconv.parse_int(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = i32(v)
      else do defaultValue = i32(0)
    case .UInt32:
      v, ok := strconv.parse_int(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = u32(v)
      else do defaultValue = u32(0)
    case .Int64:
      v, ok := strconv.parse_int(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = i64(v)
      else do defaultValue = i64(0)
    case .UInt64:
      v, ok := strconv.parse_uint(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = u64(v)
      else do defaultValue = u64(0)
    case .Float32:
      v, ok := strconv.parse_f32(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = f32(v)
      else do defaultValue = f32(0)
    case .Float64:
      v, ok := strconv.parse_f64(metadata.dataType.defaultValue.? or_else "0")
      if ok do defaultValue = f64(v)
      else do defaultValue = f64(0)
    case .String:
      defaultValue = metadata.dataType.defaultValue.? or_else ""
    case .Blob:
      defaultValue = nil
    }

    if data.DataType(metadata.dataType.type) != .Set {
      for j in 0 ..< (metadata.dataType.minBufferLength.? or_else 1) {
        append(fieldValueArray, defaultValue)
      }
    }
  }
}

/*
Returns the length of the array for the given field path.

**Inputs**  
- rootFieldValueArray: Root field value array.
- args:                Field path.

Example:
args: 5000, 2, 6000, 3, 7000
is read as f1 id = 5000, f1 index = 2, f2 id = 6000, f2 index = 3, f3 id = 7000

**Returns**  
- Length of array referenced by given field path.
*/
getCount :: proc(rootFieldValueArray: ^[dynamic]data.FieldValue, args: ..any) -> int {
  fieldValueArray := getFieldValueArray(rootFieldValueArray, ..args)
  return len(fieldValueArray)
}

getFieldValueArray :: proc(rootFieldValueArray: ^[dynamic]data.FieldValue, args: ..any) -> ^[dynamic]data.FieldValue {

  fieldValueMap := &rootFieldValueArray[0].(map[int][dynamic]data.FieldValue)
  index := 0

  for {
    if len(args) > 1 {
      setId, index1, arg1ok := fmt.int_from_arg(args, index)
      arrayIndex, index2, arg2ok := fmt.int_from_arg(args, index1)
      index = index2
      fieldValueMap = &fieldValueMap[setId][arrayIndex].(map[int][dynamic]data.FieldValue)
    } else if len(args) == 1 {
      fieldId, index, ok := fmt.int_from_arg(args, 0)
      return &fieldValueMap[fieldId]
    } else {
      return rootFieldValueArray
    }
  }
}

@(private = "file")
populateSetMap :: proc(
  setMap: ^map[int][dynamic]data.FieldValue,
  fieldMetadataTreeNode: ^metadata.FieldMetadataTreeNode,
) {
  for child in fieldMetadataTreeNode.children {
    setMap[child.fieldMetadata.id] = make([dynamic]data.FieldValue)
    populateFieldValueArray(&setMap[child.fieldMetadata.id], child)
  }
}
