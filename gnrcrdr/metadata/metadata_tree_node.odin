package metadata

Field_Metadata_Tree_Node :: struct {
	metadata: ^Field_Metadata,
	children: [dynamic]^Field_Metadata_Tree_Node,
	parent: ^Field_Metadata_Tree_Node
}

destroy_metadata_node :: proc(metadata_node: ^Field_Metadata_Tree_Node) {
	free(metadata_node.metadata)
	for child_node in metadata_node.children {
		destroy_metadata_node(child_node)
		free(child_node)
	}
	delete(metadata_node.children)
}
