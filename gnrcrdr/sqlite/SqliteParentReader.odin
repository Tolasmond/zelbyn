package sqlite

import sql "../../sqlite3"
import "../data"
import "../metadata"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"

readParent :: proc(
	db: ^sql.sqlite3,
	parentMap: ^map[int][dynamic]^data.ParentRecord,
) -> (
	result: Result_Code,
) {
	log.debug("Reading Parent table")

	stmt: ^Stmt
	queryText := "SELECT * FROM Parent"
	queryData := mem.raw_data(queryText)
	sql.prepare_v2(db, queryData, i32(len(queryText)), &stmt, nil)

	for {
		result = sql.step(stmt)

		if result != .ROW do break

		record := new(data.ParentRecord)

		record.formatId = sql.column_int64(stmt, i32(ParentColumn.formatId))
		record.parentId = sql.column_int64(stmt, i32(ParentColumn.parentId))
		record.childId = sql.column_int64(stmt, i32(ParentColumn.childId))
		record.childIndex = sql.column_int64(stmt, i32(ParentColumn.childIndex))

		keyExists := record.parentId in parentMap

		if !keyExists do parentMap[record.parentId] = make([dynamic]^data.ParentRecord)

		append(&parentMap[record.parentId], record)
	}

	for id, parentRecords in parentMap {
		slice.sort_by(parentRecords[:], data.sortParentRecordsByChildIndex)
	}

	return
}

ParentColumn :: enum i32 {
	formatId,
	parentId,
	childId,
	childIndex,
}
