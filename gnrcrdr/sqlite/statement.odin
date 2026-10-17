package sqlite

import sql "../../sqlite3"

@(private)
prepare :: proc(db: ^sql.sqlite3, query: string, stmt: ^^sql.Stmt) -> sql.ResultCode {
	return sql.prepare_v2(db, raw_data(query), i32(len(query)), stmt, nil)
}

// Steps stmt and normalises the result for reader loops:
//   .ROW  -> (true, .OK), a row is ready
//   .DONE -> (false, .OK), no more rows
//   other -> (false, that code)
@(private)
step :: proc(stmt: ^sql.Stmt) -> (has_row: bool, rc: sql.ResultCode) {
	rc = sql.step(stmt)
	if rc == .ROW do return true, .OK
	if rc == .DONE do return false, .OK
	return false, rc
}
