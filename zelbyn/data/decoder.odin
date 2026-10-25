package data

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"
import "core:mem/virtual"
import "core:strings"

// The state of a decode by code that package codegen generates, which
// follows the decoder's (package reader, doc/arch.md, "Decoding") step for
// step, so that a schema and an input decode to the same values, or fail
// with the same error at the same offset and path, in both: the stream
// being read and the offset in the input of its first byte, the path, the
// set instances being decoded (frames) and the streams that substreams were
// taken from, as the decoder keeps them, and the parse instances to read
// once the root is. Set instances are the structs generated code declares,
// each starting with a Header, known here by their address alone.
//
// Unlike the decoder, it has no limits on nesting, memory or steps. Its own
// records are allocated in an arena of its own, which decoder_destroy
// frees; the values that generated code reads and makes are allocated with
// context.allocator.
Decoder :: struct {
	r:          Reader,
	base:       int,
	path:       [dynamic]Path_Segment,
	frames:     [dynamic]Frame,
	streams:    [dynamic]Stream,
	kept:       map[rawptr]Stream,   // the streams of the instances of sets that keep theirs, once each is read
	cache:      map[Cached]rawptr,   // the value of each cached value instance evaluated, for its instance
	pending:    [dynamic]Pending,
	pending_at: map[Pending_Key]int, // the index in pending of each, made when an expression first reads one
	err:        Parse_Error,
	records:    virtual.Arena,
	allocator:  runtime.Allocator,   // records'
}

// The first member of every struct that generated code declares, which the
// decoder reads through an instance's address.
Header :: struct {
	set:    int, // the set the instance was read as, as generated code numbers them
	choice: int, // for an instance of a switch-on field, the index of the case it was read as, or DEFAULT_CASE
}

// Header.choice of the _ case of a switch-on field.
DEFAULT_CASE :: -1

// A set instance being decoded, as the decoder's Frame: its stream is
// streams[stream], or r when stream is len(streams); path[:path] is its
// path; set is the set it is read as; parent is the index of the frame of
// its _parent, and -1 for the root.
Frame :: struct {
	instance: rawptr,
	stream:   int,
	path:     int,
	set:      int,
	parent:   int,
}

Stream :: struct {
	r:    Reader,
	base: int,
}

// Reads parse instance k of instance, which generated code declares, as set,
// in the stream the decoder has made the current one.
Parse_Proc :: #type proc(d: ^Decoder, instance: rawptr, k: int, set: int) -> Read_Error

// A parse instance that no expression had read when the fields of its set
// instance were, read once the whole input is (read_pending), with the
// frames, streams and path of that instance, and its stream, as they were
// then. done and mask are the bit that records that it has been read, in
// the instance.
Pending :: struct {
	instance: rawptr,
	k:        int,
	read:     Parse_Proc,
	io:       bool,
	done:     ^u64,
	mask:     u64,
	frames:   [dynamic]Frame,
	streams:  [dynamic]Stream,
	path:     [dynamic]Path_Segment,
	r:        Reader,
	base:     int,
}

Pending_Key :: struct {
	instance: rawptr,
	k:        int,
}

// Value instance id, as generated code numbers them, of instance.
Cached :: struct {
	instance: rawptr,
	id:       int,
}

// What _index and _ are, and the instance whose value instance is being
// evaluated, as the decoder's Eval_Context: index is -1 when an expression
// is not evaluated for an element of a repeat, element the address of _
// (nil when it has no value, or outside repeat-until and valid), and self
// nil outside a value instance. In a value instance, base finds the
// instances enclosing self, from the expression that gave self, in the
// context caller (ancestor).
Eval_Context :: struct {
	index:   int,
	element: rawptr,
	self:    rawptr,
	base:    Enclosing_Proc,
	caller:  ^Eval_Context,
}

// The instance up levels above the one that an expression, evaluated in
// ctx, gives (reader's enclosing).
Enclosing_Proc :: #type proc(d: ^Decoder, ctx: ^Eval_Context, up: int) -> (rawptr, Read_Error)

// Starts a decode of data, a view of which every string and byte array
// read is.
decoder_init :: proc(d: ^Decoder, data: []byte) {
	d^ = {}
	if virtual.arena_init_growing(&d.records) != nil do panic("decoder_init: no memory for the decoder's records")
	d.allocator = virtual.arena_allocator(&d.records)
	d.path = make([dynamic]Path_Segment, d.allocator)
	d.frames = make([dynamic]Frame, d.allocator)
	d.streams = make([dynamic]Stream, d.allocator)
	reader_init(&d.r, data)
}

// Frees the decoder's records; the error and the values read are the
// caller's.
decoder_destroy :: proc(d: ^Decoder) {
	virtual.arena_destroy(&d.records)
}

// Records the first error with the current path; always returns kind.
// offset is in the stream being read.
fail :: proc(d: ^Decoder, kind: Read_Error, offset: int) -> Read_Error {
	if d.err.kind == .None {
		d.err.kind = kind
		d.err.offset = d.base + offset
		d.err.path = format_path(d.path[:])
	}
	return kind
}

// Whether kind is a check's failure, which a Parse_Error shows the value
// and the expected values of.
is_check_error :: proc(kind: Read_Error) -> bool {
	#partial switch kind {
	case .Not_Equal, .Less_Than_Min, .Greater_Than_Max, .Not_Any_Of, .Not_In_Enum, .Expr_False:
		return true
	}
	return false
}

// Records kind, a check's failure, with what it read and what it expected,
// each as a Parse_Error shows them, as the decoder's fail_check does once
// it has built expected. Returns kind.
fail_check :: proc(d: ^Decoder, kind: Read_Error, offset: int, read, expected: string) -> Read_Error {
	fail(d, kind, offset)
	d.err.value = read
	d.err.expected = expected
	return kind
}

// Appends v to records, one of the decoder's own.
@(require_results)
push_record :: proc(d: ^Decoder, records: ^[dynamic]$T, v: T) -> Read_Error {
	if _, err := append(records, v); err != nil do return fail(d, .Memory_Limit, d.r.pos)
	return .None
}

// Pushes a segment of the path, for element index of the field called name.
@(require_results)
push_path :: #force_inline proc(d: ^Decoder, name: string, index: int) -> Read_Error {
	return push_record(d, &d.path, Path_Segment{name, index})
}

pop_path :: #force_inline proc(d: ^Decoder) {
	pop(&d.path)
}

// The index of the frame of the _parent of an instance read now whose field
// has a parent of up levels (0 without one).
parent_frame :: proc(d: ^Decoder, up: int) -> int {
	parent := len(d.frames) - 1
	for _ in 0 ..< up do parent = d.frames[parent].parent
	return parent
}

// Pushes the frame of instance, read as set, whose _parent's frame is
// parent.
@(require_results)
push_frame :: proc(d: ^Decoder, instance: rawptr, set: int, parent: int) -> Read_Error {
	return push_record(d, &d.frames, Frame{instance, len(d.streams), len(d.path), set, parent})
}

pop_frame :: proc(d: ^Decoder) {
	pop(&d.frames)
}

// Records that the innermost frame's instance is read as set instead
// (an endian switch-on that chose its big-endian set).
set_frame_set :: proc(d: ^Decoder, set: int) {
	d.frames[len(d.frames) - 1].set = set
	(^Header)(d.frames[len(d.frames) - 1].instance).set = set
}

// Makes bytes, read from the current stream at start, the current stream,
// as the substream of an instance; pop_stream puts the stream back.
@(require_results)
push_substream :: proc(d: ^Decoder, bytes: []byte, start: int) -> Read_Error {
	push_record(d, &d.streams, Stream{d.r, d.base}) or_return
	reader_init(&d.r, bytes)
	d.base += start
	return .None
}

// Makes stream the current one, keeping the one before as the stream of
// the innermost frame (a parse instance with io).
@(require_results)
push_stream :: proc(d: ^Decoder, stream: Stream) -> Read_Error {
	push_record(d, &d.streams, Stream{d.r, d.base}) or_return
	d.r, d.base = stream.r, stream.base
	return .None
}

pop_stream :: proc(d: ^Decoder) {
	parent := pop(&d.streams)
	d.r = parent.r
	d.base = parent.base
}

// The instance _root is: the outermost frame's.
root_instance :: proc(d: ^Decoder) -> (rawptr, Read_Error) {
	if len(d.frames) == 0 do return nil, .Absent_Field
	return d.frames[0].instance, .None
}

// The instance up levels above that of ctx (_parent is 1), as the decoder's
// ancestor finds it: from the frames, each of which has its _parent's, or
// in a value instance, through ctx.base.
ancestor :: proc(d: ^Decoder, ctx: ^Eval_Context, up: int) -> (rawptr, Read_Error) {
	if ctx.self == nil {
		i := len(d.frames) - 1
		for _ in 0 ..< up {
			if i < 0 do break
			i = d.frames[i].parent
		}
		if i < 0 do return nil, .Absent_Field
		return d.frames[i].instance, .None
	}
	if up == 0 do return ctx.self, .None
	return ctx.base(d, ctx.caller, up)
}

// The instance being decoded of set, the top-level type of an imported
// schema, or of big, its big-endian set (-1 for none): the frame read as
// either, at any depth.
imported_root :: proc(d: ^Decoder, set, big: int) -> (rawptr, Read_Error) {
	for f in d.frames {
		if f.set == set || (big >= 0 && f.set == big) do return f.instance, .None
	}
	return nil, .Absent_Field
}

// The stream that _io refers to in an expression of instance, or of the
// set instance being decoded when instance is nil, as the decoder's
// stream_of gives it: that of its frame, or once it is no longer decoded,
// the stream kept for it (keep_stream).
stream_of :: proc(d: ^Decoder, instance: rawptr) -> ^Reader {
	#reverse for f in d.frames {
		if instance != nil && f.instance != instance do continue
		if f.stream < len(d.streams) do return &d.streams[f.stream].r
		return &d.r
	}
	if instance == nil do return &d.r
	kept, ok := &d.kept[instance]
	assert(ok, "stream_of: the stream of the instance was not kept")
	return &kept.r
}

// The stream of instance, as an io expression (X._io) gives it, which a
// parse instance is read from: a copy, which reading does not move.
stream_value :: proc(d: ^Decoder, instance: rawptr) -> Stream {
	#reverse for f in d.frames {
		if f.instance != instance do continue
		if f.stream < len(d.streams) do return d.streams[f.stream]
		return {d.r, d.base}
	}
	kept, ok := d.kept[instance]
	assert(ok, "stream_value: the stream of the instance was not kept")
	return kept
}

// The current stream, as _io in the set instance being decoded gives it to
// an io expression.
current_stream :: proc(d: ^Decoder) -> Stream {
	return {d.r, d.base}
}

// Records the stream of instance, which has been read, for an expression
// that refers to it once it is no longer decoded (stream_of).
@(require_results)
keep_stream :: proc(d: ^Decoder, instance: rawptr) -> Read_Error {
	if d.kept == nil do d.kept = make(map[rawptr]Stream, d.allocator)
	if map_insert(&d.kept, instance, Stream{d.r, d.base}) == nil do return fail(d, .Memory_Limit, d.r.pos)
	return .None
}

// A copy of values in the decoder's records, to append to.
@(require_results)
clone_records :: proc(d: ^Decoder, values: []$T) -> (copied: [dynamic]T, err: Read_Error) {
	alloc_err: runtime.Allocator_Error
	copied, alloc_err = make([dynamic]T, len(values), max(len(values), 8), d.allocator)
	if alloc_err != nil do return nil, fail(d, .Memory_Limit, d.r.pos)
	copy(copied[:], values)
	return copied, .None
}

// Keeps parse instance k of instance, which no expression has read, to be
// read once the root is (read_pending). io is whether it has io; done and
// mask the bit that records that it is read.
@(require_results)
keep_pending :: proc(d: ^Decoder, instance: rawptr, k: int, read: Parse_Proc, io: bool, done: ^u64, mask: u64) -> Read_Error {
	if d.pending == nil do d.pending = make([dynamic]Pending, d.allocator)
	frames := clone_records(d, d.frames[:]) or_return
	streams := clone_records(d, d.streams[:]) or_return
	path := clone_records(d, d.path[:]) or_return
	push_record(d, &d.pending, Pending{instance, k, read, io, done, mask, frames, streams, path, d.r, d.base}) or_return
	if d.pending_at != nil && map_insert(&d.pending_at, Pending_Key{instance, k}, len(d.pending) - 1) == nil do return fail(d, .Memory_Limit, d.r.pos)
	return .None
}

// Reads the parse instances that no expression had read when their set
// instances were, in the order those were read, and any that reading them
// leaves, once the root is read.
@(require_results)
read_pending :: proc(d: ^Decoder) -> Read_Error {
	for i := 0; i < len(d.pending); i += 1 {
		p := d.pending[i]
		// an expression may have read it since
		if p.done^ & p.mask != 0 do continue
		d.frames, d.streams, d.path = p.frames, p.streams, p.path
		d.r, d.base = p.r, p.base
		read_parse_instance(d, p.instance, p.k, p.read, p.io) or_return
	}
	return .None
}

// Reads parse instance k of instance, which has io when io is set, with
// read: at its pos in the instance's stream, as the instance's frame sees
// it, or once the instance is no longer decoded, as it was kept
// (keep_pending). The stream, frames and path are then put back as they
// were, as the decoder's read_parse_instance does.
@(require_results)
read_parse_instance :: proc(d: ^Decoder, instance: rawptr, k: int, read: Parse_Proc, io: bool) -> Read_Error {
	j := len(d.frames) - 1
	for j >= 0 && d.frames[j].instance != instance do j -= 1
	if j < 0 do return read_kept(d, instance, k, read, io)
	frame := d.frames[j]

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
	aside := j < len(frames) - 1 || frame.stream < len(streams) || frame.path < len(path) || io
	if aside {
		aside_frames := clone_records(d, frames[:j + 1]) or_return
		aside_streams := clone_records(d, streams[:frame.stream]) or_return
		aside_path := clone_records(d, path[:frame.path]) or_return
		d.frames, d.streams, d.path = aside_frames, aside_streams, aside_path
	}

	err := read(d, instance, k, frame.set)
	if aside {
		d.frames = frames
		d.streams = streams
		d.path = path
	}
	return err
}

// Reads parse instance k of instance, once instance is no longer decoded,
// as read_pending reads it, with the frames, streams, path and stream it was
// kept with, which are then put back as they were.
@(private = "file", require_results)
read_kept :: proc(d: ^Decoder, instance: rawptr, k: int, read: Parse_Proc, io: bool) -> Read_Error {
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
	err := read_parse_instance(d, instance, k, read, io)
	d.frames, d.streams, d.path, d.r, d.base = frames, streams, path, r, base
	return err
}

// The value that value instance id has kept for instance, nil when it has
// none yet.
cached :: proc(d: ^Decoder, instance: rawptr, id: int) -> rawptr {
	if d.cache == nil do return nil
	return d.cache[Cached{instance, id}]
}

// Keeps value, the value of value instance id for instance, which a copy
// of is made in the decoder's records, to give it from now on (cached).
@(require_results)
keep_cached :: proc(d: ^Decoder, instance: rawptr, id: int, value: $T) -> Read_Error {
	if d.cache == nil do d.cache = make(map[Cached]rawptr, d.allocator)
	cell, err := new(T, d.allocator)
	if err != nil do return .Memory_Limit
	cell^ = value
	if map_insert(&d.cache, Cached{instance, id}, rawptr(cell)) == nil do return .Memory_Limit
	return .None
}

// The value of an Array expression: the values of a field, or of an array
// literal or a conversion, all of one kind. A field's (array_of) is its
// storage, so that it is the field's values as they grow, as the decoder
// keeps a field's slot; any other is its items, made for it.
Array :: struct {
	kind:  Array_Kind,
	items: rawptr,
	len:   int,
	slot:  ^runtime.Raw_Dynamic_Array, // a field's [dynamic] storage; nil for any other
}

// The type of an Array's items: those of a field's values, Int (i128) and
// Float (f64) of an expression's, Struct an instance's address, and Array
// an array literal's.
Array_Kind :: enum u8 {
	I8,
	I16,
	I32,
	I64,
	U8,
	U16,
	U32,
	U64,
	F32,
	F64,
	Int,
	Bool,
	Bytes,
	String,
	Struct,
	Array,
}

// The values of a field, as they are now and as they grow.
array_of :: proc(slot: ^[dynamic]$E) -> Array {
	return {kind = array_kind(E), slot = (^runtime.Raw_Dynamic_Array)(slot)}
}

// An array of items, made by an expression.
array_from :: proc(items: []$E) -> Array {
	return {kind = array_kind(E), items = raw_data(items), len = len(items)}
}

// The Array_Kind of items of type E.
array_kind :: proc($E: typeid) -> Array_Kind {
	when E == i8 {
		return .I8
	} else when E == i16 {
		return .I16
	} else when E == i32 {
		return .I32
	} else when E == i64 {
		return .I64
	} else when E == u8 {
		return .U8
	} else when E == u16 {
		return .U16
	} else when E == u32 {
		return .U32
	} else when E == u64 {
		return .U64
	} else when E == f32 {
		return .F32
	} else when E == f64 {
		return .F64
	} else when E == i128 {
		return .Int
	} else when E == bool {
		return .Bool
	} else when E == []byte {
		return .Bytes
	} else when E == string {
		return .String
	} else when E == Array {
		return .Array
	} else {
		#assert(intrinsics.type_is_pointer(E), "array_kind: not an item type")
		return .Struct
	}
}

// The items of a and how many there are.
@(private = "file")
array_items :: #force_inline proc(a: Array) -> (rawptr, int) {
	if a.slot != nil do return a.slot.data, a.slot.len
	return a.items, a.len
}

array_len :: proc(a: Array) -> int {
	_, n := array_items(a)
	return n
}

// Item i of a, an index that an expression gives: Index_Out_Of_Range
// outside a, also above max(int).
@(private = "file", require_results)
array_item :: proc(a: Array, i: i128, $T: typeid) -> (T, Read_Error) {
	items, n := array_items(a)
	if i < 0 || i >= i128(n) do return {}, .Index_Out_Of_Range
	return ([^]T)(items)[int(i)], .None
}

// Item i of a, an array of integers, as an Int.
@(require_results)
array_int :: proc(a: Array, i: i128) -> (n: i128, err: Read_Error) {
	#partial switch a.kind {
	case .I8:  return i128(array_item(a, i, i8) or_return), .None
	case .I16: return i128(array_item(a, i, i16) or_return), .None
	case .I32: return i128(array_item(a, i, i32) or_return), .None
	case .I64: return i128(array_item(a, i, i64) or_return), .None
	case .U8:  return i128(array_item(a, i, u8) or_return), .None
	case .U16: return i128(array_item(a, i, u16) or_return), .None
	case .U32: return i128(array_item(a, i, u32) or_return), .None
	case .U64: return i128(array_item(a, i, u64) or_return), .None
	case .Int: return array_item(a, i, i128)
	}
	panic("array_int: not an array of integers")
}

// Item i of a, an array of floats, as a Float.
@(require_results)
array_float :: proc(a: Array, i: i128) -> (f: f64, err: Read_Error) {
	#partial switch a.kind {
	case .F32: return f64(array_item(a, i, f32) or_return), .None
	case .F64: return array_item(a, i, f64)
	}
	panic("array_float: not an array of floats")
}

@(require_results)
array_bool :: proc(a: Array, i: i128) -> (bool, Read_Error) {
	assert(a.kind == .Bool)
	return array_item(a, i, bool)
}

@(require_results)
array_bytes :: proc(a: Array, i: i128) -> ([]byte, Read_Error) {
	assert(a.kind == .Bytes)
	return array_item(a, i, []byte)
}

@(require_results)
array_string :: proc(a: Array, i: i128) -> (string, Read_Error) {
	assert(a.kind == .String)
	return array_item(a, i, string)
}

// Item i of a, an array of instances, as the address of one.
@(require_results)
array_struct :: proc(a: Array, i: i128) -> (rawptr, Read_Error) {
	assert(a.kind == .Struct)
	return array_item(a, i, rawptr)
}

@(require_results)
array_array :: proc(a: Array, i: i128) -> (Array, Read_Error) {
	assert(a.kind == .Array)
	return array_item(a, i, Array)
}

// The index of the last item of a, for .last: -1 when it is empty, which
// every item of a is then Index_Out_Of_Range for.
array_last :: proc(a: Array) -> i128 {
	return i128(array_len(a)) - 1
}

// The least (max false) or greatest item of a, an array of integers, and
// Index_Out_Of_Range when it is empty (.min, .max).
@(require_results)
array_min_max :: proc(a: Array, max: bool) -> (best: i128, err: Read_Error) {
	n := array_len(a)
	if n == 0 do return 0, .Index_Out_Of_Range
	best = array_int(a, 0) or_return
	for i in 1 ..< n {
		v := array_int(a, i128(i)) or_return
		if max ? v > best : v < best do best = v
	}
	return best, .None
}

// The bytes of a, an array of integers, each of which must be within 0 to
// 255, else Integer_Overflow (.as<bytes>), allocated with allocator.
@(require_results)
array_to_bytes :: proc(a: Array, allocator: runtime.Allocator) -> (bytes: []byte, err: Read_Error) {
	n := array_len(a)
	alloc_err: runtime.Allocator_Error
	bytes, alloc_err = make([]byte, n, allocator)
	if alloc_err != nil do return nil, .Memory_Limit
	for i in 0 ..< n {
		v := array_int(a, i128(i)) or_return
		if v < 0 || v > 255 do return nil, .Integer_Overflow
		bytes[i] = byte(v)
	}
	return bytes, .None
}

// The least and greatest byte of bytes, for .min and .max: Index_Out_Of_Range
// when there are none.
@(require_results)
bytes_min_max :: proc(bytes: []byte, max: bool) -> (best: i128, err: Read_Error) {
	if len(bytes) == 0 do return 0, .Index_Out_Of_Range
	b := bytes[0]
	for x in bytes[1:] {
		if max ? x > b : x < b do b = x
	}
	return i128(b), .None
}

// Byte i of bytes, an index that an expression gives, as an Int:
// Index_Out_Of_Range outside them.
@(require_results)
bytes_item :: proc(bytes: []byte, i: i128) -> (i128, Read_Error) {
	if i < 0 || i >= i128(len(bytes)) do return 0, .Index_Out_Of_Range
	return i128(bytes[i]), .None
}

// l + r, a new string allocated with allocator.
@(require_results)
join_strings :: proc(l, r: string, allocator: runtime.Allocator) -> (string, Read_Error) {
	joined, err := strings.concatenate({l, r}, allocator)
	if err != nil do return "", .Memory_Limit
	return joined, .None
}

// The decimal digits of n, with a - when it is negative (.to_s of an Int),
// a new string allocated with allocator.
@(require_results)
int_to_string :: proc(n: i128, allocator: runtime.Allocator) -> (string, Read_Error) {
	buf: [20]byte
	s, err := strings.clone(int_digits(&buf, n), allocator)
	if err != nil do return "", .Memory_Limit
	return s, .None
}

// Whether every marker of a -peek count, an integer of type in order at
// offset from the reader's position, equals value; a marker that cannot be
// read does not.
marker_matches :: proc(r: ^Reader, offset: int, type: Data_Type, order: endian.Byte_Order, value: int) -> bool {
	v, err := peek_integer_at(r, r.pos + offset, type, order)
	return err == .None && v == value
}
