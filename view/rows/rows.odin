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

// An expanded row: its position among the rows of the row it is under, the
// rows visible under it, and those of them that are expanded, by position.
@(private)
Open :: struct {
	parent:   ^Open,
	pos:      int,
	below:    int,
	children: [dynamic]^Open,
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
	// for the tests: the expanded rows and fields stepped over to find
	// rows, and the values formatted
	steps:     int,
	formatted: int,
}

// Makes the rows of tree, read with format, with the root's set expanded.
init :: proc(m: ^Model, format: ^mdata.File_Format, tree: ^fld.Value_Tree, allocator := context.allocator) {
	m^ = {format = format, tree = tree, allocator = allocator}
	m.top.children = make([dynamic]^Open, allocator)
	m.top.below = child_count(m, top_item())
	if m.top.below > 0 do expand(m, 0)
}

destroy :: proc(m: ^Model) {
	for o in m.top.children do free_open(m, o)
	delete(m.top.children)
	m^ = {}
}

// The rows there are, with those under the rows expanded.
count :: proc(m: ^Model) -> int {
	return m.top.below
}

// Rows first to first + n - 1, or to the last row, with their text in
// allocator, a string's cut at preview characters when it is above 0.
rows :: proc(m: ^Model, first, n: int, preview := 0, allocator := context.temp_allocator) -> []Row {
	if first < 0 || first >= count(m) || n <= 0 do return nil
	out := make([dynamic]Row, 0, min(n, count(m) - first), allocator)
	c := locate(m, first, allocator)
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
	f := &c.frames[len(c.frames) - 1]
	if current_open(&c) != nil do return false
	item := child(m, f.item, c.pos)
	if !can_expand(item) do return false
	n := child_count(m, item)
	if n == 0 do return false

	o := new(Open, m.allocator)
	o^ = {parent = f.open, pos = c.pos, below = n}
	o.children = make([dynamic]^Open, m.allocator)
	inject_at(&f.open.children, f.next, o)
	for a := f.open; a != nil; a = a.parent do a.below += n
	return true
}

// Collapses row r, when it is expanded, forgetting which rows under it
// were. Returns whether it did. r stays the row's index.
collapse :: proc(m: ^Model, r: int) -> bool {
	if r < 0 || r >= count(m) do return false
	c := locate(m, r, context.temp_allocator)
	o := current_open(&c)
	if o == nil do return false
	f := &c.frames[len(c.frames) - 1]
	ordered_remove(&f.open.children, f.next)
	for a := f.open; a != nil; a = a.parent do a.below -= o.below
	free_open(m, o)
	return true
}

// Expands every row, as the dump shows every value. It takes the time and
// memory of every set and array in the tree.
expand_all :: proc(m: ^Model) {
	for o in m.top.children do free_open(m, o)
	clear(&m.top.children)
	m.top.below = open_all(m, &m.top, top_item())
}

// The row that row r is under, or -1 for a row at depth 0.
parent :: proc(m: ^Model, r: int) -> int {
	if r < 0 || r >= count(m) do return -1
	c := locate(m, r, context.temp_allocator)
	return c.frames[len(c.frames) - 1].row
}

// The row after row r under the same row, past the rows under r, or -1
// when r is the last.
next_sibling :: proc(m: ^Model, r: int) -> int {
	if r < 0 || r >= count(m) do return -1
	c := locate(m, r, context.temp_allocator)
	f := &c.frames[len(c.frames) - 1]
	if c.pos + 1 >= f.count do return -1
	below := 0
	if o := current_open(&c); o != nil do below = o.below
	return r + 1 + below
}

// The row before row r under the same row, or -1 when r is the first.
prev_sibling :: proc(m: ^Model, r: int) -> int {
	if r < 0 || r >= count(m) do return -1
	c := locate(m, r, context.temp_allocator)
	if c.pos == 0 do return -1
	f := &c.frames[len(c.frames) - 1]
	// the expanded rows before the current one end just before f.next
	below := 0
	if f.next > 0 {
		if o := f.open.children[f.next - 1]; o.pos == c.pos - 1 do below = o.below
	}
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
	next:  int, // the first of open.children at or after the cursor's position
}

// The cursor of row r, which must be a row. It steps over the expanded rows
// before r at each depth, not over the rows themselves.
@(private)
locate :: proc(m: ^Model, r: int, allocator: mem.Allocator) -> (c: Cursor) {
	c.frames = make([dynamic]Frame, 0, 8, allocator)
	append(&c.frames, Frame{open = &m.top, item = top_item(), count = child_count(m, top_item()), row = -1})
	c.row = r
	base := 0 // the row of the first row of the last frame
	descend: for {
		f := &c.frames[len(c.frames) - 1]
		extra := 0 // rows under the expanded rows before
		for o, i in f.open.children {
			m.steps += 1
			start := base + o.pos + extra
			if r < start do break
			if r == start {
				f.next = i
				c.pos = o.pos
				return
			}
			if r <= start + o.below {
				f.next = i + 1
				item := child(m, f.item, o.pos)
				append(&c.frames, Frame{open = o, item = item, count = child_count(m, item), pos = o.pos, row = start})
				base = start + 1
				continue descend
			}
			extra += o.below
			f.next = i + 1
		}
		c.pos = r - base - extra
		return
	}
}

// The expanded row at the cursor, or nil.
@(private)
current_open :: proc(c: ^Cursor) -> ^Open {
	f := &c.frames[len(c.frames) - 1]
	if f.next < len(f.open.children) {
		if o := f.open.children[f.next]; o.pos == c.pos do return o
	}
	return nil
}

// Moves c to the next row; false after the last.
@(private)
advance :: proc(m: ^Model, c: ^Cursor) -> bool {
	f := &c.frames[len(c.frames) - 1]
	if o := current_open(c); o != nil {
		f.next += 1
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

@(private)
make_row :: proc(m: ^Model, c: ^Cursor, preview: int, allocator: mem.Allocator) -> Row {
	f := &c.frames[len(c.frames) - 1]
	item := child(m, f.item, c.pos)
	row := Row {
		depth    = len(c.frames) - 1,
		name     = item.name,
		element  = !item.single && item.index >= 0,
		index    = item.index,
		expanded = current_open(c) != nil,
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
	_ = fld.write_value(strings.to_writer(&b), item.values[item.index], preview)
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
		co^ = {parent = o, pos = p}
		co.children = make([dynamic]^Open, m.allocator)
		append(&o.children, co)
		co.below = open_all(m, co, c)
		below += co.below
	}
	return
}

@(private)
free_open :: proc(m: ^Model, o: ^Open) {
	for c in o.children do free_open(m, c)
	delete(o.children)
	free(o, m.allocator)
}
