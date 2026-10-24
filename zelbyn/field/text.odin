package field

import "core:fmt"
import "core:io"
import "core:unicode/utf8"

// Number of leading bytes write_value shows for a blob.
BLOB_PREVIEW :: 16

// Writes one scalar as the text dump shows it: integers in decimal, floats
// with %v, strings with %q, booleans as true or false, and a blob as "<N
// bytes>" followed by its first BLOB_PREVIEW bytes in hex and " ..." if
// there are more. With string_preview above 0, a string of more characters
// shows its first string_preview, followed by " ...". Anything else (a set,
// an array or nil) is .Unsupported.
@(require_results)
write_value :: proc(w: io.Writer, v: Value, string_preview := 0) -> io.Error {
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
		if string_preview > 0 && utf8.rune_count_in_string(x) > string_preview {
			end := 0
			for _ in 0 ..< string_preview {
				_, width := utf8.decode_rune_in_string(x[end:])
				end += width
			}
			io.write_quoted_string(w, x[:end]) or_return
			io.write_string(w, " ...") or_return
		} else {
			io.write_quoted_string(w, x) or_return
		}
	case []byte:
		io.write_byte(w, '<') or_return
		io.write_int(w, len(x)) or_return
		io.write_string(w, " bytes>") or_return
		digits := "0123456789abcdef"
		for b in x[:min(len(x), BLOB_PREVIEW)] {
			io.write_byte(w, ' ') or_return
			io.write_byte(w, digits[b >> 4]) or_return
			io.write_byte(w, digits[b & 0xf]) or_return
		}
		if len(x) > BLOB_PREVIEW do io.write_string(w, " ...") or_return
	case bool:
		io.write_string(w, x ? "true" : "false") or_return
	case ^Instance, []Value:
		return .Unsupported
	case:
		return .Unsupported
	}
	return .None
}

@(private = "file", require_results)
write_float :: proc(w: io.Writer, f: $T) -> io.Error {
	buf: [64]byte
	_, err := io.write_string(w, fmt.bprintf(buf[:], "%v", f))
	return err
}
