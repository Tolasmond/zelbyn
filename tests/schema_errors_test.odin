package tests

import mdat "../gnrcrdr/metadata"
import sql "../gnrcrdr/sqlite"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

// One way of breaking the GIF89a records, and the error compile must give.
@(private = "file")
Schema_Error_Case :: struct {
	name:    string,
	mutate:  proc(r: ^sql.Records, a: mem.Allocator),
	table:   string,
	message: string, // must occur in the error's message
}

@(private = "file")
add_parent :: proc(r: ^sql.Records, a: mem.Allocator, parent, child, index: int) {
	rows := r.parent_map[parent]
	if rows.allocator.procedure == nil do rows = make([dynamic]^sql.Parent_Record, a)
	append(&rows, new_clone(sql.Parent_Record{format_id = 1, parent_id = parent, child_id = child, child_index = index}, a))
	r.parent_map[parent] = rows
}

@(private = "file")
SCHEMA_ERROR_CASES := [?]Schema_Error_Case {
	// missing references and bad type codes
	{"missing root", proc(r: ^sql.Records, a: mem.Allocator) {r.format_record.root_field = 4999}, "Format", "field 4999 not found"},
	{"missing child", proc(r: ^sql.Records, a: mem.Allocator) {delete_key(&r.field_map, 5068)}, "Parent", "field 5068 not found"},
	{"missing data type", proc(r: ^sql.Records, a: mem.Allocator) {r.field_map[5004].data_type_id = 999}, "Field", "Field row 5004: data type 999 not found"},
	{"unknown type code", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[7].type = 99}, "DataType", "data type 7: unknown type code 99"},
	{"missing length", proc(r: ^sql.Records, a: mem.Allocator) {r.set_helper_map[5013].length_id = 99}, "SetHelper", "length 99 not found"},
	{"marker without offsets", proc(r: ^sql.Records, a: mem.Allocator) {r.set_helper_map[5019].marker_id = 9}, "SetHelper", "marker 9 has no MarkerOffset rows"},
	{"missing packed field", proc(r: ^sql.Records, a: mem.Allocator) {r.packed_records[0].field_id = 4242}, "Packed", "packed field 4242 not found"},

	// tree shape
	{"cycle", proc(r: ^sql.Records, a: mem.Allocator) {add_parent(r, a, 5003, 5000, 9)}, "Parent", "field 5000 contains itself"},
	{"duplicate ChildIndex", proc(r: ^sql.Records, a: mem.Allocator) {r.parent_map[5003][1].child_index = 0}, "Parent", "both have ChildIndex 0"},
	{"duplicate child", proc(r: ^sql.Records, a: mem.Allocator) {add_parent(r, a, 5003, 5004, 9)}, "Parent", "child 5004 appears twice"},
	{"children of a scalar", proc(r: ^sql.Records, a: mem.Allocator) {add_parent(r, a, 5004, 5005, 0)}, "Parent", "is a UInt16, not a set, but has children"},

	// DataType columns
	{"IsGrowAsNeeded 2", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[3].is_grow_as_needed = 2}, "DataType", "IsGrowAsNeeded is 2, not 0 or 1"},
	{"growing scalar", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[19].is_grow_as_needed = 1}, "DataType", "IsGrowAsNeeded is set on a UInt16"},
	{"negative MinArrayLength", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[1].min_array_length = -1}, "DataType", "MinArrayLength is -1"},
	{"growing set with MinArrayLength", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[3].min_array_length = 1}, "DataType", "a growing set cannot have a MinArrayLength"},
	{"String without MaxBufferLength", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[10000].max_buffer_length = nil}, "DataType", "a String needs a MaxBufferLength"},
	{"MinBufferLength above MaxBufferLength", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[22].min_buffer_length = 300}, "DataType", "buffer lengths 300 to 255"},
	{"blob below MinBufferLength", proc(r: ^sql.Records, a: mem.Allocator) {
			r.data_type_map[22].min_buffer_length = 5
			r.data_type_map[22].max_buffer_length = nil
			delete_key(&r.set_helper_map, 5052)
		}, "DataType", "has length 0, below MinBufferLength 5"},

	// SetHelper rows
	{"both LengthId and MarkerId", proc(r: ^sql.Records, a: mem.Allocator) {r.set_helper_map[5019].length_id = 1}, "SetHelper", "exactly one of LengthId and MarkerId"},
	{"helper on a number", proc(r: ^sql.Records, a: mem.Allocator) {
			r.set_helper_map[5004] = new_clone(sql.Set_Helper_Record{format_id = 1, field_id = 5004, marker_id = 1}, a)
		}, "SetHelper", "a UInt16 takes no SetHelper row"},
	{"growing set without LengthId", proc(r: ^sql.Records, a: mem.Allocator) {
			r.set_helper_map[5017].length_id = nil
			r.set_helper_map[5017].marker_id = 1
		}, "SetHelper", "grows as needed but has no LengthId"},
	{"helper on a fixed-length blob", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[22].min_buffer_length = 255}, "SetHelper", "a fixed-length blob"},

	// Length rows
	{"both Continuator and Terminator", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[4].continuator = 33}, "Length", "exactly one of Continuator and Terminator"},
	{"repeat with a mask", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[3].value_mask = 7}, "Length", "only Continuator or Terminator may be set"},
	{"count with a Terminator", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[5].terminator = 0}, "Length", "Continuator and Terminator only apply to growing sets"},
	{"absolute and relative flag", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[5].flag_absoute_offset_from_beginning = 10}, "Length", "both FlagAbsoluteOffsetFromBeginning and FlagRelativeOffsetFromField"},
	{"mask without an offset", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[1].flag_mask = 1}, "Length", "FlagMask or FlagShift without an offset"},
	{"shift out of range", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[5].flag_shift = 64}, "Length", "FlagShift is 64"},
	{"FlagExpression", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[5].flag_expression = "x"}, "Length", "FlagExpression is not supported"},
	{"unknown ValueExpression", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[5].value_expression = "Pow(3, [x])"}, "Length", `ValueExpression "Pow(3, [x])" is not supported`},
	{"blob ValueExpression", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[1].value_expression = "x"}, "Length", "ValueExpression is not supported on a blob length"},
	{"peek a String", proc(r: ^sql.Records, a: mem.Allocator) {r.set_length_map[5].data_type_id = 20}, "Length", "is a String, which cannot be peeked"},
	{"peek a UInt64", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[8].type = 8}, "Length", "is a UInt64, which cannot be peeked"},
	{"marker peeks a Blob", proc(r: ^sql.Records, a: mem.Allocator) {r.marker_offset_map[1][0].data_type_id = 21}, "MarkerOffset", "is a Blob, which cannot be peeked"},

	// Packed rows
	{"packed set", proc(r: ^sql.Records, a: mem.Allocator) {r.packed_records[0].id = 5003}, "Packed", "is a Set, which cannot have packed fields"},
	{"packed bits too wide", proc(r: ^sql.Records, a: mem.Allocator) {r.packed_records[0].high_bit = 8}, "Packed", "not within 0 to 7"},
	{"packed field without a data type", proc(r: ^sql.Records, a: mem.Allocator) {r.field_map[5009].data_type_id = 999}, "Field", "Field row 5009: data type 999 not found"},
	{"packed field not an integer", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[6].type = 11}, "Packed", "packed field 5009 is a String, not an integer"},

	// DefaultValue
	{"default on a set", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[1].default_value = "0"}, "DataType", "data type 1: a Set cannot have a DefaultValue"},
	{"default on a blob", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[22].default_value = "00"}, "DataType", "data type 22: a Blob cannot have a DefaultValue"},
	{"default not a number", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[13].default_value = "0x21"}, "DataType", `data type 13: DefaultValue "0x21" is not a UInt8`},
	{"default too large for the type", proc(r: ^sql.Records, a: mem.Allocator) {
			r.data_type_map[7].default_value = "256"
			r.data_type_map[7].max_value = nil
		}, "DataType", `DefaultValue "256" is not a UInt8`},
	{"negative unsigned default", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[7].default_value = "-1"}, "DataType", `DefaultValue "-1" is not a UInt8`},
	{"default too large for any type", proc(r: ^sql.Records, a: mem.Allocator) {
			r.data_type_map[7].type = 8 // UInt64
			r.data_type_map[7].default_value = "18446744073709551616"
			r.data_type_map[7].max_value = nil
		}, "DataType", `DefaultValue "18446744073709551616" is not a UInt64`},
	{"default below MinValue", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[19].min_value = "10"}, "DataType", "data type 19: DefaultValue 0 is below MinValue 10"},
	{"default above MaxValue", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[6].default_value = "8"}, "DataType", "data type 6: DefaultValue 8 is above MaxValue 7"},
	{"MinValue not a number", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[19].min_value = "low"}, "DataType", `data type 19: MinValue "low" is not a UInt16`},
	{"MaxValue not a number", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[19].max_value = "65536"}, "DataType", `data type 19: MaxValue "65536" is not a UInt16`},
	{"float default above MaxValue", proc(r: ^sql.Records, a: mem.Allocator) {
			r.data_type_map[19].type = 9 // Float32
			r.data_type_map[19].default_value = "65535.5"
		}, "DataType", "data type 19: DefaultValue 65535.5 is above MaxValue 65535"},
	{"float default out of range", proc(r: ^sql.Records, a: mem.Allocator) {
			r.data_type_map[19].type = 9 // Float32
			r.data_type_map[19].default_value = "1e39"
			r.data_type_map[19].max_value = nil
		}, "DataType", `DefaultValue "1e39" is not a Float32`},
	{"String default too long", proc(r: ^sql.Records, a: mem.Allocator) {r.data_type_map[10000].default_value = "GIF8"}, "DataType", `data type 10000: DefaultValue "GIF8" is longer than MaxBufferLength 3`},
}

@(test)
schema_errors :: proc(t: ^testing.T) {
	for c in SCHEMA_ERROR_CASES {
		arena: virtual.Arena
		defer virtual.arena_destroy(&arena)
		a := virtual.arena_allocator(&arena)

		records: sql.Records
		read_err := sql.read_records(DB_PATH, 1, &records, a)
		defer sql.destroy_load_error(&read_err)
		if !testing.expectf(t, read_err.kind == .None, "%s: reading records: %v: %s", c.name, read_err.kind, read_err.message) do continue

		c.mutate(&records, a)

		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		err := sql.compile(&records, &ff)
		defer sql.destroy_load_error(&err)

		testing.expectf(
			t,
			err.kind == .Invalid_Schema && err.table == c.table && strings.contains(err.message, c.message),
			"%s: got %v, table %q, %q; want Invalid_Schema, table %q, a message containing %q",
			c.name, err.kind, err.table, err.message, c.table, c.message,
		)
	}
}

// The unmodified records compile, and compiling them twice gives two
// independent plans.
@(test)
schema_compiles_twice :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)

	records: sql.Records
	read_err := sql.read_records(DB_PATH, 1, &records, virtual.arena_allocator(&arena))
	defer sql.destroy_load_error(&read_err)
	if !testing.expectf(t, read_err.kind == .None, "reading records: %v: %s", read_err.kind, read_err.message) do return

	first, second: mdat.File_Format
	defer mdat.destroy_file_format(&first)
	defer mdat.destroy_file_format(&second)

	for ff in ([?]^mdat.File_Format{&first, &second}) {
		err := sql.compile(&records, ff)
		defer sql.destroy_load_error(&err)
		testing.expectf(t, err.kind == .None, "%v (table %s): %s", err.kind, err.table, err.message)
	}
	testing.expect(t, first.root != nil && second.root != nil && first.root != second.root, "the plans are not independent")
}
