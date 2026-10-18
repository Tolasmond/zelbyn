package sqlite

import "core:mem"
import "core:strings"
import sql "../../sqlite3"

read_field :: proc(db: ^sql.sqlite3, field_map: ^map[int]^Field_Record, allocator: mem.Allocator) -> (result: sql.ResultCode) {
	field_map^ = make(map[int]^Field_Record, allocator)

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM Field", &stmt)
	if rc != .OK do return rc
	defer sql.finalize(stmt)

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record := new(Field_Record, allocator)

		record.id = sql.column_int64(stmt, i32(Field_Column.id))

		name : cstring = sql.column_text(stmt, i32(Field_Column.name))
		record.name = strings.clone(string(name), allocator)

		record.data_type_id = sql.column_int64(stmt, i32(Field_Column.data_type_id))

		field_map[record.id] = record
	}

	return
}

Field_Column :: enum i32 {
	id,
	name,
	data_type_id,
}
