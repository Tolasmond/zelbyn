package sqlite

import sql "../../sqlite3"
import "../metadata"
import "core:log"
import "core:mem"
import "core:strings"

readFormat :: proc(db: ^sql.sqlite3, record: ^metadata.FormatRecord) -> (result: Result_Code) {
	log.debug("Reading Format table")

	stmt: ^Stmt
	queryText := "SELECT * FROM Length"
	data := mem.raw_data(queryText)
	sql.prepare_v2(db, data, i32(len(queryText)), &stmt, nil)

	result = sql.step(stmt)

  if result != .ROW do return;

	record.id = sql.column_int(stmt, i32(FormatColumn.id))

	if (sql.column_type(stmt, i32(FormatColumn.name)) != sql.SqliteColumnType.NULL) {
		name: cstring = sql.column_text(stmt, i32(FormatColumn.name))
		record.name = strings.clone(string(name))
	}

	record.rootField = sql.column_int(stmt, i32(FormatColumn.rootField))

	return
}

FormatColumn :: enum i32 {
	id,
	name,
	rootField,
}
