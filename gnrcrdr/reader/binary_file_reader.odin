package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:os"

read :: proc(name: string, file_format: ^mdata.File_Format, root_field_value_array: ^[dynamic]fld.Value) {
  buffer: dat.Byte_Buffer
  dat.read_file_into_buffer(&buffer, name)
  read_set(root_field_value_array, &file_format.root_metadata_node, &file_format.metadata, &buffer)
}


@(private = "file")
read_set :: proc(
    parent_field: ^[dynamic]fld.Value,
    metadata_node: ^mdata.Field_Metadata_Tree_Node,
    metadata: ^mdata.Field_Metadata_Provider,
    buffer: ^dat.Byte_Buffer) {

  count := fld.adjust_count(parent_field, metadata_node, metadata, buffer)
}
