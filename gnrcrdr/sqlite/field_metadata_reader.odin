package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import dat "../data"
import mdat "../metadata"
import sql "../../sqlite3"

read_field :: proc(db: ^sql.sqlite3, packed_records: []^dat.Packed_Record, data_type_map: ^map[int]^dat.Data_Type_Record, field_metadata_map: ^map[int]^mdat.Field_Metadata) -> (result: sql.ResultCode) {
	log.debug("Reading Field table")

  stmt: ^sql.Stmt
  query_text := "SELECT * FROM Field"
	query_data := mem.raw_data(query_text)
  sql.prepare_v2(db, query_data, i32(len(query_text)), &stmt, nil)

	for {
		result = sql.step(stmt)

		if result != .ROW do break

		record: dat.Field_Record

  	record.id = sql.column_int64(stmt, i32(Field_Column.id))

		name : cstring = sql.column_text(stmt, i32(Field_Column.name))
 		record.name = strings.clone(string(name))

  	record.data_type_id = sql.column_int64(stmt, i32(Field_Column.data_type_id))

  	field_metadata := new(mdat.Field_Metadata)
  	field_metadata.id = record.id
  	field_metadata.name = record.name
  	field_metadata.data_type = data_type_map[record.data_type_id]

    start_index := -1
    end_index := -1

    for packedRecord, index in packed_records {
			if packedRecord.id == record.id {
			  if start_index < 0 {
				  start_index = index
			  } else {
			  	end_index = index
			  }
			}
		}

    if start_index >= 0 do field_metadata.packed_fields = packed_records[start_index:end_index]

  	field_metadata_map[record.id] = field_metadata
	}

	return
}

Field_Column :: enum i32 {
	id,
	name,
	data_type_id,
}
