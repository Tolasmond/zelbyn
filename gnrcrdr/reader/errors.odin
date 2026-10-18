package reader

import dat "../data"
import fld "../field"
import "core:mem"
import "core:os"
import "core:strings"

Parse_Error :: struct {
	kind:     dat.Read_Error,
	offset:   int,      // in the input: where the failing read started, or the reader position for peeks and computed lengths
	path:     string,   // owned (context.allocator); "" on success; free with destroy_parse_error
	os_error: os.Error, // set only when kind == .File_Read_Failed
}

Path_Segment :: struct {
	name:  string, // borrowed from the plan
	index: int,
}

@(private)
Decoder :: struct {
	r:         dat.Reader, // the stream being read: the input, or a substream of it
	base:      int,        // the offset in the input of r.data[0]
	allocator: mem.Allocator, // the value tree's arena; also holds path
	path:      [dynamic]Path_Segment,
	frames:    [dynamic]^fld.Instance, // the set instances being decoded, outermost first; also in allocator
	err:       Parse_Error,
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
	err.path = ""
}
