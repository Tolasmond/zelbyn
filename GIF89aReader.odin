package main

import "core:fmt"
import "core:log"
import "gnrcrdr/metadata"
import "gnrcrdr/sqlite"

main :: proc() {

	context.logger = log.create_console_logger()  

	fileFormat: metadata.FileFormat
	dbFilePath:= "GIF89aMetadata.sqlite3"

  log.debugf("reading %v", dbFilePath)

	sqlite.readFileFormat(dbFilePath, 1, &fileFormat)

  


	// test: metadata.FieldMetadata
	// test.id = 1
	// test.dataType.id = 2
	// test.dataType.dataType = datatype.DataType.Int32

	// fmt.printf("id = %v\n", test.id)
	// fmt.printf("dataType = %v\n", test.dataType.dataType)
	// fmt.printf(datatype.description(&test.dataType))
}
