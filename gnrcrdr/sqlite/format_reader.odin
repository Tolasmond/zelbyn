package sqlite

import sql "../../sqlite3"
import dat "../data"
import "core:log"
import "core:strings"

read_format :: proc(db: ^sql.sqlite3, format_id: int, record: ^dat.Format_Record) -> (found: bool, result: sql.ResultCode) {
	log.debug("Reading Format table")

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM Format WHERE Id = ?1", &stmt)
	if rc != .OK do return false, rc
	defer sql.finalize(stmt)
	rc = sql.bind_int64(stmt, 1, i64(format_id))
	if rc != .OK do return false, rc

	found, result = step(stmt)

	if !found do return

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
