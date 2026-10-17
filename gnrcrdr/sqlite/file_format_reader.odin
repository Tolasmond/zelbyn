package sqlite

import sql "../../sqlite3"
import dat "../data"
import mdata "../metadata"
import "core:fmt"
import "core:log"
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
// read-only. After an error, mdata.destroy_file_format frees whatever was
// loaded so far.
read_file_format :: proc(db_path: string, format_id: int, file_format: ^mdata.File_Format) -> (err: Load_Error) {
	log.debugf("Opening database and reading format ID %v", format_id)
	db: ^sql.sqlite3
	cpath := strings.clone_to_cstring(db_path)
	defer delete(cpath)

	rc := sql.open_v2(cpath, &db, sql.OPEN_READONLY, nil)
	if rc != .OK {
		err = Load_Error{kind = .Open_Failed, code = rc, message = strings.clone(string(sql.errmsg(db)))}
		sql.close(db)
		return
	}

	err = load(db, format_id, file_format)

	log.debug("closing database connection")
	rc = sql.close(db)
	if rc != .OK && err.kind == .None {
		err = Load_Error{kind = .Close_Failed, code = rc, message = strings.clone(string(sql.errmsg(db)))}
	}

	return
}

@(private = "file")
load :: proc(db: ^sql.sqlite3, format_id: int, file_format: ^mdata.File_Format) -> Load_Error {
	metadata := &file_format.metadata

	if rc := read_data_type(db, &metadata.data_type_map); rc != .OK {
		return query_error(db, rc, "DataType")
	}

	if rc := read_length(db, &metadata.set_length_map); rc != .OK {
		return query_error(db, rc, "Length")
	}

	if rc := read_marker_offset(db, &metadata.marker_offset_map); rc != .OK {
		return query_error(db, rc, "MarkerOffset")
	}

	if rc := read_set_helper(db, format_id, &metadata.set_helper_map); rc != .OK {
		return query_error(db, rc, "SetHelper")
	}

	if rc := read_packed(db, &metadata.packed_records); rc != .OK {
		return query_error(db, rc, "Packed")
	}

	if rc := read_field(db, metadata.packed_records[:], &metadata.data_type_map, &metadata.field_metadata_map); rc != .OK {
		return query_error(db, rc, "Field")
	}

	found, rc := read_format(db, format_id, &metadata.format_record)
	if rc != .OK {
		return query_error(db, rc, "Format")
	}
	if !found {
		return Load_Error{kind = .Format_Not_Found, table = "Format", message = strings.clone("format id not found")}
	}

	if rc := read_parent(db, format_id, &metadata.parent_map); rc != .OK {
		return query_error(db, rc, "Parent")
	}

	root := metadata.field_metadata_map[metadata.format_record.root_field]
	if root == nil || root.data_type == nil {
		return Load_Error {
			kind = .Invalid_Schema,
			table = "Format",
			message = fmt.aprintf("root field %v has no field metadata or data type", metadata.format_record.root_field),
		}
	}

	file_format.root_metadata_node.metadata = root

	log.debug("reading children")

	return read_children(&file_format.root_metadata_node, metadata)
}

@(private = "file")
query_error :: proc(db: ^sql.sqlite3, rc: sql.ResultCode, table: string) -> Load_Error {
	return Load_Error{kind = .Query_Failed, code = rc, table = table, message = strings.clone(string(sql.errmsg(db)))}
}

@(private = "file")
read_children :: proc(
	parent_node: ^mdata.Field_Metadata_Tree_Node, metadata: ^mdata.Field_Metadata_Provider) -> Load_Error {

	parent_map := &metadata.parent_map
	field_metadata_map := &metadata.field_metadata_map

	for childRecord in parent_map[parent_node.metadata.id] {

		child_tree_node := new(mdata.Field_Metadata_Tree_Node)

		child_tree_node.metadata = field_metadata_map[childRecord.child_id]

		child_tree_node.parent = parent_node

		// appended before validation so destroy_file_format frees it on error
		append(&parent_node.children, child_tree_node)

		if child_tree_node.metadata == nil || child_tree_node.metadata.data_type == nil {
			return Load_Error {
				kind = .Invalid_Schema,
				table = "Parent",
				message = fmt.aprintf("child field %v has no field metadata or data type", childRecord.child_id),
			}
		}

		if (dat.Data_Type(child_tree_node.metadata.data_type.type) == .Set) {
			if err := read_children(child_tree_node, metadata); err.kind != .None do return err
		}
	}

	return {}
}
