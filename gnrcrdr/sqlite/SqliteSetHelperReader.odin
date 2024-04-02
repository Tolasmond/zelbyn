package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../metadata"
import sql "../../sqlite3"

readSetHelper :: proc(db: ^sql.sqlite3, setHelperMap: ^map[i32]^metadata.SetHelperRecord) -> (result: Result_Code) {
	log.debug("Reading SetHelper table")

  stmt: ^Stmt
  queryText := "SELECT * FROM SetHelper"
	data := mem.raw_data(queryText);
  sql.prepare_v2(db, data, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(metadata.SetHelperRecord)

  	record.formatId = sql.column_int(stmt, i32(SetHelperColumn.formatId))
  	record.fieldId = sql.column_int(stmt, i32(SetHelperColumn.fieldId))

  	if (sql.column_type(stmt, i32(SetHelperColumn.lengthId)) != sql.SqliteColumnType.NULL) {
    	record.lengthId = sql.column_int(stmt, i32(SetHelperColumn.lengthId))
  	}

  	if (sql.column_type(stmt, i32(SetHelperColumn.markerId)) != sql.SqliteColumnType.NULL) {
    	record.markerId = sql.column_int(stmt, i32(SetHelperColumn.markerId))
  	}

  	setHelperMap[record.formatId] = record
	}

	return
}

SetHelperColumn :: enum i32 {
	formatId,
	fieldId,
	lengthId,
	markerId
}
