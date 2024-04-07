package main

import "core:fmt"
import "core:log"
import fld "gnrcrdr/field"
import mdat "gnrcrdr/metadata"
import rdr "gnrcrdr/reader"
import sql "gnrcrdr/sqlite"

main :: proc() {

  context.logger = log.create_console_logger()  

  file_format: mdat.File_Format
  dbFilePath:= "GIF89aMetadata.sqlite3"

  log.debugf("reading %v", dbFilePath)

  sql.read_file_format(dbFilePath, 1, &file_format)

  log.debug("populating field value array")
  
  root_field := make([dynamic]fld.Value)

  log.debugf("root_field len = %v", len(root_field))

  fld.initializeFieldValueArray(&root_field, &file_format.root_metadata_node)

  rdr.read("data/855.gif", &file_format, &root_field)
}
