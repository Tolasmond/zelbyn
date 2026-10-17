package field

import dat "../data"
import fld "../field"
import mdat "../metadata"
import "core:log"
import "core:strconv"
import "core:strings"

initializeFieldValueArray :: proc(
  field_value_array: ^[dynamic]fld.Value,
  node: ^mdat.Field_Metadata_Tree_Node) {

  metadata := node.metadata

  min_length := metadata.data_type.min_array_length.? or_else 1

  default_value: fld.Value

  data_type := dat.Data_Type(metadata.data_type.type)

  switch data_type {
  case .Set:
    for _ in 0 ..< min_length {
      //new_map := make(map[int][dynamic]fld.Value)
      new_map : map[int][dynamic]fld.Value
      initialize_set_map(&new_map, node)
      append(field_value_array, new_map)
    }
    return
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
    // each element owns its own copy; the metadata keeps the original
    for _ in 0 ..< min_length {
      append(field_value_array, fld.Value(strings.clone(metadata.data_type.default_value.? or_else "")))
    }
    return
  case .Blob:
    default_value = nil
  }

  for _ in 0 ..< min_length do append(field_value_array, default_value)
}

/*
Returns the length of the array for the given field path.

**Inputs**  
- parent_field: Root field value array.
- path:         Field path.

**Returns**  
- Length of array referenced by given field path.
*/
get_count :: proc(parent_field: ^[dynamic]fld.Value, path_pair: ^Path_Pair) -> int {
  field_value_array := get_field(parent_field, path_pair)
  return len(field_value_array)
}

set_count :: proc(count: int, node: ^mdat.Field_Metadata_Tree_Node, field: ^[dynamic]fld.Value) {
  for count > len(field) {
    append_set_instance(node, field)
  }

  for count < len(field) {
    remove_at(len(field) - 1, field)
  }
}

get_field :: proc(parent_field: ^[dynamic]fld.Value, path_pair: ^Path_Pair) -> ^[dynamic]fld.Value {

  if path_pair == nil {
    return parent_field
  }

  field_value_map := &parent_field[0].(map[int][dynamic]fld.Value)

  field, ok := &field_value_map[path_pair.id]

  if !ok {
    log.debugf("field_value_map does not have key %v", path_pair.id)

    for key, _ in field_value_map {
      log.debugf("key = %v", key)
    }
  }

  return field
}

remove_at :: proc(i: int, field: ^[dynamic]fld.Value) {
  destroy_value_in_field(field[i])
  ordered_remove(field, i)
}

append_set_instance :: proc(node: ^mdat.Field_Metadata_Tree_Node, parent_field: ^[dynamic]fld.Value) {
  append(parent_field, make(map[int][dynamic]fld.Value))
  initialize_set_map(
    &parent_field[len(parent_field) - 1].(map[int][dynamic]fld.Value),
    node)
}

destroy_field :: proc(field: [dynamic]fld.Value) {
  for value in field {
    destroy_value_in_field(value)
  }
  delete(field)
}

@(private = "file")
destroy_value_in_field :: proc(value: fld.Value) {
  set_map, is_set_map := value.(map[int][dynamic]fld.Value)
  blob, is_blob := value.([]byte)
  str, is_str := value.(string)

  if is_set_map {
    for _, fld_value in set_map {
      destroy_field(fld_value)
    }
    delete(set_map)
  }
  else if is_blob {
    delete(blob)
  }
  else if is_str {
    delete(str)
  }
}

set_value :: proc(node: ^mdat.Field_Metadata_Tree_Node, parent_field: ^[dynamic]fld.Value, path_pair: ^Path_Pair, index: int, value: fld.Value) {
  field := get_field(parent_field, path_pair)
  destroy_value_in_field(field[index])
  field[index] = value
}

initialize_set_map :: proc(set_map: ^map[int][dynamic]fld.Value, node: ^mdat.Field_Metadata_Tree_Node) {
  for child in node.children {
    new_arr: [dynamic]fld.Value
    initializeFieldValueArray(&new_arr, child)
    set_map[child.metadata.id] = new_arr
  }
}

