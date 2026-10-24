package ksy

import dat "../data"
import expr "../expression"
import mdata "../metadata"
import yml "../yaml"
import "core:slice"
import "core:strings"

// Whether item, a scalar of a list of bytes and strings (contents, the
// peek extensions), is a byte rather than text: a plain scalar that YAML
// 1.1, as the official tools read the YAML, reads as an integer (yaml_int),
// which byte_list then requires to be one from 0 to 255.
@(private)
is_byte_item :: proc(item: ^yml.Node) -> bool {
	return item.style == .Plain && yaml_int(item.text)
}

// A byte: an integer from 0 to 255.
@(private)
byte_value :: proc(c: ^Compiler, n: ^yml.Node, id, what: string) -> (b: u8, ok: bool) {
	text := expect_scalar(c, n, what) or_return
	v, is_int := parse_int(text)
	if !is_int || n.style != .Plain || v < 0 || v > 255 do return 0, fail(c, .Invalid, n, "%s: %s must be a byte, 0 to 255, not %q", id, what, text)
	return u8(v), true
}

// A boolean: true or false.
@(private)
boolean :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (value: bool, ok: bool) {
	text := expect_scalar(c, n, what) or_return
	if n.style == .Plain {
		switch text {
		case "true":
			return true, true
		case "false":
			return false, true
		}
	}
	return false, fail(c, .Invalid, n, "%s must be true or false, not %q", what, text)
}

// contents (and the peek extensions): a string, whose UTF-8 bytes are
// meant, or a sequence of bytes (0 to 255) and strings.
@(private)
byte_list :: proc(c: ^Compiler, n: ^yml.Node, what: string) -> (bytes: []byte, ok: bool) {
	b := make([dynamic]byte, c.allocator)
	switch n.kind {
	case .Scalar:
		if n.style == .Plain && yaml_int(n.text) {
			return nil, fail(c, .Invalid, n, "%s: write a byte as a sequence, [%s]", what, n.text)
		}
		append(&b, n.text)
	case .Seq:
		for item in n.items {
			if item.kind != .Scalar do return nil, fail(c, .Invalid, item, "%s: an element must be a byte or a string", what)
			// a number, as the official tools read the YAML, is a byte; one
			// that is not written as zelbyn reads integers is an error, rather
			// than its text
			if is_byte_item(item) {
				v, status := int_scalar_value(item.text)
				if status != .Ok do return nil, fail(c, .Invalid, item, "%s: %s is an integer in YAML, which is not written as zelbyn reads one: decimal without leading zeros, 0x, 0b or 0o, with single _ between digits, to 2^64 - 1", what, item.text)
				if v < 0 || v > 255 do return nil, fail(c, .Invalid, item, "%s: %s is not a byte (0 to 255)", what, item.text)
				append(&b, byte(v))
			} else {
				append(&b, item.text)
			}
		}
	case .Map:
		return nil, fail(c, .Invalid, n, "%s must be a string or a sequence", what)
	}
	return b[:], true
}

// valid on node, an attribute or a parse instance with the enum en (nil
// when it has none), in scope: a
// constant (eq), or a mapping of eq, min and max, any-of, expr or in-enum.
// A constant is a literal of the value's type (an integer or an enum
// constant, a string literal, or a list of bytes, [0x50, 0x4b], for a
// blob), or an expression of that type; in it and in expr, _ is the
// value. The check keeps Scalars when every constant is a literal, as
// most are, and is a Valid_Expr otherwise.
@(private)
compile_valid :: proc(c: ^Compiler, n: ^yml.Node, id: string, node: ^mdata.Node, en: ^expr.Enum, scope: expr.Scope) -> (valid: mdata.Valid, ok: bool) {
	// the constants of a bit type have the type of its values
	type := node.type == .Bits ? mdata.bits_type(int(node.width)) : node.type
	scope := scope
	scope.element = node
	scope.in_repeat = !mdata.is_single(node)

	eq, lo, hi, any_of, ex, in_enum: ^yml.Node
	switch n.kind {
	case .Scalar:
		eq = n
	case .Seq:
		return nil, fail(c, .Invalid, n, "%s: valid must be a constant or a mapping", id)
	case .Map:
		check_keys(c, n, {what = "%s: valid", name = id, allowed = {"eq", "min", "max", "any-of", "expr", "in-enum"}}) or_return
		eq, lo, hi, any_of, ex, in_enum = get(n, "eq"), get(n, "min"), get(n, "max"), get(n, "any-of"), get(n, "expr"), get(n, "in-enum")
		forms := int(eq != nil) + int(lo != nil || hi != nil) + int(any_of != nil) + int(ex != nil) + int(in_enum != nil)
		if forms != 1 do return nil, fail(c, .Invalid, n, "%s: valid needs exactly one of eq, min and max, any-of, expr and in-enum", id)
	}

	switch {
	case ex != nil:
		cond := compile_expr(c, ex, "valid", scope, .Bool) or_return
		checks := make([]mdata.Valid_Check, 1, c.allocator)
		checks[0] = {cond, .Expr_False}
		return mdata.Valid_Expr{checks}, true
	case in_enum != nil:
		return compile_in_enum(c, in_enum, id, en)
	}
	if type == .Set do return nil, fail(c, .Invalid, n, "%s: valid on a user type must be an expr", id)
	if type != .Bool && type != .String && type != .Blob && type not_in INTEGER_TYPES {
		return nil, fail(c, .Unsupported, n, "%s: valid on a %v is not supported", id, type)
	}
	if (lo != nil || hi != nil) && type not_in INTEGER_TYPES {
		return nil, fail(c, .Unsupported, n, "%s: min and max are only supported on integer types", id)
	}

	nodes := []^yml.Node{eq}
	if lo != nil || hi != nil do nodes = []^yml.Node{lo, hi}
	if any_of != nil {
		if any_of.kind != .Seq do return nil, fail(c, .Invalid, any_of, "%s: any-of must be a sequence", id)
		nodes = any_of.items
	}
	bounds := make([]Bound, len(nodes), c.scratch)
	literal := true
	for x, i in nodes {
		if x == nil do continue
		bounds[i] = compile_bound(c, x, id, type, scope) or_return
		literal &&= bounds[i].value != nil
	}

	if literal {
		switch {
		case eq != nil:
			return mdata.Valid_Eq{bounds[0].value}, true
		case any_of != nil:
			values := make([]mdata.Scalar, len(bounds), c.allocator)
			for b, i in bounds do values[i] = b.value
			return mdata.Valid_Any_Of{values}, true
		}
		r := mdata.Valid_Range{bounds[0].value, bounds[1].value}
		if lo != nil && hi != nil && int_of(r.min) > int_of(r.max) do return nil, fail(c, .Invalid, n, "%s: min is above max", id)
		return r, true
	}

	for b, i in bounds {
		if nodes[i] != nil && b.e == nil do return nil, fail(c, .Unsupported, nodes[i], "%s: %s cannot be compared with an expression", id, nodes[i].text)
	}
	checks := make([dynamic]mdata.Valid_Check, c.allocator)
	value_type: mdata.Expr_Type
	#partial switch type {
	case .Bool:
		value_type = .Bool
	case .String:
		value_type = .String
	case .Blob:
		value_type = .Bytes
	case:
		value_type = .Int
	}
	value := new_expr(c, value_type, mdata.Repeat_Element{node})
	switch {
	case eq != nil:
		append(&checks, mdata.Valid_Check{new_expr(c, .Bool, mdata.Binary{.Eq, value, bounds[0].e}), .Not_Equal})
	case any_of != nil:
		append(&checks, mdata.Valid_Check{any_of_cond(c, value, bounds), .Not_Any_Of})
	case:
		if lo != nil do append(&checks, mdata.Valid_Check{new_expr(c, .Bool, mdata.Binary{.Ge, value, bounds[0].e}), .Less_Than_Min})
		if hi != nil do append(&checks, mdata.Valid_Check{new_expr(c, .Bool, mdata.Binary{.Le, value, bounds[1].e}), .Greater_Than_Max})
	}
	return mdata.Valid_Expr{checks[:]}, true
}

// value == bounds[0].e or ..., a Bool expression: an or of the equalities,
// halved into a balanced tree, so that a long any-of is no deeper than
// its logarithm (expression.MAX_DEPTH); or tests them in order still, and
// stops at the first that holds.
@(private = "file")
any_of_cond :: proc(c: ^Compiler, value: ^mdata.Expr, bounds: []Bound) -> ^mdata.Expr {
	if len(bounds) == 1 do return new_expr(c, .Bool, mdata.Binary{.Eq, value, bounds[0].e})
	half := len(bounds) / 2
	return new_expr(c, .Bool, mdata.Binary{.Logical_Or, any_of_cond(c, value, bounds[:half]), any_of_cond(c, value, bounds[half:])})
}

// A constant of valid: value when it is a literal, and e when it can be
// compared in an expression; at least one is set.
@(private = "file")
Bound :: struct {
	value: mdata.Scalar,
	e:     ^mdata.Expr,
}

// The constant n of valid, on a value of type, in scope.
@(private = "file")
compile_bound :: proc(c: ^Compiler, n: ^yml.Node, id: string, type: dat.Data_Type, scope: expr.Scope) -> (b: Bound, ok: bool) {
	text := strings.trim_space(expect_scalar(c, n, "a valid constant") or_return)

	#partial switch type {
	case .Blob:
		// a list of bytes, as contents takes one, or a Bytes expression
		if bytes, is_list := byte_literal(c, text); is_list {
			return {value = bytes, e = new_expr(c, .Bytes, mdata.Bytes_Literal{bytes})}, true
		}
		return {e = compile_expr(c, n, "valid", scope, .Bytes) or_return}, true
	case .Bool:
		return {e = compile_expr(c, n, "valid", scope, .Bool) or_return}, true
	case .String:
		b.e = compile_expr(c, n, "valid", scope, .String) or_return
		if lit, is_literal := b.e.variant.(mdata.String_Literal); is_literal do b.value = lit.value
		return b, true
	}

	// an integer literal is read here, as text, so that its value is taken
	// in the field's own type (int_scalar) and one that does not fit it
	// (300 for a u1, -1 for a u8) is an error when the schema is compiled,
	// rather than a check that no value passes. Its expression form, for
	// an expr, is kept only for a value that fits an int; one above, up to
	// max(u64), is checked by its Scalar alone.
	v, is_int := parse_int(text)
	if !is_int {
		b.e = compile_expr(c, n, "valid", scope, .Int) or_return
		v, is_int = int_literal(b.e)
		if !is_int do return b, true
	} else if v >= i128(min(int)) && v <= i128(max(int)) {
		b.e = new_expr(c, .Int, mdata.Int_Literal{int(v)})
	}
	b.value, ok = int_scalar(type, v)
	if !ok do return {}, fail(c, .Invalid, n, "%s: %s does not fit in a %v", id, text, type)
	return b, true
}

// The value of e when it is an integer literal or a negated one, such as
// -1, or -9223372036854775808, the negation of a literal above max(int);
// enum constants are already literals. As the parser reads -1 as the
// negation of 1, valid bounds and switch-on cases take their integers here.
// Not when it, or a negation within it, is outside the integers that
// evaluating it gives, from min(int) to max(u64): evaluated, it fails with
// Integer_Overflow, as -(-18446744073709551615) does at its inner negation.
@(private)
int_literal :: proc(e: ^mdata.Expr) -> (v: i128, ok: bool) {
	#partial switch x in e.variant {
	case mdata.Int_Literal:
		return i128(x.value), true
	case mdata.Big_Literal:
		return i128(x.value), true
	case mdata.Unary:
		if x.op != .Neg do return
		n, err := mdata.int_unary(.Neg, int_literal(x.operand) or_return)
		return n, err == .None
	}
	return
}

// text as a list of bytes, [0x50, 0x4b]: integer literals from 0 to 255.
@(private = "file")
byte_literal :: proc(c: ^Compiler, text: string) -> (bytes: []byte, ok: bool) {
	if len(text) < 2 || text[0] != '[' || text[len(text) - 1] != ']' do return
	b := make([dynamic]byte, c.allocator)
	for item in strings.split(text[1:len(text) - 1], ",", c.scratch) {
		v := parse_int(strings.trim_space(item)) or_return
		if v < 0 || v > 255 do return
		append(&b, byte(v))
	}
	return b[:], true
}

// valid: in-enum: true, of id, whose enum is en (nil when it has none): its
// value is one of the enum's. in-enum: false checks nothing.
@(private = "file")
compile_in_enum :: proc(c: ^Compiler, n: ^yml.Node, id: string, en: ^expr.Enum) -> (valid: mdata.Valid, ok: bool) {
	if !(boolean(c, n, "in-enum") or_return) do return nil, true
	if en == nil do return nil, fail(c, .Invalid, n, "%s: in-enum needs an enum", id)
	values := make([]int, len(en.values), c.allocator)
	for v, i in en.values do values[i] = v.value
	slice.sort(values)
	return mdata.Valid_In_Enum{values}, true
}

@(private = "file")
int_scalar :: proc(type: dat.Data_Type, v: i128) -> (value: mdata.Scalar, ok: bool) {
	#partial switch type {
	case .Int8:
		if v >= i128(min(i8)) && v <= i128(max(i8)) do return i8(v), true
	case .UInt8:
		if v >= 0 && v <= i128(max(u8)) do return u8(v), true
	case .Int16:
		if v >= i128(min(i16)) && v <= i128(max(i16)) do return i16(v), true
	case .UInt16:
		if v >= 0 && v <= i128(max(u16)) do return u16(v), true
	case .Int32:
		if v >= i128(min(i32)) && v <= i128(max(i32)) do return i32(v), true
	case .UInt32:
		if v >= 0 && v <= i128(max(u32)) do return u32(v), true
	case .Int64:
		if v >= i128(min(i64)) && v <= i128(max(i64)) do return i64(v), true
	case .UInt64:
		if v >= 0 && v <= i128(max(u64)) do return u64(v), true
	}
	return nil, false
}

// An integer Scalar as an i128, for comparing bounds.
@(private = "file")
int_of :: proc(s: mdata.Scalar) -> i128 {
	#partial switch v in s {
	case i8:  return i128(v)
	case i16: return i128(v)
	case i32: return i128(v)
	case i64: return i128(v)
	case u8:  return i128(v)
	case u16: return i128(v)
	case u32: return i128(v)
	case u64: return i128(v)
	}
	panic("int_of: not an integer")
}

// An integer literal in a YAML scalar: an optional sign, then an integer
// literal as an expression has one (expression.int_literal_value, which the
// expression parser reads them with too), so up to 2^64 - 1 either way.
@(private)
parse_int :: proc(text: string) -> (v: i128, ok: bool) {
	value, status := int_scalar_value(text)
	return value, status == .Ok
}

// Whether YAML 1.1, which the official Kaitai tools read schemas with
// (SnakeYAML, and PyYAML, which tools/kaitai_compare uses), reads text, a
// plain scalar, as an integer: with an optional sign, 0b and 0x digits,
// octal with a leading 0, decimal, or base 60 (1:30), each with _
// anywhere after its first digit. A list of bytes and strings (contents)
// takes a scalar that is one as a byte, any other as text: 0o17 and 08,
// which YAML 1.1 reads as strings, are text.
@(private = "file")
yaml_int :: proc(text: string) -> bool {
	only :: proc(s: string, allowed: string) -> bool {
		if len(s) == 0 do return false
		for ch in s do if !strings.contains_rune(allowed, ch) do return false
		return true
	}
	s := text
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') do s = s[1:]
	switch {
	case strings.has_prefix(s, "0b"):
		return only(s[2:], "01_")
	case strings.has_prefix(s, "0x"):
		return only(s[2:], "0123456789abcdefABCDEF_")
	case s == "0":
		return true
	case len(s) > 0 && s[0] == '0':
		return only(s[1:], "01234567_")
	case len(s) > 0 && s[0] >= '1' && s[0] <= '9':
		colon := strings.index_byte(s, ':')
		if colon < 0 do return only(s, "0123456789_")
		if !only(s[:colon], "0123456789_") do return false
		// then :[0-5]?[0-9], one or more times
		rest := s[colon:]
		for len(rest) > 0 {
			if rest[0] != ':' do return false
			rest = rest[1:]
			k := 0
			for k < len(rest) && k < 2 && rest[k] >= '0' && rest[k] <= '9' do k += 1
			if k == 0 || (k == 2 && rest[0] > '5') do return false
			rest = rest[k:]
		}
		return true
	}
	return false
}

// The value of text as parse_int reads it, and why it is not one: Invalid
// for text that is no integer, Leading_Zero (010) and Too_Large for text
// that would be one, but is not one zelbyn reads.
@(private = "file")
int_scalar_value :: proc(text: string) -> (v: i128, status: expr.Int_Literal_Status) {
	s := text
	negative := false
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		negative = s[0] == '-'
		s = s[1:]
	}
	value: u64
	value, _, status, _ = expr.int_literal_value(s)
	return negative ? -i128(value) : i128(value), status
}
