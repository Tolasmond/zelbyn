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
//
// An instance is one block of its tree's arena (make_instance): the
// Instance, its slots, then a cell for each slot. The slot of a field read
// at most once is a view of its cell; any other slot is its own array.
Instance :: struct {
	slots:  [][]Value,
	choice: int,
}

// Instance.choice for the _ case of a switch-on field.
DEFAULT_CASE :: -1

// Allocates an instance with n slots, all empty, in one block of a, and
// returns it with its n cells.
make_instance :: proc(a: ^Tree_Arena, n: int, choice: int) -> (instance: ^Instance, cells: []Value) {
	// Instance, slots and Value all have the alignment of a pointer
	#assert(align_of(Instance) == align_of(rawptr) && align_of([]Value) == align_of(rawptr) && align_of(Value) == align_of(rawptr))
	SLOT_WORDS :: size_of([]Value) / size_of(rawptr)
	CELL_WORDS :: size_of(Value) / size_of(rawptr)
	HEADER_WORDS :: size_of(Instance) / size_of(rawptr)
	words := raw_data(tree_arena_make(a, rawptr, HEADER_WORDS + n * (SLOT_WORDS + CELL_WORDS)))
	instance = (^Instance)(words)
	slots := ([^][]Value)(&words[HEADER_WORDS])
	instance.slots = slots[:n]
	instance.choice = choice
	cells = ([^]Value)(&slots[n])[:n]
	return
}
// A decoded value tree. Every instance and array reachable from root is
// allocated in arena, so the tree is freed with one destroy_value_tree, and
// it never references the schema. Strings and blobs are views of the input:
// reader.read puts the input in arena too, so that tree owns it, while
// reader.read_from_bytes borrows the caller's bytes. Do not copy a
// Value_Tree after decoding into it: its containers refer to &arena.
Value_Tree :: struct {
	root:  []Value,
	arena: Tree_Arena,
}

// Frees the whole tree and resets it to the zero value, ready for reuse. Safe
// on a zero or already destroyed tree.
destroy_value_tree :: proc(tree: ^Value_Tree) {
	tree_arena_destroy(&tree.arena)
	tree^ = {}
}
