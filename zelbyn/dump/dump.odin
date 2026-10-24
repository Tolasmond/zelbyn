package dump

import fld "../field"
import mdata "../metadata"
import "core:io"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

// Writes one line per scalar in tree: its path in reader.format_path form
// (Name[i].Name[i]..., root included), " = ", then the value as
// field.write_value writes it. Sets get no line of their own, and empty
// arrays write nothing. Children are taken in schema order, each followed
// by its bit fields, and then the parse instances; those of a switch-on
// field are those of the case each instance was read as. Value instances
// are not read, so they are not written. With offsets, which needs a tree read with spans, each
// line ends with " @0x" and the value's offset in the input, in hex.
@(require_results)
write_text :: proc(w: io.Writer, format: ^mdata.File_Format, tree: ^fld.Value_Tree, offsets := false) -> io.Error {
	assert(!offsets || tree.spans, "write_text: offsets need a tree read with spans")
	path := strings.builder_make()
	defer strings.builder_destroy(&path)

	return write_text_array(w, &path, format.root.name, set_of(format.root), tree.root[:], offsets ? tree : nil, nil, 0)
}

// Writes tree as compact JSON followed by a newline. A set instance is an
// object whose keys are its field names in schema order, each followed by
// the names of its bit fields, then the names of its parse instances, and
// every field is an array:
// {"<root name>":[{...}]}. Blobs are lowercase hex strings, numbers are
// numbers, and NaN and infinities are null.
@(require_results)
write_json :: proc(w: io.Writer, format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> io.Error {
	io.write_byte(w, '{') or_return
	write_json_field(w, format.root.name, set_of(format.root), tree.root[:]) or_return
	io.write_string(w, "}\n") or_return
	return .None
}

// Writes the values of the field called name. set is the field's node when
// it is a set, else nil. The values are slot k of owner, or the root when
// owner is nil. offsets is the tree when the lines end with offsets, else
// nil.
@(private = "file", require_results)
write_text_array :: proc(w: io.Writer, path: ^strings.Builder, name: string, set: ^mdata.Node, values: []fld.Value, offsets: ^fld.Value_Tree, owner: ^fld.Instance, k: int) -> io.Error {
	parent_len := strings.builder_len(path^)
	defer resize(&path.buf, parent_len)

	for v, i in values {
		resize(&path.buf, parent_len)
		if parent_len > 0 do strings.write_byte(path, '.')
		strings.write_string(path, name)
		strings.write_byte(path, '[')
		strings.write_int(path, i)
		strings.write_byte(path, ']')

		// a switch-on field that chose no set has its bytes instead
		if instance, is_instance := v.(^fld.Instance); is_instance {
			read_as := mdata.instance_set(set, instance)
			slot := len(read_as.parse_instances)
			for child in read_as.children {
				write_text_array(w, path, child.name, set_of(child), instance.slots[slot][:], offsets, instance, slot) or_return
				for bit, b in child.bits {
					write_text_array(w, path, bit.name, nil, instance.slots[slot + 1 + b][:], offsets, instance, slot + 1 + b) or_return
				}
				slot += 1 + len(child.bits)
			}
			for p, j in read_as.parse_instances {
				write_text_array(w, path, p.name, set_of(p), instance.slots[j][:], offsets, instance, j) or_return
			}
		} else {
			io.write_string(w, strings.to_string(path^)) or_return
			io.write_string(w, " = ") or_return
			fld.write_value(w, v) or_return
			if offsets != nil {
				span := owner == nil ? fld.root_span(offsets, i) : fld.value_span(owner, k, i)
				io.write_string(w, " @0x") or_return
				write_hex_int(w, span.offset) or_return
			}
			io.write_byte(w, '\n') or_return
		}
	}
	return .None
}

// As for write_text_array.
@(private = "file", require_results)
write_json_array :: proc(w: io.Writer, set: ^mdata.Node, values: []fld.Value) -> io.Error {
	io.write_byte(w, '[') or_return
	for v, i in values {
		if i > 0 do io.write_byte(w, ',') or_return
		if instance, is_instance := v.(^fld.Instance); is_instance {
			write_json_object(w, set, instance) or_return
		} else {
			write_json_scalar(w, v) or_return
		}
	}
	io.write_byte(w, ']') or_return
	return .None
}

@(private = "file", require_results)
write_json_object :: proc(w: io.Writer, node: ^mdata.Node, instance: ^fld.Instance) -> io.Error {
	io.write_byte(w, '{') or_return
	read_as := mdata.instance_set(node, instance)
	slot := len(read_as.parse_instances)
	for child, i in read_as.children {
		if i > 0 do io.write_byte(w, ',') or_return
		write_json_field(w, child.name, set_of(child), instance.slots[slot][:]) or_return
		for bit, b in child.bits {
			io.write_byte(w, ',') or_return
			write_json_field(w, bit.name, nil, instance.slots[slot + 1 + b][:]) or_return
		}
		slot += 1 + len(child.bits)
	}
	for p, k in read_as.parse_instances {
		if k > 0 || len(read_as.children) > 0 do io.write_byte(w, ',') or_return
		write_json_field(w, p.name, set_of(p), instance.slots[k][:]) or_return
	}
	io.write_byte(w, '}') or_return
	return .None
}

@(private = "file", require_results)
write_json_field :: proc(w: io.Writer, name: string, set: ^mdata.Node, values: []fld.Value) -> io.Error {
	write_json_string(w, name) or_return
	io.write_byte(w, ':') or_return
	return write_json_array(w, set, values)
}

// node when it is a set, else nil.
@(private = "file")
set_of :: proc(node: ^mdata.Node) -> ^mdata.Node {
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
		write_hex(w, x) or_return
		io.write_byte(w, '"') or_return
		return .None
	}
	// integers and finite floats read the same in both forms
	return fld.write_value(w, v)
}

// Writes bytes as lowercase hex, a chunk at a time: one write per byte
// costs more than encoding.
@(private = "file", require_results)
write_hex :: proc(w: io.Writer, bytes: []byte) -> io.Error {
	digits := "0123456789abcdef"
	buf: [1024]byte
	for rest := bytes; len(rest) > 0; {
		chunk := rest[:min(len(rest), len(buf) / 2)]
		for b, i in chunk {
			buf[2 * i] = digits[b >> 4]
			buf[2 * i + 1] = digits[b & 0xf]
		}
		io.write(w, buf[:2 * len(chunk)]) or_return
		rest = rest[len(chunk):]
	}
	return .None
}

// Writes s as a JSON string, escaping characters as json.marshal does. A
// byte that is not part of valid UTF-8 is written \u00NN, the character of
// the same value (json.marshal writes \xNN, which is not JSON), so the
// output is always valid JSON.
@(private = "file", require_results)
write_json_string :: proc(w: io.Writer, s: string) -> io.Error {
	// printable ASCII other than " and \ needs no escape, so it is written
	// as it is
	plain := true
	for i in 0 ..< len(s) {
		if s[i] < 0x20 || s[i] > 0x7e || s[i] == '"' || s[i] == '\\' {
			plain = false
			break
		}
	}
	if plain {
		io.write_byte(w, '"') or_return
		io.write_string(w, s) or_return
		return io.write_byte(w, '"')
	}

	io.write_byte(w, '"') or_return
	for rest := s; len(rest) > 0; {
		r, width := utf8.decode_rune_in_string(rest)
		if r == utf8.RUNE_ERROR && width == 1 {
			io.write_string(w, `\u00`) or_return
			write_hex_byte(w, rest[0]) or_return
		} else {
			io.write_escaped_rune(w, r, '"', for_json = true) or_return
		}
		rest = rest[width:]
	}
	return io.write_byte(w, '"')
}

@(private = "file", require_results)
write_null :: proc(w: io.Writer) -> io.Error {
	_, err := io.write_string(w, "null")
	return err
}

// Writes n, which is not negative, in uppercase hex without leading zeros.
@(private = "file", require_results)
write_hex_int :: proc(w: io.Writer, n: int) -> io.Error {
	digits := "0123456789ABCDEF"
	buf: [16]byte
	i := len(buf)
	for x := u64(n); i == len(buf) || x > 0; x >>= 4 {
		i -= 1
		buf[i] = digits[x & 0xf]
	}
	_, err := io.write(w, buf[i:])
	return err
}

@(private = "file", require_results)
write_hex_byte :: proc(w: io.Writer, b: byte) -> io.Error {
	digits := "0123456789abcdef"
	io.write_byte(w, digits[b >> 4]) or_return
	return io.write_byte(w, digits[b & 0xf])
}
