package metadata

Field_Metadata_Tree_Node :: struct {
	metadata: ^Field_Metadata,
	children: [dynamic]^Field_Metadata_Tree_Node,
	parent: ^Field_Metadata_Tree_Node,
}
