package metadata

import arn "../arena"

// A compiled format. name and every node reachable from root are allocated
// in arena and freed by destroy_file_format.
File_Format :: struct {
	name:  string,
	root:  ^Node,
	arena: arn.Arena,
}

// Frees everything the format owns and resets it to the zero value. Safe on a
// zero, partially loaded or already destroyed File_Format.
destroy_file_format :: proc(ff: ^File_Format) {
	arn.arena_destroy(&ff.arena)
	ff^ = {}
}
