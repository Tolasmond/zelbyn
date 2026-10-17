package tests

import dat "../gnrcrdr/data"
import fld "../gnrcrdr/field"
import mdat "../gnrcrdr/metadata"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

// Hand-built metadata for one field, allocated in arena.
@(private = "file")
field_node :: proc(arena: ^virtual.Arena, type: dat.Data_Type, default_value: string, min_array_length: int) -> ^mdat.Field_Metadata_Tree_Node {
	a := virtual.arena_allocator(arena)
	dt := new(dat.Data_Type_Record, a)
	dt.type = int(type)
	dt.default_value = strings.clone(default_value, a)
	dt.min_array_length = min_array_length
	fm := new(mdat.Field_Metadata, a)
	fm^ = {id = 1, name = "s", data_type = dt}
	node := new(mdat.Field_Metadata_Tree_Node, a)
	node.metadata = fm
	return node
}

@(test)
string_default_cloned :: proc(t: ^testing.T) {
	meta: virtual.Arena
	defer virtual.arena_destroy(&meta)
	values: virtual.Arena
	defer virtual.arena_destroy(&values)
	va := virtual.arena_allocator(&values)

	node := field_node(&meta, .String, "abc", 3)
	arr: [dynamic]fld.Value

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		fld.initializeFieldValueArray(&arr, node, va)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect(t, arr.allocator.data == rawptr(&values), "the zero-value array did not adopt the arena")

	if !testing.expect_value(t, len(arr), 3) do return

	default_ptr := raw_data(node.metadata.data_type.default_value.?)
	ptrs: [3]rawptr
	for v, i in arr {
		s, is_str := v.(string)
		testing.expectf(t, is_str && s == "abc", "arr[%v] = %v, want \"abc\"", i, v)
		ptrs[i] = raw_data(s)
		testing.expectf(t, ptrs[i] != default_ptr, "arr[%v] aliases the metadata default", i)
	}
	testing.expect(t, ptrs[0] != ptrs[1] && ptrs[0] != ptrs[2] && ptrs[1] != ptrs[2], "elements share a string")
}

// Replaces the old set_value_frees_old: with an arena there is nothing to free.
@(test)
set_value_overwrites :: proc(t: ^testing.T) {
	meta: virtual.Arena
	defer virtual.arena_destroy(&meta)
	values: virtual.Arena
	defer virtual.arena_destroy(&values)
	va := virtual.arena_allocator(&values)

	node := field_node(&meta, .String, "abc", 3)
	arr: [dynamic]fld.Value

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		fld.initializeFieldValueArray(&arr, node, va)
		fld.set_value(node, &arr, nil, 0, fld.Value(strings.clone("xyz", va)))
	}
	testing.expect_value(t, track.total_allocation_count, 0)

	if !testing.expect_value(t, len(arr), 3) do return
	testing.expect_value(t, arr[0].(string), "xyz")
	testing.expect_value(t, arr[1].(string), "abc")
	testing.expect_value(t, arr[2].(string), "abc")
}

@(test)
numeric_min_array_length :: proc(t: ^testing.T) {
	meta: virtual.Arena
	defer virtual.arena_destroy(&meta)
	values: virtual.Arena
	defer virtual.arena_destroy(&values)
	va := virtual.arena_allocator(&values)

	node := field_node(&meta, .Int16, "7", 3)
	arr := make([dynamic]fld.Value, va)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		fld.initializeFieldValueArray(&arr, node, va)
	}
	testing.expect_value(t, track.total_allocation_count, 0)

	testing.expect_value(t, len(arr), 3)
	for v, i in arr {
		n, is_i16 := v.(i16)
		testing.expectf(t, is_i16 && n == 7, "arr[%v] = %v, want i16(7)", i, v)
	}
}

@(test)
set_count_uses_allocator :: proc(t: ^testing.T) {
	meta: virtual.Arena
	defer virtual.arena_destroy(&meta)
	values: virtual.Arena
	defer virtual.arena_destroy(&values)
	va := virtual.arena_allocator(&values)

	child := field_node(&meta, .String, "abc", 1)
	set := field_node(&meta, .Set, "", 0)
	set.metadata.id = 2
	set.children = make([dynamic]^mdat.Field_Metadata_Tree_Node, virtual.arena_allocator(&meta))
	append(&set.children, child)
	arr := make([dynamic]fld.Value, va)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		fld.initializeFieldValueArray(&arr, set, va)
		fld.set_count(3, set, &arr, va)
		fld.set_count(1, set, &arr, va)
	}
	testing.expect_value(t, track.total_allocation_count, 0)

	if !testing.expect_value(t, len(arr), 1) do return
	testing.expect_value(t, set_of(arr[0])[1][0].(string), "abc")
}
