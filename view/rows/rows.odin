// Package rows presents a decoded tree as the rows of an outline, for the
// viewer to draw: each value, set instance and array is a row, under the
// set or array that holds it, and a set or an array can be expanded to show
// its rows. A window of rows is found without stepping through the rows
// before it, so a tree of any size scrolls in the time of the window and of
// the rows expanded around it. It draws nothing and imports no terminal
// library, so it is tested on every platform.
package rows

import fld "../../zelbyn/field"
import mdata "../../zelbyn/metadata"
import "core:mem"
import "core:strings"

Kind :: enum u8 {
	Value, // a scalar, or the bytes of a switch-on that chose no set
	Set,   // a set instance
	Array, // the values of a field read more than once
}

// One row, as rows gives it.
Row :: struct {
	kind:       Kind,
	depth:      int,    // 0 for the root's set
	name:       string, // the field's, as the dump names it (the plan's)
	element:    bool,   // a value of an array, which the dump names name[index]
	index:      int,    // the value's index in its field; 0 for a field read once; -1 for an Array
	text:       string, // a Value's, as the dump writes it (field.write_value); "" for the others
	count:      int,    // an Array's values
	expandable: bool,   // a Set or Array with rows under it
	expanded:   bool,
	span:       fld.Span, // in a tree read with spans; an Array's, from its first value's start to its last's end
	has_span:   bool,
	// under a field with process (zlib): the span is in the bytes it
	// decompressed, not in the file, and source is the span in the file of
	// the outermost such field it is under, whose bytes it was read from
	// (doc/usage.md). A parse instance there with an io of another stream
	// is taken to be in them too.
	decompressed: bool,
	source:       fld.Span,
}

// A row's place in the tree: value index of values, slot k of owner, or of
// the root when owner is nil, the values of the field node (nil for a
// -bits field) called name. index is -1 for the row of an array, and TOP
// for the top, which is no row.
@(private)
Item :: struct {
	name:   string,
	node:   ^mdata.Node,
	owner:  ^fld.Instance,
	k:      int,
	values: []fld.Value,
	index:  int,
	single: bool,
}

@(private)
TOP :: -2

// An expanded row: its position among the rows of the row it is under, and
// the rows visible under it. The expanded rows under one row are a treap
// ordered by position, whose root is that row's children, and each keeps
// the rows visible under all the expanded rows of its subtree (sum), so
// that the rows before a position are counted, and an expanded row is
// found, added or removed, in steps of the logarithm of how many rows are
// expanded beside it, however many rows there are.
@(private)
Open :: struct {
	parent:      ^Open,
	pos:         int,
	below:       int,
	children:    ^Open, // the root of the treap of the expanded rows under it
	left, right: ^Open, // in the treap of the row it is under
	sum:         int,
	priority:    u64,
}

// The rows of a tree read with format. Both must outlive it: the tree holds
// no names, so the plan gives them. Expanding and collapsing allocate in
// allocator. rows gives its rows in the allocator it is given, and finding a
// row for the others takes a little of context.temp_allocator; nothing
// allocates through context.allocator once the model is made.
Model :: struct {
	format:    ^mdata.File_Format,
	tree:      ^fld.Value_Tree,
	top:       Open, // the rows at depth 0, under no row
	allocator: mem.Allocator,
	seed:      u64, // for the treaps' priorities
	// for the tests: the expanded rows and fields stepped over to find
	// rows, and the values formatted
	steps:     int,
	formatted: int,
}

// Makes the rows of tree, read with format, with the root's set expanded.
init :: proc(m: ^Model, format: ^mdata.File_Format, tree: ^fld.Value_Tree, allocator := context.allocator) {
	m^ = {format = format, tree = tree, allocator = allocator, seed = 0x9e3779b97f4a7c15}
	m.top.below = child_count(m, top_item())
	if m.top.below > 0 do expand(m, 0)
}

destroy :: proc(m: ^Model) {
	free_treap(m, m.top.children)
	m^ = {}
}

// The rows there are, with those under the rows expanded.
count :: proc(m: ^Model) -> int {
	return m.top.below
}

// Rows first to first + n - 1, or to the last row, with their text in
// allocator. With preview above 0, a string shows at most preview
// characters, and a blob at most preview bytes, and never more than
// field.BLOB_PREVIEW, as in the dump.
rows :: proc(m: ^Model, first, n: int, preview := 0, allocator := context.temp_allocator) -> []Row {
	if first < 0 || first >= count(m) || n <= 0 do return nil
	out := make([dynamic]Row, 0, min(n, count(m) - first), allocator)
	c := locate(m, first, allocator)
	defer delete(c.frames)
	for len(out) < n {
		append(&out, make_row(m, &c, preview, allocator))
		if !advance(m, &c) do break
	}
	return out[:]
}

// Expands row r, when it is a set or an array with rows under it and is
// not expanded. Returns whether it did. r stays the row's index.
expand :: proc(m: ^Model, r: int) -> bool {
	if r < 0 || r >= count(m) do return false
	c := locate(m, r, context.temp_allocator)
	defer delete(c.frames)
	if current_open(m, &c) != nil do return false
	f := &c.frames[len(c.frames) - 1]
	item := child(m, f.item, c.pos)
	if !can_expand(item) do return false
	n := child_count(m, item)
	if n == 0 do return false

	o := new(Open, m.allocator)
	o^ = {parent = f.open, pos = c.pos, priority = next_priority(m)}
	insert(m, f.open, o)
	grow(m, o, n)
	return true
}

// Collapses row r, when it is expanded, forgetting which rows under it
// were. Returns whether it did. r stays the row's index.
collapse :: proc(m: ^Model, r: int) -> bool {
	if r < 0 || r >= count(m) do return false
	c := locate(m, r, context.temp_allocator)
	defer delete(c.frames)
	o := current_open(m, &c)
	if o == nil do return false
	grow(m, o, -o.below)
	remove(m, o.parent, o.pos)
	free_open(m, o)
	return true
}

// Expands every row, as the dump shows every value. It takes the time and
// memory of every set and array in the tree.
expand_all :: proc(m: ^Model) {
	free_treap(m, m.top.children)
	m.top.children = nil
	m.top.below = open_all(m, &m.top, top_item())
}

// The row that row r is under, or -1 for a row at depth 0.
parent :: proc(m: ^Model, r: int) -> int {
	if r < 0 || r >= count(m) do return -1
	c := locate(m, r, context.temp_allocator)
	defer delete(c.frames)
	return c.frames[len(c.frames) - 1].row
}

// The row after row r under the same row, past the rows under r, or -1
// when r is the last.
next_sibling :: proc(m: ^Model, r: int) -> int {
	if r < 0 || r >= count(m) do return -1
	c := locate(m, r, context.temp_allocator)
	defer delete(c.frames)
	if c.pos + 1 >= c.frames[len(c.frames) - 1].count do return -1
	below := 0
	if o := current_open(m, &c); o != nil do below = o.below
	return r + 1 + below
}

// The row before row r under the same row, or -1 when r is the first.
prev_sibling :: proc(m: ^Model, r: int) -> int {
	if r < 0 || r >= count(m) do return -1
	c := locate(m, r, context.temp_allocator)
	defer delete(c.frames)
	if c.pos == 0 do return -1
	below := 0
	if o := find(m, c.frames[len(c.frames) - 1].open, c.pos - 1); o != nil do below = o.below
	return r - 1 - below
}

// A row's place: the rows it is under, outermost first, each with the
// expanded row of its own (the top for the first), and its position among
// the rows of the innermost.
@(private)
Cursor :: struct {
	frames: [dynamic]Frame,
	pos:    int, // among the rows of the last frame
	row:    int,
}

@(private)
Frame :: struct {
	open:  ^Open,
	item:  Item,
	count: int, // the rows directly under it
	pos:   int, // its position among the rows of the frame before
	row:   int, // its row; -1 for the top
}

// The cursor of row r, which must be a row. At each depth it descends the
// treap of the expanded rows, counting the rows under those before r.
@(private)
locate :: proc(m: ^Model, r: int, allocator: mem.Allocator) -> (c: Cursor) {
	c.frames = make([dynamic]Frame, 0, 8, allocator)
	append(&c.frames, Frame{open = &m.top, item = top_item(), count = child_count(m, top_item()), row = -1})
	c.row = r
	base := 0 // the row of the first row of the last frame
	for {
		f := &c.frames[len(c.frames) - 1]
		rel := r - base
		before := 0 // rows under the expanded rows before the subtree descended into
		inside: ^Open
		start: int
		for x := f.open.children; x != nil; {
			m.steps += 1
			start = x.pos + before + sum_of(x.left)
			if rel < start {
				x = x.left
			} else if rel == start {
				c.pos = x.pos
				return
			} else if rel <= start + x.below {
				inside = x
				break
			} else {
				before += sum_of(x.left) + x.below
				x = x.right
			}
		}
		if inside == nil {
			c.pos = rel - before
			return
		}
		item := child(m, f.item, inside.pos)
		append(&c.frames, Frame{open = inside, item = item, count = child_count(m, item), pos = inside.pos, row = base + start})
		base += start + 1
	}
}

// The expanded row at the cursor, or nil.
@(private)
current_open :: proc(m: ^Model, c: ^Cursor) -> ^Open {
	return find(m, c.frames[len(c.frames) - 1].open, c.pos)
}

// Moves c to the next row; false after the last.
@(private)
advance :: proc(m: ^Model, c: ^Cursor) -> bool {
	if o := current_open(m, c); o != nil {
		f := &c.frames[len(c.frames) - 1]
		item := child(m, f.item, c.pos)
		append(&c.frames, Frame{open = o, item = item, count = child_count(m, item), pos = c.pos, row = c.row})
		c.pos = 0
		c.row += 1
		return true
	}
	c.pos += 1
	c.row += 1
	for c.pos >= c.frames[len(c.frames) - 1].count {
		if len(c.frames) == 1 do return false
		done := pop(&c.frames)
		c.pos = done.pos + 1
	}
	return true
}

// The expanded row at position pos under o, or nil.
@(private)
find :: proc(m: ^Model, o: ^Open, pos: int) -> ^Open {
	for x := o.children; x != nil; x = pos < x.pos ? x.left : x.right {
		m.steps += 1
		if x.pos == pos do return x
	}
	return nil
}

// Adds delta to the rows under o and the rows it is under, and to the sums
// of the treaps they are in, on the path from each treap's root to it.
@(private)
grow :: proc(m: ^Model, o: ^Open, delta: int) {
	for a := o; a != nil; a = a.parent {
		a.below += delta
		if a.parent == nil do continue
		for x := a.parent.children; x != nil; x = a.pos < x.pos ? x.left : x.right {
			m.steps += 1
			x.sum += delta
			if x == a do break
		}
	}
}

// Adds o, which is not expanded under anything, to the treap of the rows
// expanded under parent.
@(private)
insert :: proc(m: ^Model, parent: ^Open, o: ^Open) {
	o.sum = o.below
	before, after := split(m, parent.children, o.pos)
	parent.children = merge(m, merge(m, before, o), after)
}

// Removes the row expanded at pos from the treap of those under parent.
@(private)
remove :: proc(m: ^Model, parent: ^Open, pos: int) {
	before, rest := split(m, parent.children, pos)
	_, after := split(m, rest, pos + 1)
	parent.children = merge(m, before, after)
}

// The rows of treap t before pos, and those at or after it.
@(private)
split :: proc(m: ^Model, t: ^Open, pos: int) -> (before, after: ^Open) {
	if t == nil do return nil, nil
	m.steps += 1
	if t.pos < pos {
		t.right, after = split(m, t.right, pos)
		update(t)
		return t, after
	}
	before, t.left = split(m, t.left, pos)
	update(t)
	return before, t
}

// The treap of a and b, every row of a before every row of b.
@(private)
merge :: proc(m: ^Model, a, b: ^Open) -> ^Open {
	if a == nil do return b
	if b == nil do return a
	m.steps += 1
	if a.priority > b.priority {
		a.right = merge(m, a.right, b)
		update(a)
		return a
	}
	b.left = merge(m, a, b.left)
	update(b)
	return b
}

@(private)
update :: proc(o: ^Open) {
	o.sum = sum_of(o.left) + o.below + sum_of(o.right)
}

@(private)
sum_of :: proc(o: ^Open) -> int {
	return o == nil ? 0 : o.sum
}

// A priority for a treap's row, from a xorshift of the model's seed: the
// same model makes the same treaps.
@(private)
next_priority :: proc(m: ^Model) -> u64 {
	m.seed ~= m.seed << 13
	m.seed ~= m.seed >> 7
	m.seed ~= m.seed << 17
	return m.seed
}

@(private)
make_row :: proc(m: ^Model, c: ^Cursor, preview: int, allocator: mem.Allocator) -> Row {
	f := &c.frames[len(c.frames) - 1]
	item := child(m, f.item, c.pos)
	row := Row {
		depth    = len(c.frames) - 1,
		name     = item.name,
		element  = !item.single && item.index >= 0,
		index    = item.index,
		expanded = current_open(m, c) != nil,
	}
	if m.tree.spans {
		// the frames past the top are the rows this one is under
		for f in c.frames[1:] {
			if f.item.index >= 0 && f.item.node != nil && f.item.node.process != .None {
				row.decompressed = true
				row.source = value_span(m, f.item, f.item.index)
				break
			}
		}
	}
	if item.index < 0 {
		row.kind = .Array
		row.count = len(item.values)
		row.expandable = row.count > 0
		if m.tree.spans && row.count > 0 {
			first, last := value_span(m, item, 0), value_span(m, item, row.count - 1)
			row.span = {first.offset, max(last.offset + last.size - first.offset, 0)}
			row.has_span = true
		}
		return row
	}
	if m.tree.spans {
		row.span = value_span(m, item, item.index)
		row.has_span = true
	}
	if _, is_set := item.values[item.index].(^fld.Instance); is_set {
		row.kind = .Set
		row.expandable = child_count(m, item) > 0
		return row
	}
	b := strings.builder_make(allocator)
	blob_preview := preview > 0 ? min(preview, fld.BLOB_PREVIEW) : fld.BLOB_PREVIEW
	_ = fld.write_value(strings.to_writer(&b), item.values[item.index], preview, blob_preview)
	row.text = strings.to_string(b)
	m.formatted += 1
	return row
}

@(private)
value_span :: proc(m: ^Model, item: Item, i: int) -> fld.Span {
	return item.owner == nil ? fld.root_span(m.tree, i) : fld.value_span(item.owner, item.k, i)
}

@(private)
top_item :: proc() -> Item {
	return {index = TOP}
}

// Whether item's row is one that can be expanded, when it has rows under it:
// a set instance or an array.
@(private)
can_expand :: proc(item: Item) -> bool {
	if item.index == TOP do return false
	if item.index < 0 do return true
	_, is_set := item.values[item.index].(^fld.Instance)
	return is_set
}

// The rows directly under item.
@(private)
child_count :: proc(m: ^Model, item: Item) -> int {
	switch {
	case item.index == TOP:
		return len(m.tree.root) > 0 ? 1 : 0
	case item.index < 0:
		return len(item.values)
	}
	n, _ := field_row(m, item, -1)
	return n
}

// Row p directly under item, which has it.
@(private)
child :: proc(m: ^Model, item: Item, p: int) -> Item {
	switch {
	case item.index == TOP:
		// the root's field is read once
		return {name = m.format.root.name, node = m.format.root, values = m.tree.root, index = 0, single = true}
	case item.index < 0:
		e := item
		e.index = p
		return e
	}
	_, found := field_row(m, item, p)
	return found
}

// The rows of the fields of item, a set instance, in the dump's order: each
// child, then its -bits fields, then the parse instances. A field read once
// is a row when it has a value, and any other field is the row of an array.
// Returns the count of them, and when p is one of them, row p.
@(private)
field_row :: proc(m: ^Model, item: Item, p: int) -> (n: int, found: Item) {
	instance := item.values[item.index].(^fld.Instance)
	set := mdata.instance_set(item.node, instance)
	add :: proc(m: ^Model, n: ^int, found: ^Item, p: int, instance: ^fld.Instance, name: string, node: ^mdata.Node, k: int, single: bool) -> bool {
		m.steps += 1
		values := instance.slots[k]
		if single && len(values) == 0 do return false
		if n^ == p do found^ = {name = name, node = node, owner = instance, k = k, values = values, index = single ? 0 : -1, single = single}
		n^ += 1
		return n^ > p && p >= 0
	}
	slot := len(set.parse_instances)
	for child in set.children {
		single := mdata.is_single(child)
		if add(m, &n, &found, p, instance, child.name, child, slot, single) do return
		for bit, b in child.bits {
			if add(m, &n, &found, p, instance, bit.name, nil, slot + 1 + b, single) do return
		}
		slot += 1 + len(child.bits)
	}
	for pi, j in set.parse_instances {
		if add(m, &n, &found, p, instance, pi.name, pi, j, mdata.is_single(pi)) do return
	}
	return
}

// Expands every set and array under item, whose expanded row is o, and
// returns the rows visible under it.
@(private)
open_all :: proc(m: ^Model, o: ^Open, item: Item) -> (below: int) {
	n := child_count(m, item)
	below = n
	for p in 0 ..< n {
		c := child(m, item, p)
		if !can_expand(c) || child_count(m, c) == 0 do continue
		co := new(Open, m.allocator)
		co^ = {parent = o, pos = p, priority = next_priority(m)}
		co.below = open_all(m, co, c)
		insert(m, o, co)
		below += co.below
	}
	return
}

@(private)
free_open :: proc(m: ^Model, o: ^Open) {
	free_treap(m, o.children)
	free(o, m.allocator)
}

@(private)
free_treap :: proc(m: ^Model, t: ^Open) {
	if t == nil do return
	free_treap(m, t.left)
	free_treap(m, t.right)
	free_open(m, t)
}
