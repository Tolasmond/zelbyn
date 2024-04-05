package sqlite

import sql "../../sqlite3"
import "../data"
import "../metadata"
import "core:log"
import "core:mem"
import "core:strings"

read_format :: proc(db: ^sql.sqlite3, record: ^data.Format_Record) -> (result: sql.ResultCode) {
	log.debug("Reading Format table")

	stmt: ^sql.Stmt
	query_text := "SELECT * FROM Format"
	data := mem.raw_data(query_text)
	sql.prepare_v2(db, data, i32(len(query_text)), &stmt, nil)

	result = sql.step(stmt)

  if result != .ROW do return;

	record.id = sql.column_int64(stmt, i32(Format_Column.id))

	if (sql.column_type(stmt, i32(Format_Column.name)) != sql.SqliteColumnType.NULL) {
		name: cstring = sql.column_text(stmt, i32(Format_Column.name))
		record.name = strings.clone(string(name))
	}

	record.root_field = sql.column_int64(stmt, i32(Format_Column.root_field))

	return
}

Format_Column :: enum i32 {
	id,
	name,
	root_field,
}
