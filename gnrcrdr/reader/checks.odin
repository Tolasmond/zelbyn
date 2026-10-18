package reader

import dat "../data"
import fld "../field"
import mdata "../metadata"
import "core:slice"

// Checks value, of a field that is not a set, against valid, whose
// constants have the value's type.
@(private, require_results)
check_valid :: proc(value: fld.Value, valid: mdata.Valid) -> dat.Read_Error {
	if valid == nil do return .None

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
	case map[int][dynamic]fld.Value:
		panic("check_valid: called for a set")
	}
	panic("check_valid: no value")
}

// Comparisons are written !(a <= b) so that a NaN fails every range.
@(private = "file", require_results)
check_scalar :: proc(v: $T, valid: mdata.Valid) -> dat.Read_Error {
	switch c in valid {
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
	switch c in valid {
	case mdata.Valid_Eq:
		if !slice.equal(v, c.value.([]byte)) do return .Not_Equal
	case mdata.Valid_Range:
		panic("check_valid: a range on a blob")
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
