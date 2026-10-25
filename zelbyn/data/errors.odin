package data

import "core:os"
import "core:strings"

// A decode's error, as the decoder (package reader) and generated code
// (package codegen) report it.
Parse_Error :: struct {
	kind:     Read_Error,
	offset:   int,      // in the input: where the failing read started, or the reader position for peeks and computed lengths
	path:     string,   // owned (context.allocator); "" on success; free with destroy_parse_error
	os_error: os.Error, // set only when kind == .File_Read_Failed
	// When a check fails (Not_Equal, Less_Than_Min, Greater_Than_Max,
	// Not_Any_Of, Not_In_Enum, Expr_False), the value read, and what the
	// check expected, as the text dump writes a value (write_string and
	// the other writers of values.odin), a string shortened to
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

// One step of a path: the field read (its name in the dumps, borrowed) and
// the index of its element.
Path_Segment :: struct {
	name:  string,
	index: int,
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

// Starts item i of a list in b, as a Parse_Error shows one; false when it
// is past the first LIST_PREVIEW, after ", ..." for the first of those.
write_list_item :: proc(b: ^strings.Builder, i: int) -> bool {
	if i > LIST_PREVIEW do return false
	if i > 0 do strings.write_string(b, ", ")
	if i == LIST_PREVIEW {
		strings.write_string(b, "...")
		return false
	}
	return true
}
