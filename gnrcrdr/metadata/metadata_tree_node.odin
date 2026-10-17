package metadata

Field_Metadata_Tree_Node :: struct {
	metadata: ^Field_Metadata,
	children: [dynamic]^Field_Metadata_Tree_Node,
	parent: ^Field_Metadata_Tree_Node,
}

create_path_name_map :: proc(node: ^Field_Metadata_Tree_Node) -> map[int]string {
	name_map := make(map[int]string)

	name_map[node.metadata.id] = node.metadata.name

	node := node

	for node.parent != nil {
		node = node.parent
		name_map[node.metadata.id] = node.metadata.name
	}

	return name_map
}
