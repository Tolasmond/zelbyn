package dump

import fld "../field"
import mdat "../metadata"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:math"
import "core:strings"

// Number of leading bytes write_value shows for a blob.
BLOB_PREVIEW :: 16

// Writes one line per scalar in tree: its path in reader.format_path form
// (Name[i].Name[i]..., root included), " = ", then the value as write_value
// writes it. Sets get no line of their own, and empty arrays write nothing.
// Children are taken in schema order, each followed by its bit fields.
@(require_results)
write_text :: proc(w: io.Writer, format: ^mdat.File_Format, tree: ^fld.Value_Tree) -> io.Error {
	path := strings.builder_make()
	defer strings.builder_destroy(&path)

	return write_text_array(w, &path, format.root.name, set_of(format.root), tree.root[:])
}

// Writes tree as compact JSON followed by a newline. A set instance is an
// object whose keys are its field names in schema order, each followed by
// the names of its bit fields, and every field is an array:
// {"<root name>":[{...}]}. Blobs are lowercase hex strings, numbers are
// numbers, and NaN and infinities are null.
@(require_results)
write_json :: proc(w: io.Writer, format: ^mdat.File_Format, tree: ^fld.Value_Tree) -> io.Error {
	io.write_byte(w, '{') or_return
	write_json_field(w, format.root.name, set_of(format.root), tree.root[:]) or_return
	io.write_string(w, "}\n") or_return
	return .None
}

// Writes one scalar in text-dump form: integers in decimal, floats with %v,
// strings with %q, and a blob as "<N bytes>" followed by its first
// BLOB_PREVIEW bytes in hex and " ..." if there are more. Anything else (a
// set or nil) is .Unsupported.
@(require_results)
write_value :: proc(w: io.Writer, v: fld.Value) -> io.Error {
	switch x in v {
	case i8:  io.write_i64(w, i64(x)) or_return
	case i16: io.write_i64(w, i64(x)) or_return
	case i32: io.write_i64(w, i64(x)) or_return
	case i64: io.write_i64(w, x) or_return
	case u8:  io.write_u64(w, u64(x)) or_return
	case u16: io.write_u64(w, u64(x)) or_return
	case u32: io.write_u64(w, u64(x)) or_return
	case u64: io.write_u64(w, x) or_return
	case f32: write_float(w, x) or_return
	case f64: write_float(w, x) or_return
	case string:
		io.write_quoted_string(w, x) or_return
	case []byte:
		io.write_byte(w, '<') or_return
		io.write_int(w, len(x)) or_return
		io.write_string(w, " bytes>") or_return
		for b in x[:min(len(x), BLOB_PREVIEW)] {
			io.write_byte(w, ' ') or_return
			write_hex_byte(w, b) or_return
		}
		if len(x) > BLOB_PREVIEW do io.write_string(w, " ...") or_return
	case map[int][dynamic]fld.Value:
		return .Unsupported
	case:
		return .Unsupported
	}
	return .None
}

// Writes the values of the field called name. set is the field's node when
// it is a set, else nil.
@(private = "file", require_results)
write_text_array :: proc(w: io.Writer, path: ^strings.Builder, name: string, set: ^mdat.Node, values: []fld.Value) -> io.Error {
	parent_len := strings.builder_len(path^)
	defer resize(&path.buf, parent_len)

	for v, i in values {
		resize(&path.buf, parent_len)
		if parent_len > 0 do strings.write_byte(path, '.')
		strings.write_string(path, name)
		strings.write_byte(path, '[')
		strings.write_int(path, i)
		strings.write_byte(path, ']')

		if set != nil {
			set_map := v.(map[int][dynamic]fld.Value)
			for child in set.children {
				write_text_array(w, path, child.name, set_of(child), set_map[child.id][:]) or_return
				for bit in child.bits {
					write_text_array(w, path, bit.name, nil, set_map[bit.id][:]) or_return
				}
			}
		} else {
			io.write_string(w, strings.to_string(path^)) or_return
			io.write_string(w, " = ") or_return
			write_value(w, v) or_return
			io.write_byte(w, '\n') or_return
		}
	}
	return .None
}

// As for write_text_array.
@(private = "file", require_results)
write_json_array :: proc(w: io.Writer, set: ^mdat.Node, values: []fld.Value) -> io.Error {
	io.write_byte(w, '[') or_return
	for v, i in values {
		if i > 0 do io.write_byte(w, ',') or_return
		if set != nil {
			write_json_object(w, set, v.(map[int][dynamic]fld.Value)) or_return
		} else {
			write_json_scalar(w, v) or_return
		}
	}
	io.write_byte(w, ']') or_return
	return .None
}

@(private = "file", require_results)
write_json_object :: proc(w: io.Writer, node: ^mdat.Node, set_map: map[int][dynamic]fld.Value) -> io.Error {
	io.write_byte(w, '{') or_return
	for child, i in node.children {
		if i > 0 do io.write_byte(w, ',') or_return
		write_json_field(w, child.name, set_of(child), set_map[child.id][:]) or_return
		for bit in child.bits {
			io.write_byte(w, ',') or_return
			write_json_field(w, bit.name, nil, set_map[bit.id][:]) or_return
		}
	}
	io.write_byte(w, '}') or_return
	return .None
}

@(private = "file", require_results)
write_json_field :: proc(w: io.Writer, name: string, set: ^mdat.Node, values: []fld.Value) -> io.Error {
	write_json_string(w, name) or_return
	io.write_byte(w, ':') or_return
	return write_json_array(w, set, values)
}

// node when it is a set, else nil.
@(private = "file")
set_of :: proc(node: ^mdat.Node) -> ^mdat.Node {
	return node.type == .Set ? node : nil
}

@(private = "file", require_results)
write_json_scalar :: proc(w: io.Writer, v: fld.Value) -> io.Error {
	#partial switch x in v {
	case f32:
		if math.is_nan(x) || math.is_inf(x) do return write_null(w)
	case f64:
		if math.is_nan(x) || math.is_inf(x) do return write_null(w)
	case string:
		return write_json_string(w, x)
	case []byte:
		io.write_byte(w, '"') or_return
		for b in x do write_hex_byte(w, b) or_return
		io.write_byte(w, '"') or_return
		return .None
	}
	// integers and finite floats read the same in both forms
	return write_value(w, v)
}

@(private = "file", require_results)
write_json_string :: proc(w: io.Writer, s: string) -> io.Error {
	opt: json.Marshal_Options
	switch e in json.marshal_to_writer(w, s, &opt) {
	case io.Error:
		return e
	case json.Marshal_Data_Error:
		return .Unknown // a string always marshals
	}
	return .None
}

@(private = "file", require_results)
write_null :: proc(w: io.Writer) -> io.Error {
	_, err := io.write_string(w, "null")
	return err
}

@(private = "file", require_results)
write_float :: proc(w: io.Writer, f: $T) -> io.Error {
	buf: [64]byte
	_, err := io.write_string(w, fmt.bprintf(buf[:], "%v", f))
	return err
}

@(private = "file", require_results)
write_hex_byte :: proc(w: io.Writer, b: byte) -> io.Error {
	digits := "0123456789abcdef"
	io.write_byte(w, digits[b >> 4]) or_return
	return io.write_byte(w, digits[b & 0xf])
}
