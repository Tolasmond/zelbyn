package field

import dat "../data"
import "core:fmt"

Field_Data_Type :: struct {
  id: i32,
  data_type: dat.Data_Type,
  min_value: Maybe(string),
  max_value: Maybe(string),
  default_value: Maybe(string),
  units: Maybe(string),
  min_length: Maybe(i32),
  max_length: Maybe(i32),
  min_array_length: Maybe(i32),
  max_array_length: Maybe(i32),
  grow_as_needed: Maybe(bool),
  pattern: Maybe(string),
  comparison_tolerance: Maybe(f64),
}

description :: proc(field_data_type: ^Field_Data_Type) -> string {
	return fmt.aprintf("id = %v", field_data_type.id)
}
