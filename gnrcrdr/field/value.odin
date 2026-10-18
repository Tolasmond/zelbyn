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
	map[int][dynamic]Value,
}

// A decoded value tree. Every map, array, string and blob reachable from root
// is allocated in arena, so the tree is freed with one destroy_value_tree and
// never references the input bytes or the schema. Do not copy a Value_Tree
// after decoding into it: its containers refer to &arena.
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
