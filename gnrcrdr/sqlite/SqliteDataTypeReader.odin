package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../data"
import "../metadata"
import sql "../../sqlite3"

readDataType :: proc(db: ^sql.sqlite3, dataTypeMap: ^map[int]^data.DataTypeRecord) -> (result: Result_Code) {
	log.debug("Reading DataType table")

  stmt: ^Stmt
  queryText := "SELECT * FROM DataType"
	queryData := mem.raw_data(queryText);
  sql.prepare_v2(db, queryData, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(data.DataTypeRecord)

  	record.id = sql.column_int64(stmt, i32(DataTypeColumn.id))
  	record.type = sql.column_int64(stmt, i32(DataTypeColumn.type))

  	if (sql.column_type(stmt, i32(DataTypeColumn.minValue)) != sql.SqliteColumnType.NULL) {
  		minValue : cstring = sql.column_text(stmt, i32(DataTypeColumn.minValue))
  		record.minValue = strings.clone(string(minValue))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.maxValue)) != sql.SqliteColumnType.NULL) {
  		maxValue : cstring = sql.column_text(stmt, i32(DataTypeColumn.maxValue))
  		record.maxValue = strings.clone(string(maxValue))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.defaultValue)) != sql.SqliteColumnType.NULL) {
  		defaultValue : cstring = sql.column_text(stmt, i32(DataTypeColumn.defaultValue))
  		record.defaultValue = strings.clone(string(defaultValue))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.units)) != sql.SqliteColumnType.NULL) {
  		units : cstring = sql.column_text(stmt, i32(DataTypeColumn.units))
  		record.units = strings.clone(string(units))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.minArrayLength)) != sql.SqliteColumnType.NULL) {
    	record.minArrayLength = sql.column_int64(stmt, i32(DataTypeColumn.minArrayLength))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.maxArrayLength)) != sql.SqliteColumnType.NULL) {
    	record.maxArrayLength = sql.column_int64(stmt, i32(DataTypeColumn.maxArrayLength))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.isGrowAsNeeded)) != sql.SqliteColumnType.NULL) {
    	record.isGrowAsNeeded = sql.column_int64(stmt, i32(DataTypeColumn.isGrowAsNeeded))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.pattern)) != sql.SqliteColumnType.NULL) {
  		pattern : cstring = sql.column_text(stmt, i32(DataTypeColumn.pattern))
  		record.pattern = strings.clone(string(pattern))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.comparisonTolerance)) != sql.SqliteColumnType.NULL) {
    	record.comparisonTolerance = sql.column_double(stmt, i32(DataTypeColumn.comparisonTolerance))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.minBufferLength)) != sql.SqliteColumnType.NULL) {
    	record.minBufferLength = sql.column_int64(stmt, i32(DataTypeColumn.minBufferLength))
  	}

  	if (sql.column_type(stmt, i32(DataTypeColumn.maxBufferLength)) != sql.SqliteColumnType.NULL) {
    	record.maxBufferLength = sql.column_int64(stmt, i32(DataTypeColumn.maxBufferLength))
  	}

  	dataTypeMap[record.id] = record
	}

	return
}

DataTypeColumn :: enum i32 {
	id,
	type,
	minValue,
	maxValue,
	defaultValue,
	units,
	minArrayLength,
	maxArrayLength,
	isGrowAsNeeded,
	pattern,
	comparisonTolerance,
	minBufferLength,
	maxBufferLength
}
