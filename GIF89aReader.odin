package main

import "core:fmt"
import "core:log"
import "gnrcrdr/data"
import "gnrcrdr/manip"
import "gnrcrdr/metadata"
import "gnrcrdr/reader"
import "gnrcrdr/sqlite"

main :: proc() {

  context.logger = log.create_console_logger()  

  file_format: metadata.File_Format
  dbFilePath:= "GIF89aMetadata.sqlite3"

  log.debugf("reading %v", dbFilePath)

  sqlite.read_file_format(dbFilePath, 1, &file_format)

  log.debug("populating field value array")
  
  root_field_value_array := make([dynamic]data.Field_Value)

  log.debugf("root_field_value_array len = %v", len(root_field_value_array))

  manip.initializeFieldValueArray(&root_field_value_array, &file_format.root_metadata_tree_node)

  reader.read("data/855.gif", &file_format, &root_field_value_array)

}
