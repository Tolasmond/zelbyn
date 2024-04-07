package field

import dat "../data"
import fld "../field"
import mdat "../metadata"
import "core:fmt"
import "core:strconv"

initializeFieldValueArray :: proc(
  field_value_array: ^[dynamic]fld.Value,
  metadata_node: ^mdat.Field_Metadata_Tree_Node) {

  metadata := metadata_node.metadata

  min_length := metadata.data_type.min_array_length.? or_else 1

  for i in 0 ..< min_length {
    default_value: fld.Value

    switch (dat.Data_Type(metadata.data_type.type)) {
    case .Set:
      append(field_value_array, make(map[int][dynamic]fld.Value))
      initialize_set_map(
        &field_value_array[len(field_value_array) - 1].(map[int][dynamic]fld.Value),
        metadata_node)
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

    if dat.Data_Type(metadata.data_type.type) != .Set {
      for j in 0 ..< (metadata.data_type.min_buffer_length.? or_else 1) {
        append(field_value_array, default_value)
      }
    }
  }
}

/*
Returns the length of the array for the given field path.

**Inputs**  
- parent_field: Root field value array.
- args:         Field path.

Example:
args: 5000, 2, 6000, 3, 7000
is read as f1 id = 5000, f1 index = 2, f2 id = 6000, f2 index = 3, f3 id = 7000

**Returns**  
- Length of array referenced by given field path.
*/
get_count :: proc(parent_field: ^[dynamic]fld.Value, path: ..any) -> int {
  field_value_array := get_field(parent_field, ..path)
  return len(field_value_array)
}

get_field :: proc(parent_field: ^[dynamic]fld.Value, path: ..any) -> ^[dynamic]fld.Value {

  field_value_map := &parent_field[0].(map[int][dynamic]fld.Value)
  index := 0

  for {
    if len(path) > 1 {
      set_id, index1, arg1ok := fmt.int_from_arg(path, index)
      array_index, index2, arg2ok := fmt.int_from_arg(path, index1)
      index = index2
      field_value_map = &field_value_map[set_id][array_index].(map[int][dynamic]fld.Value)
    } else if len(path) == 1 {
      field_id, index, ok := fmt.int_from_arg(path, 0)
      return &field_value_map[field_id]
    } else {
      return parent_field
    }
  }
}

remove_at :: proc(i: int, parent_field: ^[dynamic]fld.Value, path: ..any) {
  array := get_field(parent_field, path)
  ordered_remove(array, i)
}

add :: proc(metadata_node: ^mdat.Field_Metadata_Tree_Node, parent_field: ^[dynamic]fld.Value, path: ..any) {
  append(parent_field, make(map[int][dynamic]fld.Value))
  initialize_set_map(
    &parent_field[len(parent_field) - 1].(map[int][dynamic]fld.Value),
    metadata_node)
}

destroy_field :: proc(field: [dynamic]fld.Value) {
  for value in field {
    set_map, is_set_map := value.(map[int][dynamic]fld.Value)

    if is_set_map {
      for _, fld_value in set_map {
        destroy_field(fld_value)
      }
      delete(set_map)
    }
  }
  delete(field)
}

@(private = "file")
initialize_set_map :: proc(
  set_map: ^map[int][dynamic]fld.Value,
  metadata_node: ^mdat.Field_Metadata_Tree_Node) {
  for child in metadata_node.children {
    set_map[child.metadata.id] = make([dynamic]fld.Value)
    initializeFieldValueArray(&set_map[child.metadata.id], child)
  }
}

