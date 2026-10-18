package metadata

import "core:mem/virtual"

// A loaded format. Everything reachable from root_metadata_node and metadata
// is allocated in arena and freed by destroy_file_format; there are no
// per-record destroy procedures. Do not copy a File_Format after loading:
// its maps, arrays and tree nodes refer to &arena and to &root_metadata_node.
File_Format :: struct {
	name: string,
	root: ^Node, // the compiled plan
	root_metadata_node: Field_Metadata_Tree_Node,
	metadata: Field_Metadata_Provider,
	arena: virtual.Arena,
}

// Frees everything the format owns and resets it to the zero value. Safe on a
// zero, partially loaded or already destroyed File_Format.
destroy_file_format :: proc(ff: ^File_Format) {
	virtual.arena_destroy(&ff.arena)
	ff^ = {}
}
