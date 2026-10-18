package field

Value :: union {
	i8,
	i16,
	i32,
	i64,
	u8,
	u16,
	u32,
	u64,
	f32,
	f64,
	string,
	[]byte,
	^Instance,
}

// A decoded set instance. slots holds the values of each field of the set
// it was read as, by position: each child of the set in order, each
// followed by its bit fields (metadata.slot_of gives a child's slot). For
// an instance of a switch-on field, choice is the case it was read as: an
// index into the field's cases, or DEFAULT_CASE; otherwise it is 0.
Instance :: struct {
	slots:  [][dynamic]Value,
	choice: int,
}

// Instance.choice for the _ case of a switch-on field.
DEFAULT_CASE :: -1

// A decoded value tree. Every instance and array reachable from root is
// allocated in arena, so the tree is freed with one destroy_value_tree, and
// it never references the schema. Strings and blobs are views of the input:
// reader.read puts the input in arena too, so that tree owns it, while
// reader.read_from_bytes borrows the caller's bytes. Do not copy a
// Value_Tree after decoding into it: its containers refer to &arena.
Value_Tree :: struct {
	root:  [dynamic]Value,
	arena: Tree_Arena,
}

// Frees the whole tree and resets it to the zero value, ready for reuse. Safe
// on a zero or already destroyed tree.
destroy_value_tree :: proc(tree: ^Value_Tree) {
	tree_arena_destroy(&tree.arena)
	tree^ = {}
}
