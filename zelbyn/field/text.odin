package field

import dat "../data"
import "core:io"

// Number of leading bytes write_value shows for a blob.
BLOB_PREVIEW :: dat.BLOB_PREVIEW

// Writes one scalar as the text dump shows it, with the writers of package
// data, which generated code uses too: integers in decimal, floats with %v,
// strings with %q, booleans as true or false, and a blob as "<N bytes>"
// followed by its first blob_preview bytes in hex, BLOB_PREVIEW unless
// another is given, and " ..." if there are more. With string_preview above
// 0, a string of more characters shows its first string_preview, followed
// by " ...". Anything else (a set, an array or nil) is .Unsupported.
@(require_results)
write_value :: proc(w: io.Writer, v: Value, string_preview := 0, blob_preview := BLOB_PREVIEW) -> io.Error {
	switch x in v {
	case i8:     return dat.write_int(w, i64(x))
	case i16:    return dat.write_int(w, i64(x))
	case i32:    return dat.write_int(w, i64(x))
	case i64:    return dat.write_int(w, x)
	case u8:     return dat.write_uint(w, u64(x))
	case u16:    return dat.write_uint(w, u64(x))
	case u32:    return dat.write_uint(w, u64(x))
	case u64:    return dat.write_uint(w, x)
	case f32:    return dat.write_f32(w, x)
	case f64:    return dat.write_f64(w, x)
	case string: return dat.write_string(w, x, string_preview)
	case []byte: return dat.write_blob(w, x, blob_preview)
	case bool:   return dat.write_bool(w, x)
	case ^Instance, []Value:
		return .Unsupported
	}
	return .Unsupported
}
