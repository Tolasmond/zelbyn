package field

import arn "../arena"

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
	bool,
	^Instance,
}

// A decoded set instance. slots holds the values of each field of the set
// it was read as, by position: each of its parse instances, then each
// child in order, each followed by its bit fields (metadata.slot_of gives
// a child's slot), then each of its params. For an instance of a switch-on
// field, choice is the case it was read as: an index into the field's
// cases, or DEFAULT_CASE; otherwise it is 0. A value of a switch-on field
// with a length that no case chose is not an instance but a []byte, its
// bytes (metadata.Switch).
//
// An instance is one block of its tree's arena (make_instance): the
// Instance, its slots, then a cell for each slot, and in a tree read with
// spans, a span for each cell. The slot of a field read at most once is a
// view of its cell; any other slot is its own array. The slot of a parse
// instance is nil until it is read, and then never nil, even when it has
// no values.
Instance :: struct {
	slots:  [][]Value,
	choice: int,
}

// Instance.choice for the _ case of a switch-on field.
DEFAULT_CASE :: -1

// Allocates an instance with n slots, all empty, in one block of a, and
// returns it with its n cells, and with SPANS their spans. Inlined: the
// decoder calls it from two places (with and without spans), and a call
// for every instance costs 3% more decode instructions.
make_instance :: #force_inline proc(a: ^arn.Arena, n: int, choice: int, $SPANS: bool) -> (instance: ^Instance, cells: []Value) {
	// Instance, slots, Value and Span all have the alignment of a pointer
	#assert(align_of(Instance) == align_of(rawptr) && align_of([]Value) == align_of(rawptr) && align_of(Value) == align_of(rawptr))
	#assert(align_of(Span) == align_of(rawptr) && size_of(Span) % size_of(rawptr) == 0)
	SLOT_WORDS :: size_of([]Value) / size_of(rawptr)
	CELL_WORDS :: size_of(Value) / size_of(rawptr)
	HEADER_WORDS :: size_of(Instance) / size_of(rawptr)
	cell_words := CELL_WORDS
	when SPANS do cell_words += size_of(Span) / size_of(rawptr)
	words := raw_data(arn.arena_make(a, rawptr, HEADER_WORDS + n * (SLOT_WORDS + cell_words)))
	instance = (^Instance)(words)
	slots := ([^][]Value)(&words[HEADER_WORDS])
	instance.slots = slots[:n]
	instance.choice = choice
	cells = ([^]Value)(&slots[n])[:n]
	return
}

// The bytes a value was read from, as Kaitai's debug mode records them:
// from the stream's position before the value was read to its position
// after, as an offset in the input and a size. A set instance's span holds
// its substream, if it has one. Positions are of whole bytes, so a bit
// type that takes only bits left over has size 0.
Span :: struct {
	offset: int,
	size:   int,
}

// The span of value i of slot k of instance, in a tree read with spans.
// The span of a value in a cell is in the instance, after its cells; the
// spans of an array are kept just before it, in reverse: that of element i
// at index -1 - i. Params, which are not read, have none.
value_span :: proc(instance: ^Instance, k, i: int) -> Span {
	values := instance.slots[k]
	assert(i >= 0 && i < len(values), "value_span: no such value")
	if raw_data(values) == &instance_cells(instance)[k] do return cell_spans(instance)[k]
	return array_span(values, i)^
}

// The span of value i of the root of tree, which was read with spans.
root_span :: proc(tree: ^Value_Tree, i: int) -> Span {
	assert(tree.spans && i >= 0 && i < len(tree.root), "root_span: no such value")
	return array_span(tree.root, i)^
}

// The span of values[i], an array with its spans before it.
array_span :: #force_inline proc(values: []Value, i: int) -> ^Span {
	return &([^]Span)(raw_data(values))[-1 - i]
}

// The spans of the cells of instance, in a tree read with spans.
cell_spans :: proc(instance: ^Instance) -> []Span {
	cells := instance_cells(instance)
	return ([^]Span)(([^]Value)(raw_data(cells))[len(cells):])[:len(cells)]
}

// The cells of instance, which make_instance allocated after its slots.
instance_cells :: proc(instance: ^Instance) -> []Value {
	n := len(instance.slots)
	return ([^]Value)(&raw_data(instance.slots)[n])[:n]
}
// A decoded value tree. Every instance and array reachable from root is
// allocated in arena, so the tree is freed with one destroy_value_tree, and
// it never references the schema. Strings and blobs are views of the input:
// reader.read puts the input in arena too, so that tree owns it, while
// reader.read_from_bytes borrows the caller's bytes. arena holds the list
// of the tree's blocks, so a copy of a Value_Tree shares them: destroy only
// one of the copies. spans is set when the tree was read with spans, so
// that value_span gives the span of each value in it.
Value_Tree :: struct {
	root:  []Value,
	arena: arn.Arena,
	spans: bool,
}

// Frees the whole tree and resets it to the zero value, ready for reuse. Safe
// on a zero or already destroyed tree.
destroy_value_tree :: proc(tree: ^Value_Tree) {
	arn.arena_destroy(&tree.arena)
	tree^ = {}
}
