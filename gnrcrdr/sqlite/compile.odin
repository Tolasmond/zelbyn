package sqlite

import dat "../data"
import expr "../expression"
import mdata "../metadata"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// Integer types the decoder can peek (dat.read_integer).
@(private = "file")
PEEKABLE :: bit_set[dat.Data_Type]{.Int8, .UInt8, .Int16, .UInt16, .Int32, .UInt32, .Int64}

@(private = "file")
TYPE_SIZE :: #partial [dat.Data_Type]int {
	.Int8   = 1,
	.UInt8  = 1,
	.Int16  = 2,
	.UInt16 = 2,
	.Int32  = 4,
	.UInt32 = 4,
	.Int64  = 8,
	.UInt64 = 8,
}

@(private = "file")
Compiler :: struct {
	records:   ^Records,
	allocator: mem.Allocator,       // the File_Format's arena
	nodes:     map[int]^mdata.Node, // by field id; nil while that field is being compiled
	err:       Load_Error,
}

// Compiles the records of one format into file_format, which must be zero
// or destroyed, and validates them. The first problem found is returned as .Invalid_Schema,
// naming the table at fault and the row ids involved. Rejected:
//   - a missing root, child field, data type, Length or MarkerOffset row
//   - a type code outside dat.Data_Type, and a field that contains itself
//   - two children of one set with the same id or ChildIndex, and children
//     of a field that is not a set
//   - IsGrowAsNeeded other than 0 or 1, or set on a field that is not a set
//   - a negative MinArrayLength, buffer length or shift
//   - a SetHelper row with both or neither of LengthId and MarkerId, or on
//     a field that is neither a set nor a variable-length blob
//   - a growing set without a Length row that has exactly one of
//     Continuator and Terminator and nothing else, or with MinArrayLength > 0
//   - a counting Length row with a Continuator or Terminator, both an
//     absolute and a relative offset, or a mask or shift without an offset
//   - a FlagExpression, a ValueExpression on a blob length (the decoder
//     ignored both before the plan existed), and any ValueExpression other
//     than LEGACY_POW2
//   - peek types that are not integers of at most 64 bits (UInt64 included)
//   - a String without MaxBufferLength, a blob whose fixed length is below
//     its MinBufferLength, and MinBufferLength > MaxBufferLength
//   - packed fields on a non-integer field, or with bits outside its width,
//     or whose own data type is missing or not an integer
//   - a DefaultValue on a Set or Blob, one that is not a number of the
//     field's type (integers in decimal) or lies outside MinValue and
//     MaxValue (when a default is present, those must be numbers of the type
//     too), and a String default longer than MaxBufferLength
compile :: proc(records: ^Records, file_format: ^mdata.File_Format) -> Load_Error {
	scratch: virtual.Arena
	defer virtual.arena_destroy(&scratch)

	c := Compiler{records = records, allocator = virtual.arena_allocator(&file_format.arena)}
	c.nodes = make(map[int]^mdata.Node, virtual.arena_allocator(&scratch))

	file_format.name = strings.clone(records.format_record.name, c.allocator)
	file_format.root, _ = compile_node(&c, records.format_record.root_field, "Format")
	return c.err
}

// Records the first error; always returns false.
@(private = "file")
fail :: proc(c: ^Compiler, table: string, format: string, args: ..any) -> bool {
	if c.err.kind == .None {
		c.err = Load_Error{kind = .Invalid_Schema, table = table, message = fmt.aprintf(format, ..args)}
	}
	return false
}

// table names the table that refers to field id, for the error when the
// field does not exist.
@(private = "file")
compile_node :: proc(c: ^Compiler, id: int, table: string) -> (node: ^mdata.Node, ok: bool) {
	if n, seen := c.nodes[id]; seen {
		if n == nil do return nil, fail(c, "Parent", "field %v contains itself", id)
		return n, true
	}

	field := c.records.field_map[id]
	if field == nil do return nil, fail(c, table, "field %v not found", id)

	dt := data_type(c, field.data_type_id, "Field", id) or_return

	c.nodes[id] = nil // in progress: meeting id again below it is a cycle

	node = new(mdata.Node, c.allocator)
	node^ = {id = id, name = strings.clone(field.name, c.allocator), type = dat.Data_Type(dt.type)}

	grow := false
	if g, has_grow := dt.is_grow_as_needed.?; has_grow {
		if g != 0 && g != 1 do return nil, fail(c, "DataType", "data type %v: IsGrowAsNeeded is %v, not 0 or 1", dt.id, g)
		grow = g == 1
	}

	helper := c.records.set_helper_map[id]
	children := c.records.parent_map[id]

	if node.type == .Set {
		compile_children(c, node, children[:]) or_return
		node.count = set_count(c, node, dt, helper, grow) or_return
	} else {
		if len(children) > 0 do return nil, fail(c, "Parent", "field %v (%s) is a %v, not a set, but has children", id, node.name, node.type)
		if grow do return nil, fail(c, "DataType", "data type %v: IsGrowAsNeeded is set on a %v", dt.id, node.type)

		node.count = mdata.Fixed_Count{min_array_length(c, dt) or_return}

		#partial switch node.type {
		case .String:
			if helper != nil do return nil, fail(c, "SetHelper", "field %v (%s): a String takes no SetHelper row", id, node.name)
			n, has_n := dt.max_buffer_length.?
			if !has_n || n < 0 do return nil, fail(c, "DataType", "data type %v: a String needs a MaxBufferLength of 0 or more", dt.id)
			node.length = mdata.Fixed_Length{n}
		case .Blob:
			node.length = blob_length(c, node, dt, helper) or_return
		case:
			if helper != nil do return nil, fail(c, "SetHelper", "field %v (%s): a %v takes no SetHelper row", id, node.name, node.type)
		}
	}

	max_bytes := 0
	if l, fixed := node.length.(mdata.Fixed_Length); fixed do max_bytes = l.n
	node.default_value = compile_default(c, dt, node.type, max_bytes) or_return
	node.bits = compile_bits(c, node) or_return

	c.nodes[id] = node
	return node, true
}

// owner is the id of the row in table that refers to data type id.
@(private = "file")
data_type :: proc(c: ^Compiler, id: int, table: string, owner: int) -> (dt: ^Data_Type_Record, ok: bool) {
	dt = c.records.data_type_map[id]
	if dt == nil do return nil, fail(c, table, "%s row %v: data type %v not found", table, owner, id)
	if dt.type < 0 || dt.type > int(max(dat.Data_Type)) {
		return nil, fail(c, "DataType", "data type %v: unknown type code %v", id, dt.type)
	}
	return dt, true
}

// The integer type of data type id, for a peek. owner is as for data_type.
@(private = "file")
peek_type :: proc(c: ^Compiler, id: int, table: string, owner: int) -> (type: dat.Data_Type, ok: bool) {
	dt := data_type(c, id, table, owner) or_return
	type = dat.Data_Type(dt.type)
	if type not_in PEEKABLE do return type, fail(c, table, "%s row %v: data type %v is a %v, which cannot be peeked", table, owner, id, type)
	return type, true
}

@(private = "file")
min_array_length :: proc(c: ^Compiler, dt: ^Data_Type_Record) -> (n: int, ok: bool) {
	n = dt.min_array_length.? or_else 1
	if n < 0 do return 0, fail(c, "DataType", "data type %v: MinArrayLength is %v", dt.id, n)
	return n, true
}

// rows must be sorted by ChildIndex.
@(private = "file")
compile_children :: proc(c: ^Compiler, node: ^mdata.Node, rows: []^Parent_Record) -> bool {
	children := make([]^mdata.Node, len(rows), c.allocator)

	for row, i in rows {
		for prev in rows[:i] {
			if prev.child_index == row.child_index {
				return fail(c, "Parent", "field %v (%s): children %v and %v both have ChildIndex %v", node.id, node.name, prev.child_id, row.child_id, row.child_index)
			}
			if prev.child_id == row.child_id {
				return fail(c, "Parent", "field %v (%s): child %v appears twice", node.id, node.name, row.child_id)
			}
		}
		children[i] = compile_node(c, row.child_id, "Parent") or_return
	}

	node.children = children
	return true
}

@(private = "file")
set_count :: proc(
	c: ^Compiler,
	node: ^mdata.Node,
	dt: ^Data_Type_Record,
	helper: ^Set_Helper_Record,
	grow: bool) -> (count: mdata.Count, ok: bool) {

	length_id, marker_id := 0, 0
	has_length, has_marker := false, false
	if helper != nil {
		length_id, has_length = helper.length_id.?
		marker_id, has_marker = helper.marker_id.?
		if has_length == has_marker {
			return nil, fail(c, "SetHelper", "field %v (%s): exactly one of LengthId and MarkerId must be set", node.id, node.name)
		}
	}

	if grow {
		if !has_length do return nil, fail(c, "SetHelper", "field %v (%s) grows as needed but has no LengthId", node.id, node.name)
		if n := dt.min_array_length.? or_else 0; n != 0 {
			return nil, fail(c, "DataType", "data type %v: a growing set cannot have a MinArrayLength (%v)", dt.id, n)
		}
		repeat := repeat_count(c, node, length_id) or_return
		repeat.max = dt.max_array_length
		return repeat, true
	}

	if has_marker do return marker_count(c, node, marker_id)

	if has_length {
		e := length_expr(c, node, length_id, true) or_return
		return mdata.Rule_Count{expr = e, max = dt.max_array_length}, true
	}

	return mdata.Fixed_Count{min_array_length(c, dt) or_return}, true
}

@(private = "file")
marker_count :: proc(c: ^Compiler, node: ^mdata.Node, marker_id: int) -> (count: mdata.Count, ok: bool) {
	rows := c.records.marker_offset_map[marker_id]
	if len(rows) == 0 do return nil, fail(c, "SetHelper", "field %v (%s): marker %v has no MarkerOffset rows", node.id, node.name, marker_id)

	markers := make([]mdata.Marker, len(rows), c.allocator)
	for row, i in rows {
		markers[i] = {offset = row.byte_offset, type = peek_type(c, row.data_type_id, "MarkerOffset", marker_id) or_return, value = row.marker}
	}
	return mdata.Marker_Count{markers}, true
}

@(private = "file")
length_record :: proc(c: ^Compiler, node: ^mdata.Node, id: int) -> (rec: ^Length_Record, ok: bool) {
	rec = c.records.set_length_map[id]
	if rec == nil do return nil, fail(c, "SetHelper", "field %v (%s): length %v not found", node.id, node.name, id)
	return rec, true
}

// A growing set's stop condition: a Length row with exactly one of
// Continuator and Terminator, and nothing else.
@(private = "file")
repeat_count :: proc(c: ^Compiler, node: ^mdata.Node, length_id: int) -> (repeat: mdata.Repeat_Count, ok: bool) {
	rec := length_record(c, node, length_id) or_return

	continuator, has_continuator := rec.continuator.?
	terminator, has_terminator := rec.terminator.?
	if has_continuator == has_terminator {
		return {}, fail(c, "Length", "length %v: exactly one of Continuator and Terminator must be set for growing set %v (%s)", rec.id, node.id, node.name)
	}

	if rec.flag_absoute_offset_from_beginning != nil || rec.flag_relative_offset_from_field != nil ||
	   rec.value_absolute_offset_from_beginning != nil || rec.value_relative_offset_from_field != nil ||
	   rec.flag_mask != nil || rec.flag_shift != nil || rec.value_mask != nil || rec.value_shift != nil ||
	   rec.flag_expression != nil || rec.value_expression != nil {
		return {}, fail(c, "Length", "length %v: only Continuator or Terminator may be set for growing set %v (%s)", rec.id, node.id, node.name)
	}

	repeat.type = peek_type(c, rec.data_type_id, "Length", rec.id) or_return
	repeat.value = has_continuator ? continuator : terminator
	repeat.until = has_terminator
	return repeat, true
}

// The only ValueExpression the database uses: 2^(x+1), where x is the
// value. It compiles to 2 << x.
@(private = "file")
LEGACY_POW2 :: "Pow(2, [x]+1)"

// A computed count or length, as an Int expression over integers peeked at
// the reader's position or from the start of the input. When the flag peek
// reads as zero the result is 0; otherwise it is the value peek (0 when
// absent), with ValueExpression applied when present:
//   flag != 0 ? 2 << value : 0
// allow_expression is false for blob lengths.
@(private = "file")
length_expr :: proc(c: ^Compiler, node: ^mdata.Node, length_id: int, allow_expression: bool) -> (e: ^mdata.Expr, ok: bool) {
	rec := length_record(c, node, length_id) or_return

	if rec.continuator != nil || rec.terminator != nil {
		return nil, fail(c, "Length", "length %v: Continuator and Terminator only apply to growing sets, not to %v (%s)", rec.id, node.id, node.name)
	}
	if rec.flag_expression != nil {
		return nil, fail(c, "Length", "length %v: FlagExpression is not supported", rec.id)
	}

	type := peek_type(c, rec.data_type_id, "Length", rec.id) or_return
	flag := peek(c, rec, type, "Flag", rec.flag_absoute_offset_from_beginning, rec.flag_relative_offset_from_field, rec.flag_mask, rec.flag_shift) or_return
	value := peek(c, rec, type, "Value", rec.value_absolute_offset_from_beginning, rec.value_relative_offset_from_field, rec.value_mask, rec.value_shift) or_return

	e = value != nil ? value : expr.int_literal(0, c.allocator)

	if expression, has_expression := rec.value_expression.?; has_expression {
		if !allow_expression {
			return nil, fail(c, "Length", "length %v: ValueExpression is not supported on a blob length (%v, %s)", rec.id, node.id, node.name)
		}
		if expression != LEGACY_POW2 {
			return nil, fail(c, "Length", "length %v: ValueExpression %q is not supported; the only one is %q", rec.id, expression, LEGACY_POW2)
		}
		e = expr.binary(.Shl, expr.int_literal(2, c.allocator), e, c.allocator)
	}

	if flag != nil {
		is_set := expr.binary(.Ne, flag, expr.int_literal(0, c.allocator), c.allocator)
		e = expr.ternary(is_set, e, expr.int_literal(0, c.allocator), c.allocator)
	}

	return e, true
}

// An integer of type read at an offset, then masked and shifted right; nil
// when neither offset is set. what is "Flag" or "Value", the prefix of the
// columns.
@(private = "file")
peek :: proc(
	c: ^Compiler,
	rec: ^Length_Record,
	type: dat.Data_Type,
	what: string,
	absolute, relative, mask, shift: Maybe(int)) -> (e: ^mdata.Expr, ok: bool) {

	abs_offset, has_absolute := absolute.?
	rel_offset, has_relative := relative.?

	if has_absolute && has_relative {
		return nil, fail(c, "Length", "length %v: both %sAbsoluteOffsetFromBeginning and %sRelativeOffsetFromField are set", rec.id, what, what)
	}
	if !has_absolute && !has_relative {
		if mask != nil || shift != nil do return nil, fail(c, "Length", "length %v: %sMask or %sShift without an offset", rec.id, what, what)
		return nil, true
	}

	pos: ^mdata.Expr
	switch {
	case has_absolute:
		pos = expr.int_literal(abs_offset, c.allocator)
	case rel_offset < 0:
		pos = expr.binary(.Sub, expr.io_pos(c.allocator), expr.int_literal(-rel_offset, c.allocator), c.allocator)
	case rel_offset > 0:
		pos = expr.binary(.Add, expr.io_pos(c.allocator), expr.int_literal(rel_offset, c.allocator), c.allocator)
	case:
		pos = expr.io_pos(c.allocator)
	}
	e = expr.peek(type, pos, c.allocator)

	if m, has_mask := mask.?; has_mask {
		e = expr.binary(.And, e, expr.int_literal(m, c.allocator), c.allocator)
	}
	if s, has_shift := shift.?; has_shift {
		if s < 0 || s > 63 do return nil, fail(c, "Length", "length %v: %sShift is %v, not 0 to 63", rec.id, what, s)
		if s > 0 do e = expr.binary(.Shr, e, expr.int_literal(s, c.allocator), c.allocator)
	}
	return e, true
}

@(private = "file")
blob_length :: proc(c: ^Compiler, node: ^mdata.Node, dt: ^Data_Type_Record, helper: ^Set_Helper_Record) -> (length: mdata.Length, ok: bool) {
	min_length, max_length := dt.min_buffer_length, dt.max_buffer_length
	lo, has_lo := min_length.?
	hi, has_hi := max_length.?

	if (has_lo && lo < 0) || (has_hi && hi < 0) || (has_lo && has_hi && lo > hi) {
		return nil, fail(c, "DataType", "data type %v: buffer lengths %v to %v", dt.id, min_length, max_length)
	}

	if min_length == max_length {
		if helper != nil {
			return nil, fail(c, "SetHelper", "field %v (%s): a fixed-length blob (MinBufferLength = MaxBufferLength) takes no SetHelper row", node.id, node.name)
		}
		return mdata.Fixed_Length{hi}, true
	}

	if helper != nil {
		length_id, has_length := helper.length_id.?
		if !has_length || helper.marker_id != nil {
			return nil, fail(c, "SetHelper", "field %v (%s): a blob's SetHelper row needs a LengthId and no MarkerId", node.id, node.name)
		}
		e := length_expr(c, node, length_id, false) or_return
		return mdata.Rule_Length{expr = e, min = min_length, max = max_length}, true
	}

	if hi < lo {
		return nil, fail(c, "DataType", "data type %v: a blob without a SetHelper length has length %v, below MinBufferLength %v", dt.id, hi, lo)
	}
	return mdata.Fixed_Length{hi}, true
}

@(private = "file")
compile_bits :: proc(c: ^Compiler, node: ^mdata.Node) -> (bits: []mdata.Bit_Field, ok: bool) {
	n := 0
	for p in c.records.packed_records {
		if p.id == node.id do n += 1
	}
	if n == 0 do return nil, true

	sizes := TYPE_SIZE
	width := 8 * sizes[node.type]
	if width == 0 do return nil, fail(c, "Packed", "field %v (%s) is a %v, which cannot have packed fields", node.id, node.name, node.type)

	bits = make([]mdata.Bit_Field, n, c.allocator)
	i := 0
	for p in c.records.packed_records {
		if p.id != node.id do continue

		field := c.records.field_map[p.field_id]
		if field == nil do return nil, fail(c, "Packed", "field %v (%s): packed field %v not found", node.id, node.name, p.field_id)

		dt := data_type(c, field.data_type_id, "Field", p.field_id) or_return
		type := dat.Data_Type(dt.type)
		if sizes[type] == 0 do return nil, fail(c, "Packed", "field %v (%s): packed field %v is a %v, not an integer", node.id, node.name, p.field_id, type)

		if p.low_bit < 0 || p.low_bit > p.high_bit || p.high_bit >= width {
			return nil, fail(c, "Packed", "field %v (%s): packed field %v has bits %v to %v, not within 0 to %v", node.id, node.name, p.field_id, p.low_bit, p.high_bit, width - 1)
		}

		bits[i] = {
			id            = p.field_id,
			name          = strings.clone(field.name, c.allocator),
			low           = p.low_bit,
			high          = p.high_bit,
			default_value = compile_default(c, dt, type, 0) or_return,
		}
		i += 1
	}
	return bits, true
}

// dt's DefaultValue as type, or nil when there is none. max_bytes bounds a
// String default.
@(private = "file")
compile_default :: proc(c: ^Compiler, dt: ^Data_Type_Record, type: dat.Data_Type, max_bytes: int) -> (value: mdata.Scalar, ok: bool) {
	text, has_default := dt.default_value.?
	if !has_default do return nil, true

	switch type {
	case .Set, .Blob:
		return nil, fail(c, "DataType", "data type %v: a %v cannot have a DefaultValue", dt.id, type)
	case .String:
		if len(text) > max_bytes {
			return nil, fail(c, "DataType", "data type %v: DefaultValue %q is longer than MaxBufferLength %v", dt.id, text, max_bytes)
		}
		return strings.clone(text, c.allocator), true
	case .Int8:
		return default_number(c, dt, text, type, i8)
	case .UInt8:
		return default_number(c, dt, text, type, u8)
	case .Int16:
		return default_number(c, dt, text, type, i16)
	case .UInt16:
		return default_number(c, dt, text, type, u16)
	case .Int32:
		return default_number(c, dt, text, type, i32)
	case .UInt32:
		return default_number(c, dt, text, type, u32)
	case .Int64:
		return default_number(c, dt, text, type, i64)
	case .UInt64:
		return default_number(c, dt, text, type, u64)
	case .Float32:
		return default_number(c, dt, text, type, f32)
	case .Float64:
		return default_number(c, dt, text, type, f64)
	}
	unreachable()
}

// The default text as a T, within MinValue and MaxValue when they are set.
@(private = "file")
default_number :: proc(c: ^Compiler, dt: ^Data_Type_Record, text: string, type: dat.Data_Type, $T: typeid) -> (value: mdata.Scalar, ok: bool) {
	n := parse_number(c, dt, "DefaultValue", text, type, T) or_return

	if lo_text, has_min := dt.min_value.?; has_min {
		lo := parse_number(c, dt, "MinValue", lo_text, type, T) or_return
		if !(lo <= n) do return nil, fail(c, "DataType", "data type %v: DefaultValue %v is below MinValue %v", dt.id, text, lo_text)
	}
	if hi_text, has_max := dt.max_value.?; has_max {
		hi := parse_number(c, dt, "MaxValue", hi_text, type, T) or_return
		if !(n <= hi) do return nil, fail(c, "DataType", "data type %v: DefaultValue %v is above MaxValue %v", dt.id, text, hi_text)
	}

	return n, true
}

// text as a T: a float, or a decimal integer within T's range. column names
// the DataType column text came from, for the error.
@(private = "file")
parse_number :: proc(c: ^Compiler, dt: ^Data_Type_Record, column, text: string, type: dat.Data_Type, $T: typeid) -> (n: T, ok: bool) {
	when intrinsics.type_is_float(T) {
		f, parsed := strconv.parse_f64(text)
		n = T(f)
		ok = parsed && (math.is_inf(f) || !math.is_inf(n)) // out of range for f32
	} else {
		n, ok = parse_integer(text, T)
	}

	if !ok do return n, fail(c, "DataType", "data type %v: %s %q is not a %v", dt.id, column, text, type)
	return n, true
}

// text as an optionally signed decimal integer that fits in T.
@(private = "file")
parse_integer :: proc(text: string, $T: typeid) -> (n: T, ok: bool) where intrinsics.type_is_integer(T) {
	digits := text
	negative := len(digits) > 0 && digits[0] == '-'
	if negative || (len(digits) > 0 && digits[0] == '+') do digits = digits[1:]
	if digits == "" do return

	v: i128
	for ch in transmute([]byte)digits {
		if ch < '0' || ch > '9' do return
		v = v * 10 + i128(ch - '0')
		if v > i128(max(u64)) do return // too large for any T; stop before v overflows
	}
	if negative do v = -v

	if v < i128(min(T)) || v > i128(max(T)) do return
	return T(v), true
}
