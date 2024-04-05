package sqlite

import sql "../../sqlite3"
import "../data"
import "../manip"
import "../metadata"
import "core:log"
import "core:mem"
import "core:strings"

read_file_format :: proc(dbFilePath: string, format_id: int, file_format: ^metadata.File_Format) {
	log.debugf("Opening database and reading format ID %v", format_id)
	db: ^sql.sqlite3
  sql.open(strings.clone_to_cstring(dbFilePath), &db)
	defer sql.close(db)

	result := read_data_type(db, &file_format.metadata_provider.data_type_map)

	result = read_length(db, &file_format.metadata_provider.set_length_map)

	result = read_marker_offset(db, &file_format.metadata_provider.marker_offset_map)

	result = read_set_helper(db, &file_format.metadata_provider.set_helper_map)

	packed_records := make([dynamic]^data.Packed_Record)

	result = read_packed(db, &packed_records)

	file_format.metadata_provider.packed_records = packed_records

	result = read_field(
		db,
		packed_records[:],
		&file_format.metadata_provider.data_type_map,
		&file_format.metadata_provider.field_metadata_map,
	)

	result = read_format(db, &file_format.metadata_provider.format_record)

	result = read_parent(db, &file_format.metadata_provider.parent_map)

	file_format.root_metadata_tree_node.field_metadata =
		file_format.metadata_provider.field_metadata_map[file_format.metadata_provider.format_record.root_field]

	log.debug("reading children")

	read_children(&file_format.root_metadata_tree_node, &file_format.metadata_provider)

  log.debug("closing database connection")
}

@(private = "file")
read_children :: proc(
	parent_tree_node: ^metadata.Field_Metadata_Tree_Node, field_metadata_provider: ^metadata.Field_Metadata_Provider) {

	parent_map := &field_metadata_provider.parent_map
	field_metadata_map := &field_metadata_provider.field_metadata_map

	key_exists := parent_tree_node.field_metadata.id in parent_map

	for childRecord in parent_map[parent_tree_node.field_metadata.id] {

		child_tree_node := new(metadata.Field_Metadata_Tree_Node)

		child_tree_node.field_metadata = field_metadata_map[childRecord.child_id]

		child_tree_node.parent = parent_tree_node

		append(&parent_tree_node.children, child_tree_node)

		if (data.Data_Type(child_tree_node.field_metadata.data_type.type) == .Set) {
      read_children(child_tree_node, field_metadata_provider)
		}
	}
}
