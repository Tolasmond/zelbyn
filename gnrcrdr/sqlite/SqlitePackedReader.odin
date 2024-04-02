package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../metadata"
import sql "../../sqlite3"

readPacked :: proc(db: ^sql.sqlite3, packedRecords: ^[dynamic]^metadata.PackedRecord) -> (result: Result_Code) {
	log.debug("Reading Packed table")

  stmt: ^Stmt
  queryText := "SELECT * FROM Packed"
	data := mem.raw_data(queryText);
  sql.prepare_v2(db, data, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(metadata.PackedRecord)

  	record.id = sql.column_int(stmt, i32(PackedColumn.id))
  	record.fieldId = sql.column_int(stmt, i32(PackedColumn.fieldId))
  	record.lowBit = sql.column_int(stmt, i32(PackedColumn.lowBit))
  	record.highBit = sql.column_int(stmt, i32(PackedColumn.highBit))

    append(packedRecords, record)
	}

	return
}

PackedColumn :: enum i32 {
	id,
	fieldId,
	lowBit,
	highBit
}
