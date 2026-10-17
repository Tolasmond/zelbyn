package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import dat "../data"
import sql "../../sqlite3"

read_data_type :: proc(db: ^sql.sqlite3, data_type_map: ^map[int]^dat.Data_Type_Record, allocator: mem.Allocator) -> (result: sql.ResultCode) {
	log.debug("Reading DataType table")
	data_type_map^ = make(map[int]^dat.Data_Type_Record, allocator)

	stmt: ^sql.Stmt
	rc := prepare(db, "SELECT * FROM DataType", &stmt)
	if rc != .OK do return rc
	defer sql.finalize(stmt)

	for {
		has_row: bool
		has_row, result = step(stmt)

		if !has_row do break

		record := new(dat.Data_Type_Record, allocator)

		record.id = sql.column_int64(stmt, i32(Data_Type_Column.id))
		record.type = sql.column_int64(stmt, i32(Data_Type_Column.type))

		if (sql.column_type(stmt, i32(Data_Type_Column.min_value)) != sql.SqliteColumnType.NULL) {
			min_value : cstring = sql.column_text(stmt, i32(Data_Type_Column.min_value))
			record.min_value = strings.clone(string(min_value), allocator)
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.max_value)) != sql.SqliteColumnType.NULL) {
			max_value : cstring = sql.column_text(stmt, i32(Data_Type_Column.max_value))
			record.max_value = strings.clone(string(max_value), allocator)
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.default_value)) != sql.SqliteColumnType.NULL) {
			default_value : cstring = sql.column_text(stmt, i32(Data_Type_Column.default_value))
			record.default_value = strings.clone(string(default_value), allocator)
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.units)) != sql.SqliteColumnType.NULL) {
			units : cstring = sql.column_text(stmt, i32(Data_Type_Column.units))
			record.units = strings.clone(string(units), allocator)
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.min_array_length)) != sql.SqliteColumnType.NULL) {
			record.min_array_length = sql.column_int64(stmt, i32(Data_Type_Column.min_array_length))
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.max_array_length)) != sql.SqliteColumnType.NULL) {
			record.max_array_length = sql.column_int64(stmt, i32(Data_Type_Column.max_array_length))
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.is_grow_as_needed)) != sql.SqliteColumnType.NULL) {
			record.is_grow_as_needed = sql.column_int64(stmt, i32(Data_Type_Column.is_grow_as_needed))
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.pattern)) != sql.SqliteColumnType.NULL) {
			pattern : cstring = sql.column_text(stmt, i32(Data_Type_Column.pattern))
			record.pattern = strings.clone(string(pattern), allocator)
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.comparison_tolerance)) != sql.SqliteColumnType.NULL) {
			record.comparison_tolerance = sql.column_double(stmt, i32(Data_Type_Column.comparison_tolerance))
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.min_buffer_length)) != sql.SqliteColumnType.NULL) {
			record.min_buffer_length = sql.column_int64(stmt, i32(Data_Type_Column.min_buffer_length))
		}

		if (sql.column_type(stmt, i32(Data_Type_Column.max_buffer_length)) != sql.SqliteColumnType.NULL) {
			record.max_buffer_length = sql.column_int64(stmt, i32(Data_Type_Column.max_buffer_length))
		}

		data_type_map[record.id] = record
	}

	return
}

Data_Type_Column :: enum i32 {
	id,
	type,
	min_value,
	max_value,
	default_value,
	units,
	min_array_length,
	max_array_length,
	is_grow_as_needed,
	pattern,
	comparison_tolerance,
	min_buffer_length,
	max_buffer_length,
}
