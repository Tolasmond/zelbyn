package reader

import arn "../arena"
import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:os"
import "core:slice"

// Reads the file name into tree's arena, closes it, and decodes it into
// tree, which must be zero or destroyed. Strings and blobs are views of that
// copy, so the tree owns its input: it needs neither the file nor the
// schema once read returns. With spans, the tree records the span of each
// value (field.value_span), which costs memory and time.
@(require_results)
read :: proc(name: string, format: ^mdata.File_Format, tree: ^fld.Value_Tree, spans := false) -> (consumed: int, err: Parse_Error) {
	assert(tree.arena.block == nil && tree.root == nil, "read: tree must be zero or destroyed")
	f, open_err := os.open(name)
	if open_err != nil {
		return 0, Parse_Error{kind = .File_Read_Failed, os_error = open_err}
	}
	// a size that cannot be found leaves the arena at its default first block
	size, _ := os.file_size(f)
	init_arena(tree, int(size))
	data, read_err := os.read_entire_file(f, arn.arena_allocator(&tree.arena))
	os.close(f)
	if read_err != nil {
		return 0, Parse_Error{kind = .File_Read_Failed, os_error = read_err}
	}
	return decode(data, format, tree, spans)
}

// Decodes data into tree, which must be zero or destroyed. Strings and
// blobs are views of data, which the tree borrows: keep data alive and
// unchanged for as long as the tree is used. The tree references nothing
// in the schema. spans is as for read.
@(require_results)
read_from_bytes :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree, spans := false) -> (consumed: int, err: Parse_Error) {
	assert(tree.arena.block == nil && tree.root == nil, "read_from_bytes: tree must be zero or destroyed")
	init_arena(tree, len(data))
	return decode(data, format, tree, spans)
}

// Sizes the first block of tree's arena for an input of input_size bytes.
// The block is reserved, and committed only as it is used; it holds the
// tree of every sample, and the input too when read put it there.
@(private = "file")
init_arena :: proc(tree: ^fld.Value_Tree, input_size: int) {
	arn.arena_init(&tree.arena, max(16 * uint(max(input_size, 0)), arn.ARENA_BLOCK_SIZE))
}

// Decodes data into tree, whose arena init_arena has sized. The decoder is
// compiled twice, with and without spans, so that a decode without them
// pays nothing for them.
@(private = "file", require_results)
decode :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree, spans: bool) -> (consumed: int, err: Parse_Error) {
	allocator := arn.arena_allocator(&tree.arena)
	tree.spans = spans

	d := Decoder{arena = &tree.arena, allocator = allocator, spans = spans}
	d.path = make([dynamic]Path_Segment, allocator)
	d.frames = make([dynamic]Frame, allocator)
	d.streams = make([dynamic]Stream, allocator)
	dat.reader_init(&d.r, data)

	root := Sink{slots = ([^][]fld.Value)(&tree.root)[:1]}
	rerr := spans ? read_values(&d, &root, format.root, true) : read_values(&d, &root, format.root, false)
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}

	return d.r.pos, d.err
}

// Where the values of one field go: its slot, then a slot for each of its
// bit fields, in the instance that holds them, or the tree's root. Each
// slot is a view of an array with room for cap values.
@(private = "file")
Sink :: struct {
	slots: [][]fld.Value,
	cells: []fld.Value, // the instance's cells for slots; nil for the root
	cap:   int,
}

// An array with room for n values, and with SPANS, for their spans before
// it (field.value_span).
@(private = "file")
make_values :: #force_inline proc(d: ^Decoder, n: int, $SPANS: bool) -> []fld.Value {
	when SPANS {
		#assert(size_of(fld.Span) % size_of(rawptr) == 0 && size_of(fld.Value) % size_of(rawptr) == 0)
		SPAN_WORDS :: size_of(fld.Span) / size_of(rawptr)
		VALUE_WORDS :: size_of(fld.Value) / size_of(rawptr)
		if n <= 0 do return nil
		words := raw_data(arn.arena_make(d.arena, rawptr, n * (SPAN_WORDS + VALUE_WORDS)))
		return ([^]fld.Value)(&words[n * SPAN_WORDS])[:n]
	} else {
		return arn.arena_make(d.arena, fld.Value, n)
	}
}

// Makes room for n values in each slot of s, which must be empty: the cells
// when n is at most 1, else an array of exactly n.
@(private = "file")
reserve_exactly :: proc(d: ^Decoder, s: ^Sink, n: int, $SPANS: bool) {
	for &slot, k in s.slots {
		slot = n <= 1 && s.cells != nil ? s.cells[k:k] : make_values(d, n, SPANS)[:0]
	}
	s.cap = n
}

// Makes room for at least n values in each slot of s, doubling, for a count
// that is not known in advance.
@(private = "file")
reserve_growing :: proc(d: ^Decoder, s: ^Sink, n: int, $SPANS: bool) {
	if n <= s.cap do return
	s.cap = max(8, 2 * s.cap, n)
	for &slot in s.slots {
		grown := make_values(d, s.cap, SPANS)
		copy(grown, slot)
		when SPANS {
			if len(slot) > 0 do copy(([^]fld.Span)(fld.array_span(grown, len(slot) - 1))[:len(slot)], ([^]fld.Span)(fld.array_span(slot, len(slot) - 1))[:len(slot)])
		}
		slot = grown[:len(slot)]
	}
}

// Appends v to slot k of s, which has room for it.
@(private = "file")
push :: #force_inline proc(s: ^Sink, k: int, v: fld.Value) {
	slot := s.slots[k]
	assert(len(slot) < s.cap, "push: no room in the slot")
	s.slots[k] = ([^]fld.Value)(raw_data(slot))[:len(slot) + 1]
	s.slots[k][len(slot)] = v
}

// Records the span of the last value of slot k of s, in a tree read with
// spans: from start, a position in the stream being read, to the stream's
// position. A value in a cell is in the instance of the innermost frame,
// which keeps the cells' spans (field.value_span).
@(private = "file")
set_span :: proc(d: ^Decoder, s: ^Sink, k: int, start: int) {
	slot := s.slots[k]
	span := fld.Span{d.base + start, d.r.pos - start}
	if s.cells == nil || raw_data(slot) != &s.cells[k] {
		fld.array_span(slot, len(slot) - 1)^ = span
		return
	}
	instance := d.frames[len(d.frames) - 1].instance
	cells := fld.instance_cells(instance)
	assert(uintptr(raw_data(slot)) >= uintptr(raw_data(cells)) && uintptr(raw_data(slot)) < uintptr(raw_data(cells)) + uintptr(len(cells) * size_of(fld.Value)), "set_span: the cell is not the innermost instance's")
	fld.cell_spans(instance)[(uintptr(raw_data(slot)) - uintptr(raw_data(cells))) / size_of(fld.Value)] = span
}

// Reads every value of node into s: the instances of a set, or the elements
// of any other field, with their bit fields. A parse instance is read at
// its pos, which moves the stream: read_parse_instance puts it back.
@(private = "file", require_results)
read_values :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, $SPANS: bool) -> dat.Read_Error {
	if node.align do dat.align_to_byte(&d.r)

	if node.cond != nil {
		read_it, err := eval_bool(d, node.cond)
		if err != .None do return fail(d, err, d.r.pos)
		if !read_it do return .None
	}

	if node.pos != nil {
		// io, then pos, in the instance's stream; pos is in io's
		stream := Stream{d.r, d.base}
		err: dat.Read_Error
		if node.io != nil do stream, err = eval_stream(d, node.io)
		pos: int
		if err == .None do pos, err = eval_int(d, node.pos)
		if err == .None && (pos < 0 || pos > len(stream.r.data)) do err = .Offset_Out_Of_Range
		if err != .None {
			append(&d.path, Path_Segment{node.name, 0})
			return fail(d, err, d.r.pos)
		}
		if node.io != nil {
			// the instance's stream stays its frame's, for _io in the rest
			// of node's expressions; read_parse_instance puts the streams
			// back
			append(&d.streams, Stream{d.r, d.base})
			d.r, d.base = stream.r, stream.base
		}
		d.r.pos = pos
		// unlike Kaitai's runtimes, which keep the bits left over from
		// whatever was read before the instance
		dat.align_to_byte(&d.r)
	}

	count: int
	switch c in node.count {
	case mdata.Fixed_Count:
		count = c.n
	case mdata.Rule_Count:
		n, err := eval_int(d, c.expr)
		if err == .None && n < 0 do err = .Invalid_Length
		if err != .None do return fail(d, err, d.r.pos)
		count = n
	case mdata.Marker_Count:
		count = markers_match(&d.r, c.markers) ? 1 : 0
	case mdata.Repeat_Count:
		return read_repeat(d, s, node, c, SPANS)
	case mdata.Eos_Count:
		for i := 0; !dat.at_eof(&d.r); i += 1 {
			start, start_bits := d.r.pos, dat.bit_pos(&d.r)
			reserve_growing(d, s, i + 1, SPANS)
			read_element(d, s, node, i, SPANS) or_return
			if dat.bit_pos(&d.r) == start_bits do return no_progress(d, node, i, start)
		}
		return .None
	case mdata.Until_Count:
		for i := 0;; i += 1 {
			start, start_bits := d.r.pos, dat.bit_pos(&d.r)
			reserve_growing(d, s, i + 1, SPANS)
			read_element(d, s, node, i, SPANS) or_return

			values := s.slots[0]
			done, err := eval_bool(d, c.expr, element = values[len(values) - 1])
			if err != .None do return fail(d, err, d.r.pos)
			if done do return .None

			if dat.bit_pos(&d.r) == start_bits do return no_progress(d, node, i, start)
		}
	}

	// elements that consume input cannot outnumber the bytes left, so a
	// larger count, which may come from the input, grows as it is read
	if count <= 1 || count <= len(d.r.data) - d.r.pos {
		reserve_exactly(d, s, count, SPANS)
		for i in 0 ..< count {
			read_element(d, s, node, i, SPANS) or_return
		}
	} else {
		for i in 0 ..< count {
			reserve_growing(d, s, i + 1, SPANS)
			read_element(d, s, node, i, SPANS) or_return
		}
	}
	return .None
}

// Reads elements of node while its continuator is present or until its
// terminator is found. The terminator is required, and every element must
// consume input.
@(private = "file", require_results)
read_repeat :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, repeat: mdata.Repeat_Count, $SPANS: bool) -> dat.Read_Error {
	for {
		value, peek_err := dat.peek_integer_at(&d.r, d.r.pos, repeat.type, repeat.order)

		if repeat.until {
			if peek_err != .None do return fail(d, .Unexpected_EOF, d.r.pos)
			if value == repeat.value do return .None
		} else {
			if peek_err != .None || value != repeat.value do return .None
		}

		n := len(s.slots[0])
		start, start_bits := d.r.pos, dat.bit_pos(&d.r)
		reserve_growing(d, s, n + 1, SPANS)
		read_element(d, s, node, n, SPANS) or_return
		if dat.bit_pos(&d.r) == start_bits do return no_progress(d, node, n, start)
	}
}

// Fails with .No_Progress for element index of node, which started at
// start and consumed no input.
@(private = "file")
no_progress :: proc(d: ^Decoder, node: ^mdata.Node, index, start: int) -> dat.Read_Error {
	append(&d.path, Path_Segment{node.name, index})
	return fail(d, .No_Progress, start)
}

// Reads element index of node into s, which has room for it: an instance of
// a set, or a value of any other field and its bit fields, each with its
// span when SPANS is set.
@(private = "file", require_results)
read_element :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, index: int, $SPANS: bool) -> dat.Read_Error {
	// on error the segment is left pushed; fail has already copied the path
	append(&d.path, Path_Segment{node.name, index})
	start := d.r.pos

	if node.type == .Set {
		read_instance(d, s, node, index, SPANS) or_return
		// a switch-on that chooses no set reads nothing
		read := len(s.slots[0]) > index
		when SPANS do if read do set_span(d, s, 0, start)
		if node.valid != nil && read {
			if e := check_valid(d, s.slots[0][index], node.valid, index); e != .None do return fail(d, e, start)
		}
		pop(&d.path)
		return .None
	}

	value := read_scalar(d, node, index) or_return
	push(s, 0, value)
	when SPANS do set_span(d, s, 0, start)
	if node.valid != nil {
		if e := check_valid(d, value, node.valid, index); e != .None do return fail(d, e, start)
	}
	pop(&d.path)

	for bit, b in node.bits {
		bit_value := bit_field_value(value, bit)
		push(s, 1 + b, bit_value)
		when SPANS do set_span(d, s, 1 + b, start)

		if bit.valid != nil {
			if e := check_constant(bit_value, bit.valid); e != .None {
				append(&d.path, Path_Segment{bit.name, index})
				return fail(d, e, start)
			}
		}
	}
	return .None
}

// Reads instance index of set node into s: from a substream when node has
// a length or a terminator, and as the set its switch-on chooses, with
// that set's arguments. As in Kaitai, they are evaluated in node's stream,
// after the bytes of the substream. A switch-on that chooses no set reads
// nothing, or with a length, the bytes of the length, as a []byte: as the
// official compiler does, without removing pad_right or cutting them at a
// terminator. One that chooses a case that is not a set reads a value of
// its type, as a field of that type, in node's stream.
@(private = "file", require_results)
read_instance :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, index: int, $SPANS: bool) -> dat.Read_Error {
	set := node
	choice := 0
	if sw := node.switch_on; sw != nil {
		set, choice = sw.default, fld.DEFAULT_CASE
		if sw.on.type == .String {
			on, err := eval_string(d, sw.on, index)
			if err != .None do return fail(d, err, d.r.pos)
			for c, i in sw.cases {
				if c.text == on {
					set, choice = c.node, i
					break
				}
			}
		} else {
			on, err := eval_int(d, sw.on, index)
			if err != .None do return fail(d, err, d.r.pos)
			for c, i in sw.cases {
				if c.value == on {
					set, choice = c.node, i
					break
				}
			}
		}
		if set == nil do return read_unchosen(d, s, node, index)
		if set.type != .Set do return read_case_value(d, s, set, index)
	}

	if node.length == nil && node.terminator == nil {
		args: []fld.Value
		if len(set.args) > 0 do args = eval_args(d, set, index) or_return
		return read_set_instance(d, s, set, choice, args, SPANS)
	}

	start := d.r.pos
	bytes := element_bytes(d, node, index) or_return
	args: []fld.Value
	if len(set.args) > 0 do args = eval_args(d, set, index) or_return

	// the parent's stream is already past the substream, whatever the
	// instance consumes
	append(&d.streams, Stream{d.r, d.base})
	defer {
		parent := pop(&d.streams)
		d.r = parent.r
		d.base = parent.base
	}
	dat.reader_init(&d.r, bytes)
	d.base += start

	return read_set_instance(d, s, set, choice, args, SPANS)
}

// Reads element index of node, a switch-on field that chose no set, into
// s: nothing, or with a length, the bytes of the length, as they are.
@(private = "file", require_results)
read_unchosen :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, index: int) -> dat.Read_Error {
	if node.length == nil do return .None
	start := d.r.pos
	n, err := byte_length(d, node.length, index)
	if err != .None do return fail(d, err, start)
	bytes: []byte
	bytes, err = dat.read_bytes(&d.r, n)
	if err != .None do return fail(d, err, start)
	push(s, 0, bytes)
	return .None
}

// Reads element index of a switch-on field into s as node, the case it
// chose, which is not a set: a value of node's type, with the length and
// terminator the case has.
@(private = "file", require_results)
read_case_value :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, index: int) -> dat.Read_Error {
	value := read_scalar(d, node, index) or_return
	push(s, 0, value)
	return .None
}

// The values of the arguments of set, which has some, for instance index,
// in the tree's arena. The callers check that it has some: a call for
// every instance costs more than the check.
@(private = "file", require_results)
eval_args :: proc(d: ^Decoder, set: ^mdata.Node, index: int) -> (args: []fld.Value, err: dat.Read_Error) {
	args = arn.arena_make(d.arena, fld.Value, len(set.args))
	for a, k in set.args {
		v, e := eval_value(d, a, index)
		if e != .None do return nil, fail(d, e, d.r.pos)
		args[k] = v
	}
	return args, .None
}

// Appends one instance of set node to s, read as choice (see
// field.Instance), with the values of its params, args, and reads its
// children into it, then the parse instances that no expression has read.
@(private = "file", require_results)
read_set_instance :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, choice: int, args: []fld.Value, $SPANS: bool) -> dat.Read_Error {
	when ODIN_DEBUG {
		assert(node.slot_count == mdata.count_slots(node), "read_set_instance: the set's slot_count was not recorded")
	}
	instance, cells := fld.make_instance(d.arena, node.slot_count, choice, SPANS)
	push(s, 0, instance)
	if node.keeps_stream do keep_stream(d, instance)
	for v, k in args {
		slot := mdata.param_slot(node, k)
		cells[slot] = v
		instance.slots[slot] = cells[slot:][:1]
	}

	// on error the frame is left pushed, like the path segment
	append(&d.frames, Frame{instance, len(d.streams), len(d.path)})

	slot := len(node.parse_instances)
	for child in node.children {
		n := 1 + len(child.bits)
		child_sink := Sink{slots = instance.slots[slot:][:n], cells = cells[slot:][:n]}
		read_values(d, &child_sink, child, SPANS) or_return
		slot += n
	}

	for p, k in node.parse_instances {
		if raw_data(instance.slots[k]) == nil do read_parse_instance(d, instance, p, k, SPANS) or_return
	}

	pop(&d.frames)
	return .None
}

// Records the stream of instance, which is being read, for an io
// expression that refers to it (eval_stream). Not inlined: inlining it into
// read_set_instance costs 0.5% more decode instructions.
@(private = "file")
keep_stream :: #force_no_inline proc(d: ^Decoder, instance: ^fld.Instance) {
	if d.kept == nil do d.kept = make(map[^fld.Instance]Stream, d.allocator)
	d.kept[instance] = Stream{d.r, d.base}
}

// Reads parse instance node of instance, a set instance being decoded, into
// slot k: at its pos in the instance's stream, as the instance's frame
// sees it, or in the stream of its io. The stream, frames and path are then
// put back as they were.
@(private, require_results)
read_parse_instance :: proc(d: ^Decoder, instance: ^fld.Instance, node: ^mdata.Node, k: int, $SPANS: bool) -> dat.Read_Error {
	j := len(d.frames) - 1
	for j >= 0 && d.frames[j].instance != instance do j -= 1
	// an instance that is no longer decoded had its parse instances read
	assert(j >= 0, "read_parse_instance: the instance is not being decoded")
	frame := d.frames[j]

	cells := fld.instance_cells(instance)
	// from here on the slot is not nil, so the instance is read only once
	instance.slots[k] = cells[k:k]

	r, base := d.r, d.base
	defer {
		d.r = r
		d.base = base
	}
	if frame.stream < len(d.streams) {
		d.r = d.streams[frame.stream].r
		d.base = d.streams[frame.stream].base
	}

	// the frames, streams and path above the instance's are set aside while
	// it is read, and so are the streams when io adds the instance's
	frames, streams, path := d.frames, d.streams, d.path
	aside := j < len(frames) - 1 || frame.stream < len(streams) || frame.path < len(path) || node.io != nil
	if aside {
		d.frames = clone_dynamic(d, frames[:j + 1])
		d.streams = clone_dynamic(d, streams[:frame.stream])
		d.path = clone_dynamic(d, path[:frame.path])
	}

	s := Sink{slots = instance.slots[k:][:1], cells = cells[k:][:1]}
	err := read_values(d, &s, node, SPANS)
	if aside {
		d.frames = frames
		d.streams = streams
		d.path = path
	}
	return err
}

// A copy of values, in the tree's arena, to append to.
@(private = "file")
clone_dynamic :: proc(d: ^Decoder, values: []$T) -> [dynamic]T {
	a := make([dynamic]T, len(values), max(len(values), 8), d.allocator)
	copy(a[:], values)
	return a
}

// Reads element index of node, a field that is not a set.
// Inlined into each read_element, with and without spans: a call for every
// value costs 8% more decode instructions.
@(private = "file", require_results)
read_scalar :: #force_inline proc(d: ^Decoder, node: ^mdata.Node, index: int) -> (value: fld.Value, err: dat.Read_Error) {
	start := d.r.pos

	switch node.type {
	case .Int8:
		value, err = to_value(dat.read(&d.r, i8, node.order))
	case .UInt8:
		value, err = to_value(dat.read(&d.r, u8, node.order))
	case .Int16:
		value, err = to_value(dat.read(&d.r, i16, node.order))
	case .UInt16:
		value, err = to_value(dat.read(&d.r, u16, node.order))
	case .Int32:
		value, err = to_value(dat.read(&d.r, i32, node.order))
	case .UInt32:
		value, err = to_value(dat.read(&d.r, u32, node.order))
	case .Int64:
		value, err = to_value(dat.read(&d.r, i64, node.order))
	case .UInt64:
		value, err = to_value(dat.read(&d.r, u64, node.order))
	case .Float32:
		value, err = to_value(dat.read(&d.r, f32, node.order))
	case .Float64:
		value, err = to_value(dat.read(&d.r, f64, node.order))
	case .String:
		value = fld.Value(string(element_bytes(d, node, index) or_return))
	case .Blob:
		value = fld.Value(element_bytes(d, node, index) or_return)
	case .Set:
		panic("read_scalar: called for a set")
	case .Bool, .Bits:
		value, err = read_bit_type(d, node)
	}

	if err != .None do return nil, fail(d, err, start)
	return value, .None
}

// Reads the bytes of element index of node, a String or Blob, or of the
// substream of instance index of a Set: those of its length, without the
// pad_right at their end and cut at its terminator, or else those up to
// its terminator.
@(private = "file", require_results)
element_bytes :: #force_inline proc(d: ^Decoder, node: ^mdata.Node, index: int) -> (bytes: []byte, err: dat.Read_Error) {
	start := d.r.pos
	if node.length == nil {
		t := node.terminator.?
		bytes, err = dat.read_bytes_term(&d.r, t.value, t.include, t.consume, t.eos_error)
		if err != .None do return nil, fail(d, err, start)
		return
	}

	n: int
	n, err = byte_length(d, node.length, index)
	if err != .None do return nil, fail(d, err, start)
	bytes, err = dat.read_bytes(&d.r, n)
	if err != .None do return nil, fail(d, err, start)
	if node.pad_right != nil || node.terminator != nil do bytes = trim_bytes(node, bytes)
	return
}

// bytes without node's pad_right at their end, and cut at its terminator.
@(private = "file")
trim_bytes :: proc(node: ^mdata.Node, bytes: []byte) -> []byte {
	bytes := bytes
	if pad, padded := node.pad_right.?; padded {
		for len(bytes) > 0 && bytes[len(bytes) - 1] == pad do bytes = bytes[:len(bytes) - 1]
	}
	if t, terminated := node.terminator.?; terminated {
		if i, found := slice.linear_search(bytes, t.value); found do bytes = bytes[:i + int(t.include)]
	}
	return bytes
}

// Reads an element of node, a bit type.
@(private = "file", require_results)
read_bit_type :: proc(d: ^Decoder, node: ^mdata.Node) -> (value: fld.Value, err: dat.Read_Error) {
	bits := dat.read_bits(&d.r, int(node.width), node.order) or_return
	if node.type == .Bool do return bits != 0, .None
	#partial switch mdata.bits_type(int(node.width)) {
	case .UInt8:
		return u8(bits), .None
	case .UInt16:
		return u16(bits), .None
	case .UInt32:
		return u32(bits), .None
	}
	return bits, .None
}

@(private = "file", require_results)
to_value :: proc(v: $T, err: dat.Read_Error) -> (fld.Value, dat.Read_Error) {
	return fld.Value(v), err
}
