package reader

import arn "../arena"
import dat "../data"
import fld "../field"
import mdata "../metadata"
import "base:runtime"
import bts "core:bytes"
import "core:compress/zlib"
import "core:os"
import "core:slice"

// What a decode may take, so that every input either decodes or fails with
// the limit it reached, Memory_Limit or Step_Limit, at the offset and path
// where it did. Each is 0 for no limit; start from DEFAULT_LIMITS to
// change one.
//
// max_memory is the bytes the tree's arena may hold, beyond the input read
// puts in it: every value, instance, array, string made or decoded, and
// what process: zlib decompresses, and the decoder's own records (its
// path, frames, maps and the parse instances it keeps). An allocation
// never takes the arena past it.
//
// max_steps is the steps a decode may take: one for each element of a
// field, set instance and parse instance read, value instance evaluated,
// and item of an array an expression makes, converts or searches.
Limits :: struct {
	max_memory: int,
	max_steps:  int,
}

// The limits read and read_from_bytes take when not given others.
// max_memory is some 300 times the largest tree of a sample of the corpus
// (3.3 MB), and max_steps some 3 seconds of the elements of GIF files,
// read with gif.ksy at about 40 million a second (doc/arch.md, "Limits").
DEFAULT_LIMITS :: Limits {
	max_memory = 1 << 30,
	max_steps  = 100_000_000,
}

// Reads the file name into tree's arena, closes it, and decodes it into
// tree, which must be zero or destroyed. Strings and blobs are views of that
// copy, or for a string in an encoding that is decoded, in the arena too,
// so the tree owns its input: it needs neither the file nor the
// schema once read returns. With spans, the tree records the span of each
// value (field.value_span), which costs memory and time. args are the
// arguments of the params of the schema's top-level type, one of each
// param's type: an i64 for an integer type, a bool, []byte for bytes or a
// string for str, which the tree copies, or for a user type, []byte, read
// as an instance of it in a stream of their own; else Invalid_Arguments.
// limits bound the decode (Limits).
@(require_results)
read :: proc(name: string, format: ^mdata.File_Format, tree: ^fld.Value_Tree, spans := false, args: []fld.Value = nil, limits := DEFAULT_LIMITS) -> (consumed: int, err: Parse_Error) {
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
	return decode(data, format, tree, spans, args, limits)
}

// Decodes data into tree, which must be zero or destroyed. Strings and
// blobs are views of data, which the tree borrows, but for strings in an
// encoding that is decoded, which are in the tree's arena: keep data alive and
// unchanged for as long as the tree is used. The tree references nothing
// in the schema. spans and args are as for read.
@(require_results)
read_from_bytes :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree, spans := false, args: []fld.Value = nil, limits := DEFAULT_LIMITS) -> (consumed: int, err: Parse_Error) {
	assert(tree.arena.block == nil && tree.root == nil, "read_from_bytes: tree must be zero or destroyed")
	init_arena(tree, len(data))
	return decode(data, format, tree, spans, args, limits)
}

// args, the arguments of the params of params, copied into the tree's
// arena; Invalid_Arguments unless there is one of each param's type, bytes
// for a param of a user type (read_root_arg).
@(private = "file", require_results)
root_args :: proc(d: ^Decoder, params: []^mdata.Node, args: []fld.Value) -> (copied: []fld.Value, err: dat.Read_Error) {
	if len(args) != len(params) do return nil, .Invalid_Arguments
	copied = tree_make(d, fld.Value, len(args)) or_return
	for p, k in params {
		#partial switch p.type {
		case .Int64:
			if _, ok := args[k].(i64); !ok do return nil, .Invalid_Arguments
			copied[k] = args[k]
		case .Bool:
			if _, ok := args[k].(bool); !ok do return nil, .Invalid_Arguments
			copied[k] = args[k]
		case .Blob, .Set:
			v, ok := args[k].([]byte)
			if !ok do return nil, .Invalid_Arguments
			b := tree_make(d, byte, len(v)) or_return
			copy(b, v)
			copied[k] = b
		case .String:
			v, ok := args[k].(string)
			if !ok do return nil, .Invalid_Arguments
			b := tree_make(d, byte, len(v)) or_return
			copy(b, v)
			copied[k] = string(b)
		case:
			return nil, .Invalid_Arguments
		}
	}
	return copied, .None
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
decode :: proc(data: []byte, format: ^mdata.File_Format, tree: ^fld.Value_Tree, spans: bool, args: []fld.Value, limits: Limits) -> (consumed: int, err: Parse_Error) {
	// the decoder's own records, which max_memory bounds too
	allocator := arn.arena_allocator(&tree.arena)
	tree.spans = spans
	// beyond the input, which read put in the arena
	if limits.max_memory > 0 do arn.arena_set_limit(&tree.arena, arn.arena_used(&tree.arena) + uint(limits.max_memory))

	d := Decoder{arena = &tree.arena, allocator = allocator, spans = spans}
	d.steps_left = limits.max_steps > 0 ? limits.max_steps : max(int)
	d.stack_start = uintptr(&d)
	d.path = make([dynamic]Path_Segment, allocator)
	d.frames = make([dynamic]Frame, allocator)
	d.streams = make([dynamic]Stream, allocator)
	dat.reader_init(&d.r, data)
	if params := format.root.params; len(params) > 0 || len(args) > 0 {
		args_err: dat.Read_Error
		d.args, args_err = root_args(&d, params, args)
		if args_err != .None do return 0, Parse_Error{kind = args_err}
		for p, k in params {
			if p.type != .Set do continue
			set := format.root.args[k].variant.(mdata.Root_Arg).set
			rerr := spans ? read_root_arg(&d, set, k, true) : read_root_arg(&d, set, k, false)
			if rerr != .None {
				if d.err.kind == .None do fail(&d, rerr, d.r.pos)
				return 0, d.err
			}
		}
	}

	root := Sink{slots = ([^][]fld.Value)(&tree.root)[:1]}
	rerr := spans ? read_values(&d, &root, format.root, true) : read_values(&d, &root, format.root, false)
	consumed = d.r.pos
	if rerr == .None {
		rerr = spans ? read_pending(&d, true) : read_pending(&d, false)
	}
	if rerr != .None && d.err.kind == .None {
		fail(&d, rerr, d.r.pos)
	}
	return consumed, d.err
}

// Reads the bytes of d.args[k], the argument of a param of a user type of
// the root, in a stream of their own, as an instance of set, which becomes
// the argument, as the caller of Kaitai's runtimes makes one from bytes.
@(private = "file", require_results)
read_root_arg :: proc(d: ^Decoder, set: ^mdata.Node, k: int, $SPANS: bool) -> dat.Read_Error {
	r := d.r
	defer d.r = r
	dat.reader_init(&d.r, d.args[k].([]byte))
	value: []fld.Value
	sink := Sink{slots = ([^][]fld.Value)(&value)[:1]}
	read_values(d, &sink, set, SPANS) or_return
	d.args[k] = value[0]
	return .None
}

// Reads the parse instances that no expression had read when their set
// instances were (Pending), in the order those were read, and any that
// reading them leaves, once the root is read.
@(private = "file", require_results)
read_pending :: proc(d: ^Decoder, $SPANS: bool) -> dat.Read_Error {
	for i := 0; i < len(d.pending); i += 1 {
		p := d.pending[i]
		// an expression may have read it since
		if raw_data(p.instance.slots[p.k]) != nil do continue
		d.frames, d.streams, d.path = p.frames, p.streams, p.path
		d.r, d.base = p.r, p.base
		read_parse_instance(d, p.instance, p.node, p.k, SPANS) or_return
	}
	return .None
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
@(private = "file", require_results)
make_values :: #force_inline proc(d: ^Decoder, n: int, $SPANS: bool) -> (values: []fld.Value, err: dat.Read_Error) {
	when SPANS {
		#assert(size_of(fld.Span) % size_of(rawptr) == 0 && size_of(fld.Value) % size_of(rawptr) == 0)
		SPAN_WORDS :: size_of(fld.Span) / size_of(rawptr)
		VALUE_WORDS :: size_of(fld.Value) / size_of(rawptr)
		if n <= 0 do return nil, .None
		if n > max(int) / (SPAN_WORDS + VALUE_WORDS) do return nil, .Memory_Limit
		words := raw_data(tree_make(d, rawptr, n * (SPAN_WORDS + VALUE_WORDS)) or_return)
		return ([^]fld.Value)(&words[n * SPAN_WORDS])[:n], .None
	} else {
		return tree_make(d, fld.Value, n)
	}
}

// Makes room for n values in each slot of s, which must be empty: the cells
// when n is at most 1, else an array of exactly n.
@(private = "file", require_results)
reserve_exactly :: proc(d: ^Decoder, s: ^Sink, n: int, $SPANS: bool) -> dat.Read_Error {
	for &slot, k in s.slots {
		if n <= 1 && s.cells != nil {
			slot = s.cells[k:k]
		} else {
			values := make_values(d, n, SPANS) or_return
			slot = values[:0]
		}
	}
	s.cap = n
	return .None
}

// Makes room for at least n values in each slot of s, doubling, for a count
// that is not known in advance. The repeats ask for one more than a slot
// holds before each element, which adds at most one value to each: an
// element that adds none, of a switch-on that no case chooses, takes no
// room.
@(private = "file", require_results)
reserve_growing :: proc(d: ^Decoder, s: ^Sink, n: int, $SPANS: bool) -> dat.Read_Error {
	if n <= s.cap do return .None
	s.cap = max(8, 2 * s.cap, n)
	for &slot in s.slots {
		grown := make_values(d, s.cap, SPANS) or_return
		copy(grown, slot)
		when SPANS {
			if len(slot) > 0 do copy(([^]fld.Span)(fld.array_span(grown, len(slot) - 1))[:len(slot)], ([^]fld.Span)(fld.array_span(slot, len(slot) - 1))[:len(slot)])
		}
		slot = grown[:len(slot)]
	}
	return .None
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
		pos := stream.r.pos
		if err == .None && !node.at_stream_pos do pos, err = eval_int(d, node.pos)
		if err == .None && (pos < 0 || pos > len(stream.r.data)) do err = .Offset_Out_Of_Range
		if err != .None {
			append(&d.path, Path_Segment{node.name, 0})
			return fail(d, err, d.r.pos)
		}
		if node.io != nil {
			// the instance's stream stays its frame's, for _io in the rest
			// of node's expressions; read_parse_instance puts the streams
			// back
			push_record(d, &d.streams, Stream{d.r, d.base}) or_return
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
		if err != .None do return fail(d, err, d.r.pos)
		// a negative count reads no elements, as in Kaitai's runtimes
		count = max(n, 0)
	case mdata.Marker_Count:
		count = markers_match(&d.r, c.markers) ? 1 : 0
	case mdata.Repeat_Count:
		return read_repeat(d, s, node, c, SPANS)
	case mdata.Eos_Count:
		for i := 0; !dat.at_eof(&d.r); i += 1 {
			start, start_bits := d.r.pos, dat.bit_pos(&d.r)
			reserve_growing(d, s, len(s.slots[0]) + 1, SPANS) or_return
			read_element(d, s, node, i, SPANS) or_return
			if dat.bit_pos(&d.r) == start_bits do return no_progress(d, node, i, start)
		}
		return .None
	case mdata.Until_Count:
		// read is the count of elements read once element i is
		for read := 1;; read += 1 {
			i := read - 1
			start, start_bits := d.r.pos, dat.bit_pos(&d.r)
			reserve_growing(d, s, len(s.slots[0]) + 1, SPANS) or_return
			n := len(s.slots[0])
			read_element(d, s, node, i, SPANS) or_return

			// _ is the element just read; an element of a switch-on that chose
			// no case added none, and _ then has no value. _index is the count
			// of elements read, as the official compiler's JavaScript, C++ and
			// Java increment it before the test; its Python tests first
			values := s.slots[0]
			done: bool
			err: dat.Read_Error
			if len(values) > n {
				done, err = eval_bool(d, c.expr, read, values[n])
			} else {
				done, err = eval_bool(d, c.expr, read, nil)
			}
			if err != .None do return fail(d, err, d.r.pos)
			if done do return .None

			if dat.bit_pos(&d.r) == start_bits do return no_progress(d, node, i, start)
		}
	}

	// elements that consume input cannot outnumber the bytes left, so a
	// larger count, which may come from the input, grows as it is read
	if count <= 1 || count <= len(d.r.data) - d.r.pos {
		reserve_exactly(d, s, count, SPANS) or_return
		for i in 0 ..< count {
			read_element(d, s, node, i, SPANS) or_return
		}
	} else {
		for i in 0 ..< count {
			reserve_growing(d, s, len(s.slots[0]) + 1, SPANS) or_return
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
		reserve_growing(d, s, n + 1, SPANS) or_return
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
	push_record(d, &d.path, Path_Segment{node.name, index}) or_return
	start := d.r.pos
	d.steps_left -= 1
	if d.steps_left < 0 do return fail(d, .Step_Limit, start)

	if node.type == .Set {
		n := len(s.slots[0])
		read_instance(d, s, node, index, SPANS) or_return
		// a switch-on that chooses no case adds no value, so in a repeat the
		// elements before may have added fewer values than index
		read := len(s.slots[0]) > n
		when SPANS do if read do set_span(d, s, 0, start)
		if node.valid != nil && read {
			if e := check_valid(d, s.slots[0][n], node.valid, index); e != .None do return fail_check(d, e, start, s.slots[0][n], node.valid, index)
		}
		pop(&d.path)
		return .None
	}

	value := read_scalar(d, node, index) or_return
	push(s, 0, value)
	when SPANS do set_span(d, s, 0, start)
	if node.valid != nil {
		if e := check_valid(d, value, node.valid, index); e != .None do return fail_check(d, e, start, value, node.valid, index)
	}
	pop(&d.path)

	for bit, b in node.bits {
		bit_value := bit_field_value(value, bit)
		push(s, 1 + b, bit_value)
		when SPANS do set_span(d, s, 1 + b, start)

		if bit.valid != nil {
			if e := check_constant(bit_value, bit.valid); e != .None {
				append(&d.path, Path_Segment{bit.name, index})
				return fail_check(d, e, start, bit_value, bit.valid, index)
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
			// a Bool is chosen by its value as 0 or 1, an Int by its value in
			// full, which can be above max(int)
			on: i128
			err: dat.Read_Error
			if sw.on.type == .Bool {
				b: bool
				b, err = eval_bool(d, sw.on, index)
				on = i128(int(b))
			} else {
				on, err = eval_wide(d, sw.on, index)
			}
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
	push_record(d, &d.streams, Stream{d.r, d.base}) or_return
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
	if node.process != .None do bytes = process_bytes(d, bytes, start) or_return
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
	args = tree_make(d, fld.Value, len(set.args)) or_return
	for a, k in set.args {
		v, e := eval_value(d, a, index)
		if e != .None do return nil, fail(d, e, d.r.pos)
		args[k] = v
	}
	return args, .None
}

// The deepest that set instances nest, as frames. Only a recursive type
// can nest them deeper than CHECK_DEPTH, and an input can then nest them
// as deeply as it likes, which would overflow the stack. Decoding a level
// takes about 1.1 KB of it, and writing it 1.3 KB (2.7 KB each in a debug
// build), so MAX_DEPTH levels fit in the 1 MB of the main thread's stack
// on Windows.
MAX_DEPTH :: 256

// The most stack that decoding uses before an instance is Too_Deep, which
// bounds what frames do not count: read_parse_instance sets aside the
// frames above the instance's while it reads, and a parse instance read
// from an expression has the evaluator's frames below it, which take
// several times what a level takes otherwise (6.6 KB, and 20 KB in a debug
// build, for the instance in an if). Instances read that way can reach it
// in fewer than MAX_DEPTH levels. It is checked in each parse instance, and
// in each set instance deeper than CHECK_DEPTH, so the stack grows at most
// CHECK_DEPTH levels past it.
MAX_STACK :: 768 * 1024

// The frames below which the depth and the stack are not checked: deeper
// than formats without recursive types nest, so that they pay one test.
CHECK_DEPTH :: 32

// Appends one instance of set node to s, read as choice (see
// field.Instance), with the values of its params, args, and reads its
// children into it, and keeps the parse instances that no expression has
// read, to be read once the root is (keep_pending). An instance nested
// deeper than MAX_DEPTH is Too_Deep, and so is one read below CHECK_DEPTH
// frames once decoding has used MAX_STACK.
@(private = "file", require_results)
read_set_instance :: proc(d: ^Decoder, s: ^Sink, node: ^mdata.Node, choice: int, args: []fld.Value, $SPANS: bool) -> dat.Read_Error {
	when ODIN_DEBUG {
		assert(node.slot_count == mdata.count_slots(node), "read_set_instance: the set's slot_count was not recorded")
	}
	if len(d.frames) >= CHECK_DEPTH && (len(d.frames) >= MAX_DEPTH || stack_used(d) > MAX_STACK) do return fail(d, .Too_Deep, d.r.pos)

	node := node
	instance, cells, alloc_err := fld.make_instance(d.arena, node.slot_count, choice, SPANS)
	if alloc_err != nil do return .Memory_Limit
	push(s, 0, instance)
	for v, k in args {
		slot := mdata.param_slot(node, k)
		cells[slot] = v
		instance.slots[slot] = cells[slot:][:1]
	}

	// on error the frame is left pushed, like the path segment
	parent := len(d.frames) - 1
	for _ in 0 ..< node.parent_up do parent = d.frames[parent].parent
	push_record(d, &d.frames, Frame{instance, len(d.streams), len(d.path), node, parent}) or_return
	if node.order_switch != nil do node = choose_order(d, node) or_return

	slot := len(node.parse_instances)
	for child in node.children {
		n := 1 + len(child.bits)
		child_sink := Sink{slots = instance.slots[slot:][:n], cells = cells[slot:][:n]}
		read_values(d, &child_sink, child, SPANS) or_return
		slot += n
	}

	for p, k in node.parse_instances {
		if raw_data(instance.slots[k]) == nil do keep_pending(d, instance, p, k) or_return
	}
	if node.keeps_stream do keep_stream(d, instance) or_return

	pop(&d.frames)
	return .None
}

// The set of node, a set with an Order_Switch, to read the instance of the
// innermost frame as: node, compiled little-endian, or its big-endian set,
// which the frame then records. Not inlined: only types whose endian is a
// switch-on call it.
@(private = "file", require_results)
choose_order :: #force_no_inline proc(d: ^Decoder, node: ^mdata.Node) -> (set: ^mdata.Node, err: dat.Read_Error) {
	sw := node.order_switch
	order, decided := sw.default.?
	for c in sw.cases {
		is, test_err := eval_bool(d, c.test)
		if test_err != .None do return nil, fail(d, test_err, d.r.pos)
		if is {
			order, decided = c.order, true
			break
		}
	}
	if !decided do return nil, fail(d, .Undecided_Endianness, d.r.pos)
	if order == .Little do return node, .None
	d.frames[len(d.frames) - 1].set = sw.big
	return sw.big, .None
}

// Keeps parse instance node of instance, in slot k, which no expression
// has read, to be read once the root is (read_pending). Not inlined: it is
// called only for the sets that have parse instances.
@(private = "file", require_results)
keep_pending :: #force_no_inline proc(d: ^Decoder, instance: ^fld.Instance, node: ^mdata.Node, k: int) -> dat.Read_Error {
	if d.pending == nil do d.pending = make([dynamic]Pending, d.allocator)
	frames := clone_dynamic(d, d.frames[:]) or_return
	streams := clone_dynamic(d, d.streams[:]) or_return
	path := clone_dynamic(d, d.path[:]) or_return
	push_record(d, &d.pending, Pending{instance, node, k, frames, streams, path, d.r, d.base}) or_return
	if d.pending_at != nil && map_insert(&d.pending_at, Pending_Key{instance, k}, len(d.pending) - 1) == nil do return fail(d, .Memory_Limit, d.r.pos)
	return .None
}

// Reads parse instance node of instance, in slot k, for an expression,
// once instance is no longer decoded: as read_pending reads it, with the
// frames, streams, path and stream it was kept with, which are then put
// back as they were. The index of the kept instances is made the first
// time, so that a format whose expressions read none pays nothing for it.
@(private = "file", require_results)
read_kept :: #force_no_inline proc(d: ^Decoder, instance: ^fld.Instance, node: ^mdata.Node, k: int, $SPANS: bool) -> dat.Read_Error {
	if d.pending_at == nil {
		alloc_err: runtime.Allocator_Error
		d.pending_at, alloc_err = make(map[Pending_Key]int, max(len(d.pending), 16), d.allocator)
		if alloc_err != nil do return fail(d, .Memory_Limit, d.r.pos)
		for p, i in d.pending {
			if map_insert(&d.pending_at, Pending_Key{p.instance, p.k}, i) == nil do return fail(d, .Memory_Limit, d.r.pos)
		}
	}
	i, kept := d.pending_at[{instance, k}]
	// an instance that has been read keeps the parse instances it did not
	// read (keep_pending)
	assert(kept, "read_kept: the parse instance was not kept")
	p := d.pending[i]
	frames, streams, path, r, base := d.frames, d.streams, d.path, d.r, d.base
	d.frames, d.streams, d.path, d.r, d.base = p.frames, p.streams, p.path, p.r, p.base
	err := read_parse_instance(d, instance, node, k, SPANS)
	d.frames, d.streams, d.path, d.r, d.base = frames, streams, path, r, base
	return err
}

// The bytes of stack used since decoding started, by the frame this is
// inlined into: the stack grows down on every platform Odin targets.
@(private)
stack_used :: #force_inline proc(d: ^Decoder) -> int {
	marker: byte
	return int(d.stack_start - uintptr(&marker))
}

// Records the stream of instance, which has been read, for an io
// expression or a value instance that refers to it once it is no longer
// decoded (stream_of). Not inlined: inlining it into
// read_set_instance costs 0.5% more decode instructions.
@(private = "file", require_results)
keep_stream :: #force_no_inline proc(d: ^Decoder, instance: ^fld.Instance) -> dat.Read_Error {
	if d.kept == nil do d.kept = make(map[^fld.Instance]Stream, d.allocator)
	if map_insert(&d.kept, instance, Stream{d.r, d.base}) == nil do return fail(d, .Memory_Limit, d.r.pos)
	return .None
}

// Reads parse instance node of instance into slot k: at its pos in the
// instance's stream, as the instance's frame sees it, or in the stream of
// its io; for an instance no longer decoded, as it was kept (read_kept). The stream, frames and path are then
// put back as they were. It is Too_Deep once decoding has used MAX_STACK.
@(private, require_results)
read_parse_instance :: proc(d: ^Decoder, instance: ^fld.Instance, node: ^mdata.Node, k: int, $SPANS: bool) -> dat.Read_Error {
	node := node
	if stack_used(d) > MAX_STACK {
		append(&d.path, Path_Segment{node.name, 0})
		return fail(d, .Too_Deep, d.r.pos)
	}
	j := len(d.frames) - 1
	for j >= 0 && d.frames[j].instance != instance do j -= 1
	if j < 0 do return read_kept(d, instance, node, k, SPANS)
	frame := d.frames[j]
	// as the set the instance was read as has it: an expression compiled
	// outside a type whose endian is a switch-on refers to the parse
	// instances of its little-endian sets, also for an instance of one of
	// the big-endian ones (Order_Switch)
	node = frame.set.parse_instances[k]

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
		aside_frames := clone_dynamic(d, frames[:j + 1]) or_return
		aside_streams := clone_dynamic(d, streams[:frame.stream]) or_return
		aside_path := clone_dynamic(d, path[:frame.path]) or_return
		d.frames, d.streams, d.path = aside_frames, aside_streams, aside_path
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

// A copy of values, in the tree's arena, to append to; Memory_Limit when
// the arena has no room for it.
@(private = "file", require_results)
clone_dynamic :: proc(d: ^Decoder, values: []$T) -> (copied: [dynamic]T, err: dat.Read_Error) {
	alloc_err: runtime.Allocator_Error
	copied, alloc_err = make([dynamic]T, len(values), max(len(values), 8), d.allocator)
	if alloc_err != nil do return nil, fail(d, .Memory_Limit, d.r.pos)
	copy(copied[:], values)
	return copied, .None
}

// Appends v to records, one of the decoder's own (Decoder.allocator);
// Memory_Limit when the arena has no room for it.
@(private, require_results)
push_record :: #force_inline proc(d: ^Decoder, records: ^[dynamic]$T, v: T) -> dat.Read_Error {
	if _, err := append(records, v); err != nil do return no_room(d)
	return .None
}

// Fails with Memory_Limit, for push_record. Not inlined, so that each
// append, one for every element read, stays small.
@(private = "file")
no_room :: #force_no_inline proc(d: ^Decoder) -> dat.Read_Error {
	return fail(d, .Memory_Limit, d.r.pos)
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
		bytes := element_bytes(d, node, index) or_return
		if node.encoding == .None {
			value = string(bytes)
		} else {
			value = fld.Value(decode_text(d, bytes, node.encoding) or_return)
		}
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
		if node.process != .None do return process_bytes(d, bytes, start)
		return
	}

	n: int
	n, err = byte_length(d, node.length, index)
	if err != .None do return nil, fail(d, err, start)
	bytes, err = dat.read_bytes(&d.r, n)
	if err != .None do return nil, fail(d, err, start)
	if node.pad_right != nil || node.terminator != nil do bytes = trim_bytes(node, bytes)
	if node.process != .None do return process_bytes(d, bytes, start)
	return
}

// The bytes of an element with process: zlib, read at start, decompressed
// into the tree's arena, which also holds what decompressing allocates.
// Not inlined: only fields with process call it.
@(private = "file", require_results)
process_bytes :: #force_no_inline proc(d: ^Decoder, raw: []byte, start: int) -> (processed: []byte, err: dat.Read_Error) {
	// what inflating allocates is bounded by Limits.max_memory, which ends
	// a stream that decompresses to more than it allows
	recorder := Failure_Recorder{allocator = arn.arena_allocator(d.arena)}
	allocator := runtime.Allocator{failure_recorder_proc, &recorder}
	buf: bts.Buffer
	bts.buffer_init_allocator(&buf, 0, max(4 * len(raw), 64), allocator)
	inflate_err: zlib.Error
	{
		context.allocator = allocator
		context.temp_allocator = allocator
		inflate_err = zlib.inflate(raw, &buf)
	}
	// the error's path is in the context's allocator; inflate reports some
	// allocations that fail as another error
	if _, out_of_memory := inflate_err.(runtime.Allocator_Error); out_of_memory || recorder.failed do return nil, fail(d, .Memory_Limit, start)
	if inflate_err != nil do return nil, fail(d, .Decompression_Failed, start)
	return bts.buffer_to_bytes(&buf), .None
}

// An allocator, as process_bytes gives inflate the tree's arena, that
// records whether an allocation through it failed for want of memory.
@(private = "file")
Failure_Recorder :: struct {
	allocator: runtime.Allocator,
	failed:    bool,
}

@(private = "file")
failure_recorder_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	data: []byte,
	err: runtime.Allocator_Error,
) {
	r := (^Failure_Recorder)(allocator_data)
	data, err = r.allocator.procedure(r.allocator.data, mode, size, alignment, old_memory, old_size, loc)
	if err == .Out_Of_Memory do r.failed = true
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
