package metadata

File_Format :: struct {
	root_metadata_node: Field_Metadata_Tree_Node,
	metadata: Field_Metadata_Provider
}

destroy_file_format :: proc(ff: ^File_Format) {
	destroy_metadata_node(&ff.root_metadata_node)
	destroy_metadata_provider(&ff.metadata)
}
