package reader

import "../metadata"
import "../data"
import "core:os"

read :: proc(name: string, file_format: ^metadata.File_Format, root_field_value_array: ^[dynamic]data.Field_Value) {
  buffer: data.Byte_Buffer
  data.read_file_into_buffer(&buffer, name)
}


@(private = "file")
readSet :: proc() {

}

read_integer :: proc(buffer: ^data.Byte_Buffer, data_type: data.Data_Type) -> (value: int, ok: bool) {
  ok = true
  #partial switch data_type {
  case .Int8: value = int(data.get_i8(buffer))
  case .UInt8: value = int(data.get_u8(buffer))
  case .Int16: value = int(data.get_i16(buffer))
  case .UInt16: value = int(data.get_u16(buffer))
  case .Int32: value = int(data.get_i32(buffer))
  case .UInt32: value = int(data.get_u32(buffer))
  case .Int64: value = int(data.get_i64(buffer))
  case:
    ok = false
  }
  return value, ok
}
