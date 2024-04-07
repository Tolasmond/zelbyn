package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import dat "../data"
import sql "../../sqlite3"

read_set_helper :: proc(db: ^sql.sqlite3, set_helper_map: ^map[int]^dat.Set_Helper_Record) -> (result: sql.ResultCode) {
	log.debug("Reading SetHelper table")

  stmt: ^sql.Stmt
  query_text := "SELECT * FROM SetHelper"
	query_data := mem.raw_data(query_text);
  sql.prepare_v2(db, query_data, i32(len(query_text)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(dat.Set_Helper_Record)

  	record.format_id = sql.column_int64(stmt, i32(Set_Helper_Column.format_id))
  	record.field_id = sql.column_int64(stmt, i32(Set_Helper_Column.field_id))

  	if (sql.column_type(stmt, i32(Set_Helper_Column.length_id)) != sql.SqliteColumnType.NULL) {
    	record.length_id = sql.column_int64(stmt, i32(Set_Helper_Column.length_id))
  	}

  	if (sql.column_type(stmt, i32(Set_Helper_Column.marker_id)) != sql.SqliteColumnType.NULL) {
    	record.marker_id = sql.column_int64(stmt, i32(Set_Helper_Column.marker_id))
  	}

  	set_helper_map[record.format_id] = record
	}

	return
}

Set_Helper_Column :: enum i32 {
	format_id,
	field_id,
	length_id,
	marker_id
}
