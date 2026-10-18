package reader

import dat "../data"
import eval "../evaluate"
import mdata "../metadata"
import "core:mem"

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
		value, err := dat.peek_integer_at(r, r.pos + m.offset, m.type)
		if err != .None || value != m.value do return false
	}
	return true
}

// The byte length of a String or Blob element at the reader's position. A
// computed length must lie within the rule's bounds.
@(private, require_results)
byte_length :: proc(r: ^dat.Reader, length: mdata.Length, allocator: mem.Allocator) -> (n: int, err: dat.Read_Error) {
	switch l in length {
	case mdata.Fixed_Length:
		n = l.n
	case mdata.Rule_Length:
		n = eval_rule(r, l.rule, allocator) or_return
		if max_length, ok := l.max.?; ok && n > max_length do return 0, .Invalid_Length
		if min_length, ok := l.min.?; ok && n < min_length do return 0, .Invalid_Length
	}

	if n < 0 do return 0, .Invalid_Length
	return
}

// Evaluates rule at the reader's position: an optional flag (zero means the
// result is 0), then the value and, when present, its expression. Peeks never
// move the reader. Only the expression allocates, with allocator.
@(private, require_results)
eval_rule :: proc(r: ^dat.Reader, rule: mdata.Length_Rule, allocator: mem.Allocator) -> (value: int, err: dat.Read_Error) {
	if flag, has_flag := rule.flag.?; has_flag {
		flag_value := read_peek(r, flag, rule.type) or_return
		if flag_value == 0 do return 0, .None
	}

	if p, has_value := rule.value.?; has_value {
		value = read_peek(r, p, rule.type) or_return
	}

	if expression, has_expression := rule.expression.?; has_expression {
		param_map := make(map[string]int, allocator)
		defer delete(param_map)
		param_map["x"] = value
		value = eval.evaluate(expression, &param_map)
	}

	return
}

@(private = "file", require_results)
read_peek :: proc(r: ^dat.Reader, p: mdata.Peek, type: dat.Data_Type) -> (value: int, err: dat.Read_Error) {
	pos := p.absolute ? p.offset : r.pos + p.offset
	value = dat.peek_integer_at(r, pos, type) or_return

	if mask, has_mask := p.mask.?; has_mask do value &= mask

	return value >> p.shift, .None
}
