package data

import "core:fmt"
import "core:io"
import "core:strings"
import "core:unicode/utf8"

// How the text dump writes each value, which error messages show too
// (Parse_Error.value and expected): integers in decimal, floats with %v,
// strings with %q, booleans as true or false, and a blob as "<N bytes>"
// followed by its first BLOB_PREVIEW bytes in hex and " ..." if there are
// more.

// Number of leading bytes write_blob shows.
BLOB_PREVIEW :: 16

@(require_results)
write_int :: proc(w: io.Writer, x: i64) -> io.Error {
	_, err := io.write_i64(w, x)
	return err
}

@(require_results)
write_uint :: proc(w: io.Writer, x: u64) -> io.Error {
	_, err := io.write_u64(w, x)
	return err
}

// An f4 with the fewest digits that give it, which are not those of the
// f8 it widens to.
@(require_results)
write_f32 :: proc(w: io.Writer, f: f32) -> io.Error {
	buf: [64]byte
	_, err := io.write_string(w, fmt.bprintf(buf[:], "%v", f))
	return err
}

@(require_results)
write_f64 :: proc(w: io.Writer, f: f64) -> io.Error {
	buf: [64]byte
	_, err := io.write_string(w, fmt.bprintf(buf[:], "%v", f))
	return err
}

@(require_results)
write_bool :: proc(w: io.Writer, b: bool) -> io.Error {
	_, err := io.write_string(w, b ? "true" : "false")
	return err
}

// With string_preview above 0, a string of more characters shows its first
// string_preview, followed by " ...".
@(require_results)
write_string :: proc(w: io.Writer, s: string, string_preview := 0) -> io.Error {
	if string_preview > 0 && utf8.rune_count_in_string(s) > string_preview {
		end := 0
		for _ in 0 ..< string_preview {
			_, width := utf8.decode_rune_in_string(s[end:])
			end += width
		}
		io.write_quoted_string(w, s[:end]) or_return
		_, err := io.write_string(w, " ...")
		return err
	}
	_, err := io.write_quoted_string(w, s)
	return err
}

@(require_results)
write_blob :: proc(w: io.Writer, b: []byte) -> io.Error {
	io.write_byte(w, '<') or_return
	io.write_int(w, len(b)) or_return
	io.write_string(w, " bytes>") or_return
	digits := "0123456789abcdef"
	for x in b[:min(len(b), BLOB_PREVIEW)] {
		io.write_byte(w, ' ') or_return
		io.write_byte(w, digits[x >> 4]) or_return
		io.write_byte(w, digits[x & 0xf]) or_return
	}
	if len(b) > BLOB_PREVIEW do io.write_string(w, " ...") or_return
	return .None
}

// Appends v to b as a Parse_Error shows a value it read or expected, as the
// text dump writes it, a string shortened to STRING_PREVIEW characters
// (Parse_Error.value and expected).
show_int :: proc(b: ^strings.Builder, x: i64) {
	_ = write_int(strings.to_writer(b), x)
}

show_uint :: proc(b: ^strings.Builder, x: u64) {
	_ = write_uint(strings.to_writer(b), x)
}

// An Int of an expression: as an i64, or above max(int), a u64.
show_wide :: proc(b: ^strings.Builder, n: i128) {
	if n > i128(max(i64)) {
		show_uint(b, u64(n))
	} else {
		show_int(b, i64(n))
	}
}

show_f32 :: proc(b: ^strings.Builder, f: f32) {
	_ = write_f32(strings.to_writer(b), f)
}

show_f64 :: proc(b: ^strings.Builder, f: f64) {
	_ = write_f64(strings.to_writer(b), f)
}

show_bool :: proc(b: ^strings.Builder, x: bool) {
	_ = write_bool(strings.to_writer(b), x)
}

show_string :: proc(b: ^strings.Builder, s: string) {
	_ = write_string(strings.to_writer(b), s, STRING_PREVIEW)
}

show_blob :: proc(b: ^strings.Builder, x: []byte) {
	_ = write_blob(strings.to_writer(b), x)
}

// Sets path, which holds the path of a set instance in its first n bytes,
// to that of value i of its field called name, as the text dump writes it:
// Name[i].Name[i]... (format_path).
dump_path :: proc(path: ^strings.Builder, n: int, name: string, i: int) {
	resize(&path.buf, n)
	if n > 0 do strings.write_byte(path, '.')
	strings.write_string(path, name)
	strings.write_byte(path, '[')
	strings.write_int(path, i)
	strings.write_byte(path, ']')
}

// Writes the start of the text dump's line of a value: its path and " = ".
@(require_results)
write_dump_start :: proc(w: io.Writer, path: ^strings.Builder) -> io.Error {
	io.write_string(w, strings.to_string(path^)) or_return
	_, err := io.write_string(w, " = ")
	return err
}
