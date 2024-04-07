package sqlite

import sql "../../sqlite3"
import dat "../data"
import mdata "../metadata"
import "core:log"
import "core:mem"
import "core:strings"

read_file_format :: proc(dbFilePath: string, format_id: int, file_format: ^mdata.File_Format) {
	log.debugf("Opening database and reading format ID %v", format_id)
	db: ^sql.sqlite3
	cpath := strings.clone_to_cstring(dbFilePath)
  sql.open(cpath, &db)
	defer {
		delete(cpath)
		sql.close(db)
	}

	result := read_data_type(db, &file_format.metadata.data_type_map)

	result = read_length(db, &file_format.metadata.set_length_map)

	result = read_marker_offset(db, &file_format.metadata.marker_offset_map)

	result = read_set_helper(db, &file_format.metadata.set_helper_map)

	packed_records := make([dynamic]^dat.Packed_Record)

	result = read_packed(db, &packed_records)

	file_format.metadata.packed_records = packed_records

	result = read_field(
		db,
		packed_records[:],
		&file_format.metadata.data_type_map,
		&file_format.metadata.field_metadata_map,
	)

	result = read_format(db, &file_format.metadata.format_record)

	result = read_parent(db, &file_format.metadata.parent_map)

	file_format.root_metadata_node.metadata =
		file_format.metadata.field_metadata_map[file_format.metadata.format_record.root_field]

	log.debug("reading children")

	read_children(&file_format.root_metadata_node, &file_format.metadata)

  log.debug("closing database connection")
}

@(private = "file")
read_children :: proc(
	parent_node: ^mdata.Field_Metadata_Tree_Node, metadata: ^mdata.Field_Metadata_Provider) {

	parent_map := &metadata.parent_map
	field_metadata_map := &metadata.field_metadata_map

	key_exists := parent_node.metadata.id in parent_map

	for childRecord in parent_map[parent_node.metadata.id] {

		child_tree_node := new(mdata.Field_Metadata_Tree_Node)

		child_tree_node.metadata = field_metadata_map[childRecord.child_id]

		child_tree_node.parent = parent_node

		append(&parent_node.children, child_tree_node)

		if (dat.Data_Type(child_tree_node.metadata.data_type.type) == .Set) {
      read_children(child_tree_node, metadata)
		}
	}
}
