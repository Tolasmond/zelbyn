package reader

import dat "../data"
import mdata "../metadata"
import "core:os"
import "core:strings"

Parse_Error :: struct {
	kind:     dat.Read_Error,
	offset:   int,      // where the failing read started, or the reader position for peeks and computed lengths
	path:     string,   // owned (context.allocator); "" on success; free with destroy_parse_error
	os_error: os.Error, // set only when kind == .File_Read_Failed
}

Path_Segment :: struct {
	name:  string, // borrowed from metadata
	index: int,
}

@(private)
Decoder :: struct {
	r:        dat.Reader,
	metadata: ^mdata.Field_Metadata_Provider,
	path:     [dynamic]Path_Segment,
	err:      Parse_Error,
}

// Records the first error with the current path; always returns kind.
@(private)
fail :: proc(d: ^Decoder, kind: dat.Read_Error, offset: int) -> dat.Read_Error {
	if d.err.kind == .None {
		d.err.kind = kind
		d.err.offset = offset
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
