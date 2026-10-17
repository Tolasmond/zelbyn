package sqlite

import sql "../../sqlite3"
import dat "../data"
import "core:log"
import "core:slice"

read_parent :: proc(
	db: ^sql.sqlite3,
	format_id: int,
	parent_map: ^map[int][dynamic]^dat.Parent_Record,
) -> (
	result: sql.ResultCode,
) {
	log.debug("Reading Parent table")

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM Parent WHERE FormatId = ?1", &stmt)
	if rc != .OK do return rc
	defer sql.finalize(stmt)
	rc = sql.bind_int64(stmt, 1, i64(format_id))
	if rc != .OK do return rc

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record := new(dat.Parent_Record)

		record.format_id = sql.column_int64(stmt, i32(ParentColumn.format_id))
		record.parent_id = sql.column_int64(stmt, i32(ParentColumn.parent_id))
		record.child_id = sql.column_int64(stmt, i32(ParentColumn.child_id))
		record.child_index = sql.column_int64(stmt, i32(ParentColumn.child_index))

		key_exists := record.parent_id in parent_map

		if !key_exists do parent_map[record.parent_id] = make([dynamic]^dat.Parent_Record)

		append(&parent_map[record.parent_id], record)
	}

	if result != .OK do return

	for _, parent_records in parent_map {
		slice.sort_by(parent_records[:], dat.sort_parent_records_by_child_index)
	}

	return
}

ParentColumn :: enum i32 {
	format_id,
	parent_id,
	child_id,
	child_index,
}
