package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:slice"
import "core:strings"

// Checks value, element index of a field that has valid, against it. The
// value is already in the tree, so that the expressions of a Valid_Expr see
// it under the field's name as well as as _.
@(private, require_results)
check_valid :: proc(d: ^Decoder, value: fld.Value, valid: mdata.Valid, index: int) -> dat.Read_Error {
	#partial switch c in valid {
	case mdata.Valid_In_Enum:
		n, is_int := int_of_value(value)
		if !is_int do return .Not_In_Enum
		if _, found := slice.binary_search(c.values, n); !found do return .Not_In_Enum
		return .None
	case mdata.Valid_Expr:
		for check in c.checks {
			ok := eval_bool(d, check.cond, index, value) or_return
			if !ok do return check.err
		}
		return .None
	}
	return check_constant(value, valid)
}

// Checks value against valid, a check with constants of its type.
@(private, require_results)
check_constant :: proc(value: fld.Value, valid: mdata.Valid) -> dat.Read_Error {
	switch v in value {
	case i8:
		return check_scalar(v, valid)
	case i16:
		return check_scalar(v, valid)
	case i32:
		return check_scalar(v, valid)
	case i64:
		return check_scalar(v, valid)
	case u8:
		return check_scalar(v, valid)
	case u16:
		return check_scalar(v, valid)
	case u32:
		return check_scalar(v, valid)
	case u64:
		return check_scalar(v, valid)
	case f32:
		return check_scalar(v, valid)
	case f64:
		return check_scalar(v, valid)
	case string:
		return check_scalar(v, valid)
	case []byte:
		return check_bytes(v, valid)
	case bool:
		panic("check_constant: a check on a boolean")
	case ^fld.Instance:
		panic("check_constant: called for a set")
	case []fld.Value:
		panic("check_constant: called for an array")
	}
	panic("check_constant: no value")
}

// Records kind, which checking value, element index of a field, against
// valid gave, as fail does, at offset in the stream being read. When kind is
// a check's failure, the error also has the value read and what valid
// expected (Parse_Error.value and expected); an expression valid compares
// with is evaluated again for it, and shows nothing if that fails.
@(private)
fail_check :: proc(d: ^Decoder, kind: dat.Read_Error, offset: int, value: fld.Value, valid: mdata.Valid, index: int) -> dat.Read_Error {
	#partial switch kind {
	case .Not_Equal, .Less_Than_Min, .Greater_Than_Max, .Not_Any_Of, .Not_In_Enum, .Expr_False:
	case:
		return fail(d, kind, offset)
	}
	if d.err.kind != .None do return kind

	expected := strings.builder_make()
	switch c in valid {
	case mdata.Valid_Eq:
		write_shown(&expected, scalar_value(c.value))
	case mdata.Valid_Range:
		write_shown(&expected, scalar_value(kind == .Less_Than_Min ? c.min : c.max))
	case mdata.Valid_Any_Of:
		for x, i in c.values {
			if !write_list_item(&expected, i) do break
			write_shown(&expected, scalar_value(x))
		}
	case mdata.Valid_In_Enum:
		for x, i in c.values {
			if !write_list_item(&expected, i) do break
			strings.write_int(&expected, x)
		}
	case mdata.Valid_Expr:
		for check in c.checks {
			if check.err != kind do continue
			items := 0
			if kind != .Expr_False && !write_operands(d, &expected, check.cond, index, value, &items) {
				strings.builder_reset(&expected)
			}
			break
		}
	}

	fail(d, kind, offset)
	read := strings.builder_make()
	write_shown(&read, value)
	d.err.value = strings.to_string(read)
	d.err.expected = strings.to_string(expected)
	return kind
}

// Appends v to b as Parse_Error shows it; nothing for a set.
@(private = "file")
write_shown :: proc(b: ^strings.Builder, v: fld.Value) {
	n := len(b.buf)
	// a builder's writer fails only on a value write_value does not show
	if fld.write_value(strings.to_writer(b), v, STRING_PREVIEW) != .None do resize(&b.buf, n)
}

// Starts item i of a list in b; false when it is past the first
// LIST_PREVIEW, after ", ..." for the first of those.
@(private = "file")
write_list_item :: proc(b: ^strings.Builder, i: int) -> bool {
	if i > LIST_PREVIEW do return false
	if i > 0 do strings.write_string(b, ", ")
	if i == LIST_PREVIEW {
		strings.write_string(b, "...")
		return false
	}
	return true
}

// Appends to b, as a list, the value of each operand that cond compares
// _ with: eq, min and max compare _ with theirs (_ == x, _ >= x, _ <= x),
// and any-of is an or of such comparisons. items is the number in b so
// far. False when an operand cannot be evaluated.
@(private = "file")
write_operands :: proc(d: ^Decoder, b: ^strings.Builder, cond: ^mdata.Expr, index: int, element: fld.Value, items: ^int) -> bool {
	x, is_binary := cond.variant.(mdata.Binary)
	if !is_binary do return true
	if x.op == .Logical_Or {
		return write_operands(d, b, x.left, index, element, items) && write_operands(d, b, x.right, index, element, items)
	}
	items^ += 1
	if !write_list_item(b, items^ - 1) do return true
	v, err := eval_check_operand(d, x.right, index, element)
	if err != .None do return false
	write_shown(b, eval_as_value(v))
	return true
}

@(private = "file")
scalar_value :: proc(s: mdata.Scalar) -> fld.Value {
	switch x in s {
	case i8:     return x
	case i16:    return x
	case i32:    return x
	case i64:    return x
	case u8:     return x
	case u16:    return x
	case u32:    return x
	case u64:    return x
	case f32:    return x
	case f64:    return x
	case string: return x
	case []byte: return x
	}
	return nil
}

// v as a Value write_value shows: an int as an i64; nil for a set or an
// array.
@(private = "file")
eval_as_value :: proc(v: Eval_Value) -> fld.Value {
	#partial switch x in v {
	case int:    return i64(x)
	case u64:    return x
	case f64:    return x
	case bool:   return x
	case []byte: return x
	case string: return x
	}
	return nil
}

// An integer value as an int; is_int is false for any other value, and for
// a u64 above max(int).
@(private = "file")
int_of_value :: proc(value: fld.Value) -> (n: int, is_int: bool) {
	#partial switch v in value {
	case i8:
		return int(v), true
	case i16:
		return int(v), true
	case i32:
		return int(v), true
	case i64:
		return int(v), true
	case u8:
		return int(v), true
	case u16:
		return int(v), true
	case u32:
		return int(v), true
	case u64:
		if v <= u64(max(int)) do return int(v), true
	}
	return 0, false
}

// Comparisons are written !(a <= b) so that a NaN fails every range.
@(private = "file", require_results)
check_scalar :: proc(v: $T, valid: mdata.Valid) -> dat.Read_Error {
	#partial switch c in valid {
	case mdata.Valid_Eq:
		if v != c.value.(T) do return .Not_Equal
	case mdata.Valid_Range:
		if lo, has_min := c.min.(T); has_min && !(lo <= v) do return .Less_Than_Min
		if hi, has_max := c.max.(T); has_max && !(v <= hi) do return .Greater_Than_Max
	case mdata.Valid_Any_Of:
		for x in c.values {
			if v == x.(T) do return .None
		}
		return .Not_Any_Of
	}
	return .None
}

@(private = "file", require_results)
check_bytes :: proc(v: []byte, valid: mdata.Valid) -> dat.Read_Error {
	#partial switch c in valid {
	case mdata.Valid_Eq:
		if !slice.equal(v, c.value.([]byte)) do return .Not_Equal
	case mdata.Valid_Range:
		panic("check_constant: a range on a blob")
	case mdata.Valid_Any_Of:
		for x in c.values {
			if slice.equal(v, x.([]byte)) do return .None
		}
		return .Not_Any_Of
	}
	return .None
}

// Bits bit.low through bit.high of value, an integer, as bit.type.
@(private, require_results)
bit_field_value :: proc(value: fld.Value, bit: mdata.Bit_Field) -> fld.Value {
	raw: u64
	#partial switch v in value {
	case i8:
		raw = u64(u8(v))
	case i16:
		raw = u64(u16(v))
	case i32:
		raw = u64(u32(v))
	case i64:
		raw = u64(v)
	case u8:
		raw = u64(v)
	case u16:
		raw = u64(v)
	case u32:
		raw = u64(v)
	case u64:
		raw = v
	case:
		panic("bit_field_value: not an integer")
	}

	width := uint(bit.high - bit.low + 1)
	bits := raw >> uint(bit.low)
	if width < 64 do bits &= (1 << width) - 1

	#partial switch bit.type {
	case .Int8:
		return i8(bits)
	case .UInt8:
		return u8(bits)
	case .Int16:
		return i16(bits)
	case .UInt16:
		return u16(bits)
	case .Int32:
		return i32(bits)
	case .UInt32:
		return u32(bits)
	case .Int64:
		return i64(bits)
	case .UInt64:
		return bits
	}
	panic("bit_field_value: a bit field that is not an integer")
}
