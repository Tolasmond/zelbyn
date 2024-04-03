package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../data"
import "../metadata"
import sql "../../sqlite3"

readMarkerOffset :: proc(db: ^sql.sqlite3, markerOffsetMap: ^map[int]^data.MarkerOffsetRecord) -> (result: Result_Code) {
	log.debug("Reading MarkerOffset table")

  stmt: ^Stmt
  queryText := "SELECT * FROM MarkerOffset"
	queryData := mem.raw_data(queryText);
  result = sql.prepare_v2(db, queryData, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(data.MarkerOffsetRecord)

  	record.markerId = sql.column_int64(stmt, i32(MarkerOffsetColumn.markerId))
  	record.byteOffset = sql.column_int64(stmt, i32(MarkerOffsetColumn.byteOffset))
  	record.dataTypeId = sql.column_int64(stmt, i32(MarkerOffsetColumn.dataTypeId))
  	record.marker = sql.column_int64(stmt, i32(MarkerOffsetColumn.marker))

  	markerOffsetMap[record.markerId] = record
	}

	return
}

MarkerOffsetColumn :: enum i32 {
	markerId,
	byteOffset,
	dataTypeId,
	marker
}
