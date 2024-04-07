package data

import "core:bytes"
import "core:encoding/endian"
import "core:os"

Byte_Buffer :: struct {
  data: bytes.Buffer,
  byteOrder: endian.Byte_Order
}

destroy :: proc(buffer: ^Byte_Buffer) {
  bytes.buffer_destroy(&buffer.data)
}

get_i8 :: proc(buffer: ^Byte_Buffer) -> i8 {
  value, error := bytes.buffer_read_byte(&buffer.data)
  return i8(value)
}

get_u8 :: proc(buffer: ^Byte_Buffer) -> u8 {
  value, error := bytes.buffer_read_byte(&buffer.data)
  return value
}

get_i16 :: proc(buffer: ^Byte_Buffer) -> i16 {
  buf := bytes.buffer_next(&buffer.data, 2)
  value, ok := endian.get_i16(buf, buffer.byteOrder)
  return value
}

get_u16 :: proc(buffer: ^Byte_Buffer) -> u16 {
  buf := bytes.buffer_next(&buffer.data, 2)
  value, ok := endian.get_u16(buf, buffer.byteOrder)
  return value
}

get_i32 :: proc(buffer: ^Byte_Buffer) -> i32 {
  buf := bytes.buffer_next(&buffer.data, 4)
  value, ok := endian.get_i32(buf, buffer.byteOrder)
  return value
}

get_u32 :: proc(buffer: ^Byte_Buffer) -> u32 {
  buf := bytes.buffer_next(&buffer.data, 4)
  value, ok := endian.get_u32(buf, buffer.byteOrder)
  return value
}

get_i64 :: proc(buffer: ^Byte_Buffer) -> i64 {
  buf := bytes.buffer_next(&buffer.data, 8)
  value, ok := endian.get_i64(buf, buffer.byteOrder)
  return value
}

read_integer :: proc(buffer: ^Byte_Buffer, data_type: Data_Type) -> (value: int, ok: bool) {
  ok = true
  #partial switch data_type {
  case .Int8: value = int(get_i8(buffer))
  case .UInt8: value = int(get_u8(buffer))
  case .Int16: value = int(get_i16(buffer))
  case .UInt16: value = int(get_u16(buffer))
  case .Int32: value = int(get_i32(buffer))
  case .UInt32: value = int(get_u32(buffer))
  case .Int64: value = int(get_i64(buffer))
  case:
    ok = false
  }
  return value, ok
}

read_file_into_buffer :: proc(buffer: ^Byte_Buffer, name: string) {
  buf, ok := os.read_entire_file_from_filename(name)
  if (ok) {
    bytes.buffer_init(&buffer.data, buf)
  }
}
