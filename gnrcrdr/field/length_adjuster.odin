package field

import dat  "../data"
import eval "../evaluate"
import fld  "../field"
import mdat "../metadata"

adjust_count :: proc(
  field: ^[dynamic]fld.Value,
  node: ^mdat.Field_Metadata_Tree_Node,
  metadata: ^mdat.Field_Metadata_Provider,
  buf: ^dat.Byte_Buffer) -> int {
  
  set_helper_rec := metadata.set_helper_map[node.metadata.id]

  marker_id := 0
  length_id := 0
  marker_id_exists := false
  length_id_exists := false

  if set_helper_rec != nil {
    marker_id, marker_id_exists = set_helper_rec.marker_id.?
    length_id, length_id_exists = set_helper_rec.length_id.?
  }

  count := 0

  if marker_id_exists {

    marker_off_recs := metadata.marker_offset_map[marker_id]

    marker_found := true

    // peek ahead to see if marker(s) exist
    for marker_off_rec in marker_off_recs {
      pos := buf.data.off
      buf.data.off = buf.data.off + marker_off_rec.byte_offset
      marker_data_type_rec := metadata.data_type_map[marker_off_rec.data_type_id]
      marker, _ := dat.get_integer(buf, dat.Data_Type(marker_data_type_rec.type))
      buf.data.off = pos
      if marker == marker_off_rec.marker {
        continue
      }

      marker_found = false
    }

    count = marker_found ? 1 : 0

    set_count(count, node, field)
  }
  else if length_id_exists {

    length_rec := metadata.set_length_map[length_id]

    length_data_type_rec := metadata.data_type_map[length_rec.data_type_id]

    flag_value := 1

    flag_abs_pos, flag_abs_pos_exists := length_rec.flag_absoute_offset_from_beginning.?

    flag_rel_pos, flag_rel_pos_exists := length_rec.flag_relative_offset_from_field.?

    if flag_abs_pos_exists {
      pos := buf.data.off
      buf.data.off = flag_abs_pos
      flag_value, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
      buf.data.off = pos
    }
    else if flag_rel_pos_exists {
      pos := buf.data.off
      buf.data.off = buf.data.off + flag_rel_pos
      flag_value, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
      buf.data.off = pos
    }

    if flag_abs_pos_exists || flag_rel_pos_exists {
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
        pos := buf.data.off
        buf.data.off = value_abs_pos
        count, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
        buf.data.off = pos
      }

      if value_rel_pos_exists {
        pos := buf.data.off
        buf.data.off = buf.data.off + value_rel_pos
        count, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
        buf.data.off = pos
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

    set_count(count, node, field)
  }
  else {
    count = len(field)
  }

  return count
}

get_buffer_length :: proc(
  node: ^mdat.Field_Metadata_Tree_Node,
  metadata: ^mdat.Field_Metadata_Provider,
  buf: ^dat.Byte_Buffer) -> int {

  data_type_rec := node.metadata.data_type

  buffer_length, _ := data_type_rec.max_buffer_length.?

  if data_type_rec.min_buffer_length != data_type_rec.max_buffer_length {

    set_helper_rec := metadata.set_helper_map[node.metadata.id]

    length_id := 0
    length_id_exists := false

    if set_helper_rec != nil {
      length_id, length_id_exists = set_helper_rec.length_id.?

      if length_id_exists {

        length_rec := metadata.set_length_map[length_id]

        length_data_type_rec := metadata.data_type_map[length_rec.data_type_id]

        flag_value := 1

        flag_abs_pos, flag_abs_pos_exists := length_rec.flag_absoute_offset_from_beginning.?

        flag_rel_pos, flag_rel_pos_exists := length_rec.flag_relative_offset_from_field.?

        if flag_abs_pos_exists {
          pos := buf.data.off
          buf.data.off = flag_abs_pos
          flag_value, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
          buf.data.off = pos
        }
        else if flag_rel_pos_exists {
          pos := buf.data.off
          buf.data.off = buf.data.off + flag_rel_pos
          flag_value, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
          buf.data.off = pos
        }

        if flag_abs_pos_exists || flag_rel_pos_exists {
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
          return 0
        } 

        value_abs_pos, value_abs_pos_exists := length_rec.value_absolute_offset_from_beginning.?
        value_rel_pos, value_rel_pos_exists := length_rec.value_relative_offset_from_field.?
        value_mask, value_mask_exists := length_rec.value_mask.?
        value_shift, value_shift_exists := length_rec.value_shift.?
        value_expr, value_expr_exists := length_rec.value_expression.?

        if value_abs_pos_exists {
          pos := buf.data.off
          buf.data.off = value_abs_pos
          buffer_length, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
          buf.data.off = pos
        }

        if value_rel_pos_exists {
          pos := buf.data.off
          buf.data.off = buf.data.off + value_rel_pos
          buffer_length, _ = dat.get_integer(buf, dat.Data_Type(length_data_type_rec.type))
          buf.data.off = pos
        }

        if value_mask_exists {
          buffer_length &= value_mask
        }

        if value_shift_exists {
          buffer_length >>= u32(value_shift)
        }
      }
    }
  }

  return buffer_length
}
