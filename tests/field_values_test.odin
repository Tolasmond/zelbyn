package tests

import dat "../gnrcrdr/data"
import fld "../gnrcrdr/field"
import mdat "../gnrcrdr/metadata"
import "core:strings"
import "core:testing"

@(test)
string_default_cloned :: proc(t: ^testing.T) {
	dt := new(dat.Data_Type_Record)
	dt.type = int(dat.Data_Type.String)
	dt.default_value = strings.clone("abc")
	dt.min_array_length = 3
	defer dat.destroy_data_type_record(dt)
	fm := mdat.Field_Metadata{id = 1, name = "s", data_type = dt}
	node := mdat.Field_Metadata_Tree_Node{metadata = &fm}

	arr: [dynamic]fld.Value
	fld.initializeFieldValueArray(&arr, &node)
	defer fld.destroy_field(arr)

	if !testing.expect_value(t, len(arr), 3) do return

	default_ptr := raw_data(dt.default_value.?)
	ptrs: [3]rawptr
	for v, i in arr {
		s, is_str := v.(string)
		testing.expectf(t, is_str && s == "abc", "arr[%v] = %v, want \"abc\"", i, v)
		ptrs[i] = raw_data(s)
		testing.expectf(t, ptrs[i] != default_ptr, "arr[%v] aliases the metadata default", i)
	}
	testing.expect(t, ptrs[0] != ptrs[1] && ptrs[0] != ptrs[2] && ptrs[1] != ptrs[2], "elements share a string")
}

@(test)
set_value_frees_old :: proc(t: ^testing.T) {
	dt := new(dat.Data_Type_Record)
	dt.type = int(dat.Data_Type.String)
	dt.default_value = strings.clone("abc")
	dt.min_array_length = 3
	defer dat.destroy_data_type_record(dt)
	fm := mdat.Field_Metadata{id = 1, name = "s", data_type = dt}
	node := mdat.Field_Metadata_Tree_Node{metadata = &fm}

	arr: [dynamic]fld.Value
	fld.initializeFieldValueArray(&arr, &node)
	defer fld.destroy_field(arr)

	fld.set_value(&node, &arr, nil, 0, fld.Value(strings.clone("xyz")))

	s, is_str := arr[0].(string)
	testing.expect(t, is_str && s == "xyz", "arr[0] should be \"xyz\"")
}

@(test)
numeric_min_array_length :: proc(t: ^testing.T) {
	dt := new(dat.Data_Type_Record)
	dt.type = int(dat.Data_Type.Int16)
	dt.default_value = strings.clone("7")
	dt.min_array_length = 3
	defer dat.destroy_data_type_record(dt)
	fm := mdat.Field_Metadata{id = 1, name = "n", data_type = dt}
	node := mdat.Field_Metadata_Tree_Node{metadata = &fm}

	arr: [dynamic]fld.Value
	fld.initializeFieldValueArray(&arr, &node)
	defer fld.destroy_field(arr)

	testing.expect_value(t, len(arr), 3)
	for v, i in arr {
		n, is_i16 := v.(i16)
		testing.expectf(t, is_i16 && n == 7, "arr[%v] = %v, want i16(7)", i, v)
	}
}
