package manip

import "../data"
import "../metadata"
import "core:fmt"
import "core:strconv"

initializeFieldValueArray :: proc(
  field_value_array: ^[dynamic]data.Field_Value,
  field_metadata_tree_node: ^metadata.Field_Metadata_Tree_Node) {

  metadata := field_metadata_tree_node.field_metadata

  min_length := metadata.data_type.min_array_length.? or_else 1

  for i in 0 ..< min_length {
    default_value: data.Field_Value

    switch (data.Data_Type(metadata.data_type.type)) {
    case .Set:
      append(field_value_array, make(map[int][dynamic]data.Field_Value))
      populateSetMap(
        &field_value_array[len(field_value_array) - 1].(map[int][dynamic]data.Field_Value),
        field_metadata_tree_node)
    case .Int8:
      v, ok := strconv.parse_int(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = i8(v)
      else do default_value = i8(0)
    case .UInt8:
      v, ok := strconv.parse_uint(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = u8(v)
      else do default_value = u8(0)
    case .Int16:
      v, ok := strconv.parse_int(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = i16(v)
      else do default_value = i16(0)
    case .UInt16:
      v, ok := strconv.parse_uint(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = u16(v)
      else do default_value = u16(0)
    case .Int32:
      v, ok := strconv.parse_int(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = i32(v)
      else do default_value = i32(0)
    case .UInt32:
      v, ok := strconv.parse_int(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = u32(v)
      else do default_value = u32(0)
    case .Int64:
      v, ok := strconv.parse_int(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = i64(v)
      else do default_value = i64(0)
    case .UInt64:
      v, ok := strconv.parse_uint(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = u64(v)
      else do default_value = u64(0)
    case .Float32:
      v, ok := strconv.parse_f32(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = f32(v)
      else do default_value = f32(0)
    case .Float64:
      v, ok := strconv.parse_f64(metadata.data_type.default_value.? or_else "0")
      if ok do default_value = f64(v)
      else do default_value = f64(0)
    case .String:
      default_value = metadata.data_type.default_value.? or_else ""
    case .Blob:
      default_value = nil
    }

    if data.Data_Type(metadata.data_type.type) != .Set {
      for j in 0 ..< (metadata.data_type.min_buffer_length.? or_else 1) {
        append(field_value_array, default_value)
      }
    }
  }
}

/*
Returns the length of the array for the given field path.

**Inputs**  
- root_field_value_array: Root field value array.
- args:                Field path.

Example:
args: 5000, 2, 6000, 3, 7000
is read as f1 id = 5000, f1 index = 2, f2 id = 6000, f2 index = 3, f3 id = 7000

**Returns**  
- Length of array referenced by given field path.
*/
getCount :: proc(root_field_value_array: ^[dynamic]data.Field_Value, args: ..any) -> int {
  field_value_array := getFieldValueArray(root_field_value_array, ..args)
  return len(field_value_array)
}

getFieldValueArray :: proc(root_field_value_array: ^[dynamic]data.Field_Value, args: ..any) -> ^[dynamic]data.Field_Value {

  field_value_map := &root_field_value_array[0].(map[int][dynamic]data.Field_Value)
  index := 0

  for {
    if len(args) > 1 {
      set_id, index1, arg1ok := fmt.int_from_arg(args, index)
      array_index, index2, arg2ok := fmt.int_from_arg(args, index1)
      index = index2
      field_value_map = &field_value_map[set_id][array_index].(map[int][dynamic]data.Field_Value)
    } else if len(args) == 1 {
      field_id, index, ok := fmt.int_from_arg(args, 0)
      return &field_value_map[field_id]
    } else {
      return root_field_value_array
    }
  }
}

@(private = "file")
populateSetMap :: proc(
  set_map: ^map[int][dynamic]data.Field_Value,
  field_metadata_tree_node: ^metadata.Field_Metadata_Tree_Node) {
  for child in field_metadata_tree_node.children {
    set_map[child.field_metadata.id] = make([dynamic]data.Field_Value)
    initializeFieldValueArray(&set_map[child.field_metadata.id], child)
  }
}
