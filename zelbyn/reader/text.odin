package reader

import dat "../data"
import mdata "../metadata"

// The text of a string in encoding, bytes, as UTF-8 in the tree's arena,
// as data.decode_text decodes it, for generated code too. Not inlined: it
// is called only for strings in encodings that are decoded. Fails with
// Memory_Limit when the tree's arena has no room for the text.
@(private, require_results)
decode_text :: #force_no_inline proc(d: ^Decoder, bytes: []byte, encoding: mdata.Encoding) -> (string, dat.Read_Error) {
	return dat.decode_text(bytes, encoding, d.allocator)
}
