package sqlite

import "core:log"
import dat "../data"
import sql "../../sqlite3"

read_marker_offset :: proc(db: ^sql.sqlite3, marker_offset_map: ^map[int][dynamic]^dat.Marker_Offset_Record) -> (result: sql.ResultCode) {
	log.debug("Reading MarkerOffset table")

  stmt: ^sql.Stmt
  rc := prepare(db, "SELECT * FROM MarkerOffset", &stmt)
  if rc != .OK do return rc
  defer sql.finalize(stmt)

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record := new(dat.Marker_Offset_Record)

  	record.marker_id = sql.column_int64(stmt, i32(Marker_Offset_Column.marker_id))
  	record.byte_offset = sql.column_int64(stmt, i32(Marker_Offset_Column.byte_offset))
  	record.data_type_id = sql.column_int64(stmt, i32(Marker_Offset_Column.data_type_id))
  	record.marker = sql.column_int64(stmt, i32(Marker_Offset_Column.marker))

		key_exists := record.marker_id in marker_offset_map

		if !key_exists do marker_offset_map[record.marker_id] = make([dynamic]^dat.Marker_Offset_Record)

		append(&marker_offset_map[record.marker_id], record)
	}

	return
}

Marker_Offset_Column :: enum i32 {
	marker_id,
	byte_offset,
	data_type_id,
	marker,
}
