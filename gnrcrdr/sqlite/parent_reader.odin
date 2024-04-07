package sqlite

import sql "../../sqlite3"
import dat "../data"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"

read_parent :: proc(
	db: ^sql.sqlite3,
	parent_map: ^map[int][dynamic]^dat.Parent_Record,
) -> (
	result: sql.ResultCode,
) {
	log.debug("Reading Parent table")

	stmt: ^sql.Stmt
	query_text := "SELECT * FROM Parent"
	query_data := mem.raw_data(query_text)
	sql.prepare_v2(db, query_data, i32(len(query_text)), &stmt, nil)

	for {
		result = sql.step(stmt)

		if result != .ROW do break

		record := new(dat.Parent_Record)

		record.format_id = sql.column_int64(stmt, i32(ParentColumn.format_id))
		record.parent_id = sql.column_int64(stmt, i32(ParentColumn.parent_id))
		record.child_id = sql.column_int64(stmt, i32(ParentColumn.child_id))
		record.child_index = sql.column_int64(stmt, i32(ParentColumn.child_index))

		key_exists := record.parent_id in parent_map

		if !key_exists do parent_map[record.parent_id] = make([dynamic]^dat.Parent_Record)

		append(&parent_map[record.parent_id], record)
	}

	for id, parent_records in parent_map {
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
