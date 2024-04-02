package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../datatype"
import "../metadata"
import sql "../../sqlite3"

readField :: proc(db: ^sql.sqlite3, packedRecords: []^metadata.PackedRecord, fieldMetadataMap: ^map[i32]^metadata.FieldMetadata) -> (result: Result_Code) {
	log.debug("Reading Field table")

  stmt: ^Stmt
  queryText := "SELECT * FROM Field"
	data := mem.raw_data(queryText);
  sql.prepare_v2(db, data, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record: metadata.FieldRecord

  	record.id = sql.column_int(stmt, i32(FieldColumn.id))

		name : cstring = sql.column_text(stmt, i32(FieldColumn.name))
 		record.name = strings.clone(string(name))

  	record.dataTypeId = sql.column_int(stmt, i32(FieldColumn.dataTypeId))

  	fieldMetadata := new(metadata.FieldMetadata)
  	fieldMetadata.id = record.id;
  	fieldMetadata.name = record.name;
  	fieldMetadata.dataTypeId = record.dataTypeId

    startIndex := -1
    endIndex := -1

    for packedRecord, index in packedRecords {
			if packedRecord.id == record.id {
			  if startIndex < 0 {
				  startIndex = index
			  } else {
			  	endIndex = index
			  }
			}
		}

    if startIndex >= 0 do fieldMetadata.packedFields = packedRecords[startIndex:endIndex]

  	fieldMetadataMap[record.id] = fieldMetadata
	}

	return
}

FieldColumn :: enum i32 {
	id,
	name,
	dataTypeId
}
