package sqlite

import "core:mem"
import dat "../data"
import sql "../../sqlite3"

read_packed :: proc(db: ^sql.sqlite3, packed_records: ^[dynamic]^dat.Packed_Record, allocator: mem.Allocator) -> (result: sql.ResultCode) {
	packed_records^ = make([dynamic]^dat.Packed_Record, allocator)

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM Packed ORDER BY Id, LowBit", &stmt)
	if rc != .OK do return rc
	defer sql.finalize(stmt)

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record := new(dat.Packed_Record, allocator)

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
