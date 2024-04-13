package main

import "core:fmt"
import "core:log"
import "core:mem"
import fld "gnrcrdr/field"
import mdat "gnrcrdr/metadata"
import rdr "gnrcrdr/reader"
import sql "gnrcrdr/sqlite"

main :: proc() {

  context.logger = log.create_console_logger()  

  // tracking_allocator: mem.Tracking_Allocator
  // mem.tracking_allocator_init(&tracking_allocator, context.allocator)
  // context.allocator = mem.tracking_allocator(&tracking_allocator)

  file_format: mdat.File_Format
  dbFilePath:= "data/GIF89aMetadata.sqlite3"

  log.debugf("reading %v", dbFilePath)

  sql.read_file_format(dbFilePath, 1, &file_format)

  log.debug("populating field value array")
  
  root_field := make([dynamic]fld.Value)

  fld.initializeFieldValueArray(&root_field, &file_format.root_metadata_node)

  rdr.read("data/855.gif", &file_format, &root_field)

  fld.destroy_field(root_field)

  mdat.destroy_file_format(&file_format)

  // reset_tracking_allocator(&tracking_allocator)
  // mem.tracking_allocator_destroy(&tracking_allocator)
}

reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
  leaks := false

  if len(a.allocation_map) != 0 {
    fmt.printfln("%v leaks found!", len(a.allocation_map))
  }

  for key, value in a.allocation_map {
    fmt.printfln("%v: Leaked %v bytes", value.location, value.size)
    leaks = true
  }

  mem.tracking_allocator_clear(a)
  return leaks
}
