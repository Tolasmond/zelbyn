package field

import dat  "../data"
import eval "../evaluate"
import fld  "../field"
import mdat "../metadata"

adjust_count :: proc(
  parent_field: ^[dynamic]fld.Value,
  metadata_node: ^mdat.Field_Metadata_Tree_Node,
  metadata: ^mdat.Field_Metadata_Provider,
  buffer: ^dat.Byte_Buffer, path: ..any) -> int {
  
  set_helper_rec := metadata.set_helper_map[metadata_node.metadata.id]

  marker_id, marker_id_exists := set_helper_rec.marker_id.?

  length_id, length_id_exists := set_helper_rec.length_id.?

  count := 0

  if marker_id_exists {

    marker_off_recs := metadata.marker_offset_map[marker_id]

    marker_found := true

    // peek ahead to see if marker(s) exist
    for marker_off_rec in marker_off_recs {
      off := buffer.data.off
      buffer.data.off = marker_off_rec.byte_offset
      marker, ok := dat.read_integer(buffer, dat.Data_Type(marker_off_rec.data_type_id))
      buffer.data.off = off
      if marker == marker_off_rec.marker {
        continue
      }

      marker_found = false
      break;
    }

    count = marker_found ? 1 : 0

    set_count := get_count(parent_field, ..path)
    for count < set_count {
      fld.remove_at(set_count - 1, parent_field, ..path)
      set_count = get_count(parent_field, ..path)
    }
  }
  else if length_id_exists {
    length_rec := metadata.set_length_map[length_id]

    flag_exists := false
    flag_value := 1

    flag_abs_pos, flag_abs_pos_exists := length_rec.flag_absoute_offset_from_beginning.?

    flag_rel_pos, flag_rel_pos_exists := length_rec.flag_relative_offset_from_field.?

    if flag_abs_pos_exists {
      pos := buffer.data.off
      buffer.data.off = flag_abs_pos
      flag_value, ok := dat.read_integer(buffer, dat.Data_Type(length_rec.data_type_id))
      buffer.data.off = pos
      flag_exists = true
    }
    else if flag_rel_pos_exists {
      pos := buffer.data.off
      buffer.data.off = buffer.data.off + flag_rel_pos
      flag_value, ok := dat.read_integer(buffer, dat.Data_Type(length_rec.data_type_id))
      buffer.data.off = pos
      flag_exists = true
    }

    if flag_exists {
      flag_mask, flag_mask_exists := length_rec.flag_mask.?
      flag_shift, flag_shift_exists := length_rec.flag_shift.?

      if flag_mask_exists {
        flag_value &= flag_mask
      }

      if flag_shift_exists {
        flag_value >>= u32(flag_shift)
      }
    }

    if flag_value == 0 {
      count = 0
    }
    else {
      value_abs_pos, value_abs_pos_exists := length_rec.value_absolute_offset_from_beginning.?
      value_rel_pos, value_rel_pos_exists := length_rec.value_relative_offset_from_field.?
      value_mask, value_mask_exists := length_rec.value_mask.?
      value_shift, value_shift_exists := length_rec.value_shift.?
      value_expr, value_expr_exists := length_rec.value_expression.?

      if value_abs_pos_exists {
        pos := buffer.data.off
        buffer.data.off = value_abs_pos
        count, ok := dat.read_integer(buffer, dat.Data_Type(length_rec.data_type_id))
        buffer.data.off = pos
      }

      if value_rel_pos_exists {
        pos := buffer.data.off
        buffer.data.off = buffer.data.off + value_rel_pos
        count, ok := dat.read_integer(buffer, dat.Data_Type(length_rec.data_type_id))
        buffer.data.off = pos
      }

      if value_mask_exists {
        count &= value_mask
      }

      if value_shift_exists {
        count >>= u32(value_shift)
      }

      if value_expr_exists {
        param_map := make(map[string]int)
        param_map["x"] = count
        defer delete(param_map)
        count = eval.evaluate(value_expr, &param_map)
      }
    }

    set_count(count, metadata_node, parent_field, ..path)
  }
  else {
    count = fld.get_count(parent_field, ..path)
  }

  return count
}

set_count :: proc(count: int, metadata_node: ^mdat.Field_Metadata_Tree_Node, parent_field: ^[dynamic]fld.Value, path: ..any) {
  for count > fld.get_count(parent_field, ..path) {
    new_field := make([dynamic]fld.Value)
    fld.initializeFieldValueArray(&new_field, metadata_node)
    fld.add(metadata_node, parent_field, ..path)
  }

  for count < fld.get_count(parent_field, ..path) {
    fld.remove_at(fld.get_count(parent_field, ..path) - 1, parent_field, ..path)
  }
}