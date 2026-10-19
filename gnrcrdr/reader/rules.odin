package reader

import dat "../data"
import mdata "../metadata"

// Reports whether every marker matches the input at the reader's position. A
// marker that cannot be peeked (e.g. past EOF) does not match.
@(private)
markers_match :: proc(r: ^dat.Reader, markers: []mdata.Marker) -> bool {
	for m in markers {
		value, err := dat.peek_integer_at(r, r.pos + m.offset, m.type, m.order)
		if err != .None || value != m.value do return false
	}
	return true
}

// The byte length of element index of a String or Blob field, or of the
// substream of instance index of a Set.
@(private, require_results)
byte_length :: proc(d: ^Decoder, length: mdata.Length, index: int) -> (n: int, err: dat.Read_Error) {
	switch l in length {
	case mdata.Fixed_Length:
		n = l.n
	case mdata.Rule_Length:
		n = eval_int(d, l.expr, index) or_return
	case mdata.Eos_Length:
		n = len(d.r.data) - d.r.pos
	}

	if n < 0 do return 0, .Invalid_Length
	return
}
