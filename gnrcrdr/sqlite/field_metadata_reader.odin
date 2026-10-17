package sqlite

import "core:log"
import "core:strings"
import dat "../data"
import mdat "../metadata"
import sql "../../sqlite3"

read_field :: proc(db: ^sql.sqlite3, packed_records: []^dat.Packed_Record, data_type_map: ^map[int]^dat.Data_Type_Record, field_metadata_map: ^map[int]^mdat.Field_Metadata) -> (result: sql.ResultCode) {
	log.debug("Reading Field table")

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM Field", &stmt)
	if rc != .OK do return rc
	defer sql.finalize(stmt)

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record: dat.Field_Record

		record.id = sql.column_int64(stmt, i32(Field_Column.id))

		name : cstring = sql.column_text(stmt, i32(Field_Column.name))
		record.name = strings.clone(string(name))

		record.data_type_id = sql.column_int64(stmt, i32(Field_Column.data_type_id))

		field_metadata := new(mdat.Field_Metadata)
		field_metadata.id = record.id
		field_metadata.name = record.name
		field_metadata.data_type = data_type_map[record.data_type_id]

		// packed_records is ordered by Id, so a field's records are contiguous
		start := -1
		for p, i in packed_records {
			if p.id == record.id {
				start = i
				break
			}
		}
		if start >= 0 {
			end := start
			for end < len(packed_records) && packed_records[end].id == record.id {
				end += 1
			}
			field_metadata.packed_fields = packed_records[start:end]
		}

		field_metadata_map[record.id] = field_metadata
	}

	return
}

Field_Column :: enum i32 {
	id,
	name,
	data_type_id,
}
