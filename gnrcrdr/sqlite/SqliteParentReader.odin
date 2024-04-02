package sqlite

import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "../metadata"
import sql "../../sqlite3"

readParent :: proc(db: ^sql.sqlite3, parentMap: ^map[i32][dynamic]^metadata.ParentRecord) -> (result: Result_Code) {
	log.debug("Reading Parent table")

  stmt: ^Stmt
  queryText := "SELECT * FROM Parent"
	data := mem.raw_data(queryText);
  sql.prepare_v2(db, data, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(metadata.ParentRecord)

  	record.formatId = sql.column_int(stmt, i32(ParentColumn.formatId))
  	record.parentId = sql.column_int(stmt, i32(ParentColumn.parentId))
  	record.childId = sql.column_int(stmt, i32(ParentColumn.childId))
  	record.childIndex = sql.column_int(stmt, i32(ParentColumn.childIndex))

    keyExists := record.parentId in parentMap

  	if !keyExists do parentMap[record.parentId] = make([dynamic]^metadata.ParentRecord)

    append(&parentMap[record.parentId], record)
	}

	for id, parentRecords in parentMap {
    slice.sort_by(parentRecords[:], metadata.sortParentRecordsByChildIndex)
	}

	return
}

ParentColumn :: enum i32 {
	formatId,
	parentId,
	childId,
	childIndex
}
