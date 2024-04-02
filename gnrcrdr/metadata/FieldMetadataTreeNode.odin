package metadata

FieldMetadataTreeNode :: struct {
	fieldMetadata: ^FieldMetadata,
	children: [dynamic]^FieldMetadataTreeNode,
	parent: ^FieldMetadataTreeNode
}
