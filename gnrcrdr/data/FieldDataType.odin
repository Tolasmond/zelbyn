package data

import "core:fmt"

FieldDataType :: struct {
  id: i32,
  dataType: DataType,
  minValue: Maybe(string),
  maxValue: Maybe(string),
  defaultValue: Maybe(string),
  units: Maybe(string),
  minLength: Maybe(i32),
  maxLength: Maybe(i32),
  minArrayLength: Maybe(i32),
  maxArrayLength: Maybe(i32),
  growAsNeeded: Maybe(bool),
  pattern: Maybe(string),
  comparisonTolerance: Maybe(f64)
}

description :: proc(fieldDataType: ^FieldDataType) -> string {
	return fmt.aprintf("id = %v", fieldDataType.id)
}
