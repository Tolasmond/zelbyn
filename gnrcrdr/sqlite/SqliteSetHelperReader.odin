package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../data"
import "../metadata"
import sql "../../sqlite3"

readSetHelper :: proc(db: ^sql.sqlite3, setHelperMap: ^map[int]^data.SetHelperRecord) -> (result: Result_Code) {
	log.debug("Reading SetHelper table")

  stmt: ^Stmt
  queryText := "SELECT * FROM SetHelper"
	queryData := mem.raw_data(queryText);
  sql.prepare_v2(db, queryData, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(data.SetHelperRecord)

  	record.formatId = sql.column_int64(stmt, i32(SetHelperColumn.formatId))
  	record.fieldId = sql.column_int64(stmt, i32(SetHelperColumn.fieldId))

  	if (sql.column_type(stmt, i32(SetHelperColumn.lengthId)) != sql.SqliteColumnType.NULL) {
    	record.lengthId = sql.column_int64(stmt, i32(SetHelperColumn.lengthId))
  	}

  	if (sql.column_type(stmt, i32(SetHelperColumn.markerId)) != sql.SqliteColumnType.NULL) {
    	record.markerId = sql.column_int64(stmt, i32(SetHelperColumn.markerId))
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
