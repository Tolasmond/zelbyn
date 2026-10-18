package sqlite

import sql "../../sqlite3"
import mdata "../metadata"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

Load_Error_Kind :: enum {
	None,
	Open_Failed,
	Query_Failed,
	Format_Not_Found,
	Invalid_Schema,
	Close_Failed,
}

Load_Error :: struct {
	kind:    Load_Error_Kind,
	code:    sql.ResultCode, // SQLite result code where applicable, else .OK
	table:   string,         // string literal naming the table/query, NOT owned
	message: string,         // owned; free with destroy_load_error
}

destroy_load_error :: proc(err: ^Load_Error) {
	delete(err.message)
	err.message = ""
}

// Loads format format_id from the database at db_path, which is opened
// read-only, and compiles it into file_format. The records are read into a
// scratch arena that is freed before returning. After an error,
// mdata.destroy_file_format frees whatever was compiled so far.
read_file_format :: proc(db_path: string, format_id: int, file_format: ^mdata.File_Format) -> (err: Load_Error) {
	scratch: virtual.Arena
	defer virtual.arena_destroy(&scratch)

	records: Records
	err = read_records(db_path, format_id, &records, virtual.arena_allocator(&scratch))
	if err.kind != .None do return

	return compile(&records, file_format)
}

// Reads the rows of format format_id from the database at db_path, which is
// opened read-only, into records. Everything is allocated with allocator,
// except an error's message.
read_records :: proc(db_path: string, format_id: int, records: ^Records, allocator: mem.Allocator) -> (err: Load_Error) {
	db: ^sql.sqlite3
	cpath := strings.clone_to_cstring(db_path, allocator)

	rc := sql.open_v2(cpath, &db, sql.OPEN_READONLY, nil)
	if rc != .OK {
		err = Load_Error{kind = .Open_Failed, code = rc, message = strings.clone(string(sql.errmsg(db)))}
		sql.close(db)
		return
	}

	err = load(db, format_id, records, allocator)

	rc = sql.close(db)
	if rc != .OK && err.kind == .None {
		err = Load_Error{kind = .Close_Failed, code = rc, message = strings.clone(string(sql.errmsg(db)))}
	}

	return
}

@(private = "file")
load :: proc(db: ^sql.sqlite3, format_id: int, records: ^Records, allocator: mem.Allocator) -> Load_Error {
	if rc := read_data_type(db, &records.data_type_map, allocator); rc != .OK {
		return query_error(db, rc, "DataType")
	}

	if rc := read_length(db, &records.set_length_map, allocator); rc != .OK {
		return query_error(db, rc, "Length")
	}

	if rc := read_marker_offset(db, &records.marker_offset_map, allocator); rc != .OK {
		return query_error(db, rc, "MarkerOffset")
	}

	if rc := read_set_helper(db, format_id, &records.set_helper_map, allocator); rc != .OK {
		return query_error(db, rc, "SetHelper")
	}

	if rc := read_packed(db, &records.packed_records, allocator); rc != .OK {
		return query_error(db, rc, "Packed")
	}

	if rc := read_field(db, &records.field_map, allocator); rc != .OK {
		return query_error(db, rc, "Field")
	}

	found, format_rc := read_format(db, format_id, &records.format_record, allocator)
	if format_rc != .OK {
		return query_error(db, format_rc, "Format")
	}
	if !found {
		return Load_Error{kind = .Format_Not_Found, table = "Format", message = strings.clone("format id not found")}
	}

	if rc := read_parent(db, format_id, &records.parent_map, allocator); rc != .OK {
		return query_error(db, rc, "Parent")
	}

	return {}
}

@(private = "file")
query_error :: proc(db: ^sql.sqlite3, rc: sql.ResultCode, table: string) -> Load_Error {
	return Load_Error{kind = .Query_Failed, code = rc, table = table, message = strings.clone(string(sql.errmsg(db)))}
}
