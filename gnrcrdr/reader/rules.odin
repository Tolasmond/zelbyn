package reader

import dat "../data"
import mdata "../metadata"

// Validates a set count: negative counts are invalid, and counts above max
// (when present) exceed the repeat limit.
@(require_results)
check_count :: proc(count: int, max: Maybe(int)) -> dat.Read_Error {
	if count < 0 do return .Invalid_Length

	if max_count, ok := max.?; ok && count > max_count {
		return .Repeat_Limit_Exceeded
	}

	return .None
}

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

// The byte length of element index of a String or Blob field. A computed
// length must lie within the rule's bounds.
@(private, require_results)
byte_length :: proc(d: ^Decoder, length: mdata.Length, index: int) -> (n: int, err: dat.Read_Error) {
	switch l in length {
	case mdata.Fixed_Length:
		n = l.n
	case mdata.Rule_Length:
		n = eval_int(d, l.expr, index) or_return
		if max_length, ok := l.max.?; ok && n > max_length do return 0, .Invalid_Length
		if min_length, ok := l.min.?; ok && n < min_length do return 0, .Invalid_Length
	}

	if n < 0 do return 0, .Invalid_Length
	return
}
