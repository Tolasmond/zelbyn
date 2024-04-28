package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import dat "../data"
import sql "../../sqlite3"

read_length :: proc(db: ^sql.sqlite3, set_length_map: ^map[int]^dat.Length_Record) -> (result: sql.ResultCode) {
	log.debug("Reading Length table")

  stmt: ^sql.Stmt
  query_text := "SELECT * FROM Length"
	query_data := mem.raw_data(query_text)
  sql.prepare_v2(db, query_data, i32(len(query_text)), &stmt, nil)

	for {
		result = sql.step(stmt)

		if result != .ROW do break

		record := new(dat.Length_Record)

  	record.id = sql.column_int64(stmt, i32(Length_Column.id))
  	record.data_type_id = sql.column_int64(stmt, i32(Length_Column.data_type_id))

  	if (sql.column_type(stmt, i32(Length_Column.flag_absoute_offset_from_beginning)) != sql.SqliteColumnType.NULL) {
    	record.flag_absoute_offset_from_beginning = sql.column_int64(stmt, i32(Length_Column.flag_absoute_offset_from_beginning))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.flag_relative_offset_from_field)) != sql.SqliteColumnType.NULL) {
    	record.flag_relative_offset_from_field = sql.column_int64(stmt, i32(Length_Column.flag_relative_offset_from_field))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.value_absolute_offset_from_beginning)) != sql.SqliteColumnType.NULL) {
    	record.value_absolute_offset_from_beginning = sql.column_int64(stmt, i32(Length_Column.value_absolute_offset_from_beginning))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.value_relative_offset_from_field)) != sql.SqliteColumnType.NULL) {
    	record.value_relative_offset_from_field = sql.column_int64(stmt, i32(Length_Column.value_relative_offset_from_field))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.continuator)) != sql.SqliteColumnType.NULL) {
    	record.continuator = sql.column_int64(stmt, i32(Length_Column.continuator))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.terminator)) != sql.SqliteColumnType.NULL) {
    	record.terminator = sql.column_int64(stmt, i32(Length_Column.terminator))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.flag_mask)) != sql.SqliteColumnType.NULL) {
    	record.flag_mask = sql.column_int64(stmt, i32(Length_Column.flag_mask))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.value_mask)) != sql.SqliteColumnType.NULL) {
    	record.value_mask = sql.column_int64(stmt, i32(Length_Column.value_mask))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.value_shift)) != sql.SqliteColumnType.NULL) {
    	record.value_shift = sql.column_int64(stmt, i32(Length_Column.value_shift))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.flag_expression)) != sql.SqliteColumnType.NULL) {
  		flag_expression : cstring = sql.column_text(stmt, i32(Length_Column.flag_expression))
  		record.flag_expression = strings.clone(string(flag_expression))
  	}

  	if (sql.column_type(stmt, i32(Length_Column.value_expression)) != sql.SqliteColumnType.NULL) {
  		value_expression : cstring = sql.column_text(stmt, i32(Length_Column.value_expression))
  		record.value_expression = strings.clone(string(value_expression))
  	}

  	set_length_map[record.id] = record
	}

	return
}

Length_Column :: enum i32 {
	id,
	data_type_id,
	flag_absoute_offset_from_beginning,
	flag_relative_offset_from_field,
	value_absolute_offset_from_beginning,
	value_relative_offset_from_field,
	continuator,
	terminator,
	flag_mask,
	flag_shift,
	value_mask,
	value_shift,
	flag_expression,
	value_expression,
}
