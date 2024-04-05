package manip

import "../data"
import "../metadata"
import "../reader"

adjust_count :: proc(field_metadata_tree_node: ^metadata.Field_Metadata_Tree_Node, field_metadata_provider: ^metadata.Field_Metadata_Provider, buffer: ^data.Byte_Buffer, args: ..int) -> int {
  set_helper_record := field_metadata_provider.set_helper_map[field_metadata_tree_node.field_metadata.id]

  count := 0

  marker_id, marker_id_exists := set_helper_record.marker_id.?

  if marker_id_exists {

    marker_offset_records := field_metadata_provider.marker_offset_map[marker_id]

    // peek ahead to see if marker(s) exist
    for marker_offset_record in marker_offset_records {
      off := buffer.data.off
      buffer.data.off = marker_offset_record.byte_offset
      marker, ok := reader.read_integer(buffer, data.Data_Type(marker_offset_record.data_type_id))
      buffer.data.off = off
      if marker == marker_offset_record.marker {
        continue
      }
    }

  }

  return 0
}