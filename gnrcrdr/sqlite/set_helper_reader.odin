package sqlite

import "core:log"
import "core:mem"
import dat "../data"
import sql "../../sqlite3"

read_set_helper :: proc(db: ^sql.sqlite3, format_id: int, set_helper_map: ^map[int]^dat.Set_Helper_Record, allocator: mem.Allocator) -> (result: sql.ResultCode) {
	log.debug("Reading SetHelper table")
	set_helper_map^ = make(map[int]^dat.Set_Helper_Record, allocator)

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM SetHelper WHERE FormatId = ?1", &stmt)
	if rc != .OK do return rc
	defer sql.finalize(stmt)
	rc = sql.bind_int64(stmt, 1, i64(format_id))
	if rc != .OK do return rc

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record := new(dat.Set_Helper_Record, allocator)

		record.format_id = sql.column_int64(stmt, i32(Set_Helper_Column.format_id))
		record.field_id = sql.column_int64(stmt, i32(Set_Helper_Column.field_id))

		if (sql.column_type(stmt, i32(Set_Helper_Column.length_id)) != sql.SqliteColumnType.NULL) {
			record.length_id = sql.column_int64(stmt, i32(Set_Helper_Column.length_id))
		}

		if (sql.column_type(stmt, i32(Set_Helper_Column.marker_id)) != sql.SqliteColumnType.NULL) {
			record.marker_id = sql.column_int64(stmt, i32(Set_Helper_Column.marker_id))
		}

		set_helper_map[record.field_id] = record
	}

	return
}

Set_Helper_Column :: enum i32 {
	format_id,
	field_id,
	length_id,
	marker_id,
}
