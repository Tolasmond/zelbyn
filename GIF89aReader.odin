package main

import "core:fmt"
import "core:log"
import "gnrcrdr/data"
import "gnrcrdr/manip"
import "gnrcrdr/metadata"
import "gnrcrdr/sqlite"

main :: proc() {

  context.logger = log.create_console_logger()  

  fileFormat: metadata.FileFormat
  dbFilePath:= "GIF89aMetadata.sqlite3"

  log.debugf("reading %v", dbFilePath)

  sqlite.readFileFormat(dbFilePath, 1, &fileFormat)

  log.debug("populating field value array")
  
  rootFieldValueArray := make([dynamic]data.FieldValue)

  log.debugf("rootFieldValueArray len = %v", len(rootFieldValueArray))

  manip.populateFieldValueArray(&rootFieldValueArray, &fileFormat.rootMetadataTreeNode)

  log.debugf("rootFieldValueArray len = %v", len(rootFieldValueArray))

  log.debug("getting count")

  count := manip.getCount(&rootFieldValueArray)

  log.debugf("count = %v", count)
}
