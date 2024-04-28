package sqlite

import "core:log"
import "core:mem"
import dat "../data"
import sql "../../sqlite3"

read_packed :: proc(db: ^sql.sqlite3, packed_records: ^[dynamic]^dat.Packed_Record) -> (result: sql.ResultCode) {
	log.debug("Reading Packed table")

  stmt: ^sql.Stmt
  query_text := "SELECT * FROM Packed"
	query_data := mem.raw_data(query_text)
  sql.prepare_v2(db, query_data, i32(len(query_text)), &stmt, nil)

	for {
		result = sql.step(stmt)

		if result != .ROW do break

		record := new(dat.Packed_Record)

  	record.id = sql.column_int64(stmt, i32(PackedColumn.id))
  	record.field_id = sql.column_int64(stmt, i32(PackedColumn.field_id))
  	record.low_bit = sql.column_int64(stmt, i32(PackedColumn.low_bit))
  	record.high_bit = sql.column_int64(stmt, i32(PackedColumn.high_bit))

    append(packed_records, record)
	}

	return
}

PackedColumn :: enum i32 {
	id,
	field_id,
	low_bit,
	high_bit,
}
