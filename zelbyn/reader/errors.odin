package reader

import arn "../arena"
import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:mem"
import "core:os"
import "core:strings"

Parse_Error :: struct {
	kind:     dat.Read_Error,
	offset:   int,      // in the input: where the failing read started, or the reader position for peeks and computed lengths
	path:     string,   // owned (context.allocator); "" on success; free with destroy_parse_error
	os_error: os.Error, // set only when kind == .File_Read_Failed
	// When a check fails (Not_Equal, Less_Than_Min, Greater_Than_Max,
	// Not_Any_Of, Not_In_Enum, Expr_False), the value read, and what the
	// check expected, as field.write_value writes them, a string shortened to
	// STRING_PREVIEW characters: the constant (Not_Equal), the bound
	// (Less_Than_Min, Greater_Than_Max), or the values allowed, separated by
	// ", ", the first LIST_PREVIEW followed by ", ..." when there are more
	// (Not_Any_Of, Not_In_Enum). Each is "" when there is none to show: the
	// value of a set, what an Expr_False expected, and for any other error.
	// Owned, as path is.
	value:    string,
	expected: string,
}

// The characters of a string, and the values of a list, that a Parse_Error
// shows.
STRING_PREVIEW :: 64
LIST_PREVIEW :: 16

Path_Segment :: struct {
	name:  string, // borrowed from the plan
	index: int,
}

@(private)
Decoder :: struct {
	r:           dat.Reader,      // the stream being read: the input, or a substream of it
	base:        int,             // the offset in the input of r.data[0]
	arena:       ^arn.Arena,      // the value tree's; the decoder allocates its values here directly
	allocator:   mem.Allocator,   // the same arena, for path, frames, streams and the maps, bounded by its limit too (push_record)
	path:        [dynamic]Path_Segment,
	frames:      [dynamic]Frame,  // the set instances being decoded, outermost first
	streams:     [dynamic]Stream, // the streams that substreams were taken from, outermost first, as they are now
	kept:        map[^fld.Instance]Stream, // the streams of the instances of sets with keeps_stream, in the same arena; nil until one is read
	cache:       map[Cached]Kept_Value, // the values of the cached value instances evaluated, in the same arena; nil until one is
	stack_start: uintptr,         // the address of a local of decode, where the stack that decoding uses starts (stack_used)
	pending:     [dynamic]Pending, // the parse instances to read once the root is (read_pending), in the same arena
	pending_at:  map[Pending_Key]int, // the index in pending of each, made when an expression first reads one (read_kept); nil until then
	spans:       bool,            // the tree records spans: read_parse_instance is called with SPANS
	args:        []fld.Value,     // the arguments of the params of the root's set (Root_Arg)
	steps_left:  int,             // the steps the decode may still take (Limits.max_steps), below 0 once it took too many
	nesting:     int,             // the parse instances being read, each inside the one before (MAX_INSTANCE_DEPTH)
	err:         Parse_Error,
}

// A set instance being decoded, and where: its stream is streams[stream],
// or r when stream is len(streams); path[:path] is its path; set is the set
// it is read as, whose parse instances are read into it; parent is the
// index of the frame of its _parent, the frame before it unless its field
// has a parent (Node.parent_up), and -1 for the root. Only while a parse
// instance of it is read from another stream (Node.io) is the stream of the
// innermost frame not r.
@(private)
Frame :: struct {
	instance: ^fld.Instance,
	stream:   int,
	path:     int,
	set:      ^mdata.Node,
	parent:   int,
}

// A parse instance that no expression had read when the fields of its set
// instance were, read once the whole input is, as Kaitai's runtimes read
// an instance when it is first used: with the frames, streams and path of
// that instance, and its stream, as they were then.
@(private)
Pending :: struct {
	instance: ^fld.Instance,
	node:     ^mdata.Node,
	k:        int,
	frames:   [dynamic]Frame,
	streams:  [dynamic]Stream,
	path:     [dynamic]Path_Segment,
	r:        dat.Reader,
	base:     int,
}

// A cached value instance (Value_Instance.cached) of a set instance.
@(private)
Cached :: struct {
	instance: ^fld.Instance,
	value:    ^mdata.Value_Instance,
}

// The value a cached value instance keeps (eval_kept): value, or when it is
// the values of a field, the slot that holds them, which the decoder updates
// as the field grows; slot is nil otherwise.
@(private)
Kept_Value :: struct {
	value: Eval_Value,
	slot:  ^[]fld.Value,
}

// Parse instance k of instance.
@(private)
Pending_Key :: struct {
	instance: ^fld.Instance,
	k:        int,
}

@(private)
Stream :: struct {
	r:    dat.Reader,
	base: int,
}

// Records the first error with the current path; always returns kind.
// offset is in the stream being read.
@(private)
fail :: proc(d: ^Decoder, kind: dat.Read_Error, offset: int) -> dat.Read_Error {
	if d.err.kind == .None {
		d.err.kind = kind
		d.err.offset = d.base + offset
		d.err.path = format_path(d.path[:])
	}
	return kind
}

// Joins segments as "Name[index].Name[index]...".
format_path :: proc(segments: []Path_Segment, allocator := context.allocator) -> string {
	if len(segments) == 0 do return ""

	b := strings.builder_make(allocator)
	for segment, i in segments {
		if i > 0 do strings.write_byte(&b, '.')
		strings.write_string(&b, segment.name)
		strings.write_byte(&b, '[')
		strings.write_int(&b, segment.index)
		strings.write_byte(&b, ']')
	}
	return strings.to_string(b)
}

destroy_parse_error :: proc(err: ^Parse_Error) {
	delete(err.path)
	delete(err.value)
	delete(err.expected)
	err.path, err.value, err.expected = "", "", ""
}
