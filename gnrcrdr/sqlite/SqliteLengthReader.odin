package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "../data"
import "../metadata"
import sql "../../sqlite3"

readLength :: proc(db: ^sql.sqlite3, setLengthMap: ^map[int]^data.LengthRecord) -> (result: Result_Code) {
	log.debug("Reading Length table")

  stmt: ^Stmt
  queryText := "SELECT * FROM Length"
	queryData := mem.raw_data(queryText);
  sql.prepare_v2(db, queryData, i32(len(queryText)), &stmt, nil);

	for {
		result = sql.step(stmt)

		if result != .ROW do break;

		record := new(data.LengthRecord)

  	record.id = sql.column_int64(stmt, i32(LengthColumn.id))
  	record.dataTypeId = sql.column_int64(stmt, i32(LengthColumn.dataTypeId))

  	if (sql.column_type(stmt, i32(LengthColumn.flagAbsouteOffsetFromBeginning)) != sql.SqliteColumnType.NULL) {
    	record.flagAbsouteOffsetFromBeginning = sql.column_int64(stmt, i32(LengthColumn.flagAbsouteOffsetFromBeginning))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.flagRelativeOffsetFromField)) != sql.SqliteColumnType.NULL) {
    	record.flagRelativeOffsetFromField = sql.column_int64(stmt, i32(LengthColumn.flagRelativeOffsetFromField))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.valueAbsoluteOffsetFromBeginning)) != sql.SqliteColumnType.NULL) {
    	record.valueAbsoluteOffsetFromBeginning = sql.column_int64(stmt, i32(LengthColumn.valueAbsoluteOffsetFromBeginning))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.valueRelativeOffsetFromField)) != sql.SqliteColumnType.NULL) {
    	record.valueRelativeOffsetFromField = sql.column_int64(stmt, i32(LengthColumn.valueRelativeOffsetFromField))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.continuator)) != sql.SqliteColumnType.NULL) {
    	record.continuator = sql.column_int64(stmt, i32(LengthColumn.continuator))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.terminator)) != sql.SqliteColumnType.NULL) {
    	record.terminator = sql.column_int64(stmt, i32(LengthColumn.terminator))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.flagMask)) != sql.SqliteColumnType.NULL) {
    	record.flagMask = sql.column_int64(stmt, i32(LengthColumn.flagMask))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.valueMask)) != sql.SqliteColumnType.NULL) {
    	record.valueMask = sql.column_int64(stmt, i32(LengthColumn.valueMask))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.valueShift)) != sql.SqliteColumnType.NULL) {
    	record.valueShift = sql.column_int64(stmt, i32(LengthColumn.valueShift))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.flagExpression)) != sql.SqliteColumnType.NULL) {
  		flagExpression : cstring = sql.column_text(stmt, i32(LengthColumn.flagExpression))
  		record.flagExpression = strings.clone(string(flagExpression))
  	}

  	if (sql.column_type(stmt, i32(LengthColumn.valueExpression)) != sql.SqliteColumnType.NULL) {
  		valueExpression : cstring = sql.column_text(stmt, i32(LengthColumn.valueExpression))
  		record.valueExpression = strings.clone(string(valueExpression))
  	}

  	setLengthMap[record.id] = record
	}

	return
}

LengthColumn :: enum i32 {
	id,
	dataTypeId,
	flagAbsouteOffsetFromBeginning,
	flagRelativeOffsetFromField,
	valueAbsoluteOffsetFromBeginning,
	valueRelativeOffsetFromField,
	continuator,
	terminator,
	flagMask,
	flagShift,
	valueMask,
	valueShift,
	flagExpression,
	valueExpression
}
